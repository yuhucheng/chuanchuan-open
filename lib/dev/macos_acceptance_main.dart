import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';
import 'package:share_hub_open/features/preview/preview_controller.dart';
import 'package:share_hub_open/platform/client_platform.dart';

/// Development-only macOS acceptance entry.
///
/// This file is never part of the shipped client: it is built with an explicit
/// `--target lib/dev/macos_acceptance_main.dart` and must be launched through
/// LaunchServices (`open`), because a sandboxed app cannot initialise its App
/// Sandbox container when it is spawned directly by another sandboxed process.
///
/// Modes, selected by an `acceptance-mode` file in the app container:
/// * `full` (default) — permissions, real sources, primary selection, two real
///   captures and the shipped controller happy path.
/// * `revocation` — starts a real capture through the shipped controller, then
///   waits for an externally triggered permission withdrawal.
/// * `lifecycle` — asserts the preview surface is released on stop, then runs
///   20 real start/stop cycles.
/// * `source-loss|<needle>,<needle>` — captures the first window source whose
///   name contains a needle, then waits for an external close of that source.
///
/// The engine view is mounted exactly like the shipped client does. The native
/// bridge only reports `firstFrame` from the first `copyPixelBuffer()` call, so
/// a live Flutter render tree owning the texture is required for a real first
/// frame to arrive.
final GlobalKey _hostKey = GlobalKey();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final engine = createPreviewEngine();
  runApp(MacosAcceptanceHost(engine: engine, hostKey: _hostKey));
  final home = Platform.environment['HOME']!;
  final mode = _readMode(home);
  final report = switch (mode.split('|').first) {
    'revocation' => await _revocationRun(engine, home),
    'lifecycle' => await _lifecycleRun(engine),
    'source-loss' => await _sourceLossRun(engine, home, mode),
    _ => await _runAcceptance(engine),
  };
  await _writeReport(home, report);
  await Future<void>.delayed(const Duration(seconds: 1));
  exit(0);
}

String _readMode(String home) {
  try {
    return File('$home/acceptance-mode').readAsStringSync().trim();
  } catch (_) {
    return 'full';
  }
}

Future<void> _writeReport(String home, Map<String, dynamic> report) async {
  // Written from a single place so a watchdog expiry still leaves evidence.
  await File('$home/macos-acceptance.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln(jsonEncode(report));
}

/// Minimal render host: a real window with the real engine texture mounted.
class MacosAcceptanceHost extends StatelessWidget {
  const MacosAcceptanceHost({
    super.key,
    required this.engine,
    required this.hostKey,
  });

  final PreviewEngine engine;
  final GlobalKey hostKey;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: KeyedSubtree(
      key: hostKey,
      child: SizedBox.expand(child: engine.view),
    ),
  );
}

/// Whether the preview `Texture` widget is currently mounted. The engine only
/// attaches it while a session owns a live texture, so its presence/absence is
/// the Dart-visible half of "the preview surface is released".
bool _surfaceMounted() {
  final context = _hostKey.currentContext;
  if (context is! Element) return false;
  var found = false;
  void visit(Element element) {
    if (found) return;
    if (element.widget is Texture) {
      found = true;
      return;
    }
    element.visitChildren(visit);
  }

  context.visitChildren(visit);
  return found;
}

