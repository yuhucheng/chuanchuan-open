// Opt-in desktop acceptance entry. It uses the shipped native file picker,
// receive-directory picker, connection and transfer owners. Do not ship a build
// launched with this entry point. Rebuild the normal app after running it.
//
// FILE_NATIVE_ROLE=host|client
// FILE_NATIVE_HANDSHAKE=<temporary JSON file shared with the other computer>
// FILE_NATIVE_REPORT=<temporary local JSON report>
// FILE_NATIVE_STATUS=<temporary local JSON status>
// FILE_NATIVE_HOST=<host IP, client only>

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';

import '../features/connections/connection_controller.dart';
import '../features/transfers/file_access.dart';
import '../features/transfers/network_transfers.dart';
import '../features/transfers/receive_access.dart';
import '../features/transfers/source_access.dart';
import '../features/transfers/transfer_queue.dart';

final class _ObservedPlatform implements ConnectionPlatform {
  final MethodChannelConnectionPlatform native =
      MethodChannelConnectionPlatform();
  int? port;

  @override
  Future<DeviceIdentity> identity() => native.identity();
  @override
  Future<int> now() => native.now();
  @override
  Future<String?> advertise(int? port, String? key) async {
    final name = await native.advertise(port, key);
    this.port = port;
    return name;
  }
}

final class _Reporter {
  _Reporter(this.statusPath, this.reportPath);
  final String statusPath, reportPath;
  final stage = ValueNotifier<String>('启动中');

  void update(String value) {
    stage.value = value;
    File(statusPath).writeAsStringSync(
      jsonEncode({
        'stage': value,
        'at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  void finish(Map<String, Object?> report) {
    File(reportPath)
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final reporter = _Reporter(
    env['FILE_NATIVE_STATUS'] ?? '',
    env['FILE_NATIVE_REPORT'] ?? '',
  );
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<String>(
            valueListenable: reporter.stage,
            builder: (context, value, child) => Text(value),
          ),
        ),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_run(env, reporter));
  });
}

Future<void> _run(Map<String, String> env, _Reporter report) async {
  final role = env['FILE_NATIVE_ROLE'];
  final handshakePath = env['FILE_NATIVE_HANDSHAKE'];
  final host = env['FILE_NATIVE_HOST'];
  if ((role != 'host' && role != 'client') ||
      handshakePath == null ||
      report.statusPath.isEmpty ||
      report.reportPath.isEmpty ||
      (role == 'client' && (host == null || host.isEmpty))) {
    report.finish({'outcome': 'invalid_environment'});
    exit(2);
  }

  final platform = _ObservedPlatform();
  final connections = ConnectionController(platform);
  final queue = TransferQueue(MethodChannelFileAccess());
  final transfers = NetworkTransfers(
    connections: connections,
    queue: queue,
    source: MethodChannelSourceAccess(),
    receive: MethodChannelReceiveAccess(),
  );
  var outcome = 0;
  try {
    report.update('选择接收目录');
    await transfers.directories.pick();
    if (transfers.directories.current == null) {
      throw StateError('receive directory was not selected');
    }

    report.update('选择两个测试文件');
    await queue.selectFiles();
    if (queue.items.isEmpty) {
      throw StateError('no native file selection was returned: ${queue.error}');
    }
    await _until(
      () =>
          queue.items.isNotEmpty &&
          queue.items.every(
            (item) =>
                item.state != PreparationState.queued &&
                item.state != PreparationState.preparing,
          ),
    );
    if (queue.items.length != 2 ||
        queue.items.any((item) => item.state != PreparationState.ready)) {
      throw StateError(
        'expected two prepared native file selections: ${queue.error}',
      );
    }

    if (role == 'host') {
      report.update('生成接入短码');
      await connections.open();
      final code = connections.code;
      final port = platform.port;
      if (code == null || port == null) {
        throw StateError('pairing host did not open: ${connections.message}');
      }
      final identity = await platform.identity();
      File(handshakePath).writeAsStringSync(
        jsonEncode({
          'port': port,
          'code': code,
          'peerKey': identity.encodedKey,
        }),
      );
      report.update('等待对端连接');
    } else {
      report.update('等待接入信息');
      await _until(() => File(handshakePath).existsSync());
      final handshake = jsonDecode(
        File(handshakePath).readAsStringSync(),
      ) as Map<String, dynamic>;
      report.update('验证对端身份');
      final connection = await connections.connect(
        host!,
        handshake['port'] as int,
        handshake['code'] as String,
        expectedPeerKey: handshake['peerKey'] as String,
      );
      if (connection == null) {
        throw StateError('pairing failed: ${connections.message}');
      }
    }

    await _until(() => transfers.targets.length == 1);
    final peer = transfers.targets.single;
    report.update('双向发送和自动接收');
    final sends = [for (final item in queue.items) transfers.send(item, peer)];
    await Future.wait(sends.map((job) => job.done))
        .timeout(const Duration(minutes: 3));
    await _until(() => transfers.receiveHistory.length == 2);
    if (sends.any(
      (job) => job.phase != NetworkSendPhase.completed || job.receipt == null,
    )) {
      throw StateError(
        'send did not complete: ${sends.map((job) => job.error).toList()}',
      );
    }
    final received = transfers.receiveHistory;
    if (received.any(
      (item) => item.file.outcome != FileRetirementOutcome.completed,
    )) {
      throw StateError('receive did not complete');
    }
    report.finish({
      'outcome': 'passed',
      'platform': Platform.operatingSystem,
      'role': role,
      'peerKey': peer.peerKey,
      'directory': transfers.directories.current!.label,
      'sent': [
        for (final job in sends)
          {
            'name': job.item.file.name,
            'size': job.receipt!.size,
            'sha256': job.receipt!.sha256,
            'actualName': job.receipt!.actualName,
          },
      ],
      'received': [
        for (final item in received)
          {
            'name': item.file.name,
            'size': item.file.size,
            'sha256': item.file.sha256,
            'actualName': item.file.actualName,
          },
      ],
    });
    report.update('验收通过');
  } catch (error) {
    outcome = 1;
    stderr.writeln('Native acceptance failed at ${report.stage.value}: $error');
    try {
      report.finish({
        'outcome': 'failed',
        'stage': report.stage.value,
        'error': error.toString(),
      });
      report.update('验收失败');
    } catch (reportError) {
      stderr.writeln('Native acceptance report unavailable: $reportError');
    }
  } finally {
    try {
      await transfers.close();
      await queue.close();
      await connections.disconnectAll();
    } catch (error) {
      outcome = 1;
      report.finish({'outcome': 'cleanup_failed', 'error': error.toString()});
    }
    transfers.dispose();
    queue.dispose();
    connections.dispose();
    exit(outcome);
  }
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('stage timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
