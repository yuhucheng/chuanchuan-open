/// Public protocol core. Socket routing and retry policy belong to the client.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

const grantLifetime = Duration(hours: 8);

/// Extensible authenticated grant profile. Product admission chooses supported
/// profiles; an arbitrary remote type never enables a new authorization mode.
final class GrantPolicy {
  const GrantPolicy({required this.type, required this.lifetime});
  static const shortCode = GrantPolicy(
    type: 'short-code',
    lifetime: grantLifetime,
  );
  final String type;
  final Duration lifetime;
  void validate() {
    if (!RegExp(r'^[a-z][a-z0-9.-]{0,63}$').hasMatch(type) ||
        lifetime.inSeconds <= 0 ||
        lifetime.inSeconds > 0x7fffffff ||
        lifetime.inMicroseconds % Duration.microsecondsPerSecond != 0) {
      throw const SessionFailure('invalid_grant_policy');
    }
  }
}

const sessionProtocolVersion = 2;

enum GrantRole { initiator, receiver }

enum GrantPhase { suspended, negotiating, active, revoked }

enum SessionOperation { watch, cast, control, file }

final class SessionFailure implements Exception {
  const SessionFailure(this.code);
  final String code;
  @override
  String toString() => 'SessionFailure($code)';
}

List<int> _bytes(Object value, int count) {
  if (value is! List<int> ||
      value.length != count ||
      value.any((v) => v < 0 || v > 255)) {
    throw const SessionFailure('invalid_material');
  }
  return List<int>.unmodifiable(value);
}

List<int> _random() {
  final random = Random.secure();
  return List<int>.generate(32, (_) => random.nextInt(256));
}

List<int> _encode(List<Object> values) => utf8.encode(jsonEncode(values));
String _b64(List<int> bytes) => base64Url.encode(bytes);

/// Issued ONLY by the authenticated pairing boundary after successful code
/// consumption. Never reconstruct a live grant from remote JSON or storage.
/// Keys are the authenticated Ed25519 public keys, not discovery UUIDs.
final class GrantBinding {
  GrantBinding({
    required List<int> id,
    required List<int> initiatorKey,
    required List<int> receiverKey,
    this.policy = GrantPolicy.shortCode,
  }) : id = _bytes(id, 32),
       initiatorKey = _bytes(initiatorKey, 32),
       receiverKey = _bytes(receiverKey, 32) {
    policy.validate();
    if (_b64(this.initiatorKey) == _b64(this.receiverKey)) {
      throw const SessionFailure('same_identity');
    }
  }
  final List<int> id, initiatorKey, receiverKey;
  final GrantPolicy policy;
  String get encodedId => _b64(id);
  List<Object> get _context => [
    sessionProtocolVersion,
    _b64(id),
    _b64(initiatorKey),
    _b64(receiverKey),
    policy.type,
    policy.lifetime.inSeconds,
  ];
}

final class ResumeHello {
  ResumeHello(this.generation, List<int> challenge)
    : challenge = _bytes(challenge, 32);
  final int generation;
  final List<int> challenge;
}

final class ResumeResponse {
  ResumeResponse(this.hello, List<int> challenge, List<int> proof)
    : challenge = _bytes(challenge, 32),
      proof = _bytes(proof, 32);
  final ResumeHello hello;
  final List<int> challenge, proof;
}

final class ResumeFinish {
  ResumeFinish(List<int> proof) : proof = _bytes(proof, 32);
  final List<int> proof;
}

final class SessionEnvelope {
  SessionEnvelope({
    required this.generation,
    required this.sequence,
    required List<int> ciphertext,
    required List<int> mac,
  }) : ciphertext = List<int>.unmodifiable(ciphertext),
       mac = _bytes(mac, 16) {
    if (ciphertext.length > 65536 || ciphertext.any((v) => v < 0 || v > 255)) {
      throw const SessionFailure('message_limit');
    }
  }
  final int generation, sequence;
  final List<int> ciphertext, mac;
}

