import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'channel.dart';
import 'identity.dart';

/// Must advance through sleep and never go backwards. Hosts supply an OS
/// continuous clock; a process restart discards every authorization.
typedef ContinuousClock = Future<int> Function();
const connectionLifetime = Duration(hours: 8);

class SessionLease {
  SessionLease({required this.startedMicros});
  final int startedMicros;
  int? _last;
  bool _revoked = false;
  int get expiresMicros => startedMicros + connectionLifetime.inMicroseconds;
  bool get revoked => _revoked;
  bool check(int now) {
    if (now < startedMicros || (_last != null && now < _last!)) revoke();
    _last = now;
    if (now >= expiresMicros) revoke();
    return !_revoked;
  }

  void revoke() => _revoked = true;
}

class CipherChannel {
  CipherChannel._(
    this.wire,
    this._sendKey,
    this._receiveKey,
    this.sessionId, {
    SecretKey? baseSendKey,
    SecretKey? baseReceiveKey,
  }) : _baseSendKey = baseSendKey ?? _sendKey,
       _baseReceiveKey = baseReceiveKey ?? _receiveKey;
  final WireChannel wire;
  final SecretKey _sendKey;
  final SecretKey _receiveKey;
  final SecretKey _baseSendKey, _baseReceiveKey;
  final String sessionId;
  int _sent = 0;
  int _received = 0;
  final _cipher = AesGcm.with256bits();
  Future<void> _sendTail = Future.value();
  int _queuedSends = 0;
  int _clearLimit = 4096;
  void enableSessionFrames() {
    _clearLimit = 98304;
    wire.enableSessionFrames();
  }

  static Future<CipherChannel> create(
    WireChannel wire,
    List<int> key,
    List<int> transcript, {
    required bool host,
  }) async {
    final digest = hashes.sha256.convert(transcript).bytes;
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    Future<SecretKey> derive(String direction) => hkdf.deriveKey(
      secretKey: SecretKey(key),
      nonce: digest,
      info: utf8.encode('chuanchuan.connection.v1/$direction'),
    );
    final toHost = await derive('client-to-host');
    final toClient = await derive('host-to-client');
    return CipherChannel._(
      wire,
      host ? toClient : toHost,
      host ? toHost : toClient,
      encodeBytes(digest),
    );
  }

  /// The PAKE-established directional keys are retained only in this process.
  /// Derive from that stable base, not the last attempt: a lost final ack must
  /// not leave the peers on incompatible key chains. Grant proofs authorize
  /// this path; fresh challenges/generation separate every transport's keys.
  Future<CipherChannel> _recover(
    WireChannel wire,
    GrantEndpoint endpoint,
    ResumeResponse response,
  ) async {
    await endpoint.checkValidity();
    if (endpoint.phase != GrantPhase.active) {
      throw const ConnectionFailure('recovery_unavailable');
    }
    final transcript = utf8.encode(
      jsonEncode([
        'chuanchuan.connection.resume.v1',
        endpoint.binding.encodedId,
        response.hello.generation,
        encodeBytes(response.hello.challenge),
        encodeBytes(response.challenge),
      ]),
    );
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    Future<SecretKey> derive(SecretKey base) => hkdf.deriveKey(
      secretKey: base,
      nonce: transcript,
      info: utf8.encode('chuanchuan.connection.resume.v1'),
    );
    final send = await derive(_baseSendKey),
        receive = await derive(_baseReceiveKey);
    await endpoint.checkValidity();
    if (endpoint.phase != GrantPhase.active ||
        endpoint.generation != response.hello.generation) {
      throw const ConnectionFailure('recovery_unavailable');
    }
    return CipherChannel._(
      wire,
      send,
      receive,
      encodeBytes(hashes.sha256.convert(transcript).bytes),
      baseSendKey: _baseSendKey,
      baseReceiveKey: _baseReceiveKey,
    );
  }

  List<int> _nonce(int sequence) => List.generate(
    12,
    (index) => index < 4 ? 0 : (sequence >> ((11 - index) * 8)) & 255,
  );
  List<int> _aad(int sequence) =>
      utf8.encode(jsonEncode([1, sessionId, sequence]));

