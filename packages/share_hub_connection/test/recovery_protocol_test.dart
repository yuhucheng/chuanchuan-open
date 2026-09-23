import 'dart:convert';
import 'dart:io';

import 'package:share_hub_connection/src/channel.dart';
import 'package:share_hub_connection/src/identity.dart';
import 'package:share_hub_connection/src/recovery_protocol.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

void main() {
  final credentials = <RecoveryCredentials>[];
  final wires = <WireChannel>[];
  late RecoveryCredentials initiator, receiver;
  GrantBinding binding({
    int id = 1,
    int sender = 2,
    int target = 3,
    GrantPolicy policy = GrantPolicy.shortCode,
  }) => GrantBinding(
    id: List.filled(32, id),
    initiatorKey: List.filled(32, sender),
    receiverKey: List.filled(32, target),
    policy: policy,
  );
  Future<RecoveryCredentials> make(
    GrantRole role, {
    GrantBinding? grant,
    int key = 7,
    String transcript = 'pairing transcript',
  }) async {
    final result = await RecoveryCredentials.fromPairing(
      binding: grant ?? binding(),
      role: role,
      pairingKey: List.filled(32, key),
      pairingTranscript: utf8.encode(transcript),
    );
    credentials.add(result);
    return result;
  }

  Future<(WireChannel, WireChannel)> wirePair() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;
    final left = WireChannel(await Socket.connect('127.0.0.1', server.port));
    final right = WireChannel(await accepted);
    await server.close();
    wires.addAll([left, right]);
    return (left, right);
  }

  Future<(RecoveryCipherMaterial, RecoveryCipherMaterial)> exchange() async {
    final offer = await initiator.begin();
    final challenge = await receiver.acceptHello(
      RecoveryHello.parse(offer.message),
    );
    final proof = await offer.answer(challenge.message);
    return (proof.material, await challenge.accept(proof.message));
  }

  setUp(() async {
    initiator = await make(GrantRole.initiator);
    receiver = await make(GrantRole.receiver);
  });
  tearDown(() {
    for (final value in credentials) {
      value.dispose();
    }
    credentials.clear();
    for (final wire in wires) {
      wire.close();
    }
    wires.clear();
  });

  // Independently generated using Python stdlib RFC5869 HKDF/HMAC, not the
  // implementation under test: pairing key=7*32, transcript UTF8 above, ci=9*32.
  final knownHello = <String, dynamic>{
    'type': 'recover-hello',
    'v': 1,
    'grantId': 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=',
    'ci': 'CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk=',
    'proof': 'XVO-XAtKg3En8L4cmrsJkV8pLmGduMtoGlEc9u6uDwM=',
  };
  test(
    'independent hello vector binds the specified exporter and context',
    () async {
      final challenge = await receiver.acceptHello(
        RecoveryHello.parse(knownHello),
      );
      expect(challenge.message['ci'], knownHello['ci']);
      expect(decodeBytes(challenge.message['cr'], 32), hasLength(32));
    },
  );

  test(
    'mutual proofs produce fresh direction-bound ciphers over real TCP',
    () async {
      final keys = await exchange();
      final wire = await wirePair();
      final a = await keys.$1.open(wire.$1), b = await keys.$2.open(wire.$2);
      expect(a.sessionId, b.sessionId);
      await a.send({'type': 'test', 'direction': 'to-receiver'});
      expect((await b.next())['direction'], 'to-receiver');
      await b.send({'type': 'test', 'direction': 'to-initiator'});
      expect((await a.next())['direction'], 'to-initiator');
      final next = await exchange();
      final nextWire = await wirePair();
      final newer = await next.$1.open(nextWire.$1);
      expect(newer.sessionId, isNot(a.sessionId));
    },
  );

  test('a forged hello does not consume the original credential', () async {
    final forged = {...knownHello, 'proof': encodeBytes(List.filled(32, 0))};
    await expectLater(
      receiver.acceptHello(RecoveryHello.parse(forged)),
      throwsA(isA<ConnectionFailure>()),
    );
    await receiver.acceptHello(RecoveryHello.parse(knownHello));
  });

  test('a captured old cipher frame cannot enter a fresh recovery', () async {
    final previous = await exchange();
    final oldWire = await wirePair();
    final sender = await previous.$1.open(oldWire.$1);
    await sender.send({'type': 'test', 'payload': 'old-operation'});
    final captured = await oldWire.$2.next();
    final current = await exchange();
    final newWire = await wirePair();
    final receiver = await current.$2.open(newWire.$2);
    newWire.$1.send(captured);
    await expectLater(receiver.next(), throwsA(isA<ConnectionFailure>()));
  });

  for (final variant in [
    ('grant id', () => binding(id: 8)),
    ('initiator identity', () => binding(sender: 8)),
    ('receiver identity', () => binding(target: 8)),
    (
      'policy type',
      () => binding(
        policy: const GrantPolicy(type: 'different', lifetime: grantLifetime),
      ),
    ),
    (
      'policy lifetime',
      () => binding(
        policy: const GrantPolicy(
          type: 'short-code',
          lifetime: Duration(hours: 7),
        ),
      ),
    ),
  ]) {
    test('hello cannot move to another ${variant.$1}', () async {
      final other = await make(GrantRole.receiver, grant: variant.$2());
      await expectLater(
        other.acceptHello(RecoveryHello.parse(knownHello)),
        throwsA(isA<ConnectionFailure>()),
      );
    });
  }
  test('a different PAKE key or transcript cannot authenticate', () async {
    for (final other in [
      await make(GrantRole.receiver, key: 8),
      await make(GrantRole.receiver, transcript: 'other transcript'),
    ]) {
      await expectLater(
        other.acceptHello(RecoveryHello.parse(knownHello)),
        throwsA(isA<ConnectionFailure>()),
      );
    }
  });

  test(
    'replaying a hello produces a fresh challenge that rejects the old proof',
    () async {
      final offer = await initiator.begin();
      final hello = RecoveryHello.parse(offer.message);
      final first = await receiver.acceptHello(hello);
      final second = await receiver.acceptHello(hello);
      expect(second.message['cr'], isNot(first.message['cr']));
      final proof = await offer.answer(first.message);
      await first.accept(proof.message);
      await expectLater(
        second.accept(proof.message),
        throwsA(isA<ConnectionFailure>()),
      );
      await expectLater(
        first.accept(proof.message),
        throwsA(isA<ConnectionFailure>()),
      );
    },
  );

  test(
    'a challenge for another candidate cannot answer the current offer',
    () async {
      final one = await initiator.begin(), two = await initiator.begin();
      final challenge = await receiver.acceptHello(
        RecoveryHello.parse(one.message),
      );
      await expectLater(
        two.answer(challenge.message),
        throwsA(isA<ConnectionFailure>()),
      );
    },
  );

  test('receiver proof cannot be reflected as the initiator proof', () async {
    final offer = await initiator.begin();
    final challenge = await receiver.acceptHello(
      RecoveryHello.parse(offer.message),
    );
    await expectLater(
      challenge.accept({
        'type': 'recover-proof',
        'v': 1,
        'proof': challenge.message['proof'],
      }),
      throwsA(isA<ConnectionFailure>()),
    );
  });

  test(
    'one candidate cannot answer concurrent challenge calls twice',
    () async {
      final offer = await initiator.begin();
      final challenge = await receiver.acceptHello(
        RecoveryHello.parse(offer.message),
      );
      final first = offer.answer(challenge.message);
      await expectLater(
        offer.answer(challenge.message),
        throwsA(isA<ConnectionFailure>()),
      );
      await first;
    },
  );

  test(
    'disposing credentials during proof verification rejects the late result',
    () async {
      final offer = await initiator.begin();
      final challenge = await receiver.acceptHello(
        RecoveryHello.parse(offer.message),
      );
      final pending = offer.answer(challenge.message);
      initiator.dispose();
      await expectLater(pending, throwsA(isA<ConnectionFailure>()));
      await expectLater(initiator.begin(), throwsA(isA<ConnectionFailure>()));
    },
  );

  test(
    'cancelled candidates cannot consume proofs but new candidates still work',
    () async {
      final offer = await initiator.begin();
      final challenge = await receiver.acceptHello(
        RecoveryHello.parse(offer.message),
      );
      offer.cancel();
      await expectLater(
        offer.answer(challenge.message),
        throwsA(isA<ConnectionFailure>()),
      );
      challenge.cancel();
      await expectLater(
        challenge.accept({
          'type': 'recover-proof',
          'v': 1,
          'proof': knownHello['proof'],
        }),
        throwsA(isA<ConnectionFailure>()),
      );
      await exchange();
    },
  );

  test(
    'disposed cipher material rejects and closes its candidate wire',
    () async {
      final keys = await exchange();
      final wire = await wirePair();
      keys.$1.cancel();
      await expectLater(
        keys.$1.open(wire.$1),
        throwsA(isA<ConnectionFailure>()),
      );
      await expectLater(wire.$1.next(), throwsA(isA<ConnectionFailure>()));
    },
  );

  test('wrong local roles cannot initiate or accept a hello', () async {
    await expectLater(receiver.begin(), throwsA(isA<ConnectionFailure>()));
    await expectLater(
      initiator.acceptHello(RecoveryHello.parse(knownHello)),
      throwsA(isA<ConnectionFailure>()),
    );
  });

  test('duplicate opens cannot close the original candidate wire', () async {
    final keys = await exchange();
    final wire = await wirePair();
    final first = keys.$1.open(wire.$1);
    await expectLater(keys.$1.open(wire.$1), throwsA(isA<ConnectionFailure>()));
    final sender = await first;
    final receiver = await keys.$2.open(wire.$2);
    await sender.send({'type': 'test', 'stage': 'concurrent'});
    expect((await receiver.next())['stage'], 'concurrent');
    await expectLater(keys.$1.open(wire.$1), throwsA(isA<ConnectionFailure>()));
    await sender.send({'type': 'test', 'stage': 'published'});
    expect((await receiver.next())['stage'], 'published');

    final extra = await wirePair();
    await expectLater(
      keys.$1.open(extra.$1),
      throwsA(isA<ConnectionFailure>()),
    );
    await expectLater(extra.$1.next(), throwsA(isA<ConnectionFailure>()));
    await sender.send({'type': 'test', 'stage': 'different-wire'});
    expect((await receiver.next())['stage'], 'different-wire');
  });

  test('cancelling while opening rejects and closes the candidate', () async {
    final keys = await exchange();
    final wire = await wirePair();
    final pending = keys.$1.open(wire.$1);
    keys.$1.cancel();
    await expectLater(pending, throwsA(isA<ConnectionFailure>()));
    await expectLater(wire.$1.next(), throwsA(isA<ConnectionFailure>()));
    await exchange();
  });

  for (final stage in ['challenge', 'proof']) {
    for (final invalid in [
      'version',
      'extra-field',
      'short-proof',
      'forged-proof',
    ]) {
      test(
        'strict $stage rejects $invalid and consumes only its candidate',
        () async {
          final offer = await initiator.begin();
          final challenge = await receiver.acceptHello(
            RecoveryHello.parse(offer.message),
          );
          final proof = stage == 'proof'
              ? await offer.answer(challenge.message)
              : null;
          final original = proof?.message ?? challenge.message;
          final malformed = {...original};
          switch (invalid) {
            case 'version':
              malformed['v'] = 1.0;
            case 'extra-field':
              malformed['expiresMicros'] = 9999999999;
            case 'short-proof':
              malformed['proof'] = encodeBytes([1]);
            case 'forged-proof':
              malformed['proof'] = encodeBytes(List.filled(32, 0));
          }
          Future<Object> attempt(Map<String, dynamic> value) =>
              stage == 'proof' ? challenge.accept(value) : offer.answer(value);
          await expectLater(
            attempt(malformed),
            throwsA(isA<ConnectionFailure>()),
          );
          await expectLater(
            attempt(original),
            throwsA(isA<ConnectionFailure>()),
          );
          await exchange();
        },
      );
    }
  }

  for (final entry in <String, Map<String, dynamic>>{
    'unknown version': {...knownHello, 'v': 2},
    'noninteger version': {...knownHello, 'v': 1.0},
    'extra authority': {...knownHello, 'expiresMicros': 9999999999},
    'wrong type': {...knownHello, 'type': 'recover-proof'},
    'bad nonce type': {...knownHello, 'ci': 32},
    'noncanonical encoding': {
      ...knownHello,
      'ci': (knownHello['ci'] as String).replaceAll('=', ''),
    },
    'short MAC': {
      ...knownHello,
      'proof': encodeBytes([1]),
    },
    'oversized field': {...knownHello, 'ci': 'x' * 9000},
  }.entries) {
    test('strict hello rejects ${entry.key}', () {
      expect(
        () => RecoveryHello.parse(entry.value),
        throwsA(isA<ConnectionFailure>()),
      );
    });
  }
}
