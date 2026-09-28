import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';
import 'package:share_hub_open/features/transfers/network_transfers.dart';
import 'package:share_hub_open/features/transfers/receive_access.dart';
import 'package:share_hub_open/features/transfers/transfer_queue.dart';

import '../test/connection_controller_test.dart' show FakeConnectionPlatform;
import '../test/connection_relay.dart';
import '../test/file_fakes.dart';
import '../test/network_file_fakes.dart';
import '../test/transfer_queue_test.dart' show drainQueue;

class _LiveClockPlatform extends FakeConnectionPlatform {
  @override
  Future<int> now() => MethodChannelConnectionPlatform().now();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'authenticated TCP transfer commits through native receive store',
    (tester) async {
      expect(Platform.isWindows || Platform.isMacOS, isTrue);
      final senderPlatform = _LiveClockPlatform();
      final receiverPlatform = _LiveClockPlatform();
      final receiverIdentity = await DeviceIdentity.fromSeed(
        List<int>.filled(32, 102),
      );
      senderPlatform.seed.complete(
        await DeviceIdentity.fromSeed(List<int>.filled(32, 101)),
      );
      receiverPlatform.seed.complete(receiverIdentity);
      final sender = ConnectionController(senderPlatform);
      final receiver = ConnectionController(receiverPlatform);
      final selectedFiles = TestFileAccess();
      final senderQueue = TransferQueue(selectedFiles);
      final receiverQueue = TransferQueue(TestFileAccess());
      final source = MemorySourceAccess(selectedFiles.data);
      final sourceOnReceiver = MemorySourceAccess({});
      final sent = NetworkTransfers(
        connections: sender,
        queue: senderQueue,
        source: source,
        receive: MemoryReceiveAccess(),
      );
      final received = NetworkTransfers(
        connections: receiver,
        queue: receiverQueue,
        source: sourceOnReceiver,
        receive: MethodChannelReceiveAccess(),
      );
      ConnectionRelay? relay;
      try {
        await receiver.open();
        relay = await ConnectionRelay.open(
          receiverPlatform.advertisements.whereType<int>().last,
        );
        await sender.connect(
          '127.0.0.1',
          relay.port,
          receiver.code!,
          expectedPeerKey: receiverIdentity.encodedKey,
        );
        final bytes = Uint8List.fromList(
          List<int>.generate(2 * 256 * 1024 + 13, (index) => index % 251),
        );
        final name =
            'chuan-network-native-${DateTime.now().microsecondsSinceEpoch}.bin';
        selectedFiles.selection = [
          SelectedFile(token: 'source', name: name, size: bytes.length),
        ];
        selectedFiles.data['source'] = bytes;
        await senderQueue.selectFiles();
        await drainQueue(senderQueue);
        final job = sent.send(senderQueue.items.single, sender.sessions.single);
        await job.done.timeout(const Duration(seconds: 20));
        expect(job.phase, NetworkSendPhase.completed);
        expect(job.receipt?.size, bytes.length);
        expect(job.receipt?.sha256, sha256.convert(bytes).toString());
        expect(job.receipt?.actualName, name);
        final historyReady = Completer<void>();
        void checkHistory() {
          if (received.receiveHistory.length == 1 &&
              !historyReady.isCompleted) {
            historyReady.complete();
          }
        }

        received.addListener(checkHistory);
        try {
          checkHistory();
          await historyReady.future.timeout(const Duration(seconds: 5));
        } finally {
          received.removeListener(checkHistory);
        }
        expect(received.receiveHistory, hasLength(1));
        expect(
          received.receiveHistory.single.file.sha256,
          sha256.convert(bytes).toString(),
        );
        expect(received.receiveHistory.single.file.actualName, name);
        stdout.writeln(
          'NATIVE_NETWORK_RECEIVE_REPORT name=$name '
          'size=${bytes.length} sha256=${sha256.convert(bytes)}',
        );
      } finally {
        await Future.wait([sent.close(), received.close()]);
        await Future.wait([
          senderQueue.close(),
          receiverQueue.close(),
          sender.disconnectAll(),
          receiver.disconnectAll(),
        ]);
        sent.dispose();
        received.dispose();
        senderQueue.dispose();
        receiverQueue.dispose();
        sender.dispose();
        receiver.dispose();
        await relay?.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
