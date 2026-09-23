import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:pointycastle/srp/srp6_client.dart';
import 'package:pointycastle/srp/srp6_server.dart';
import 'package:pointycastle/srp/srp6_standard_groups.dart';
import 'package:pointycastle/srp/srp6_verifier_generator.dart';

import 'channel.dart';
import 'identity.dart';
import 'session.dart';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:share_hub_session_api/share_hub_session_api.dart';

const offerLifetime = Duration(minutes: 5);

/// Default budget for one handshake attempt. Hosts and tests may shorten it;
/// an expired attempt is cancelled, never completed late.
const defaultHandshakeTimeout = Duration(seconds: 30);
final _group = SRP6StandardGroups.rfc5054_3072;
FortunaRandom _random() => FortunaRandom()..seed(KeyParameter(randomBytes(32)));
Uint8List _bytes(BigInt value, int length) {
  final result = Uint8List(length);
  for (var i = length - 1; i >= 0; i--) {
    result[i] = (value & BigInt.from(255)).toInt();
    value >>= 8;
  }
  if (value != BigInt.zero) throw const ConnectionFailure('invalid_message');
  return result;
}

String _number(BigInt? value, int length) =>
    encodeBytes(_bytes(value!, length));
BigInt _readNumber(Object? value, int length, {bool public = false}) {
  var result = BigInt.zero;
  for (final byte in decodeBytes(value, length)) {
    result = (result << 8) | BigInt.from(byte);
  }
  if (public && (result <= BigInt.zero || result >= _group.N)) {
    throw const ConnectionFailure('invalid_message');
  }
  return result;
}

Uint8List _transcript(List<Object?> fields) =>
    Uint8List.fromList(utf8.encode(jsonEncode(fields)));
void _message(Map<String, dynamic> message, String type, int version) {
  if (message['v'] != version || message['type'] != type) {
    throw const ConnectionFailure('protocol_mismatch');
  }
}

/// No code, verifier or authorization is persisted. One offer permits five
/// handshake reservations total, even if a caller disconnects without proof.
class PairingOffer {
  PairingOffer(this.issuedMicros)
    : id = encodeBytes(randomBytes(16)),
      code = Random.secure().nextInt(1000000).toString().padLeft(6, '0');
  final String id;
  final String code;
  final int issuedMicros;
  int _attempts = 0;
  bool _consumed = false;
  bool _revoked = false;
  int? _last;
  bool available(int now) {
    if (now < issuedMicros || (_last != null && now < _last!)) _revoked = true;
    _last = now;
    return !_consumed &&
        !_revoked &&
        now < issuedMicros + offerLifetime.inMicroseconds;
  }

  bool reservable(int now) => available(now) && _attempts < 5;
  void reserve(int now) {
    if (!reservable(now)) throw const ConnectionFailure('offer_unavailable');
    _attempts++;
  }

  void consume(int now) {
    if (!available(now)) throw const ConnectionFailure('offer_unavailable');
    _consumed = true;
  }

  void revoke() => _revoked = true;
}

class PairingHost {
  PairingHost({
    required this.identity,
    required this.clock,
    required this.onConnection,
    this.protocolVersion = 1,
    this.handshakeTimeout = defaultHandshakeTimeout,
    this.enableRecovery = false,
    this.grantPolicy = GrantPolicy.shortCode,
  }) {
    if (protocolVersion != 1 && protocolVersion != 2) {
      throw ArgumentError.value(protocolVersion);
    }
    grantPolicy.validate();
    if (protocolVersion == 1 &&
        (grantPolicy.type != GrantPolicy.shortCode.type ||
            grantPolicy.lifetime != GrantPolicy.shortCode.lifetime)) {
      throw ArgumentError.value(grantPolicy, 'grantPolicy');
    }
  }
  final int protocolVersion;
  final bool enableRecovery;
  final Duration handshakeTimeout;
  final GrantPolicy grantPolicy;
  final DeviceIdentity identity;
  final ContinuousClock clock;
  final void Function(TrustedConnection) onConnection;
  final _pending = <WireChannel>{};
  final _sessions = <TrustedConnection>{};
  final _recovery = <String, TrustedConnection>{};
  final _revocations = <String, StreamSubscription<void>>{};
  ServerSocket? _server;
  PairingOffer? _offer;
  int _generation = 0;
  PairingOffer? get offer => _offer;
  int? get port => _server?.port;

