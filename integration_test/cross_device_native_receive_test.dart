// Opt-in desktop receiver for tool/cross_device_file_wire_test.dart on the
// other computer. Handshake and report paths must be writable by this app.
// Pass WIRE_HOST, WIRE_HANDSHAKE and WIRE_REPORT with --dart-define.
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
import 'package:share_hub_open/features/transfers/transfer_queue.dart';

import '../test/file_fakes.dart';
import '../test/network_file_fakes.dart';

const _host = String.fromEnvironment('WIRE_HOST');
const _handshakePath = String.fromEnvironment('WIRE_HANDSHAKE');
const _reportPath = String.fromEnvironment('WIRE_REPORT');

final class _ProbePlatform implements ConnectionPlatform {
  _ProbePlatform(this._identity);
  final DeviceIdentity _identity;

  @override
  Future<DeviceIdentity> identity() async => _identity;

  @override
  // Native scopes reject a deadline derived from the VM probe's fixed clock.
  Future<int> now() => MethodChannelConnectionPlatform().now();

  @override
  Future<String?> advertise(int? port, String? key) async => 'probe.local';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('peer sends through authenticated TCP to native store', (
    tester,
  ) async {
    expect(Platform.isMacOS || Platform.isWindows, isTrue);
    expect(_host, isNotEmpty);
    expect(_handshakePath, isNotEmpty);
    expect(_reportPath, isNotEmpty);
    final handshake = jsonDecode(
      await File(_handshakePath).readAsString(),
    ) as Map<String, dynamic>;
    final identity = await DeviceIdentity.fromSeed(List<int>.filled(32, 81));
    final connections = ConnectionController(_ProbePlatform(identity));
    final selected = TestFileAccess();
    final queue = TransferQueue(selected);
    final source = MemorySourceAccess(selected.data);
    final transfers = NetworkTransfers(
      connections: connections,
      queue: queue,
      source: source,
      receive: MethodChannelReceiveAccess(),
    );
    try {
      final connected = await connections.connect(
        _host,
        handshake['port'] as int,
        handshake['code'] as String,
        expectedPeerKey: handshake['peerKey'] as String,
      );
      expect(connected, isNotNull, reason: connections.message);
      await _until(() => transfers.targets.length == 1);

      final own = <String, Uint8List>{
        'client-small.bin': Uint8List.fromList([1, 2, 3, 4, 5]),
        'client-中文.txt': Uint8List.fromList(utf8.encode('双机文件传输')),
      };
      selected.data.addAll(own);
      selected.selection = [
        for (final entry in own.entries)
          SelectedFile(
            token: entry.key,
            name: entry.key,
            size: entry.value.length,
          ),
      ];
      await queue.selectFiles();
      await _until(
        () =>
            queue.items.length == own.length &&
            queue.items.every((item) => item.state == PreparationState.ready),
      );
      final peer = transfers.targets.single;
      final sends = [
        for (final item in queue.items) transfers.send(item, peer),
      ];
      await Future.wait(sends.map((job) => job.done))
          .timeout(const Duration(seconds: 45));
      for (final job in sends) {
        expect(job.phase, NetworkSendPhase.completed, reason: job.error);
        expect(job.receipt?.size, own[job.item.file.token]!.length);
        expect(
          job.receipt?.sha256,
          sha256.convert(own[job.item.file.token]!).toString(),
        );
      }

      await _until(() => transfers.receiveHistory.length == 2);
      final received = transfers.receiveHistory
          .map((item) => item.file)
          .toList();
      expect(
        received.every(
          (file) => file.outcome == FileRetirementOutcome.completed,
        ),
        isTrue,
      );
      final expected = <String, (int, String)>{
        'host-empty.bin': (0, sha256.convert([]).toString()),
        'host-large.bin': (
          2 * 256 * 1024 + 13,
          sha256
              .convert(List<int>.generate(2 * 256 * 1024 + 13, (i) => i % 251))
              .toString(),
        ),
      };
      for (final file in received) {
        final pair = expected[file.name];
        expect(pair, isNotNull, reason: 'unexpected received ${file.name}');
        expect(file.size, pair!.$1);
        expect(file.sha256, pair.$2);
      }
      await File(_reportPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'platform': Platform.operatingSystem,
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
            for (final file in received)
              {
                'name': file.name,
                'size': file.size,
                'sha256': file.sha256,
                'actualName': file.actualName,
              },
          ],
        }),
      );
    } finally {
      await transfers.close();
      await queue.close();
      await connections.disconnectAll();
      transfers.dispose();
      queue.dispose();
      connections.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}

Future<void> _until(bool Function() ready) async {
  final limit = DateTime.now().add(const Duration(minutes: 2));
  while (!ready()) {
    if (DateTime.now().isAfter(limit)) {
      throw TimeoutException('peer did not progress');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
