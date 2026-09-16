import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

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

  Future<void> send(Map<String, dynamic> body) async {
    if (_sent >= 0x100000000) throw const ConnectionFailure('session_limit');
    final sequence = _sent++;
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(body)),
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
class TrustedConnection {
  TrustedConnection(this._channel, this.peerKey, this.lease, this._clock);
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
        if (message['type'] != 'heartbeat') {
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
    lease.revoke();
    _timer?.cancel();
    _deadline?.cancel();
    _channel.wire.close();
    _closed.complete(reason);
  }
}
