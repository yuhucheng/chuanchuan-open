import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'channel.dart';
import 'identity.dart';
import 'session.dart';

const _domain = 'chuanchuan.connection-recovery.v1';
List<int> _encode(List<Object> values) => utf8.encode(jsonEncode(values));
Never _fail([String code = 'invalid_recovery']) =>
    throw ConnectionFailure(code);

void _shape(Map<String, dynamic> message, String type, Set<String> fields) {
  if (message.length != fields.length ||
      !message.keys.every(fields.contains) ||
      message['type'] != type ||
      message['v'] is! int ||
      message['v'] != 1) {
    _fail();
  }
}

/// Strictly parsed lookup input. Possessing a grant identifier is NOT proof.
final class RecoveryHello {
  RecoveryHello._(this.grantId, this._nonce, this._proof);
  final String grantId;
  final List<int> _nonce, _proof;
  static RecoveryHello parse(Map<String, dynamic> message) {
    _shape(message, 'recover-hello', {'type', 'v', 'grantId', 'ci', 'proof'});
    final id = encodeBytes(decodeBytes(message['grantId'], 32));
    return RecoveryHello._(
      id,
      List.unmodifiable(decodeBytes(message['ci'], 32)),
      List.unmodifiable(decodeBytes(message['proof'], 32)),
    );
  }
}

/// Internal, process-only exporter from an already authenticated PAKE boundary.
/// Holds no endpoint or connection: bad proofs cannot mutate live grant state.
/// The service must bound candidates and independently enforce the original
/// owner/clock/deadline before reserving recovery after mutual proof succeeds.
final class RecoveryCredentials {
  RecoveryCredentials._(
    this.binding,
    this.role,
    this._context,
    this._root,
    this._helloKey,
    this._receiverKey,
    this._initiatorKey,
  );
  final GrantBinding binding;
  final GrantRole role;
  final List<Object> _context;
  SecretKey? _root, _helloKey, _receiverKey, _initiatorKey;
  int _epoch = 0;
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _hmac = Hmac.sha256();

  static Future<RecoveryCredentials> fromPairing({
    required GrantBinding binding,
    required GrantRole role,
    required List<int> pairingKey,
    required List<int> pairingTranscript,
  }) async {
    if (pairingKey.length != 32 ||
        pairingTranscript.isEmpty ||
        pairingKey.any((byte) => byte < 0 || byte > 255) ||
        pairingTranscript.any((byte) => byte < 0 || byte > 255)) {
      _fail('invalid_material');
    }
    final key = SecretKey(List<int>.of(pairingKey));
    final transcript = List<int>.unmodifiable(pairingTranscript);
    final context = List<Object>.unmodifiable([
      sessionProtocolVersion,
      binding.encodedId,
      encodeBytes(binding.initiatorKey),
      encodeBytes(binding.receiverKey),
      binding.policy.type,
      binding.policy.lifetime.inSeconds,
    ]);
    final root = await _hkdf.deriveKey(
      secretKey: key,
      nonce: transcript,
      info: utf8.encode('$_domain/root'),
    );
    final salt = hashes.sha256.convert(_encode(context)).bytes;
    final keys = await Future.wait([
      for (final purpose in ['hello', 'receiver-proof', 'initiator-proof'])
        _hkdf.deriveKey(
          secretKey: root,
          nonce: salt,
          info: utf8.encode('$_domain/$purpose'),
        ),
    ]);
    return RecoveryCredentials._(
      binding,
      role,
      context,
      root,
      keys[0],
      keys[1],
      keys[2],
    );
  }

  void _require(int epoch) {
    if (_root == null || _epoch != epoch) _fail('recovery_unavailable');
  }

  Future<List<int>> _sign(SecretKey? key, List<int> data, int epoch) async {
    _require(epoch);
    final mac = await _hmac.calculateMac(data, secretKey: key!);
    _require(epoch);
    return mac.bytes;
  }

  Future<void> _verify(
    SecretKey? key,
    List<int> data,
    List<int> proof,
    int epoch,
  ) async {
    final expected = await _sign(key, data, epoch);
    _require(epoch);
    // cryptography Mac equality uses constant-time byte comparison.
    if (Mac(expected) != Mac(proof)) _fail('authentication_failed');
  }

  Future<SecretKey> _outer(List<int> transcript, int epoch) async {
    _require(epoch);
    final key = await _hkdf.deriveKey(
      secretKey: _root!,
      nonce: hashes.sha256.convert(transcript).bytes,
      info: utf8.encode('$_domain/outer-root'),
    );
    _require(epoch);
    return key;
  }

  Future<RecoveryOffer> begin() async {
    final epoch = _epoch;
    _require(epoch);
    if (role != GrantRole.initiator) _fail('invalid_recovery_role');
    final nonce = encodeBytes(randomBytes(32));
    final proof = await _sign(
      _helloKey,
      _encode(['hello', ..._context, nonce]),
      epoch,
    );
    _require(epoch);
    return RecoveryOffer._(
      this,
      epoch,
      nonce,
      Map.unmodifiable({
        'type': 'recover-hello',
        'v': 1,
        'grantId': binding.encodedId,
        'ci': nonce,
        'proof': encodeBytes(proof),
      }),
    );
  }

