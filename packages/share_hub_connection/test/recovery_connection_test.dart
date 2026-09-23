import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:share_hub_connection/src/auxiliary_service.dart';
import 'package:share_hub_connection/src/channel.dart';
import 'package:share_hub_connection/src/identity.dart';
import 'package:share_hub_connection/src/recovery.dart';
import 'package:share_hub_connection/src/recovery_protocol.dart';
import 'package:share_hub_connection/src/relay_room_claim.dart';
import 'package:share_hub_connection/src/relay_service_client.dart';
import 'package:share_hub_connection/src/relay_signal_envelope.dart';
import 'package:share_hub_connection/src/session.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

void main() {
  late _Pair pair;
  setUp(() async => pair = await _Pair.create());
  tearDown(() => pair.close());

  test('closing during listener bind cannot publish a late port', () async {
    final service = ConnectionRecoveryService();
    final opening = service.open(address: InternetAddress.loopbackIPv4);
    final rejected = expectLater(opening, throwsA(isA<ConnectionFailure>()));
    await service.close();
    await rejected;
    expect(service.port, isNull);
    expect(service.pendingCount, 0);
  });

  test(
    'authenticated recovery retains original authority and stable ports',
    () async {
      final original = pair.a.grant!,
          lease = pair.a.lease,
          id = pair.a.sessionId;
      final port = pair.b.operationTransport({SessionOperation.file});
      final received = Completer<VerifiedSessionMessage>();
      port.attachReceiver(
        onRequest: received.complete,
        resolveSession: (_) => null,
        onSignal: (_) {},
      );
      await pair.lose();
      final active = pair.b.phaseChanges.firstWhere(
        (p) => p == ConnectionPhase.active,
      );
      await pair.left.reconnect(pair.a);
      await active.timeout(const Duration(seconds: 2));
      expect(pair.a.grant, same(original));
      expect(pair.a.lease, same(lease));
      expect(original.expiresMicros, 100 + grantLifetime.inMicroseconds);
      expect(original.generation, 2);
      expect(pair.b.grant!.generation, 2);
      expect(pair.a.sessionId, isNot(id));
      expect(pair.a.sessionId, pair.b.sessionId);
      expect(pair.b.operationTransport({SessionOperation.file}), same(port));
      await pair.a.sendRequest(
        await pair.a.createRequest(SessionOperation.file, 'new', 'payload'),
      );
      expect(
        (await received.future.timeout(const Duration(seconds: 2))).body,
        'payload',
      );
    },
  );

  test(
    'caller-provided wires reuse the registered stable recovery owner',
    () async {
      final original = pair.a.grant!;
      final transport = pair.b.operationTransport({SessionOperation.file});
      await pair.lose();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      final outgoing = WireChannel(
        await Socket.connect('127.0.0.1', server.port),
      );
      final incoming = WireChannel(await accepted);
      await server.close();
      pair.wires.addAll([outgoing, incoming]);
      await Future.wait([
        pair.left.reconnectVia(pair.a, (_) async => outgoing),
        pair.right.acceptVia(pair.b, (_) async => incoming),
      ]).timeout(const Duration(seconds: 2));
      expect(pair.a.grant, same(original));
      expect(pair.a.grant!.generation, 2);
      expect(pair.b.grant!.generation, 2);
      expect(pair.a.phase, ConnectionPhase.active);
      expect(pair.b.phase, ConnectionPhase.active);
      expect(
        pair.b.operationTransport({SessionOperation.file}),
        same(transport),
      );
    },
  );

  test(
    'sealed relay recovery keeps one grant and one connection owner',
    () async {
      await pair.close();
      final alice = await DeviceIdentity.fromSeed(List<int>.filled(32, 11));
      final bob = await DeviceIdentity.fromSeed(List<int>.filled(32, 12));
      pair = await _Pair.create(
        initiatorKey: alice.publicKey.bytes,
        receiverKey: bob.publicKey.bytes,
      );
      final grant = pair.a.grant!;
      final transportOwner = pair.b.operationTransport({SessionOperation.file});
      await pair.lose();
      final relay = _RelayTransport([alice, bob]);
      final client = RelayServiceClient(relay);
      final ca = await client.open(
        pair.a.grant!,
        alice,
        cancellation: AuxiliaryCancellation(),
        generation: 2,
      );
      final cb = await client.open(
        pair.b.grant!,
        bob,
        cancellation: AuxiliaryCancellation(),
        generation: 2,
      );
      await Future.wait([
        pair.left.reconnectVia(pair.a, (_) => pair.a.openRelayWire(ca)),
        pair.right.acceptVia(pair.b, (_) => pair.b.openRelayWire(cb)),
      ]).timeout(const Duration(seconds: 5));
      expect(pair.a.grant, same(grant));
      expect(pair.a.phase, ConnectionPhase.active);
      expect(pair.b.phase, ConnectionPhase.active);
      expect(pair.a.sessionId, pair.b.sessionId);
      expect(
        pair.b.operationTransport({SessionOperation.file}),
        same(transportOwner),
      );
      expect(relay.forwarded, greaterThan(0));
    },
  );

  test('relay room for an old generation cannot start recovery', () async {
    await pair.close();
    final alice = await DeviceIdentity.fromSeed(List<int>.filled(32, 11));
    final bob = await DeviceIdentity.fromSeed(List<int>.filled(32, 12));
    pair = await _Pair.create(
      initiatorKey: alice.publicKey.bytes,
      receiverKey: bob.publicKey.bytes,
    );
    await pair.lose();
    final channel = await RelayServiceClient(_RelayTransport([alice, bob]))
        .open(
          pair.a.grant!,
          alice,
          cancellation: AuxiliaryCancellation(),
          generation: pair.a.grant!.generation,
        );
    await expectLater(
      pair.a.openRelayWire(channel),
      throwsA(
        isA<ConnectionFailure>().having(
          (error) => error.code,
          'code',
          'invalid_relay_claim',
        ),
      ),
    );
    expect(pair.a.phase, ConnectionPhase.suspended);
    expect(pair.a.grant!.generation, 1);
    expect(channel.closed, isTrue);
  });

  test('late caller-provided wire is closed after candidate timeout', () async {
    await pair.close();
    pair = await _Pair.create(timeout: const Duration(milliseconds: 150));
    await pair.lose();
    final gate = Completer<ConnectionWire>();
    AuxiliaryCancellation? opening;
    final attempted = pair.left.reconnectVia(pair.a, (cancellation) {
      opening = cancellation;
      return gate.future;
    });
    await expectLater(attempted, throwsA(isA<ConnectionFailure>()));
    expect(opening!.isCancelled, isTrue);
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;
    final late = WireChannel(await Socket.connect('127.0.0.1', server.port));
    final peer = WireChannel(await accepted);
    await server.close();
    pair.wires.addAll([late, peer]);
    gate.complete(late);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(late.isClosed, isTrue);
    expect(pair.a.phase, ConnectionPhase.suspended);
    expect(pair.a.grant!.phase, GrantPhase.suspended);
  });

  test(
    'receiver waiting for relay room is cancelled at candidate deadline',
    () async {
      await pair.close();
      pair = await _Pair.create(timeout: const Duration(milliseconds: 150));
      await pair.lose();
      final gate = Completer<ConnectionWire>();
      AuxiliaryCancellation? opening;
      final attempted = pair.right.acceptVia(pair.b, (cancellation) {
        opening = cancellation;
        return gate.future;
      });
      await expectLater(attempted, throwsA(isA<ConnectionFailure>()));
      expect(opening!.isCancelled, isTrue);
      expect(pair.b.phase, ConnectionPhase.suspended);
      expect(pair.b.grant!.phase, GrantPhase.suspended);
      expect(pair.right.pendingCount, 0);
    },
  );

  test(
    'forged and stalled proofs cannot suspend an active original grant',
    () async {
      final wire = await pair.candidate();
      final offer = await pair.ca.begin();
      wire.send(offer.message);
      await wire.next(); // Valid hello alone is not mutual proof.
      expect(pair.b.isConnected, isTrue);
      expect(pair.b.grant!.generation, 1);
      wire.send({
        'type': 'recover-proof',
        'v': 1,
        'proof': encodeBytes(List.filled(32, 0)),
      });
      await expectLater(wire.next(), throwsA(isA<ConnectionFailure>()));
      expect(pair.b.isConnected, isTrue);
      expect(pair.b.grant!.phase, GrantPhase.active);
      expect(await pair.b.check(), isTrue);
    },
  );

  test('concurrent local reconnect calls share one attempt', () async {
    await pair.lose();
    final first = pair.left.reconnect(pair.a);
    final second = pair.left.reconnect(pair.a);
    expect(second, same(first));
    await Future.wait([first, second]);
    expect(pair.a.grant!.generation, 2);
  });

  test(
    'a second authenticated candidate cannot replace a reserved recovery',
    () async {
      final first = await pair.authenticate();
      expect(pair.b.phase, ConnectionPhase.recovering);
      final second = await pair.candidate();
      final offer = await pair.ca.begin();
      second.send(offer.message);
      final proof = await offer.answer(await second.next());
      second.send(proof.message);
      final cipher = await proof.material.open(second);
      await expectLater(cipher.next(), throwsA(isA<ConnectionFailure>()));
      expect(pair.b.phase, ConnectionPhase.recovering);
      expect(pair.b.grant!.generation, 1);
      final suspended = pair.b.phaseChanges.firstWhere(
        (p) => p == ConnectionPhase.suspended,
      );
      first.wire.close();
      await suspended.timeout(const Duration(seconds: 2));
      final active = pair.b.phaseChanges.firstWhere(
        (p) => p == ConnectionPhase.active,
      );
      await pair.left.reconnect(pair.a);
      await active.timeout(const Duration(seconds: 2));
    },
  );

  test(
    'inner activation cannot publish business traffic before ready',
    () async {
      await pair.close();
      pair = await _Pair.create(timeout: const Duration(milliseconds: 350));
      final cipher = await pair.authenticate();
      if (pair.a.phase != ConnectionPhase.suspended) {
        await pair.a.phaseChanges
            .firstWhere((p) => p == ConnectionPhase.suspended)
            .timeout(const Duration(seconds: 2));
      }
      final hello = await pair.a.grant!.beginResume();
      await cipher.send({
        'type': 'grant-hello',
        'generation': hello.generation,
        'challenge': encodeBytes(hello.challenge),
      });
      final response = await cipher.next();
      final finish = await pair.a.grant!.finishResume(
        ResumeResponse(
          hello,
          decodeBytes(response['challenge'], 32),
          decodeBytes(response['proof'], 32),
        ),
      );
      await cipher.send({
        'type': 'grant-finish',
        'proof': encodeBytes(finish.proof),
      });
      expect((await cipher.next())['type'], 'grant-active');
      expect(pair.b.grant!.phase, GrantPhase.active);
      expect(pair.b.isConnected, isFalse);
      await expectLater(
        pair.b.createRequest(SessionOperation.file, 'too-early', ''),
        throwsA(isA<ConnectionFailure>()),
      );
      // Losing the final ready cannot leave an active inner grant usable.
      await expectLater(cipher.next(), throwsA(isA<ConnectionFailure>()));
      expect(pair.b.grant!.phase, GrantPhase.suspended);
      pair.a.grant!.suspend();
      final active = pair.b.phaseChanges.firstWhere(
        (p) => p == ConnectionPhase.active,
      );
      await pair.left.reconnect(pair.a);
      await active.timeout(const Duration(seconds: 2));
      expect(pair.a.grant!.generation, 3);
      expect(pair.b.grant!.generation, 3);
    },
  );

  test(
    'shutdown during local clock audit rejects its late completion',
    () async {
      await pair.lose();
      pair.clockGate = Completer<int>();
      final attempting = pair.left.reconnect(pair.a);
      final failed = expectLater(attempting, throwsA(isA<ConnectionFailure>()));
      await pair.clockEntered.future;
      await pair.left.close();
      await failed;
      expect(pair.left.pendingCount, 0);
      pair.clockGate!.complete(100);
      await Future<void>.delayed(Duration.zero);
      expect(pair.a.phase, ConnectionPhase.closed);
      expect(pair.a.grant!.phase, GrantPhase.revoked);
    },
  );

  test('large business frame survives the receiver ready publication gap', () async {
    await pair.lose();
    final received = Completer<VerifiedSessionMessage>();
    pair.b
        .operationTransport({SessionOperation.file})
        .attachReceiver(
          onRequest: received.complete,
          resolveSession: (_) => null,
          onSignal: (_) {},
        );
    final cipher = await pair.authenticate();
    final hello = await pair.a.grant!.beginResume();
    await cipher.send({
      'type': 'grant-hello',
      'generation': hello.generation,
      'challenge': encodeBytes(hello.challenge),
    });
    final response = await cipher.next();
    final finish = await pair.a.grant!.finishResume(
      ResumeResponse(
        hello,
        decodeBytes(response['challenge'], 32),
        decodeBytes(response['proof'], 32),
      ),
    );
    await cipher.send({
      'type': 'grant-finish',
      'proof': encodeBytes(finish.proof),
    });
    expect((await cipher.next())['type'], 'grant-active');
    final payload = 'x' * 12000;
    final request = await pair.a.grant!.authorizeLocal(
      SessionOperation.file,
      'large-after-ready',
      payload,
    );
    final packet = await pair.a.grant!.sealRequest(request);
    // Hold receiver publication after proof activation. A real initiator can
    // already publish after sending ready and immediately transmit large data.
    pair.clockGate = Completer<int>();
    cipher.enableSessionFrames();
    await cipher.send({
      'type': 'recover-ready',
      'generation': hello.generation,
    });
    await pair.clockEntered.future;
    await cipher.send({
      'type': 'operation-request',
      'packet': {
        'generation': packet.generation,
        'sequence': packet.sequence,
        'ciphertext': encodeBytes(packet.ciphertext),
        'mac': encodeBytes(packet.mac),
      },
    });
    // The receiver cannot deliver or reply while its clock is held, but it
    // must keep the wire open while accepting this bounded authenticated frame.
    await cipher.wire.next().timeout(
      const Duration(milliseconds: 100),
      onTimeout: () => <String, dynamic>{},
    );
    expect(received.isCompleted, isFalse);
    expect(pair.b.isConnected, isFalse);
    pair.clockGate!.complete(100);
    expect(
      (await received.future.timeout(const Duration(seconds: 2))).body,
      payload,
    );
    expect(pair.b.isConnected, isTrue);
  });

  test(
    'shutdown while accepting inner proof cannot activate a late result',
    () async {
      await pair.lose();
      final cipher = await pair.authenticate();
      final hello = await pair.a.grant!.beginResume();
      await cipher.send({
        'type': 'grant-hello',
        'generation': hello.generation,
        'challenge': encodeBytes(hello.challenge),
      });
      final response = await cipher.next();
      final finish = await pair.a.grant!.finishResume(
        ResumeResponse(
          hello,
          decodeBytes(response['challenge'], 32),
          decodeBytes(response['proof'], 32),
        ),
      );
      pair.clockGate = Completer<int>();
      await cipher.send({
        'type': 'grant-finish',
        'proof': encodeBytes(finish.proof),
      });
      await pair.clockEntered.future;
      final ended = expectLater(
        cipher.next(),
        throwsA(isA<ConnectionFailure>()),
      );
      await pair.right.close();
      await ended;
      expect(pair.right.pendingCount, 0);
      pair.clockGate!.complete(100);
      await Future<void>.delayed(Duration.zero);
      expect(pair.b.phase, ConnectionPhase.closed);
      expect(pair.b.grant!.phase, GrantPhase.revoked);
    },
  );

  test('unauthenticated timeout leaves the active grant usable', () async {
    await pair.close();
    pair = await _Pair.create(timeout: const Duration(milliseconds: 100));
    final wire = await pair.candidate();
    wire.send((await pair.ca.begin()).message);
    await wire.next();
    await expectLater(wire.next(), throwsA(isA<ConnectionFailure>()));
    expect(pair.right.pendingCount, 0);
    expect(pair.b.isConnected, isTrue);
    expect(pair.b.grant!.generation, 1);
    expect(await pair.b.check(), isTrue);
  });

  test(
    'registration bounds original records without revoking rejected owners',
    () async {
      final extra = <_Pair>[];
      try {
        for (var id = 2; id <= 9; id++) {
          final next = await _Pair.create(id: id, registerLeft: false);
          extra.add(next);
          void register() => pair.left.register(
            next.a,
            next.ha,
            next.ca,
            address: InternetAddress.loopbackIPv4,
            port: next.right.port,
          );
          if (id <= 8) {
            register();
          } else {
            expect(register, throwsA(isA<ConnectionFailure>()));
            expect(next.a.isConnected, isTrue);
            await next.ca
                .begin(); // A rejected registration did not take ownership.
          }
        }
        expect(pair.left.registeredCount, 8);
        await pair.left.close();
        for (final next in extra.take(7)) {
          expect(next.a.isClosed, isTrue);
        }
        expect(extra.last.a.isClosed, isFalse);
      } finally {
        for (final next in extra) {
          await next.close();
          next.ca.dispose();
        }
      }
    },
  );

  test(
    'original local expiry refuses recovery and removes the record',
    () async {
      await pair.lose();
      pair.now = 100 + grantLifetime.inMicroseconds;
      await expectLater(
        pair.left.reconnect(pair.a),
        throwsA(isA<ConnectionFailure>()),
      );
      expect(pair.a.isClosed, isTrue);
      expect(pair.a.grant!.phase, GrantPhase.revoked);
      await Future<void>.delayed(Duration.zero);
      expect(pair.left.registeredCount, 0);
    },
  );

  test(
    'closing the service revokes its owners and rejects future recovery',
    () async {
      await pair.lose();
      await pair.left.close();
      expect(pair.a.isClosed, isTrue);
      expect(pair.left.registeredCount, 0);
      expect(pair.left.pendingCount, 0);
      await expectLater(
        pair.left.reconnect(pair.a),
        throwsA(isA<ConnectionFailure>()),
      );
      await expectLater(pair.left.open(), throwsA(isA<ConnectionFailure>()));
    },
  );

  test(
    'listener admits at most four candidates and closes them on shutdown',
    () async {
      final candidates = <WireChannel>[];
      for (var i = 0; i < 4; i++) {
        final wire = await pair.candidate();
        wire.send((await pair.ca.begin()).message);
        await wire.next();
        candidates.add(wire);
      }
      expect(pair.right.pendingCount, 4);
      final fifth = await pair.candidate();
      await expectLater(fifth.next(), throwsA(isA<ConnectionFailure>()));
      expect(pair.right.pendingCount, 4);
      final ended = candidates
          .map((w) => expectLater(w.next(), throwsA(isA<ConnectionFailure>())))
          .toList();
      await pair.right.close();
      await Future.wait(ended);
      expect(pair.right.pendingCount, 0);
    },
  );

  test(
    'authenticated candidate timeout releases only its reservation',
    () async {
      await pair.close();
      pair = await _Pair.create(timeout: const Duration(milliseconds: 180));
      final wire = await pair.candidate();
      final offer = await pair.ca.begin();
      wire.send(offer.message);
      final proof = await offer.answer(await wire.next());
      wire.send(proof.message);
      final cipher = await proof.material.open(wire);
      expect((await cipher.next())['type'], 'recover-authenticated');
      expect(pair.b.phase, ConnectionPhase.recovering);
      await expectLater(cipher.next(), throwsA(isA<ConnectionFailure>()));
      expect(pair.b.phase, ConnectionPhase.suspended);
      expect(pair.b.grant!.phase, GrantPhase.suspended);
      final active = pair.b.phaseChanges.firstWhere(
        (p) => p == ConnectionPhase.active,
      );
      await pair.left.reconnect(pair.a);
      await active.timeout(const Duration(seconds: 2));
    },
  );
}

