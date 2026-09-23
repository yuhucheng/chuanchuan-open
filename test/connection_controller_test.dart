import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';

class FakeConnectionPlatform implements ConnectionPlatform {
  final seed = Completer<DeviceIdentity>();
  final advertisements = <int?>[];
  Completer<void>? advertisingStarted;
  Completer<String?>? advertisementResult;
  int identityRequests = 0;
  @override
  Future<DeviceIdentity> identity() {
    identityRequests++;
    return seed.future;
  }

  @override
  Future<int> now() async => 1000;
  @override
  Future<String?> advertise(int? port, String? key) async {
    advertisements.add(port);
    if (port != null) {
      if (advertisingStarted case final started? when !started.isCompleted) {
        started.complete();
      }
      if (advertisementResult case final result?) return result.future;
    }
    return 'test.local';
  }
}

void main() {
  test(
    'auxiliary demand distinguishes outbound pairing from opening admission',
    () async {
      final platform = FakeConnectionPlatform();
      final controller = ConnectionController(platform);
      addTearDown(controller.dispose);
      final observed = <bool>[];
      controller.addListener(() => observed.add(controller.connecting));
      final opening = controller.open();
      expect(controller.busy, isTrue);
      expect(controller.connecting, isFalse);
      controller.cancel();
      platform.seed.complete(
        await DeviceIdentity.fromSeed(List.filled(32, 80)),
      );
      await opening;
      expect(observed, isNot(contains(true)));

      final outgoing = controller.connect('127.0.0.1', 12345, '123456');
      expect(controller.connecting, isTrue);
      controller.cancel();
      await outgoing;
      expect(controller.connecting, isFalse);
      expect(observed, contains(true));
      expect(observed.last, isFalse);
    },
  );

  test('client v2 grants bind both identities and off revokes before I/O', () async {
    final aPlatform = FakeConnectionPlatform();
    final bPlatform = FakeConnectionPlatform();
    final a = ConnectionController(aPlatform);
    final b = ConnectionController(bPlatform);
    addTearDown(() async {
      await a.disconnectAll();
      await b.disconnectAll();
      a.dispose();
      b.dispose();
    });
    final aIdentity = await DeviceIdentity.fromSeed(List.filled(32, 21));
    final bIdentity = await DeviceIdentity.fromSeed(List.filled(32, 22));
    aPlatform.seed.complete(aIdentity);
    bPlatform.seed.complete(bIdentity);
    await b.open();
    final port = bPlatform.advertisements.whereType<int>().last;
    final established = await a.connect(
      '127.0.0.1',
      port,
      b.code!,
      expectedPeerKey: bIdentity.encodedKey,
    );
    expect(established, same(a.sessions.single));
    expect(a.outgoingFor(bIdentity.encodedKey), same(established));
    expect(b.outgoingFor(aIdentity.encodedKey), isNull);
    expect(a.accepting, isFalse); // Admission off still permits outbound.
    expect(a.sessions.single.peerKey, bIdentity.encodedKey);
    expect(b.sessions.single.peerKey, aIdentity.encodedKey);
    expect(a.notice?.kind, ConnectionNoticeKind.status);
    expect(b.notice?.kind, ConnectionNoticeKind.status);
    expect(a.problem, isNull);
    expect(b.problem, isNull);
    final outgoing = a.sessions.single;
    final initiator = outgoing.grant!;
    final receiver = b.sessions.single.grant!;
    expect(initiator.binding.encodedId, receiver.binding.encodedId);
    expect(a.sessions.single.capabilities, isEmpty);
    // Initial grant activation was completed over the actual pairing socket.
    expect(initiator.phase, GrantPhase.active);
    expect(receiver.phase, GrantPhase.active);
    final permit = await receiver.open(
      await initiator.seal(SessionOperation.watch, 'contract-watch', ''),
    );
    await b.grants.verify(permit);
    await expectLater(a.grants.verify(permit), throwsA(isA<SessionFailure>()));
    final closing = b.disconnectAll();
    expect(receiver.phase, GrantPhase.revoked);
    await expectLater(b.grants.verify(permit), throwsA(isA<SessionFailure>()));
    await closing;
    expect(b.accepting, isFalse);
    expect(b.code, isNull);
    await outgoing.whenClosed.timeout(const Duration(seconds: 5));
    expect(initiator.phase, GrantPhase.revoked);
    // Reopening admission must mint a fresh context, never revive the old one.
    await b.open();
    expect(receiver.phase, GrantPhase.revoked);
    expect(b.code, matches(RegExp(r'^\d{6}$')));
  });

  test(
    'shutdown permanently rejects new authentication and advertisement',
    () async {
      final platform = FakeConnectionPlatform();
      final controller = ConnectionController(platform);
      final peerPlatform = FakeConnectionPlatform();
      final peer = ConnectionController(peerPlatform);
      addTearDown(() async {
        await peer.disconnectAll();
        controller.dispose();
        peer.dispose();
      });
      final peerIdentity = await DeviceIdentity.fromSeed(List.filled(32, 71));
      peerPlatform.seed.complete(peerIdentity);
      await peer.open();
      final port = peerPlatform.advertisements.whereType<int>().last;
      final code = peer.code!;

      await controller.shutdown();
      // No seed is supplied: admission must reject before requesting identity.
      await controller.open();
      expect(
        await controller.connect(
          '127.0.0.1',
          port,
          code,
          expectedPeerKey: peerIdentity.encodedKey,
        ),
        isNull,
      );
      // The ordinary disconnect action cannot reset a process-exit gate.
      await controller.disconnectAll();
      await controller.open();
      expect(platform.identityRequests, 0);
      expect(platform.advertisements, isEmpty);
      expect(controller.accepting, isFalse);
      expect(controller.sessions, isEmpty);
      expect(controller.busy, isFalse);
      expect(peer.sessions, isEmpty);
      expect(peer.code, code);
    },
  );

  test(
    'shutdown closes its real listener and cannot reopen admission',
    () async {
      final platform = FakeConnectionPlatform();
      final controller = ConnectionController(platform);
      final peerPlatform = FakeConnectionPlatform();
      final peer = ConnectionController(peerPlatform);
      addTearDown(() async {
        await peer.disconnectAll();
        controller.dispose();
        peer.dispose();
      });
      final identity = await DeviceIdentity.fromSeed(List.filled(32, 72));
      platform.seed.complete(identity);
      peerPlatform.seed.complete(
        await DeviceIdentity.fromSeed(List.filled(32, 73)),
      );
      await controller.open();
      final port = platform.advertisements.whereType<int>().last;
      final code = controller.code!;

      await controller.shutdown();
      final advertisements = platform.advertisements.toList();
      await controller.open();
      expect(platform.advertisements, advertisements);
      expect(controller.accepting, isFalse);
      expect(controller.code, isNull);
      expect(
        await peer.connect(
          '127.0.0.1',
          port,
          code,
          expectedPeerKey: identity.encodedKey,
        ),
        isNull,
      );
      expect(controller.sessions, isEmpty);
      expect(peer.sessions, isEmpty);
    },
  );

  for (final outgoing in [false, true]) {
    test(
      'shutdown cancels ${outgoing ? 'outgoing' : 'incoming'} admission waiting for identity',
      () async {
        final platform = FakeConnectionPlatform();
        final controller = ConnectionController(platform);
        final peerPlatform = FakeConnectionPlatform();
        final peer = ConnectionController(peerPlatform);
        addTearDown(() async {
          await peer.disconnectAll();
          controller.dispose();
          peer.dispose();
        });
        final peerIdentity = await DeviceIdentity.fromSeed(List.filled(32, 74));
        peerPlatform.seed.complete(peerIdentity);
        await peer.open();
        final code = peer.code!;
        final pending = outgoing
            ? controller
                  .connect(
                    '127.0.0.1',
                    peerPlatform.advertisements.whereType<int>().last,
                    code,
                    expectedPeerKey: peerIdentity.encodedKey,
                  )
                  .then<void>((_) {})
            : controller.open();
        expect(platform.identityRequests, 1);
        expect(controller.busy, isTrue);

        var shutdownFinished = false;
        final shutdown = controller.shutdown().then((_) {
          shutdownFinished = true;
        });
        await Future<void>.delayed(Duration.zero);
        expect(shutdownFinished, isFalse);
        platform.seed.complete(
          await DeviceIdentity.fromSeed(List.filled(32, 75)),
        );
        await pending;
        await shutdown;
        await controller.open();
        expect(platform.identityRequests, 1);
        expect(platform.advertisements.whereType<int>(), isEmpty);
        expect(controller.accepting, isFalse);
        expect(controller.sessions, isEmpty);
        expect(controller.busy, isFalse);
        expect(peer.sessions, isEmpty);
        expect(peer.code, code);
      },
    );
  }

  test(
    'shutdown waits for pending advertisement and its late cleanup',
    () async {
      final platform = FakeConnectionPlatform()
        ..advertisingStarted = Completer<void>()
        ..advertisementResult = Completer<String?>();
      final controller = ConnectionController(platform);
      addTearDown(controller.dispose);
      platform.seed.complete(
        await DeviceIdentity.fromSeed(List.filled(32, 76)),
      );
      final opening = controller.open();
      await platform.advertisingStarted!.future;
      expect(platform.advertisements.whereType<int>(), hasLength(1));

      var shutdownFinished = false;
      final shutdown = controller.shutdown();
      unawaited(shutdown.then((_) => shutdownFinished = true));
      expect(controller.shutdown(), same(shutdown));
      await Future<void>.delayed(Duration.zero);
      expect(shutdownFinished, isFalse);
      expect(controller.accepting, isFalse);

      platform.advertisementResult!.complete('late.local');
      await opening;
      await shutdown;
      expect(shutdownFinished, isTrue);
      expect(platform.advertisements.last, isNull);
      expect(controller.accepting, isFalse);
      expect(controller.code, isNull);
      expect(controller.address, isNull);
    },
  );

  for (final outgoing in [false, true]) {
    test(
      'shutdown from synchronous ${outgoing ? 'connect' : 'open'} notification awaits its owner',
      () async {
        final platform = FakeConnectionPlatform();
        final controller = ConnectionController(platform);
        addTearDown(controller.dispose);
        Future<void>? shutdown;
        var requested = false;
        controller.addListener(() {
          if (controller.busy && !requested) {
            requested = true;
            shutdown = controller.shutdown();
          }
        });

        final pending = outgoing
            ? controller
                  .connect('127.0.0.1', 12345, '123456')
                  .then<void>((_) {})
            : controller.open();
        expect(requested, isTrue);
        expect(platform.identityRequests, 1);
        var shutdownFinished = false;
        unawaited(shutdown!.then((_) => shutdownFinished = true));
        expect(controller.shutdown(), same(shutdown));
        await Future<void>.delayed(Duration.zero);
        expect(shutdownFinished, isFalse);

        platform.seed.complete(
          await DeviceIdentity.fromSeed(List.filled(32, 77)),
        );
        await pending;
        await shutdown;
        expect(shutdownFinished, isTrue);
        expect(platform.advertisements.whereType<int>(), isEmpty);
        expect(controller.sessions, isEmpty);
        expect(controller.accepting, isFalse);
        expect(controller.busy, isFalse);
      },
    );
  }

  test(
    'closing admission refuses new inbound even with the old code',
    () async {
      final bPlatform = FakeConnectionPlatform();
      final b = ConnectionController(bPlatform);
      final bIdentity = await DeviceIdentity.fromSeed(List.filled(32, 41));
      bPlatform.seed.complete(bIdentity);
      await b.open();
      final port = bPlatform.advertisements.whereType<int>().last;
      final code = b.code!;
      await b.disconnectAll();
      expect(b.accepting, isFalse);
      expect(b.code, isNull);
      final cPlatform = FakeConnectionPlatform();
      final c = ConnectionController(cPlatform);
      addTearDown(() {
        c.dispose();
        b.dispose();
      });
      cPlatform.seed.complete(
        await DeviceIdentity.fromSeed(List.filled(32, 42)),
      );
      final rejected = await c.connect(
        '127.0.0.1',
        port,
        code,
        expectedPeerKey: bIdentity.encodedKey,
      );
      expect(rejected, isNull);
      expect(c.sessions, isEmpty);
      expect(c.message, contains('连接未建立'));
      expect(c.notice?.kind, ConnectionNoticeKind.problem);
      expect(c.problem, c.message);
    },
  );
  test(
    'cancel while loading identity cannot start listener from late result',
    () async {
      final platform = FakeConnectionPlatform();
      final controller = ConnectionController(platform);
      final opening = controller.open();
      controller.cancel();
      platform.seed.complete(await DeviceIdentity.fromSeed(List.filled(32, 4)));
      await opening;
      expect(controller.accepting, isFalse);
      expect(controller.code, isNull);
      expect(controller.notice?.kind, ConnectionNoticeKind.status);
      expect(controller.problem, isNull);
      expect(platform.advertisements.whereType<int>(), isEmpty);
      controller.dispose();
    },
  );
  test(
    'dispose while loading identity cannot publish or notify late result',
    () async {
      final platform = FakeConnectionPlatform();
      final controller = ConnectionController(platform);
      final opening = controller.open();
      controller.dispose();
      platform.seed.complete(await DeviceIdentity.fromSeed(List.filled(32, 5)));
      await opening;
      expect(platform.advertisements.whereType<int>(), isEmpty);
    },
  );
  test(
    'cancelled outgoing attempt does not revive UI after identity returns',
    () async {
      final platform = FakeConnectionPlatform();
      final controller = ConnectionController(platform);
      final connecting = controller.connect('127.0.0.1', 12345, '123456');
      controller.cancel();
      platform.seed.complete(await DeviceIdentity.fromSeed(List.filled(32, 6)));
      expect(await connecting, isNull);
      expect(controller.sessions, isEmpty);
      expect(controller.busy, isFalse);
      expect(controller.message, '已取消连接。');
      controller.dispose();
    },
  );
}
