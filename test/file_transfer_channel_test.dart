import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_open/features/transfers/file_transfer_channel.dart';
import 'package:share_hub_open/features/transfers/incoming_file_transfer.dart';
import 'package:share_hub_open/features/transfers/receive_access.dart';
import 'package:share_hub_open/features/transfers/receive_directories.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';
import 'package:share_hub_open/features/transfers/outgoing_file_transfer.dart';
import 'package:share_hub_open/features/transfers/source_access.dart';
import 'package:share_hub_open/features/transfers/verified_file_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Pair pair;
  setUp(() async => pair = await _Pair.create());
  tearDown(() => pair.close());

  Future<void> recoverGrant() async {
    pair.sender.suspend();
    pair.receiver.suspend();
    await pair.receiver.acceptResume(
      await pair.sender.finishResume(
        await pair.receiver.answerResume(await pair.sender.beginResume()),
      ),
    );
  }

  Future<({OutgoingFileTransfer task, FileTransferChannel peer})>
  sendFromReceiver() async {
    final reverse = pair.reverse = _ReverseTransport(pair);
    final peer = FileTransferChannel(
      registry: GrantRegistry()..register(pair.sender),
      transport: reverse,
      access: _Disk(),
      directory: () async =>
          const ReceiveDirectory(token: 'peer', label: 'Downloads'),
    );
    addTearDown(peer.close);
    final publication = pair.channel.reserveOutgoing();
    final request = await pair.receiver.authorizeLocal(
      SessionOperation.file,
      publication.nextOperation(pair.receiver.role).encoded,
      FileCodec.encode(
        FileOffer(
          transferId: _id,
          transferOrdinal: publication.ordinal,
          name: 'sample.bin',
          size: 3,
          sha256: _hash,
          chunkBytes: FileLimits.chunkBytes,
        ),
      ),
    );
    final task = OutgoingFileTransfer(
      transport: pair.wire,
      publication: publication,
      source: VerifiedFileSource(
        access: _Source(Uint8List.fromList([1, 2, 3])),
        file: const SelectedFile(
          token: 'outgoing',
          name: 'sample.bin',
          size: 3,
        ),
        context: await FileTransferContext.fromRequest(
          pair.channel.registry,
          request,
        ),
      ),
    );
    pair.channel.trackOutgoing(task);
    return (task: task, peer: peer);
  }

  test('forgetting a completed sender retires its peer slot before releasing history', () async {
    final owners = await sendFromReceiver();
    await owners.task.start();
    await pair.channel.forgetOutgoing(owners.task);
    await pair.channel.whenIdle;
    expect(owners.peer.received, isEmpty);
    expect(
      owners.peer.receiveHistory.single.actualName,
      owners.task.receipt!.actualName,
    );
    expect(pair.channel.outgoing, isEmpty);
  });

  test(
    'confirmed cancellation retires an unstarted sender tombstone',
    () async {
      final owners = await sendFromReceiver();
      final cancellation = pair.channel.cancelOutgoing(owners.task);
      await pair.channel.whenIdle;
      await owners.peer.whenIdle;
      await pair.channel.whenIdle;
      expect(cancellation.acknowledged, isTrue);
      await pair.channel.forgetOutgoing(owners.task);
      await pair.channel.whenIdle;
      expect(owners.peer.receiveHistory, hasLength(1));
      expect(
        owners.peer.receiveHistory.single.outcome,
        FileRetirementOutcome.cancelled,
      );
      expect(pair.channel.outgoing, isEmpty);
    },
  );

  test(
    'retirement corrects a cancelled sender to the committed receipt',
    () async {
      final owners = await sendFromReceiver();
      pair.reverse!.cancelFirstComplete = true;
      await expectLater(
        owners.task.start(),
        throwsA(isA<FileProtocolFailure>()),
      );
      expect(owners.task.receipt, isNull);
      expect(owners.task.mayHaveCommitted, isTrue);
      final retirement = pair.channel.retireOutgoing(owners.task);
      await pair.channel.whenIdle;
      expect(retirement.retired, isTrue);
      expect(retirement.receipt?.actualName, 'sample (1).bin');
      expect(
        pair.channel.sendHistory.single.outcome,
        FileRetirementOutcome.completed,
      );
      expect(owners.peer.receiveHistory.single.actualName, 'sample (1).bin');
    },
  );

  test('lost retired reply is retried after original grant recovery without duplicate history', () async {
    final owners = await sendFromReceiver();
    await owners.task.start();
    pair.reverse!.dropNextRetired = true;
    final retirement = pair.channel.retireOutgoing(owners.task);
    await Future.doWhile(() async {
      await Future<void>.delayed(Duration.zero);
      return owners.peer.receiveHistory.isEmpty;
    }).timeout(const Duration(seconds: 3));
    await owners.peer.whenIdle;
    expect(retirement.retired, isFalse);
    await Future.wait([
      pair.channel.suspendTransport(),
      owners.peer.suspendTransport(),
    ]);
    await recoverGrant();
    await owners.peer.resumeTransport();
    await pair.channel.resumeTransport();
    await pair.channel.whenIdle;
    expect(retirement.retired, isTrue);
    expect(owners.peer.receiveHistory, hasLength(1));
    expect(pair.channel.sendHistory, hasLength(1));
  });

  test(
    'new-generation retirement does not wait for an old resume prerequisite',
    () async {
      final owners = await sendFromReceiver();
      // Hold source authorization verification in the original start. The next
      // resume must wait for that start, but a newer retirement must not.
      pair.nextClockGate = Completer<void>();
      final started = owners.task.start();
      unawaited(
        started.then<void>((_) {}, onError: (Object e, StackTrace s) {}),
      );
      await pair.nextClockEntered.future;
      await Future.wait([
        pair.channel.suspendTransport(),
        owners.peer.suspendTransport(),
      ]);
      await recoverGrant();
      await owners.peer.resumeTransport();
      await pair.channel.resumeTransport();
      final original = owners.task.context;
      final request = await pair.wire.createRequest(
        SessionOperation.file,
        owners.task.publication!.nextOperation(pair.receiver.role).encoded,
        FileCodec.encode(
          FileResume(
            transferId: original.transferId,
            transferOrdinal: original.transferOrdinal,
            name: 'sample.bin',
            size: 3,
            sha256: _hash,
            chunkBytes: FileLimits.chunkBytes,
            attemptId: 'e' * 32,
          ),
        ),
      );
      final resumed = pair.channel.resumeOutgoing(owners.task, request);
      unawaited(
        resumed.then<void>((_) {}, onError: (Object e, StackTrace s) {}),
      );
      await Future<void>.delayed(Duration.zero);
      await Future.wait([
        pair.channel.suspendTransport(),
        owners.peer.suspendTransport(),
      ]);
      await recoverGrant();
      await owners.peer.resumeTransport();
      await pair.channel.resumeTransport();
      final cancellation = pair.channel.cancelOutgoing(owners.task);
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return !cancellation.acknowledged;
      }).timeout(const Duration(seconds: 3));
      final retirement = pair.channel.retireOutgoing(owners.task);
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return !retirement.retired;
      }).timeout(const Duration(seconds: 3));
      expect(pair.nextClockGate!.isCompleted, isFalse);
      expect(pair.channel.sendHistory, hasLength(1));
      pair.nextClockGate!.complete();
      await pair.channel.whenIdle;
      expect(pair.channel.outgoing, isEmpty);
    },
  );

  test(
    'local cancellation alone cannot authorize outgoing retirement',
    () async {
      final owners = await sendFromReceiver();
      await owners.task.cancel(notifyPeer: false);
      expect(pair.channel.canRetireOutgoing(owners.task), isFalse);
      expect(
        () => pair.channel.retireOutgoing(owners.task),
        throwsA(isA<FileProtocolFailure>()),
      );
      expect(pair.channel.outgoing, hasLength(1));
      expect(pair.channel.sendHistory, isEmpty);
      expect(owners.peer.receiveHistory, isEmpty);
    },
  );

  test(
    'outgoing retirement retains cleanup failure and retries the same owner',
    () async {
      final owners = await sendFromReceiver();
      await owners.task.start();
      final source = owners.task.source.access as _Source;
      source.failClose = true;
      addTearDown(() {
        source.failClose = false;
      });
      final retirement = pair.channel.retireOutgoing(owners.task);
      await pair.channel.whenIdle;
      expect(retirement.failure, isNotNull);
      expect(retirement.retired, isFalse);
      expect(pair.channel.outgoing, hasLength(1));
      expect(owners.peer.received, hasLength(1));
      source.failClose = false;
      pair.channel.retryOutgoingRetirement(retirement);
      await pair.channel.whenIdle;
      expect(retirement.retired, isTrue);
      expect(pair.channel.outgoing, isEmpty);
      expect(owners.peer.received, isEmpty);
      expect(
        pair.channel.sendHistory.single.actualName,
        owners.task.receipt!.actualName,
      );
    },
  );

  test('early retired acknowledgement keeps a blocked write bounded until physical recovery', () async {
    final owners = await sendFromReceiver();
    await owners.task.start();
    final oldWrite = pair.wire.requestReturnGate = Completer<void>();
    addTearDown(() {
      if (!oldWrite.isCompleted) oldWrite.complete();
    });
    final retirement = pair.channel.retireOutgoing(owners.task);
    await Future.doWhile(() async {
      await Future<void>.delayed(Duration.zero);
      return owners.peer.receiveHistory.isEmpty;
    }).timeout(const Duration(seconds: 3));
    await owners.peer.whenIdle;
    expect(pair.channel.outgoing, hasLength(1));
    expect(retirement.retired, isFalse);
    await Future.wait([
      pair.channel.suspendTransport(),
      owners.peer.suspendTransport(),
    ]);
    await recoverGrant();
    await owners.peer.resumeTransport();
    await pair.channel.resumeTransport();
    await pair.channel.whenIdle;
    expect(retirement.retired, isTrue);
    expect(pair.channel.sendHistory, hasLength(1));
    oldWrite.complete();
    await Future<void>.delayed(Duration.zero);
    expect(pair.channel.sendHistory, hasLength(1));
    expect(owners.peer.receiveHistory, hasLength(1));
  });

  test(
    'completed retirement releases its slot and old data cannot reopen it',
    () async {
      final request = await pair.offer();
      await pair.next();
      await pair.chunk(request, [1, 2, 3]);
      await pair.next();
      await pair.signal(
        request,
        FileFinish(transferId: _id, size: 3, sha256: _hash),
      );
      final saved = await pair.next() as FileComplete;
      await pair.channel.whenIdle;
      await pair.retire(
        outcome: FileRetirementOutcome.completed,
        actualName: saved.actualName,
      );
      expect(await pair.next(), isA<FileRetired>());
      expect(pair.channel.received, isEmpty);
      await pair.retire(
        outcome: FileRetirementOutcome.completed,
        actualName: saved.actualName,
      );
      expect(await pair.next(), isA<FileRetired>());
      await pair.offer(operationId: 'file-v2-i-1-2');
      expect(await pair.next(), isA<FileRejected>());
      await pair.offer(session: 'next-file', id: 'b' * 32);
      expect(await pair.next(), isA<FileAccept>());
      expect(pair.disk.begins, 2);
      expect(pair.disk.commits, 1);
    },
  );

  for (final outcome in [
    FileRetirementOutcome.cancelled,
    FileRetirementOutcome.failed,
  ]) {
    test(
      'matching $outcome retirement requires the actual terminal result',
      () async {
        pair.failDirectory = outcome == FileRetirementOutcome.failed;
        final request = await pair.offer();
        if (pair.failDirectory) {
          expect(await pair.next(), isA<FileFailed>());
        } else {
          await pair.next();
          await pair.signal(request, FileCancel(transferId: _id));
          expect(await pair.next(), isA<FileCancelled>());
        }
        await pair.channel.whenIdle;
        await pair.retire(
          outcome: outcome,
          failureCode: pair.failDirectory ? 'permission_denied' : null,
        );
        expect(await pair.next(), isA<FileRetired>());
        expect(pair.channel.received, isEmpty);
      },
    );
  }

  test('retirement cannot cancel an active or paused file', () async {
    final request = await pair.offer();
    await pair.next();
    await pair.retire();
    expect(await pair.next(), isA<FileRejected>());
    expect(pair.disk.stops, isEmpty);
    await pair.signal(request, FilePause(transferId: _id));
    await pair.next();
    await pair.retire();
    expect(await pair.next(), isA<FileRejected>());
    expect(pair.disk.stops, isNot(contains(ReceiveStopMode.cancel)));
    expect(pair.channel.received, hasLength(1));
  });

  test(
    'retirement corrects cancellation to the saved receipt without deleting it',
    () async {
      final request = await pair.offer();
      await pair.next();
      await pair.chunk(request, [1, 2, 3]);
      await pair.next();
      await pair.signal(
        request,
        FileFinish(transferId: _id, size: 3, sha256: _hash),
      );
      final saved = await pair.next() as FileComplete;
      await pair.channel.whenIdle;
      await pair.retire();
      expect((await pair.next() as FileComplete).actualName, saved.actualName);
      expect(pair.channel.received, hasLength(1));
      await pair.retire(
        outcome: FileRetirementOutcome.completed,
        actualName: 'wrong.bin',
      );
      expect(await pair.next(), isA<FileRejected>());
      expect(pair.channel.received, hasLength(1));
      await pair.retire(
        outcome: FileRetirementOutcome.completed,
        actualName: saved.actualName,
      );
      expect(await pair.next(), isA<FileRetired>());
      expect(pair.disk.commits, 1);
    },
  );

  test(
    'retiring an unseen future ordinal cannot consume a future file',
    () async {
      await pair.retire(ordinal: 5);
      expect(await pair.next(), isA<FileRejected>());
      await pair.offer();
      expect(await pair.next(), isA<FileAccept>());
      expect(pair.disk.begins, 1);
    },
  );

  test(
    'retirement releases a termination tombstone without opening storage',
    () async {
      await pair.terminate();
      expect(await pair.next(), isA<FileCancelled>());
      await pair.channel.whenIdle;
      await pair.retire();
      expect(await pair.next(), isA<FileRetired>());
      expect(
        pair.channel.receiveHistory.single.outcome,
        FileRetirementOutcome.cancelled,
      );
      await pair.terminate(session: 'late-stop');
      expect(await pair.next(), isA<FileRejected>());
      expect(pair.directoryCalls, 0);
    },
  );

  test(
    'retirement cleanup failure retains owner and retry removes it once',
    () async {
      final request = await pair.offer();
      await pair.next();
      pair.failLeaseRelease = true;
      await pair.signal(request, FileCancel(transferId: _id));
      await pair.next();
      await pair.channel.whenIdle;
      await pair.retire();
      expect(await pair.next(), isA<FileRejected>());
      expect(pair.channel.received.single.cleanupFailure, isNotNull);
      expect(pair.channel.receiveHistory, isEmpty);
      pair.failLeaseRelease = false;
      await pair.retire();
      expect(await pair.next(), isA<FileRetired>());
      expect(pair.channel.received, isEmpty);
      expect(pair.leaseReleases, 1);
      await pair.retire();
      expect(await pair.next(), isA<FileRetired>());
      expect(pair.channel.receiveHistory, hasLength(1));
    },
  );

  test('retirement waits for an already admitted completion reply', () async {
    final request = await pair.offer();
    await pair.next();
    await pair.chunk(request, [1, 2, 3]);
    await pair.next();
    pair.wire.sendGate = Completer<void>();
    await pair.signal(
      request,
      FileFinish(transferId: _id, size: 3, sha256: _hash),
    );
    final saved = await pair.next() as FileComplete;
    await pair.wire.sendEntered.future;
    await pair.retire(
      outcome: FileRetirementOutcome.completed,
      actualName: saved.actualName,
    );
    await Future<void>.delayed(Duration.zero);
    expect(pair.channel.received, hasLength(1));
    expect(pair.channel.receiveHistory, isEmpty);
    pair.wire.sendGate!.complete();
    expect(await pair.next(), isA<FileRetired>());
    expect(pair.channel.receiveHistory.single.actualName, saved.actualName);
  });

  test('retirement drains a failed local cancellation notification without waiting for an ACK', () async {
    await pair.offer();
    await pair.next();
    // This one-way fixture has no reverse request receiver, so the notification
    // send fails after local stop. FileCancel still reaches the producer.
    await pair.channel.cancelReceived(pair.channel.received.single);
    expect(await pair.next(), isA<FileCancel>());
    await pair.channel.whenIdle;
    expect(pair.channel.received.single.notificationFailure, isNotNull);
    await pair.retire();
    expect(await pair.next(), isA<FileRetired>());
    expect(pair.channel.received, isEmpty);
  });

  test('physical replacement during retirement cleanup cannot delete the retained slot', () async {
    final request = await pair.offer();
    await pair.next();
    await pair.signal(request, FileCancel(transferId: _id));
    await pair.next();
    await pair.channel.whenIdle;
    pair.disk.closeGate = Completer<void>();
    await pair.retire();
    await pair.disk.closeEntered.future;
    await pair.channel.suspendTransport();
    await recoverGrant();
    await pair.channel.resumeTransport();
    await pair.channel.whenIdle;
    expect(pair.channel.received, hasLength(1));
    expect(pair.channel.receiveHistory, isEmpty);
    pair.disk.closeGate!.complete();
    await pair.retire();
    expect(await pair.next(), isA<FileRetired>());
    expect(pair.channel.receiveHistory, hasLength(1));
  });

  test(
    'concurrent retirement and terminate cannot replace cleanup ownership',
    () async {
      final request = await pair.offer();
      await pair.next();
      await pair.signal(request, FileCancel(transferId: _id));
      await pair.next();
      await pair.channel.whenIdle;
      pair.disk.closeGate = Completer<void>();
      await pair.retire();
      await pair.disk.closeEntered.future;
      await pair.retire();
      expect(await pair.next(), isA<FileRejected>());
      await pair.terminate();
      expect(await pair.next(), isA<FileRejected>());
      await pair.offer(resume: true, operationId: 'file-v2-i-1-2');
      expect(await pair.next(), isA<FileRejected>());
      pair.disk.closeGate!.complete();
      expect(await pair.next(), isA<FileRetired>());
      expect(pair.disk.begins, 1);
      expect(pair.channel.receiveHistory, hasLength(1));
    },
  );

  test('520 received files retire with bounded immutable history and no old resolver', () async {
    for (var ordinal = 1; ordinal <= 520; ordinal++) {
      final id = ordinal.toRadixString(16).padLeft(32, '0');
      final request = await pair.offer(
        session: 'file-$ordinal',
        id: id,
        ordinal: ordinal,
      );
      expect(await pair.next(), isA<FileAccept>());
      await pair.signal(request, FileCancel(transferId: id));
      expect(await pair.next(), isA<FileCancelled>());
      await pair.retire(id: id, ordinal: ordinal);
      expect(await pair.next(), isA<FileRetired>());
      expect(pair.channel.received, isEmpty);
      expect(pair.wire.resolver!(request.sessionId), isNull);
      expect(pair.channel.receiveHistory.length, lessThanOrEqualTo(64));
    }
    final history = pair.channel.receiveHistory;
    expect(history.first.transferOrdinal, 457);
    expect(history.last.transferOrdinal, 520);
    expect(() => history.clear(), throwsUnsupportedError);
    expect(pair.disk.begins, 520);
    expect(pair.disk.releases, 520);
    await pair.offer(
      id: '0' * 31 + '1',
      ordinal: 1,
      operationId: 'file-v2-i-1-2',
    );
    expect(await pair.next(), isA<FileRejected>());
    expect(pair.disk.begins, 520);
  });

  test(
    'retirement removes a cancelled held admission before transport resumes',
    () async {
      await pair.channel.suspendTransport();
      await recoverGrant();
      final request = await pair.offer();
      await pair.signal(request, FileCancel(transferId: _id));
      await pair.retire();
      expect(await pair.next(), isA<FileRetired>());
      expect(pair.wire.resolver!(request.sessionId), isNull);
      await pair.channel.resumeTransport();
      await pair.channel.whenIdle;
      expect(pair.replies, isEmpty);
      expect(pair.channel.received, isEmpty);
      expect(pair.channel.receiveHistory, hasLength(1));
      expect(pair.disk.begins, 0);
    },
  );

  test('retirement reply loss preserves one snapshot through authenticated recovery', () async {
    await pair.terminate();
    await pair.next();
    await pair.channel.whenIdle;
    pair.wire.sendGate = Completer<void>();
    await pair.retire();
    expect(await pair.next(), isA<FileRetired>());
    await pair.wire.sendEntered.future;
    await pair.channel.suspendTransport();
    await recoverGrant();
    await pair.channel.resumeTransport();
    await pair.channel.whenIdle;
    final oldWrite = pair.wire.sendGate!;
    pair.wire.sendGate = null;
    await pair.retire();
    expect(await pair.next(), isA<FileRetired>());
    expect(pair.channel.receiveHistory, hasLength(1));
    oldWrite.complete();
    await pair.channel.whenIdle;
    expect(pair.channel.receiveHistory, hasLength(1));
  });

  for (final variant in ['control-id', 'direction', 'metadata', 'outcome']) {
    test(
      'invalid retirement $variant cannot release a cancelled owner',
      () async {
        final request = await pair.offer();
        await pair.next();
        await pair.signal(request, FileCancel(transferId: _id));
        await pair.next();
        await pair.channel.whenIdle;
        await pair.retire(
          session: variant == 'control-id' ? 'file-v2-i-1-2' : null,
          transferSender: variant == 'direction' ? GrantRole.receiver : null,
          name: variant == 'metadata' ? 'changed.bin' : 'sample.bin',
          outcome: variant == 'outcome'
              ? FileRetirementOutcome.failed
              : FileRetirementOutcome.cancelled,
          failureCode: variant == 'outcome' ? 'io_failure' : null,
        );
        expect(await pair.next(), isA<FileRejected>());
        expect(pair.channel.received, hasLength(1));
        expect(pair.channel.receiveHistory, isEmpty);
        await pair.retire();
        expect(await pair.next(), isA<FileRetired>());
      },
    );
  }

  for (final invalid in [
    'legacy-random-id',
    'file-v2-i-01-1',
    'file-v2-r-1-1',
    'file-v2-i-2-1',
    'file-terminate-deadbeef',
  ]) {
    test(
      'invalid data operation $invalid cannot open a received file',
      () async {
        await pair.offer(operationId: invalid);
        expect(await pair.next(), isA<FileRejected>());
        await pair.channel.whenIdle;
        expect(pair.channel.received, isEmpty);
        expect(pair.directoryCalls, 0);
        expect(pair.disk.begins, 0);
        await pair.offer(operationId: 'file-v2-i-1-1');
        expect(await pair.next(), isA<FileAccept>());
      },
    );
  }

  test(
    'incoming ordinal high water rejects a later unseen lower file',
    () async {
      await pair.offer(ordinal: 2);
      expect(await pair.next(), isA<FileAccept>());
      await pair.offer(session: 'late-lower', id: 'b' * 32, ordinal: 1);
      expect(await pair.next(), isA<FileRejected>());
      expect(pair.disk.begins, 1);
      expect(pair.directoryCalls, 1);
    },
  );

  test('busy rejection consumes the newer resume attempt without replacing the resolver', () async {
    final original = await pair.offer();
    await pair.next();
    final authority = pair.wire.resolver!(original.sessionId);
    await pair.offer(resume: true, operationId: 'file-v2-i-1-5');
    expect(await pair.next(), isA<FileRejected>());
    expect(pair.wire.resolver!(original.sessionId), same(authority));
    await pair.signal(original, FilePause(transferId: _id));
    expect(await pair.next(), isA<FilePaused>());
    await pair.offer(resume: true, operationId: 'file-v2-i-1-4');
    expect(await pair.next(), isA<FileRejected>());
    await pair.offer(resume: true, operationId: 'file-v2-i-1-6');
    expect(await pair.next(), isA<FileResumeState>());
    expect(pair.disk.resumes, 1);
  });

  test(
    'superseded native rebind is stopped and cleaned before any resume state',
    () async {
      final original = await pair.offer();
      await pair.next();
      await pair.signal(original, FilePause(transferId: _id));
      expect(await pair.next(), isA<FilePaused>());
      final authority = pair.wire.resolver!(original.sessionId);
      pair.disk.resumeGate = Completer<void>();
      await pair.offer(resume: true, operationId: 'file-v2-i-1-2');
      await pair.disk.resumeEntered.future;
      expect(pair.wire.resolver!(original.sessionId), same(authority));
      await pair.offer(resume: true, operationId: 'file-v2-i-1-3');
      expect(await pair.next(), isA<FileRejected>());
      pair.disk.resumeGate!.complete();
      await pair.channel.whenIdle;
      expect(pair.replies.whereType<FileResumeState>(), isEmpty);
      expect(pair.disk.stops, contains(ReceiveStopMode.cancel));
      expect(
        pair.disk.cancelledScopes,
        contains(pair.disk.resumedScopes.single),
      );
      expect(pair.disk.aborts, 1);
      expect(pair.disk.releases, 1);
      expect(pair.disk.begins, 1);
    },
  );

  test(
    'channel recovery restores unconfirmed first-publication barriers',
    () async {
      final first = pair.channel.reserveOutgoing(),
          second = pair.channel.reserveOutgoing();
      await first.publish(() async {});
      expect(second.canPublish, isTrue);
      await pair.channel.suspendTransport();
      await recoverGrant();
      await pair.channel.resumeTransport();
      expect(second.canPublish, isFalse);
      await first.publish(() async {});
      expect(second.canPublish, isTrue);
    },
  );

  test(
    'a held new file survives two losses before native work settles',
    () async {
      final original = await pair.offer();
      await pair.next();
      pair.disk.appendGate = Completer<void>();
      await pair.chunk(original, [1, 2, 3]);
      await pair.disk.appendEntered.future;
      final firstPause = pair.channel.suspendTransport();
      await recoverGrant();
      await pair.offer(session: 'held-new', id: 'b' * 32);
      final secondPause = pair.channel.suspendTransport();
      await recoverGrant();
      pair.disk.appendGate!.complete();
      await Future.wait([firstPause, secondPause]);
      await pair.channel.resumeTransport();
      await pair.offer(session: 'held-new-resume', id: 'b' * 32, resume: true);
      expect(
        await pair.next(),
        isA<FileResumeState>().having((s) => s.offset, 'offset', 0),
      );
      expect(pair.disk.begins, 2);
      expect(pair.disk.resumes, 0);
    },
  );

  test(
    'invalid duplicate offer cannot invalidate a valid resume ticket',
    () async {
      final original = await pair.offer();
      await pair.next();
      await pair.signal(original, FilePause(transferId: _id));
      await pair.next();
      pair.disk.resumeGate = Completer<void>();
      await pair.offer(resume: true, operationId: 'file-v2-i-1-2');
      await pair.disk.resumeEntered.future;
      await pair.offer(operationId: 'file-v2-i-1-3');
      expect(await pair.next(), isA<FileRejected>());
      pair.disk.resumeGate!.complete();
      expect(await pair.next(), isA<FileResumeState>());
      expect(pair.disk.aborts, 0);
    },
  );

  test('unknown incoming termination advances ordinal history without opening a file', () async {
    await pair.terminate(ordinal: 2);
    expect(await pair.next(), isA<FileCancelled>());
    await pair.offer(session: 'older', ordinal: 1, id: 'b' * 32);
    expect(await pair.next(), isA<FileRejected>());
    expect(pair.disk.begins, 0);
    expect(pair.directoryCalls, 0);
  });

  test(
    'higher busy attempt cannot invalidate an admitted initial native begin',
    () async {
      pair.disk.beginGate = Completer<void>();
      await pair.offer();
      await pair.disk.beginEntered.future;
      await pair.offer(resume: true, operationId: 'file-v2-i-1-5');
      expect(await pair.next(), isA<FileRejected>());
      pair.disk.beginGate!.complete();
      expect(await pair.next(), isA<FileAccept>());
      expect(pair.channel.received.single.failure, isNull);
      expect(pair.disk.aborts, 0);
    },
  );

  test('late old data cannot poison a fresh native rebind', () async {
    final original = await pair.offer();
    await pair.next();
    await pair.signal(original, FilePause(transferId: _id));
    await pair.next();
    pair.disk.resumeGate = Completer<void>();
    final fresh = await pair.offer(session: 'fresh', resume: true);
    await pair.disk.resumeEntered.future;
    for (var n = 0; n < 4; n++) {
      await pair.chunk(original, [1, 2, 3]);
    }
    expect(pair.disk.appends, 0);
    pair.disk.resumeGate!.complete();
    final state = await pair.next() as FileResumeState;
    await pair.signal(
      fresh,
      FileResumeAccept(
        transferId: _id,
        attemptId: state.attemptId,
        offset: state.offset,
        prefixSha256: state.prefixSha256,
      ),
    );
    await pair.channel.whenIdle;
    await pair.chunk(fresh, [1, 2, 3]);
    expect(await pair.next(), isA<FileAck>());
    expect(pair.channel.received.single.failure, isNull);
    expect(pair.disk.appends, 1);
  });

  test(
    'metadata mismatch cannot invalidate a pending native rebind ticket',
    () async {
      final original = await pair.offer();
      await pair.next();
      await pair.signal(original, FilePause(transferId: _id));
      await pair.next();
      pair.disk.resumeGate = Completer<void>();
      await pair.offer(resume: true, operationId: 'file-v2-i-1-2');
      await pair.disk.resumeEntered.future;
      await pair.offer(
        resume: true,
        operationId: 'file-v2-i-1-3',
        name: 'changed.bin',
      );
      expect(await pair.next(), isA<FileRejected>());
      pair.disk.resumeGate!.complete();
      expect(await pair.next(), isA<FileResumeState>());
      expect(pair.disk.aborts, 0);
    },
  );

  test(
    'pending resume cancellation stops native rebind and suppresses its state',
    () async {
      final original = await pair.offer();
      await pair.next();
      await pair.signal(original, FilePause(transferId: _id));
      await pair.next();
      pair.disk.resumeGate = Completer<void>();
      final fresh = await pair.offer(session: 'pending', resume: true);
      await pair.disk.resumeEntered.future;
      await pair.signal(fresh, FileCancel(transferId: _id));
      expect(
        pair.disk.cancelledScopes,
        contains(pair.disk.resumedScopes.single),
      );
      pair.disk.resumeGate!.complete();
      expect(await pair.next(), isA<FileCancelled>());
      await pair.channel.whenIdle;
      expect(pair.replies.whereType<FileResumeState>(), isEmpty);
      expect(pair.disk.aborts, 1);
      expect(pair.disk.releases, 1);
    },
  );

  test(
    'physical loss during native rebind cannot publish a stale binding',
    () async {
      final original = await pair.offer();
      await pair.next();
      await pair.signal(original, FilePause(transferId: _id));
      await pair.next();
      pair.disk.resumeGate = Completer<void>();
      await pair.offer(session: 'pending', resume: true);
      await pair.disk.resumeEntered.future;
      final pausing = pair.channel.suspendTransport();
      await recoverGrant();
      pair.disk.resumeGate!.complete();
      await pausing;
      await pair.channel.resumeTransport();
      await pair.channel.whenIdle;
      expect(pair.replies, isEmpty);
      expect(
        pair.disk.cancelledScopes,
        contains(pair.disk.resumedScopes.single),
      );
      expect(pair.disk.releases, 1);
      await pair.offer(session: 'after-loss', resume: true);
      expect(await pair.next(), isA<FileRejected>());
      expect(pair.disk.begins, 1);
    },
  );

  test(
    'retained lower ordinal can resume after a higher file is admitted',
    () async {
      final original = await pair.offer();
      await pair.next();
      await pair.signal(original, FilePause(transferId: _id));
      await pair.next();
      await pair.offer(session: 'higher', id: 'b' * 32);
      expect(await pair.next(), isA<FileAccept>());
      await pair.offer(session: 'lower-resume', resume: true);
      expect(await pair.next(), isA<FileResumeState>());
      expect(pair.disk.begins, 2);
      expect(pair.disk.resumes, 1);
    },
  );

  test(
    'incoming recovery no longer exhausts the old 512 operation history',
    () async {
      var request = await pair.offer();
      await pair.next();
      for (var n = 0; n < 520; n++) {
        await pair.signal(request, FilePause(transferId: _id));
        expect(await pair.next(), isA<FilePaused>());
        request = await pair.offer(session: 'resume-$n', resume: true);
        final state = await pair.next() as FileResumeState;
        await pair.signal(
          request,
          FileResumeAccept(
            transferId: _id,
            attemptId: state.attemptId,
            offset: state.offset,
            prefixSha256: state.prefixSha256,
          ),
        );
        await pair.channel.whenIdle;
      }
      expect(pair.disk.begins, 1);
      expect(pair.disk.resumes, 520);
      expect(pair.channel.received, hasLength(1));
      await pair.chunk(request, [1, 2, 3]);
      expect(await pair.next(), isA<FileAck>());
    },
  );

  for (final loseWriteCompletion in [false, true]) {
    test(
      loseWriteCompletion
          ? 'authenticated cancellation before lost write completion unblocks publication after recovery'
          : 'later cancellation waits without blocking an earlier cancellation notification',
      () async {
        final reverse = pair.reverse = _ReverseTransport(pair);
        final published = <int>[];
        final repliesSent = Completer<void>();
        var replies = 0;
        reverse.onRequest = (request) async {
          final message = FileCodec.decode(request.body) as FileTerminate;
          published.add(message.transferOrdinal);
          final response = await pair.sender.sealSignal(
            request,
            FileCodec.encode(FileCancelled(transferId: message.transferId)),
          );
          pair.wire.onSignal!(
            await pair.receiver.openSignal(
              pair.wire.resolver!(request.sessionId)!,
              response,
            ),
          );
          if (++replies == 2) repliesSent.complete();
        };
        Future<OutgoingFileTransfer> owner() async {
          final publication = pair.channel.reserveOutgoing();
          final source = _Source(Uint8List.fromList([1, 2, 3]));
          final local = await pair.receiver.authorizeLocal(
            SessionOperation.file,
            publication.nextOperation(pair.receiver.role).encoded,
            FileCodec.encode(
              FileOffer(
                transferOrdinal: publication.ordinal,
                transferId: publication.ordinal
                    .toRadixString(16)
                    .padLeft(32, '0'),
                name: 'sample.bin',
                size: 3,
                sha256: _hash,
                chunkBytes: FileLimits.chunkBytes,
              ),
            ),
          );
          final task = OutgoingFileTransfer(
            transport: pair.wire,
            publication: publication,
            source: VerifiedFileSource(
              access: source,
              file: const SelectedFile(
                token: 'local',
                name: 'sample.bin',
                size: 3,
              ),
              context: await FileTransferContext.fromRequest(
                pair.channel.registry,
                local,
              ),
            ),
          );
          pair.channel.trackOutgoing(task);
          return task;
        }

        final first = await owner(), second = await owner();
        final later = pair.channel.cancelOutgoing(second);
        await pair.channel.whenIdle;
        expect(published, isEmpty);
        final oldWrite = loseWriteCompletion ? Completer<void>() : null;
        pair.wire.requestReturnGate = oldWrite;
        addTearDown(() {
          if (oldWrite != null && !oldWrite.isCompleted) oldWrite.complete();
        });
        final earlier = pair.channel.cancelOutgoing(first);
        if (loseWriteCompletion) {
          await Future.doWhile(() async {
            await Future<void>.delayed(Duration.zero);
            return !earlier.acknowledged;
          }).timeout(const Duration(seconds: 3));
          expect(published, [1]);
          await pair.channel.suspendTransport();
          await recoverGrant();
          await pair.channel.resumeTransport();
        }
        await repliesSent.future.timeout(const Duration(seconds: 3));
        await pair.channel.whenIdle;
        expect(published, [1, 2]);
        expect(earlier.acknowledged, isTrue);
        expect(later.acknowledged, isTrue);
        if (oldWrite != null) expect(oldWrite.isCompleted, isFalse);
      },
    );
  }

  test(
    'fresh termination cancels only the matching direction without a new scope',
    () async {
      await pair.offer();
      await pair.next();
      await pair.terminate(
        session: 'wrong-direction',
        sender: GrantRole.receiver,
      );
      expect(await pair.next(), isA<FileRejected>());
      expect(pair.channel.received.single.canCancel, isTrue);
      await pair.terminate(session: 'wrong-metadata', size: 4);
      expect(await pair.next(), isA<FileRejected>());
      expect(pair.channel.received.single.canCancel, isTrue);
      await pair.terminate(session: 'correct');
      expect(await pair.next(), isA<FileCancelled>());
      await pair.channel.whenIdle;
      expect(pair.disk.begins, 1);
      expect(pair.disk.resumes, 0);
      expect(pair.disk.aborts, 1);
      expect(pair.channel.received.single.canCancel, isFalse);
    },
  );

  test(
    'unknown terminated file can never be opened by a later offer',
    () async {
      await pair.terminate();
      expect(await pair.next(), isA<FileCancelled>());
      await pair.offer();
      expect(await pair.next(), isA<FileCancelled>());
      expect(pair.disk.begins, 0);
      expect(pair.directoryCalls, 0);
    },
  );

  test(
    'termination of an already published file returns its original receipt',
    () async {
      final original = await pair.offer();
      await pair.next();
      await pair.chunk(original, [1, 2, 3]);
      await pair.next();
      await pair.signal(
        original,
        FileFinish(transferId: _id, size: 3, sha256: _hash),
      );
      final receipt = await pair.next() as FileComplete;
      await pair.terminate();
      final repeated = await pair.next() as FileComplete;
      expect(repeated.actualName, receipt.actualName);
      expect(pair.disk.commits, 1);
      expect(pair.disk.aborts, 0);
    },
  );

  test('full incoming history rejects new terminal facts but preserves local cleanup', () async {
    await pair.offer();
    await pair.next();
    for (var index = 0; index < FileTransferChannel.maxTransfers - 1; index++) {
      await pair.terminate(
        session: 't-$index',
        id: index.toRadixString(16).padLeft(32, '0'),
      );
      expect(await pair.next(), isA<FileCancelled>());
    }
    await pair.terminate(session: 'overflow-terminal', id: 'f' * 32);
    expect((await pair.next() as FileRejected).code, 'resource_limit');
    await pair.offer(session: 'overflow-data', id: 'f' * 32);
    expect((await pair.next() as FileRejected).code, 'invalid_state');
    final entry = pair.channel.received.single;
    await pair.channel.cancelReceived(entry);
    await pair.channel.whenIdle;
    expect(entry.canCancel, isFalse);
    expect(pair.disk.aborts, 1);
    expect(pair.disk.releases, 1);
  });

  test(
    'termination clock waits do not retain the channel after loss and close',
    () async {
      final local = await pair.sender.authorizeLocal(
        SessionOperation.file,
        'clock-terminal',
        FileCodec.encode(
          FileTerminate(
            transferOrdinal: 1,
            transferId: _id,
            transferSender: GrantRole.initiator,
            name: 'sample.bin',
            size: 3,
            sha256: _hash,
            chunkBytes: FileLimits.chunkBytes,
          ),
        ),
      );
      pair.locals['clock-terminal'] = local;
      final remote = await pair.receiver.open(
        await pair.sender.sealRequest(local),
      );
      pair.nextClockGate = Completer<void>();
      pair.wire.onRequest!(remote);
      await pair.nextClockEntered.future;
      await pair.channel.suspendTransport();
      await pair.channel.close().timeout(const Duration(seconds: 1));
      expect(pair.disk.begins, 0);
      expect(pair.replies, isEmpty);
      pair.nextClockGate!.complete();
    },
  );

  for (final admitted in [false, true]) {
    test(
      'resume from zero when initial file was never opened (admitted=$admitted)',
      () async {
        if (admitted) {
          pair.directoryGate = Completer<void>();
          await pair.offer();
          await pair.directoryEntered.future;
        }
        final pausing = pair.channel.suspendTransport();
        await recoverGrant();
        final resuming = pair.channel.resumeTransport();
        final fresh = await pair.offer(session: 'empty-resume', resume: true);
        pair.directoryGate?.complete();
        await pausing;
        await resuming;
        final state = await pair.next() as FileResumeState;
        expect(state.offset, 0);
        expect(state.prefixSha256, hashes.sha256.convert([]).toString());
        await pair.signal(
          fresh,
          FileResumeAccept(
            transferId: _id,
            attemptId: 'c' * 32,
            offset: 0,
            prefixSha256: state.prefixSha256,
          ),
        );
        await pair.channel.whenIdle;
        await pair.chunk(fresh, [1, 2, 3]);
        expect(await pair.next(), isA<FileAck>());
        await pair.signal(
          fresh,
          FileFinish(transferId: _id, size: 3, sha256: _hash),
        );
        expect(await pair.next(), isA<FileComplete>());
        expect(pair.disk.begins, 1);
        expect(pair.disk.resumes, 0);
      },
    );
  }

  test(
    'unstarted cancellation remains terminal while its reply clock is pending',
    () async {
      await pair.channel.suspendTransport();
      await recoverGrant();
      final fresh = await pair.offer(session: 'unstarted-cancel', resume: true);
      await pair.signal(fresh, FileCancel(transferId: _id));
      pair.nextClockGate = Completer<void>();
      final resuming = pair.channel.resumeTransport();
      await pair.nextClockEntered.future;
      final secondPause = pair.channel.suspendTransport();
      await recoverGrant();
      pair.nextClockGate!.complete();
      await resuming;
      await secondPause;
      await pair.channel.whenIdle;
      await pair.channel.resumeTransport();
      await pair.offer(session: 'after-unstarted-cancel', resume: true);
      expect(await pair.next(), isA<FileRejected>());
      expect(pair.disk.begins, 0);
    },
  );

  test('transport suspension gates native work before invalidation and holds early resume', () async {
    final original = await pair.offer();
    await pair.next();
    pair.disk.appendGate = Completer<void>();
    await pair.chunk(original, [1, 2, 3]);
    await pair.disk.appendEntered.future;
    final paused = pair.channel.suspendTransport();
    expect(pair.disk.stops.last, ReceiveStopMode.pause);
    expect(pair.channel.received.single.task!.phase, IncomingFilePhase.paused);
    await recoverGrant();
    expect(pair.disk.stops, isNot(contains(ReceiveStopMode.cancel)));
    final resuming = pair.channel.resumeTransport();
    final request = await pair.offer(session: 'after-loss', resume: true);
    expect(pair.disk.resumes, 0);
    pair.disk.appendGate!.complete();
    await paused;
    await resuming;
    final state = await pair.next() as FileResumeState;
    expect(state.offset, 3);
    expect(pair.disk.begins, 1);
    expect(pair.disk.resumes, 1);
    await pair.signal(
      request,
      FileResumeAccept(
        transferId: _id,
        attemptId: 'c' * 32,
        offset: 3,
        prefixSha256: _hash,
      ),
    );
    await pair.channel.whenIdle;
    await pair.signal(
      request,
      FileFinish(transferId: _id, size: 3, sha256: _hash),
    );
    expect(await pair.next(), isA<FileComplete>());
  });

  test(
    'closing a suspended channel upgrades native pause to cancellation',
    () async {
      await pair.offer();
      await pair.next();
      await pair.channel.suspendTransport();
      pair.receiver.suspend();
      await pair.channel.close();
      expect(pair.disk.stops, contains(ReceiveStopMode.cancel));
      expect(pair.disk.aborts, 1);
      expect(pair.disk.commits, 0);
    },
  );

  test('queued old replies cannot occupy a recovered response queue', () async {
    pair.wire.sendGate = Completer<void>();
    await pair.offer();
    await pair.wire.sendEntered.future;
    expect(await pair.next(), isA<FileAccept>());
    final paused = pair.channel.suspendTransport();
    await recoverGrant();
    await paused;
    final oldGate = pair.wire.sendGate!;
    pair.wire.sendGate = null;
    await pair.channel.resumeTransport();
    await pair.offer(session: 'fresh-reply', resume: true);
    expect(await pair.next(), isA<FileResumeState>());
    oldGate.complete();
    await pair.channel.whenIdle;
    expect(pair.replies, isEmpty);
  });

  test(
    'a second transport loss invalidates an earlier pending resume',
    () async {
      final original = await pair.offer();
      await pair.next();
      pair.disk.appendGate = Completer<void>();
      await pair.chunk(original, [1, 2, 3]);
      await pair.disk.appendEntered.future;
      final paused = pair.channel.suspendTransport();
      await recoverGrant();
      final staleResume = pair.channel.resumeTransport();
      final secondPause = pair.channel.suspendTransport();
      pair.disk.appendGate!.complete();
      await paused;
      await secondPause;
      await staleResume;
      await pair.offer(session: 'held-after-second-loss', resume: true);
      await Future<void>.delayed(Duration.zero);
      expect(pair.disk.resumes, 0);
      expect(pair.replies, isEmpty);
      await pair.channel.resumeTransport();
      expect(await pair.next(), isA<FileResumeState>());
    },
  );

  test(
    'held cancellation with another ordinal cannot stop the original file',
    () async {
      await pair.offer();
      expect(await pair.next(), isA<FileAccept>());
      await pair.channel.suspendTransport();
      await recoverGrant();
      final wrong = await pair.offer(
        session: 'wrong-held-ordinal',
        resume: true,
        ordinal: 2,
      );
      await pair.signal(wrong, FileCancel(transferId: _id));
      await pair.channel.whenIdle;
      expect(pair.disk.stops, isNot(contains(ReceiveStopMode.cancel)));
      expect(pair.channel.received.single.canCancel, isTrue);
      await pair.channel.resumeTransport();
      expect(await pair.next(), isA<FileRejected>());
      final resumed = await pair.offer(
        session: 'correct-ordinal',
        resume: true,
      );
      expect(await pair.next(), isA<FileResumeState>());
      await pair.signal(resumed, FileCancel(transferId: _id));
      expect(await pair.next(), isA<FileCancelled>());
    },
  );

  test('cancelling a held resume never reopens its native file', () async {
    final original = await pair.offer();
    await pair.next();
    pair.disk.appendGate = Completer<void>();
    await pair.chunk(original, [1, 2, 3]);
    await pair.disk.appendEntered.future;
    final pausing = pair.channel.suspendTransport();
    await recoverGrant();
    final resuming = pair.channel.resumeTransport();
    final fresh = await pair.offer(session: 'cancel-held', resume: true);
    await pair.signal(fresh, FileCancel(transferId: _id));
    pair.disk.appendGate!.complete();
    await pausing;
    await resuming;
    expect(await pair.next(), isA<FileCancelled>());
    await pair.channel.whenIdle;
    expect(pair.disk.resumes, 0);
    expect(pair.disk.commits, 0);
    expect(pair.channel.received.single.canCancel, isFalse);
    await pair.offer(session: 'after-held-cancel', resume: true);
    expect(await pair.next(), isA<FileRejected>());
  });

  test(
    'stale pause clock callback cannot cancel a transport-paused file',
    () async {
      final original = await pair.offer();
      await pair.next();
      final authority = pair.wire.resolver!(original.sessionId)!;
      final signal = await pair.receiver.openSignal(
        authority,
        await pair.sender.sealSignal(
          original,
          FileCodec.encode(FilePause(transferId: _id)),
        ),
      );
      pair.acceptClockGate = Completer<void>();
      pair.wire.onSignal!(signal);
      await pair.acceptClockEntered.future;
      final pausing = pair.channel.suspendTransport();
      await recoverGrant();
      pair.acceptClockGate!.complete();
      await pausing;
      await pair.channel.whenIdle;
      expect(pair.channel.received.single.failure, isNull);
      expect(pair.disk.stops, isNot(contains(ReceiveStopMode.cancel)));
      await pair.channel.resumeTransport();
      await pair.offer(session: 'after-stale-pause', resume: true);
      expect(await pair.next(), isA<FileResumeState>());
    },
  );

  test(
    'held cancellation remains terminal across another physical loss',
    () async {
      final original = await pair.offer();
      await pair.next();
      pair.disk.appendGate = Completer<void>();
      await pair.chunk(original, [1, 2, 3]);
      await pair.disk.appendEntered.future;
      final pausing = pair.channel.suspendTransport();
      await recoverGrant();
      final fresh = await pair.offer(
        session: 'cancel-before-next-loss',
        resume: true,
      );
      await pair.signal(fresh, FileCancel(transferId: _id));
      final secondPause = pair.channel.suspendTransport();
      await recoverGrant();
      pair.disk.appendGate!.complete();
      await pausing;
      await secondPause;
      await pair.channel.resumeTransport();
      await pair.offer(session: 'after-lost-cancel', resume: true);
      expect(await pair.next(), isA<FileRejected>());
      expect(pair.disk.resumes, 0);
    },
  );

  test(
    'automatically accepts, writes exact bytes and returns actual receipt',
    () async {
      final request = await pair.offer();
      expect(await pair.next(), isA<FileAccept>());
      await pair.chunk(request, [1, 2, 3]);
      expect((await pair.next() as FileAck).nextOffset, 3);
      expect(pair.disk.commits, 0);
      await pair.signal(
        request,
        FileFinish(transferId: _id, size: 3, sha256: _hash),
      );
      expect((await pair.next() as FileComplete).actualName, 'sample (1).bin');
      expect(
        pair.channel.received.single.task!.phase,
        IncomingFilePhase.completed,
      );
      expect(pair.disk.bytes.values.single, [1, 2, 3]);
      expect(pair.disk.commits, 1);
    },
  );

  test(
    'cancel bypasses blocked append and no ACK or later append escapes',
    () async {
      final request = await pair.offer();
      await pair.next();
      pair.disk.appendGate = Completer<void>();
      await pair.chunk(request, [1, 2, 3]);
      await pair.disk.appendEntered.future;
      await pair.signal(request, FileCancel(transferId: _id));
      expect(await pair.next(), isA<FileCancelled>());
      expect(pair.disk.stops, contains(ReceiveStopMode.cancel));
      pair.disk.appendGate!.complete();
      await pair.channel.whenIdle;
      await pair.chunk(request, [1, 2, 3]);
      await pair.channel.whenIdle;
      expect(pair.disk.appends, 1);
      expect(pair.replies, isEmpty);
      expect(pair.disk.commits, 0);
    },
  );

  test('cancel while directory lookup is pending never opens a file', () async {
    pair.directoryGate = Completer<void>();
    final request = await pair.offer();
    await pair.directoryEntered.future;
    await pair.signal(request, FileCancel(transferId: _id));
    expect(await pair.next(), isA<FileCancelled>());
    pair.directoryGate!.complete();
    await pair.channel.whenIdle;
    expect(pair.disk.begins, 0);
    expect(pair.replies, isEmpty);
  });

  test('failed directory remains visible and never falls back', () async {
    pair.failDirectory = true;
    await pair.offer();
    expect((await pair.next() as FileFailed).code, 'permission_denied');
    expect(pair.channel.received.single.failure, 'permission_denied');
    expect(pair.directoryCalls, 1);
    expect(pair.disk.begins, 0);
  });

  test('native disk-full callback reaches the peer without a receipt', () async {
    await pair.close();
    pair = await _Pair.create(access: MethodChannelReceiveAccess());
    const channel = MethodChannel('dev.sharehub.client/platform');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'files.receive.scopeOpen' => 'native-scope',
        'files.receive.begin' => throw PlatformException(code: 'disk_full'),
        'files.receive.scopeStop' => 'cancelled',
        _ => null,
      };
    });
    try {
      await pair.offer();
      expect((await pair.next() as FileFailed).code, 'disk_full');
      await pair.channel.whenIdle;
      expect(pair.channel.received.single.failure, 'disk_full');
      expect(pair.channel.received.single.task?.receipt, isNull);
    } finally {
      await pair.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test(
    'duplicate transfer and reused operation ID cannot allocate again',
    () async {
      await pair.offer();
      await pair.next();
      await pair.offer(session: 'other');
      expect(await pair.next(), isA<FileRejected>());
      await pair.offer(id: 'b' * 32);
      await pair.channel.whenIdle;
      expect(pair.channel.received, hasLength(1));
      expect(pair.disk.begins, 1);
    },
  );

  test(
    'close during native begin owns late file and detaches routing',
    () async {
      pair.disk.beginGate = Completer<void>();
      await pair.offer();
      await pair.disk.beginEntered.future;
      final closing = pair.channel.close();
      expect(pair.wire.resolver, isNull);
      expect(pair.disk.stops, contains(ReceiveStopMode.cancel));
      pair.disk.beginGate!.complete();
      await closing;
      expect(pair.disk.releases, 1);
      expect(pair.replies, isEmpty);
    },
  );

  test(
    'completed receipt survives cancel and is never published twice',
    () async {
      final request = await pair.offer();
      await pair.next();
      await pair.chunk(request, [1, 2, 3]);
      await pair.next();
      await pair.signal(
        request,
        FileFinish(transferId: _id, size: 3, sha256: _hash),
      );
      await pair.next();
      await pair.signal(request, FileCancel(transferId: _id));
      expect(await pair.next(), isA<FileComplete>());
      expect(pair.disk.commits, 1);
      expect(pair.disk.aborts, 0);
    },
  );

  test(
    'retained incoming task resumes with a new resolver and exact prefix',
    () async {
      final request = await pair.offer();
      await pair.next();
      await pair.chunk(request, [1, 2, 3]);
      await pair.next();
      await pair.signal(request, FilePause(transferId: _id));
      expect((await pair.next() as FilePaused).offset, 3);
      final resumed = await pair.offer(session: 'resume', resume: true);
      final state = await pair.next() as FileResumeState;
      expect(state.offset, 3);
      expect(pair.wire.resolver!(pair.operationIds['initial']!), isNull);
      expect(pair.wire.resolver!(pair.operationIds['resume']!), isNotNull);
      await pair.signal(
        resumed,
        FileResumeAccept(
          transferId: _id,
          attemptId: 'c' * 32,
          offset: 3,
          prefixSha256: _hash,
        ),
      );
      await pair.channel.whenIdle;
      await pair.signal(
        resumed,
        FileFinish(transferId: _id, size: 3, sha256: _hash),
      );
      expect(await pair.next(), isA<FileComplete>());
      expect(pair.disk.begins, 1);
      expect(pair.disk.resumes, 1);
    },
  );

  test('resume cannot replace an active operation resolver', () async {
    final request = await pair.offer();
    await pair.next();
    final original = pair.wire.resolver!(pair.operationIds['initial']!);
    await pair.offer(session: 'resume', resume: true);
    expect(await pair.next(), isA<FileRejected>());
    expect(pair.wire.resolver!(pair.operationIds['initial']!), same(original));
    expect(pair.wire.resolver!(pair.operationIds['resume']!), isNull);
    expect(pair.channel.received.single.failure, isNull);
    await pair.chunk(request, [1, 2, 3]);
    expect(await pair.next(), isA<FileAck>());
  });

  test(
    'cancel after commit still permits recovery of the actual receipt',
    () async {
      final request = await pair.offer();
      await pair.next();
      await pair.chunk(request, [1, 2, 3]);
      await pair.next();
      await pair.signal(
        request,
        FileFinish(transferId: _id, size: 3, sha256: _hash),
      );
      await pair.next();
      await pair.signal(request, FileCancel(transferId: _id));
      await pair.next();
      await pair.offer(session: 'resume', resume: true);
      expect(await pair.next(), isA<FileComplete>());
      expect(pair.disk.commits, 1);
      expect(pair.disk.begins, 1);
    },
  );

  test(
    'pause before file ownership never promises a recoverable prefix',
    () async {
      pair.directoryGate = Completer<void>();
      final request = await pair.offer();
      await pair.directoryEntered.future;
      await pair.signal(request, FilePause(transferId: _id));
      expect(await pair.next(), isA<FileCancelled>());
      pair.directoryGate!.complete();
      await pair.channel.whenIdle;
      expect(pair.disk.begins, 0);
    },
  );

  test(
    'bounded retained records reject overflow before directory access',
    () async {
      for (var i = 0; i < FileTransferChannel.maxTransfers; i++) {
        await pair.offer(
          session: 'file-$i',
          id: i.toRadixString(16).padLeft(32, '0'),
        );
        expect(await pair.next(), isA<FileAccept>());
      }
      await pair.offer(session: 'overflow', id: 'f' * 32);
      expect((await pair.next() as FileRejected).code, 'resource_limit');
      expect(pair.directoryCalls, FileTransferChannel.maxTransfers);
      expect(pair.disk.begins, FileTransferChannel.maxTransfers);
    },
  );

  test(
    'data overflow stops native work and emits one bounded failure',
    () async {
      final request = await pair.offer();
      await pair.next();
      pair.disk.appendGate = Completer<void>();
      await pair.chunk(request, [1]);
      await pair.disk.appendEntered.future;
      for (var i = 0; i < 8; i++) {
        await pair.chunk(request, [1]);
      }
      expect((await pair.next() as FileFailed).code, 'resource_limit');
      expect(pair.disk.stops, contains(ReceiveStopMode.cancel));
      pair.disk.appendGate!.complete();
      await pair.channel.whenIdle;
      expect(pair.disk.appends, 1);
      expect(pair.replies, isEmpty);
    },
  );

  test(
    'both channels transfer opposite files with the same transfer ID',
    () async {
      final reverse = pair.reverse = _ReverseTransport(pair);
      final leftDisk = _Disk();
      final left = FileTransferChannel(
        registry: GrantRegistry()..register(pair.sender),
        transport: reverse,
        access: leftDisk,
        directory: () async =>
            const ReceiveDirectory(token: 'left', label: 'Downloads'),
      );
      addTearDown(left.close);
      final a = _Source(
        Uint8List.fromList(List.generate(70000, (i) => i % 251)),
      );
      final b = _Source(Uint8List.fromList([8, 7, 6]));
      Future<OutgoingFileTransfer> outgoing(
        FileTransferChannel channel,
        GrantEndpoint endpoint,
        _Source source,
        String session,
      ) async {
        final request = await endpoint.authorizeLocal(
          SessionOperation.file,
          FileOperationId(
            sender: endpoint.role,
            ordinal: 1,
            attempt: 1,
          ).encoded,
          FileCodec.encode(
            FileOffer(
              transferOrdinal: 1,
              transferId: _id,
              name: 'sample.bin',
              size: source.bytes.length,
              sha256: hashes.sha256.convert(source.bytes).toString(),
              chunkBytes: FileLimits.chunkBytes,
            ),
          ),
        );
        final task = OutgoingFileTransfer(
          transport: channel.transport,
          source: VerifiedFileSource(
            access: source,
            file: SelectedFile(
              token: session,
              name: 'sample.bin',
              size: source.bytes.length,
            ),
            context: await FileTransferContext.fromRequest(
              channel.registry,
              request,
            ),
          ),
        );
        channel.trackOutgoing(task);
        return task;
      }

      final sendA = await outgoing(left, pair.sender, a, 'send-left');
      final sendB = await outgoing(
        pair.channel,
        pair.receiver,
        b,
        'send-right',
      );
      final results = await Future.wait([sendA.start(), sendB.start()]);
      expect(results.map((r) => r.size), [70000, 3]);
      expect(pair.disk.bytes.values.single, a.bytes);
      expect(leftDisk.bytes.values.single, b.bytes);
      expect(sendA.acknowledgedOffset, 70000);
      expect(sendB.acknowledgedOffset, 3);
      expect(a.sendReads, 3);
      expect(pair.disk.commits, 1);
      expect(leftDisk.commits, 1);
    },
  );

  test('pause offset is checked before stopping a valid receiver', () async {
    final request = await pair.offer();
    await pair.next();
    await pair.signal(request, FilePaused(transferId: _id, offset: 4));
    expect((await pair.next() as FileFailed).code, 'invalid_range');
    expect(
      pair.channel.received.single.task!.phase,
      isNot(IncomingFilePhase.paused),
    );
  });

  test(
    'local cancellation stops native I/O synchronously and notifies the peer',
    () async {
      final request = await pair.offer();
      await pair.next();
      pair.disk.appendGate = Completer<void>();
      await pair.chunk(request, [1, 2, 3]);
      await pair.disk.appendEntered.future;
      final cancelling = pair.channel.cancelReceived(
        pair.channel.received.single,
      );
      expect(pair.disk.stops, contains(ReceiveStopMode.cancel));
      expect(pair.leaseReleases, 0);
      await cancelling;
      expect(await pair.next(), isA<FileCancel>());
      pair.disk.appendGate!.complete();
      await pair.channel.whenIdle;
      expect(pair.leaseReleases, 1);
      expect(pair.disk.releases, 1);
      expect(pair.replies, isEmpty);
    },
  );

  test('late directory lease after cancellation is released without creating a file', () async {
    pair.directoryGate = Completer<void>();
    await pair.offer();
    await pair.directoryEntered.future;
    await pair.channel.cancelReceived(pair.channel.received.single);
    expect(await pair.next(), isA<FileCancel>());
    pair.directoryGate!.complete();
    await pair.channel.whenIdle;
    expect(pair.disk.begins, 0);
    expect(pair.leaseReleases, 1);
  });

  test(
    'completion releases directory use and keeps receipt replayable',
    () async {
      final request = await pair.offer();
      await pair.next();
      await pair.chunk(request, [1, 2, 3]);
      await pair.next();
      await pair.signal(
        request,
        FileFinish(transferId: _id, size: 3, sha256: _hash),
      );
      await pair.next();
      await pair.channel.whenIdle;
      expect(pair.leaseReleases, 1);
      expect(pair.disk.releases, 1);
      await pair.offer(session: 'resume', resume: true);
      expect(await pair.next(), isA<FileComplete>());
      await pair.channel.whenIdle;
      expect(pair.directoryCalls, 1);
      expect(pair.disk.commits, 1);
      expect(pair.leaseReleases, 1);
    },
  );

  test(
    'failed directory release stays visible and cleanup can retry it',
    () async {
      await pair.offer();
      await pair.next();
      pair.failLeaseRelease = true;
      final entry = pair.channel.received.single;
      await pair.channel.cancelReceived(entry);
      await pair.channel.whenIdle;
      expect(entry.cleanupFailure, isNotNull);
      expect(pair.leaseReleases, 0);
      pair.failLeaseRelease = false;
      await pair.channel.retryCleanup(entry);
      expect(entry.cleanupFailure, isNull);
      expect(pair.leaseReleases, 1);
    },
  );

  test('burst acceptance replies use one transport write at a time', () async {
    pair.wire.sendGate = Completer<void>();
    await pair.offer();
    await pair.next();
    for (var i = 0; i < 12; i++) {
      await pair.offer(
        session: 'burst-$i',
        id: i.toRadixString(16).padLeft(32, '0'),
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(pair.wire.maxSending, 1);
    pair.wire.sendGate!.complete();
    await pair.channel.whenIdle;
    expect(pair.replies, hasLength(12));
    expect(pair.replies, everyElement(isA<FileAccept>()));
  });

  test(
    'close completes native cleanup without waiting for a stuck reply write',
    () async {
      pair.wire.sendGate = Completer<void>();
      await pair.offer();
      await pair.next();
      await pair.channel.close().timeout(const Duration(seconds: 2));
      expect(pair.disk.releases, 1);
      pair.wire.sendGate!.complete();
    },
  );

  test(
    'cancel during acceptance clock check suppresses the late acceptance',
    () async {
      pair.acceptClockGate = Completer<void>();
      final request = await pair.offer();
      await pair.acceptClockEntered.future;
      await pair.signal(request, FileCancel(transferId: _id));
      expect(await pair.next(), isA<FileCancelled>());
      pair.acceptClockGate!.complete();
      await pair.channel.whenIdle;
      expect(pair.replies, isEmpty);
    },
  );

  test(
    'real TCP file port transfers while a separate media request is routed',
    () async {
      final accepted = Completer<TrustedConnection>();
      final host = PairingHost(
        identity: await DeviceIdentity.fromSeed(List.filled(32, 91)),
        clock: () async => 100,
        protocolVersion: 2,
        onConnection: accepted.complete,
      );
      await host.open(address: InternetAddress.loopbackIPv4);
      final a = await PairingAttempt(
        identity: await DeviceIdentity.fromSeed(List.filled(32, 92)),
        clock: () async => 100,
        protocolVersion: 2,
      ).connect('127.0.0.1', host.port!, host.offer!.code);
      final b = await accepted.future;
      final aDisk = _Disk(), bDisk = _Disk();
      final left = FileTransferChannel(
        registry: GrantRegistry()..register(a.grant!),
        transport: a.operationTransport({SessionOperation.file}),
        access: aDisk,
        directory: () async =>
            const ReceiveDirectory(token: 'a', label: 'Downloads'),
      );
      final right = FileTransferChannel(
        registry: GrantRegistry()..register(b.grant!),
        transport: b.operationTransport({SessionOperation.file}),
        access: bDisk,
        directory: () async =>
            const ReceiveDirectory(token: 'b', label: 'Downloads'),
      );
      addTearDown(() async {
        await Future.wait([left.close(), right.close()]);
        a.close();
        b.close();
        await host.close();
      });
      final mediaReceived = Completer<VerifiedSessionMessage>();
      final mediaA = a.operationTransport({
        SessionOperation.watch,
        SessionOperation.cast,
      });
      mediaA.attachReceiver(
        onRequest: (_) => fail('unexpected reverse media request'),
        resolveSession: (_) => null,
        onSignal: (_) {},
      );
      b
          .operationTransport({SessionOperation.watch, SessionOperation.cast})
          .attachReceiver(
            onRequest: mediaReceived.complete,
            resolveSession: (_) => null,
            onSignal: (_) {},
          );
      final bytes = Uint8List.fromList(List.generate(70000, (i) => i % 251));
      final local = await left.transport.createRequest(
        SessionOperation.file,
        FileOperationId(sender: a.grant!.role, ordinal: 1, attempt: 1).encoded,
        FileCodec.encode(
          FileOffer(
            transferOrdinal: 1,
            transferId: _id,
            name: 'sample.bin',
            size: bytes.length,
            sha256: hashes.sha256.convert(bytes).toString(),
            chunkBytes: FileLimits.chunkBytes,
          ),
        ),
      );
      final sender = OutgoingFileTransfer(
        transport: left.transport,
        source: VerifiedFileSource(
          access: _Source(bytes),
          file: SelectedFile(
            token: 'picked',
            name: 'sample.bin',
            size: bytes.length,
          ),
          context: await FileTransferContext.fromRequest(left.registry, local),
        ),
      );
      left.trackOutgoing(sender);
      final transferred = sender.start();
      await mediaA.sendRequest(
        await mediaA.createRequest(SessionOperation.watch, 'media', 'picture'),
      );
      expect(
        (await mediaReceived.future.timeout(const Duration(seconds: 5))).body,
        'picture',
      );
      final receipt = await transferred.timeout(const Duration(seconds: 10));
      expect(receipt.actualName, 'sample (1).bin');
      expect(receipt.sha256, hashes.sha256.convert(bytes).toString());
      expect(bDisk.bytes.values.single, bytes);
      expect(bDisk.commits, 1);
      expect(right.received, hasLength(1));
      expect(a.isClosed, isFalse);
      expect(b.isClosed, isFalse);
      await left.forgetOutgoing(sender);
      await left.whenIdle;
      for (var ordinal = 2; ordinal <= 521; ordinal++) {
        final request = await left.transport.createRequest(
          SessionOperation.file,
          FileOperationId(
            sender: a.grant!.role,
            ordinal: ordinal,
            attempt: 1,
          ).encoded,
          FileCodec.encode(
            FileOffer(
              transferId: ordinal.toRadixString(16).padLeft(32, '0'),
              transferOrdinal: ordinal,
              name: 'sample.bin',
              size: 3,
              sha256: _hash,
              chunkBytes: FileLimits.chunkBytes,
            ),
          ),
        );
        final task = OutgoingFileTransfer(
          transport: left.transport,
          source: VerifiedFileSource(
            access: _Source(Uint8List.fromList([1, 2, 3])),
            file: SelectedFile(
              token: 'picked-$ordinal',
              name: 'sample.bin',
              size: 3,
            ),
            context: await FileTransferContext.fromRequest(
              left.registry,
              request,
            ),
          ),
        );
        left.trackOutgoing(task);
        await task.start();
        final retirement = left.retireOutgoing(task);
        await left.whenIdle;
        expect(retirement.retired, isTrue);
        expect(left.outgoing, isEmpty);
        expect(right.received, isEmpty);
        expect(left.sendHistory.length, lessThanOrEqualTo(64));
        expect(right.receiveHistory.length, lessThanOrEqualTo(64));
      }
      expect(bDisk.commits, 521);
      expect(left.sendHistory.first.transferOrdinal, 458);
      expect(right.receiveHistory.last.transferOrdinal, 521);
      expect(
        () => left.trackOutgoing(sender),
        throwsA(isA<FileProtocolFailure>()),
      );
    },
  );
}

const _id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final _hash = hashes.sha256.convert([1, 2, 3]).toString();

class _Pair {
  late GrantEndpoint sender, receiver;
  late _Transport wire;
  late FileTransferChannel channel;
  _ReverseTransport? reverse;
  final disk = _Disk();
  final locals = <String, LocalSessionRequest>{};
  final operationIds = <String, String>{};
  final operationAttempts = <int, int>{};
  final ordinals = <String, int>{};
  int lastOrdinal = 0;
  int retirementRequests = 0;
  final replies = <FileMessage>[];
  Completer<void>? replyReady, directoryGate;
  Completer<void>? acceptClockGate;
  final acceptClockEntered = Completer<void>();
  bool acceptClockUsed = false;
  Completer<void>? nextClockGate;
  final nextClockEntered = Completer<void>();
  bool nextClockUsed = false;
  final directoryEntered = Completer<void>();
  bool failDirectory = false;
  bool failLeaseRelease = false;
  int leaseReleases = 0;
  int directoryCalls = 0;

  static Future<_Pair> create({ReceiveAccess? access}) async {
    final pair = _Pair();
    final binding = GrantBinding(
      id: List.filled(32, 1),
      initiatorKey: List.filled(32, 2),
      receiverKey: List.filled(32, 3),
    );
    GrantEndpoint endpoint(GrantRole role) =>
        GrantEndpoint.fromAuthenticatedPairing(
          binding: binding,
          role: role,
          establishedMicros: 100,
          recoverySecret: List.filled(32, 4),
          clock: () async {
            if (role == GrantRole.receiver &&
                pair.nextClockGate != null &&
                !pair.nextClockUsed) {
              pair.nextClockUsed = true;
              pair.nextClockEntered.complete();
              await pair.nextClockGate!.future;
            }
            if (role == GrantRole.receiver &&
                pair.acceptClockGate != null &&
                !pair.acceptClockUsed &&
                pair.channel.received.firstOrNull?.task?.phase ==
                    IncomingFilePhase.receiving) {
              pair.acceptClockUsed = true;
              pair.acceptClockEntered.complete();
              await pair.acceptClockGate!.future;
            }
            return 100;
          },
          onInvalidated: () {},
        );
    pair.sender = endpoint(GrantRole.initiator);
    pair.receiver = endpoint(GrantRole.receiver);
    await pair.receiver.acceptResume(
      await pair.sender.finishResume(
        await pair.receiver.answerResume(await pair.sender.beginResume()),
      ),
    );
    pair.wire = _Transport(pair);
    pair.channel = FileTransferChannel(
      registry: GrantRegistry()..register(pair.receiver),
      transport: pair.wire,
      access: access ?? pair.disk,
      acquireDirectory: () async {
        pair.directoryCalls++;
        if (!pair.directoryEntered.isCompleted) {
          pair.directoryEntered.complete();
        }
        if (pair.directoryGate != null) await pair.directoryGate!.future;
        if (pair.failDirectory) {
          throw const ReceiveAccessFailure('permission_denied');
        }
        return ReceiveDirectoryLease(
          const ReceiveDirectory(token: 'directory', label: 'Downloads'),
          () async {
            if (pair.failLeaseRelease) {
              throw StateError('directory release failed');
            }
            pair.leaseReleases++;
          },
        );
      },
    );
    return pair;
  }

  Future<LocalSessionRequest> offer({
    String session = 'initial',
    String? operationId,
    String id = _id,
    bool resume = false,
    String name = 'sample.bin',
    int? ordinal,
  }) async {
    ordinal ??= ordinals.putIfAbsent(id, () => ++lastOrdinal);
    final FileMessage message = resume
        ? FileResume(
            transferOrdinal: ordinal,
            transferId: id,
            name: name,
            size: 3,
            sha256: _hash,
            chunkBytes: FileLimits.chunkBytes,
            attemptId: 'c' * 32,
          )
        : FileOffer(
            transferOrdinal: ordinal,
            transferId: id,
            name: name,
            size: 3,
            sha256: _hash,
            chunkBytes: FileLimits.chunkBytes,
          );
    final local = await sender.authorizeLocal(
      SessionOperation.file,
      operationId ??
          operationIds.putIfAbsent(
            session,
            () => FileOperationId(
              sender: sender.role,
              ordinal: ordinal!,
              attempt: operationAttempts.update(
                ordinal,
                (n) => n + 1,
                ifAbsent: () => 1,
              ),
            ).encoded,
          ),
      FileCodec.encode(message),
    );
    locals[local.sessionId] = local;
    wire.onRequest!(await receiver.open(await sender.sealRequest(local)));
    return local;
  }

  Future<void> terminate({
    String session = 'terminate',
    String id = _id,
    GrantRole sender = GrantRole.initiator,
    int size = 3,
    int? ordinal,
  }) async {
    ordinal ??= ordinals.putIfAbsent(id, () => ++lastOrdinal);
    final local = await this.sender.authorizeLocal(
      SessionOperation.file,
      session,
      FileCodec.encode(
        FileTerminate(
          transferOrdinal: ordinal,
          transferId: id,
          transferSender: sender,
          name: 'sample.bin',
          size: size,
          sha256: _hash,
          chunkBytes: FileLimits.chunkBytes,
        ),
      ),
    );
    locals[session] = local;
    wire.onRequest!(await receiver.open(await this.sender.sealRequest(local)));
  }

  Future<void> retire({
    String id = _id,
    String name = 'sample.bin',
    String? session,
    GrantRole? transferSender,
    int ordinal = 1,
    FileRetirementOutcome outcome = FileRetirementOutcome.cancelled,
    String? actualName,
    String? failureCode,
  }) async {
    final local = await sender.authorizeLocal(
      SessionOperation.file,
      session ??
          'file-retire-${(++retirementRequests).toRadixString(16).padLeft(32, '0')}',
      FileCodec.encode(
        FileRetire(
          transferId: id,
          transferOrdinal: ordinal,
          transferSender: transferSender ?? sender.role,
          name: name,
          size: 3,
          sha256: _hash,
          chunkBytes: FileLimits.chunkBytes,
          outcome: outcome,
          actualName: actualName,
          failureCode: failureCode,
        ),
      ),
    );
    locals[local.sessionId] = local;
    wire.onRequest!(await receiver.open(await sender.sealRequest(local)));
  }

  Future<void> chunk(LocalSessionRequest request, List<int> bytes) =>
      signal(request, FileChunk(transferId: _id, offset: 0, data: bytes));
  Future<void> signal(LocalSessionRequest request, FileMessage message) async {
    final authority = wire.resolver!(request.sessionId);
    if (authority == null) return;
    wire.onSignal!(
      await receiver.openSignal(
        authority,
        await sender.sealSignal(request, FileCodec.encode(message)),
      ),
    );
  }

  Future<FileMessage> next() async {
    while (replies.isEmpty) {
      replyReady = Completer<void>();
      await replyReady!.future.timeout(const Duration(seconds: 3));
    }
    return replies.removeAt(0);
  }

  Future<void> close() async {
    failLeaseRelease = false;
    for (final gate in [
      directoryGate,
      disk.beginGate,
      disk.appendGate,
      disk.resumeGate,
      disk.closeGate,
      acceptClockGate,
      nextClockGate,
      wire.sendGate,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    await channel.close();
    sender.revoke();
    receiver.revoke();
  }
}

class _Transport implements SessionTransport {
  _Transport(this.pair);
  final _Pair pair;
  void Function(VerifiedSessionMessage)? onRequest;
  void Function(VerifiedSessionSignal)? onSignal;
  SessionAuthorization? Function(String)? resolver;
  Completer<void>? sendGate;
  Completer<void>? requestReturnGate;
  final sendEntered = Completer<void>();
  int sending = 0, maxSending = 0;
  @override
  Future<LocalSessionRequest> createRequest(
    SessionOperation operation,
    String sessionId,
    String body,
  ) => pair.receiver.authorizeLocal(operation, sessionId, body);
  @override
  void attachReceiver({
    required void Function(VerifiedSessionMessage) onRequest,
    required SessionAuthorization? Function(String) resolveSession,
    required void Function(VerifiedSessionSignal) onSignal,
  }) {
    this.onRequest = onRequest;
    this.onSignal = onSignal;
    resolver = resolveSession;
  }

  @override
  void detachReceiver() {
    onRequest = null;
    onSignal = null;
    resolver = null;
  }

  @override
  Future<void> sendSignal(
    SessionAuthorization authorization,
    String body,
  ) async {
    sending++;
    if (sending > maxSending) maxSending = sending;
    try {
      await _send(authorization, body);
      if (sendGate != null) {
        if (!sendEntered.isCompleted) sendEntered.complete();
        await sendGate!.future;
      }
    } finally {
      sending--;
    }
  }

  Future<void> _send(SessionAuthorization authorization, String body) async {
    final reverse = pair.reverse;
    if (reverse != null) {
      final target = reverse.resolver!(authorization.sessionId)!;
      reverse.onSignal!(
        await pair.sender.openSignal(
          target,
          await pair.receiver.sealSignal(authorization, body),
        ),
      );
      return;
    }
    final decoded = await pair.sender.openSignal(
      pair.locals[authorization.sessionId]!,
      await pair.receiver.sealSignal(authorization, body),
    );
    pair.replies.add(FileCodec.decode(decoded.body));
    if (pair.replyReady case final ready? when !ready.isCompleted) {
      ready.complete();
    }
  }

  @override
  Future<void> sendRequest(LocalSessionRequest request) async {
    pair.reverse!.onRequest!(
      await pair.sender.open(await pair.receiver.sealRequest(request)),
    );
    final gate = requestReturnGate;
    requestReturnGate = null;
    if (gate != null) await gate.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _ReverseTransport implements SessionTransport {
  _ReverseTransport(this.pair);
  final _Pair pair;
  bool cancelFirstComplete = false, dropNextRetired = false;
  void Function(VerifiedSessionMessage)? onRequest;
  void Function(VerifiedSessionSignal)? onSignal;
  SessionAuthorization? Function(String)? resolver;
  @override
  void attachReceiver({
    required void Function(VerifiedSessionMessage) onRequest,
    required SessionAuthorization? Function(String) resolveSession,
    required void Function(VerifiedSessionSignal) onSignal,
  }) {
    this.onRequest = onRequest;
    this.onSignal = onSignal;
    resolver = resolveSession;
  }

  @override
  void detachReceiver() {
    onRequest = null;
    onSignal = null;
    resolver = null;
  }

  @override
  Future<void> sendSignal(
    SessionAuthorization authorization,
    String body,
  ) async {
    final message = FileCodec.decode(body);
    if (dropNextRetired && message is FileRetired) {
      dropNextRetired = false;
      return;
    }
    if (cancelFirstComplete && message is FileComplete) {
      cancelFirstComplete = false;
      body = FileCodec.encode(FileCancelled(transferId: message.transferId));
    }
    final target = pair.wire.resolver!(authorization.sessionId)!;
    pair.wire.onSignal!(
      await pair.receiver.openSignal(
        target,
        await pair.sender.sealSignal(authorization, body),
      ),
    );
  }

  @override
  Future<void> sendRequest(LocalSessionRequest request) async {
    pair.wire.onRequest!(
      await pair.receiver.open(await pair.sender.sealRequest(request)),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Source implements SourceAccess {
  _Source(this.bytes);
  final Uint8List bytes;
  int passes = 0, sendReads = 0;
  bool failClose = false;
  @override
  Future<SourceScope> openScope({
    required String fileToken,
    required String key,
    required int deadlineMicros,
  }) async => SourceScope(
    token: key,
    fileToken: fileToken,
    key: key,
    deadlineMicros: deadlineMicros,
  );
  @override
  Future<SourceStopState> stopScope(
    SourceScope scope,
    SourceStopMode mode,
  ) async => mode == SourceStopMode.pause
      ? SourceStopState.paused
      : SourceStopState.cancelled;
  @override
  Future<void> closeScope(SourceScope scope) async {
    if (failClose) throw StateError('source close failed');
  }

  @override
  Future<SourceReadPass> beginPass(SourceScope scope) async =>
      SourceReadPass(id: '${++passes}', scope: scope);
  @override
  Future<Uint8List> readPass(
    SourceReadPass pass,
    int offset,
    int length,
  ) async {
    if (passes.isEven) sendReads++;
    return Uint8List.fromList(bytes.sublist(offset, offset + length));
  }

  @override
  Future<void> finishPass(SourceReadPass pass) async {}
}

class _Disk implements ReceiveAccess {
  final bytes = <String, List<int>>{};
  final stops = <ReceiveStopMode>[];
  final cancelledScopes = <String>[], resumedScopes = <String>[];
  int scopeOpens = 0;
  int begins = 0,
      appends = 0,
      commits = 0,
      releases = 0,
      aborts = 0,
      resumes = 0;
  Completer<void>? beginGate, appendGate, resumeGate, closeGate;
  final closeEntered = Completer<void>();
  final resumeEntered = Completer<void>();
  final beginEntered = Completer<void>(), appendEntered = Completer<void>();
  @override
  Future<ReceiveScope> openScope({
    required String key,
    required int deadlineMicros,
  }) async => ReceiveScope(
    token: 'scope-${++scopeOpens}',
    key: key,
    deadlineMicros: deadlineMicros,
  );
  @override
  Future<ReceiveStopState> stopScope(
    ReceiveScope scope,
    ReceiveStopMode mode,
  ) async {
    stops.add(mode);
    if (mode == ReceiveStopMode.cancel) cancelledScopes.add(scope.token);
    return mode == ReceiveStopMode.cancel
        ? ReceiveStopState.cancelled
        : ReceiveStopState.paused;
  }

  @override
  Future<void> closeScope(ReceiveScope scope) async {
    if (!closeEntered.isCompleted) closeEntered.complete();
    if (closeGate != null) await closeGate!.future;
  }

  @override
  Future<ReceiveFile> begin({
    required ReceiveDirectory directory,
    required ReceiveScope scope,
    required ReceiveMetadata metadata,
  }) async {
    final token = '${++begins}';
    if (!beginEntered.isCompleted) beginEntered.complete();
    if (beginGate != null) await beginGate!.future;
    bytes[token] = [];
    return ReceiveFile(
      token: token,
      metadata: metadata,
      key: scope.key,
      deadlineMicros: scope.deadlineMicros,
    );
  }

  @override
  Future<int> append(
    ReceiveFile file,
    ReceiveScope scope,
    int offset,
    Uint8List data,
  ) async {
    appends++;
    if (!appendEntered.isCompleted) appendEntered.complete();
    if (appendGate != null) await appendGate!.future;
    expect(offset, bytes[file.token]!.length);
    bytes[file.token]!.addAll(data);
    return bytes[file.token]!.length;
  }

  @override
  Future<ReceiveReceipt> commit(ReceiveFile file, ReceiveScope scope) async {
    expect(
      hashes.sha256.convert(bytes[file.token]!).toString(),
      file.metadata.sha256,
    );
    commits++;
    return ReceiveReceipt(
      name: 'sample (1).bin',
      size: file.metadata.size,
      sha256: file.metadata.sha256,
    );
  }

  @override
  Future<ReceiveCheckpoint> checkpoint(ReceiveFile file) async =>
      ReceiveCheckpoint(
        offset: bytes[file.token]!.length,
        sha256: hashes.sha256.convert(bytes[file.token]!).toString(),
        identity: file.token,
      );
  @override
  Future<void> resume(
    ReceiveFile file,
    ReceiveScope scope,
    ReceiveCheckpoint checkpoint,
  ) async {
    resumes++;
    resumedScopes.add(scope.token);
    if (!resumeEntered.isCompleted) resumeEntered.complete();
    if (resumeGate != null) await resumeGate!.future;
  }

  @override
  Future<void> abort(ReceiveFile file) async {
    aborts++;
  }

  @override
  Future<void> retryCleanup(ReceiveFile file) async {}
  @override
  Future<void> release(ReceiveFile file) async {
    releases++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
