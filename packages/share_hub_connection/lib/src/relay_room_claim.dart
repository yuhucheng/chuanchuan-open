import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;
import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'identity.dart';

/// A matching rendezvous hint, not a transferable grant. Both identities must
/// sign this exact claim with independent service challenges before forwarding;
/// endpoints still check their own live GrantEndpoint when opening messages.
final class RelayRoomClaim {
  RelayRoomClaim({
    required List<int> grant,
    required List<int> initiator,
    required List<int> receiver,
    required this.policyType,
    required this.lifetimeSeconds,
    required this.generation,
  }) : grant = List<int>.unmodifiable(grant),
       initiator = List<int>.unmodifiable(initiator),
       receiver = List<int>.unmodifiable(receiver) {
    _validate();
  }

  factory RelayRoomClaim.fromBinding(GrantBinding binding, int generation) =>
      RelayRoomClaim(
        grant: binding.id,
        initiator: binding.initiatorKey,
        receiver: binding.receiverKey,
        policyType: binding.policy.type,
        lifetimeSeconds: binding.policy.lifetime.inSeconds,
        generation: generation,
      );

  static const version = 1;
  static const _roomDomain = 'chuanchuan.signal.room.v1\u0000';
  static const _joinDomain = 'chuanchuan.signal.join.v1\u0000';
  final List<int> grant, initiator, receiver;
  final String policyType;
  final int lifetimeSeconds, generation;

  void _validate() {
    if (grant.length != 32 ||
        initiator.length != 32 ||
        receiver.length != 32 ||
        [...grant, ...initiator, ...receiver].any((v) => v < 0 || v > 255) ||
        encodeBytes(initiator) == encodeBytes(receiver) ||
        !RegExp(r'^[a-z][a-z0-9.-]{0,63}$').hasMatch(policyType) ||
        lifetimeSeconds <= 0 ||
        lifetimeSeconds > 0x7fffffff ||
        generation < 0 ||
        generation > 0xffffffff) {
      throw const ConnectionFailure('invalid_relay_claim');
    }
  }

  String encode() => jsonEncode({
    'v': version,
    'grant': encodeBytes(grant),
    'initiator': encodeBytes(initiator),
    'receiver': encodeBytes(receiver),
    'type': policyType,
    'lifetime': lifetimeSeconds,
    'generation': generation,
  });

  static RelayRoomClaim decode(String wire) {
    if (wire.length > 512) throw const ConnectionFailure('invalid_relay_claim');
    try {
      final value = jsonDecode(wire);
      if (value is! Map<String, dynamic> ||
          value.length != 7 ||
          value['v'] != version ||
          value['type'] is! String ||
          value['lifetime'] is! int ||
          value['generation'] is! int) {
        throw const ConnectionFailure('invalid_relay_claim');
      }
      final claim = RelayRoomClaim(
        grant: decodeBytes(value['grant'], 32),
        initiator: decodeBytes(value['initiator'], 32),
        receiver: decodeBytes(value['receiver'], 32),
        policyType: value['type'] as String,
        lifetimeSeconds: value['lifetime'] as int,
        generation: value['generation'] as int,
      );
      if (claim.encode() != wire) {
        throw const ConnectionFailure('invalid_relay_claim');
      }
      return claim;
    } on FormatException {
      throw const ConnectionFailure('invalid_relay_claim');
    } on TypeError {
      throw const ConnectionFailure('invalid_relay_claim');
    } on ConnectionFailure {
      throw const ConnectionFailure('invalid_relay_claim');
    }
  }

  List<int> get roomId => hashes.sha256.convert([
    ...utf8.encode(_roomDomain),
    ...utf8.encode(encode()),
  ]).bytes;

  List<int> _joinTranscript(List<int> sender, List<int> nonce) {
    if (nonce.length != 32 ||
        nonce.any((v) => v < 0 || v > 255) ||
        sender.length != 32 ||
        (encodeBytes(sender) != encodeBytes(initiator) &&
            encodeBytes(sender) != encodeBytes(receiver))) {
      throw const ConnectionFailure('invalid_relay_claim');
    }
    return [...utf8.encode(_joinDomain), ...roomId, ...sender, ...nonce];
  }

  Future<String> signJoin(DeviceIdentity identity, List<int> nonce) =>
      identity.sign(_joinTranscript(identity.publicKey.bytes, nonce));

  Future<bool> verifyJoin(
    String encodedSender,
    Object? signature,
    List<int> nonce,
  ) async {
    try {
      final sender = decodeBytes(encodedSender, 32);
      return await DeviceIdentity.verify(
        encodedSender,
        signature,
        _joinTranscript(sender, nonce),
      );
    } on ConnectionFailure {
      return false;
    }
  }
}
