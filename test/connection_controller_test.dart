import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/connections/auxiliary_route_controller.dart';

final class _RouteStore implements AuxiliaryRouteStore {
  @override
  Future<AuxiliaryRouteChoice?> read() async => null;
  @override
  Future<void> write(AuxiliaryRouteChoice choice) async {}
}

final class _UnavailableAuxiliary implements AuxiliaryTransport {
  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  ) => Future.error(const AuxiliaryFailure('unreachable'));
}

class FakeConnectionPlatform implements ConnectionPlatform {
  final seed = Completer<DeviceIdentity>();
  final advertisements = <int?>[];
  @override
  Future<DeviceIdentity> identity() => seed.future;
  @override
  Future<int> now() async => 1000;
  @override
  Future<String?> advertise(int? port, String? key) async {
    advertisements.add(port);
    return 'test.local';
  }
}

void main() {
  test('official auxiliary failure does not block local pairing', () async {
    final aPlatform = FakeConnectionPlatform();
    final bPlatform = FakeConnectionPlatform();
    final alice = await DeviceIdentity.fromSeed(List.filled(32, 91));
    final bob = await DeviceIdentity.fromSeed(List.filled(32, 92));
    aPlatform.seed.complete(alice);
    bPlatform.seed.complete(bob);
    final routes = AuxiliaryRouteController(
      identity: () async => alice,
      officialOrigin: 'https://offline.example',
      store: _RouteStore(),
      transportFactory: (_) =>
          (transport: _UnavailableAuxiliary(), close: () {}),
    );
    await routes.load();
    routes.setNeeded(true);
    final a = ConnectionController(aPlatform, auxiliaryRoutes: routes);
    final b = ConnectionController(bPlatform);
    addTearDown(() async {
      await a.disconnectAll();
      await b.disconnectAll();
      a.dispose();
      b.dispose();
      routes.stop();
    });
    await b.open();
    final port = bPlatform.advertisements.whereType<int>().last;
    final connected = await a.connect(
      '127.0.0.1',
      port,
      b.code!,
      expectedPeerKey: bob.encodedKey,
    );
    expect(connected, isNotNull);
    expect(a.sessions.single.isConnected, isTrue);
    expect(b.sessions.single.isConnected, isTrue);
    expect(a.problem, isNull);
  });

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
