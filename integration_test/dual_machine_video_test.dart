import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart'
    show createPreviewEngine;
import 'package:share_hub_open/features/connections/connection_controller.dart';

import 'owned_video_pixels.dart';
import 'owned_video_view.dart';
import 'probe_report.dart';
import 'atomic_probe_record.dart';

// Two physical hosts, ordinary SDK entry point and authenticated TCP signaling.
// Config/ready/command files are ephemeral local orchestration, never a network
// command endpoint. Only Windows may send, and only the exact owned fixture.
// macOS is receiver-only: its source resolver rejects before enumeration.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real two-device generated video and playback lifecycle', (
    tester,
  ) async {
    const configPath = String.fromEnvironment('CHUAN_DUAL_PROBE_CONFIG');
    const console = bool.fromEnvironment('CHUAN_DUAL_PROBE_CONSOLE');
    const runId = String.fromEnvironment('CHUAN_DUAL_PROBE_RUN');
    const receiverRounds = int.fromEnvironment(
      'CHUAN_DUAL_PROBE_ROUNDS',
      defaultValue: 1,
    );
    expect(console ? Platform.isMacOS : configPath.isNotEmpty, isTrue);
    final config = console
        ? <String, dynamic>{'role': 'receiver', 'runId': runId}
        : jsonDecode(await File(configPath).readAsString())
              as Map<String, dynamic>;
    final sends = config['role'] == 'sender';
    final roundLimit = console ? receiverRounds : config['rounds'] ?? 1;
    expect(roundLimit, inInclusiveRange(1, 20));
    expect(config['role'], isIn(['sender', 'receiver']));
    expect(sends ? Platform.isWindows : Platform.isMacOS, isTrue);
    final reportFile = console ? null : File(config['report'] as String);
    final commandFile = console ? null : File(config['command'] as String);
    final readyFile = console ? null : File(config['ready'] as String);
    final engine = createPreviewEngine();
    expect(engine, isA<RemoteMediaProvider>());
    final factory = (engine as RemoteMediaProvider).remoteMedia;
    final registry = GrantRegistry();
    final budget = MediaSessionBudget(factory.capabilities, grants: registry);
    final identity = await DeviceIdentity.fromSeed(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final clock = MethodChannelConnectionPlatform().now;
    PairingHost? host;
    TrustedConnection? connection;
    RemoteMediaLink? link;
    RemoteVideoSession? session;
    StreamSubscription<MediaSessionEvent>? subscription;
    final key = GlobalKey();
    final failures = <String>[];
    var revisions = <int, Map<String, Object?>>{};
    var markers = <int, Set<bool>>{};
    var previousMarker = <int, bool>{};
    var markerTransitions = <int, int>{};
    var counts = <String, int>{};
    final completedRounds = <Map<String, Object?>>[];
    final sessionIds = <String>{};
    var round = 0, stoppedSamples = 0;
    var stoppedSampleTimes = <int>[];
    var sourceQueries = 0, sequence = 0, ack = 0;
    var passed = false, checksDone = false, validated = false;
    String? commandError, failureCode;
    final elapsed = Stopwatch()..start();
    var probePhase = 'initializing', phaseSinceMillis = 0, lastReport = -1000;
    Timer? heartbeat;
    Future<T> probeStep<T>(String phase, Future<T> Function() action) {
      probePhase = phase;
      phaseSinceMillis = elapsed.elapsedMilliseconds;
      return action();
    }

    void attach(TrustedConnection value) {
      if (connection != null) throw StateError('duplicate_connection');
      connection = value;
      registry.register(value.grant!);
      link = factory.createLink(
        transport: value,
        budget: budget,
        resolveSource: () async {
          if (!sends) throw StateError('receiver_capture_forbidden');
          sourceQueries++;
          final sources = await engine.sources();
          final matches = sources
              .where(
                (source) =>
                    source.type == CaptureSourceType.window &&
                    source.id == config['sourceId'] &&
                    source.name == config['sourceTitle'],
              )
              .toList();
          if (matches.length != 1) throw StateError('owned_source_missing');
          return matches.single;
        },
        onSession: (value) {
          if (session != null && !validated) {
            throw StateError('duplicate_session');
          }
          expectSync(completedRounds.length, round);
          expectSync(round, lessThan(roundLimit));
          expectSync(sessionIds.add(value.id), isTrue);
          round++;
          revisions = {};
          markers = {};
          previousMarker = {};
          markerTransitions = {};
          counts = {};
          stoppedSamples = 0;
          stoppedSampleTimes = [];
          validated = false;
          session = value;
          // Each subscription owns this session's maps. Late events must not
          // satisfy a later session with the same media revision numbers.
          final ownedCounts = counts, ownedRevisions = revisions;
          subscription = value.events.listen((event) {
            expectSync(event.sessionId, value.id);
            ownedCounts.update(
              event.kind.name,
              (n) => n + 1,
              ifAbsent: () => 1,
            );
            final summary = ownedRevisions.putIfAbsent(
              event.mediaRevision,
              () => {},
            );
            if (event.kind == MediaEventKind.firstFrame) {
              summary['firstFrame'] = true;
            }
            if (event.transportPath != null) {
              summary['path'] = event.transportPath!.name;
            }
            if (event.frameProgress case final progress?) {
              final prefix = event.kind == MediaEventKind.peerFrameProgress
                  ? 'peer'
                  : 'local';
              summary['${prefix}Stage'] = progress.stage.name;
              summary['${prefix}Sequence'] = progress.sequence;
              summary['${prefix}Consumed'] = progress.consumedSequence;
              summary['${prefix}Active'] = progress.active;
            }
            if (event.kind == MediaEventKind.failed) {
              failures.add(event.failureCode ?? 'unknown_media_failure');
            }
          });
        },
        onFailure: (_, code) => failures.add(code),
      );
      value.startMonitoring();
    }

    Future<void> publish({String? failure}) async {
      failureCode ??= failure;
      final result = <String, Object?>{
        'schema': 1,
        'runId': config['runId'],
        'role': config['role'],
        'platform': Platform.operatingSystem,
        'pid': pid,
        'round': round,
        'roundLimit': roundLimit,
        'uniqueSessionCount': sessionIds.length,
        'completedRounds': completedRounds,
        'stoppedSamples': stoppedSamples,
        'stoppedSampleTimes': stoppedSampleTimes,
        'paired': connection != null,
        'elapsedMillis': elapsed.elapsedMilliseconds,
        'probePhase': probePhase,
        'phaseAgeMillis': elapsed.elapsedMilliseconds - phaseSinceMillis,
        'ack': ack,
        'commandError': commandError,
        'budget': budget.activeCount,
        'sourceQueries': sourceQueries,
        'revision': session?.mediaRevision,
        'stopped': session?.stopped,
        'counts': counts,
        'revisions': {for (final e in revisions.entries) '${e.key}': e.value},
        'markers': {
          for (final e in markers.entries) '${e.key}': e.value.toList(),
        },
        'markerTransitions': {
          for (final e in markerTransitions.entries) '${e.key}': e.value,
        },
        'failures': failures,
        'failure': failureCode,
        'passed': passed,
        'validated': validated,
      };
      if (console) {
        writeProbeRecord('DUAL_REPORT', result);
      } else {
        await _atomicJson(reportFile!, result);
      }
    }

    // If a GUI frame/readback stops advancing, expose SDK state independently
    // of that await. Console-only: never race atomic report-file replacements.
    if (console) {
      heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
        if (elapsed.elapsedMilliseconds - lastReport >= 1500) {
          lastReport = elapsed.elapsedMilliseconds;
          unawaited(publish());
        }
      });
    }

    try {
      await tester.pumpWidget(
        const MaterialApp(home: Text('Dual-device video probe')),
      );
      if (sends) {
        attach(
          await PairingAttempt(
            identity: identity,
            clock: clock,
            protocolVersion: 2,
          ).connect(
            config['host'] as String,
            config['port'] as int,
            config['code'] as String,
            expectedPeerKey: config['peerKey'] as String,
          ),
        );
        await link!.start(
          SessionOperation.cast,
          'dual-${Random.secure().nextInt(1 << 30)}',
        );
      } else {
        host = PairingHost(
          identity: identity,
          clock: clock,
          protocolVersion: 2,
          onConnection: attach,
        );
        await host.open();
        final ready = <String, Object?>{
          'runId': config['runId'],
          'rounds': roundLimit,
          'pid': pid,
          'port': host.port,
          'code': host.offer!.code,
          'peerKey': identity.encodedKey,
        };
        if (console) {
          // Keep this ephemeral pairing material in the ignored runner log.
          writeProbeRecord('DUAL_READY', ready);
        } else {
          await _atomicJson(readyFile!, ready);
        }
      }
      RemoteVideoSession? mountedSession;
      var lastSample = -1000;
      while (!checksDone && elapsed.elapsed < const Duration(minutes: 10)) {
        expect(failures, isEmpty, reason: 'Actual media failure');
        if (connection?.isClosed == true &&
            (!validated || completedRounds.length != roundLimit)) {
          throw StateError('peer_closed_before_validation');
        }
        if (session != null && session != mountedSession) {
          final mounting = session!;
          expect(mounting.sends, sends);
          await probeStep(
            'mount',
            () => tester.pumpWidget(ownedVideoProbeView(key, mounting.view)),
          );
          mountedSession = mounting;
        }
        final beforePumpSession = session;
        final beforePump = beforePumpSession == null
            ? null
            : OwnedVideoSampleState(
                beforePumpSession,
                beforePumpSession.mediaRevision,
                beforePumpSession.stopped,
              );
        await probeStep(
          'pump',
          () => tester.pump(const Duration(milliseconds: 50)),
        );
        if (!sends &&
            mountedSession != null &&
            elapsed.elapsedMilliseconds - lastSample >= 200) {
          lastSample = elapsed.elapsedMilliseconds;
          final boundary =
              key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
          final sampledSession = session;
          if (sampledSession != null &&
              identical(sampledSession, mountedSession) &&
              boundary != null &&
              !boundary.debugNeedsPaint) {
            final sampledState = OwnedVideoSampleState(
              sampledSession,
              sampledSession.mediaRevision,
              sampledSession.stopped,
            );
            if (beforePump == null || !beforePump.matches(sampledState)) {
              continue;
            }
            final sample = await probeStep(
              'pixels',
              () => readStableOwnedVideoPixels(sampledState, () {
                final current = session;
                return current == null || !identical(current, mountedSession)
                    ? null
                    : OwnedVideoSampleState(
                        current,
                        current.mediaRevision,
                        current.stopped,
                      );
              }, () => _ownedPixels(boundary)),
            );
            if (sample == null) continue;
            if (sampledState.stopped) {
              if (sample.readable) {
                expect(
                  sample.cleared,
                  isTrue,
                  reason: 'Stopped view must clear pixels',
                );
                stoppedSamples++;
                stoppedSampleTimes.add(elapsed.elapsedMilliseconds);
              }
            } else if (sample.ownedPattern &&
                sample.marker != null &&
                revisions[sampledState.revision]?['firstFrame'] == true) {
              final revision = sampledState.revision;
              revisions.putIfAbsent(revision, () => {})['ownedPattern'] = true;
              markers.putIfAbsent(revision, () => {}).add(sample.marker!);
              if (previousMarker.containsKey(revision) &&
                  previousMarker[revision] != sample.marker) {
                markerTransitions.update(
                  revision,
                  (n) => n + 1,
                  ifAbsent: () => 1,
                );
              }
              previousMarker[revision] = sample.marker!;
            }
          }
        }
        Map<String, dynamic>? command;
        if (commandFile != null && await commandFile.exists()) {
          try {
            final text = await commandFile.readAsString();
            if (text.length <= 512) {
              command = jsonDecode(text) as Map<String, dynamic>;
            }
          } on FormatException {
            /* A concurrent file replacement is retried. */
          } on FileSystemException {
            /* The local writer may be replacing it. */
          }
        }
        if (console &&
            session?.stopped == true &&
            !validated &&
            stoppedSamples >= 3) {
          command = {'sequence': sequence + 1, 'action': 'check'};
        } else if (console &&
            completedRounds.length == roundLimit &&
            validated &&
            connection!.isClosed) {
          command = {'sequence': sequence + 1, 'action': 'finish'};
        }
        if (command != null &&
            command['sequence'] is int &&
            (command['sequence'] as int) > sequence &&
            session != null) {
          sequence = command['sequence'] as int;
          final action = command['action'];
          probePhase = 'command_$action';
          phaseSinceMillis = elapsed.elapsedMilliseconds;
          try {
            switch (action) {
              case 'abort':
                throw StateError('orchestration_aborted');
              case 'pause':
                await session!.pause().timeout(const Duration(seconds: 35));
                expect(budget.activeCount, 1);
                break;
              case 'resume':
                await session!.resume().timeout(const Duration(seconds: 35));
                expect(budget.activeCount, 1);
                break;
              case 'stop':
                await session!.stop().timeout(const Duration(seconds: 35));
                expect(budget.activeCount, 0);
                await connection!.grant!.checkValidity();
                break;
              case 'start':
                expect(validated, isTrue);
                expect(round, lessThan(roundLimit));
                expect(budget.activeCount, 0);
                await subscription!.cancel();
                await link!
                    .start(
                      SessionOperation.cast,
                      'dual-${Random.secure().nextInt(1 << 30)}',
                    )
                    .timeout(const Duration(seconds: 35));
                break;
              case 'check':
                // stopped gates new work before asynchronous native cleanup.
                // Join that cleanup before judging the released budget.
                await session!.stop().timeout(const Duration(seconds: 35));
                expect(failures, isEmpty);
                expect(session!.stopped, isTrue);
                expect(budget.activeCount, 0);
                expect(counts['paused'], greaterThanOrEqualTo(1));
                for (final revision in [0, 1]) {
                  expect(revisions[revision]?['firstFrame'], true);
                  expect(revisions[revision]?['path'], 'direct');
                  if (!sends) {
                    expect(revisions[revision]?['ownedPattern'], true);
                    expect(markers[revision], containsAll([true, false]));
                  }
                }
                expect(sourceQueries, sends ? greaterThanOrEqualTo(1) : 0);
                await connection!.grant!.checkValidity();
                expect(failures, isEmpty);
                validated = true;
                completedRounds.add({
                  'round': round,
                  'counts': counts,
                  'revisions': {
                    for (final e in revisions.entries) '${e.key}': e.value,
                  },
                  'markers': {
                    for (final e in markers.entries)
                      '${e.key}': e.value.toList(),
                  },
                  'markerTransitions': {
                    for (final e in markerTransitions.entries)
                      '${e.key}': e.value,
                  },
                  'budgetAfterStop': budget.activeCount,
                  'stoppedSamplesAtCheck': stoppedSamples,
                });
                break;
              case 'finish':
                expect(failures, isEmpty);
                expect(validated, isTrue);
                expect(completedRounds.length, roundLimit);
                checksDone = true;
                break;
              default:
                throw StateError('unknown_local_command');
            }
            ack = sequence;
          } catch (error) {
            commandError = error.runtimeType.toString();
            await publish(failure: 'command_failed');
            rethrow;
          }
          await publish();
        }
        if (elapsed.elapsedMilliseconds - lastReport >= 500) {
          lastReport = elapsed.elapsedMilliseconds;
          await publish();
        }
      }
      expect(checksDone, isTrue, reason: 'Dual-device orchestration deadline');
    } catch (error) {
      await publish(failure: error.runtimeType.toString());
      rethrow;
    } finally {
      heartbeat?.cancel();
      probePhase = 'cleanup';
      phaseSinceMillis = elapsed.elapsedMilliseconds;
      final cleanupFailures = <String>[];
      Future<void> clean(String name, Future<void> Function() action) async {
        try {
          await action().timeout(const Duration(seconds: 35));
        } catch (_) {
          cleanupFailures.add(name);
        }
      }

      try {
        await clean('media', () async => link?.close());
        await clean('subscription', () async => subscription?.cancel());
        if (connection != null) {
          connection!.close('probe_done');
          await clean('connection', () => connection!.whenTransportClosed);
        }
        await clean('host', () async => host?.close());
        await clean('engine', engine.dispose);
        if (cleanupFailures.isNotEmpty) {
          throw StateError('cleanup_incomplete');
        }
        passed = checksDone && failureCode == null && failures.isEmpty;
        if (checksDone && failures.isNotEmpty) {
          throw StateError('late_media_failure');
        }
      } catch (error) {
        await publish(failure: 'cleanup_${error.runtimeType}');
        rethrow;
      } finally {
        await publish();
        if (readyFile != null && await readyFile.exists()) {
          await readyFile.delete();
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 14)));
}

Future<void> _atomicJson(File target, Map<String, Object?> value) async {
  await writeAtomicProbeRecord(target, value);
}

// Verify the actual displayed texture. The four colors identify the generated
// owned window; its white/black moving marker establishes changing pixels.
// No screenshot, source name, address, code or key enters the report.
Future<OwnedVideoPixels> _ownedPixels(RenderRepaintBoundary boundary) async {
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return inspectOwnedVideoPixels(pixels, image.width, image.height);
  } finally {
    image.dispose();
  }
}
