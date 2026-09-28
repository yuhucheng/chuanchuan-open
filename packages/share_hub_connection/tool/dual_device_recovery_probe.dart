// Two-device recovery acceptance. The host owns a disposable TCP proxy for
// the initial pairing wire; dropping only that proxy simulates a real socket
// break without changing either machine's network or firewall configuration.
// The recovery listener remains directly reachable on the host.
//
// Host:   dart run tool/dual_device_recovery_probe.dart --host <private-ready-file>
// Client: dart run tool/dual_device_recovery_probe.dart --client-ready <host>
//           <copied-private-ready-file>
// Never publish the ready file: it contains the one-use pairing code.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:share_hub_connection/share_hub_connection.dart';

final _clockStart = Stopwatch()..start();
Future<int> _clock() async => _clockStart.elapsedMicroseconds;

Future<DeviceIdentity> _identity() async {
  final random = Random.secure();
  return DeviceIdentity.fromSeed([
    for (var i = 0; i < 32; i++) random.nextInt(256),
  ]);
}

Future<void> _host(String readyPath) async {
  final recovery = ConnectionRecoveryService();
  await recovery.open(address: InternetAddress.anyIPv4);
  final accepted = Completer<TrustedConnection>();
  final host = PairingHost(
    identity: await _identity(),
    clock: _clock,
    protocolVersion: 2,
    recovery: recovery,
    onConnection: (connection) {
      connection.startMonitoring();
      if (!accepted.isCompleted) accepted.complete(connection);
    },
  );
  await host.open(address: InternetAddress.loopbackIPv4);
  final proxy = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final control = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final sockets = <Socket>[];
  proxy.listen((incoming) async {
    sockets.add(incoming);
    try {
      final outgoing = await Socket.connect('127.0.0.1', host.port!);
      sockets.add(outgoing);
      incoming.listen(
        outgoing.add,
        onDone: outgoing.destroy,
        onError: (Object _) => outgoing.destroy(),
      );
      outgoing.listen(
        incoming.add,
        onDone: incoming.destroy,
        onError: (Object _) => incoming.destroy(),
      );
    } catch (_) {
      incoming.destroy();
    }
  });
  final ready = File(readyPath);
  try {
    ready.writeAsStringSync(
      jsonEncode({
        'port': proxy.port,
        'code': host.offer!.code,
        'key': host.identity.encodedKey,
        'controlPort': control.port,
      }),
    );
    stdout.writeln('HOST_READY recovery_port=${recovery.port}');
    final connection = await accepted.future.timeout(
      const Duration(seconds: 30),
    );
    final originalGrant = connection.grant;
    final originalLease = connection.lease;
    final originalExpiry = originalGrant!.expiresMicros;
    final originalSession = connection.sessionId;
    final suspended = connection.phaseChanges.firstWhere(
      (phase) => phase == ConnectionPhase.suspended,
    );
    final active = connection.phaseChanges.firstWhere(
      (phase) => phase == ConnectionPhase.active,
    );
    final command = await control.first.timeout(const Duration(seconds: 20));
    final request = await command.first.timeout(const Duration(seconds: 5));
    command.destroy();
    if (utf8.decode(request).trim() != 'drop') {
      throw StateError('invalid probe command');
    }
    for (final socket in sockets) {
      socket.destroy();
    }
    await suspended.timeout(const Duration(seconds: 5));
    await active.timeout(const Duration(seconds: 15));
    final current = await connection.check();
    final retained =
        identical(connection.grant, originalGrant) &&
        identical(connection.lease, originalLease) &&
        connection.grant!.expiresMicros == originalExpiry &&
        connection.grant!.generation == 2 &&
        connection.sessionId != originalSession &&
        current;
    stdout.writeln(
      'HOST_RECOVERED=$retained generation=${connection.grant!.generation}',
    );
    if (!retained) throw StateError('original authority was not retained');
    try {
      await connection.whenClosed.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      stderr.writeln(
        'HOST_CLOSE_TIMEOUT phase=${connection.phase.name} grant=${connection.grant?.phase.name}',
      );
      rethrow;
    }
    stdout.writeln(
      'HOST_REVOKED=${connection.isClosed && recovery.registeredCount == 0}',
    );
  } finally {
    if (ready.existsSync()) ready.deleteSync();
    for (final socket in sockets) {
      socket.destroy();
    }
    await control.close();
    await proxy.close();
    await host.close();
    await recovery.close();
  }
}

Future<void> _client(List<String> args) async {
  if (args.length != 5) throw FormatException('client requires five arguments');
  final host = args[0];
  final port = int.parse(args[1]);
  final code = args[2];
  final peerKey = args[3];
  final controlPort = int.parse(args[4]);
  final recovery = ConnectionRecoveryService();
  await recovery.open(address: InternetAddress.anyIPv4);
  TrustedConnection? connection;
  try {
    connection = await PairingAttempt(
      identity: await _identity(),
      clock: _clock,
      protocolVersion: 2,
      recovery: recovery,
    ).connect(host, port, code, expectedPeerKey: peerKey);
    connection.startMonitoring();
    final originalGrant = connection.grant!;
    final originalLease = connection.lease;
    final originalExpiry = originalGrant.expiresMicros;
    final originalSession = connection.sessionId;
    final suspended = connection.phaseChanges.firstWhere(
      (phase) => phase == ConnectionPhase.suspended,
    );
    final control = await Socket.connect(host, controlPort);
    control.write('drop\n');
    await control.flush();
    control.destroy();
    await suspended.timeout(const Duration(seconds: 5));
    await recovery.reconnect(connection).timeout(const Duration(seconds: 15));
    final retained =
        identical(connection.grant, originalGrant) &&
        identical(connection.lease, originalLease) &&
        connection.grant!.expiresMicros == originalExpiry &&
        connection.grant!.generation == 2 &&
        connection.sessionId != originalSession &&
        await connection.check();
    stdout.writeln(
      'CLIENT_RECOVERED=$retained generation=${connection.grant!.generation}',
    );
    if (!retained) throw StateError('original authority was not retained');
    connection.close('probe_disconnect');
    await connection.whenClosed;
    // close() revokes locally first, then sends a best-effort peer notice.
    // Keep this short-lived CLI process alive through that bounded send.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    var denied = false;
    try {
      await recovery.reconnect(connection);
    } on ConnectionFailure {
      denied = true;
    }
    stdout.writeln('CLIENT_DISCONNECT_REJECTED=$denied');
    if (!denied) throw StateError('explicit disconnect restored authority');
  } finally {
    connection?.close('probe_cleanup');
    await recovery.close();
  }
}

Future<void> main(List<String> args) async {
  try {
    if (args.length == 2 && args[0] == '--host') {
      await _host(args[1]);
    } else if (args.length == 3 && args[0] == '--client-ready') {
      final file = File(args[2]);
      final ready = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      file.deleteSync();
      await _client([
        args[1],
        '${ready['port']}',
        ready['code'] as String,
        ready['key'] as String,
        '${ready['controlPort']}',
      ]);
    } else {
      throw FormatException(
        'usage: --host ready-file | --client-ready host ready-file',
      );
    }
  } catch (error) {
    stderr.writeln('RECOVERY_PROBE_FAILED=${error.runtimeType}');
    exitCode = 1;
  }
}
