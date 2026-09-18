import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';

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
    await a.connect(
      '127.0.0.1',
      port,
      b.code!,
      expectedPeerKey: bIdentity.encodedKey,
    );
    expect(a.accepting, isFalse); // Admission off still permits outbound.
    expect(a.sessions.single.peerKey, bIdentity.encodedKey);
    expect(b.sessions.single.peerKey, aIdentity.encodedKey);
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

  test('closing admission refuses new inbound even with the old code', () async {
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
    cPlatform.seed.complete(await DeviceIdentity.fromSeed(List.filled(32, 42)));
    await c.connect(
      '127.0.0.1',
      port,
      code,
      expectedPeerKey: bIdentity.encodedKey,
    );
    expect(c.sessions, isEmpty);
    expect(c.message, contains('连接未建立'));
  });
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
      await connecting;
      expect(controller.sessions, isEmpty);
      expect(controller.busy, isFalse);
      expect(controller.message, '已取消连接。');
      controller.dispose();
    },
  );
}