  /// Rotate only admission material; keep the authenticated recovery route and
  /// established grants. Old pairing attempts fail their offer identity check.
  Future<void> refreshOffer() async {
    final generation = _generation;
    final server = _server;
    if (server == null) throw const ConnectionFailure('admission_closed');
    _offer?.revoke();
    _offer = null;
    final now = await clock();
    if (generation != _generation || !identical(server, _server)) {
      throw const ConnectionFailure('cancelled');
    }
    _offer = PairingOffer(now);
  }

  Future<void> open({InternetAddress? address}) async {
    await stopAccepting();
    final generation = _generation;
    final now = await clock();
    final server = await ServerSocket.bind(
      address ?? InternetAddress.anyIPv4,
      0,
    );
    if (generation != _generation) {
      await server.close();
      return;
    }
    _offer = PairingOffer(now);
    _server = server;
    server.listen((socket) {
      if (_pending.length >= 4 || generation != _generation) {
        socket.destroy();
        return;
      }
      final wire = WireChannel(socket);
      _pending.add(wire);
      unawaited(_accept(wire, generation));
    });
  }

  Future<void> _accept(WireChannel wire, int generation) async {
    final timeout = Timer(handshakeTimeout, wire.close);
    TrustedConnection? connection;
    final offer = _offer;
    var reserved = false, recovery = false;
    try {
      final hello = await wire.next();
      if (hello['type'] == 'resume-hello') {
        recovery = true;
        if (!enableRecovery ||
            protocolVersion != 2 ||
            hello['grant'] is! String) {
          throw const ConnectionFailure('recovery_unavailable');
        }
        final previous = _recovery[hello['grant']];
        if (previous == null) {
          throw const ConnectionFailure('recovery_unavailable');
        }
        connection = await previous.acceptRecovery(wire, hello, () {
          if (generation != _generation || _server == null) {
            throw const ConnectionFailure('cancelled');
          }
        });
        _publish(connection);
        return;
      }
      if (offer == null) throw const ConnectionFailure('offer_unavailable');
      reserved = true;
      offer.reserve(await clock());
      _message(hello, 'hello', protocolVersion);
      final peer = encodeBytes(decodeBytes(hello['key'], 32));
      final nonce = encodeBytes(decodeBytes(hello['nonce'], 32));
      if (peer == identity.encodedKey) {
        throw const ConnectionFailure('same_identity');
      }
      final salt = randomBytes(32);
      final context = [
        protocolVersion,
        offer.id,
        identity.encodedKey,
        peer,
        nonce,
        encodeBytes(randomBytes(32)),
      ];
      final account = _transcript(context);
      final verifier =
          SRP6VerifierGenerator(
            group: _group,
            digest: SHA256Digest(),
          ).generateVerifier(
            salt,
            account,
            Uint8List.fromList(utf8.encode(offer.code)),
          );
      final srp = SRP6Server(
        group: _group,
        v: verifier,
        digest: SHA256Digest(),
        random: _random(),
      );
      final b = _number(srp.generateServerCredentials(), 384);
      wire.send({
        'v': protocolVersion,
        'type': 'challenge',
        'context': context,
        'salt': encodeBytes(salt),
        'b': b,
      });
      final proof = await wire.next();
      _message(proof, 'proof', protocolVersion);
      final a = _readNumber(proof['a'], 384, public: true);
      final transcript = _transcript([
        ...context,
        encodeBytes(salt),
        b,
        proof['a'],
      ]);
      srp.calculateSecret(a);
      if (!srp.verifyClientEvidenceMessage(_readNumber(proof['m1'], 32)) ||
          !await DeviceIdentity.verify(peer, proof['signature'], transcript)) {
        throw const ConnectionFailure('authentication_failed');
      }
      wire.send({
        'v': protocolVersion,
        'type': 'verified',
        'm2': _number(srp.calculateServerEvidenceMessage(), 32),
        'signature': await identity.sign(transcript),
      });
      final cipher = await CipherChannel.create(
        wire,
        _bytes(srp.calculateSessionKey()!, 32),
        transcript,
        host: true,
      );
      final ready = await cipher.next();
      if (ready['type'] != 'ready') {
        throw const ConnectionFailure('invalid_message');
      }
      final now = await clock();
      if (generation != _generation || !identical(offer, _offer)) {
        throw const ConnectionFailure('cancelled');
      }
      // Atomic consumption, with no await between generation check and consume.
      offer.consume(now);
      final lease = SessionLease(startedMicros: now, policy: grantPolicy);
      final recoverable =
          enableRecovery &&
          protocolVersion == 2 &&
          ready['recovery'] is int &&
          ready['recovery'] == 1;
      connection = TrustedConnection(
        cipher,
        peer,
        lease,
        clock,
        enableRecovery: recoverable,
        grant: protocolVersion == 2
            ? await _grant(
                cipher,
                peer,
                identity,
                _bytes(srp.calculateSessionKey()!, 32),
                transcript,
                now,
                clock,
                GrantRole.receiver,
                grantPolicy,
              )
            : null,
      );
      if (generation != _generation || !identical(offer, _offer)) {
        throw const ConnectionFailure('cancelled');
      }
      await cipher.send({
        'type': 'connected',
        'lifetimeSeconds': grantPolicy.lifetime.inSeconds,
        if (protocolVersion == 2) 'grantType': grantPolicy.type,
        if (recoverable) 'recovery': 1,
      });
      if (connection.grant case final endpoint?) {
        await _activateGrant(cipher, endpoint);
      }
      if (generation != _generation || !identical(offer, _offer)) {
        throw const ConnectionFailure('cancelled');
      }
      _publish(connection);
    } catch (_) {
      connection?.close('handshake_failed');
      wire.close();
    } finally {
      // A silent or malformed new-pairing socket still consumes a reservation.
      // A recovery preface never guesses or consumes a short code.
      if (!reserved && !recovery && offer != null) {
        try {
          offer.reserve(await clock());
        } catch (_) {}
      }
      timeout.cancel();
      _pending.remove(wire);
    }
  }