  Future<RecoveryChallenge> acceptHello(RecoveryHello hello) async {
    final epoch = _epoch;
    _require(epoch);
    if (role != GrantRole.receiver) _fail('invalid_recovery_role');
    if (hello.grantId != binding.encodedId) _fail('authentication_failed');
    final ci = encodeBytes(hello._nonce);
    await _verify(
      _helloKey,
      _encode(['hello', ..._context, ci]),
      hello._proof,
      epoch,
    );
    _require(epoch);
    final cr = encodeBytes(randomBytes(32));
    final transcript = _encode([_domain, ..._context, ci, cr]);
    final proof = await _sign(_receiverKey, transcript, epoch);
    _require(epoch);
    return RecoveryChallenge._(
      this,
      epoch,
      transcript,
      Map.unmodifiable({
        'type': 'recover-challenge',
        'v': 1,
        'ci': ci,
        'cr': cr,
        'proof': encodeBytes(proof),
      }),
    );
  }

  /// Invalidates every outstanding candidate, including crypto already awaited.
  /// Dropping key references is not a claim of physical secure erasure by the GC.
  void dispose() {
    _epoch++;
    _root = _helloKey = _receiverKey = _initiatorKey = null;
  }
}

abstract class _Candidate {
  _Candidate(this.credentials, this.epoch);
  final RecoveryCredentials credentials;
  final int epoch;
  bool _used = false, _cancelled = false;
  void _check() {
    credentials._require(epoch);
    if (_cancelled) _fail('recovery_unavailable');
  }

  void _consume() {
    _check();
    if (_used) _fail('recovery_unavailable');
    _used = true; // Before the first await: one proof attempt per candidate.
  }

  void cancel() {
    _cancelled = true;
  }
}

final class RecoveryOffer extends _Candidate {
  RecoveryOffer._(super.credentials, super.epoch, this._nonce, this.message);
  final String _nonce;
  final Map<String, dynamic> message;
  Future<RecoveryProof> answer(Map<String, dynamic> challenge) async {
    _consume();
    try {
      _shape(challenge, 'recover-challenge', {
        'type',
        'v',
        'ci',
        'cr',
        'proof',
      });
      final ci = encodeBytes(decodeBytes(challenge['ci'], 32));
      final cr = encodeBytes(decodeBytes(challenge['cr'], 32));
      final remoteProof = decodeBytes(challenge['proof'], 32);
      if (ci != _nonce) _fail('authentication_failed');
      final transcript = _encode([_domain, ...credentials._context, ci, cr]);
      await credentials._verify(
        credentials._receiverKey,
        transcript,
        remoteProof,
        epoch,
      );
      _check();
      final proof = await credentials._sign(
        credentials._initiatorKey,
        transcript,
        epoch,
      );
      _check();
      final key = await credentials._outer(transcript, epoch);
      _check();
      return RecoveryProof._(
        Map.unmodifiable({
          'type': 'recover-proof',
          'v': 1,
          'proof': encodeBytes(proof),
        }),
        RecoveryCipherMaterial._(key, transcript, this),
      );
    } catch (_) {
      cancel();
      rethrow;
    }
  }
}

final class RecoveryProof {
  RecoveryProof._(this.message, this.material);
  final Map<String, dynamic> message;
  final RecoveryCipherMaterial material;
}

final class RecoveryChallenge extends _Candidate {
  RecoveryChallenge._(
    super.credentials,
    super.epoch,
    this._transcript,
    this.message,
  );
  final List<int> _transcript;
  final Map<String, dynamic> message;
  Future<RecoveryCipherMaterial> accept(Map<String, dynamic> proof) async {
    _consume();
    try {
      _shape(proof, 'recover-proof', {'type', 'v', 'proof'});
      final remoteProof = decodeBytes(proof['proof'], 32);
      await credentials._verify(
        credentials._initiatorKey,
        _transcript,
        remoteProof,
        epoch,
      );
      _check();
      final key = await credentials._outer(_transcript, epoch);
      _check();
      return RecoveryCipherMaterial._(key, _transcript, this);
    } catch (_) {
      cancel();
      rethrow;
    }
  }
}

/// Single-use cipher material. Once open returns, the service owns the cipher;
/// it must close that candidate on cancellation until wire publication succeeds.
final class RecoveryCipherMaterial {
  RecoveryCipherMaterial._(this._key, this._transcript, this._candidate);
  SecretKey? _key;
  final List<int> _transcript;
  final _Candidate _candidate;
  bool _used = false, _cancelled = false;
  WireChannel? _claimedWire;
  WireChannel? _openingWire;
  void _check() {
    _candidate._check();
    if (_cancelled) _fail('recovery_unavailable');
  }

  Future<CipherChannel> open(WireChannel wire) async {
    // Reject duplicate ownership before the cleanup region. A duplicate call
    // must not close the first call's wire, even after its cipher is published.
    if (_used) {
      if (!identical(_claimedWire, wire)) wire.close();
      _fail('recovery_unavailable');
    }
    _used = true;
    _claimedWire = wire;
    try {
      _check();
      _openingWire = wire;
      final key = _key!;
      _key = null;
      final bytes = await key.extractBytes();
      _check();
      final cipher = await CipherChannel.create(
        wire,
        bytes,
        _transcript,
        host: _candidate.credentials.role == GrantRole.receiver,
      );
      _check();
      return cipher;
    } catch (_) {
      wire.close();
      rethrow;
    } finally {
      if (identical(_openingWire, wire)) _openingWire = null;
    }
  }

  void cancel() {
    _cancelled = true;
    _key = null;
    _openingWire?.close();
  }
}
