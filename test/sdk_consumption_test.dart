import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:share_hub_open/platform/client_platform.dart';
import 'package:share_hub_open/ui/client_app.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/remote/remote_media.dart';
import 'package:share_hub_open/features/remote/remote_session_controller.dart';

import 'connection_controller_test.dart' show FakeConnectionPlatform;
import 'fakes.dart';

class _Provider extends FakePreviewEngine implements RemoteMediaProvider {
  _Provider(this.remoteMedia);
  @override
  final RemoteMediaFactory remoteMedia;
}

class _Factory implements RemoteMediaFactory {
  _Factory(this.capabilities);
  @override
  final MediaCapabilities capabilities;
  int creates = 0;
  SessionTransport? seenTransport;
  MediaSessionBudget? seenBudget;
  Future<CaptureSource> Function()? seenResolver;
  Future<VideoRecoveryAdmission> Function(
    SessionAuthorization,
    VideoRecoveryRequest,
  )?
  seenRecovery;
  void Function(RemoteVideoSession)? seenSession;
  void Function(String, String)? seenFailure;
  final link = _Link();
  @override
  RemoteMediaLink createLink({
    required SessionTransport transport,
    required MediaSessionBudget budget,
    required Future<CaptureSource> Function() resolveSource,
    required void Function(RemoteVideoSession) onSession,
    required void Function(String, String) onFailure,
    Future<VideoRecoveryAdmission> Function(
      SessionAuthorization,
      VideoRecoveryRequest,
    )?
    authorizeRecovery,
  }) {
    creates++;
    seenTransport = transport;
    seenBudget = budget;
    seenResolver = resolveSource;
    seenRecovery = authorizeRecovery;
    seenSession = onSession;
    seenFailure = onFailure;
    return link;
  }
}

class _Link implements RemoteMediaLink {
  int closed = 0;
  final starts = <(SessionOperation, String, VideoRecoveryRequest?)>[];
  @override
  Future<RemoteVideoSession> start(
    SessionOperation operation,
    String id, {
    VideoRecoveryRequest? recovery,
  }) async {
    starts.add((operation, id, recovery));
    throw const SessionFailure('test_no_native_media');
  }

  @override
  Future<void> close() async {
    closed++;
  }
}

class _Transport implements SessionTransport {
  void Function(VerifiedSessionMessage)? request;
  int detached = 0;
  final sent = <SessionAuthorization>[];
  final bodies = <String>[];
  Completer<void>? sendGate;
  @override
  void attachReceiver({
    required void Function(VerifiedSessionMessage) onRequest,
    required SessionAuthorization? Function(String) resolveSession,
    required void Function(VerifiedSessionSignal) onSignal,
  }) {
    request = onRequest;
  }

  @override
  void detachReceiver() {
    request = null;
    detached++;
  }

  @override
  Future<LocalSessionRequest> createRequest(
    SessionOperation operation,
    String id,
    String body,
  ) => throw StateError('must not create a request');
  @override
  Future<void> sendRequest(LocalSessionRequest request) =>
      throw StateError('must not start media');
  @override
  Future<void> sendSignal(
    SessionAuthorization authorization,
    String body,
  ) async {
    sent.add(authorization);
    bodies.add(body);
    await sendGate?.future;
  }
}

Future<(GrantEndpoint, GrantEndpoint)> _pair() async {
  final binding = GrantBinding(
    id: List.filled(32, 1),
    initiatorKey: List.filled(32, 2),
    receiverKey: List.filled(32, 3),
  );
  GrantEndpoint endpoint(GrantRole role) =>
      GrantEndpoint.fromAuthenticatedPairing(
        binding: binding,
        role: role,
        establishedMicros: 0,
        recoverySecret: List.filled(32, 4),
        clock: () async => 0,
        onInvalidated: () {},
      );
  final a = endpoint(GrantRole.initiator), b = endpoint(GrantRole.receiver);
  await b.acceptResume(
    await a.finishResume(await b.answerResume(await a.beginResume())),
  );
  return (a, b);
}