class _Pair {
  late TrustedConnection a, b;
  late RecoveryCredentials ca, cb;
  late ConnectionRecoveryService left, right;
  late CipherChannel oldA;
  late ConnectionRecoveryHandle ha;
  final wires = <WireChannel>[];
  int now = 100;
  Completer<int>? clockGate;
  final clockEntered = Completer<void>();
  Future<int> clock() async {
    if (clockGate != null) {
      if (!clockEntered.isCompleted) clockEntered.complete();
      return clockGate!.future;
    }
    return now;
  }

  static Future<_Pair> create({
    Duration timeout = const Duration(seconds: 30),
    int id = 1,
    bool registerLeft = true,
    List<int>? initiatorKey,
    List<int>? receiverKey,
  }) async {
    final p = _Pair();
    p.left = ConnectionRecoveryService(handshakeTimeout: timeout);
    p.right = ConnectionRecoveryService(handshakeTimeout: timeout);
    await p.right.open(address: InternetAddress.loopbackIPv4);
    final binding = GrantBinding(
      id: List.filled(32, id),
      initiatorKey: initiatorKey ?? List.filled(32, 2),
      receiverKey: receiverKey ?? List.filled(32, 3),
    );
    GrantEndpoint grant(GrantRole role) =>
        GrantEndpoint.fromAuthenticatedPairing(
          binding: binding,
          role: role,
          establishedMicros: 100,
          recoverySecret: List.filled(32, 4),
          clock: p.clock,
          onInvalidated: () {},
        );
    final ga = grant(GrantRole.initiator), gb = grant(GrantRole.receiver);
    final hello = await ga.beginResume();
    final response = await gb.answerResume(hello);
    await gb.acceptResume(await ga.finishResume(response));
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;
    final wa = WireChannel(await Socket.connect('127.0.0.1', server.port));
    final wb = WireChannel(await accepted);
    await server.close();
    p.wires.addAll([wa, wb]);
    final a = p.oldA = await CipherChannel.create(wa, List.filled(32, 5), [
      1,
      2,
    ], host: false);
    final b = await CipherChannel.create(wb, List.filled(32, 5), [
      1,
      2,
    ], host: true);
    a.enableSessionFrames();
    b.enableSessionFrames();
    final ha = p.ha = ConnectionRecoveryHandle(),
        hb = ConnectionRecoveryHandle();
    p.a = TrustedConnection(
      a,
      encodeBytes(binding.receiverKey),
      SessionLease(startedMicros: 100),
      p.clock,
      grant: ga,
      recovery: ha,
    );
    p.b = TrustedConnection(
      b,
      encodeBytes(binding.initiatorKey),
      SessionLease(startedMicros: 100),
      p.clock,
      grant: gb,
      recovery: hb,
    );
    Future<RecoveryCredentials> credentials(GrantRole role) =>
        RecoveryCredentials.fromPairing(
          binding: binding,
          role: role,
          pairingKey: List.filled(32, 6),
          pairingTranscript: [7, 8],
        );
    p.ca = await credentials(GrantRole.initiator);
    p.cb = await credentials(GrantRole.receiver);
    if (registerLeft) {
      p.left.register(
        p.a,
        ha,
        p.ca,
        address: InternetAddress.loopbackIPv4,
        port: p.right.port,
      );
    }
    p.right.register(p.b, hb, p.cb);
    p.a.startMonitoring();
    p.b.startMonitoring();
    return p;
  }

