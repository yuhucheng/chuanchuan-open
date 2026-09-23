import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_connection/src/channel.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

/// Real TCP forwarding owned by this test, so loss does not call close/revoke
/// on either authenticated endpoint and does not touch a user's network.
class CuttableProxy {
  late ServerSocket server;
  final sockets = <Socket>[];
  Future<void> start(int target) async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((client) async {
      sockets.add(client);
      final remote = await Socket.connect('127.0.0.1', target);
      sockets.add(remote);
      client.listen(
        remote.add,
        onDone: remote.destroy,
        onError: (Object _) => remote.destroy(),
      );
      remote.listen(
        client.add,
        onDone: client.destroy,
        onError: (Object _) => client.destroy(),
      );
    });
  }

  void cut() {
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
  }

  Future<void> close() async {
    cut();
    await server.close();
  }
}

void main() {
  late DeviceIdentity identityA, identityB;
  late PairingHost host;
  late CuttableProxy proxy;
  late int now;
  Future<int> Function()? clientClock;
  final clients = <TrustedConnection>[];
  final accepted = <TrustedConnection>[];
  setUp(() async {
    clientClock = null;
    now = 1000000;
    clients.clear();
    accepted.clear();
    identityA = await DeviceIdentity.fromSeed(List.filled(32, 21));
    identityB = await DeviceIdentity.fromSeed(List.filled(32, 22));
    host = PairingHost(
      identity: identityB,
      clock: () async => now,
      protocolVersion: 2,
      enableRecovery: true,
      onConnection: accepted.add,
    );
    await host.open(address: InternetAddress.loopbackIPv4);
    proxy = CuttableProxy();
    await proxy.start(host.port!);
  });
  tearDown(() async {
    for (final c in clients) {
      c.close();
    }
    for (final c in accepted) {
      c.close();
    }
    await proxy.close();
    await host.close();
  });
  Future<TrustedConnection> pair({bool recovery = true}) async {
    final c =
        await PairingAttempt(
          identity: identityA,
          clock: () => clientClock?.call() ?? Future.value(now),
          protocolVersion: 2,
          enableRecovery: recovery,
        ).connect(
          '127.0.0.1',
          proxy.server.port,
          host.offer!.code,
          expectedPeerKey: identityB.encodedKey,
        );
    clients.add(c);
    return c;
  }

  Future<void> lost(TrustedConnection client) async {
    proxy.cut();
    expect(
      await client.whenClosed.timeout(const Duration(seconds: 3)),
      'transport_suspended',
    );
    expect(
      await accepted.last.whenClosed.timeout(const Duration(seconds: 3)),
      'transport_suspended',
    );
  }

  test('real socket recovery preserves identity and deadlines but invalidates old permits and packets', () async {
    final original = await pair();
    final endpoint = original.grant!, oldRemote = accepted.single;
    final lease = original.lease;
    final expiry = endpoint.expiresMicros;
    final oldRequest = await original.createRequest(
      SessionOperation.watch,
      'old',
      'body',
    );
    final packet = await endpoint.sealRequest(oldRequest);
    await oldRemote.grant!.open(packet);
    await lost(original);
    expect(endpoint.phase, GrantPhase.suspended);
    expect(oldRequest.requireCurrent, throwsA(isA<SessionFailure>()));
    now += const Duration(minutes: 12).inMicroseconds;
    final recovered = await ConnectionRecoveryAttempt(original)
        .connect('127.0.0.1', host.port!);
    clients.add(recovered);
    expect(recovered.grant, same(endpoint));
    expect(recovered.lease, same(lease));
    expect(endpoint.expiresMicros, expiry);
    expect(endpoint.generation, 2);
    expect(recovered.peerKey, original.peerKey);
    expect(recovered.sessionId, isNot(original.sessionId));
    expect(original.canRecover, false);
    final remote = accepted.last;
    expect(remote.grant, same(oldRemote.grant));
    expect(remote.lease, same(oldRemote.lease));
    await expectLater(
      remote.grant!.open(packet),
      throwsA(isA<SessionFailure>()),
    );
    final request = Completer<VerifiedSessionMessage>();
    remote.attachReceiver(
      onRequest: request.complete,
      resolveSession: (_) => null,
      onSignal: (_) {},
    );
    await recovered.sendRequest(
      await recovered.createRequest(SessionOperation.watch, 'fresh', 'body'),
    );
    expect(
      (await request.future.timeout(const Duration(seconds: 3)))
          .transportGeneration,
      2,
    );
    expect(await recovered.check(), true);
    expect(await remote.check(), true);
    now = expiry;
    expect(await recovered.check(), false);
    expect(endpoint.phase, GrantPhase.revoked);
    expect(recovered.canRecover, false);
  });

  test('recovery is negotiated; a legacy adapter keeps terminal disconnect behavior', () async {
    final c = await pair(recovery: false);
    expect(c.enableRecovery, false);
    expect(accepted.single.enableRecovery, false);
    proxy.cut();
    await c.whenClosed.timeout(const Duration(seconds: 3));
    expect(c.canRecover, false);
    expect(c.grant!.phase, GrantPhase.revoked);
    await expectLater(
      ConnectionRecoveryAttempt(c).connect('127.0.0.1', host.port!),
      throwsA(isA<ConnectionFailure>()),
    );
  });

  test(
    'explicit close while suspended permanently cancels recovery eligibility',
    () async {
      final c = await pair();
      await lost(c);
      c.close();
      expect(c.grant!.phase, GrantPhase.revoked);
      await expectLater(
        ConnectionRecoveryAttempt(c).connect('127.0.0.1', host.port!),
        throwsA(isA<ConnectionFailure>()),
      );
      expect(accepted, hasLength(1));
    },
  );

  test('wrong process or identity cannot recover a retained grant', () async {
    final c = await pair();
    await lost(c);
    final other = PairingHost(
      identity: identityA,
      clock: () async => now,
      protocolVersion: 2,
      enableRecovery: true,
      onConnection: (_) => fail('wrong identity'),
    );
    await other.open(address: InternetAddress.loopbackIPv4);
    try {
      await expectLater(
        ConnectionRecoveryAttempt(c).connect('127.0.0.1', other.port!),
        throwsA(isA<ConnectionFailure>()),
      );
      expect(c.grant!.phase, GrantPhase.suspended);
      final r = await ConnectionRecoveryAttempt(c)
          .connect('127.0.0.1', host.port!);
      clients.add(r);
      expect(r.grant!.generation, greaterThan(1));
    } finally {
      await other.close();
    }
  });

  test(
    'cancel during an unanswered handshake revokes and closes the owned socket',
    () async {
      final c = await pair();
      await lost(c);
      final dummy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<WireChannel>();
      dummy.listen((socket) => received.complete(WireChannel(socket)));
      final attempt = ConnectionRecoveryAttempt(c);
      final future = attempt.connect('127.0.0.1', dummy.port);
      final rejected = expectLater(future, throwsA(anything));
      final wire = await received.future;
      await wire.next();
      attempt.cancel();
      await rejected;
      expect(c.canRecover, false);
      expect(c.grant!.phase, GrantPhase.revoked);
      wire.close();
      await dummy.close();
    },
  );

  test('timeout leaves only bounded retry eligibility and an expired grant cannot recover', () async {
    final c = await pair();
    await lost(c);
    final dummy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final wires = <WireChannel>[];
    dummy.listen((socket) {
      final w = WireChannel(socket);
      wires.add(w);
      unawaited(w.next().catchError((Object _) => <String, dynamic>{}));
    });
    await expectLater(
      ConnectionRecoveryAttempt(
        c,
        timeout: const Duration(milliseconds: 40),
      ).connect('127.0.0.1', dummy.port),
      throwsA(anything),
    );
    expect(c.grant!.phase, GrantPhase.suspended);
    for (final wire in wires) {
      wire.close();
    }
    await dummy.close();
    now = c.grant!.expiresMicros;
    await expectLater(
      ConnectionRecoveryAttempt(c).connect('127.0.0.1', host.port!),
      throwsA(anything),
    );
    expect(c.grant!.phase, GrantPhase.revoked);
    expect(c.canRecover, false);
  });

  test(
    'host admission closure rejects suspended grants without renewing them',
    () async {
      final c = await pair();
      await lost(c);
      final previousPort = host.port!;
      await host.stopAccepting();
      expect(accepted.single.grant!.phase, GrantPhase.revoked);
      await expectLater(
        ConnectionRecoveryAttempt(c).connect('127.0.0.1', previousPort),
        throwsA(anything),
      );
      expect(accepted, hasLength(1));
    },
  );
  test('forged final proof cannot commit generation or replace the retained connection', () async {
    final c = await pair();
    await lost(c);
    final serverGrant = accepted.single.grant!;
    final wire = WireChannel(await Socket.connect('127.0.0.1', host.port!));
    wire.send({
      'v': 2,
      'type': 'resume-hello',
      'grant': c.grant!.binding.encodedId,
      'generation': 0xffffffff,
      'challenge': base64Url.encode(List.filled(32, 9)),
    });
    expect((await wire.next())['type'], 'resume-response');
    wire.send({
      'v': 2,
      'type': 'resume-finish',
      'proof': base64Url.encode(List.filled(32, 0)),
    });
    await expectLater(wire.next(), throwsA(isA<ConnectionFailure>()));
    expect(serverGrant.phase, GrantPhase.suspended);
    expect(serverGrant.generation, 1);
    expect(accepted, hasLength(1));
    final recovered = await ConnectionRecoveryAttempt(c)
        .connect('127.0.0.1', host.port!);
    clients.add(recovered);
    expect(recovered.grant!.generation, 2);
  });

  test('lost final encrypted acknowledgement retries with fresh keys and the original deadline', () async {
    final c = await pair();
    await lost(c);
    final expires = c.grant!.expiresMicros;
    final dropper = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final dropped = Completer<void>();
    final forwarding = <WireChannel>[];
    dropper.listen((socket) async {
      final clientWire = WireChannel(socket);
      final hostWire = WireChannel(
        await Socket.connect('127.0.0.1', host.port!),
      );
      forwarding.addAll([clientWire, hostWire]);
      try {
        hostWire.send(await clientWire.next());
        clientWire.send(await hostWire.next());
        hostWire.send(await clientWire.next());
        await hostWire.next();
        clientWire.close();
        hostWire.close();
        dropped.complete();
      } catch (e, st) {
        if (!dropped.isCompleted) dropped.completeError(e, st);
      }
    });
    try {
      await expectLater(
        ConnectionRecoveryAttempt(c).connect('127.0.0.1', dropper.port),
        throwsA(anything),
      );
      await dropped.future;
      for (var i = 0; i < 100 && accepted.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(accepted, hasLength(2));
      await accepted.last.whenClosed.timeout(const Duration(seconds: 3));
      expect(c.grant!.phase, GrantPhase.suspended);
      final recovered = await ConnectionRecoveryAttempt(c)
          .connect('127.0.0.1', host.port!);
      clients.add(recovered);
      expect(recovered.grant!.generation, 3);
      expect(accepted.last.grant!.generation, 3);
      expect(recovered.grant!.expiresMicros, expires);
      expect(await recovered.check(), true);
      expect(await accepted.last.check(), true);
    } finally {
      for (final wire in forwarding) {
        wire.close();
      }
      await dropper.close();
    }
  });
  test('timeout returns while clock is blocked and late completion cannot publish a connection', () async {
    final c = await pair();
    await lost(c);
    final pending = Completer<int>();
    clientClock = () => pending.future;
    final attempt = ConnectionRecoveryAttempt(
      c,
      timeout: const Duration(milliseconds: 30),
    );
    await expectLater(
      attempt
          .connect('127.0.0.1', host.port!)
          .timeout(const Duration(seconds: 1)),
      throwsA(
        isA<ConnectionFailure>().having(
          (e) => e.code,
          'code',
          'recovery_timeout',
        ),
      ),
    );
    expect(c.grant!.phase, GrantPhase.suspended);
    // A timed-out native read still owns its reservation; no second socket/clock pipeline.
    await expectLater(
      ConnectionRecoveryAttempt(c).connect('127.0.0.1', host.port!),
      throwsA(isA<ConnectionFailure>()),
    );
    clientClock = null;
    pending.complete(now);
    await attempt.settled;
    expect(accepted, hasLength(1));
    final recovered = await ConnectionRecoveryAttempt(c)
        .connect('127.0.0.1', host.port!);
    clients.add(recovered);
    expect(recovered.grant!.phase, GrantPhase.active);
  });
}
