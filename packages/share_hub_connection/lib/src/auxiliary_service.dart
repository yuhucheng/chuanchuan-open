import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'identity.dart';

/// Cancelling an auxiliary request never revokes or creates an end-to-end grant.
final class AuxiliaryCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  void throwIfCancelled() {
    if (_cancelled) throw const AuxiliaryFailure('cancelled');
  }

  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void removeOnCancel(void Function() listener) => _listeners.remove(listener);
}

final class AuxiliaryFailure implements Exception {
  const AuxiliaryFailure(this.code);
  final String code;

  @override
  String toString() => 'AuxiliaryFailure($code)';
}

/// A relay allocation only. It is not pairing, media, or input authority.
final class AuxiliaryTurnCredential {
  AuxiliaryTurnCredential({
    required List<String> urls,
    required this.username,
    required this.credential,
    required this.expiresAt,
  }) : urls = List.unmodifiable(urls);

  final List<String> urls;
  final String username;
  final String credential;
  final DateTime expiresAt;

  bool validAt(DateTime now) => now.toUtc().isBefore(expiresAt.toUtc());

  @override
  String toString() => 'AuxiliaryTurnCredential(redacted)';
}

abstract interface class AuxiliaryTransport {
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  );
}

/// Desktop HTTPS transport. TLS verification uses the platform trust store.
final class HttpsAuxiliaryTransport implements AuxiliaryTransport {
  factory HttpsAuxiliaryTransport(
    Uri endpoint, {
    HttpClient? client,
    Duration timeout = const Duration(seconds: 5),
  }) {
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.path != '' && endpoint.path != '/' ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        timeout <= Duration.zero) {
      throw ArgumentError(
        'An HTTPS service origin and positive timeout are required',
      );
    }
    return HttpsAuxiliaryTransport._(endpoint, client ?? HttpClient(), timeout);
  }

  HttpsAuxiliaryTransport._(this.endpoint, this._client, this.timeout);

  final Uri endpoint;
  final Duration timeout;
  final HttpClient _client;

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  ) async {
    cancellation.throwIfCancelled();
    HttpClientRequest? request;
    final cancelled = Completer<void>();
    void abort() {
      request?.abort();
      if (!cancelled.isCompleted) cancelled.complete();
    }

    Future<T> waitFor<T>(Future<T> operation) => Future.any<T>([
      operation,
      cancelled.future.then<T>(
        (_) => throw const AuxiliaryFailure('cancelled'),
      ),
    ]).timeout(timeout);
    cancellation.onCancel(abort);
    var abandoned = false;
    try {
      final opening = _client.postUrl(endpoint.resolve(path));
      unawaited(
        opening.then((lateRequest) {
          if (abandoned || cancellation.isCancelled) lateRequest.abort();
        }, onError: (Object _) {}),
      );
      final opened = await waitFor(opening);
      request = opened;
      if (cancellation.isCancelled) {
        opened.abort();
        cancellation.throwIfCancelled();
      }
      opened.headers.contentType = ContentType.json;
      opened.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      final payload = utf8.encode(jsonEncode(body));
      opened.contentLength = payload.length;
      opened.add(payload);
      final response = await waitFor(opened.close());
      cancellation.throwIfCancelled();
      final responseLimit = path == '/v1/signal/poll' ? 210000 : 4096;
      final bytes = await waitFor(
        response.fold<List<int>>(<int>[], (value, chunk) {
          if (value.length + chunk.length > responseLimit) {
            throw const AuxiliaryFailure('invalid_response');
          }
          value.addAll(chunk);
          return value;
        }),
      );
      cancellation.throwIfCancelled();
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const AuxiliaryFailure('invalid_response');
      }
      if (response.statusCode == 200) return decoded;
      final error = decoded['error'];
      if (error is String &&
          (response.statusCode == 400 && error == 'invalid_request' ||
              response.statusCode == 400 &&
                  (error == 'invalid_relay_claim' ||
                      error == 'invalid_relay_envelope' ||
                      error == 'relay_message_limit') ||
              response.statusCode == 403 &&
                  (error == 'invalid_proof' ||
                      error == 'not_eligible' ||
                      error == 'not_member') ||
              response.statusCode == 409 &&
                  (error == 'room_closed' || error == 'stale_relay_message') ||
              response.statusCode == 429 && error == 'capacity_limited')) {
        throw AuxiliaryFailure(error);
      }
      throw const AuxiliaryFailure('server_error');
    } on AuxiliaryFailure {
      request?.abort();
      rethrow;
    } on TimeoutException {
      abandoned = true;
      request?.abort();
      cancellation.throwIfCancelled();
      throw const AuxiliaryFailure('timeout');
    } on TlsException {
      request?.abort();
      cancellation.throwIfCancelled();
      throw const AuxiliaryFailure('tls_error');
    } on SocketException {
      request?.abort();
      cancellation.throwIfCancelled();
      throw const AuxiliaryFailure('unreachable');
    } on HttpException {
      request?.abort();
      cancellation.throwIfCancelled();
      throw const AuxiliaryFailure('unreachable');
    } on FormatException {
      request?.abort();
      throw const AuxiliaryFailure('invalid_response');
    } finally {
      cancellation.removeOnCancel(abort);
    }
  }

  void close() => _client.close(force: true);
}