  Future<WireChannel> candidate() async {
    final wire = WireChannel(await Socket.connect('127.0.0.1', right.port!));
    wires.add(wire);
    return wire;
  }

  Future<CipherChannel> authenticate() async {
    final wire = await candidate();
    final offer = await ca.begin();
    wire.send(offer.message);
    final proof = await offer.answer(await wire.next());
    wire.send(proof.message);
    final cipher = await proof.material.open(wire);
    expect((await cipher.next())['type'], 'recover-authenticated');
    return cipher;
  }

  Future<void> lose() async {
    final phases = [a, b]
        .map(
          (c) =>
              c.phaseChanges.firstWhere((p) => p == ConnectionPhase.suspended),
        )
        .toList();
    oldA.wire.close();
    await Future.wait(phases).timeout(const Duration(seconds: 2));
  }

  Future<void> close() async {
    if (clockGate != null && !clockGate!.isCompleted) clockGate!.complete(now);
    a.close();
    b.close();
    await left.close();
    await right.close();
    for (final wire in wires) {
      wire.close();
    }
  }
}

final class _RelayTransport implements AuxiliaryTransport {
  _RelayTransport(this.identities);
  final List<DeviceIdentity> identities;
  final joined = <String, String>{};
  final queues = <String, List<String>>{};
  final nonce = base64Url.encode(List<int>.generate(32, (i) => i + 32));
  int forwarded = 0;

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  ) async {
    cancellation.throwIfCancelled();
    if (path == '/v1/aux/challenge' || path == '/v1/signal/challenge') {
      return path == '/v1/aux/challenge'
          ? {'nonce': nonce, 'expiresAt': 1}
          : {'nonce': nonce};
    }
    if (path == '/v1/devices/register') {
      final identity = identities.singleWhere(
        (item) => item.encodedKey == body['publicKey'],
      );
      return {'deviceId': identity.id};
    }
    if (path == '/v1/signal/join') {
      final claim = RelayRoomClaim.decode(body['claim']!);
      expect(
        await claim.verifyJoin(
          body['sender']!,
          body['signature'],
          base64Url.decode(nonce),
        ),
        isTrue,
      );
      final index = identities.indexWhere(
        (identity) => identity.encodedKey == body['sender'],
      );
      final token = base64Url.encode(List<int>.filled(32, index + 5));
      joined[token] = body['sender']!;
      queues[token] = [];
      return {
        'room': base64Url.encode(claim.roomId),
        'token': token,
        'ready': joined.length == 2,
      };
    }
    if (path == '/v1/signal/send') {
      final envelope = RelaySignalEnvelope.decode(body['wire']!);
      expect(base64Url.encode(envelope.sender), joined[body['token']]);
      final recipient = joined.keys.singleWhere(
        (token) => token != body['token'],
      );
      queues[recipient]!.add(body['wire']!);
      forwarded++;
      return {'accepted': true};
    }
    if (path == '/v1/signal/poll') {
      final queued = queues[body['token']]!;
      if (queued.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      cancellation.throwIfCancelled();
      return {
        'ready': joined.length == 2,
        'wire': queued.isEmpty ? '' : queued.removeAt(0),
      };
    }
    if (path == '/v1/signal/leave') {
      joined.clear();
      queues.clear();
      return {'closed': true};
    }
    throw StateError(path);
  }
}
