// Explicit Windows/macOS two-computer acceptance probe. Run host and client
// with WIRE_ROLE, WIRE_HOST, WIRE_HANDSHAKE and WIRE_REPORT --dart-define values.
// WIRE_SCENARIO=changed verifies same-length source mutation after the cut;
// the default scenario verifies successful resume.
// The sender is memory-backed; the receiver uses the production native store.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';
import 'package:share_hub_open/features/transfers/network_transfers.dart';
import 'package:share_hub_open/features/transfers/receive_access.dart';
import 'package:share_hub_open/features/transfers/source_access.dart';
import 'package:share_hub_open/features/transfers/transfer_queue.dart';

import '../test/connection_relay.dart';
import '../test/file_fakes.dart';
import '../test/network_file_fakes.dart';

const _role = String.fromEnvironment('WIRE_ROLE');
const _host = String.fromEnvironment('WIRE_HOST');
const _handshakePath = String.fromEnvironment('WIRE_HANDSHAKE');
const _reportPath = String.fromEnvironment('WIRE_REPORT');
const _scenario = String.fromEnvironment(
  'WIRE_SCENARIO',
  defaultValue: 'resume',
);

final class _ProbePlatform implements ConnectionPlatform {
  _ProbePlatform(this._identity);
  final DeviceIdentity _identity;
  int? advertisedPort;

  @override
  Future<DeviceIdentity> identity() async => _identity;

  @override
  Future<int> now() => MethodChannelConnectionPlatform().now();

  @override
  Future<String?> advertise(int? port, String? key) async {
    advertisedPort = port;
    return 'probe.local';
  }
}

