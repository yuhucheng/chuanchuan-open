// Opt-in Windows/macOS wire probe. Run each side with flutter test on its real
// machine; this is deliberately outside test/ so routine unit runs do not wait
// for another computer. File access is memory-backed: this tests the shipped
// pairing, authenticated transport and file coordinator, not OS picker/storage.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';
import 'package:share_hub_open/features/transfers/network_transfers.dart';
import 'package:share_hub_open/features/transfers/transfer_queue.dart';

import '../test/file_fakes.dart';
import '../test/network_file_fakes.dart';

final class _ProbeConnectionPlatform implements ConnectionPlatform {
  _ProbeConnectionPlatform(this._identity);
  final DeviceIdentity _identity;
  int? advertisedPort;

  @override
  Future<DeviceIdentity> identity() async => _identity;

  @override
  Future<int> now() async => 1000;

  @override
  Future<String?> advertise(int? port, String? key) async {
    advertisedPort = port;
    return 'probe.local';
  }
}

void main() {
  final role = Platform.environment['FILE_WIRE_ROLE'];
  test(
    'authenticated file messages and receipts cross two real computers',
    () async {
      if (role != 'host' && role != 'client') {
        throw StateError('FILE_WIRE_ROLE must be host or client');
      }
      final handshakePath = Platform.environment['FILE_WIRE_HANDSHAKE'];
      final reportPath = Platform.environment['FILE_WIRE_REPORT'];
      if (handshakePath == null || reportPath == null) {
        throw StateError(
          'FILE_WIRE_HANDSHAKE and FILE_WIRE_REPORT are required',
        );
      }

      final identity = await DeviceIdentity.fromSeed(
        List<int>.filled(32, role == 'host' ? 82 : 81),
      );
      final platform = _ProbeConnectionPlatform(identity);
      final connections = ConnectionController(platform);
      final files = TestFileAccess();
      final queue = TransferQueue(files);
      final source = MemorySourceAccess(files.data);
      final receive = MemoryReceiveAccess();
      final transfers = NetworkTransfers(
        connections: connections,
        queue: queue,
        source: source,
        receive: receive,
      );
      try {
        if (role == 'host') {
          await connections.open();
          expect(connections.code, isNotNull);
          final port = platform.advertisedPort!;
          await File(handshakePath).writeAsString(
            jsonEncode({
              'port': port,
              'code': connections.code,
              'peerKey': identity.encodedKey,
            }),
          );
        } else {
          final handshake = jsonDecode(
            await File(handshakePath).readAsString(),
          ) as Map<String, dynamic>;
          final connected = await connections.connect(
            Platform.environment['FILE_WIRE_HOST']!,
            handshake['port'] as int,
            handshake['code'] as String,
            expectedPeerKey: handshake['peerKey'] as String,
          );
          expect(connected, isNotNull, reason: connections.message);
        }
        await _until(() => transfers.targets.length == 1);

        final own = role == 'host'
            ? <String, Uint8List>{
                'host-empty.bin': Uint8List(0),
                'host-large.bin': Uint8List.fromList(
                  List<int>.generate(2 * 256 * 1024 + 13, (i) => i % 251),
                ),
              }
            : <String, Uint8List>{
                'client-small.bin': Uint8List.fromList([1, 2, 3, 4, 5]),
                'client-中文.txt': Uint8List.fromList(utf8.encode('双机文件传输')),
              };
        files.data.addAll(own);
        files.selection = [
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
        final connection = transfers.targets.single;
        final sends = [
          for (final item in queue.items) transfers.send(item, connection),
        ];
        await Future.wait(sends.map((job) => job.done))
            .timeout(const Duration(seconds: 45));
        for (final job in sends) {
          expect(job.phase, NetworkSendPhase.completed, reason: job.error);
          expect(job.receipt, isNotNull);
          expect(
            job.receipt!.sha256,
            sha256.convert(own[job.item.file.token]!).toString(),
          );
          expect(job.receipt!.size, own[job.item.file.token]!.length);
        }
        await _until(() => receive.receipts.length == 2);
        final receivedHashes = receive.files.values
            .map((bytes) => sha256.convert(bytes).toString())
            .toSet();
        final expectedOther = role == 'host'
            ? <String>{
                sha256.convert([1, 2, 3, 4, 5]).toString(),
                sha256.convert(utf8.encode('双机文件传输')).toString(),
              }
            : <String>{
                sha256.convert(Uint8List(0)).toString(),
                sha256
                    .convert(
                      List<int>.generate(2 * 256 * 1024 + 13, (i) => i % 251),
                    )
                    .toString(),
              };
        expect(receivedHashes, expectedOther);
        final report = {
          'role': role,
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
            for (final receipt in receive.receipts)
              {
                'name': receipt.name,
                'size': receipt.size,
                'sha256': receipt.sha256,
              },
          ],
        };
        await File(reportPath)
            .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      } finally {
        await transfers.close();
        await queue.close();
        await connections.disconnectAll();
        transfers.dispose();
        queue.dispose();
        connections.dispose();
        if (role == 'host') {
          final handshake = File(handshakePath);
          if (await handshake.exists()) {
            await handshake.delete();
          }
        }
      }
    },
    skip: role == null ? 'Set FILE_WIRE_ROLE for cross-device run' : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
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
