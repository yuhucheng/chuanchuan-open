import 'dart:async';
import 'dart:convert';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

List<int> _encodeSealed(SessionEnvelope envelope) => utf8.encode(
  jsonEncode([
    envelope.generation,
    envelope.sequence,
    base64Url.encode(envelope.ciphertext),
    base64Url.encode(envelope.mac),
  ]),
);

SessionEnvelope _decodeSealed(List<int> bytes) {
  final values = jsonDecode(utf8.decode(bytes)) as List<dynamic>;
  return SessionEnvelope(
    generation: values[0] as int,
    sequence: values[1] as int,
    ciphertext: base64Url.decode(values[2] as String),
    mac: base64Url.decode(values[3] as String),
  );
}

final class _RelayTransport implements AuxiliaryTransport {
  _RelayTransport(this.identities);
  final List<DeviceIdentity> identities;
  final joined = <String, String>{};
  final queue = <String, List<String>>{};
  final nonce = base64Url.encode(List<int>.generate(32, (i) => i + 32));
  Completer<void>? joinGate;
  int forwarded = 0;

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  ) async {
    cancellation.throwIfCancelled();
    if (path == '/v1/aux/challenge') {
      return {'nonce': nonce, 'expiresAt': 1};
    }
    if (path == '/v1/devices/register') {
      final identity = identities.singleWhere(
        (item) => item.encodedKey == body['publicKey'],
      );
      return {'deviceId': identity.id};
    }
    if (path == '/v1/signal/challenge') return {'nonce': nonce};
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
        (item) => item.encodedKey == body['sender'],
      );
      final token = base64Url.encode(List<int>.filled(32, index + 5));
      joined[token] = body['sender']!;
      queue[token] = [];
      if (joinGate case final gate?) await gate.future;
      return {
        'room': base64Url.encode(claim.roomId),
        'token': token,
        'ready': joined.length == 2,
      };
    }
    if (path == '/v1/signal/send') {
      final sender = joined[body['token']];
      final envelope = RelaySignalEnvelope.decode(body['wire']!);
      expect(base64Url.encode(envelope.sender), sender);
      final recipient = joined.keys.singleWhere(
        (token) => token != body['token'],
      );
      queue[recipient]!.add(body['wire']!);
      forwarded++;
      return {'accepted': true};
    }
    if (path == '/v1/signal/poll') {
      final pending = queue[body['token']]!;
      return {
        'ready': joined.length == 2,
        'wire': pending.isEmpty ? '' : pending.removeAt(0),
      };
    }
    if (path == '/v1/signal/leave') {
      joined.remove(body['token']);
      return {'closed': true};
    }
    throw StateError(path);
  }
}

void main() {
  test(
    'relay carries only sealed request between two live grant endpoints',
    () async {
      final alice = await DeviceIdentity.fromSeed(List<int>.filled(32, 1));
      final bob = await DeviceIdentity.fromSeed(List<int>.filled(32, 2));
      final binding = GrantBinding(
        id: List<int>.filled(32, 3),
        initiatorKey: alice.publicKey.bytes,
        receiverKey: bob.publicKey.bytes,
      );
      GrantEndpoint endpoint(GrantRole role) =>
          GrantEndpoint.fromAuthenticatedPairing(
            binding: binding,
            role: role,
            establishedMicros: 0,
            recoverySecret: List<int>.filled(32, 4),
            clock: () async => 0,
            onInvalidated: () {},
          );
      final a = endpoint(GrantRole.initiator), b = endpoint(GrantRole.receiver);
      await b.acceptResume(
        await a.finishResume(await b.answerResume(await a.beginResume())),
      );
      final transport = _RelayTransport([alice, bob]);
      final client = RelayServiceClient(transport);
      final ca = await client.open(
        a,
        alice,
        cancellation: AuxiliaryCancellation(),
      );
      final cb = await client.open(
        b,
        bob,
        cancellation: AuxiliaryCancellation(),
      );
      final local = await a.authorizeLocal(
        SessionOperation.watch,
        'watch-1',
        '',
      );
      final sealed = await a.sealRequest(local);
      await ca.sendSealed(_encodeSealed(sealed));
      final received = await cb.receive();
      expect(received, isNotNull);
      expect(
        (await b.open(_decodeSealed(received!.payload))).operation,
        SessionOperation.watch,
      );
      expect(transport.forwarded, 1);
      await ca.cancel();
      expect((await cb.receive())!.kind, RelaySignalKind.cancel);
      expect(cb.closed, isTrue);
      a.revoke();
      await expectLater(ca.sendSealed([1]), throwsA(isA<AuxiliaryFailure>()));
      await cb.close();
    },
  );

  test(
    'identity mismatch fails before registration or relay challenge',
    () async {
      final alice = await DeviceIdentity.fromSeed(List<int>.filled(32, 1));
      final bob = await DeviceIdentity.fromSeed(List<int>.filled(32, 2));
      final binding = GrantBinding(
        id: List<int>.filled(32, 3),
        initiatorKey: alice.publicKey.bytes,
        receiverKey: bob.publicKey.bytes,
      );
      final grant = GrantEndpoint.fromAuthenticatedPairing(
        binding: binding,
        role: GrantRole.initiator,
        establishedMicros: 0,
        recoverySecret: List<int>.filled(32, 4),
        clock: () async => 0,
        onInvalidated: () {},
      );
      final transport = _RelayTransport([alice, bob]);
      await expectLater(
        RelayServiceClient(transport)
            .open(grant, bob, cancellation: AuxiliaryCancellation()),
        throwsA(isA<AuxiliaryFailure>()),
      );
      expect(transport.joined, isEmpty);
    },
  );

  test('cancel after accepted join removes the late room', () async {
    final alice = await DeviceIdentity.fromSeed(List<int>.filled(32, 1));
    final bob = await DeviceIdentity.fromSeed(List<int>.filled(32, 2));
    final binding = GrantBinding(
      id: List<int>.filled(32, 3),
      initiatorKey: alice.publicKey.bytes,
      receiverKey: bob.publicKey.bytes,
    );
    final grant = GrantEndpoint.fromAuthenticatedPairing(
      binding: binding,
      role: GrantRole.initiator,
      establishedMicros: 0,
      recoverySecret: List<int>.filled(32, 4),
      clock: () async => 0,
      onInvalidated: () {},
    );
    final transport = _RelayTransport([alice, bob])
      ..joinGate = Completer<void>();
    final cancellation = AuxiliaryCancellation();
    final opening = RelayServiceClient(transport)
        .open(grant, alice, cancellation: cancellation);
    for (var i = 0; i < 20 && transport.joined.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(transport.joined, isNotEmpty);
    cancellation.cancel();
    transport.joinGate!.complete();
    await expectLater(opening, throwsA(isA<AuxiliaryFailure>()));
    expect(transport.joined, isEmpty);
  });
}