  Future<void> send(Map<String, dynamic> body) {
    // Capture the caller's data now; serialize encryption and writes so an
    // asynchronous cipher cannot put sequence N+1 on the wire before N.
    final clear = utf8.encode(jsonEncode(body));
    if (clear.length > _clearLimit || _queuedSends >= 8) {
      return Future.error(const ConnectionFailure('message_limit'));
    }
    _queuedSends++;
    final pending = _sendTail.then((_) => _sendEncoded(clear));
    _sendTail = pending.then<void>(
      (_) {
        _queuedSends--;
      },
      onError: (Object _, StackTrace _) {
        _queuedSends--;
        wire.close();
      },
    );
    return pending;
  }

  Future<void> _sendEncoded(List<int> clear) async {
    if (_sent >= 0x100000000) throw const ConnectionFailure('session_limit');
    final sequence = _sent++;
    final box = await _cipher.encrypt(
      clear,
      secretKey: _sendKey,
      nonce: _nonce(sequence),
      aad: _aad(sequence),
    );
    wire.send({
      'v': 1,
      'seq': sequence,
      'body': encodeBytes(box.cipherText),
      'mac': encodeBytes(box.mac.bytes),
    });
  }

  Future<Map<String, dynamic>> next() async {
    final envelope = await wire.next();
    final sequence = envelope['seq'];
    if (envelope['v'] != 1 ||
        sequence is! int ||
        sequence != _received ||
        sequence >= 0x100000000 ||
        envelope['body'] is! String) {
      throw const ConnectionFailure('invalid_message');
    }
    try {
      final body = base64Url.decode(envelope['body'] as String);
      final clear = await _cipher.decrypt(
        SecretBox(
          body,
          nonce: _nonce(sequence),
          mac: Mac(decodeBytes(envelope['mac'], 16)),
        ),
        secretKey: _receiveKey,
        aad: _aad(sequence),
      );
      final message = jsonDecode(utf8.decode(clear));
      if (message is! Map<String, dynamic>) {
        throw const ConnectionFailure('invalid_message');
      }
      _received++;
      return message;
    } catch (_) {
      throw const ConnectionFailure('authentication_failed');
    }
  }
}

/// A live authenticated control connection, not a media or input permission.
/// Grants are never serialized or restored. There is no renewal operation.
class TrustedConnection implements SessionTransport {
  TrustedConnection(
    this._channel,
    this.peerKey,
    this.lease,
    this._clock, {
    this.grant,
    this.enableRecovery = false,
  });

  /// Opt-in v2 contract material. No remote media capabilities are implied.
  final GrantEndpoint? grant;

  /// Transport-level opt-in; callers must retain/revoke suspended grants and
  /// supply bounded retry policy. False preserves legacy terminal-close rules.
  final bool enableRecovery;
  bool _recovering = false, _replaced = false;
  int _recoverySerial = 0;
  bool get canRecover =>
      enableRecovery &&
      !_replaced &&
      _reason == 'transport_suspended' &&
      !lease.revoked &&
      grant != null &&
      grant!.phase != GrantPhase.revoked;
  final CipherChannel _channel;
  final String peerKey;
  final SessionLease lease;
  final ContinuousClock _clock;
  final _closed = Completer<String>();
  Timer? _timer;
  Timer? _deadline;
  bool _monitoring = false;
  bool _checking = false;
  bool _sending = false;
  String? _reason;
  String get sessionId => _channel.sessionId;
  String get peerId =>
      hashes.sha256.convert(decodeBytes(peerKey, 32)).toString();
  Future<String> get whenClosed => _closed.future;
  bool get isClosed => _reason != null;
  Future<void>? _closingTransport;
  Future<void> get whenTransportClosed => _closingTransport ?? Future.value();
  // No remote media/input/file implementation has been accepted yet.
  Set<String> get capabilities => const {};

  void Function(VerifiedSessionMessage)? _onRequest;
  SessionAuthorization? Function(String)? _resolveSession;
  void Function(VerifiedSessionSignal)? _onSignal;
  int _receiverGeneration = 0, _queuedOperations = 0;
  Future<void> _operationTail = Future.value();