/// Sealed authority: consumers cannot implement or construct this from UI data.
/// Both endpoints recheck their own grant clock and transport epoch. Local
/// authorization is not evidence that the peer has received or rendered media.
sealed class SessionAuthorization {
  SessionAuthorization._(
    this._owner,
    this._epoch,
    this.operation,
    this.sessionId,
    this.body,
  ) : transportGeneration = _owner.generation;
  final GrantEndpoint _owner;
  final int _epoch;
  final SessionOperation operation;
  final String sessionId;
  final String body;
  GrantBinding get grant => _owner.binding;
  Stream<void> get invalidated => _owner.invalidated;
  final int transportGeneration;
  int get expiresMicros => _owner.expiresMicros;
  GrantRole get sender;
  Future<void> check() => _owner._check(_epoch, GrantPhase.active);

  /// Close the microtask gap after awaiting check(), immediately before effects.
  void requireCurrent() {
    if (_owner._epoch != _epoch || _owner.phase != GrantPhase.active) {
      throw const SessionFailure('stale_or_revoked');
    }
  }
}

/// Only authenticated decode can mint an incoming request.
final class VerifiedSessionMessage extends SessionAuthorization {
  VerifiedSessionMessage._(
    super.owner,
    super.epoch,
    super.operation,
    super.sessionId,
    super.body,
  ) : super._();
  @override
  GrantRole get sender => _owner.role == GrantRole.initiator
      ? GrantRole.receiver
      : GrantRole.initiator;
}

/// Minted from a live local grant, for the initiating SDK resource owner.
/// This cannot be parsed from the network or substituted for a peer response.
final class LocalSessionRequest extends SessionAuthorization {
  LocalSessionRequest._(
    super.owner,
    super.epoch,
    super.operation,
    super.sessionId,
    super.body,
  ) : super._();
  @override
  GrantRole get sender => _owner.role;
}

/// Authenticated signaling for an already authorized operation. This is not a
/// start request and cannot grant a reverse operation. Consumers still check
/// their operation's current state/slot before applying SDP, ICE or stop.
final class VerifiedSessionSignal {
  VerifiedSessionSignal._(this.authorization, this.body);
  final SessionAuthorization authorization;
  final String body;
  Future<void> check() => authorization.check();
  void requireCurrent() => authorization.requireCurrent();
}

/// Authenticated control transport, independent of client UI and media SDK.
/// One coordinator owns the receiver. Callbacks must enqueue bounded work and
/// return promptly; execution still verifies the local registry/session slot.
abstract interface class SessionTransport {
  Future<LocalSessionRequest> createRequest(
    SessionOperation operation,
    String sessionId,
    String body,
  );
  Future<void> sendRequest(LocalSessionRequest request);
  Future<void> sendSignal(SessionAuthorization authorization, String body);
  void attachReceiver({
    required void Function(VerifiedSessionMessage) onRequest,
    required SessionAuthorization? Function(String sessionId) resolveSession,
    required void Function(VerifiedSessionSignal) onSignal,
  });
  void detachReceiver();
}

/// A trusted process-local registry entry. [recoverySecret] must be an exporter
/// derived from an authenticated PAKE transcript, NEVER the six-digit code.
/// Both endpoints use independent sleep-inclusive monotonic deadlines anchored
/// at the original pairing; peer timestamps cannot extend either deadline.
final class GrantEndpoint {
  GrantEndpoint.fromAuthenticatedPairing({
    required this.binding,
    required this.role,
    required int establishedMicros,
    required List<int> recoverySecret,
    required this.clock,
    required this.onInvalidated,
  }) : expiresMicros =
           establishedMicros + binding.policy.lifetime.inMicroseconds,
       _lastMicros = establishedMicros,
       _root = SecretKey(_bytes(recoverySecret, 32));
  final GrantBinding binding;
  final GrantRole role;
  final int expiresMicros;
  final Future<int> Function() clock;