  void _publish(TrustedConnection connection) {
    _sessions.add(connection);
    if (connection.enableRecovery) {
      final grant = connection.grant!;
      final id = grant.binding.encodedId;
      unawaited(_revocations.remove(id)?.cancel());
      _recovery[id] = connection;
      _revocations[id] = grant.invalidated.listen((_) {
        if (grant.phase == GrantPhase.revoked &&
            identical(_recovery[id], connection)) {
          _recovery.remove(id);
          unawaited(_revocations.remove(id)?.cancel());
        }
      });
    }
    connection.startMonitoring();
    unawaited(
      connection.whenClosed.then((_) {
        _sessions.remove(connection);
        if (!connection.canRecover &&
            connection.grant != null &&
            identical(
              _recovery[connection.grant!.binding.encodedId],
              connection,
            )) {
          _recovery.remove(connection.grant!.binding.encodedId);
        }
      }),
    );
    onConnection(connection);
  }

  Future<void> stopAccepting() async {
    _generation++;
    _offer?.revoke();
    _offer = null;
    for (final connection in _recovery.values.toList()) {
      if (connection.isClosed) connection.close('revoked');
    }
    _recovery.clear();
    final subscriptions = _revocations.values.toList();
    _revocations.clear();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    for (final wire in _pending.toList()) {
      wire.close();
    }
    final server = _server;
    _server = null;
    await server?.close();
  }

  Future<void> close() async {
    for (final session in _sessions.toList()) {
      session.close();
    }
    await stopAccepting();
  }
}

/// Cancellation owns the socket, including a socket arriving after cancellation.
/// Retrying constructs a new attempt and requires a fresh unconsumed code.
class PairingAttempt {
  PairingAttempt({
    required this.identity,
    required this.clock,
    this.protocolVersion = 1,
    this.handshakeTimeout = defaultHandshakeTimeout,
    this.enableRecovery = false,
    this.grantPolicy = GrantPolicy.shortCode,
  }) {
    if (protocolVersion != 1 && protocolVersion != 2) {
      throw ArgumentError.value(protocolVersion);
    }
    grantPolicy.validate();
    if (protocolVersion == 1 &&
        (grantPolicy.type != GrantPolicy.shortCode.type ||
            grantPolicy.lifetime != GrantPolicy.shortCode.lifetime)) {
      throw ArgumentError.value(grantPolicy, 'grantPolicy');
    }
  }
  final int protocolVersion;
  final bool enableRecovery;
  final Duration handshakeTimeout;
  final GrantPolicy grantPolicy;
  final DeviceIdentity identity;
  final ContinuousClock clock;
  bool _cancelled = false;
  bool _started = false;
  WireChannel? _wire;
  TrustedConnection? _connection;
  void cancel() {
    _cancelled = true;
    _connection?.close('cancelled');
    _wire?.close();
  }

