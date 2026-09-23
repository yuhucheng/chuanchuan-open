import 'dart:async';
import 'dart:io';

import 'package:share_hub_connection/src/channel.dart';
import 'package:share_hub_connection/src/identity.dart';
import 'package:share_hub_connection/src/relay_service_client.dart';
import 'package:share_hub_connection/src/session.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

void main() {
  late _Pair pair;
  setUp(() async => pair = await _Pair.create());
  tearDown(() => pair.close());

  test(
    'a connection without negotiated recovery still revokes on wire loss',
    () async {
      await pair.close();
      pair = await _Pair.create(recoverable: false);
      pair.wires.first.$1.wire.close();
      await Future.wait([pair.a.whenClosed, pair.b.whenClosed])
          .timeout(const Duration(seconds: 2));
      expect(pair.a.grant!.phase, GrantPhase.revoked);
      expect(pair.b.grant!.phase, GrantPhase.revoked);
      expect(() => pair.ra.beginRecovery(), throwsA(isA<ConnectionFailure>()));
    },
  );

  test(
    'wire loss suspends original authority after synchronous file barrier',
    () async {
      final original = pair.a.grant!;
      final lease = pair.a.lease;
      final request = await pair.a.createRequest(
        SessionOperation.file,
        'old',
        '',
      );
      var paused = false;
      pair.a.addSuspendingListener(() {
        expect(pair.a.isConnected, isFalse);
        expect(original.phase, GrantPhase.active);
        paused = true;
      });
      original.invalidated.listen((_) {
        if (original.phase == GrantPhase.suspended) expect(paused, isTrue);
      });
      await pair.loseWire();
      expect(pair.a.isClosed, isFalse);
      expect(pair.a.grant, same(original));
      expect(pair.a.lease, same(lease));
      expect(original.phase, GrantPhase.suspended);
      expect(original.expiresMicros, 100 + grantLifetime.inMicroseconds);
      await expectLater(request.check(), throwsA(isA<SessionFailure>()));
      await expectLater(
        pair.a.createRequest(SessionOperation.file, 'blocked', ''),
        throwsA(isA<ConnectionFailure>()),
      );
    },
  );

  test('fresh wire keeps operation ports and original deadline', () async {
    final port = pair.b.operationTransport({SessionOperation.file});
    final received = Completer<VerifiedSessionMessage>();
    port.attachReceiver(
      onRequest: received.complete,
      resolveSession: (_) => null,
      onSignal: (_) {},
    );
    final original = pair.a.grant!, lease = pair.a.lease;
    final oldId = pair.a.sessionId;
    await pair.loseWire();
    final left = pair.ra.beginRecovery(), right = pair.rb.beginRecovery();
    await pair.activate();
    expect(original.phase, GrantPhase.active);
    expect(
      pair.a.isConnected,
      isFalse,
      reason: 'Inner grant activation is not wire publication.',
    );
    await expectLater(
      pair.a.createRequest(SessionOperation.file, 'too-early', ''),
      throwsA(isA<ConnectionFailure>()),
    );
    final wire = await pair.newWire();
    await Future.wait([left.install(wire.$1), right.install(wire.$2)]);
    expect(pair.a.grant, same(original));
    expect(pair.a.lease, same(lease));
    expect(pair.a.grant!.generation, 2);
    expect(pair.a.sessionId, isNot(oldId));
    expect(pair.b.operationTransport({SessionOperation.file}), same(port));
    await pair.a.sendRequest(
      await pair.a.createRequest(SessionOperation.file, 'new', 'payload'),
    );
    expect(
      (await received.future.timeout(const Duration(seconds: 2))).body,
      'payload',
    );
    expect(pair.a.grant!.expiresMicros, 100 + grantLifetime.inMicroseconds);
  });

  test(
    'expired suspended owner terminates instead of extending its lease',
    () async {
      await pair.loseWire();
      pair.now = 100 + grantLifetime.inMicroseconds;
      expect(await pair.a.check(), isFalse);
      expect(pair.a.phase, ConnectionPhase.closed);
      expect(pair.a.grant!.phase, GrantPhase.revoked);
      expect(() => pair.ra.beginRecovery(), throwsA(isA<ConnectionFailure>()));
    },
  );

  test('clock failure is terminal even while wire is unavailable', () async {
    await pair.loseWire();
    pair.clockFails = true;
    expect(await pair.a.check(), isFalse);
    expect(pair.a.isClosed, isTrue);
    expect(pair.a.grant!.phase, GrantPhase.revoked);
  });

  test(
    'clock rollback while suspended terminates the original grant',
    () async {
      await pair.loseWire();
      pair.now = 99;
      expect(await pair.a.check(), isFalse);
      expect(pair.a.grant!.phase, GrantPhase.revoked);
      expect(pair.a.lease.revoked, isTrue);
    },
  );

  test(
    'a recovery without a newer active grant cannot publish a wire',
    () async {
      await pair.loseWire();
      final attempt = pair.ra.beginRecovery();
      final wire = await pair.newWire();
      await expectLater(
        attempt.install(wire.$1),
        throwsA(isA<ConnectionFailure>()),
      );
      expect(pair.a.phase, ConnectionPhase.suspended);
      expect(pair.a.grant!.generation, 1);
      expect(pair.a.grant!.phase, GrantPhase.suspended);
    },
  );

  test(
    'closing during the recovery clock check prevents late publication',
    () async {
      await pair.loseWire();
      final attempt = pair.ra.beginRecovery();
      pair.rb.beginRecovery();
      await pair.activate();
      final wire = await pair.newWire();
      pair.clockGate = Completer<int>();
      final installing = expectLater(
        attempt.install(wire.$1),
        throwsA(isA<ConnectionFailure>()),
      );
      await pair.clockEntered.future;
      pair.a.close();
      pair.clockGate!.complete(100);
      await installing;
      expect(pair.a.phase, ConnectionPhase.closed);
      expect(pair.a.grant!.phase, GrantPhase.revoked);
    },
  );

  test('a synchronous stop listener can close without suspension reviving the grant', () async {
    pair.a.addSuspendingListener(pair.a.close);
    pair.wires.first.$1.wire.close();
    await pair.a.whenClosed.timeout(const Duration(seconds: 2));
    expect(pair.a.phase, ConnectionPhase.closed);
    expect(pair.a.grant!.phase, GrantPhase.revoked);
  });

  test('cancelled recovery cannot publish over a newer attempt', () async {
    await pair.loseWire();
    final old = pair.ra.beginRecovery();
    expect(() => pair.ra.beginRecovery(), throwsA(isA<ConnectionFailure>()));
    old.cancel();
    final current = pair.ra.beginRecovery();
    final peer = pair.rb.beginRecovery();
    await pair.activate();
    final wire = await pair.newWire();
    await Future.wait([current.install(wire.$1), peer.install(wire.$2)]);
    final obsolete = await pair.newWire();
    await expectLater(
      old.install(obsolete.$1),
      throwsA(isA<ConnectionFailure>()),
    );
    old.cancel();
    expect(pair.a.phase, ConnectionPhase.active);
    expect(await pair.a.check(), isTrue);
  });

  test(
    'a stalled old heartbeat cannot block the new wire clock and heartbeat',
    () async {
      pair.control.sendGate = Completer<void>();
      pair.control.gatedType = 'heartbeat';
      final old = pair.a.check();
      await pair.control.sendEntered.future;
      await pair.loseWire();
      await pair.rewire();
      expect(await pair.a.check(), isTrue);
      pair.control.sendGate!.complete();
      expect(await old, isFalse);
      expect(pair.a.phase, ConnectionPhase.active);
    },
  );

  test(
    'eight blocked old operations do not occupy or close the new send queue',
    () async {
      final received = Completer<VerifiedSessionMessage>();
      pair.b.attachReceiver(
        onRequest: received.complete,
        resolveSession: (_) => null,
        onSignal: (_) {},
      );
      final requests = [
        for (var i = 0; i < 8; i++)
          await pair.a.createRequest(SessionOperation.file, 'old-$i', ''),
      ];
      pair.control.sendGate = Completer<void>();
      pair.control.gatedType = 'operation-request';
      final old = [
        for (final request in requests)
          expectLater(
            pair.a.sendRequest(request),
            throwsA(isA<ConnectionFailure>()),
          ),
      ];
      await pair.control.sendEntered.future;
      await pair.loseWire();
      await pair.rewire();
      await pair.a.sendRequest(
        await pair.a.createRequest(
          SessionOperation.file,
          'current',
          'new-wire',
        ),
      );
      expect(
        (await received.future.timeout(const Duration(seconds: 2))).body,
        'new-wire',
      );
      pair.control.sendGate!.complete();
      await Future.wait(old);
      expect(pair.a.phase, ConnectionPhase.active);
      expect(await pair.a.check(), isTrue);
    },
  );

  test(
    'a late decoded old frame cannot deliver into the new wire receiver',
    () async {
      final seen = <String>[];
      final current = Completer<void>();
      pair.a.attachReceiver(
        onRequest: (request) {
          seen.add(request.sessionId);
          if (request.sessionId == 'current') current.complete();
        },
        resolveSession: (_) => null,
        onSignal: (_) {},
      );
      pair.control.readGate = Completer<void>();
      await pair.b.sendRequest(
        await pair.b.createRequest(SessionOperation.file, 'old', 'old'),
      );
      await pair.control.readEntered.future;
      // Simulate the protocol's already authenticated asymmetric recovery: the
      // old reader is stalled, but the recovery capability retires that wire.
      await pair.rewire();
      await pair.b.sendRequest(
        await pair.b.createRequest(SessionOperation.file, 'current', 'new'),
      );
      await current.future.timeout(const Duration(seconds: 2));
      pair.control.readGate!.complete();
      await pair.control.readReleased.future;
      expect(await pair.a.check(), isTrue);
      expect(seen, ['current']);
      expect(pair.a.phase, ConnectionPhase.active);
    },
  );

  test(
    'healthy explicit close authenticates terminal intent to the peer',
    () async {
      pair.a.close();
      await pair.b.whenClosed.timeout(const Duration(seconds: 2));
      expect(pair.b.grant!.phase, GrantPhase.revoked);
      expect(pair.b.phase, ConnectionPhase.closed);
    },
  );
}