/// Implements the public possession challenge. Registration is idempotent at
/// the service, and never means the peer has granted a connection operation.
final class AuxiliaryServiceClient {
  AuxiliaryServiceClient(this.transport, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AuxiliaryTransport transport;
  final DateTime Function() _now;

  /// Reuse this ID across retries of one allocation, and use a fresh ID for
  /// renewal. A lost response must not spend another active TURN quota slot.
  static String newTurnRequestId() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(16, (_) => random.nextInt(256)));
  }

  Future<void> register(
    DeviceIdentity identity, {
    required AuxiliaryCancellation cancellation,
  }) async {
    final result = await _prove(
      identity,
      'register',
      '/v1/devices/register',
      cancellation,
    );
    if (result.length != 1 || result['deviceId'] != identity.id) {
      throw const AuxiliaryFailure('invalid_response');
    }
  }

  /// Retires this identity's official registration after fresh possession
  /// proof. Local grants must be revoked by their process owner immediately;
  /// an unavailable auxiliary service cannot delay that local action.
  Future<void> revokeRegistration(
    DeviceIdentity identity, {
    required AuxiliaryCancellation cancellation,
  }) async {
    final result = await _prove(
      identity,
      'revoke',
      '/v1/devices/revoke',
      cancellation,
    );
    if (result.length != 1 || result['revoked'] != true) {
      throw const AuxiliaryFailure('invalid_response');
    }
  }

  Future<AuxiliaryTurnCredential> issueTurn(
    DeviceIdentity identity, {
    required AuxiliaryCancellation cancellation,
    String? requestId,
  }) async {
    final result = await _prove(
      identity,
      'turn',
      '/v1/turn/credentials',
      cancellation,
      extraFields: {'requestId': requestId ?? newTurnRequestId()},
    );
    final expiry = DateTime.tryParse(
      result['expiresAt'] is String ? result['expiresAt'] as String : '',
    );
    final servers = result['iceServers'];
    if (expiry == null ||
        !expiry.isUtc ||
        servers is! List ||
        servers.length != 1 ||
        servers.single is! Map<String, dynamic>) {
      throw const AuxiliaryFailure('invalid_response');
    }
    final server = servers.single as Map<String, dynamic>;
    final urls = server['urls'];
    final username = server['username'];
    final credential = server['credential'];
    if (urls is! List ||
        urls.isEmpty ||
        urls.length > 4 ||
        urls.any(
          (url) =>
              url is! String ||
              url.length > 512 ||
              !RegExp(r'^turns?:[^\s@#]+$').hasMatch(url),
        ) ||
        username is! String ||
        username.isEmpty ||
        username.length > 512 ||
        credential is! String ||
        credential.isEmpty ||
        credential.length > 512) {
      throw const AuxiliaryFailure('invalid_response');
    }
    final lease = AuxiliaryTurnCredential(
      urls: List<String>.from(urls),
      username: username,
      credential: credential,
      expiresAt: expiry,
    );
    cancellation.throwIfCancelled();
    if (!lease.validAt(_now())) {
      throw const AuxiliaryFailure('expired_credential');
    }
    return lease;
  }

  Future<Map<String, Object?>> _prove(
    DeviceIdentity identity,
    String purpose,
    String path,
    AuxiliaryCancellation cancellation, {
    Map<String, String> extraFields = const {},
  }) async {
    cancellation.throwIfCancelled();
    final challenge = await transport.post('/v1/aux/challenge', {
      'publicKey': identity.encodedKey,
      'purpose': purpose,
    }, cancellation);
    cancellation.throwIfCancelled();
    final nonce = challenge['nonce'];
    final expiresAt = challenge['expiresAt'];
    if (challenge.length != 2 ||
        nonce is! String ||
        expiresAt is! int ||
        expiresAt <= 0) {
      throw const AuxiliaryFailure('invalid_response');
    }
    late final List<int> nonceBytes;
    try {
      nonceBytes = decodeBytes(nonce, 32);
    } on ConnectionFailure {
      throw const AuxiliaryFailure('invalid_response');
    }
    final transcript = <int>[
      ...utf8.encode('chuanchuan-aux-v1'),
      0,
      ...utf8.encode(purpose),
      0,
      ...identity.publicKey.bytes,
      ...nonceBytes,
    ];
    final signature = await identity.sign(transcript);
    cancellation.throwIfCancelled();
    final result = await transport.post(path, {
      'publicKey': identity.encodedKey,
      'nonce': nonce,
      'signature': signature,
      ...extraFields,
    }, cancellation);
    cancellation.throwIfCancelled();
    return result;
  }
}