  void _check() {
    if (_cancelled) throw const ConnectionFailure('cancelled');
  }

  Future<TrustedConnection> connect(
    String address,
    int port,
    String code, {
    String? expectedPeerKey,
  }) async {
    if (_started) throw StateError('An attempt cannot be reused.');
    _started = true;
    if (!RegExp(r'^[0-9]{6}$').hasMatch(code) || port < 1 || port > 65535) {
      throw const ConnectionFailure('invalid_input');
    }
    final timeout = Timer(handshakeTimeout, cancel);
    try {
      _check();
      final Socket socket;
      try {
        socket = await Socket.connect(
          address,
          port,
          timeout: const Duration(seconds: 5),
        );
      } on SocketException {
        throw const ConnectionFailure('signal_unreachable');
      } on TimeoutException {
        throw const ConnectionFailure('signal_unreachable');
      }
      final wire = _wire = WireChannel(socket);
      _check();
      final nonce = encodeBytes(randomBytes(32));
      wire.send({
        'v': protocolVersion,
        'type': 'hello',
        'key': identity.encodedKey,
        'nonce': nonce,
      });
      final challenge = await wire.next();
      _message(challenge, 'challenge', protocolVersion);
      final context = challenge['context'];
      if (context is! List ||
          context.length != 6 ||
          context[0] != protocolVersion ||
          context[3] != identity.encodedKey ||
          context[4] != nonce) {
        throw const ConnectionFailure('authentication_failed');
      }
      decodeBytes(context[1], 16);
      decodeBytes(context[5], 32);
      final peer = encodeBytes(decodeBytes(context[2], 32));
      if (peer == identity.encodedKey ||
          (expectedPeerKey != null && peer != expectedPeerKey)) {
        throw const ConnectionFailure('identity_mismatch');
      }
      final salt = decodeBytes(challenge['salt'], 32);
      final srp = SRP6Client(
        group: _group,
        digest: SHA256Digest(),
        random: _random(),
      );
      final a = _number(
        srp.generateClientCredentials(
          salt,
          _transcript(context),
          Uint8List.fromList(utf8.encode(code)),
        ),
        384,
      );
      srp.calculateSecret(_readNumber(challenge['b'], 384, public: true));
      final transcript = _transcript([
        ...context,
        challenge['salt'],
        challenge['b'],
        a,
      ]);
      wire.send({
        'v': protocolVersion,
        'type': 'proof',
        'a': a,
        'm1': _number(srp.calculateClientEvidenceMessage(), 32),
        'signature': await identity.sign(transcript),
      });
      final verified = await wire.next();
      _message(verified, 'verified', protocolVersion);
      if (!srp.verifyServerEvidenceMessage(_readNumber(verified['m2'], 32)) ||
          !await DeviceIdentity.verify(
            peer,
            verified['signature'],
            transcript,
          )) {
        throw const ConnectionFailure('authentication_failed');
      }
      final cipher = await CipherChannel.create(
        wire,
        _bytes(srp.calculateSessionKey()!, 32),
        transcript,
        host: false,
      );
      _check();
      // Conservative local deadline: the host commits only AFTER this message.
      // No peer-supplied wall clock or latency can extend the host's eight hours.
      final localStart = await clock();
      await cipher.send({
        'type': 'ready',
        if (enableRecovery && protocolVersion == 2) 'recovery': 1,
      });
      final grant = await cipher.next();
      if (grant['type'] != 'connected' ||
          grant['lifetimeSeconds'] != grantPolicy.lifetime.inSeconds ||
          (grant['grantType'] ?? GrantPolicy.shortCode.type) !=
              grantPolicy.type) {
        throw const ConnectionFailure('invalid_message');
      }
      _check();
      final connection = _connection = TrustedConnection(
        cipher,
        peer,
        SessionLease(startedMicros: localStart, policy: grantPolicy),
        clock,
        enableRecovery:
            enableRecovery &&
            protocolVersion == 2 &&
            grant['recovery'] is int &&
            grant['recovery'] == 1,
        grant: protocolVersion == 2
            ? await _grant(
                cipher,
                peer,
                identity,
                _bytes(srp.calculateSessionKey()!, 32),
                transcript,
                localStart,
                clock,
                GrantRole.initiator,
                grantPolicy,
              )
            : null,
      );
      if (connection.grant case final endpoint?) {
        await _activateGrant(cipher, endpoint);
      }
      if (!connection.lease.check(await clock())) {
        throw const ConnectionFailure('expired');
      }
      _check();
      connection.startMonitoring();
      return connection;
    } catch (error) {
      _connection?.close('handshake_failed');
      _wire?.close();
      if (_cancelled) throw const ConnectionFailure('cancelled');
      if (error is ConnectionFailure) rethrow;
      throw const ConnectionFailure('connection_failed');
    } finally {
      timeout.cancel();
    }
  }
}