  GrantEndpoint get _endpoint {
    final endpoint = grant;
    if (isClosed || endpoint == null) {
      throw const ConnectionFailure('session_unavailable');
    }
    return endpoint;
  }

  @override
  Future<LocalSessionRequest> createRequest(
    SessionOperation operation,
    String sessionId,
    String body,
  ) => _endpoint.authorizeLocal(operation, sessionId, body);

  @override
  void attachReceiver({
    required void Function(VerifiedSessionMessage) onRequest,
    required SessionAuthorization? Function(String) resolveSession,
    required void Function(VerifiedSessionSignal) onSignal,
  }) {
    _endpoint;
    if (_onRequest != null) throw StateError('Receiver already attached');
    _receiverGeneration++;
    _onRequest = onRequest;
    _resolveSession = resolveSession;
    _onSignal = onSignal;
  }

  @override
  void detachReceiver() {
    _receiverGeneration++;
    _onRequest = null;
    _resolveSession = null;
    _onSignal = null;
  }

  Future<void> _enqueueOperation(Future<void> Function() write) {
    if (isClosed || _queuedOperations >= 8) {
      return Future.error(
        const ConnectionFailure('session_unavailable_or_busy'),
      );
    }
    _queuedOperations++;
    final pending = _operationTail.then((_) async {
      if (isClosed) throw const ConnectionFailure('disconnected');
      await write();
    });
    _operationTail = pending.then<void>(
      (_) {
        _queuedOperations--;
      },
      onError: (Object _, StackTrace _) {
        _queuedOperations--;
      },
    );
    return pending;
  }

  @override
  Future<void> sendRequest(LocalSessionRequest request) =>
      _enqueueOperation(() async {
        final packet = await _endpoint.sealRequest(request);
        if (isClosed) throw const ConnectionFailure('disconnected');
        await _sendOperationPacket({
          'type': 'operation-request',
          'packet': _packetMap(packet),
        });
      });

  @override
  Future<void> sendSignal(SessionAuthorization authorization, String body) {
    if (utf8.encode(body).length > 65536) {
      return Future.error(const ConnectionFailure('message_limit'));
    }
    return _enqueueOperation(() async {
      final packet = await _endpoint.sealSignal(authorization, body);
      if (isClosed) throw const ConnectionFailure('disconnected');
      await _sendOperationPacket({
        'type': 'operation-signal',
        'sessionId': authorization.sessionId,
        'packet': _packetMap(packet),
      });
    });
  }

  Future<void> _sendOperationPacket(Map<String, dynamic> packet) async {
    try {
      await _channel.send(packet);
    } catch (_) {
      // An inner sequence was already reserved. Never continue with a gap.
      _transportLost();
      rethrow;
    }
  }

  static Map<String, dynamic> _packetMap(SessionEnvelope packet) => {
    'generation': packet.generation,
    'sequence': packet.sequence,
    'ciphertext': encodeBytes(packet.ciphertext),
    'mac': encodeBytes(packet.mac),
  };

  static SessionEnvelope _parsePacket(Object? value) {
    if (value is! Map ||
        value['generation'] is! int ||
        value['sequence'] is! int ||
        value['ciphertext'] is! String) {
      throw const ConnectionFailure('invalid_message');
    }
    final encoded = value['ciphertext'] as String;
    if (encoded.length > 87384) throw const ConnectionFailure('message_limit');
    final bytes = base64Url.decode(encoded);
    if (encodeBytes(bytes) != encoded) {
      throw const ConnectionFailure('invalid_message');
    }
    return SessionEnvelope(
      generation: value['generation'],
      sequence: value['sequence'],
      ciphertext: bytes,
      mac: decodeBytes(value['mac'], 16),
    );
  }

  Future<void> _receiveOperation(Map<String, dynamic> message) async {
    final generation = _receiverGeneration;
    final endpoint = _endpoint;
    final packet = _parsePacket(message['packet']);
    if (message['type'] == 'operation-request') {
      final request = await endpoint.open(packet);
      if (!isClosed && generation == _receiverGeneration) {
        request.requireCurrent();
        _onRequest?.call(request);
      }
    } else {
      final id = message['sessionId'];
      if (id is! String || id.isEmpty || id.length > 128) {
        throw const ConnectionFailure('invalid_message');
      }
      final authorization = _resolveSession?.call(id);
      if (authorization == null) {
        await endpoint.discardSignal(packet);
        return;
      }
      final signal = await endpoint.openSignal(authorization, packet);
      if (!isClosed && generation == _receiverGeneration) {
        signal.requireCurrent();
        _onSignal?.call(signal);
      }
    }
  }

