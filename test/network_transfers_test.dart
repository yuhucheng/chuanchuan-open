import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart'
    show SessionOperation;
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';
import 'package:share_hub_open/features/transfers/file_transfer_channel.dart';
import 'package:share_hub_open/features/transfers/network_transfers.dart';
import 'package:share_hub_open/features/transfers/network_transfers_panel.dart';
import 'package:share_hub_open/features/transfers/network_progress_view.dart';
import 'package:share_hub_open/features/transfers/incoming_file_transfer.dart';
import 'package:share_hub_open/features/transfers/transfer_queue.dart';

import 'connection_controller_test.dart' show FakeConnectionPlatform;
import 'connection_relay.dart';
import 'file_fakes.dart';
import 'network_file_fakes.dart';
import 'transfer_queue_test.dart' show drainQueue;

void main() {
  test('retired receive failure keeps actionable storage guidance', () {
    ReceivedFileHistory history(String? code) => ReceivedFileHistory(
      transferId: 'file',
      transferOrdinal: 1,
      name: 'report.txt',
      size: 2,
      sha256: '00' * 32,
      outcome: FileRetirementOutcome.failed,
      failureCode: code,
    );
    for (final code in ['permission_denied', 'disk_full']) {
      expect(
        NetworkTransfers.historyStatus(history(code), sending: false),
        contains('更改保存位置'),
      );
    }
    expect(
      NetworkTransfers.historyStatus(
        history('private-native-error'),
        sending: false,
      ),
      isNot(contains('private-native-error')),
    );
  });

  late ConnectionController a, b;
  late TransferQueue queueA, queueB;
  late TestFileAccess filesA, filesB;
  late MemorySourceAccess sourceA, sourceB;
  late MemoryReceiveAccess diskA, diskB;
  late NetworkTransfers left, right;
  late ConnectionRelay relay;
  test('cancelling a preparing drop prevents automatic send and releases its token', () async {
    const file = SelectedFile(token: 'drop', name: 'dropped.bin', size: 3);
    filesA.data['drop'] = Uint8List.fromList([7, 8, 9]);
    final gate = filesA.pendingRead = Completer<Uint8List>();
    expect(left.acceptDrop([file], left.targets.single), true);
    await queueA.cancel(queueA.items.single);
    gate.complete(filesA.data['drop']);
    await drainQueue(queueA);
    expect(left.sends, isEmpty);
    expect(right.received, isEmpty);
    expect(filesA.releases, ['drop']);
  });
  test(
    'device drop prepares then sends only to its original connection',
    () async {
      const file = SelectedFile(token: 'drop', name: 'dropped.bin', size: 3);
      filesA.data['drop'] = Uint8List.fromList([7, 8, 9]);
      filesA.pendingRead = Completer<Uint8List>();
      expect(left.acceptDrop([file], left.targets.single), true);
      expect(left.sends, isEmpty);
      expect(filesA.picks, 0);
      filesA.pendingRead!.complete(filesA.data['drop']);
      await drainQueue(queueA);
      expect(left.sends, hasLength(1));
      await left.sends.single.done;
      expect(left.sends.single.receipt?.size, 3);
      expect(right.received.single.entry.task?.receipt?.size, 3);
    },
  );
  test(
    'connection closed during drop preparation never starts a network send',
    () async {
      const file = SelectedFile(token: 'drop', name: 'dropped.bin', size: 3);
      filesA.data['drop'] = Uint8List.fromList([7, 8, 9]);
      final gate = filesA.pendingRead = Completer<Uint8List>();
      final original = left.targets.single;
      expect(left.acceptDrop([file], original), true);
      original.close('test');
      gate.complete(filesA.data['drop']);
      await drainQueue(queueA);
      expect(left.sends, isEmpty);
      expect(left.error, contains('连接'));
      expect(left.acceptDrop([file], original), false);
      expect(queueA.items.single.state, PreparationState.ready);
    },
  );
  testWidgets('file panel loads the saved destination before any receive', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NetworkTransfersPanel(controller: right)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('接收位置：Downloads/串串'), findsOneWidget);
  });
  testWidgets(
    'unavailable saved destination shows recovery action instead of default',
    (tester) async {
      diskB.failDirectory = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NetworkTransfersPanel(controller: right)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('接收位置：不可用，请重新选择'), findsOneWidget);
      expect(right.directories.current, isNull);
      await tester.tap(find.text('更改保存位置'));
      await tester.pumpAndSettle();
      expect(find.text('接收位置：Chosen'), findsOneWidget);
      expect(right.directories.error, isNull);
    },
  );
  setUp(() async {
    final pa = FakeConnectionPlatform(), pb = FakeConnectionPlatform();
    pa.seed.complete(await DeviceIdentity.fromSeed(List.filled(32, 81)));
    final peer = await DeviceIdentity.fromSeed(List.filled(32, 82));
    pb.seed.complete(peer);
    a = ConnectionController(pa);
    b = ConnectionController(pb);
    filesA = TestFileAccess();
    filesB = TestFileAccess();
    queueA = TransferQueue(filesA);
    queueB = TransferQueue(filesB);
    sourceA = MemorySourceAccess(filesA.data);
    sourceB = MemorySourceAccess(filesB.data);
    diskA = MemoryReceiveAccess();
    diskB = MemoryReceiveAccess();
    left = NetworkTransfers(
      connections: a,
      queue: queueA,
      source: sourceA,
      receive: diskA,
    );
    right = NetworkTransfers(
      connections: b,
      queue: queueB,
      source: sourceB,
      receive: diskB,
    );
    await b.open();
    relay = await ConnectionRelay.open(pb.advertisements.whereType<int>().last);
    await a.connect(
      '127.0.0.1',
      relay.port,
      b.code!,
      expectedPeerKey: peer.encodedKey,
    );
  });
  tearDown(() async {
    diskA.failCancel = diskB.failCancel = false;
    diskA.failClose = diskB.failClose = false;
    sourceA.failClose = sourceB.failClose = false;
    for (final gate in [
      sourceA.readGate,
      sourceB.readGate,
      diskA.appendGate,
      diskB.appendGate,
      diskA.commitGate,
      diskB.commitGate,
      diskA.resumeGate,
      diskB.resumeGate,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    await Future.wait([left.close(), right.close()]);
    await Future.wait([
      queueA.close(),
      queueB.close(),
      a.disconnectAll(),
      b.disconnectAll(),
    ]);
    left.dispose();
    right.dispose();
    queueA.dispose();
    queueB.dispose();
    a.dispose();
    b.dispose();
    await relay.close();
  });

  Future<TransferItem> prepare(
    TestFileAccess files,
    TransferQueue queue,
    String token,
    int size,
  ) async {
    files.selection = [
      SelectedFile(token: token, name: '$token.bin', size: size),
    ];
    files.data[token] = Uint8List.fromList(List.generate(size, (i) => i % 251));
    await queue.selectFiles();
    await drainQueue(queue);
    return queue.items.last;
  }

  Future<void> waitFor(
    NetworkTransfers controller,
    bool Function() ready,
  ) async {
    final changed = Completer<void>();
    void check() {
      if (ready() && !changed.isCompleted) changed.complete();
    }

    controller.addListener(check);
    try {
      check();
      await changed.future.timeout(const Duration(seconds: 5));
    } finally {
      controller.removeListener(check);
    }
  }

  Future<void> loseConnection() async {
    final paused = [a.sessions.single, b.sessions.single]
        .map(
          (c) =>
              c.phaseChanges.firstWhere((p) => p == ConnectionPhase.suspended),
        )
        .toList();
    relay.cut();
    await Future.wait(paused).timeout(const Duration(seconds: 2));
  }

  test(
    'both file producers use independent canonical ordinal sequences',
    () async {
      for (var ordinal = 1; ordinal <= 2; ordinal++) {
        final itemA = await prepare(filesA, queueA, 'a-$ordinal', 3);
        final itemB = await prepare(filesB, queueB, 'b-$ordinal', 3);
        final sentA = left.send(itemA, a.sessions.single);
        final sentB = right.send(itemB, b.sessions.single);
        await Future.wait([sentA.done, sentB.done]);
        final contextA = right.received.last.entry.task!.context;
        final contextB = left.received.last.entry.task!.context;
        expect(
          contextA.authorization.sessionId,
          FileOperationId(
            sender: a.sessions.single.grant!.role,
            ordinal: ordinal,
            attempt: 1,
          ).encoded,
        );
        expect(
          contextB.authorization.sessionId,
          FileOperationId(
            sender: b.sessions.single.grant!.role,
            ordinal: ordinal,
            attempt: 1,
          ).encoded,
        );
        expect(
          contextA.authorization.sessionId,
          isNot(contextB.authorization.sessionId),
        );
        expect(contextA.transferOrdinal, ordinal);
        expect(contextB.transferOrdinal, ordinal);
        expect(sentA.receipt, isNotNull);
        expect(sentB.receipt, isNotNull);
      }
    },
  );

  test(
    'physical loss automatically restores the original transfer and grant',
    () async {
      final item = await prepare(filesA, queueA, 'reconnect', 70000);
      final connection = a.sessions.single, endpoint = connection.grant!;
      final id = connection.sessionId;
      diskB.appendGate = Completer<void>();
      final job = left.send(item, connection);
      await diskB.appendEntered.future;
      await loseConnection();
      expect(a.sessions.single, same(connection));
      expect(job.receipt, isNull);
      expect(job.phase, NetworkSendPhase.paused);
      diskB.appendGate!.complete();
      await job.done.timeout(const Duration(seconds: 10));
      expect(job.phase, NetworkSendPhase.completed);
      expect(connection.grant, same(endpoint));
      expect(endpoint.generation, 2);
      expect(connection.sessionId, isNot(id));
      expect(diskB.begins, 1);
      expect(diskB.files.values.single, filesA.data['reconnect']);
      expect(diskB.receipts, hasLength(1));
    },
  );

  test(
    'loss before an offer reaches the receiver can restart from zero',
    () async {
      final item = await prepare(filesA, queueA, 'early-loss', 70000);
      sourceA.readGate = Completer<void>();
      final job = left.send(item, a.sessions.single);
      await sourceA.readEntered.future;
      await loseConnection();
      expect(diskB.begins, 0);
      sourceA.readGate!.complete();
      await job.done.timeout(const Duration(seconds: 10));
      expect(job.phase, NetworkSendPhase.completed);
      expect(diskB.begins, 1);
      expect(diskB.receipts, hasLength(1));
    },
  );

  test('aggregate send progress waits for acknowledgements and all commit receipts', () async {
    final first = await prepare(filesA, queueA, 'aggregate-one', 70000);
    final empty = await prepare(filesA, queueA, 'aggregate-empty', 0);
    final connection = a.sessions.single;
    expect(
      left.sendProgress(peerKey: connection.peerKey).totalFiles,
      0,
      reason: 'Prepared local files are not network transfers.',
    );
    diskB.appendGate = Completer<void>();
    diskB.commitGate = Completer<void>();
    final one = left.send(first, connection),
        two = left.send(empty, connection);
    await diskB.appendEntered.future;
    final held = left.sendProgress(peerKey: connection.peerKey);
    expect(held.totalBytes, BigInt.from(70000));
    expect(held.transferredBytes, BigInt.zero);
    expect(held.totalFiles, 2);
    expect(held.completedFiles, 0);
    expect(held.isComplete, isFalse);
    diskB.appendGate!.complete();
    await diskB.commitEntered.future;
    final verifying = left.sendProgress(peerKey: connection.peerKey);
    expect(verifying.transferredBytes, BigInt.from(70000));
    expect(verifying.completedFiles, 0);
    expect(
      verifying.progressValue,
      isNull,
      reason: 'Full byte ACK is not saved.',
    );
    diskB.commitGate!.complete();
    await Future.wait([one.done, two.done]);
    final completed = left.sendProgress(peerKey: connection.peerKey);
    expect(completed.completedFiles, 2);
    expect(completed.isComplete, isTrue);
    expect(completed.progressValue, 1);
    expect(left.sendProgress(peerKey: 'unrelated').totalFiles, 0);
    expect(
      right.receiveProgress(peerKey: b.sessions.single.peerKey).completedFiles,
      2,
    );
  });

  test('aggregate empty and cancelled sends cannot report complete', () async {
    final item = await prepare(filesA, queueA, 'aggregate-cancel', 0);
    diskB.commitGate = Completer<void>();
    final job = left.send(item, a.sessions.single);
    await diskB.commitEntered.future;
    final before = left.sendProgress();
    expect(before.totalBytes, BigInt.zero);
    expect(before.isComplete, isFalse);
    expect(before.progressValue, isNull);
    await left.cancel(job);
    diskB.commitGate!.complete();
    await job.done;
    final after = left.sendProgress();
    expect(after.isComplete, isFalse);
    expect(after.cancelledFiles, 1);
    expect(after.completedFiles, 0);
  });

  testWidgets(
    'peer aggregate view follows confirmation and receipt without counting preparation',
    (tester) async {
      final item = (await tester.runAsync(
        () => prepare(filesA, queueA, 'aggregate-view', 4096),
      ))!;
      final connection = a.sessions.single;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 220,
              child: NetworkProgressView(
                controller: left,
                peerKey: connection.peerKey,
                compact: true,
              ),
            ),
          ),
        ),
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      diskB.commitGate = Completer<void>();
      late NetworkSend job;
      await tester.runAsync(() async {
        job = left.send(item, connection);
        await diskB.commitEntered.future.timeout(const Duration(seconds: 5));
      });
      await tester.pump();
      expect(find.text('发送 · 已完成 0/1 · 未完成 1'), findsOneWidget);
      expect(find.textContaining('对端已确认 4.0 KiB / 4.0 KiB'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
      );
      diskB.commitGate!.complete();
      await tester.runAsync(() => job.done.timeout(const Duration(seconds: 5)));
      await tester.pump();
      expect(find.text('发送 · 已完成 1/1'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        1,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'production controllers send queued files and auto receive over real TCP',
    () async {
      final one = await prepare(filesA, queueA, 'one', 70000);
      final two = await prepare(filesA, queueA, 'two', 0);
      final first = left.send(one, a.sessions.single);
      final second = left.send(two, a.sessions.single);
      await Future.wait([first.done, second.done])
          .timeout(const Duration(seconds: 10));
      expect(first.phase, NetworkSendPhase.completed);
      expect(second.phase, NetworkSendPhase.completed);
      expect(first.receipt!.actualName, 'one.bin (1)');
      expect(first.acknowledgedBytes, 70000);
      expect(diskB.files.values.first, filesA.data['one']);
      expect(diskB.receipts, hasLength(2));
      await waitFor(right, () => right.receiveHistory.length == 2);
      expect(right.received, isEmpty);
      expect(right.receiveHistory.map((item) => item.file.transferOrdinal), [
        1,
        2,
      ]);
      expect(
        sourceA.maxScopes,
        1,
        reason: 'Queue schedules one active sender.',
      );
      expect(filesA.releases, isEmpty);
    },
  );

  test(
    'manual pause survives transport recovery until explicitly resumed',
    () async {
      final item = await prepare(filesA, queueA, 'manual-loss', 70000);
      diskB.appendGate = Completer<void>();
      final job = left.send(item, a.sessions.single);
      await diskB.appendEntered.future;
      await left.pause(job);
      diskB.appendGate!.complete();
      await waitFor(left, () => job.canResume);
      final active = a.sessions.single.phaseChanges.firstWhere(
        (p) => p == ConnectionPhase.active,
      );
      await loseConnection();
      await active.timeout(const Duration(seconds: 5));
      await waitFor(left, () => job.canResume);
      expect(job.phase, NetworkSendPhase.paused);
      expect(diskB.receipts, isEmpty);
      left.resume(job);
      await job.done.timeout(const Duration(seconds: 5));
      expect(job.phase, NetworkSendPhase.completed);
    },
  );

  test('reverse-direction file resumes after physical loss', () async {
    final item = await prepare(filesB, queueB, 'reverse-loss', 70000);
    diskA.appendGate = Completer<void>();
    final job = right.send(item, b.sessions.single);
    await diskA.appendEntered.future;
    await loseConnection();
    diskA.appendGate!.complete();
    await job.done.timeout(const Duration(seconds: 5));
    expect(job.phase, NetworkSendPhase.completed);
    expect(diskA.begins, 1);
    expect(diskA.files.values.single, filesB.data['reverse-loss']);
  });

  test('a commit completed during loss replays its receipt without publishing twice', () async {
    final item = await prepare(filesA, queueA, 'commit-loss', 3);
    diskB.commitGate = Completer<void>();
    final job = left.send(item, a.sessions.single);
    await diskB.commitEntered.future;
    await loseConnection();
    diskB.commitGate!.complete();
    await job.done.timeout(const Duration(seconds: 5));
    expect(job.phase, NetworkSendPhase.completed);
    expect(job.receipt!.actualName, 'commit-loss.bin (1)');
    expect(diskB.receipts, hasLength(1));
    expect(diskB.begins, 1);
  });

  test(
    'source changes during physical loss prevent all subsequent sending',
    () async {
      final item = await prepare(filesA, queueA, 'changed-loss', 70000);
      diskB.appendGate = Completer<void>();
      final job = left.send(item, a.sessions.single);
      await diskB.appendEntered.future;
      await loseConnection();
      filesA.data['changed-loss'] = Uint8List(70000);
      diskB.appendGate!.complete();
      await job.done.timeout(const Duration(seconds: 5));
      expect(job.phase, NetworkSendPhase.failed);
      expect(job.error, contains('文件内容已变化'));
      expect(sourceA.activeScopes, 0);
      expect(diskB.files.values.single.length, lessThan(70000));
      expect(diskB.receipts, isEmpty);
      await waitFor(right, () => !right.received.single.entry.canCancel);
      expect(diskB.releasedFiles, 1);
    },
  );

  for (final reverse in [false, true]) {
    test(
      'changed receive prefix after physical loss stops both owners (reverse=$reverse)',
      () async {
        final sending = reverse ? right : left;
        final receiving = reverse ? left : right;
        final files = reverse ? filesB : filesA;
        final queue = reverse ? queueB : queueA;
        final source = reverse ? sourceB : sourceA;
        final disk = reverse ? diskA : diskB;
        final item = await prepare(files, queue, 'damaged-prefix', 70000);
        disk.appendGate = Completer<void>();
        disk.resumeGate = Completer<void>();
        final job = sending.send(item, sending.targets.single);
        await disk.appendEntered.future;
        await loseConnection();
        disk.appendGate!.complete();
        await disk.resumeEntered.future.timeout(const Duration(seconds: 5));
        final partial = disk.files.values.single;
        expect(partial, isNotEmpty);
        final offset = partial.length;
        partial[0] ^= 1;
        disk.resumeGate!.complete();
        await job.done.timeout(const Duration(seconds: 5));
        await waitFor(receiving, () => disk.releasedFiles == 1);
        expect(job.phase, NetworkSendPhase.failed);
        expect(job.canResume, isFalse);
        expect(job.receipt, isNull);
        expect(job.error, contains('校验失败'));
        expect(source.activeScopes, 0);
        expect(disk.begins, 1);
        expect(partial.length, offset);
        expect(disk.receipts, isEmpty);
        expect(receiving.received.single.entry.canCancel, isFalse);

        final next = await prepare(files, queue, 'after-damage', 3);
        final healthy = sending.send(next, sending.targets.single);
        await healthy.done.timeout(const Duration(seconds: 5));
        expect(healthy.phase, NetworkSendPhase.completed);
        expect(disk.begins, 2);
        await waitFor(receiving, () => receiving.receiveHistory.length == 2);
        expect(
          receiving.receiveHistory.map((item) => item.file.transferOrdinal),
          [1, 2],
        );
        expect(disk.receipts, hasLength(1));
        expect(partial.length, offset);
      },
    );
  }

  test(
    'off settles queued files which have not acquired a transfer owner',
    () async {
      final firstItem = await prepare(filesA, queueA, 'blocking', 3);
      final queuedItem = await prepare(filesA, queueA, 'queued-off', 3);
      sourceA.readGate = Completer<void>();
      final first = left.send(firstItem, a.sessions.single);
      await sourceA.readEntered.future;
      final queued = left.send(queuedItem, a.sessions.single);
      await a.disconnectAll();
      sourceA.readGate!.complete();
      await Future.wait([first.done, queued.done])
          .timeout(const Duration(seconds: 2));
      expect(queued.phase, NetworkSendPhase.cancelled);
      expect(sourceA.opens, 1);
      expect(diskB.begins, 0);
    },
  );

  test('off during a physical interruption prevents file recovery', () async {
    final item = await prepare(filesA, queueA, 'off-loss', 70000);
    diskB.appendGate = Completer<void>();
    final job = left.send(item, a.sessions.single);
    await diskB.appendEntered.future;
    final connection = a.sessions.single;
    await loseConnection();
    await a.disconnectAll();
    diskB.appendGate!.complete();
    await job.done.timeout(const Duration(seconds: 5));
    expect(connection.isClosed, isTrue);
    expect(job.phase, NetworkSendPhase.cancelled);
    expect(job.canResume, isFalse);
    expect(diskB.receipts, isEmpty);
  });

  test(
    'failed native cancellation can be retried without reopening the file',
    () async {
      final item = await prepare(filesA, queueA, 'retry-termination', 70000);
      diskB.appendGate = Completer<void>();
      final job = left.send(item, a.sessions.single);
      await diskB.appendEntered.future;
      diskB.failCancel = true;
      await left.cancel(job);
      await waitFor(left, () => job.cancellationFailure != null);
      expect(job.phase, NetworkSendPhase.cancelled);
      expect(job.cancellationPending, isTrue);
      diskB.failCancel = false;
      diskB.appendGate!.complete();
      left.retryCancelNotification(job);
      await waitFor(left, () => !job.cancellationPending);
      await waitFor(right, () => diskB.releasedFiles == 1);
      expect(job.cancellationFailure, isNull);
      expect(diskB.begins, 1);
      expect(diskB.receipts, isEmpty);
    },
  );

  for (final receivingSide in [false, true]) {
    test(
      'offline ${receivingSide ? 'receiver' : 'sender'} cancellation is delivered after reconnect',
      () async {
        final item = await prepare(filesA, queueA, 'offline-stop', 70000);
        diskB.appendGate = Completer<void>();
        final job = left.send(item, a.sessions.single);
        await diskB.appendEntered.future;
        final restored = a.sessions.single.phaseChanges.firstWhere(
          (p) => p == ConnectionPhase.active,
        );
        await loseConnection();
        if (receivingSide) {
          await right.cancelReceive(right.received.single);
        } else {
          await queueA.remove(item);
        }
        diskB.appendGate!.complete();
        await restored.timeout(const Duration(seconds: 5));
        await waitFor(right, () => !right.received.single.entry.canCancel);
        await job.done.timeout(const Duration(seconds: 5));
        expect(job.phase, NetworkSendPhase.cancelled);
        expect(diskB.receipts, isEmpty);
        expect(diskB.begins, 1);
        expect(a.sessions.single.isConnected, isTrue);
        await waitFor(left, () => !job.cancellationPending);
        await waitFor(
          right,
          () =>
              right.receiveHistory.isNotEmpty ||
              !right.received.single.entry.cancellationPending,
        );
      },
    );
  }

  test(
    'native pause failure terminates the connection instead of stranding files',
    () async {
      final item = await prepare(filesA, queueA, 'stop-failure', 70000);
      diskB.appendGate = Completer<void>();
      final connection = a.sessions.single;
      final job = left.send(item, connection);
      await diskB.appendEntered.future;
      sourceA.failPause = true;
      await loseConnection();
      diskB.appendGate!.complete();
      await connection.whenClosed.timeout(const Duration(seconds: 2));
      await job.done.timeout(const Duration(seconds: 2));
      expect(job.phase, NetworkSendPhase.cancelled);
      expect(left.error, isNotNull);
      expect(diskB.receipts, isEmpty);
    },
  );

  test('the connection receiver can also initiate file sending', () async {
    final item = await prepare(filesB, queueB, 'reverse', 3);
    final sent = right.send(item, b.sessions.single);
    await sent.done.timeout(const Duration(seconds: 10));
    expect(sent.phase, NetworkSendPhase.completed);
    expect(diskA.receipts, hasLength(1));
    expect(left.received, hasLength(1));
  });

  test('cleanup retry preserves delivery without a stale failure', () async {
    final item = await prepare(filesA, queueA, 'cleanup', 3);
    sourceA.failClose = true;
    final sent = left.send(item, a.sessions.single);
    await sent.done.timeout(const Duration(seconds: 10));
    expect(sent.phase, NetworkSendPhase.completed);
    expect(sent.receipt!.actualName, 'cleanup.bin (1)');
    expect(sent.cleanupFailure, isNotNull);
    expect(filesA.releases, isEmpty);
    sourceA.failClose = false;
    await left.cancel(sent);
    expect(sent.cleanupFailure, isNull);
    expect(sent.error, isNull);
    expect(sent.phase, NetworkSendPhase.completed);
    expect(sent.receipt!.actualName, 'cleanup.bin (1)');
    expect(sourceA.activeScopes, 0);
    await queueA.remove(item);
    expect(filesA.releases, ['cleanup']);
  });

  test('cleanup failure does not replace the source-change error', () async {
    final item = await prepare(filesA, queueA, 'changed', 3);
    filesA.data['changed'] = Uint8List.fromList([9, 8, 7]);
    sourceA.failClose = true;
    final sent = left.send(item, a.sessions.single);
    await sent.done.timeout(const Duration(seconds: 10));
    expect(sent.phase, NetworkSendPhase.failed);
    expect(sent.cleanupFailure, isNotNull);
    sourceA.failClose = false;
    await left.cancel(sent);
    expect(sent.cleanupFailure, isNull);
    expect(sent.error, contains('文件内容已变化'));
    expect(sent.receipt, isNull);
    expect(right.received, isEmpty);
  });

  test(
    'queue removal cancels the active sender before releasing its token',
    () async {
      final item = await prepare(filesA, queueA, 'held', 3);
      sourceA.readGate = Completer<void>();
      final sent = left.send(item, a.sessions.single);
      await sourceA.readEntered.future;
      final removing = queueA.remove(item);
      expect(filesA.releases, isEmpty);
      sourceA.readGate!.complete();
      await removing;
      await sent.done;
      expect(sent.phase, NetworkSendPhase.cancelled);
      expect(filesA.releases, ['held']);
      expect(sourceA.activeScopes, 0);
      expect(diskB.receipts, isEmpty);
    },
  );

  test('directory failure is visible and choosing a new location permits a later file', () async {
    diskB.failDirectory = true;
    final item = await prepare(filesA, queueA, 'denied', 3);
    final failed = left.send(item, a.sessions.single);
    await failed.done.timeout(const Duration(seconds: 10));
    expect(failed.phase, NetworkSendPhase.failed);
    expect(right.received.single.entry.failure, 'permission_denied');
    expect(diskB.begins, 0);
    await right.directories.pick();
    final next = await prepare(filesA, queueA, 'next', 3);
    final sent = left.send(next, a.sessions.single);
    await sent.done.timeout(const Duration(seconds: 10));
    expect(sent.phase, NetworkSendPhase.completed);
    expect(diskB.destinations, ['chosen-1']);
  });

  test('a disconnected target never consumes a ready selection', () async {
    final item = await prepare(filesA, queueA, 'ready', 3);
    final target = a.sessions.single;
    target.close();
    expect(() => left.send(item, target), throwsStateError);
    expect(item.canSend, isTrue);
    expect(sourceA.opens, 0);
  });

  test(
    'removing a finished selection releases its outbound history slot',
    () async {
      final item = await prepare(filesA, queueA, 'finished', 0);
      final sent = left.send(item, a.sessions.single);
      await sent.done.timeout(const Duration(seconds: 5));
      await queueA.remove(item);
      expect(left.sends, isEmpty);
      expect(sourceA.activeScopes, 0);
      expect(filesA.releases, ['finished']);
    },
  );

  test(
    'intentional pause retains the selected token and source owner',
    () async {
      final item = await prepare(filesA, queueA, 'pause', 70000);
      diskB.appendGate = Completer<void>();
      final sent = left.send(item, a.sessions.single);
      await diskB.appendEntered.future;
      await left.pause(sent);
      await Future<void>.delayed(Duration.zero);
      expect(sent.phase, NetworkSendPhase.paused);
      expect(sourceA.activeScopes, 1);
      expect(filesA.releases, isEmpty);
      diskB.appendGate!.complete();
      await right.received.single.channel.whenIdle;
      await left.cancel(sent);
      await sent.done;
      expect(sent.phase, NetworkSendPhase.cancelled);
      expect(sourceA.activeScopes, 0);
    },
  );

  test(
    'resume waits for the peer checkpoint and completes the original file',
    () async {
      final item = await prepare(filesA, queueA, 'resume', 70000);
      diskB.appendGate = Completer<void>();
      final sent = left.send(item, a.sessions.single);
      await diskB.appendEntered.future;
      final original = right.received.single.entry.task!.context;
      await left.pause(sent);
      expect(sent.canResume, isFalse);
      expect(() => left.resume(sent), throwsStateError);
      diskB.appendGate!.complete();
      await waitFor(left, () => sent.canResume);
      left.resume(sent);
      expect(sent.canResume, isFalse);
      expect(() => left.resume(sent), throwsStateError);
      await sent.done.timeout(const Duration(seconds: 10));
      expect(sent.phase, NetworkSendPhase.completed);
      expect(sent.receipt!.actualName, 'resume.bin (1)');
      expect(diskB.begins, 1);
      expect(diskB.files.values.single, filesA.data['resume']);
      expect(sourceA.opens, 2);
      expect(sourceA.activeScopes, 0);
      expect(filesA.releases, isEmpty);
      final resumed = right.received.single.entry.task!.context;
      expect(resumed.transferId, original.transferId);
      final beforeId = FileOperationId.parse(original.authorization.sessionId);
      final afterId = FileOperationId.parse(resumed.authorization.sessionId);
      expect(afterId.sender, beforeId.sender);
      expect(afterId.ordinal, beforeId.ordinal);
      expect(beforeId.attempt, 1);
      expect(afterId.attempt, 2);
      expect(
        resumed.authorization.sessionId,
        isNot(original.authorization.sessionId),
      );
      expect(
        resumed.authorization.hasSameGrantAs(original.authorization),
        isTrue,
      );
      expect(
        resumed.authorization.expiresMicros,
        original.authorization.expiresMicros,
      );
    },
  );

  test('changed source is rejected by a queued resume without another receive file', () async {
    final item = await prepare(filesA, queueA, 'mutated', 70000);
    diskB.appendGate = Completer<void>();
    final sent = left.send(item, a.sessions.single);
    await diskB.appendEntered.future;
    await left.pause(sent);
    diskB.appendGate!.complete();
    await waitFor(left, () => sent.canResume);
    filesA.data['mutated']![0] ^= 1;
    left.resume(sent);
    await sent.done.timeout(const Duration(seconds: 10));
    expect(sent.phase, NetworkSendPhase.failed);
    expect(sent.error, contains('文件内容已变化'));
    expect(sent.receipt, isNull);
    expect(diskB.begins, 1);
    expect(diskB.receipts, isEmpty);
    expect(sourceA.activeScopes, 0);
    await waitFor(
      right,
      () =>
          right.received.single.entry.task!.phase ==
          IncomingFilePhase.cancelled,
    );
  });

  test(
    'a queued resume can be cancelled without opening another source scope',
    () async {
      final first = await prepare(filesA, queueA, 'first', 70000);
      diskB.appendGate = Completer<void>();
      final paused = left.send(first, a.sessions.single);
      await diskB.appendEntered.future;
      await left.pause(paused);
      diskB.appendGate!.complete();
      await waitFor(left, () => paused.canResume);

      diskB.appendGate = Completer<void>();
      final second = await prepare(filesA, queueA, 'second', 70000);
      final sending = left.send(second, a.sessions.single);
      await waitFor(
        right,
        () =>
            right.received.length == 2 &&
            right.received.last.entry.task?.phase ==
                IncomingFilePhase.receiving,
      );
      left.resume(paused);
      expect(paused.phase, NetworkSendPhase.queued);
      expect(sourceA.opens, 2);
      await left.cancel(paused);
      await paused.done;
      expect(paused.phase, NetworkSendPhase.cancelled);
      expect(paused.canResume, isFalse);
      expect(() => left.resume(paused), throwsStateError);
      diskB.appendGate!.complete();
      await sending.done.timeout(const Duration(seconds: 10));
      expect(sending.phase, NetworkSendPhase.completed);
      expect(sourceA.opens, 2);
      expect(diskB.receipts, hasLength(1));
    },
  );

  test(
    'peer cancellation settles a paused sender and releases its source',
    () async {
      final item = await prepare(filesA, queueA, 'peer-stop', 70000);
      diskB.appendGate = Completer<void>();
      final sent = left.send(item, a.sessions.single);
      await diskB.appendEntered.future;
      await left.pause(sent);
      diskB.appendGate!.complete();
      await waitFor(left, () => sent.canResume);
      await right.cancelReceive(right.received.single);
      await sent.done.timeout(const Duration(seconds: 2));
      expect(sent.phase, NetworkSendPhase.cancelled);
      expect(sent.canResume, isFalse);
      expect(sourceA.activeScopes, 0);
      expect(filesA.releases, isEmpty);
    },
  );

  test('a real commit receipt settles a sender paused while completion was pending', () async {
    final item = await prepare(filesA, queueA, 'published', 3);
    diskB.commitGate = Completer<void>();
    final sent = left.send(item, a.sessions.single);
    await diskB.commitEntered.future;
    await left.pause(sent);
    await waitFor(left, () => sent.phase == NetworkSendPhase.paused);
    diskB.commitGate!.complete();
    await sent.done.timeout(const Duration(seconds: 5));
    expect(sent.phase, NetworkSendPhase.completed);
    expect(sent.receipt!.actualName, 'published.bin (1)');
    expect(sent.canResume, isFalse);
    expect(sourceA.activeScopes, 0);
    expect(diskB.receipts, hasLength(1));
  });

  test('closing the connection settles a paused sender without recovery eligibility', () async {
    final item = await prepare(filesA, queueA, 'disconnect', 70000);
    diskB.appendGate = Completer<void>();
    final sent = left.send(item, a.sessions.single);
    await diskB.appendEntered.future;
    await left.pause(sent);
    diskB.appendGate!.complete();
    await waitFor(left, () => sent.canResume);
    await a.disconnectAll();
    await sent.done.timeout(const Duration(seconds: 2));
    expect(sent.phase, NetworkSendPhase.cancelled);
    expect(sent.canResume, isFalse);
    expect(() => left.resume(sent), throwsStateError);
    expect(sourceA.activeScopes, 0);
  });

  test(
    'a missing file route fails a resume and cleans the retained source',
    () async {
      final item = await prepare(filesA, queueA, 'route', 70000);
      diskB.appendGate = Completer<void>();
      final sent = left.send(item, a.sessions.single);
      await diskB.appendEntered.future;
      await left.pause(sent);
      diskB.appendGate!.complete();
      await waitFor(left, () => sent.canResume);
      a.sessions.single.operationTransport({
        SessionOperation.file,
      }).detachReceiver();
      left.resume(sent);
      await sent.done.timeout(const Duration(seconds: 2));
      expect(sent.phase, NetworkSendPhase.failed);
      expect(sent.error, isNotNull);
      expect(sent.canResume, isFalse);
      expect(sourceA.opens, 1);
      expect(sourceA.activeScopes, 0);
    },
  );

  testWidgets('file panel pauses and resumes to the actual saved receipt', (
    tester,
  ) async {
    late NetworkSend sent;
    await tester.runAsync(() async {
      final item = await prepare(filesA, queueA, 'panel', 70000);
      diskB.appendGate = Completer<void>();
      sent = left.send(item, a.sessions.single);
      await diskB.appendEntered.future;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NetworkTransfersPanel(controller: left),
          ),
        ),
      ),
    );
    expect(find.text('暂停发送'), findsOneWidget);
    await tester.ensureVisible(find.text('暂停发送'));
    await tester.runAsync(() async {
      await tester.tap(find.text('暂停发送'));
      await waitFor(left, () => sent.phase == NetworkSendPhase.paused);
      diskB.appendGate!.complete();
      await waitFor(left, () => sent.canResume);
    });
    await tester.pump();
    expect(find.text('继续发送'), findsOneWidget);
    await tester.ensureVisible(find.text('继续发送'));
    await tester.runAsync(() async {
      await tester.tap(find.text('继续发送'));
      await sent.done.timeout(const Duration(seconds: 10));
    });
    await tester.pump();
    expect(find.text('对方已保存：panel.bin (1)'), findsOneWidget);
    expect(find.text('继续发送'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'removed selection keeps failed retirement visible and retryable',
    () async {
      diskB.failClose = true;
      final item = await prepare(filesA, queueA, 'cleanup-pending', 3);
      final job = left.send(item, a.sessions.single);
      await job.done;
      await waitFor(left, () => job.retirementFailure != null);
      expect(job.phase, NetworkSendPhase.completed);
      expect(job.receipt, isNotNull);
      await queueA.remove(item);
      expect(left.sends, isEmpty);
      expect(left.pendingRetirements.single.record.name, 'cleanup-pending.bin');
      expect(left.sendProgress().completedFiles, 1);
      expect(left.sendProgress().totalBytes, BigInt.from(3));
      expect(left.sendHistory, isEmpty);
      diskB.failClose = false;
      left.retryPendingRetirement(left.pendingRetirements.single);
      await waitFor(left, () => left.pendingRetirements.isEmpty);
      expect(
        left.sendHistory.single.file.outcome,
        FileRetirementOutcome.completed,
      );
      expect(
        right.receiveHistory.single.file.outcome,
        FileRetirementOutcome.completed,
      );
      expect(right.received, isEmpty);
    },
  );

  test('automatic retirement permits 70 production sends with bounded display history', () async {
    for (var index = 0; index < 70; index++) {
      final item = await prepare(filesA, queueA, 'sequential-$index', 3);
      final job = left.send(item, a.sessions.single);
      await job.done;
      await waitFor(left, () => job.retirementComplete);
      expect(right.received, isEmpty);
      expect(job.receipt, isNotNull);
      await queueA.remove(item);
      expect(left.sends, isEmpty);
      expect(left.sendHistory.length, lessThanOrEqualTo(64));
      expect(right.receiveHistory.length, lessThanOrEqualTo(64));
    }
    expect(diskB.receipts, hasLength(70));
    expect(sourceA.activeScopes, 0);
    expect(left.sendHistory.first.file.transferOrdinal, 7);
    expect(right.receiveHistory.last.file.transferOrdinal, 70);
    expect(left.sendProgress().completedFiles, 64);
    expect(right.receiveProgress().completedFiles, 64);
  });

  testWidgets(
    'retired display history preserves the real saved name after selection removal',
    (tester) async {
      await tester.runAsync(() async {
        final item = await prepare(filesA, queueA, 'history', 3);
        final job = left.send(item, a.sessions.single);
        await job.done;
        await waitFor(left, () => job.retirementComplete);
        expect(
          left.sendHistory,
          isEmpty,
          reason: 'The selected row already displays this result.',
        );
        await queueA.remove(item);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: NetworkTransfersPanel(controller: left),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('对方已保存：history.bin (1)'), findsOneWidget);
      expect(find.text('发送 · 已完成 1/1'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: NetworkTransfersPanel(controller: right),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已保存：history.bin (1)'), findsOneWidget);
      expect(find.text('取消接收'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('removed selection retains an unconfirmed cancellation and its retry action', () async {
    final item = await prepare(filesA, queueA, 'unconfirmed-cleanup', 70000);
    diskB.appendGate = Completer<void>();
    final job = left.send(item, a.sessions.single);
    await diskB.appendEntered.future;
    diskB.failCancel = true;
    await left.cancel(job);
    await waitFor(left, () => job.cancellationFailure != null);
    await queueA.remove(item);
    expect(left.sends.single, same(job));
    expect(job.cancellationPending, isTrue);
    expect(job.cancellationFailure, isNotNull);
    expect(left.sendHistory, isEmpty);
    diskB.failCancel = false;
    diskB.appendGate!.complete();
    left.retryCancelNotification(job);
    await waitFor(
      left,
      () =>
          left.sends.isEmpty &&
          left.pendingRetirements.isEmpty &&
          left.sendHistory.isNotEmpty,
    );
    expect(
      left.sendHistory.single.file.outcome,
      FileRetirementOutcome.cancelled,
    );
    expect(right.received, isEmpty);
    expect(diskB.receipts, isEmpty);
  });

  test('removing a sending item also cancels the retained peer task', () async {
    final item = await prepare(filesA, queueA, 'cancel', 70000);
    diskB.appendGate = Completer<void>();
    final sent = left.send(item, a.sessions.single);
    await diskB.appendEntered.future;
    final cancelled = Completer<void>();
    void check() {
      if (right.received.single.entry.task!.phase ==
              IncomingFilePhase.cancelled &&
          !cancelled.isCompleted) {
        cancelled.complete();
      }
    }

    right.addListener(check);
    try {
      await queueA.remove(item);
      await cancelled.future.timeout(const Duration(seconds: 2));
      diskB.appendGate!.complete();
      await sent.done;
      expect(sent.phase, NetworkSendPhase.cancelled);
      expect(diskB.receipts, isEmpty);
    } finally {
      right.removeListener(check);
    }
  });
}
