import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

Uint8List randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

String encodeBytes(List<int> bytes) => base64Url.encode(bytes);
Uint8List decodeBytes(Object? value, int length) {
  if (value is! String || value.length > length * 2) {
    throw const ConnectionFailure('invalid_message');
  }
  try {
    final bytes = base64Url.decode(value);
    if (bytes.length != length || encodeBytes(bytes) != value) {
      throw const ConnectionFailure('invalid_message');
    }
    return bytes;
  } on FormatException {
    throw const ConnectionFailure('invalid_message');
  }
}

class ConnectionFailure implements Exception {
  const ConnectionFailure(this.code);
  final String code;
  @override
  String toString() => 'ConnectionFailure($code)';
}

/// The host supplies the seed from protected storage. It is never discovery ID,
/// a signing certificate, an activation token, or a reusable pairing grant.
class DeviceIdentity {
  DeviceIdentity._(this._key, this.publicKey);
  final SimpleKeyPair _key;
  final SimplePublicKey publicKey;
  String get encodedKey => encodeBytes(publicKey.bytes);
  String get id => hashes.sha256.convert(publicKey.bytes).toString();

  static Future<DeviceIdentity> fromSeed(List<int> seed) async {
    if (seed.length != 32) {
      throw const ConnectionFailure('identity_unavailable');
    }
    final key = await Ed25519().newKeyPairFromSeed(seed);
    return DeviceIdentity._(key, await key.extractPublicKey());
  }

  Future<String> sign(List<int> transcript) async =>
      encodeBytes((await Ed25519().sign(transcript, keyPair: _key)).bytes);

  static Future<bool> verify(
    String key,
    Object? signature,
    List<int> transcript,
  ) => Ed25519().verify(
    transcript,
    signature: Signature(
      decodeBytes(signature, 64),
      publicKey: SimplePublicKey(
        decodeBytes(key, 32),
        type: KeyPairType.ed25519,
      ),
    ),
  );
}