  void startMonitoring() {
    if (_monitoring || isClosed) return;
    _monitoring = true;
    unawaited(_armDeadline());
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(check()),
    );
    unawaited(_read());
  }

  Future<void> _armDeadline() async {
    try {
      final now = await _clock();
      if (isClosed) return;
      if (!lease.check(now)) {
        close('expired');
        return;
      }
      _deadline?.cancel();
      _deadline = Timer(
        Duration(microseconds: lease.expiresMicros - now),
        () => unawaited(_armDeadline()),
      );
    } catch (_) {
      if (!isClosed) close('clock_unavailable');
    }
  }

  Future<bool> check() async {
    if (isClosed) return false;
    if (_checking) return false;
    _checking = true;
    try {
      int now;
      try {
        now = await _clock();
      } catch (_) {
        if (!isClosed) close('clock_unavailable');
        return false;
      }
      if (isClosed) return false;
      if (!lease.check(now)) {
        close('expired');
        return false;
      }
      if (!_sending) {
        _sending = true;
        try {
          await _channel.send({'type': 'heartbeat'});
        } finally {
          _sending = false;
        }
      }
      return !isClosed;
    } catch (error) {
      if (isClosed) return false;
      if (error is ConnectionFailure && error.code == 'disconnected' ||
          error is SocketException) {
        _transportLost();
      } else {
        close('transport_failed');
      }
      return false;
    } finally {
      _checking = false;
    }
  }

  Future<void> _read() async {
    try {
      while (!isClosed) {
        final message = await _channel.next().timeout(
          const Duration(seconds: 10),
        );
        int now;
        try {
          now = await _clock();
        } catch (_) {
          if (!isClosed) close('clock_unavailable');
          return;
        }
        if (isClosed) return;
        if (enableRecovery &&
            message.length == 1 &&
            message['type'] == 'revoked') {
          close('peer_revoked');
          return;
        }
        if (!lease.check(now)) {
          close('expired');
          return;
        }
        if (grant != null &&
            (message['type'] == 'operation-request' ||
                message['type'] == 'operation-signal')) {
          await _receiveOperation(message);
        } else if (message['type'] != 'heartbeat') {
          // A paired device has no implicit input/file/media permission.
          close('unsupported_operation');
          return;
        }
      }
    } catch (error) {
      if (isClosed) return;
      if (error is TimeoutException ||
          error is SocketException ||
          error is ConnectionFailure && error.code == 'disconnected') {
        _transportLost();
      } else {
        close('authentication_or_protocol_failed');
      }
    }
  }

  void close([String reason = 'revoked']) {
    if (isClosed) {
      _timer?.cancel();
      _deadline?.cancel();
      if (!_replaced) {
        grant?.revoke();
        lease.revoke();
      }
      return;
    }
    _reason = reason;
    detachReceiver();
    grant?.revoke();
    lease.revoke();
    _timer?.cancel();
    _deadline?.cancel();
    if (enableRecovery && reason != 'peer_revoked') {
      // Authority is already revoked. Bound the final authenticated notice and
      // flush so the peer distinguishes an explicit close from transient loss.
      _closingTransport = () async {
        try {
          await _channel
              .send({'type': 'revoked'})
              .timeout(const Duration(milliseconds: 500));
          await _channel.wire.socket.flush().timeout(
            const Duration(milliseconds: 500),
          );
        } catch (_) {
        } finally {
          _channel.wire.close();
        }
      }();
    } else {
      _channel.wire.close();
    }
    _closed.complete(reason);
  }

  void _transportLost() {
    if (isClosed) return;
    if (!enableRecovery ||
        grant == null ||
        grant!.phase != GrantPhase.active ||
        lease.revoked) {
      close('disconnected');
      return;
    }
    _reason = 'transport_suspended';
    detachReceiver();
    grant!.suspend(); // Synchronous barrier for all operation owners.
    _timer?.cancel();
    _deadline?.cancel();
    _channel.wire.close();
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkSuspended(),
    );
    _closed.complete(_reason!);
  }

  void _checkSuspended() {
    if (!canRecover) {
      _timer?.cancel();
      return;
    }
    if (_checking || _recovering) return;
    _checking = true;
    final serial = _recoverySerial;
    unawaited(() async {
      try {
        await grant!.checkValidity();
        final now = await _clock();
        if (serial == _recoverySerial &&
            !_recovering &&
            !_replaced &&
            !lease.check(now)) {
          close('expired');
        }
      } catch (_) {
        if (serial == _recoverySerial && !_recovering && !_replaced) {
          close('expired');
        }
      } finally {
        _checking = false;
      }
    }());
  }

  void _reserveRecovery(GrantRole role) {
    if (!canRecover ||
        _recovering ||
        grant!.phase != GrantPhase.suspended ||
        grant!.role != role) {
      throw const ConnectionFailure('recovery_unavailable');
    }
    _recovering = true;
    _recoverySerial++;
  }

  Future<void> _checkRecovery() async {
    if (!canRecover || !_recovering) {
      throw const ConnectionFailure('recovery_unavailable');
    }
    await grant!.checkValidity();
    if (!canRecover || !lease.check(await _clock())) {
      close('expired');
      throw const ConnectionFailure('recovery_unavailable');
    }
  }

  /// Used by the authenticated host's bounded socket dispatcher. The routing
  /// id is only a lookup hint; the grant's proof authenticates both identities.
  Future<TrustedConnection> acceptRecovery(
    WireChannel wire,
    Map<String, dynamic> hello,
    void Function() requireAdmission,
  ) async {
    _reserveRecovery(GrantRole.receiver);
    void current() {
      requireAdmission();
      if (wire.isClosed) throw const ConnectionFailure('cancelled');
    }

    try {
      requireAdmission();
      await _checkRecovery();
      if (hello.length != 5 ||
          hello['v'] is! int ||
          hello['v'] != 2 ||
          hello['type'] != 'resume-hello' ||
          hello['grant'] != grant!.binding.encodedId ||
          hello['generation'] is! int) {
        throw const ConnectionFailure('invalid_message');
      }
      final response = await grant!.answerResume(
        ResumeHello(hello['generation'], decodeBytes(hello['challenge'], 32)),
      );
      requireAdmission();
      await _checkRecovery();
      wire.send({
        'v': 2,
        'type': 'resume-response',
        'generation': response.hello.generation,
        'challenge': encodeBytes(response.challenge),
        'proof': encodeBytes(response.proof),
      });
      final finish = await wire.next();
      if (finish.length != 3 ||
          finish['v'] is! int ||
          finish['v'] != 2 ||
          finish['type'] != 'resume-finish') {
        throw const ConnectionFailure('invalid_message');
      }
      requireAdmission();
      await _checkRecovery();
      await grant!.acceptResume(ResumeFinish(decodeBytes(finish['proof'], 32)));
      final cipher = await _channel._recover(wire, grant!, response);
      requireAdmission();
      await _checkRecovery();
      cipher.enableSessionFrames();
      await cipher.send({
        'type': 'resume-active',
        'generation': grant!.generation,
      });
      requireAdmission();
      await _checkRecovery();
      current();
      _replaced = true;
      _timer?.cancel();
      return TrustedConnection(
        cipher,
        peerKey,
        lease,
        _clock,
        grant: grant,
        enableRecovery: true,
      );
    } catch (_) {
      wire.close();
      if (canRecover) grant!.suspend();
      rethrow;
    } finally {
      _recovering = false;
    }
  }
}