  /// Synchronous stop barrier: release input and stop media/file operations.
  final void Function() onInvalidated;
  final _invalidations = StreamController<void>.broadcast(sync: true);
  Stream<void> get invalidated => _invalidations.stream;
  int _lastMicros;
  SecretKey? _root, _sendKey, _receiveKey;
  GrantPhase _phase = GrantPhase.suspended;
  GrantPhase get phase => _phase;
  int _epoch = 0, _generation = 0, _sent = 0, _received = 0;
  int get generation => _generation;
  bool _sending = false, _receiving = false;
  ResumeHello? _hello;
  ResumeResponse? _response;
  final _hmac = Hmac.sha256();
  final _cipher = AesGcm.with256bits();

  Future<void> _check(int epoch, GrantPhase expected) async {
    int now;
    try {
      now = await clock();
    } catch (_) {
      revoke();
      rethrow;
    }
    if (now < _lastMicros || now >= expiresMicros) {
      revoke();
      throw const SessionFailure('expired_or_clock_rollback');
    }
    _lastMicros = now;
    if (_epoch != epoch || _phase != expected || _root == null) {
      throw const SessionFailure('stale_or_revoked');
    }
  }

  void _invalidate(GrantPhase next) {
    _epoch++;
    _phase = next;
    _hello = null;
    _response = null;
    _sendKey = _receiveKey = null;
    _invalidations.add(null);
    if (next == GrantPhase.revoked) unawaited(_invalidations.close());
    onInvalidated();
  }

  /// Hosts poll this with their continuous clock even when no traffic arrives.
  Future<void> checkValidity() => _check(_epoch, _phase);

  void suspend() {
    if (_phase != GrantPhase.revoked) _invalidate(GrantPhase.suspended);
  }

  void revoke() {
    if (_phase == GrantPhase.revoked) return;
    _root = null;
    _invalidate(GrantPhase.revoked);
  }

  List<int> _transcript(ResumeHello hello, List<int> response) => _encode([
    'chuanchuan.resume.v2',
    ...binding._context,
    hello.generation,
    _b64(hello.challenge),
    _b64(response),
  ]);
  Future<List<int>> _proof(String side, List<int> transcript) async =>
      (await _hmac.calculateMac(
        _encode([side, _b64(transcript)]),
        secretKey: _root ?? (throw const SessionFailure('revoked')),
      )).bytes;
  Future<bool> _verify(
    String side,
    List<int> transcript,
    List<int> proof,
  ) async => Mac(await _proof(side, transcript)) == Mac(proof);

  Future<ResumeHello> beginResume() async {
    if (role != GrantRole.initiator || _phase != GrantPhase.suspended) {
      throw const SessionFailure('invalid_resume_role_or_state');
    }
    // Reserve synchronously before the clock await; only one attempt is live.
    _phase = GrantPhase.negotiating;
    final epoch = ++_epoch;
    await _check(epoch, GrantPhase.negotiating);
    if (_generation >= 0xffffffff) {
      revoke();
      throw const SessionFailure('generation_limit');
    }
    return _hello = ResumeHello(++_generation, _random());
  }

  Future<ResumeResponse> answerResume(ResumeHello hello) async {
    if (role != GrantRole.receiver ||
        _phase != GrantPhase.suspended ||
        hello.generation <= _generation ||
        hello.generation > 0xffffffff) {
      throw const SessionFailure('stale_resume');
    }
    _phase = GrantPhase.negotiating;
    final epoch = ++_epoch;
    await _check(epoch, GrantPhase.negotiating);
    final challenge = _random();
    final proof = await _proof('receiver', _transcript(hello, challenge));
    await _check(epoch, GrantPhase.negotiating);
    return _response = ResumeResponse(hello, challenge, proof);
  }

  Future<ResumeFinish> finishResume(ResumeResponse response) async {
    final epoch = _epoch;
    await _check(epoch, GrantPhase.negotiating);
    final hello = _hello;
    if (role != GrantRole.initiator ||
        hello == null ||
        hello.generation != response.hello.generation ||
        _b64(hello.challenge) != _b64(response.hello.challenge)) {
      throw const SessionFailure('challenge_mismatch');
    }
    final transcript = _transcript(hello, response.challenge);
    if (!await _verify('receiver', transcript, response.proof)) {
      throw const SessionFailure('authentication_failed');
    }
    final proof = await _proof('initiator', transcript);
    await _activate(transcript, epoch);
    return ResumeFinish(proof);
  }

