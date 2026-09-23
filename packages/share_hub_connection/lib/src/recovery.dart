import 'dart:async';
import 'dart:io';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'auxiliary_service.dart';
import 'channel.dart';
import 'identity.dart';
import 'recovery_protocol.dart';
import 'session.dart';

/// Process-only owner of negotiated original grants. Pairing must register only
/// after authenticated capability agreement and initial grant activation.
/// This listener is independent of short-code offers and their cancellation.
final class ConnectionRecoveryService {
  ConnectionRecoveryService({
    this.handshakeTimeout = const Duration(seconds: 30),
  }) {
    if (handshakeTimeout <= Duration.zero ||
        handshakeTimeout > const Duration(seconds: 30)) {
      throw ArgumentError.value(handshakeTimeout);
    }
  }
  final Duration handshakeTimeout;
  final _records = <String, _Record>{};
  final _pending = <_Candidate>{};
  ServerSocket? _server;
  Future<void>? _opening;
  bool _closed = false;
  int? get port => _server?.port;
  int get registeredCount => _records.length;
  int get pendingCount => _pending.length;

  Future<void> open({InternetAddress? address}) {
    if (_closed) {
      return Future.error(const ConnectionFailure('recovery_unavailable'));
    }
    if (_server != null) return Future.value();
    return _opening ??= _open(address).whenComplete(() => _opening = null);
  }

  Future<void> _open(InternetAddress? address) async {
    final server = await ServerSocket.bind(
      address ?? InternetAddress.anyIPv4,
      0,
    );
    if (_closed) {
      await server.close();
      throw const ConnectionFailure('recovery_unavailable');
    }
    _server = server;
    server.listen((socket) {
      if (_closed || _pending.length >= 4) {
        socket.destroy();
        return;
      }
      final candidate = _admit()..wire = WireChannel(socket);
      unawaited(_accept(candidate));
    });
  }

  /// Transfers credential ownership on success. A failed registration leaves it
  /// with pairing, which must dispose it along with its uncommitted connection.
  void register(
    TrustedConnection owner,
    ConnectionRecoveryHandle handle,
    RecoveryCredentials credentials, {
    InternetAddress? address,
    int? port,
  }) {
    final endpoint = owner.grant;
    if (_closed ||
        _records.length >= 8 ||
        owner.isClosed ||
        !handle.owns(owner) ||
        endpoint == null ||
        endpoint.phase != GrantPhase.active ||
        !identical(endpoint.binding, credentials.binding) ||
        endpoint.role != credentials.role ||
        _records.containsKey(endpoint.binding.encodedId)) {
      throw const ConnectionFailure('recovery_unavailable');
    }
    if (credentials.role == GrantRole.initiator &&
        (address == null || port == null || port < 1 || port > 65535)) {
      throw const ConnectionFailure('invalid_recovery_target');
    }
    if (credentials.role == GrantRole.receiver && _server == null) {
      throw const ConnectionFailure('recovery_unavailable');
    }
    final expectedPeer = endpoint.role == GrantRole.initiator
        ? endpoint.binding.receiverKey
        : endpoint.binding.initiatorKey;
    if (owner.peerKey != encodeBytes(expectedPeer)) {
      throw const ConnectionFailure('identity_mismatch');
    }
    final record = _Record(owner, handle, credentials, address, port);
    _records[endpoint.binding.encodedId] = record;
    unawaited(owner.whenClosed.then((_) => _remove(record)));
  }

  void _remove(_Record record) {
    final id = record.credentials.binding.encodedId;
    if (!identical(_records[id], record)) return;
    _records.remove(id);
    record.credentials.dispose();
    for (final candidate in _pending.toList()) {
      if (identical(candidate.record, record)) candidate.cancel();
    }
  }

  bool _owns(_Record record) =>
      !_closed &&
      !record.owner.isClosed &&
      identical(_records[record.credentials.binding.encodedId], record);

  _Candidate _admit() {
    if (_closed || _pending.length >= 4) {
      throw const ConnectionFailure('recovery_busy');
    }
    final candidate = _Candidate(this);
    _pending.add(candidate);
    return candidate;
  }

  /// Only the original grant initiator dials. Concurrent callers share one
  /// bounded attempt; retry/backoff is owned by the application controller.
  Future<void> reconnect(TrustedConnection owner) => _reconnect(owner, null);

  /// Uses the same bounded candidate and grant proof over a caller-provided
  /// sealed wire. Opening the wire does not grant authority or replace owner.
  Future<void> reconnectVia(
    TrustedConnection owner,
    Future<ConnectionWire> Function(AuxiliaryCancellation) open,
  ) => _reconnect(owner, open);