void main() {
  for (final entry in <String, MediaCapabilities?>{
    'legacy preview': null,
    'cast only': MediaCapabilities(
      protocolVersion: sessionProtocolVersion,
      operations: {SessionOperation.cast},
      maxVideoSessions: 1,
    ),
    'zero capacity': MediaCapabilities(
      protocolVersion: sessionProtocolVersion,
      operations: {SessionOperation.watch, SessionOperation.cast},
      maxVideoSessions: 0,
    ),
    'wrong protocol': MediaCapabilities(
      protocolVersion: 99,
      operations: {SessionOperation.watch, SessionOperation.cast},
      maxVideoSessions: 1,
    ),
  }.entries) {
    testWidgets(
      'device panel reflects ${entry.key} without disabled future entries',
      (tester) async {
        tester.view.physicalSize = const Size(1180, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final platform = FakePlatform();
        final engine = entry.value == null
            ? FakePreviewEngine()
            : _Provider(_Factory(entry.value!));
        await tester.pumpWidget(
          ShareHubApp(
            platform: platform,
            previewEngine: engine,
            targetPlatform: TargetPlatform.macOS,
          ),
        );
        await tester.pumpAndSettle();
        platform.events.add(
          const DiscoverySnapshot(
            state: 'running',
            devices: [
              NearbyDevice(
                'peer',
                '远端电脑',
                'macos',
                host: 'test.local',
                port: 1234,
                publicKey: 'peer-key',
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        final node = find.byKey(const ValueKey('device-peer-key'));
        await tester.ensureVisible(node);
        await tester.tap(node);
        await tester.pumpAndSettle();
        expect(find.text('连接并观看'), findsNothing);
        if (entry.key == 'cast only') {
          expect(find.text('连接并投屏'), findsOneWidget);
          expect(find.text('本构建未提供观看或投屏能力。'), findsNothing);
        } else {
          expect(find.text('连接并投屏'), findsNothing);
          expect(find.text('本构建未提供观看或投屏能力。'), findsOneWidget);
        }
        expect(find.textContaining('未开放'), findsNothing);
        expect(engine.sourceCalls, 0);
        expect(engine.starts, 0);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await platform.events.close();
      },
    );
  }

  test(
    'legacy preview does not infer remote from null unavailableReason',
    () async {
      final preview = FakePreviewEngine();
      expect(preview.unavailableReason, isNull);
      final factory = remotePicturesFor(preview);
      expect(factory, isA<PreviewOnlyPictureFactory>());
      expect(factory.capabilities.operations, isEmpty);
      expect(factory.capabilities.maxVideoSessions, 0);
      expect(capabilitiesOf(preview).operations, isEmpty);
      var firstFrame = false;
      await preview.start(
        const CaptureSource('local', 'Local'),
        onEnded: () {},
        onFirstFrame: () => firstFrame = true,
      );
      expect(firstFrame, isFalse);
      preview.firstFrame!();
      expect(firstFrame, isTrue);
      await preview.dispose();
    },
  );

  test('public provider is consumed without constructing a link at lookup', () {
    final api = _Factory(
      MediaCapabilities(
        protocolVersion: sessionProtocolVersion,
        operations: {SessionOperation.cast},
        maxVideoSessions: 1,
      ),
    );
    final preview = _Provider(api);
    final factory = remotePicturesFor(preview);
    expect(factory, isA<ApiRemotePictureFactory>());
    expect(factory.capabilities.operations, {SessionOperation.cast});
    expect(capabilitiesOf(preview).operations, {SessionOperation.cast});
    expect(api.creates, 0);
  });

  test(
    'public adapter forwards verified dependencies and recovery unchanged',
    () async {
      final api = _Factory(
        MediaCapabilities(
          protocolVersion: sessionProtocolVersion,
          operations: {SessionOperation.cast},
          maxVideoSessions: 1,
        ),
      );
      final factory =
          remotePicturesFor(_Provider(api)) as RecoverableRemotePictureFactory;
      final transport = _Transport();
      final budget = MediaSessionBudget(
        api.capabilities,
        grants: GrantRegistry(),
      );
      Future<CaptureSource> resolver() =>
          throw StateError('must not enumerate yet');
      Future<VideoRecoveryAdmission> recover(
        SessionAuthorization a,
        VideoRecoveryRequest r,
      ) => throw StateError('must not admit yet');
      String? failure;
      final link = factory.createRecoverable(
        transport: transport,
        budget: budget,
        resolveSource: resolver,
        authorizeRecovery: recover,
        onSession: (_) {},
        onFailure: (_, code) => failure = code,
      );
      expect(api.creates, 1);
      expect(api.seenTransport, same(transport));
      expect(api.seenBudget, same(budget));
      expect(api.seenResolver, same(resolver));
      expect(api.seenRecovery, same(recover));
      api.seenFailure!('session', 'unavailable');
      expect(failure, 'unavailable');
      await expectLater(
        link.start(SessionOperation.cast, 'new'),
        throwsA(isA<SessionFailure>()),
      );
      expect(api.link.starts.single, (SessionOperation.cast, 'new', null));
      final recovery = VideoRecoveryRequest(
        previousSessionId: 'old',
        previousTransportGeneration: 1,
        previousRevision: 2,
        paused: true,
      );
      await expectLater(
        (link as RecoverableRemotePictureLink).startRecovered(
          SessionOperation.cast,
          'recovered',
          recovery,
        ),
        throwsA(isA<SessionFailure>()),
      );
      expect(api.link.starts.last, (
        SessionOperation.cast,
        'recovered',
        recovery,
      ));
      await link.close();
      expect(api.link.closed, 1);
    },
  );

  test(
    'zero capacity or wrong protocol cannot expose remote actions',
    () async {
      for (final capabilities in [
        MediaCapabilities(
          protocolVersion: sessionProtocolVersion,
          operations: {SessionOperation.watch},
          maxVideoSessions: 0,
        ),
        MediaCapabilities(
          protocolVersion: 99,
          operations: {SessionOperation.watch},
          maxVideoSessions: 1,
        ),
        MediaCapabilities.previewOnly(),
      ]) {
        final connections = ConnectionController(FakeConnectionPlatform());
        final api = _Factory(capabilities);
        final preview = _Provider(api);
        final selected = remotePicturesFor(preview);
        expect(selected, isA<PreviewOnlyPictureFactory>());
        expect(api.creates, 0);
        final remote = RemoteSessionController(
          connections: connections,
          platform: FakePlatform(),
          factory: selected,
          listSources: preview.sources,
        );
        expect(remote.offeredOperations, isEmpty);
        await remote.shutdown();
        remote.dispose();
        connections.dispose();
      }
    },
  );

  test('legacy link rejects local starts and authenticated incoming video without allocation', () async {
    final (a, b) = await _pair();
    final transport = _Transport();
    final budget = MediaSessionBudget(
      MediaCapabilities.previewOnly(),
      grants: GrantRegistry()..register(b),
    );
    final link = const PreviewOnlyPictureFactory().create(
      transport: transport,
      budget: budget,
      resolveSource: () => throw StateError('no capture'),
      onSession: (_) => fail('no session'),
      onFailure: (_, _) {},
    );
    await expectLater(
      link.start(SessionOperation.watch, 'local'),
      throwsA(
        isA<SessionFailure>().having(
          (e) => e.code,
          'code',
          'capability_unavailable',
        ),
      ),
    );
    final request = await b.open(
      await a.seal(
        SessionOperation.watch,
        'incoming',
        VideoSessionRequest.body,
      ),
    );
    transport.request!(request);
    await Future<void>.delayed(Duration.zero);
    expect(transport.sent, [same(request)]);
    expect(transport.bodies, [
      const VideoSessionEnd(VideoEndReason.unavailable).encode(),
    ]);
    expect(budget.activeCount, 0);
    await link.close();
    expect(transport.detached, 1);
    await link.close();
    expect(transport.detached, 1);
    a.revoke();
    b.revoke();
  });

  test(
    'legacy refusal is bounded and close waits for actual pending sends',
    () async {
      final (a, b) = await _pair();
      final transport = _Transport()..sendGate = Completer<void>();
      final budget = MediaSessionBudget(
        MediaCapabilities.previewOnly(),
        grants: GrantRegistry()..register(b),
      );
      final link = const PreviewOnlyPictureFactory().create(
        transport: transport,
        budget: budget,
        resolveSource: () => throw StateError('no capture'),
        onSession: (_) => fail('no session'),
        onFailure: (_, _) {},
      );
      for (var i = 0; i < 12; i++) {
        transport.request!(
          await b.open(
            await a.seal(
              SessionOperation.cast,
              'incoming-$i',
              VideoSessionRequest.body,
            ),
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(transport.sent.length, 8);
      var closed = false;
      final closing = link.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(transport.request, isNull);
      transport.sendGate!.complete();
      await closing;
      expect(closed, isTrue);
      expect(budget.activeCount, 0);
      a.revoke();
      b.revoke();
    },
  );

  test(
    'foreign registry and revoked incoming requests receive no reply',
    () async {
      final (a, b) = await _pair();
      final transport = _Transport();
      final registry = GrantRegistry();
      final budget = MediaSessionBudget(
        MediaCapabilities.previewOnly(),
        grants: registry,
      );
      final link = const PreviewOnlyPictureFactory().create(
        transport: transport,
        budget: budget,
        resolveSource: () => throw StateError('no capture'),
        onSession: (_) => fail('no session'),
        onFailure: (_, _) {},
      );
      final request = await b.open(
        await a.seal(
          SessionOperation.watch,
          'incoming',
          VideoSessionRequest.body,
        ),
      );
      transport.request!(request);
      await Future<void>.delayed(Duration.zero);
      expect(transport.sent, isEmpty);
      registry.register(b);
      b.revoke();
      transport.request!(request);
      await Future<void>.delayed(Duration.zero);
      expect(transport.sent, isEmpty);
      await link.close();
      a.revoke();
    },
  );
}
