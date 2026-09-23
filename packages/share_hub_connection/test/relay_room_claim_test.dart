import 'dart:convert';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'room claim binds grant policy, peers and transport generation',
    () async {
      final initiator = await DeviceIdentity.fromSeed(List<int>.filled(32, 1));
      final receiver = await DeviceIdentity.fromSeed(List<int>.filled(32, 2));
      final binding = GrantBinding(
        id: List<int>.generate(32, (index) => index),
        initiatorKey: initiator.publicKey.bytes,
        receiverKey: receiver.publicKey.bytes,
      );
      final claim = RelayRoomClaim.fromBinding(binding, 7);
      expect(
        claim.encode(),
        '{"v":1,"grant":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",'
        '"initiator":"iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=",'
        '"receiver":"gTl3Dqh9F19Wo1Rmw0x-zMuNipG07jeiXfYPW4_Js5Q=",'
        '"type":"short-code","lifetime":28800,"generation":7}',
      );
      expect(
        base64Url.encode(claim.roomId),
        // Cross-language room identifier pinned by the Python service test.
        'nPbj46YL0jts0OOx0GufXoaHqvkeDb-X2X2RpFq2xgw=',
      );
      expect(RelayRoomClaim.decode(claim.encode()).roomId, claim.roomId);
      expect(claim.policyType, binding.policy.type);
      expect(claim.lifetimeSeconds, binding.policy.lifetime.inSeconds);
      expect(
        RelayRoomClaim.fromBinding(binding, 8).roomId,
        isNot(claim.roomId),
      );
      expect(
        RelayRoomClaim(
          grant: binding.id,
          initiator: initiator.publicKey.bytes,
          receiver: receiver.publicKey.bytes,
          policyType: 'extended',
          lifetimeSeconds: 3600,
          generation: 7,
        ).roomId,
        isNot(claim.roomId),
      );

      final challenge = List<int>.generate(32, (index) => index + 32);
      final signature = await claim.signJoin(initiator, challenge);
      expect(
        signature,
        'FFK1JeWw6ZJicJ_Tn1EG6ygMdABuJKMUod36hZarGPM-1X3NOAQc-vMa3JNEFINOqBnUu1lcYqNcI7z0hvo_CQ==',
      );
      expect(
        await claim.verifyJoin(initiator.encodedKey, signature, challenge),
        isTrue,
      );
      expect(
        await claim.verifyJoin(receiver.encodedKey, signature, challenge),
        isFalse,
      );
      expect(
        await claim.verifyJoin(
          initiator.encodedKey,
          signature,
          List<int>.filled(32, 0),
        ),
        isFalse,
      );
      final stranger = await DeviceIdentity.fromSeed(List<int>.filled(32, 3));
      expect(
        () => claim.signJoin(stranger, challenge),
        throwsA(isA<ConnectionFailure>()),
      );
    },
  );

  test('claim refuses ambiguous or noncanonical wire', () {
    final claim = RelayRoomClaim(
      grant: List<int>.filled(32, 1),
      initiator: List<int>.filled(32, 2),
      receiver: List<int>.filled(32, 3),
      policyType: 'time-limited',
      lifetimeSeconds: 28800,
      generation: 7,
    );
    final wire = claim.encode();
    for (final bad in [
      '$wire ',
      wire.replaceFirst('"v":1,', '"v":1,"v":1,'),
      wire.replaceFirst('"v":1', '"v":2'),
      wire.replaceFirst('"generation":7', '"generation":-1'),
      wire.replaceFirst('"lifetime":28800', '"lifetime":0'),
    ]) {
      expect(
        () => RelayRoomClaim.decode(bad),
        throwsA(isA<ConnectionFailure>()),
      );
    }
  });
}