  Future<void> _reconnect(
    TrustedConnection owner,
    Future<ConnectionWire> Function(AuxiliaryCancellation)? open,
  ) {
    final record = _records[owner.grant?.binding.encodedId];
    if (record == null ||
        !identical(record.owner, owner) ||
        !_owns(record) ||
        record.credentials.role != GrantRole.initiator) {
      return Future.error(const ConnectionFailure('recovery_unavailable'));
    }
    if (record.dialing case final pending?) return pending;
    if (owner.isConnected) return Future.value();
    _Candidate candidate;
    try {
      candidate = _admit()..record = record;
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    return record.dialing = _dial(
      candidate,
      open: open,
    ).whenComplete(() => record.dialing = null);
  }

  /// The receiver supplies its already joined, sealed room. The parsed grant
  /// identifier must still select this exact registered owner.
  Future<void> acceptVia(
    TrustedConnection owner,
    Future<ConnectionWire> Function(AuxiliaryCancellation) open,
  ) async {
    final record = _records[owner.grant?.binding.encodedId];
    if (record == null ||
        !identical(record.owner, owner) ||
        !_owns(record) ||
        record.credentials.role != GrantRole.receiver) {
      throw const ConnectionFailure('recovery_unavailable');
    }
    final candidate = _admit()..record = record;
    try {
      candidate.wire = await candidate.step(() async {
        final wire = await open(candidate.openingCancellation);
        if (!candidate.current) {
          wire.close();
          throw const ConnectionFailure('recovery_unavailable');
        }
        return candidate.wire = wire;
      });
      await _accept(candidate, propagate: true);
    } finally {
      candidate.cancel();
    }
  }

  Future<void> _audit(_Candidate candidate) async {
    candidate.check();
    await candidate.step(candidate.record!.handle.check);
    candidate.check();
  }

  Future<void> _dial(
    _Candidate candidate, {
    Future<ConnectionWire> Function(AuxiliaryCancellation)? open,
  }) async {
    try {
      final record = candidate.record!;
      await _audit(candidate);
      candidate.wire = await candidate.step(() async {
        if (open != null) {
          final wire = await open(candidate.openingCancellation);
          if (!candidate.current) {
            wire.close();
            throw const ConnectionFailure('recovery_unavailable');
          }
          return candidate.wire = wire;
        }
        final socket = await Socket.connect(
          record.address!,
          record.port!,
          timeout: const Duration(seconds: 5),
        );
        if (!candidate.current) {
          socket.destroy();
          throw const ConnectionFailure('recovery_unavailable');
        }
        // Claim before returning across an async boundary: cancellation may win
        // the step race before its caller receives this newly connected socket.
        return candidate.wire = WireChannel(socket);
      });
      final wire = candidate.wire!;
      final offer = await candidate.step(record.credentials.begin);
      candidate.offer = offer;
      wire.send(offer.message);
      final challenge = await candidate.step(wire.next);
      final proof = await candidate.step(() => offer.answer(challenge));
      candidate.material = proof.material;
      await _audit(candidate);
      wire.send(proof.message);
      final cipher = await candidate.step(() => proof.material.open(wire));
      final authenticated = await candidate.step(cipher.next);
      _message(authenticated, 'recover-authenticated', {'v', 'grantId'});
      if (authenticated['v'] is! int ||
          authenticated['v'] != 1 ||
          authenticated['grantId'] != record.credentials.binding.encodedId) {
        throw const ConnectionFailure('invalid_recovery');
      }
      await _audit(candidate);
      candidate.reservation = record.handle.beginRecovery();
      await _activate(candidate, cipher);
      await _audit(candidate);
      await candidate.step(
        () => cipher.send({
          'type': 'recover-ready',
          'generation': record.owner.grant!.generation,
        }),
      );
      await _install(candidate, cipher);
    } finally {
      candidate.cancel();
    }
  }

  Future<void> _accept(_Candidate candidate, {bool propagate = false}) async {
    try {
      final wire = candidate.wire!;
      final hello = RecoveryHello.parse(await candidate.step(wire.next));
      final record = _records[hello.grantId];
      if (record == null ||
          (candidate.record != null && !identical(candidate.record, record)) ||
          !_owns(record) ||
          record.credentials.role != GrantRole.receiver) {
        throw const ConnectionFailure('recovery_unavailable');
      }
      candidate.record = record;
      final challenge = await candidate.step(
        () => record.credentials.acceptHello(hello),
      );
      candidate.challenge = challenge;
      wire.send(challenge.message);
      final proof = await candidate.step(wire.next);
      final material = await candidate.step(() => challenge.accept(proof));
      candidate.material = material;
      final cipher = await candidate.step(() => material.open(wire));
      await _audit(candidate);
      // Only complete proof and a current local lease may retire the old wire.
      candidate.reservation = record.handle.beginRecovery();
      await candidate.step(
        () => cipher.send({
          'type': 'recover-authenticated',
          'v': 1,
          'grantId': hello.grantId,
        }),
      );
      await _activate(candidate, cipher);
      final ready = await candidate.step(cipher.next);
      _message(ready, 'recover-ready', {'generation'});
      _generation(ready, record.owner.grant!.generation);
      await _install(candidate, cipher);
    } catch (_) {
      // Candidate failure is not permission to revoke the original grant.
      if (propagate) rethrow;
    } finally {
      candidate.cancel();
    }
  }

  Future<void> _install(_Candidate candidate, CipherChannel cipher) async {
    await _audit(candidate);
    await candidate.step(() => candidate.reservation!.install(cipher));
    candidate.finish(); // Transfer the wire to TrustedConnection.
  }

  Future<void> _activate(_Candidate candidate, CipherChannel cipher) async {
    final endpoint = candidate.record!.owner.grant!;
    await _audit(candidate);
    if (endpoint.role == GrantRole.initiator) {
      final hello = await candidate.step(endpoint.beginResume);
      await candidate.step(
        () => cipher.send({
          'type': 'grant-hello',
          'generation': hello.generation,
          'challenge': encodeBytes(hello.challenge),
        }),
      );
      final response = await candidate.step(cipher.next);
      _message(response, 'grant-response', {
        'generation',
        'challenge',
        'proof',
      });
      _generation(response, hello.generation);
      final finish = await candidate.step(
        () => endpoint.finishResume(
          ResumeResponse(
            hello,
            decodeBytes(response['challenge'], 32),
            decodeBytes(response['proof'], 32),
          ),
        ),
      );
      cipher.enableSessionFrames();
      await candidate.step(
        () => cipher.send({
          'type': 'grant-finish',
          'proof': encodeBytes(finish.proof),
        }),
      );
      final active = await candidate.step(cipher.next);
      _message(active, 'grant-active', {'generation'});
      _generation(active, hello.generation);
    } else {
      final hello = await candidate.step(cipher.next);
      _message(hello, 'grant-hello', {'generation', 'challenge'});
      final generation = hello['generation'];
      if (generation is! int ||
          generation <= endpoint.generation ||
          generation > 0xffffffff) {
        throw const ConnectionFailure('invalid_recovery');
      }
      final response = await candidate.step(
        () => endpoint.answerResume(
          ResumeHello(generation, decodeBytes(hello['challenge'], 32)),
        ),
      );
      await candidate.step(
        () => cipher.send({
          'type': 'grant-response',
          'generation': generation,
          'challenge': encodeBytes(response.challenge),
          'proof': encodeBytes(response.proof),
        }),
      );
      final finish = await candidate.step(cipher.next);
      _message(finish, 'grant-finish', {'proof'});
      await candidate.step(
        () => endpoint.acceptResume(
          ResumeFinish(decodeBytes(finish['proof'], 32)),
        ),
      );
      // The initiator may send ready and a large operation in the same TCP
      // read. Raise framing before releasing it; the owner still gates all
      // business effects until ready and the final clock audit/install.
      cipher.enableSessionFrames();
      await candidate.step(
        () => cipher.send({
          'type': 'grant-active',
          'generation': endpoint.generation,
        }),
      );
    }
    await candidate.step(endpoint.checkValidity);
    await _audit(candidate);
  }

  /// Revocation is synchronous; awaiting close only waits for listener cleanup.
  Future<void> close() {
    _closed = true;
    for (final candidate in _pending.toList()) {
      candidate.cancel();
    }
    for (final record in _records.values.toList()) {
      record.owner.close();
      _remove(record);
    }
    final server = _server;
    _server = null;
    return server?.close().then<void>((_) {}) ?? Future.value();
  }
}

void _message(Map<String, dynamic> message, String type, Set<String> fields) {
  if (message['type'] != type ||
      message.length != fields.length + 1 ||
      !message.keys.every((key) => key == 'type' || fields.contains(key))) {
    throw const ConnectionFailure('invalid_recovery');
  }
}

void _generation(Map<String, dynamic> message, int expected) {
  if (message['generation'] is! int || message['generation'] != expected) {
    throw const ConnectionFailure('invalid_recovery');
  }
}

final class _Record {
  _Record(this.owner, this.handle, this.credentials, this.address, this.port);
  final TrustedConnection owner;
  final ConnectionRecoveryHandle handle;
  final RecoveryCredentials credentials;
  final InternetAddress? address;
  final int? port;
  Future<void>? dialing;
}

final class _Candidate {
  _Candidate(this.service) {
    _timeout = Timer(service.handshakeTimeout, cancel);
  }
  final ConnectionRecoveryService service;
  late final Timer _timeout;
  final _stopped = Completer<void>();
  final openingCancellation = AuxiliaryCancellation();
  bool _alive = true;
  _Record? record;
  ConnectionWire? wire;
  RecoveryOffer? offer;
  RecoveryChallenge? challenge;
  RecoveryCipherMaterial? material;
  ConnectionRecoveryAttempt? reservation;
  bool get current =>
      _alive && !service._closed && (record == null || service._owns(record!));
  void check() {
    if (!current) throw const ConnectionFailure('recovery_unavailable');
  }

  Future<T> step<T>(Future<T> Function() operation) async {
    check();
    final result = await Future.any<T>([
      operation(),
      _stopped.future.then<T>(
        (_) => throw const ConnectionFailure('recovery_unavailable'),
      ),
    ]);
    check();
    return result;
  }

  void finish() {
    _alive = false;
    _timeout.cancel();
    service._pending.remove(this);
    if (!_stopped.isCompleted) _stopped.complete();
  }

  void cancel() {
    if (!_alive) return;
    finish();
    openingCancellation.cancel();
    offer?.cancel();
    challenge?.cancel();
    material?.cancel();
    wire?.close();
    reservation?.cancel();
  }
}
