import 'dart:async';
import 'dart:io';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

void main() {
  final hosts = <PairingHost>[];
  final services = <ConnectionRecoveryService>[];
  final sessions = <TrustedConnection>[];
  final relays = <_Relay>[];
  tearDown(() async {
    for (final session in sessions) {
      session.close();
    }
    for (final host in hosts) {
      await host.close();
    }
    for (final service in services) {
      await service.close();
    }
    for (final relay in relays) {
      await relay.close();
    }
    hosts.clear();
    services.clear();
    sessions.clear();
    relays.clear();
  });

  Future<ConnectionRecoveryService> service() async {
    final s = ConnectionRecoveryService();
    services.add(s);
    await s.open(address: InternetAddress.loopbackIPv4);
    return s;
  }

  Future<(TrustedConnection, TrustedConnection, PairingHost, _Relay)> pair({
    ConnectionRecoveryService? initiator,
    ConnectionRecoveryService? receiver,
    int version = 2,
  }) async {
    final accepted = Completer<TrustedConnection>();
    final host = PairingHost(
      identity: await DeviceIdentity.fromSeed(List.filled(32, 1)),
      clock: () async => 100,
      protocolVersion: version,
      recovery: receiver,
      onConnection: accepted.complete,
    );
    hosts.add(host);
    await host.open(address: InternetAddress.loopbackIPv4);
    final relay = await _Relay.open(host.port!);
    relays.add(relay);
    final attempt = PairingAttempt(
      identity: await DeviceIdentity.fromSeed(List.filled(32, 2)),
      clock: () async => 100,
      protocolVersion: version,
      recovery: initiator,
    );
    final client = await attempt.connect(
      '127.0.0.1',
      relay.server.port,
      host.offer!.code,
    );
    final server = await accepted.future;
    sessions.addAll([client, server]);
    return (client, server, host, relay);
  }

  test(
    'v2 pairing registers recovery only after both sides negotiate',
    () async {
      final left = await service(), right = await service();
      final connected = await pair(initiator: left, receiver: right);
      expect(left.registeredCount, 1);
      expect(right.registeredCount, 1);
      expect(connected.$1.grant!.generation, 1);
      expect(connected.$2.grant!.generation, 1);
      await connected.$3.stopAccepting();
      expect(right.port, isNotNull);
      expect(right.registeredCount, 1);
    },
  );

  for (final side in ['initiator', 'receiver']) {
    test(
      'one-sided capability keeps normal v2 pairing compatible ($side)',
      () async {
        final available = await service();
        final connected = await pair(
          initiator: side == 'initiator' ? available : null,
          receiver: side == 'receiver' ? available : null,
        );
        expect(available.registeredCount, 0);
        connected.$1.close();
        await connected.$2.whenClosed.timeout(const Duration(seconds: 2));
        expect(connected.$2.grant!.phase, GrantPhase.revoked);
      },
    );
  }

  test('v1 does not negotiate recovery even with available services', () async {
    final left = await service(), right = await service();
    final connected = await pair(initiator: left, receiver: right, version: 1);
    expect(connected.$1.grant, isNull);
    expect(left.registeredCount, 0);
    expect(right.registeredCount, 0);
  });

  test(
    'real PAKE pair recovers after wire loss and short-code refresh',
    () async {
      final left = await service(), right = await service();
      final connected = await pair(initiator: left, receiver: right);
      final a = connected.$1, b = connected.$2;
      final ga = a.grant!, gb = b.grant!;
      final oldSession = a.sessionId;
      final received = Completer<VerifiedSessionMessage>();
      b
          .operationTransport({SessionOperation.file})
          .attachReceiver(
            onRequest: received.complete,
            resolveSession: (_) => null,
            onSignal: (_) {},
          );
      await connected.$3.open(address: InternetAddress.loopbackIPv4);
      await connected.$3.stopAccepting();
      final paused = [a, b]
          .map(
            (c) => c.phaseChanges.firstWhere(
              (p) => p == ConnectionPhase.suspended,
            ),
          )
          .toList();
      connected.$4.cut();
      await Future.wait(paused).timeout(const Duration(seconds: 2));
      final active = b.phaseChanges.firstWhere(
        (p) => p == ConnectionPhase.active,
      );
      await left.reconnect(a);
      await active.timeout(const Duration(seconds: 2));
      expect(a.grant, same(ga));
      expect(b.grant, same(gb));
      expect(ga.generation, 2);
      expect(gb.generation, 2);
      expect(a.sessionId, isNot(oldSession));
      expect(a.sessionId, b.sessionId);
      expect(ga.expiresMicros, 100 + grantLifetime.inMicroseconds);
      await a.sendRequest(
        await a.createRequest(
          SessionOperation.file,
          'after-recovery',
          'authenticated',
        ),
      );
      expect(
        (await received.future.timeout(const Duration(seconds: 2))).body,
        'authenticated',
      );
      a.close();
      await b.whenClosed.timeout(const Duration(seconds: 2));
      expect(b.grant!.phase, GrantPhase.revoked);
      await expectLater(left.reconnect(a), throwsA(isA<ConnectionFailure>()));
    },
  );
}

/// Byte-only relay: closing these sockets injects physical EOF without calling
/// TrustedConnection.close (which intentionally revokes the grant).
class _Relay {
  _Relay(this.server);
  final ServerSocket server;
  final sockets = <Socket>{};
  bool closed = false;
  static Future<_Relay> open(int targetPort) async {
    final relay = _Relay(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    relay.server.listen((client) async {
      relay.sockets.add(client);
      Socket remote;
      try {
        remote = await Socket.connect('127.0.0.1', targetPort);
      } catch (_) {
        client.destroy();
        return;
      }
      if (relay.closed) {
        client.destroy();
        remote.destroy();
        return;
      }
      relay.sockets.add(remote);
      void end() {
        client.destroy();
        remote.destroy();
      }

      client.listen(remote.add, onDone: end, onError: (Object _) => end());
      remote.listen(client.add, onDone: end, onError: (Object _) => end());
      unawaited(client.done.catchError((Object _) {}));
      unawaited(remote.done.catchError((Object _) {}));
    });
    return relay;
  }

  void cut() {
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
  }

  Future<void> close() async {
    closed = true;
    cut();
    await server.close();
  }
}