  Future<void> acceptResume(ResumeFinish finish) async {
    final epoch = _epoch;
    await _check(epoch, GrantPhase.negotiating);
    final response = _response;
    if (role != GrantRole.receiver || response == null) {
      throw const SessionFailure('invalid_resume_state');
    }
    final transcript = _transcript(response.hello, response.challenge);
    if (!await _verify('initiator', transcript, finish.proof)) {
      throw const SessionFailure('authentication_failed');
    }
    await _activate(transcript, epoch);
  }

  Future<void> _activate(List<int> transcript, int epoch) async {
    final root = _root ?? (throw const SessionFailure('revoked'));
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    Future<SecretKey> derive(String direction) => hkdf.deriveKey(
      secretKey: root,
      nonce: transcript,
      info: utf8.encode('chuanchuan.transport.v2/$direction'),
    );
    final forward = await derive('initiator-to-receiver');
    final reverse = await derive('receiver-to-initiator');
    await _check(epoch, GrantPhase.negotiating);
    _sendKey = role == GrantRole.initiator ? forward : reverse;
    _receiveKey = role == GrantRole.initiator ? reverse : forward;
    _generation = (_hello ?? _response!.hello).generation;
    _sent = _received = 0;
    _hello = null;
    _response = null;
    _phase = GrantPhase.active;
    // Invalidate other concurrent completion paths as well as prior permits.
    _epoch++;
  }

  void _authorize(SessionOperation operation, GrantRole sender) {
    if (operation != SessionOperation.file && sender != GrantRole.initiator) {
      throw const SessionFailure('direction_denied');
    }
  }

  List<int> _nonce(int sequence) => List<int>.generate(
    12,
    (i) => i < 8 ? 0 : (sequence >> ((11 - i) * 8)) & 255,
  );
  List<int> _aad(int sequence) => _encode([
    'chuanchuan.packet.v2',
    ...binding._context,
    _generation,
    sequence,
  ]);

  Future<LocalSessionRequest> authorizeLocal(
    SessionOperation operation,
    String sessionId,
    String body,
  ) async {
    final epoch = _epoch;
    await _check(epoch, GrantPhase.active);
    _authorize(operation, role);
    if (sessionId.isEmpty || sessionId.length > 128) {
      throw const SessionFailure('invalid_session');
    }
    if (_encode([operation.name, sessionId, body]).length > 65536) {
      throw const SessionFailure('message_limit');
    }
    return LocalSessionRequest._(this, epoch, operation, sessionId, body);
  }

  Future<SessionEnvelope> seal(
    SessionOperation operation,
    String sessionId,
    String body,
  ) => _sealPayload(
    [operation.name, sessionId, body],
    sessionId,
    () => _authorize(operation, role),
  );

  Future<SessionEnvelope> sealRequest(LocalSessionRequest request) =>
      _sealPayload(
        [request.operation.name, request.sessionId, request.body],
        request.sessionId,
        () {
          _requireAuthorization(request);
          _authorize(request.operation, role);
        },
      );

  /// Either endpoint may signal only within a request it already owns. A
  /// receiver's response never becomes permission to initiate a reverse watch.
  Future<SessionEnvelope> sealSignal(
    SessionAuthorization authorization,
    String body,
  ) => _sealPayload(
    ['signal', authorization.operation.name, authorization.sessionId, body],
    authorization.sessionId,
    () => _requireAuthorization(authorization),
  );

  void _requireAuthorization(SessionAuthorization authorization) {
    if (!identical(authorization._owner, this)) {
      throw const SessionFailure('foreign_authorization');
    }
    authorization.requireCurrent();
  }