class _Pair {
  int now = 100, wireId = 0;
  bool clockFails = false;
  Completer<int>? clockGate;
  final clockEntered = Completer<void>();
  final ra = ConnectionRecoveryHandle(), rb = ConnectionRecoveryHandle();
  late TrustedConnection a, b;
  late _ControlledCipher control;
  late GrantEndpoint ga, gb;
  final wires = <(CipherChannel, CipherChannel)>[];
  Future<int> clock() async {
    if (clockFails) throw StateError('clock unavailable');
    if (clockGate != null) {
      if (!clockEntered.isCompleted) clockEntered.complete();
      return clockGate!.future;
    }
    return now;
  }

  Future<(CipherChannel, CipherChannel)> newWire() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;
    final socket = await Socket.connect('127.0.0.1', server.port);
    final other = await accepted;
    await server.close();
    final id = ++wireId;
    final left = await CipherChannel.create(
      WireChannel(socket),
      List.filled(32, id),
      [id],
      host: false,
    );
    final right = await CipherChannel.create(
      WireChannel(other),
      List.filled(32, id),
      [id],
      host: true,
    );
    left.enableSessionFrames();
    right.enableSessionFrames();
    final result = (left, right);
    wires.add(result);
    return result;
  }

  Future<void> activate() async {
    final response = await gb.answerResume(await ga.beginResume());
    await gb.acceptResume(await ga.finishResume(response));
  }

  Future<void> rewire() async {
    final left = ra.beginRecovery(), right = rb.beginRecovery();
    await activate();
    final wire = await newWire();
    await Future.wait([left.install(wire.$1), right.install(wire.$2)]);
  }

  static Future<_Pair> create({bool recoverable = true}) async {
    final p = _Pair();
    final binding = GrantBinding(
      id: List.filled(32, 1),
      initiatorKey: List.filled(32, 2),
      receiverKey: List.filled(32, 3),
    );
    GrantEndpoint endpoint(GrantRole role) =>
        GrantEndpoint.fromAuthenticatedPairing(
          binding: binding,
          role: role,
          establishedMicros: 100,
          recoverySecret: List.filled(32, 4),
          clock: p.clock,
          onInvalidated: () {},
        );
    p.ga = endpoint(GrantRole.initiator);
    p.gb = endpoint(GrantRole.receiver);
    await p.activate();
    final wire = await p.newWire();
    p.control = _ControlledCipher(wire.$1);
    p.a = TrustedConnection(
      p.control,
      encodeBytes(binding.receiverKey),
      SessionLease(startedMicros: 100),
      p.clock,
      grant: p.ga,
      recovery: recoverable ? p.ra : null,
    );
    p.b = TrustedConnection(
      wire.$2,
      encodeBytes(binding.initiatorKey),
      SessionLease(startedMicros: 100),
      p.clock,
      grant: p.gb,
      recovery: recoverable ? p.rb : null,
    );
    p.a.startMonitoring();
    p.b.startMonitoring();
    await Future.wait([p.a.check(), p.b.check()]);
    return p;
  }

  Future<void> loseWire() async {
    final left = a.phaseChanges.firstWhere(
      (phase) => phase == ConnectionPhase.suspended,
    );
    final right = b.phaseChanges.firstWhere(
      (phase) => phase == ConnectionPhase.suspended,
    );
    wires.last.$1.wire.close();
    await Future.wait([left, right]).timeout(const Duration(seconds: 2));
  }

  Future<void> close() async {
    if (clockGate != null && !clockGate!.isCompleted) clockGate!.complete(now);
    if (control.readGate != null && !control.readGate!.isCompleted) {
      control.readGate!.complete();
    }
    if (control.sendGate != null && !control.sendGate!.isCompleted) {
      control.sendGate!.complete();
    }
    a.close();
    b.close();
    for (final pair in wires) {
      pair.$1.wire.close();
      pair.$2.wire.close();
    }
  }
}

