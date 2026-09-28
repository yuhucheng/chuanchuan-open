import 'dart:async';
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

import '../test/connection_controller_test.dart' show FakeConnectionPlatform;
import '../test/connection_relay.dart';
import '../test/file_fakes.dart';
import '../test/network_file_fakes.dart';
import '../test/transfer_queue_test.dart' show drainQueue;

class _LiveClockPlatform extends FakeConnectionPlatform {
  @override
  Future<int> now() => MethodChannelConnectionPlatform().now();
}

class _CutAfterFirstAckSource extends MemorySourceAccess {
  _CutAfterFirstAckSource(super.bytes);

  int? gatePass;
  Completer<void>? gateEntered;
  Completer<void>? gateRelease;

  @override
  Future<Uint8List> readPass(
    SourceReadPass pass,
    int offset,
    int length,
  ) async {
    if (passes == gatePass && offset >= 256 * 1024) {
      gatePass = null;
      gateEntered!.complete();
      await gateRelease!.future;
    }
    return super.readPass(pass, offset, length);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'authenticated TCP transfer commits and resumes through native store',
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
      final source = _CutAfterFirstAckSource(selectedFiles.data);
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

        final resumedBytes = Uint8List.fromList(
          List<int>.generate(3 * 256 * 1024 + 13, (index) => index % 251),
        );
        final resumedName =
            'chuan-network-resumed-${DateTime.now().microsecondsSinceEpoch}.bin';
        selectedFiles.selection = [
          SelectedFile(
            token: 'resumed-source',
            name: resumedName,
            size: resumedBytes.length,
          ),
        ];
        selectedFiles.data['resumed-source'] = resumedBytes;
        await senderQueue.selectFiles();
        await drainQueue(senderQueue);
        source.gatePass = source.passes + 2;
        source.gateEntered = Completer<void>();
        source.gateRelease = Completer<void>();
        final resumedJob = sent.send(
          senderQueue.items.last,
          sender.sessions.single,
        );
        await source.gateEntered!.future.timeout(const Duration(seconds: 10));
        expect(resumedJob.acknowledgedBytes, 256 * 1024);
        final suspended = [sender.sessions.single, receiver.sessions.single]
            .map(
              (session) => session.phaseChanges.firstWhere(
                (phase) => phase == ConnectionPhase.suspended,
              ),
            )
            .toList();
        relay.cut();
        await Future.wait(suspended).timeout(const Duration(seconds: 5));
        source.gateRelease!.complete();
        await resumedJob.done.timeout(const Duration(seconds: 20));
        expect(resumedJob.phase, NetworkSendPhase.completed);
        expect(resumedJob.receipt?.size, resumedBytes.length);
        expect(
          resumedJob.receipt?.sha256,
          sha256.convert(resumedBytes).toString(),
        );
        expect(resumedJob.receipt?.actualName, resumedName);
        final resumedHistoryReady = Completer<void>();
        void checkResumedHistory() {
          if (received.receiveHistory.length == 2 &&
              !resumedHistoryReady.isCompleted) {
            resumedHistoryReady.complete();
          }
        }

        received.addListener(checkResumedHistory);
        try {
          checkResumedHistory();
          await resumedHistoryReady.future.timeout(const Duration(seconds: 5));
        } finally {
          received.removeListener(checkResumedHistory);
        }
        expect(
          received.receiveHistory.last.file.sha256,
          sha256.convert(resumedBytes).toString(),
        );
        expect(received.receiveHistory.last.file.actualName, resumedName);
        stdout.writeln(
          'NATIVE_NETWORK_RESUME_REPORT name=$resumedName '
          'size=${resumedBytes.length} sha256=${sha256.convert(resumedBytes)}',
        );
      } finally {
        if (source.gateRelease case final release?) {
          if (!release.isCompleted) release.complete();
        }
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

  testWidgets(
    'changed source after TCP loss never publishes native receive file',
    (tester) async {
      expect(Platform.isWindows || Platform.isMacOS, isTrue);
      final senderPlatform = _LiveClockPlatform();
      final receiverPlatform = _LiveClockPlatform();
      final receiverIdentity = await DeviceIdentity.fromSeed(
        List<int>.filled(32, 104),
      );
      senderPlatform.seed.complete(
        await DeviceIdentity.fromSeed(List<int>.filled(32, 103)),
      );
      receiverPlatform.seed.complete(receiverIdentity);
      final sender = ConnectionController(senderPlatform);
      final receiver = ConnectionController(receiverPlatform);
      final selectedFiles = TestFileAccess();
      final senderQueue = TransferQueue(selectedFiles);
      final receiverQueue = TransferQueue(TestFileAccess());
      final source = _CutAfterFirstAckSource(selectedFiles.data);
      final sent = NetworkTransfers(
        connections: sender,
        queue: senderQueue,
        source: source,
        receive: MemoryReceiveAccess(),
      );
      final received = NetworkTransfers(
        connections: receiver,
        queue: receiverQueue,
        source: MemorySourceAccess({}),
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
          List<int>.generate(3 * 256 * 1024 + 13, (index) => index % 251),
        );
        final name =
            'chuan-network-changed-${DateTime.now().microsecondsSinceEpoch}.bin';
        selectedFiles.selection = [
          SelectedFile(token: 'changed-source', name: name, size: bytes.length),
        ];
        selectedFiles.data['changed-source'] = bytes;
        await senderQueue.selectFiles();
        await drainQueue(senderQueue);
        source.gatePass = source.passes + 2;
        source.gateEntered = Completer<void>();
        source.gateRelease = Completer<void>();
        final job = sent.send(senderQueue.items.single, sender.sessions.single);
        await source.gateEntered!.future.timeout(const Duration(seconds: 10));
        expect(job.acknowledgedBytes, 256 * 1024);
        final suspended = [sender.sessions.single, receiver.sessions.single]
            .map(
              (session) => session.phaseChanges.firstWhere(
                (phase) => phase == ConnectionPhase.suspended,
              ),
            )
            .toList();
        relay.cut();
        await Future.wait(suspended).timeout(const Duration(seconds: 5));
        selectedFiles.data['changed-source'] = Uint8List(bytes.length);
        source.gateRelease!.complete();
        await job.done.timeout(const Duration(seconds: 20));
        expect(job.phase, NetworkSendPhase.failed);
        expect(job.error, contains('文件内容已变化'));
        expect(job.receipt, isNull);
        stdout.writeln('NATIVE_NETWORK_SOURCE_CHANGE_REPORT name=$name');
      } finally {
        if (source.gateRelease case final release?) {
          if (!release.isCompleted) release.complete();
        }
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

  testWidgets(
    'off during authenticated TCP transfer stops native publication',
    (tester) async {
      expect(Platform.isWindows || Platform.isMacOS, isTrue);
      const destinationPath = String.fromEnvironment('NATIVE_RECEIVE_DIR');
      expect(destinationPath, isNotEmpty);
      final destination = Directory(destinationPath);
      expect(destination.existsSync(), isTrue);
      final existingParts = _temporaryPaths(destination);
      final senderPlatform = _LiveClockPlatform();
      final receiverPlatform = _LiveClockPlatform();
      final receiverIdentity = await DeviceIdentity.fromSeed(
        List<int>.filled(32, 106),
      );
      senderPlatform.seed.complete(
        await DeviceIdentity.fromSeed(List<int>.filled(32, 105)),
      );
      receiverPlatform.seed.complete(receiverIdentity);
      final sender = ConnectionController(senderPlatform);
      final receiver = ConnectionController(receiverPlatform);
      final selectedFiles = TestFileAccess();
      final senderQueue = TransferQueue(selectedFiles);
      final receiverQueue = TransferQueue(TestFileAccess());
      final source = _CutAfterFirstAckSource(selectedFiles.data);
      final sent = NetworkTransfers(
        connections: sender,
        queue: senderQueue,
        source: source,
        receive: MemoryReceiveAccess(),
      );
      final received = NetworkTransfers(
        connections: receiver,
        queue: receiverQueue,
        source: MemorySourceAccess({}),
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
          List<int>.generate(3 * 256 * 1024 + 13, (index) => index % 251),
        );
        final name =
            'chuan-network-off-${DateTime.now().microsecondsSinceEpoch}.bin';
        selectedFiles.selection = [
          SelectedFile(token: 'off-source', name: name, size: bytes.length),
        ];
        selectedFiles.data['off-source'] = bytes;
        await senderQueue.selectFiles();
        await drainQueue(senderQueue);
        source.gatePass = source.passes + 2;
        source.gateEntered = Completer<void>();
        source.gateRelease = Completer<void>();
        final job = sent.send(senderQueue.items.single, sender.sessions.single);
        await source.gateEntered!.future.timeout(const Duration(seconds: 10));
        expect(job.acknowledgedBytes, 256 * 1024);
        final disconnect = sender.disconnectAll();
        source.gateRelease!.complete();
        await disconnect.timeout(const Duration(seconds: 10));
        await job.done.timeout(const Duration(seconds: 20));
        expect(job.phase, NetworkSendPhase.cancelled);
        expect(job.canResume, isFalse);
        expect(job.receipt, isNull);
        await received.close();
        expect(
          received.receiveHistory.where(
            (item) => item.file.outcome == FileRetirementOutcome.completed,
          ),
          isEmpty,
        );
        expect(
          File('${destination.path}${Platform.pathSeparator}$name')
              .existsSync(),
          isFalse,
        );
        expect(_temporaryPaths(destination).difference(existingParts), isEmpty);
        stdout.writeln('NATIVE_NETWORK_OFF_REPORT name=$name');
      } finally {
        if (source.gateRelease case final release?) {
          if (!release.isCompleted) release.complete();
        }
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

Set<String> _temporaryPaths(Directory directory) => {
  for (final entry in directory.listSync(followLinks: false))
    if (entry is File &&
        entry.uri.pathSegments.last.startsWith('.chuanchuan-receive-') &&
        entry.uri.pathSegments.last.endsWith('.part'))
      entry.path,
};
