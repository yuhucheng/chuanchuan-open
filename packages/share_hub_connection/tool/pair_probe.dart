// Dual-machine initiator probe: completes the short-code pairing handshake
// against an explicit peer, without the Flutter engine.
//
// Why it exists: the client UI can only be driven by clicking, and the short
// code lives for five minutes, so a run has to be launched within seconds of
// sampling the peer's advertisement. This probe takes the endpoint and code as
// arguments and reports the outcome as one machine-readable line.
//
// Usage (run from packages/share_hub_connection, which is pure Dart):
//   dart run tool/pair_probe.dart --self-test
//   dart run tool/pair_probe.dart <host> <port> <6-digit code> [expectedPeerKey] [--hold=<seconds>]
//
// "host" may be a ".local" name or an IPv4 address. "expectedPeerKey" is the
// 44-character key from the peer's TXT record; when given, the handshake must
// bind to exactly that identity or the run fails.
//
// The probe uses a fresh random identity unless --seed-hex is supplied, so it
// never impersonates the installed client. It answers one question only: does
// this machine complete the pairing protocol with that peer right now.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:share_hub_connection/share_hub_connection.dart';

final _start = Stopwatch()..start();

Future<int> _clock() async => _start.elapsedMicroseconds;

List<int> _randomSeed() {
  final random = Random.secure();
  return List<int>.generate(32, (_) => random.nextInt(256));
}

List<int> _parseSeed(String text) {
  if (text.length != 64 || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(text)) {
    throw const FormatException('--seed-hex must be 64 hex characters');
  }
  return [
    for (var index = 0; index < 64; index += 2)
      int.parse(text.substring(index, index + 2), radix: 16),
  ];
}

Future<int> _selfTest() async {
  final hostIdentity = await DeviceIdentity.fromSeed(_randomSeed());
  final clientIdentity = await DeviceIdentity.fromSeed(_randomSeed());
  var accepted = 0;
  final host = PairingHost(
    identity: hostIdentity,
    clock: _clock,
    protocolVersion: 2,
    onConnection: (_) => accepted++,
  );
  await host.open();
  try {
    final connection = await PairingAttempt(
      identity: clientIdentity,
      clock: _clock,
      protocolVersion: 2,
    ).connect('127.0.0.1', host.port!, host.offer!.code);
    final bound = connection.peerKey == hostIdentity.encodedKey;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    stdout.writeln('RESULT=${bound ? 'connected' : 'identity_mismatch'}');
    stdout.writeln('role=client peer_id=${connection.peerId}');
    stdout.writeln('host_accepted=$accepted');
    connection.close('probe_done');
    await connection.whenClosed;
    return bound && accepted == 1 ? 0 : 1;
  } catch (error) {
    stdout.writeln('RESULT=failed error=$error');
    return 1;
  } finally {
    await host.close();
  }
}

Future<int> _pair(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: <host> <port> <6-digit code> [expectedPeerKey]');
    return 2;
  }
  final host = args[0];
  final port = int.tryParse(args[1]);
  final code = args[2];
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('port must be 1..65535');
    return 2;
  }
  final expectedKey = args.length > 3 && !args[3].startsWith('--')
      ? args[3]
      : null;
  var seed = _randomSeed();
  var hold = Duration.zero;
  for (final argument in args.skip(3)) {
    if (argument.startsWith('--hold=')) {
      hold = Duration(seconds: int.parse(argument.substring(7)));
    } else if (argument.startsWith('--seed-hex=')) {
      seed = _parseSeed(argument.substring(11));
    }
  }
  final identity = await DeviceIdentity.fromSeed(seed);
  stdout.writeln('self_key=${identity.encodedKey}');
  stdout.writeln('target=$host:$port expected_key=${expectedKey ?? '(not given)'}');
  final attempt = PairingAttempt(
    identity: identity,
    clock: _clock,
    protocolVersion: 2,
  );
  final timeout = Timer(const Duration(seconds: 20), attempt.cancel);
  try {
    final connection = await attempt.connect(
      host,
      port,
      code,
      expectedPeerKey: expectedKey,
    );
    final hours =
        (connection.lease.expiresMicros - connection.lease.startedMicros) ~/
        Duration.microsecondsPerHour;
    stdout.writeln('RESULT=connected');
    stdout.writeln('peer_id=${connection.peerId}');
    stdout.writeln('peer_key=${connection.peerKey}');
    stdout.writeln('session_id=${connection.sessionId}');
    stdout.writeln('capabilities=${connection.capabilities}');
    stdout.writeln('lease_hours=$hours');
    if (hold > Duration.zero) {
      connection.startMonitoring();
      await Future<void>.delayed(hold);
      stdout.writeln('still_open=${!connection.isClosed}');
    }
    connection.close('probe_done');
    final reason = await connection.whenClosed;
    stdout.writeln('closed=$reason');
    return 0;
  } on ConnectionFailure catch (failure) {
    stdout.writeln('RESULT=failed error=${failure.code}');
    return 1;
  } catch (error) {
    stdout.writeln('RESULT=failed error=$error');
    return 1;
  } finally {
    timeout.cancel();
  }
}