/// Fault injection at the cipher call boundary; encryption and TCP remain real.
class _ControlledCipher implements CipherChannel {
  _ControlledCipher(this.inner);
  final CipherChannel inner;
  Completer<void>? sendGate;
  Completer<void>? readGate;
  final readEntered = Completer<void>(), readReleased = Completer<void>();
  String? gatedType;
  final sendEntered = Completer<void>();
  @override
  ConnectionWire get wire => inner.wire;
  @override
  Future<ConnectionWire> protectRelay(
    RelaySignalChannel channel,
    List<int> transcript,
  ) => inner.protectRelay(channel, transcript);
  @override
  String get sessionId => inner.sessionId;
  @override
  void enableSessionFrames() => inner.enableSessionFrames();
  @override
  Future<Map<String, dynamic>> next({void Function()? onFrame}) async {
    final result = await inner.next(onFrame: onFrame);
    if (result['type'] == 'operation-request' && readGate != null) {
      if (!readEntered.isCompleted) readEntered.complete();
      await readGate!.future;
      if (!readReleased.isCompleted) readReleased.complete();
    }
    return result;
  }

  @override
  Future<void> send(Map<String, dynamic> body) async {
    if (body['type'] == gatedType && sendGate != null) {
      if (!sendEntered.isCompleted) sendEntered.complete();
      await sendGate!.future;
    }
    await inner.send(body);
  }
}