Future<Map<String, dynamic>> _awaitSurface(bool present, Duration limit) async {
  final start = DateTime.now();
  final until = start.add(limit);
  while (DateTime.now().isBefore(until)) {
    if (_surfaceMounted() == present) {
      return {
        'ok': true,
        'present': present,
        'elapsedMs': DateTime.now().difference(start).inMilliseconds,
      };
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return {
    'ok': false,
    'present': present,
    'mounted': _surfaceMounted(),
    'elapsedMs': DateTime.now().difference(start).inMilliseconds,
  };
}

Future<bool> _waitUntil(bool Function() done, Duration limit) async {
  final until = DateTime.now().add(limit);
  while (!done() && DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return done();
}

Future<bool> _permissionSnapshot(MethodChannelClientPlatform platform) async {
  try {
    return (await platform.permissions()).screenRecording;
  } catch (_) {
    return false;
  }
}

Future<Map<String, dynamic>> _runAcceptance(PreviewEngine engine) async {
  // Let the first frame paint so the texture widget is registered.
  await Future<void>.delayed(const Duration(milliseconds: 800));
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'mode': 'full',
    'startedAt': DateTime.now().toIso8601String(),
  };

  final platform = MethodChannelClientPlatform();
  var permissionGranted = false;
  try {
    final device = await platform.loadDevice();
    report['device'] = {'id': device.id, 'name': device.name};
    report['deviceStable'] = (await platform.loadDevice()).id == device.id;
  } catch (error) {
    report['deviceError'] = error.toString();
  }
  try {
    final permissions = await platform.permissions();
    permissionGranted = permissions.screenRecording;
    report['permissions'] = {
      'screenRecording': permissions.screenRecording,
      'accessibility': permissions.accessibility,
    };
  } catch (error) {
    report['permissionError'] = error.toString();
  }

  report['unavailableReason'] = engine.unavailableReason;
  try {
    final sources = await engine.sources();
    final primary = sources.where((item) => item.isPrimary).toList();
    report['sources'] = {
      'total': sources.length,
      'screens': sources
          .where((item) => item.type == CaptureSourceType.screen)
          .length,
      'windows': sources
          .where((item) => item.type == CaptureSourceType.window)
          .length,
      'primaryNames': primary.map((item) => item.name).toList(),
      'sample': sources
          .take(5)
          .map(
            (item) => {
              'name': item.name,
              'type': item.type.name,
              'isPrimary': item.isPrimary,
            },
          )
          .toList(),
    };
    if (primary.length == 1) {
      report['primarySelection'] = primary.single.name;
      report['firstRun'] = await _capture(engine, primary.single);
      report['resumeRun'] = await _capture(engine, primary.single);
    } else {
      report['primarySelection'] = 'not-unique:${primary.length}';
    }
  } catch (error) {
    report['engineError'] = error.toString();
  }
  report['controller'] = permissionGranted
      ? await _controllerRun(platform, engine)
      : 'skipped: screen recording not granted, the shipped controller would '
            'raise the system request instead of starting capture';
  report['finishedAt'] = DateTime.now().toIso8601String();
  return report;
}

/// Exercises the shipped orchestration instead of the bare engine: default
/// primary selection, start, stop and resume, with the same permission
/// polling the client uses while a capture is active.
Future<Map<String, dynamic>> _controllerRun(
  MethodChannelClientPlatform platform,
  PreviewEngine engine,
) async {
  final controller = PreviewController(platform, engine);
  final result = <String, dynamic>{};

  try {
    await controller.loadSources();
    result['loadSources'] = {
      'sources': controller.sources.length,
      'selected': controller.selected?.name,
      'error': controller.error,
    };
    await controller.start();
    await _waitUntil(
      () => controller.active && controller.firstFrame,
      const Duration(seconds: 12),
    );
    result['start'] = {
      'active': controller.active,
      'firstFrame': controller.firstFrame,
      'selected': controller.selected?.name,
      'error': controller.error,
    };
    await controller.stop();
    result['stop'] = {
      'active': controller.active,
      'cleanupFailed': controller.cleanupFailed,
    };
    await controller.start();
    await _waitUntil(
      () => controller.active && controller.firstFrame,
      const Duration(seconds: 12),
    );
    result['resume'] = {
      'active': controller.active,
      'firstFrame': controller.firstFrame,
      'error': controller.error,
    };
    await controller.stop();
    result['stopAfterResume'] = {
      'active': controller.active,
      'cleanupFailed': controller.cleanupFailed,
    };
  } catch (error) {
    result['error'] = error.toString();
  }
  controller.dispose();
  return result;
}

/// `full` mode also verifies the primary screen end to end.
Future<Map<String, dynamic>> _capture(
  PreviewEngine engine,
  CaptureSource source,
) async {
  var firstFrame = false;
  var ended = false;
  String? startError;
  final started = DateTime.now();
  try {
    await engine.start(
      source,
      onEnded: () => ended = true,
      onFirstFrame: () => firstFrame = true,
    );
    await _waitUntil(() => firstFrame, const Duration(seconds: 12));
  } catch (error) {
    startError = error.toString();
  }
  final elapsed = DateTime.now().difference(started).inMilliseconds;
  var stopFailed = false;
  try {
    await engine.stop();
  } catch (_) {
    stopFailed = true;
  }
  return {
    'source': source.name,
    'firstFrame': firstFrame,
    'endedDuringCapture': ended,
    'elapsedMs': elapsed,
    'startError': startError,
    'stopFailed': stopFailed,
  };
}

/// Surface release on stop plus 20 real start/stop cycles.
Future<Map<String, dynamic>> _lifecycleRun(PreviewEngine engine) async {
  await Future<void>.delayed(const Duration(milliseconds: 800));
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'mode': 'lifecycle',
    'startedAt': DateTime.now().toIso8601String(),
  };
  await Future.any([
    _lifecycleScenario(engine, report),
    Future<void>.delayed(const Duration(seconds: 150), () {
      report['watchdogExpired'] = true;
    }),
  ]);
  report['finishedAt'] = DateTime.now().toIso8601String();
  return report;
}

Future<void> _lifecycleScenario(
  PreviewEngine engine,
  Map<String, dynamic> report,
) async {
  final platform = MethodChannelClientPlatform();
  report['permissions'] = await _permissionSnapshot(platform);
  final sources = await engine.sources();
  final primary = sources.where((item) => item.isPrimary).toList();
  report['sourceCount'] = sources.length;
  report['primary'] = primary.map((item) => item.name).toList();
  if (primary.length != 1) {
    report['outcome'] = 'no-unique-primary:${primary.length}';
    return;
  }
  final source = primary.single;

  // 1. A stopped capture must leave no preview surface behind.
  final release = <String, dynamic>{};
  release['surfaceBeforeStart'] = _surfaceMounted();
  try {
    await engine.start(source, onEnded: () {}, onFirstFrame: () {});
    release['surfaceWhileActive'] = await _awaitSurface(
      true,
      const Duration(seconds: 8),
    );
  } catch (error) {
    release['startError'] = error.toString();
    report['stopReleasesSurface'] = release;
    return;
  }
  try {
    await engine.stop();
    release['stopError'] = null;
  } catch (error) {
    release['stopError'] = error.toString();
  }
  release['surfaceAfterStop'] = await _awaitSurface(
    false,
    const Duration(seconds: 5),
  );
  report['stopReleasesSurface'] = release;

  // 2. Twenty real start/stop cycles on the same source.
  final cycles = <Map<String, dynamic>>[];
  final cyclesStarted = DateTime.now();
  for (var index = 1; index <= 20; index++) {
    var firstFrame = false;
    String? error;
    final started = DateTime.now();
    try {
      await engine.start(
        source,
        onEnded: () {},
        onFirstFrame: () => firstFrame = true,
      );
      await _waitUntil(() => firstFrame, const Duration(seconds: 10));
    } catch (failure) {
      error = failure.toString();
    }
    final firstFrameMs = DateTime.now().difference(started).inMilliseconds;
    try {
      await engine.stop();
    } catch (failure) {
      error = '${error ?? ''} stop:${failure.toString()}';
    }
    cycles.add({
      'cycle': index,
      'firstFrame': firstFrame,
      'firstFrameMs': firstFrameMs,
      'cycleMs': DateTime.now().difference(started).inMilliseconds,
      'error': ?error,
    });
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  report['cycles'] = cycles;
  report['cyclesElapsedMs'] = DateTime.now()
      .difference(cyclesStarted)
      .inMilliseconds;
  report['cyclesWithoutFirstFrame'] = cycles
      .where((item) => item['firstFrame'] != true)
      .length;
  report['cycleErrors'] = cycles
      .where((item) => item.containsKey('error'))
      .length;
  report['surfaceAfterCycles'] = await _awaitSurface(
    false,
    const Duration(seconds: 5),
  );

  // 3. The controller must recover right after the cycles.
  final controller = PreviewController(platform, engine);
  try {
    await controller.loadSources();
    await controller.start();
    final started = await _waitUntil(
      () => controller.active && controller.firstFrame,
      const Duration(seconds: 12),
    );
    report['recovery'] = {
      'started': started,
      'active': controller.active,
      'firstFrame': controller.firstFrame,
      'selected': controller.selected?.name,
      'error': controller.error,
    };
    await controller.stop();
    report['recovery']['cleanupFailed'] = controller.cleanupFailed;
  } catch (error) {
    report['recovery'] = {'error': error.toString()};
  }
  controller.dispose();
}

/// Captures a window source and waits for an external close of that window.
Future<Map<String, dynamic>> _sourceLossRun(
  PreviewEngine engine,
  String home,
  String mode,
) async {
  await Future<void>.delayed(const Duration(milliseconds: 800));
  final needles = mode
      .split('|')
      .skip(1)
      .join('|')
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'mode': 'source-loss',
    'needles': needles,
    'startedAt': DateTime.now().toIso8601String(),
  };
  await Future.any([
    _sourceLossScenario(engine, home, report, needles),
    Future<void>.delayed(const Duration(seconds: 150), () {
      report['watchdogExpired'] = true;
    }),
  ]);
  report['finishedAt'] = DateTime.now().toIso8601String();
  return report;
}

Future<void> _sourceLossScenario(
  PreviewEngine engine,
  String home,
  Map<String, dynamic> report,
  List<String> needles,
) async {
  final platform = MethodChannelClientPlatform();
  report['permissions'] = await _permissionSnapshot(platform);
  final sources = await engine.sources();
  final windows = sources
      .where((item) => item.type == CaptureSourceType.window)
      .toList();
  report['windowSources'] = windows.map((item) => item.name).toList();
  CaptureSource? target;
  String? matched;
  for (final needle in needles) {
    for (final window in windows) {
      if (window.name.contains(needle)) {
        target = window;
        matched = needle;
        break;
      }
    }
    if (target != null) break;
  }
  if (target == null) {
    report['outcome'] = 'no-matching-window';
    return;
  }
  report['matchedNeedle'] = matched;
  report['selected'] = target.name;

  final controller = PreviewController(platform, engine);
  final startedAt = DateTime.now();
  final transitions = <Map<String, dynamic>>[];
  String? last;
  controller.addListener(() {
    final signature = [
      controller.active,
      controller.stopping,
      controller.firstFrame,
      controller.cleanupFailed,
      controller.error,
    ].join('|');
    if (signature == last) return;
    last = signature;
    transitions.add({
      'ms': DateTime.now().difference(startedAt).inMilliseconds,
      'active': controller.active,
      'stopping': controller.stopping,
      'firstFrame': controller.firstFrame,
      'cleanupFailed': controller.cleanupFailed,
      'error': controller.error,
    });
  });

  final readiness = File('$home/acceptance-ready.json');
  try {
    controller.select(target);
    await controller.start();
    final live = await _waitUntil(
      () => controller.active && controller.firstFrame,
      const Duration(seconds: 20),
    );
    report['captureStarted'] = {
      'live': live,
      'active': controller.active,
      'firstFrame': controller.firstFrame,
      'error': controller.error,
      'elapsedMs': DateTime.now().difference(startedAt).inMilliseconds,
    };
    if (!live) {
      report['outcome'] = 'no-live-capture-to-close';
      controller.dispose();
      return;
    }
    await readiness.writeAsString(
      jsonEncode({
        'phase': 'capturing',
        'at': DateTime.now().toIso8601String(),
        'selected': controller.selected?.name,
      }),
    );
    final readyAt = DateTime.now();
    final ended = await _waitUntil(
      () => !controller.active,
      const Duration(seconds: 90),
    );
    report['sourceLoss'] = {
      'ended': ended,
      'msAfterReady': DateTime.now().difference(readyAt).inMilliseconds,
      'error': controller.error,
      'firstFrame': controller.firstFrame,
      'cleanupFailed': controller.cleanupFailed,
    };
    report['endedPath'] = switch (controller.error) {
      '屏幕预览已被系统结束。' => 'native-ended-event',
      '屏幕录制权限已关闭，预览已停止。' => 'client-permission-poll',
      '无法检查屏幕录制权限，预览已停止。' => 'client-poll-error',
      _ => 'unclassified',
    };

    // After the chosen source disappears the client must refuse to fall back
    // to full screen and must keep working once a valid source is re-selected.
    await controller.loadSources();
    await controller.start();
    report['noFallbackAfterLoss'] = {
      'active': controller.active,
      'firstFrame': controller.firstFrame,
      'selected': controller.selected?.name,
      'error': controller.error,
    };
    final primary = controller.sources
        .where(
          (item) => item.type == CaptureSourceType.screen && item.isPrimary,
        )
        .toList();
    if (primary.length != 1) {
      report['recovery'] = 'no-unique-primary-after-loss:${primary.length}';
    } else {
      controller.select(primary.single);
      await controller.start();
      final recovered = await _waitUntil(
        () => controller.active && controller.firstFrame,
        const Duration(seconds: 15),
      );
      report['recovery'] = {
        'recovered': recovered,
        'active': controller.active,
        'firstFrame': controller.firstFrame,
        'selected': controller.selected?.name,
        'error': controller.error,
      };
      await controller.stop();
      report['recovery']['cleanupFailed'] = controller.cleanupFailed;
    }
  } catch (error) {
    report['error'] = error.toString();
  }
  report['transitions'] = transitions;
  controller.dispose();
  try {
    if (readiness.existsSync()) await readiness.delete();
  } catch (_) {
    // The runner clears it anyway; a leftover marker is not a failure.
  }
}

/// Real permission withdrawal during a live capture.
///
/// The scenario starts a genuine capture through the shipped controller, drops
/// an `acceptance-ready.json` marker, then waits for an outside actor to revoke
/// screen recording. Everything observed is recorded into [report] as it
/// happens, so a watchdog expiry still leaves partial evidence.
Future<Map<String, dynamic>> _revocationRun(
  PreviewEngine engine,
  String home,
) async {
  await Future<void>.delayed(const Duration(milliseconds: 800));
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'mode': 'revocation',
    'startedAt': DateTime.now().toIso8601String(),
  };
  await Future.any([
    _revocationScenario(engine, home, report),
    Future<void>.delayed(const Duration(seconds: 90), () {
      report['watchdogExpired'] = true;
    }),
  ]);
  report['finishedAt'] = DateTime.now().toIso8601String();
  return report;
}