// Initial transport activation uses the already authenticated pairing channel.
// Final acknowledgement prevents the initiator publishing a usable connection
// before the receiver verifies its proof. Pairing owns the timeout/cancellation.
Future<void> _activateGrant(
  CipherChannel cipher,
  GrantEndpoint endpoint,
) async {
  if (endpoint.role == GrantRole.initiator) {
    final hello = await endpoint.beginResume();
    await cipher.send({
      'type': 'grant-hello',
      'generation': hello.generation,
      'challenge': encodeBytes(hello.challenge),
    });
    final response = await cipher.next();
    if (response['type'] != 'grant-response' ||
        response['generation'] != hello.generation) {
      throw const ConnectionFailure('invalid_message');
    }
    final finish = await endpoint.finishResume(
      ResumeResponse(
        hello,
        decodeBytes(response['challenge'], 32),
        decodeBytes(response['proof'], 32),
      ),
    );
    cipher.enableSessionFrames();
    await cipher.send({
      'type': 'grant-finish',
      'proof': encodeBytes(finish.proof),
    });
    final acknowledgement = await cipher.next();
    if (acknowledgement['type'] != 'grant-active' ||
        acknowledgement['generation'] != hello.generation) {
      throw const ConnectionFailure('invalid_message');
    }
    await endpoint.checkValidity();
  } else {
    final message = await cipher.next();
    if (message['type'] != 'grant-hello' || message['generation'] != 1) {
      throw const ConnectionFailure('invalid_message');
    }
    final response = await endpoint.answerResume(
      ResumeHello(1, decodeBytes(message['challenge'], 32)),
    );
    await cipher.send({
      'type': 'grant-response',
      'generation': response.hello.generation,
      'challenge': encodeBytes(response.challenge),
      'proof': encodeBytes(response.proof),
    });
    final finish = await cipher.next();
    if (finish['type'] != 'grant-finish') {
      throw const ConnectionFailure('invalid_message');
    }
    await endpoint.acceptResume(ResumeFinish(decodeBytes(finish['proof'], 32)));
    cipher.enableSessionFrames();
    await cipher.send({
      'type': 'grant-active',
      'generation': endpoint.generation,
    });
  }
}

// Pairing owns bootstrap: caller/UI input cannot mint a remote grant. The
// exporter is domain separated from transport keys and never sent on the wire.
Future<GrantEndpoint> _grant(
  CipherChannel cipher,
  String peer,
  DeviceIdentity identity,
  List<int> srpKey,
  List<int> transcript,
  int started,
  ContinuousClock clock,
  GrantRole role,
  GrantPolicy policy,
) async {
  final exporter =
      await crypto.Hkdf(hmac: crypto.Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: crypto.SecretKey(srpKey),
        nonce: transcript,
        info: utf8.encode('chuanchuan.grant.v2/recovery'),
      );
  final local = identity.publicKey.bytes;
  final remote = decodeBytes(peer, 32);
  return GrantEndpoint.fromAuthenticatedPairing(
    binding: GrantBinding(
      id: decodeBytes(cipher.sessionId, 32),
      initiatorKey: role == GrantRole.initiator ? local : remote,
      receiverKey: role == GrantRole.receiver ? local : remote,
      policy: policy,
    ),
    role: role,
    establishedMicros: started,
    recoverySecret: await exporter.extractBytes(),
    clock: clock,
    // Resource owners subscribe through the public invalidation stream.
    // There are no media/input/file resources in this heartbeat owner.
    onInvalidated: () {},
  );
}
