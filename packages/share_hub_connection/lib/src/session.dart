import 'dart:async';
import 'dart:convert';

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
  CipherChannel._(this.wire, this._sendKey, this._receiveKey, this.sessionId);
  final WireChannel wire;
  final SecretKey _sendKey;
  final SecretKey _receiveKey;
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
  });

  /// Opt-in v2 contract material. No remote media capabilities are implied.
  final GrantEndpoint? grant;
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
      close('operation_transport_failed');
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
      close('clock_unavailable');
    }
  }

  Future<bool> check() async {
    if (isClosed) return false;
    if (_checking) return false;
    _checking = true;
    try {
      if (!lease.check(await _clock())) {
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
    } catch (_) {
      close('clock_or_transport_failed');
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
        if (!lease.check(await _clock())) {
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
    } catch (_) {
      close('disconnected');
    }
  }

  void close([String reason = 'revoked']) {
    if (isClosed) return;
    _reason = reason;
    detachReceiver();
    grant?.revoke();
    lease.revoke();
    _timer?.cancel();
    _deadline?.cancel();
    _channel.wire.close();
    _closed.complete(reason);
  }
}
