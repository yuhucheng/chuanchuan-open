import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';

class RecoveryPlatform implements ConnectionPlatform {
  RecoveryPlatform(this.key);
  DeviceIdentity key;
  int time = 1000000;
  int? port;
  Completer<DeviceIdentity>? identityRead;
  Completer<void>? identityStarted;
  int identityReads = 0;
  int? blockIdentityAt;
  @override
  Future<DeviceIdentity> identity() {
    identityReads++;
    if (blockIdentityAt != null && identityReads < blockIdentityAt!) {
      return Future.value(key);
    }
    final started = identityStarted;
    if (started != null && !started.isCompleted) started.complete();
    return identityRead?.future ?? Future.value(key);
  }

  @override
  Future<int> now() async => time;
  @override
  Future<String?> advertise(int? value, String? key) async {
    if (value != null) port = value;
    return 'test.local';
  }
}

/// Loss is injected at an owned TCP proxy, never by revoking an endpoint.
class RecoveryProxy {
  late ServerSocket server;
  final sockets = <Socket>[];
  final pending = <Future<void>>{};
  bool closed = false;
  int accepted = 0;
  Future<void> start(int target) async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((client) {
      accepted++;
      sockets.add(client);
      final work = () async {
        try {
          final remote = await Socket.connect('127.0.0.1', target);
          sockets.add(remote);
          if (closed) {
            client.destroy();
            remote.destroy();
            return;
          }
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
        } catch (_) {
          client.destroy();
        }
      }();
      pending.add(work);
      unawaited(work.whenComplete(() => pending.remove(work)));
    });
  }

  void cut() {
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    cut();
    await server.close();
    await Future.wait(pending);
    cut();
  }
}