Future<void> _revocationScenario(
  PreviewEngine engine,
  String home,
  Map<String, dynamic> report,
) async {
  final platform = MethodChannelClientPlatform();
  final controller = PreviewController(platform, engine);
  final startedAt = DateTime.now();
  final transitions = <Map<String, dynamic>>[];
  String? last;
  controller.addListener(() {
    final signature = [
      controller.active,
      controller.busy,
      controller.stopping,
      controller.firstFrame,
      controller.cleanupFailed,
      controller.error,
    ].join('|');
    if (signature == last) return;
    last = signature;
    transitions.add({
      'ms': DateTime.now().difference(startedAt).inMilliseconds,
      'active': controller.active,
      'stopping': controller.stopping,
      'firstFrame': controller.firstFrame,
      'cleanupFailed': controller.cleanupFailed,
      'error': controller.error,
    });
  });

  final readiness = File('$home/acceptance-ready.json');

  try {
    report['permissionsBefore'] = await _permissionSnapshot(platform);
    await controller.loadSources();
    report['loadSources'] = {
      'sources': controller.sources.length,
      'selected': controller.selected?.name,
      'error': controller.error,
    };
    await controller.start();
    await _waitUntil(
      () => controller.active && controller.firstFrame,
      const Duration(seconds: 20),
    );
    report['captureStarted'] = {
      'active': controller.active,
      'firstFrame': controller.firstFrame,
      'selected': controller.selected?.name,
      'error': controller.error,
      'elapsedMs': DateTime.now().difference(startedAt).inMilliseconds,
    };
    if (!controller.active || !controller.firstFrame) {
      report['outcome'] = 'no-live-capture-to-revoke';
      controller.dispose();
      return;
    }
    await readiness.writeAsString(
      jsonEncode({
        'phase': 'capturing',
        'at': DateTime.now().toIso8601String(),
        'selected': controller.selected?.name,
      }),
    );
    final readyAt = DateTime.now();

    // Sample the preflight value while the capture runs. The controller polls
    // the same value every 2 s and stops when it turns false.
    final samples = <Map<String, dynamic>>[];
    while (controller.active &&
        DateTime.now().difference(readyAt) < const Duration(seconds: 60)) {
      samples.add({
        'ms': DateTime.now().difference(readyAt).inMilliseconds,
        'screenRecording': await _permissionSnapshot(platform),
      });
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    report['permissionSamples'] = samples;
    report['revocation'] = {
      'detected': !controller.active,
      'msAfterReady': DateTime.now().difference(readyAt).inMilliseconds,
      'error': controller.error,
      'firstFrame': controller.firstFrame,
      'cleanupFailed': controller.cleanupFailed,
    };
    report['endedPath'] = switch (controller.error) {
      '屏幕预览已被系统结束。' => 'native-ended-event',
      '屏幕录制权限已关闭，预览已停止。' => 'client-permission-poll',
      '无法检查屏幕录制权限，预览已停止。' => 'client-poll-error',
      _ => 'unclassified',
    };

    // A repeated stop must stay idempotent and must not report a leak.
    await controller.stop();
    report['doubleStop'] = {
      'active': controller.active,
      'stopping': controller.stopping,
      'cleanupFailed': controller.cleanupFailed,
      'error': controller.error,
    };

    // Post-revocation refusal, through the native preflight only: no system
    // request is raised, so the run cannot stall on a permission prompt.
    try {
      final sources = await engine.sources();
      report['sourcesAfterRevocation'] = 'enumerated:${sources.length}';
    } catch (failure) {
      report['sourcesAfterRevocation'] = failure is PlatformException
          ? 'PlatformException(${failure.code})'
          : failure.toString();
    }
    report['permissionsAfter'] = await _permissionSnapshot(platform);
  } catch (error) {
    report['error'] = error.toString();
  }
  report['transitions'] = transitions;
  controller.dispose();
  try {
    if (readiness.existsSync()) await readiness.delete();
  } catch (_) {
    // The runner clears it anyway; a leftover marker is not a failure.
  }
}
