import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'channel.dart';
import 'identity.dart';
import 'operation_router.dart';

part 'trusted_connection.dart';

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

  Future<Map<String, dynamic>> next({void Function()? onFrame}) async {
    final envelope = await wire.next();
    // The ownership boundary is frame dequeue, before asynchronous decryption.
    // Capturing before wire.next would discard new consumers' future traffic.
    onFrame?.call();
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