Future<void> until(bool Function() predicate) async {
  final limit = Stopwatch()..start();
  while (!predicate()) {
    if (limit.elapsed > const Duration(seconds: 5)) {
      fail('State did not settle before the test deadline');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late RecoveryPlatform pa, pb;
  late ConnectionController a, b;
  late RecoveryProxy proxy;
  late TrustedConnection oldA, oldB;
  setUp(() async {
    pa = RecoveryPlatform(await DeviceIdentity.fromSeed(List.filled(32, 101)));
    pb = RecoveryPlatform(await DeviceIdentity.fromSeed(List.filled(32, 102)));
    ConnectionController controller(RecoveryPlatform platform) =>
        ConnectionController(
          platform,
          recoveryWindow: const Duration(milliseconds: 900),
          recoveryBackoff: const [
            Duration(milliseconds: 100),
            Duration(milliseconds: 100),
            Duration(milliseconds: 100),
          ],
          recoveryAttemptTimeout: const Duration(milliseconds: 300),
        );
    a = controller(pa);
    b = controller(pb);
    await b.open();
    proxy = RecoveryProxy();
    await proxy.start(pb.port!);
    oldA = (await a.connect(
      '127.0.0.1',
      proxy.server.port,
      b.code!,
      expectedPeerKey: pb.key.encodedKey,
    ))!;
    oldB = b.sessions.single;
  });
  tearDown(() async {
    pa.identityRead?.complete(pa.key);
    pa.identityRead = null;
    pb.identityRead?.complete(pb.key);
    pb.identityRead = null;
    await a.shutdown();
    await b.shutdown();
    await proxy.close();
    a.dispose();
    b.dispose();
  });
  Future<void> lose() async {
    proxy.cut();
    await until(() => a.recoveringCount == 1 && b.recoveringCount == 1);
    expect(a.sessions, isEmpty);
    expect(b.sessions, isEmpty);
    expect(a.outgoingFor(pb.key.encodedKey), isNull);
  }

  test('code rotation preserves route; repeated recovery keeps grant and expiry but replaces operations', () async {
    final grantA = oldA.grant!, grantB = oldB.grant!;
    final expiresA = grantA.expiresMicros, expiresB = grantB.expiresMicros;
    final packet = await grantA.seal(SessionOperation.watch, 'before-loss', '');
    final permit = await grantB.open(packet);
    final port = pb.port;
    await b.open();
    final freshCode = b.code;
    expect(pb.port, port);
    await lose();
    await expectLater(b.grants.verify(permit), throwsA(isA<SessionFailure>()));
    await until(() => a.sessions.length == 1 && b.sessions.length == 1);
    expect(a.sessions.single, isNot(same(oldA)));
    expect(a.sessions.single.grant, same(grantA));
    expect(b.sessions.single.grant, same(grantB));
    expect(grantA.generation, 2);
    expect(grantB.generation, 2);
    expect(grantA.expiresMicros, expiresA);
    expect(grantB.expiresMicros, expiresB);
    expect(b.code, freshCode); // Recovery does not consume another code.
    await expectLater(grantB.open(packet), throwsA(isA<SessionFailure>()));
    await b.grants.verify(
      await grantB.open(
        await grantA.seal(SessionOperation.watch, 'after-loss', ''),
      ),
    );
    oldA.close();
    oldB.close(); // Stale handles cannot revoke replacements.
    expect(grantA.phase, GrantPhase.active);
    expect(grantB.phase, GrantPhase.active);
    await lose();
    await until(() => a.sessions.length == 1 && b.sessions.length == 1);
    expect(grantA.generation, 3);
    expect(grantA.expiresMicros, expiresA);
  });

  test(
    'explicit disconnect reaches peer as terminal revocation, not recovery',
    () async {
      oldA.close();
      expect(await oldB.whenClosed, 'peer_revoked');
      expect(oldB.grant!.phase, GrantPhase.revoked);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(a.recoveringCount, 0);
      expect(b.recoveringCount, 0);
      expect(proxy.accepted, 1);
    },
  );

  test(
    'cancel recovery revokes original grant and receiver wait is bounded',
    () async {
      await lose();
      a.cancelRecovery(oldA);
      expect(a.recoveringCount, 0);
      expect(oldA.grant!.phase, GrantPhase.revoked);
      await until(() => b.recoveringCount == 0);
      expect(a.sessions, isEmpty);
      expect(b.sessions, isEmpty);
      expect(oldB.grant!.phase, GrantPhase.revoked);
      expect(proxy.accepted, 1);
    },
  );

  test(
    'closing admission prevents recovery; reopening cannot revive old grants',
    () async {
      await lose();
      await b.disconnectAll();
      await b.open();
      await until(() => a.recoveringCount == 0);
      expect(oldA.grant!.phase, GrantPhase.revoked);
      expect(oldB.grant!.phase, GrantPhase.revoked);
      expect(a.sessions, isEmpty);
      expect(b.sessions, isEmpty);
      expect(b.code, matches(RegExp(r'^\d{6}$')));
    },
  );

  for (final receiver in [false, true]) {
    test(
      '${receiver ? 'receiver' : 'initiator'} identity change forbids adoption',
      () async {
        await lose();
        final platform = receiver ? pb : pa;
        platform.key = await DeviceIdentity.fromSeed(List.filled(32, 103));
        await until(
          () =>
              a.recoveringCount == 0 &&
              b.recoveringCount == 0 &&
              a.sessions.isEmpty &&
              b.sessions.isEmpty,
        );
        expect(oldA.grant!.phase, GrantPhase.revoked);
        expect(oldB.grant!.phase, GrantPhase.revoked);
      },
    );
  }

  test(
    'exit cancels immediately but waits for a pending identity read to settle',
    () async {
      await lose();
      pa.identityRead = Completer<DeviceIdentity>();
      pa.identityStarted = Completer<void>();
      await pa.identityStarted!.future;
      var exited = false;
      final exit = a.shutdown().then((_) => exited = true);
      expect(oldA.grant!.phase, GrantPhase.revoked);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(exited, isFalse);
      pa.identityRead!.complete(pa.key);
      pa.identityRead = null;
      await exit;
      expect(a.sessions, isEmpty);
      expect(a.recoveringCount, 0);
      expect(proxy.accepted, 1);
      await a.open();
      expect(a.accepting, isFalse);
    },
  );

  for (final expire in [false, true]) {
    test(
      'pending receiver admission closes its authenticated socket on ${expire ? 'deadline' : 'off'}',
      () async {
        await lose();
        pb.identityRead = Completer<DeviceIdentity>();
        pb.identityStarted = Completer<void>();
        await pb.identityStarted!.future;
        await until(() => a.sessions.length == 1);
        final candidatePeer = a.sessions.single;
        if (expire) {
          await until(() => b.recoveringCount == 0);
        } else {
          await b.disconnectAll();
        }
        expect(
          await candidatePeer.whenClosed.timeout(const Duration(seconds: 2)),
          'peer_revoked',
        );
        expect(candidatePeer.grant!.phase, GrantPhase.revoked);
        expect(b.sessions, isEmpty);
        pb.identityRead!.complete(pb.key);
        pb.identityRead = null;
        await b.shutdown();
        expect(b.sessions, isEmpty);
      },
    );
  }

  test(
    'exit closes sender candidate while final identity admission is pending',
    () async {
      await lose();
      pa.blockIdentityAt = 3; // Initial pairing, pre-attempt, then post-proof.
      pa.identityRead = Completer<DeviceIdentity>();
      pa.identityStarted = Completer<void>();
      await pa.identityStarted!.future;
      await until(() => b.sessions.length == 1);
      final candidatePeer = b.sessions.single;
      final exiting = a.shutdown();
      await candidatePeer.whenClosed.timeout(const Duration(seconds: 2));
      expect(candidatePeer.grant!.phase, GrantPhase.revoked);
      expect(a.sessions, isEmpty);
      pa.identityRead!.complete(pa.key);
      pa.identityRead = null;
      await exiting;
      expect(a.sessions, isEmpty);
    },
  );

  for (final receiver in [false, true]) {
    test(
      '${receiver ? 'receiver' : 'initiator'} rechecks continuous recovery window after delayed identity',
      () async {
        await lose();
        final platform = receiver ? pb : pa;
        if (!receiver) platform.blockIdentityAt = 3;
        platform.identityRead = Completer<DeviceIdentity>();
        platform.identityStarted = Completer<void>();
        await platform.identityStarted!.future;
        platform.time += const Duration(seconds: 1).inMicroseconds;
        expect(platform.time, lessThan(oldA.grant!.expiresMicros));
        platform.identityRead!.complete(platform.key);
        platform.identityRead = null;
        await until(
          () =>
              a.recoveringCount == 0 &&
              b.recoveringCount == 0 &&
              a.sessions.isEmpty &&
              b.sessions.isEmpty,
        );
        expect(oldA.grant!.phase, GrantPhase.revoked);
        expect(oldB.grant!.phase, GrantPhase.revoked);
      },
    );
  }

  test(
    'failed original route exhausts retries without renewing or re-pairing',
    () async {
      final expiry = oldA.grant!.expiresMicros;
      await proxy.close();
      await until(() => a.recoveringCount == 1);
      await until(() => a.recoveringCount == 0);
      expect(oldA.grant!.phase, GrantPhase.revoked);
      expect(oldA.grant!.expiresMicros, expiry);
      expect(a.problem, contains('恢复未完成'));
      expect(b.code, isNull);
      expect(a.sessions, isEmpty);
    },
  );

  test('expired original clock budget cannot be recovered', () async {
    await lose();
    pa.time = oldA.grant!.expiresMicros;
    await until(() => a.recoveringCount == 0);
    expect(a.sessions, isEmpty);
    expect(oldA.grant!.phase, GrantPhase.revoked);
    expect(proxy.accepted, 1);
  });

  test(
    'cancelling a separate pairing dialog does not cancel existing recovery',
    () async {
      await lose();
      a.cancel();
      expect(a.recoveringCount, 1);
      await until(() => a.sessions.length == 1 && b.sessions.length == 1);
      expect(oldA.grant!.generation, 2);
    },
  );
}