final class _GatedSource extends MemorySourceAccess {
  _GatedSource(super.bytes);
  int? gatePass;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Uint8List> readPass(
    SourceReadPass pass,
    int offset,
    int length,
  ) async {
    if (passes == gatePass && offset >= 256 * 1024) {
      gatePass = null;
      entered.complete();
      await release.future;
    }
    return super.readPass(pass, offset, length);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native receive handles a real cross-device TCP cut', (
    tester,
  ) async {
    expect(Platform.isWindows || Platform.isMacOS, isTrue);
    expect(_role, anyOf('host', 'client'));
    expect(_scenario, anyOf('resume', 'changed'));
    expect(_handshakePath, isNotEmpty);
    expect(_reportPath, isNotEmpty);
    if (_role == 'client') expect(_host, isNotEmpty);

    final identity = await DeviceIdentity.fromSeed(
      List<int>.filled(32, _role == 'host' ? 92 : 93),
    );
    final platform = _ProbePlatform(identity);
    final connections = ConnectionController(platform);
    final selected = TestFileAccess();
    final queue = TransferQueue(selected);
    final source = _GatedSource(selected.data);
    final transfers = NetworkTransfers(
      connections: connections,
      queue: queue,
      source: source,
      receive: _role == 'client'
          ? MethodChannelReceiveAccess()
          : MemoryReceiveAccess(),
    );
    ConnectionRelay? relay;
    try {
      if (_role == 'host') {
        await connections.open();
        relay = await ConnectionRelay.open(
          platform.advertisedPort!,
          bindAddress: InternetAddress.anyIPv4,
        );
        await File(_handshakePath).writeAsString(
          jsonEncode({
            'port': relay.port,
            'code': connections.code,
            'peerKey': identity.encodedKey,
          }),
        );
      } else {
        final handshake = jsonDecode(
          await File(_handshakePath).readAsString(),
        ) as Map<String, dynamic>;
        final connected = await connections.connect(
          _host,
          handshake['port'] as int,
          handshake['code'] as String,
          expectedPeerKey: handshake['peerKey'] as String,
        );
        expect(connected, isNotNull, reason: connections.message);
      }
      await _until(() => transfers.targets.length == 1);
      final session = connections.sessions.single;
      final suspended = session.phaseChanges.firstWhere(
        (phase) => phase == ConnectionPhase.suspended,
      );

      if (_role == 'host') {
        final bytes = Uint8List.fromList(
          List<int>.generate(3 * 256 * 1024 + 13, (i) => i % 251),
        );
        final name =
            'chuan-cross-$_scenario-${DateTime.now().microsecondsSinceEpoch}.bin';
        selected.data['source'] = bytes;
        selected.selection = [
          SelectedFile(token: 'source', name: name, size: bytes.length),
        ];
        await queue.selectFiles();
        await _until(
          () =>
              queue.items.length == 1 &&
              queue.items.single.state == PreparationState.ready,
        );
        source.gatePass = source.passes + 2;
        final job = transfers.send(
          queue.items.single,
          transfers.targets.single,
        );
        await source.entered.future.timeout(const Duration(seconds: 20));
        expect(job.acknowledgedBytes, 256 * 1024);
        relay!.cut();
        await suspended.timeout(const Duration(seconds: 10));
        if (_scenario == 'changed') {
          selected.data['source'] = Uint8List(bytes.length);
        }
        source.release.complete();
        await job.done.timeout(const Duration(seconds: 45));
        if (_scenario == 'changed') {
          expect(job.phase, NetworkSendPhase.failed, reason: job.error);
          expect(job.receipt, isNull);
          expect(job.error, contains('文件内容已变化'));
        } else {
          expect(job.phase, NetworkSendPhase.completed, reason: job.error);
          expect(job.receipt?.size, bytes.length);
          expect(job.receipt?.sha256, sha256.convert(bytes).toString());
          expect(job.receipt?.actualName, name);
        }
        // The content receipt precedes the receiver's terminal-history ACK.
        // Keep the original grant alive until both sides finish retirement.
        await _until(() => job.retirementComplete);
        await File(_reportPath).writeAsString(
          jsonEncode({
            'role': _role,
            'platform': Platform.operatingSystem,
            'acknowledgedBeforeCut': 256 * 1024,
            'name': name,
            'actualName': job.receipt?.actualName,
            'size': job.receipt?.size ?? bytes.length,
            'sha256': job.receipt?.sha256 ?? sha256.convert(bytes).toString(),
            'outcome': _scenario == 'changed' ? 'failed' : 'completed',
          }),
        );
      } else {
        await suspended.timeout(const Duration(seconds: 45));
        await _until(() => transfers.receiveHistory.length == 1);
        final file = transfers.receiveHistory.single.file;
        expect(
          file.outcome,
          _scenario == 'changed'
              ? FileRetirementOutcome.cancelled
              : FileRetirementOutcome.completed,
        );
        if (_scenario == 'changed') expect(file.actualName, isNull);
        expect(file.size, 3 * 256 * 1024 + 13);
        expect(
          file.sha256,
          sha256
              .convert(List<int>.generate(file.size, (i) => i % 251))
              .toString(),
        );
        await File(_reportPath).writeAsString(
          jsonEncode({
            'role': _role,
            'platform': Platform.operatingSystem,
            'sawSuspended': true,
            'name': file.name,
            'actualName': file.actualName,
            'size': file.size,
            'sha256': file.sha256,
            'outcome': _scenario == 'changed' ? 'cancelled' : 'completed',
            'failureCode': file.failureCode,
          }),
        );
      }
    } finally {
      if (!source.release.isCompleted) source.release.complete();
      await transfers.close();
      await queue.close();
      await connections.disconnectAll();
      transfers.dispose();
      queue.dispose();
      connections.dispose();
      await relay?.close();
      if (_role == 'host') {
        final handshake = File(_handshakePath);
        if (await handshake.exists()) await handshake.delete();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}

Future<void> _until(bool Function() ready) async {
  final limit = DateTime.now().add(const Duration(minutes: 2));
  while (!ready()) {
    if (DateTime.now().isAfter(limit)) {
      throw TimeoutException('cross-device file transfer did not progress');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