// Receiver-side probe: this machine accepts a pairing from a real peer, which
// the initiator-side _pair cannot exercise. It binds an ordinary socket so the
// peer can connect by explicit address:port plus the short code, with no
// dependence on discovery or on this machine's own Flutter UI.
//
// Usage:
//   dart run tool/pair_probe.dart --host [--hold=<seconds>] [--revoke-after=<seconds>]
//                                [--ready-file=<path>]
//
// --revoke-after exercises the "allow connection" switch: accepting is stopped
// at that mark while established sessions are left alone, matching
// PairingHost.stopAccepting(). --ready-file receives "port=...\ncode=..." so a
// caller can hand the peer its address without scraping stdout.
Future<int> _serve(List<String> args) async {
  var hold = const Duration(seconds: 180);
  var revokeAfter = Duration.zero;
  String? readyFile;
  for (final argument in args) {
    if (argument.startsWith('--hold=')) {
      hold = Duration(seconds: int.parse(argument.substring(7)));
    } else if (argument.startsWith('--revoke-after=')) {
      revokeAfter = Duration(seconds: int.parse(argument.substring(15)));
    } else if (argument.startsWith('--ready-file=')) {
      readyFile = argument.substring(13);
    }
  }
  final identity = await DeviceIdentity.fromSeed(_randomSeed());
  final connections = <TrustedConnection>[];
  final host = PairingHost(
    identity: identity,
    clock: _clock,
    protocolVersion: 2,
    onConnection: (connection) {
      connections.add(connection);
      stdout.writeln(
        'HOST_CONNECTED t=${_start.elapsedMilliseconds}ms '
        'peer_id=${connection.peerId} peer_key=${connection.peerKey} '
        'session_id=${connection.sessionId} '
        'capabilities=${connection.capabilities}',
      );
    },
  );
  await host.open(address: InternetAddress.anyIPv4);
  final port = host.port;
  if (port == null) {
    stderr.writeln('HOST_FAILED reason=not_bound');
    return 1;
  }
  final code = host.offer!.code;
  stdout.writeln(
    'HOST_BOUND port=$port code=$code identity=${identity.encodedKey} '
    'lifetime_seconds=${offerLifetime.inSeconds}',
  );
  if (readyFile != null) {
    // A bad path must never take the listener down: stdout already carries the
    // same facts, and this file is only a convenience for the caller.
    try {
      File(readyFile).writeAsStringSync('port=$port\ncode=$code\n');
    } catch (error) {
      stdout.writeln('HOST_READY_FILE_FAILED error=$error');
    }
  }
  Timer? revokeTimer;
  if (revokeAfter > Duration.zero) {
    revokeTimer = Timer(revokeAfter, () async {
      await host.stopAccepting();
      final alive = connections.where((item) => !item.isClosed).length;
      stdout.writeln(
        'HOST_REVOKED t=${_start.elapsedMilliseconds}ms '
        'stopped_accepting=1 sessions_alive_after_revoke=$alive',
      );
    });
  }
  await Future<void>.delayed(hold);
  revokeTimer?.cancel();
  final aliveHeld = connections.where((item) => !item.isClosed).length;
  stdout.writeln(
    'HOST_HELD sessions=${connections.length} alive=$aliveHeld',
  );
  await host.close();
  final aliveClosed = connections.where((item) => !item.isClosed).length;
  stdout.writeln('HOST_DONE sessions=${connections.length} alive=$aliveClosed');
  return 0;
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--host') {
    exit(await _serve(args.skip(1).where((value) => value.isNotEmpty).toList()));
  }
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/pair_probe.dart --self-test | --host '
      '[--hold=<seconds>] [--revoke-after=<seconds>] [--ready-file=<path>] | '
      '<host> <port> <6-digit code> [expectedPeerKey] [--hold=<seconds>] '
      '[--seed-hex=<64 hex>]',
    );
    exit(2);
  }
  final status = args.first == '--self-test'
      ? await _selfTest()
      : await _pair(args.where((value) => value.isNotEmpty).toList());
  exit(status);
}