/// One cancellable socket recovery attempt. It never pairs again or renews a
/// lease. The process owner supplies retry/backoff and revokes abandoned grants.
class ConnectionRecoveryAttempt {
  ConnectionRecoveryAttempt(
    this.previous, {
    this.timeout = const Duration(seconds: 5),
  });
  final TrustedConnection previous;
  final Duration timeout;
  WireChannel? _wire;
  TrustedConnection? _connection;
  bool _started = false, _cancelled = false;
  Completer<TrustedConnection>? _completion;
  Future<void>? _settled;

  /// Platform calls cannot be cancelled. Exit/cleanup owners can await their
  /// settlement; the caller-facing timeout does not release this reservation.
  Future<void> get settled => _settled ?? Future.value();
  void cancel() {
    _abort(true);
  }

  void _abort(bool explicit) {
    _cancelled = true;
    final connection = _connection;
    if (connection == null) {
      _wire?.close();
    } else {
      // A completed handshake owns its final authenticated close and flush.
      connection.close('cancelled');
    }
    // Explicit cancellation is terminal; a timeout is handled separately below.
    if (explicit) {
      previous.close('cancelled');
    } else if (previous.canRecover) {
      previous.grant!.suspend();
    }
    final completion = _completion;
    if (completion != null && !completion.isCompleted) {
      completion.completeError(
        ConnectionFailure(explicit ? 'cancelled' : 'recovery_timeout'),
      );
    }
  }

