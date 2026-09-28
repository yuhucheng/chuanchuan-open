// Run this explicit Flutter test on two machines. It is outside test/ so the
// normal suite does not need a peer. Keep PROBE_READY private: it contains a
// one-use short code and is deleted when consumed or when the host exits.
//
// Host:   PROBE_ROLE=host PROBE_READY=<private-file> flutter test --no-pub
//           tool/dual_device_controller_probe_test.dart
// Client: PROBE_ROLE=client PROBE_READY=<copied-private-file>
//           PROBE_HOST=<host-ip> flutter test --no-pub
//           tool/dual_device_controller_probe_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';

final class _ProbePlatform implements ConnectionPlatform {
  _ProbePlatform(this.device);
  final DeviceIdentity device;
  final Stopwatch clock = Stopwatch()..start();
  int? port;

  @override
  Future<DeviceIdentity> identity() async => device;
  @override
  Future<int> now() async => clock.elapsedMicroseconds;
  @override
  Future<String?> advertise(int? port, String? key) async {
    this.port = port;
    return 'probe.local';
  }
}

final class _Bridge {
  _Bridge._(this.server);
  final ServerSocket server;
  final sockets = <Socket>[];
  int get port => server.port;

  static Future<_Bridge> open(int targetPort) async {
    final bridge = _Bridge._(
      await ServerSocket.bind(InternetAddress.anyIPv4, 0),
    );
    bridge.server.listen((incoming) async {
      bridge.sockets.add(incoming);
      try {
        final outgoing = await Socket.connect('127.0.0.1', targetPort);
        bridge.sockets.add(outgoing);
        incoming.listen(outgoing.add, onDone: outgoing.destroy);
        outgoing.listen(incoming.add, onDone: incoming.destroy);
      } catch (_) {
        incoming.destroy();
      }
    });
    return bridge;
  }

  void drop() {
    for (final socket in sockets) {
      socket.destroy();
    }
  }

  Future<void> close() async {
    drop();
    await server.close();
  }
}

Future<TrustedConnection> _session(ConnectionController controller) async {
  for (var i = 0; i < 1200; i++) {
    if (controller.sessions.isNotEmpty) return controller.sessions.single;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException('controller session');
}

Future<_ProbePlatform> _platform() async {
  final random = Random.secure();
  return _ProbePlatform(
    await DeviceIdentity.fromSeed([
      for (var i = 0; i < 32; i++) random.nextInt(256),
    ]),
  );
}

void _sameGrant(
  TrustedConnection connection,
  GrantEndpoint grant,
  SessionLease lease,
  int expiry,
  String oldSession,
) {
  expect(connection.grant, same(grant));
  expect(connection.lease, same(lease));
  expect(grant.expiresMicros, expiry);
  expect(grant.generation, 2);
  expect(connection.sessionId, isNot(oldSession));
  expect(connection.isConnected, isTrue);
}

Future<void> _host(File ready) async {
  final platform = await _platform();
  final controller = ConnectionController(platform);
  _Bridge? bridge;
  ServerSocket? control;
  try {
    await controller.open();
    expect(controller.accepting, isTrue);
    bridge = await _Bridge.open(platform.port!);
    control = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    ready.writeAsStringSync(
      jsonEncode({
        'port': bridge.port,
        'code': controller.code,
        'key': platform.device.encodedKey,
        'controlPort': control.port,
      }),
    );
    stdout.writeln('CONTROLLER_HOST_READY');
    final connection = await _session(controller);
    final grant = connection.grant!;
    final lease = connection.lease;
    final expiry = grant.expiresMicros;
    final oldSession = connection.sessionId;
    final suspended = connection.phaseChanges.firstWhere(
      (phase) => phase == ConnectionPhase.suspended,
    );
    final active = connection.phaseChanges.firstWhere(
      (phase) => phase == ConnectionPhase.active,
    );
    final command = await control.first.timeout(const Duration(seconds: 30));
    final bytes = await command.first.timeout(const Duration(seconds: 5));
    command.destroy();
    expect(utf8.decode(bytes).trim(), 'drop');
    bridge.drop();
    await suspended.timeout(const Duration(seconds: 5));
    await active.timeout(const Duration(seconds: 20));
    _sameGrant(connection, grant, lease, expiry, oldSession);
    expect(await connection.check(), isTrue);
    stdout.writeln('CONTROLLER_HOST_RECOVERED');
    await connection.whenClosed.timeout(const Duration(seconds: 15));
    expect(grant.phase, GrantPhase.revoked);
    expect(controller.sessions, isEmpty);
    stdout.writeln('CONTROLLER_HOST_REVOKED');
  } finally {
    if (ready.existsSync()) ready.deleteSync();
    await bridge?.close();
    await control?.close();
    await controller.disconnectAll();
    controller.dispose();
  }
}

Future<void> _client(File ready, String host) async {
  final data = jsonDecode(ready.readAsStringSync()) as Map<String, dynamic>;
  ready.deleteSync();
  final platform = await _platform();
  final controller = ConnectionController(platform);
  try {
    final connection = await controller.connect(
      host,
      data['port'] as int,
      data['code'] as String,
      expectedPeerKey: data['key'] as String,
    );
    expect(connection, isNotNull);
    final grant = connection!.grant!;
    final lease = connection.lease;
    final expiry = grant.expiresMicros;
    final oldSession = connection.sessionId;
    final suspended = connection.phaseChanges.firstWhere(
      (phase) => phase == ConnectionPhase.suspended,
    );
    final active = connection.phaseChanges.firstWhere(
      (phase) => phase == ConnectionPhase.active,
    );
    final command = await Socket.connect(host, data['controlPort'] as int);
    command.write('drop\n');
    await command.flush();
    command.destroy();
    await suspended.timeout(const Duration(seconds: 5));
    await active.timeout(const Duration(seconds: 20));
    _sameGrant(connection, grant, lease, expiry, oldSession);
    expect(await connection.check(), isTrue);
    stdout.writeln('CONTROLLER_CLIENT_RECOVERED');
    await controller.disconnectAll();
    expect(grant.phase, GrantPhase.revoked);
    expect(controller.sessions, isEmpty);
    stdout.writeln('CONTROLLER_CLIENT_DISCONNECTED');
  } finally {
    await controller.disconnectAll();
    controller.dispose();
  }
}

void main() {
  final role = Platform.environment['PROBE_ROLE'];
  test(
    'two-device production connection controller recovery',
    () async {
      final path = Platform.environment['PROBE_READY'];
      if (path == null || path.isEmpty) {
        throw StateError('PROBE_READY required');
      }
      final ready = File(path);
      if (role == 'host') {
        await _host(ready);
      } else {
        final host = Platform.environment['PROBE_HOST'];
        if (host == null || host.isEmpty) {
          throw StateError('PROBE_HOST required');
        }
        await _client(ready, host);
      }
    },
    skip: role != 'host' && role != 'client',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