  Future<SessionEnvelope> _sealPayload(
    List<String> fields,
    String sessionId,
    void Function() validate,
  ) async {
    if (_sending) throw const SessionFailure('send_busy');
    _sending = true;
    try {
      final epoch = _epoch;
      await _check(epoch, GrantPhase.active);
      validate();
      if (sessionId.isEmpty || sessionId.length > 128) {
        throw const SessionFailure('invalid_session');
      }
      final clear = _encode(fields);
      if (clear.length > 65536 || _sent >= 0x100000000) {
        throw const SessionFailure('message_limit');
      }
      final sequence = _sent++;
      final generation = _generation;
      final box = await _cipher.encrypt(
        clear,
        secretKey: _sendKey!,
        nonce: _nonce(sequence),
        aad: _aad(sequence),
      );
      await _check(epoch, GrantPhase.active);
      validate();
      return SessionEnvelope(
        generation: generation,
        sequence: sequence,
        ciphertext: box.cipherText,
        mac: box.mac.bytes,
      );
    } finally {
      _sending = false;
    }
  }

  Future<VerifiedSessionMessage> open(SessionEnvelope envelope) => _openPayload(
    envelope,
    (values, epoch) {
      if (values.length != 3 || values[1].isEmpty || values[1].length > 128) {
        throw const SessionFailure('invalid_message');
      }
      final operation = SessionOperation.values.firstWhere(
        (v) => v.name == values[0],
        orElse: () => throw const SessionFailure('unknown_operation'),
      );
      _authorize(
        operation,
        role == GrantRole.initiator ? GrantRole.receiver : GrantRole.initiator,
      );
      return VerifiedSessionMessage._(
        this,
        epoch,
        operation,
        values[1],
        values[2],
      );
    },
  );

  Future<VerifiedSessionSignal> openSignal(
    SessionAuthorization authorization,
    SessionEnvelope envelope,
  ) => _openPayload(envelope, (values, epoch) {
    _requireAuthorization(authorization);
    if (values.length != 4 ||
        values[0] != 'signal' ||
        values[1] != authorization.operation.name ||
        values[2] != authorization.sessionId) {
      throw const SessionFailure('signal_context_mismatch');
    }
    return VerifiedSessionSignal._(authorization, values[3]);
  });

  /// Consume a late authenticated signal for an operation no longer owned by
  /// the coordinator, without producing a permit or changing a newer session.
  Future<void> discardSignal(SessionEnvelope envelope) =>
      _openPayload<void>(envelope, (values, epoch) {
        if (values.length != 4 || values[0] != 'signal') {
          throw const SessionFailure('invalid_message');
        }
      });

  Future<T> _openPayload<T>(
    SessionEnvelope envelope,
    T Function(List<String>, int) decode,
  ) async {
    if (_receiving) throw const SessionFailure('receive_busy');
    _receiving = true;
    try {
      final epoch = _epoch;
      await _check(epoch, GrantPhase.active);
      if (envelope.generation != _generation ||
          envelope.sequence != _received ||
          _received >= 0x100000000) {
        throw const SessionFailure('replay_or_generation');
      }
      final clear = await _cipher.decrypt(
        SecretBox(
          envelope.ciphertext,
          nonce: _nonce(envelope.sequence),
          mac: Mac(envelope.mac),
        ),
        secretKey: _receiveKey!,
        aad: _aad(envelope.sequence),
      );
      await _check(epoch, GrantPhase.active);
      final values = jsonDecode(utf8.decode(clear));
      if (values is! List || values.any((v) => v is! String)) {
        throw const SessionFailure('invalid_message');
      }
      final result = decode(values.cast<String>(), epoch);
      _received++;
      return result;
    } finally {
      _receiving = false;
    }
  }
}

/// Owned by the authenticated connection service and injected into SDK resource
/// owners at composition time. UI request data must never populate this registry.
final class GrantRegistry {
  final Set<GrantEndpoint> _grants = {};
  void register(GrantEndpoint grant) {
    if (grant.phase == GrantPhase.revoked) {
      throw const SessionFailure('revoked');
    }
    _grants.add(grant);
  }

  void revoke(GrantEndpoint grant) {
    _grants.remove(grant);
    grant.revoke();
  }

  void revokeAll() {
    final entries = _grants.toList();
    _grants.clear();
    for (final grant in entries) {
      grant.revoke();
    }
  }

  Future<void> verify(SessionAuthorization message) async {
    await message.check();
    message.requireCurrent();
    if (!_grants.contains(message._owner)) {
      throw const SessionFailure('unknown_local_grant');
    }
  }
}