  void _current() {
    if (_cancelled || (_wire?.isClosed ?? false)) {
      throw const ConnectionFailure('cancelled');
    }
  }

  Future<TrustedConnection> connect(String address, int port) {
    if (_started) {
      return Future.error(StateError('An attempt cannot be reused.'));
    }
    final completion = _completion = Completer<TrustedConnection>();
    final work = _connect(address, port);
    _settled = work.then<void>(
      (connection) {
        if (!completion.isCompleted) completion.complete(connection);
      },
      onError: (Object error, StackTrace stack) {
        if (!completion.isCompleted) completion.completeError(error, stack);
      },
    );
    return completion.future;
  }

  Future<TrustedConnection> _connect(String address, int port) async {
    if (_started) throw StateError('An attempt cannot be reused.');
    _started = true;
    if (port < 1 || port > 65535 || timeout <= Duration.zero) {
      throw const ConnectionFailure('invalid_input');
    }
    _current();
    previous._reserveRecovery(GrantRole.initiator);
    final deadline = Timer(timeout, () => _abort(false));
    try {
      await previous._checkRecovery();
      _current();
      final socket = await Socket.connect(address, port, timeout: timeout);
      final wire = _wire = WireChannel(socket);
      _current();
      await previous._checkRecovery();
      final endpoint = previous.grant!;
      final hello = await endpoint.beginResume();
      _current();
      await previous._checkRecovery();
      wire.send({
        'v': 2,
        'type': 'resume-hello',
        'grant': endpoint.binding.encodedId,
        'generation': hello.generation,
        'challenge': encodeBytes(hello.challenge),
      });
      final reply = await wire.next();
      if (reply.length != 5 ||
          reply['v'] is! int ||
          reply['v'] != 2 ||
          reply['type'] != 'resume-response' ||
          reply['generation'] is! int ||
          reply['generation'] != hello.generation) {
        throw const ConnectionFailure('invalid_message');
      }
      final response = ResumeResponse(
        hello,
        decodeBytes(reply['challenge'], 32),
        decodeBytes(reply['proof'], 32),
      );
      final finish = await endpoint.finishResume(response);
      _current();
      await previous._checkRecovery();
      final cipher = await previous._channel._recover(wire, endpoint, response);
      _current();
      await previous._checkRecovery();
      wire.send({
        'v': 2,
        'type': 'resume-finish',
        'proof': encodeBytes(finish.proof),
      });
      cipher.enableSessionFrames();
      final active = await cipher.next();
      if (active.length != 2 ||
          active['type'] != 'resume-active' ||
          active['generation'] is! int ||
          active['generation'] != hello.generation) {
        throw const ConnectionFailure('invalid_message');
      }
      _current();
      await previous._checkRecovery();
      _current();
      final result = _connection = TrustedConnection(
        cipher,
        previous.peerKey,
        previous.lease,
        previous._clock,
        grant: endpoint,
        enableRecovery: true,
      );
      previous._replaced = true;
      previous._timer?.cancel();
      result.startMonitoring();
      return result;
    } catch (_) {
      _wire?.close();
      if (previous.canRecover) previous.grant!.suspend();
      rethrow;
    } finally {
      deadline.cancel();
      previous._recovering = false;
    }
  }
}
