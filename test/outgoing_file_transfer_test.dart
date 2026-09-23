import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';
import 'package:share_hub_open/features/transfers/file_publication_order.dart';
import 'package:share_hub_open/features/transfers/incoming_file_transfer.dart';
import 'package:share_hub_open/features/transfers/outgoing_file_transfer.dart';
import 'package:share_hub_open/features/transfers/receive_access.dart';
import 'package:share_hub_open/features/transfers/source_access.dart';
import 'package:share_hub_open/features/transfers/verified_file_source.dart';

void main() {
  late _Pair pair;
  setUp(() async => pair = await _Pair.create());
  tearDown(() async => pair.close());

  for (final validReply in [true, false]) {
    test(
      validReply
          ? 'valid receiver acceptance confirms publication across recovery'
          : 'premature completion cannot confirm publication across recovery',
      () async {
        await pair.close();
        final order = FilePublicationOrder();
        addTearDown(order.close);
        pair = await _Pair.create(publication: order.reserve());
        pair.wire.prematureComplete = !validReply;
        if (validReply) {
          pair.wire.offerReturnGate = Completer<void>();
          final running = pair.outgoing.start();
          final stopped = expectLater(
            running,
            throwsA(isA<FileProtocolFailure>()),
          );
          await pair.wire.offerDelivered.future;
          expect(pair.outgoing.receipt, isNull);
          expect(pair.disk.commits, 0);
          await pair.pauseBoth();
          await stopped;
        } else {
          await expectLater(
            pair.outgoing.start(),
            throwsA(isA<FileProtocolFailure>()),
          );
        }
        order.suspend();
        order.resume();
        final next = order.reserve();
        expect(next.canPublish, validReply);
      },
    );
  }

  test(
    'physical resume publishes while the old offer write remains unresolved',
    () async {
      await pair.close();
      final order = FilePublicationOrder();
      addTearDown(order.close);
      pair = await _Pair.create(publication: order.reserve());
      pair.wire.offerReturnGate = Completer<void>();
      final first = pair.outgoing.start();
      final paused = expectLater(first, throwsA(isA<FileProtocolFailure>()));
      await pair.wire.offerDelivered.future;
      order.suspend();
      await pair.pauseBoth();
      await paused;
      final request = await pair.resumeRequest();
      order.resume();
      final resumed = pair.outgoing.resume(request);
      expect((await resumed.timeout(const Duration(seconds: 3))).size, 70000);
      expect(pair.wire.offerReturnGate!.isCompleted, isFalse);
      expect(pair.disk.commits, 1);
      expect(order.pendingCount, 0);
      pair.wire.offerReturnGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(pair.outgoing.phase, OutgoingFilePhase.completed);
    },
  );

  test(
    'prepared source waits for earlier first publication before offering',
    () async {
      await pair.close();
      final order = FilePublicationOrder();
      addTearDown(order.close);
      final earlier = order.reserve();
      final later = order.reserve();
      pair = await _Pair.create(publication: later);
      final result = pair.outgoing.start();
      await Future<void>.delayed(Duration.zero);
      expect(pair.source.finished, [1]);
      expect(pair.outgoing.phase, OutgoingFilePhase.awaitingAccept);
      expect(pair.wire.offers, 0);
      await earlier.publish(() async {});
      expect((await result).size, 70000);
      expect(pair.wire.offers, 1);
    },
  );

  test(
    'cancelling a source waiting for publication prevents a delayed offer',
    () async {
      await pair.close();
      final order = FilePublicationOrder();
      addTearDown(order.close);
      final earlier = order.reserve(), later = order.reserve();
      pair = await _Pair.create(publication: later);
      final result = pair.outgoing.start();
      final rejected = expectLater(result, throwsA(isA<FileProtocolFailure>()));
      await Future<void>.delayed(Duration.zero);
      expect(pair.source.finished, [1]);
      await pair.outgoing.cancel(notifyPeer: false);
      await rejected;
      earlier.abandon();
      await Future<void>.delayed(Duration.zero);
      expect(pair.wire.offers, 0);
      expect(pair.disk.commits, 0);
      expect(order.pendingCount, 1);
      // The controller still owes the peer an explicit terminal publication.
    },
  );

  test(
    'multiple chunks require actual receiver commit and saved name',
    () async {
      final result = await pair.outgoing.start();
      expect(result.actualName, 'sample (1).bin');
      expect(pair.disk.bytes, pair.source.bytes);
      expect(pair.source.finished, [1, 2]);
      expect(pair.wire.chunks, [32768, 32768, 4464]);
      expect(pair.outgoing.acknowledgedOffset, 70000);
      expect(pair.outgoing.phase, OutgoingFilePhase.completed);
      expect(pair.disk.commits, 1);
    },
  );

  test('slow ACK admits one chunk and no native read ahead', () async {
    pair.wire.ackGate = Completer<void>();
    final result = pair.outgoing.start();
    await pair.wire.firstChunk.future;
    expect(pair.source.sendReads, 1);
    expect(pair.outgoing.acknowledgedOffset, 0);
    expect(pair.outgoing.receipt, isNull);
    pair.wire.ackGate!.complete();
    await result;
    expect(pair.source.sendReads, 3);
  });

  test('early ACK cannot advance reads until send future completes', () async {
    pair.wire.sendGate = Completer<void>();
    final result = pair.outgoing.start();
    await pair.wire.firstAck.future;
    expect(pair.source.sendReads, 1);
    expect(pair.outgoing.acknowledgedOffset, 0);
    pair.wire.sendGate!.complete();
    await result;
    expect(pair.outgoing.acknowledgedOffset, 70000);
  });

  test('source mutation rejects before offer is sent', () async {
    pair.source.bytes[0] ^= 1;
    await expectLater(pair.outgoing.start(), throwsA(isA<FileSourceFailure>()));
    expect(pair.wire.offers, 0);
    expect(pair.source.stops, contains(SourceStopMode.cancel));
    expect(pair.outgoing.phase, OutgoingFilePhase.failed);
  });

  test('wrong ACK fails closed without another read', () async {
    pair.wire.wrongAck = true;
    await expectLater(
      pair.outgoing.start(),
      throwsA(isA<FileProtocolFailure>()),
    );
    expect(pair.source.sendReads, 1);
    expect(pair.outgoing.phase, OutgoingFilePhase.failed);
    expect(pair.source.stops, contains(SourceStopMode.cancel));
  });

  test('premature complete cannot stand in for accept', () async {
    pair.wire.prematureComplete = true;
    await expectLater(
      pair.outgoing.start(),
      throwsA(isA<FileProtocolFailure>()),
    );
    expect(pair.source.sendReads, 0);
    expect(pair.outgoing.receipt, isNull);
  });

  test('cancel stops source while data send remains blocked', () async {
    pair.wire.sendGate = Completer<void>();
    pair.wire.cancelGate = Completer<void>();
    final result = pair.outgoing.start();
    final rejected = expectLater(result, throwsA(isA<FileProtocolFailure>()));
    await pair.wire.firstAck.future;
    await pair.outgoing.cancel();
    await rejected;
    expect(pair.source.stops, contains(SourceStopMode.cancel));
    expect(pair.outgoing.phase, OutgoingFilePhase.cancelling);
    expect(pair.source.sendReads, 1);
    pair.wire.cancelGate!.complete();
    await pair.wire.cancelAnswered.future;
    expect(pair.outgoing.phase, OutgoingFilePhase.cancelled);
    pair.wire.sendGate!.complete();
  });

  test('pause intent survives grant suspension and rejects late ACK', () async {
    pair.wire.ackGate = Completer<void>();
    final result = pair.outgoing.start();
    final rejected = expectLater(result, throwsA(isA<FileProtocolFailure>()));
    await pair.wire.firstChunk.future;
    await pair.outgoing.pause(notifyPeer: false);
    pair.sender.suspend();
    await rejected;
    expect(pair.outgoing.phase, OutgoingFilePhase.paused);
    expect(pair.source.stops, [SourceStopMode.pause]);
    pair.wire.ackGate!.complete();
  });

  test(
    'native publication winning cancel remains a completed receipt',
    () async {
      pair.disk.commitGate = Completer<void>();
      pair.disk.commitWon = true;
      final result = pair.outgoing.start();
      final rejected = expectLater(result, throwsA(isA<FileProtocolFailure>()));
      await pair.disk.commitEntered.future;
      await pair.outgoing.cancel();
      await rejected;
      expect(pair.outgoing.phase, OutgoingFilePhase.cancelling);
      pair.disk.commitGate!.complete();
      await pair.wire.completed.future;
      expect(pair.outgoing.phase, OutgoingFilePhase.completed);
      expect(pair.outgoing.receipt!.actualName, 'sample (1).bin');
      expect(pair.disk.commits, 1);
      await pair.outgoing.cancel();
      expect(pair.outgoing.phase, OutgoingFilePhase.completed);
    },
  );

  test(
    'empty file still performs both passes and native publication',
    () async {
      await pair.close();
      pair = await _Pair.create(size: 0);
      await pair.outgoing.start();
      expect(pair.source.finished, [1, 2]);
      expect(pair.source.sendReads, 0);
      expect(pair.disk.commits, 1);
      expect(pair.outgoing.phase, OutgoingFilePhase.completed);
    },
  );
  test(
    'receiver negotiates smaller chunks without changing the window',
    () async {
      pair.wire.acceptedChunkBytes = 8192;
      await pair.outgoing.start();
      expect(pair.wire.chunks, [...List.filled(8, 8192), 4464]);
    },
  );
  test('cancel before start never opens a source or sends an offer', () async {
    await pair.outgoing.cancel();
    await expectLater(
      pair.outgoing.start(),
      throwsA(isA<FileProtocolFailure>()),
    );
    expect(pair.source.passes, 0);
    expect(pair.wire.offers, 0);
    expect(pair.outgoing.phase, OutgoingFilePhase.cancelled);
  });
  test('duplicate ACK before send completes fails closed', () async {
    pair.wire.duplicateAck = true;
    await expectLater(
      pair.outgoing.start(),
      throwsA(isA<FileProtocolFailure>()),
    );
    expect(pair.source.sendReads, 1);
    expect(pair.outgoing.phase, OutgoingFilePhase.failed);
  });
  test(
    'cross-operation authenticated response cannot advance this owner',
    () async {
      pair.wire.foreignAccept = true;
      await expectLater(
        pair.outgoing.start(),
        throwsA(isA<FileProtocolFailure>()),
      );
      expect(pair.source.sendReads, 0);
      expect(pair.outgoing.receipt, isNull);
    },
  );
  test(
    'second pass mutation notifies receiver failure without finish',
    () async {
      pair.wire.mutateAfterAccept = true;
      await expectLater(
        pair.outgoing.start(),
        throwsA(isA<FileSourceFailure>()),
      );
      await pair.wire.failureAnswered.future;
      expect(pair.wire.failures, ['source_changed']);
      expect(pair.disk.commits, 0);
      expect(pair.wire.incoming!.phase, IncomingFilePhase.cancelled);
    },
  );
  test(
    'cancel during native read discards bytes before network send',
    () async {
      pair.source.readGate = Completer<void>();
      final result = pair.outgoing.start();
      final rejected = expectLater(result, throwsA(isA<FileSourceFailure>()));
      await pair.source.readEntered.future;
      await pair.outgoing.cancel();
      expect(pair.source.stops, contains(SourceStopMode.cancel));
      pair.source.readGate!.complete();
      await rejected;
      expect(pair.wire.chunks, isEmpty);
      expect(pair.disk.commits, 0);
    },
  );
  test('failed cancel notification does not stall native stop', () async {
    pair.wire.sendGate = Completer<void>();
    pair.wire.failCancel = true;
    final result = pair.outgoing.start();
    final rejected = expectLater(result, throwsA(isA<FileProtocolFailure>()));
    await pair.wire.firstAck.future;
    await pair.outgoing.cancel();
    await rejected;
    await Future<void>.delayed(Duration.zero);
    expect(pair.outgoing.notificationFailure, isA<StateError>());
    expect(pair.outgoing.phase, OutgoingFilePhase.cancelling);
    pair.wire.sendGate!.complete();
  });
  test(
    'permanent revoke cancels an intentionally paused native scope',
    () async {
      pair.wire.ackGate = Completer<void>();
      final result = pair.outgoing.start();
      final rejected = expectLater(result, throwsA(isA<FileProtocolFailure>()));
      await pair.wire.firstChunk.future;
      await pair.outgoing.pause(notifyPeer: false);
      await rejected;
      pair.sender.revoke();
      await Future<void>.delayed(Duration.zero);
      expect(pair.source.stops, [SourceStopMode.pause, SourceStopMode.cancel]);
      expect(pair.outgoing.phase, OutgoingFilePhase.cancelled);
      await expectLater(
        pair.outgoing.pause(),
        throwsA(isA<FileProtocolFailure>()),
      );
      pair.wire.ackGate!.complete();
    },
  );
  test('wire failure after receiver complete preserves saved result', () async {
    pair.wire.failAfterComplete = true;
    final receipt = await pair.outgoing.start();
    expect(receipt.actualName, 'sample (1).bin');
    expect(pair.outgoing.phase, OutgoingFilePhase.completed);
  });
  test('close retries native cleanup and cannot restart the attempt', () async {
    await pair.outgoing.start();
    pair.source.failClose = true;
    await expectLater(pair.outgoing.close(), throwsStateError);
    pair.source.failClose = false;
    await pair.outgoing.close();
    expect(pair.source.closes, 2);
    expect((await pair.outgoing.start()).actualName, 'sample (1).bin');
    expect(pair.wire.offers, 1);
    expect(pair.outgoing.phase, OutgoingFilePhase.completed);
  });
  test('peer cancel preempts a pending native pause response', () async {
    pair.wire.ackGate = Completer<void>();
    pair.source.pauseGate = Completer<void>();
    final running = pair.outgoing.start();
    final rejected = expectLater(running, throwsA(isA<FileProtocolFailure>()));
    await pair.wire.firstChunk.future;
    await pair.wire.reply(
      FilePause(transferId: pair.outgoing.context.transferId),
    );
    await rejected;
    await pair.wire.reply(
      FileCancel(transferId: pair.outgoing.context.transferId),
    );
    await pair.wire.peerCancelAcknowledged.future;
    expect(pair.source.stops, [SourceStopMode.pause, SourceStopMode.cancel]);
    expect(pair.outgoing.phase, OutgoingFilePhase.cancelled);
    pair.source.pauseGate!.complete();
    pair.wire.ackGate!.complete();
  });
  test(
    'peer failure while paused is terminal and does not echo a failure',
    () async {
      pair.wire.ackGate = Completer<void>();
      final running = pair.outgoing.start();
      final rejected = expectLater(
        running,
        throwsA(isA<FileProtocolFailure>()),
      );
      await pair.wire.firstChunk.future;
      await pair.outgoing.pause(notifyPeer: false);
      await rejected;
      await pair.wire.reply(
        FileFailed(
          transferId: pair.outgoing.context.transferId,
          code: 'disk_full',
        ),
      );
      expect(pair.outgoing.phase, OutgoingFilePhase.failed);
      expect(pair.source.stops, [SourceStopMode.pause, SourceStopMode.cancel]);
      expect(pair.wire.failures, isEmpty);
      pair.wire.ackGate!.complete();
    },
  );
  test(
    'request rejection while locally paused cannot become a terminal peer fact',
    () async {
      pair.wire.ackGate = Completer<void>();
      final running = pair.outgoing.start();
      final stopped = expectLater(running, throwsA(isA<FileProtocolFailure>()));
      await pair.wire.firstChunk.future;
      await pair.outgoing.pause(notifyPeer: false);
      await stopped;
      await pair.wire.reply(
        FileRejected(
          transferId: pair.outgoing.context.transferId,
          code: 'resource_limit',
        ),
      );
      expect(pair.outgoing.phase, OutgoingFilePhase.paused);
      expect(pair.source.stops, [SourceStopMode.pause]);
      expect(pair.outgoing.receipt, isNull);
      expect(pair.wire.failures, isEmpty);
      pair.wire.ackGate!.complete();
    },
  );

  test('peer can retry cancellation after a native stop failure', () async {
    pair.wire.ackGate = Completer<void>();
    final running = pair.outgoing.start();
    final rejected = expectLater(running, throwsA(isA<FileProtocolFailure>()));
    await pair.wire.firstChunk.future;
    pair.source.failStop = true;
    await pair.wire.reply(
      FileCancel(transferId: pair.outgoing.context.transferId),
    );
    await rejected;
    await Future<void>.delayed(Duration.zero);
    expect(pair.outgoing.stopFailure, isA<StateError>());
    expect(pair.wire.peerCancelAcknowledged.isCompleted, isFalse);
    pair.source.failStop = false;
    await pair.wire.reply(
      FileCancel(transferId: pair.outgoing.context.transferId),
    );
    await pair.wire.peerCancelAcknowledged.future;
    expect(pair.outgoing.phase, OutgoingFilePhase.cancelled);
    expect(pair.outgoing.stopFailure, isNull);
    pair.wire.ackGate!.complete();
  });
  test(
    'superseded pause failure cannot replace successful cancel status',
    () async {
      pair.wire.ackGate = Completer<void>();
      pair.source.pauseGate = Completer<void>();
      final running = pair.outgoing.start();
      final rejected = expectLater(
        running,
        throwsA(isA<FileProtocolFailure>()),
      );
      await pair.wire.firstChunk.future;
      final pausing = pair.outgoing.pause(notifyPeer: false);
      final pauseRejected = expectLater(pausing, throwsStateError);
      await pair.outgoing.cancel(notifyPeer: false);
      pair.source.failPause = true;
      pair.source.pauseGate!.complete();
      await pauseRejected;
      await rejected;
      expect(pair.outgoing.stopFailure, isNull);
      pair.wire.ackGate!.complete();
    },
  );
  test(
    'lost ACK resumes verified receiver prefix under original grant',
    () async {
      pair.wire.dropAck = true;
      final running = pair.outgoing.start();
      final rejected = expectLater(
        running,
        throwsA(isA<FileProtocolFailure>()),
      );
      await pair.wire.firstChunk.future;
      await Future<void>.delayed(Duration.zero);
      expect(pair.outgoing.sentOffset, 32768);
      expect(pair.outgoing.acknowledgedOffset, 0);
      await pair.pauseBoth();
      await rejected;
      final result = await pair.outgoing.resume(await pair.resumeRequest());
      expect(result.actualName, 'sample (1).bin');
      expect(pair.disk.bytes, pair.source.bytes);
      expect(pair.wire.chunks, [32768, 32768, 4464]);
      expect(pair.disk.commits, 1);
      expect(pair.disk.resumes, 1);
      expect(
        pair.source.events,
        containsAllInOrder(['open:1', 'open:2', 'close:1']),
      );
    },
  );

  test(
    'early ACK proves resume frontier while old send is still blocked',
    () async {
      final oldSend = Completer<void>();
      pair.wire.sendGate = oldSend;
      final running = pair.outgoing.start();
      final rejected = expectLater(
        running,
        throwsA(isA<FileProtocolFailure>()),
      );
      await pair.wire.firstAck.future;
      expect(pair.outgoing.sentOffset, 0);
      await pair.pauseBoth();
      await rejected;
      pair.wire.sendGate = null;
      await pair.outgoing.resume(await pair.resumeRequest());
      expect(pair.outgoing.sentOffset, 70000);
      oldSend.complete();
      await Future<void>.delayed(Duration.zero);
      expect(pair.outgoing.sentOffset, 70000);
      expect(pair.outgoing.acknowledgedOffset, 70000);
      expect(pair.disk.commits, 1);
    },
  );

  test('resume cannot claim locally read but never emitted bytes', () async {
    pair.source.readGate = Completer<void>();
    final running = pair.outgoing.start();
    final rejected = expectLater(running, throwsA(isA<FileSourceFailure>()));
    await pair.source.readEntered.future;
    await pair.pauseBoth();
    pair.source.readGate!.complete();
    await rejected;
    pair.source.readGate = null;
    pair.wire.fakeResumeOffset = 1;
    await expectLater(
      pair.outgoing.resume(await pair.resumeRequest()),
      throwsA(isA<FileProtocolFailure>()),
    );
    expect(pair.wire.chunks, isEmpty);
    expect(pair.disk.commits, 0);
  });

  test(
    'incorrect resume prefix never sends resume-accept or more chunks',
    () async {
      pair.wire.dropAck = true;
      final running = pair.outgoing.start();
      final rejected = expectLater(
        running,
        throwsA(isA<FileProtocolFailure>()),
      );
      await pair.wire.firstChunk.future;
      await Future<void>.delayed(Duration.zero);
      await pair.pauseBoth();
      await rejected;
      pair.wire.fakeResumeHash = '0' * 64;
      await expectLater(
        pair.outgoing.resume(await pair.resumeRequest()),
        throwsA(isA<FileSourceFailure>()),
      );
      expect(pair.wire.resumeAccepts, 0);
      expect(pair.wire.chunks, [32768]);
      expect(pair.disk.commits, 0);
    },
  );

  test(
    'changed selected source fails before sending the resume request',
    () async {
      pair.wire.dropAck = true;
      final running = pair.outgoing.start();
      final rejected = expectLater(
        running,
        throwsA(isA<FileProtocolFailure>()),
      );
      await pair.wire.firstChunk.future;
      await pair.pauseBoth();
      await rejected;
      pair.source.bytes[0] ^= 1;
      await expectLater(
        pair.outgoing.resume(await pair.resumeRequest()),
        throwsA(isA<FileSourceFailure>()),
      );
      expect(pair.wire.resumes, 0);
      expect(pair.disk.commits, 0);
    },
  );

  for (final size in [0, 70000]) {
    test(
      'lost complete for $size bytes reuses actual receipt without publishing again',
      () async {
        await pair.close();
        pair = await _Pair.create(size: size);
        pair.wire.dropComplete = true;
        final running = pair.outgoing.start();
        final rejected = expectLater(
          running,
          throwsA(isA<FileProtocolFailure>()),
        );
        await pair.wire.completeDropped.future;
        expect(pair.outgoing.receipt, isNull);
        await pair.pauseBoth();
        await rejected;
        final chunkCount = pair.wire.chunks.length;
        final result = await pair.outgoing.resume(await pair.resumeRequest());
        expect(result.actualName, 'sample (1).bin');
        expect(pair.disk.commits, 1);
        expect(pair.wire.chunks.length, chunkCount);
        expect(pair.wire.resumeAccepts, 0);
        expect(pair.outgoing.phase, OutgoingFilePhase.completed);
      },
    );
  }

  test('cancel during resumed source scope opening owns late scope', () async {
    pair.wire.dropAck = true;
    final running = pair.outgoing.start();
    final rejected = expectLater(running, throwsA(isA<FileProtocolFailure>()));
    await pair.wire.firstChunk.future;
    await pair.pauseBoth();
    await rejected;
    pair.source.openGate = Completer<void>();
    final resumed = pair.outgoing.resume(await pair.resumeRequest());
    final stopped = expectLater(
      resumed,
      throwsA(
        anyOf(
          isA<SessionFailure>(),
          isA<FileProtocolFailure>(),
          isA<FileSourceFailure>(),
        ),
      ),
    );
    await pair.source.openEntered.future;
    final cancelling = pair.outgoing.cancel(notifyPeer: false);
    pair.source.openGate!.complete();
    await stopped;
    await cancelling;
    await pair.outgoing.close();
    expect(pair.source.events, containsAll(['close:1', 'close:2']));
    expect(pair.wire.resumes, 0);
  });
  test('pause preempts a blocked resume acceptance write', () async {
    pair.wire.dropAck = true;
    final running = pair.outgoing.start();
    final rejected = expectLater(running, throwsA(isA<FileProtocolFailure>()));
    await pair.wire.firstChunk.future;
    await Future<void>.delayed(Duration.zero);
    await pair.pauseBoth();
    await rejected;
    pair.wire.resumeAcceptGate = Completer<void>();
    final resumed = pair.outgoing.resume(await pair.resumeRequest());
    final paused = expectLater(resumed, throwsA(isA<FileProtocolFailure>()));
    await pair.wire.resumeAcceptEntered.future;
    await pair.outgoing.pause(notifyPeer: false);
    await paused;
    expect(pair.outgoing.phase, OutgoingFilePhase.paused);
    expect(pair.wire.chunks, [32768]);
    pair.wire.resumeAcceptGate!.complete();
  });
  test(
    'resume-state revokes permission to substitute a saved complete',
    () async {
      pair.wire.dropComplete = true;
      final running = pair.outgoing.start();
      final rejected = expectLater(
        running,
        throwsA(isA<FileProtocolFailure>()),
      );
      await pair.wire.completeDropped.future;
      await pair.pauseBoth();
      await rejected;
      pair.wire.fakeStateThenComplete = true;
      await expectLater(
        pair.outgoing.resume(await pair.resumeRequest()),
        throwsA(isA<FileProtocolFailure>()),
      );
      expect(pair.outgoing.receipt, isNull);
    },
  );
  test('repeated local cancel does not lose pending peer cancellation confirmation', () async {
    pair.wire.dropAck = true;
    final running = pair.outgoing.start();
    final rejected = expectLater(running, throwsA(isA<FileProtocolFailure>()));
    await pair.wire.firstChunk.future;
    pair.source.cancelGate = Completer<void>();
    await pair.wire.reply(
      FileCancelled(transferId: pair.outgoing.context.transferId),
    );
    final stopping = pair.outgoing.cancel(notifyPeer: false);
    pair.source.cancelGate!.complete();
    await stopping;
    await rejected;
    await Future<void>.delayed(Duration.zero);
    expect(pair.outgoing.phase, OutgoingFilePhase.cancelled);
  });
  test(
    'retired authenticated signal cannot fail a new resume attempt',
    () async {
      pair.wire.sendGate = Completer<void>();
      final running = pair.outgoing.start();
      final rejected = expectLater(
        running,
        throwsA(isA<FileProtocolFailure>()),
      );
      await pair.wire.firstAck.future;
      final old = pair.wire.lastReplySignal!;
      await pair.pauseBoth();
      await rejected;
      pair.wire.sendGate!.complete();
      pair.wire.sendGate = null;
      pair.source.openGate = Completer<void>();
      final resumed = pair.outgoing.resume(await pair.resumeRequest());
      await pair.source.openEntered.future;
      await expectLater(
        pair.outgoing.handleSignal(old),
        throwsA(isA<FileProtocolFailure>()),
      );
      expect(pair.outgoing.phase, OutgoingFilePhase.verifying);
      pair.source.openGate!.complete();
      await resumed;
      expect(pair.outgoing.phase, OutgoingFilePhase.completed);
    },
  );
  test(
    'repeated ACK loss keeps one file and original content through resumes',
    () async {
      pair.wire.dropAck = true;
      var running = pair.outgoing.start();
      var rejected = expectLater(running, throwsA(isA<FileProtocolFailure>()));
      await pair.wire.firstChunk.future;
      await Future<void>.delayed(Duration.zero);
      await pair.pauseBoth();
      await rejected;
      pair.wire.dropAck = true;
      pair.wire.nextDrop = Completer<void>();
      running = pair.outgoing.resume(await pair.resumeRequest());
      rejected = expectLater(running, throwsA(isA<FileProtocolFailure>()));
      await pair.wire.nextDrop!.future;
      await Future<void>.delayed(Duration.zero);
      await pair.pauseBoth();
      await rejected;
      await pair.outgoing.resume(await pair.resumeRequest());
      expect(pair.wire.chunks, [32768, 32768, 4464]);
      expect(pair.disk.bytes, pair.source.bytes);
      expect(pair.disk.commits, 1);
      expect(pair.disk.resumes, 2);
      expect(pair.source.opens, 3);
    },
  );
  test(
    'resume cannot roll back bytes already acknowledged by receiver',
    () async {
      pair.wire.sendGate = Completer<void>();
      final running = pair.outgoing.start();
      final rejected = expectLater(
        running,
        throwsA(isA<FileProtocolFailure>()),
      );
      await pair.wire.firstAck.future;
      await pair.pauseBoth();
      await rejected;
      pair.wire.sendGate!.complete();
      pair.wire.sendGate = null;
      pair.wire.fakeResumeOffset = 0;
      await expectLater(
        pair.outgoing.resume(await pair.resumeRequest()),
        throwsA(isA<FileProtocolFailure>()),
      );
      expect(pair.wire.resumeAccepts, 0);
      expect(pair.disk.commits, 0);
    },
  );
  test(
    'a queued transport call without send completion or ACK proves no prefix',
    () async {
      pair.wire.beforeChunkGate = Completer<void>();
      final running = pair.outgoing.start();
      final rejected = expectLater(
        running,
        throwsA(isA<FileProtocolFailure>()),
      );
      await pair.wire.chunkQueued.future;
      await pair.pauseBoth();
      await rejected;
      pair.wire.fakeResumeOffset = 1;
      await expectLater(
        pair.outgoing.resume(await pair.resumeRequest()),
        throwsA(isA<FileProtocolFailure>()),
      );
      expect(pair.outgoing.sentOffset, 0);
      expect(pair.disk.bytes, isEmpty);
      pair.wire.beforeChunkGate!.complete();
    },
  );
  test('failed old source cleanup remains retryable after resume', () async {
    pair.wire.dropAck = true;
    final running = pair.outgoing.start();
    final rejected = expectLater(running, throwsA(isA<FileProtocolFailure>()));
    await pair.wire.firstChunk.future;
    await pair.pauseBoth();
    await rejected;
    pair.source.failClose = true;
    await expectLater(
      pair.outgoing.resume(await pair.resumeRequest()),
      throwsStateError,
    );
    expect(pair.wire.resumes, 0);
    await expectLater(pair.outgoing.close(), throwsStateError);
    pair.source.failClose = false;
    await pair.outgoing.close();
    expect(pair.source.events, containsAll(['close:1', 'close:2']));
  });
  test(
    'cancelled task refuses recovery without another scope or request',
    () async {
      pair.wire.dropAck = true;
      final running = pair.outgoing.start();
      final rejected = expectLater(
        running,
        throwsA(isA<FileProtocolFailure>()),
      );
      await pair.wire.firstChunk.future;
      await pair.pauseBoth();
      await rejected;
      final request = await pair.resumeRequest();
      await pair.outgoing.cancel(notifyPeer: false);
      await expectLater(
        pair.outgoing.resume(request),
        throwsA(isA<FileProtocolFailure>()),
      );
      expect(pair.source.opens, 1);
      expect(pair.wire.resumes, 0);
    },
  );
  test('cancel during complete verification still retains authenticated publication', () async {
    pair.wire.dropComplete = true;
    final running = pair.outgoing.start();
    final rejected = expectLater(running, throwsA(isA<FileProtocolFailure>()));
    await pair.wire.completeDropped.future;
    final message = FileComplete(
      transferId: pair.outgoing.context.transferId,
      actualName: pair.wire.incoming!.receipt!.name,
      size: pair.outgoing.context.size,
      sha256: pair.outgoing.context.sha256,
    );
    final signal = await pair.sender.openSignal(
      pair.outgoing.context.authorization,
      await pair.receiver.sealSignal(
        pair.wire.incoming!.context.authorization,
        FileCodec.encode(message),
      ),
    );
    pair.clockGate = Completer<void>();
    final handling = pair.outgoing.handleSignal(signal);
    await pair.clockEntered.future;
    await pair.outgoing.cancel(notifyPeer: false);
    await rejected;
    pair.clockGate!.complete();
    await handling;
    expect(pair.outgoing.receipt!.actualName, 'sample (1).bin');
    expect(pair.outgoing.phase, OutgoingFilePhase.completed);
  });
  test('local pause during peer failure verification cannot preserve resume eligibility', () async {
    pair.wire.dropAck = true;
    final running = pair.outgoing.start();
    final rejected = expectLater(running, throwsA(isA<FileProtocolFailure>()));
    await pair.wire.firstChunk.future;
    final signal = await pair.sender.openSignal(
      pair.outgoing.context.authorization,
      await pair.receiver.sealSignal(
        pair.wire.incoming!.context.authorization,
        FileCodec.encode(
          FileFailed(
            transferId: pair.outgoing.context.transferId,
            code: 'disk_full',
          ),
        ),
      ),
    );
    pair.clockGate = Completer<void>();
    final handling = pair.outgoing.handleSignal(signal);
    await pair.clockEntered.future;
    await pair.outgoing.pause(notifyPeer: false);
    await rejected;
    pair.clockGate!.complete();
    await handling;
    expect(pair.outgoing.phase, OutgoingFilePhase.failed);
    expect(pair.source.stops.last, SourceStopMode.cancel);
  });
}

// Real sealed requests/signals and owners, with an explicit memory transport
// and native storage doubles. These tests are not TCP or platform evidence.
class _Pair {
  late GrantEndpoint sender, receiver;
  late GrantRegistry receiverRegistry;
  late _Source source;
  final disk = _Disk();
  late _Wire wire;
  late OutgoingFileTransfer outgoing;
  bool closed = false;
  int attempt = 0;
  Completer<void>? clockGate;
  final clockEntered = Completer<void>();

  Future<void> pauseBoth() async {
    await outgoing.pause(notifyPeer: false);
    await wire.incoming!.pause();
  }

  Future<LocalSessionRequest> resumeRequest() async {
    sender.suspend();
    receiver.suspend();
    final hello = await sender.beginResume();
    await receiver.acceptResume(
      await sender.finishResume(await receiver.answerResume(hello)),
    );
    final original = outgoing.context;
    return sender.authorizeLocal(
      SessionOperation.file,
      'resume-${++attempt}',
      FileCodec.encode(
        FileResume(
          transferOrdinal: original.transferOrdinal,
          transferId: original.transferId,
          name: outgoing.source.file.name,
          size: original.size,
          sha256: original.sha256,
          chunkBytes: original.chunkBytes,
          attemptId: attempt.toRadixString(16).padLeft(32, '0'),
        ),
      ),
    );
  }

  static Future<_Pair> create({
    int size = 70000,
    FilePublication? publication,
  }) async {
    final p = _Pair();
    final binding = GrantBinding(
      id: List.filled(32, 71),
      initiatorKey: List.filled(32, 72),
      receiverKey: List.filled(32, 73),
    );
    GrantEndpoint endpoint(GrantRole role) =>
        GrantEndpoint.fromAuthenticatedPairing(
          binding: binding,
          role: role,
          establishedMicros: 100,
          recoverySecret: List.filled(32, 74),
          clock: () async {
            if (role == GrantRole.initiator && p.clockGate != null) {
              if (!p.clockEntered.isCompleted) p.clockEntered.complete();
              await p.clockGate!.future;
            }
            return 100;
          },
          onInvalidated: () {},
        );
    p.sender = endpoint(GrantRole.initiator);
    p.receiver = endpoint(GrantRole.receiver);
    p.receiverRegistry = GrantRegistry()..register(p.receiver);
    final registry = GrantRegistry()..register(p.sender);
    final hello = await p.sender.beginResume();
    await p.receiver.acceptResume(
      await p.sender.finishResume(await p.receiver.answerResume(hello)),
    );
    p.source = _Source(Uint8List.fromList(List.generate(size, (i) => i % 251)));
    final request = await p.sender.authorizeLocal(
      SessionOperation.file,
      'file',
      FileCodec.encode(
        FileOffer(
          transferOrdinal: publication?.ordinal ?? 1,
          transferId: 'a' * 32,
          name: 'sample.bin',
          size: size,
          sha256: hashes.sha256.convert(p.source.bytes).toString(),
          chunkBytes: FileLimits.chunkBytes,
        ),
      ),
    );
    final context = await FileTransferContext.fromRequest(registry, request);
    p.wire = _Wire(p);
    p.outgoing = OutgoingFileTransfer(
      source: VerifiedFileSource(
        access: p.source,
        file: SelectedFile(token: 'picked', name: 'sample.bin', size: size),
        context: context,
      ),
      transport: p.wire,
      publication: publication,
    );
    return p;
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    for (final gate in [
      wire.ackGate,
      wire.sendGate,
      wire.cancelGate,
      disk.commitGate,
      source.readGate,
      source.pauseGate,
      source.openGate,
      source.cancelGate,
      wire.resumeAcceptGate,
      wire.beforeChunkGate,
      wire.offerReturnGate,
      clockGate,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    await outgoing.close();
    await wire.incoming?.close();
    sender.revoke();
    receiver.revoke();
  }
}

class _Wire implements SessionTransport {
  _Wire(this.pair);
  final _Pair pair;
  IncomingFileTransfer? incoming;
  int offers = 0;
  int resumes = 0, resumeAccepts = 0;
  bool dropAck = false, dropComplete = false;
  bool fakeStateThenComplete = false;
  Completer<void>? resumeAcceptGate;
  Completer<void>? offerReturnGate;
  final offerDelivered = Completer<void>();
  final resumeAcceptEntered = Completer<void>();
  VerifiedSessionSignal? lastReplySignal;
  Completer<void>? nextDrop, beforeChunkGate;
  final chunkQueued = Completer<void>();
  int? fakeResumeOffset;
  String? fakeResumeHash;
  final completeDropped = Completer<void>();
  final chunks = <int>[];
  bool wrongAck = false,
      prematureComplete = false,
      duplicateAck = false,
      foreignAccept = false,
      mutateAfterAccept = false,
      failCancel = false,
      failAfterComplete = false;
  int acceptedChunkBytes = FileLimits.chunkBytes;
  final failures = <String>[];
  final failureAnswered = Completer<void>();
  final peerCancelAcknowledged = Completer<void>();
  Completer<void>? ackGate, sendGate, cancelGate;
  final firstChunk = Completer<void>(),
      firstAck = Completer<void>(),
      cancelAnswered = Completer<void>(),
      completed = Completer<void>();

  Future<void> reply(FileMessage message) async {
    final auth = incoming!.context.authorization;
    final signal = await pair.sender.openSignal(
      pair.outgoing.context.authorization,
      await pair.receiver.sealSignal(auth, FileCodec.encode(message)),
    );
    lastReplySignal = signal;
    await pair.outgoing.handleSignal(signal);
  }

  @override
  Future<void> sendRequest(LocalSessionRequest request) async {
    offers++;
    final auth = await pair.receiver.open(
      await pair.sender.sealRequest(request),
    );
    if (FileCodec.decode(request.body) is FileResume) {
      resumes++;
      final response = await incoming!.resume(auth);
      if (fakeStateThenComplete && response is FileComplete) {
        await reply(
          FileResumeState(
            transferId: response.transferId,
            attemptId: (FileCodec.decode(request.body) as FileResume).attemptId,
            offset: response.size,
            prefixSha256: response.sha256,
          ),
        );
        await reply(response);
        return;
      }
      if (response is FileResumeState) {
        final offset = fakeResumeOffset ?? response.offset;
        await reply(
          FileResumeState(
            transferId: response.transferId,
            attemptId: response.attemptId,
            offset: offset,
            prefixSha256:
                fakeResumeHash ??
                (fakeResumeOffset == null
                    ? response.prefixSha256
                    : hashes.sha256
                          .convert(pair.source.bytes.sublist(0, offset))
                          .toString()),
          ),
        );
      } else {
        await reply(response);
      }
      return;
    }
    incoming = IncomingFileTransfer(
      context: await FileTransferContext.fromRequest(
        pair.receiverRegistry,
        auth,
      ),
      access: pair.disk,
      directory: const ReceiveDirectory(token: 'directory', label: 'Downloads'),
    );
    final accept = await incoming!.start();
    if (foreignAccept) {
      final local = await pair.sender.authorizeLocal(
        SessionOperation.file,
        'other',
        request.body,
      );
      final remote = await pair.receiver.open(
        await pair.sender.sealRequest(local),
      );
      final signal = await pair.sender.openSignal(
        local,
        await pair.receiver.sealSignal(remote, FileCodec.encode(accept)),
      );
      await pair.outgoing.handleSignal(signal);
      return;
    }
    await reply(
      prematureComplete
          ? FileComplete(
              transferId: accept.transferId,
              actualName: 'fake.bin',
              size: pair.source.bytes.length,
              sha256: pair.outgoing.context.sha256,
            )
          : FileAccept(
              transferId: accept.transferId,
              acceptedChunkBytes: acceptedChunkBytes,
              window: 1,
              offset: 0,
            ),
    );
    if (mutateAfterAccept) pair.source.bytes[0] ^= 1;
    if (!offerDelivered.isCompleted) offerDelivered.complete();
    if (offerReturnGate != null) await offerReturnGate!.future;
  }

  @override
  Future<void> sendSignal(
    SessionAuthorization authorization,
    String body,
  ) async {
    final signal = await pair.receiver.openSignal(
      incoming!.context.authorization,
      await pair.sender.sealSignal(authorization, body),
    );
    final message = FileCodec.decode(body);
    switch (message) {
      case FileChunk():
        chunks.add(message.data.length);
        if (!chunkQueued.isCompleted) chunkQueued.complete();
        if (beforeChunkGate != null) await beforeChunkGate!.future;
        final ack = await incoming!.append(signal);
        if (!firstChunk.isCompleted) firstChunk.complete();
        if (dropAck) {
          dropAck = false;
          if (nextDrop != null && !nextDrop!.isCompleted) nextDrop!.complete();
          return;
        }
        if (ackGate != null) await ackGate!.future;
        await reply(
          wrongAck
              ? FileAck(
                  transferId: ack.transferId,
                  nextOffset: ack.nextOffset - 1,
                )
              : ack,
        );
        if (duplicateAck) await reply(ack);
        if (!firstAck.isCompleted) firstAck.complete();
        if (sendGate != null) await sendGate!.future;
      case FileFinish():
        FileComplete receipt;
        try {
          receipt = await incoming!.finish(signal);
        } catch (_) {
          final saved = incoming!.receipt;
          if (saved == null) rethrow;
          receipt = FileComplete(
            transferId: message.transferId,
            actualName: saved.name,
            size: saved.size,
            sha256: saved.sha256,
          );
        }
        if (dropComplete) {
          dropComplete = false;
          completeDropped.complete();
          return;
        }
        await reply(receipt);
        completed.complete();
        if (failAfterComplete) {
          throw StateError('wire closed after publication');
        }
      case FileCancel():
        if (failCancel) throw StateError('control write failed');
        if (cancelGate != null) await cancelGate!.future;
        final state = await incoming!.cancel();
        if (state == ReceiveStopState.cancelled) {
          await reply(FileCancelled(transferId: message.transferId));
        }
        if (!cancelAnswered.isCompleted) cancelAnswered.complete();
      case FilePause():
        final checkpoint = await incoming!.pause();
        if (checkpoint != null) {
          await reply(
            FilePaused(
              transferId: message.transferId,
              offset: checkpoint.offset,
            ),
          );
        }
      case FileResumeAccept():
        resumeAccepts++;
        await incoming!.acceptResume(signal);
        if (!resumeAcceptEntered.isCompleted) resumeAcceptEntered.complete();
        if (resumeAcceptGate != null) await resumeAcceptGate!.future;
      case FileFailed():
        failures.add(message.code);
        await incoming!.cancel();
        await incoming!.cleanup();
        if (!failureAnswered.isCompleted) failureAnswered.complete();
      case FileCancelled():
        if (!peerCancelAcknowledged.isCompleted) {
          peerCancelAcknowledged.complete();
        }
      case FilePaused():
        break;
      default:
        throw StateError('unexpected outgoing ${message.runtimeType}');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Source implements SourceAccess {
  _Source(this.bytes);
  final Uint8List bytes;
  int passes = 0, sendReads = 0;
  int closes = 0;
  int opens = 0;
  final events = <String>[];
  Completer<void>? openGate;
  final openEntered = Completer<void>();
  bool failClose = false, failStop = false, failPause = false;
  Completer<void>? readGate, pauseGate, cancelGate;
  final readEntered = Completer<void>();
  final finished = <int>[];
  final stops = <SourceStopMode>[];
  @override
  Future<SourceScope> openScope({
    required String fileToken,
    required String key,
    required int deadlineMicros,
  }) async {
    final token = '${++opens}';
    if (openGate != null) {
      if (!openEntered.isCompleted) openEntered.complete();
      await openGate!.future;
    }
    events.add('open:$token');
    return SourceScope(
      token: token,
      fileToken: fileToken,
      key: key,
      deadlineMicros: deadlineMicros,
    );
  }

  @override
  Future<SourceStopState> stopScope(
    SourceScope scope,
    SourceStopMode mode,
  ) async {
    stops.add(mode);
    if (mode == SourceStopMode.cancel && cancelGate != null) {
      await cancelGate!.future;
    }
    if (mode == SourceStopMode.pause && pauseGate != null) {
      await pauseGate!.future;
    }
    if ((mode == SourceStopMode.pause && failPause) ||
        (mode == SourceStopMode.cancel && failStop)) {
      throw StateError('stop failed');
    }
    return mode == SourceStopMode.pause
        ? SourceStopState.paused
        : SourceStopState.cancelled;
  }

  @override
  Future<void> closeScope(SourceScope scope) async {
    closes++;
    if (failClose) throw StateError('close failed');
    events.add('close:${scope.token}');
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
    if (passes.isEven) {
      sendReads++;
      if (!readEntered.isCompleted) readEntered.complete();
      if (readGate != null) await readGate!.future;
    }
    return Uint8List.fromList(bytes.sublist(offset, offset + length));
  }

  @override
  Future<void> finishPass(SourceReadPass pass) async => finished.add(passes);
}

class _Disk implements ReceiveAccess {
  final bytes = <int>[];
  int commits = 0;
  int resumes = 0, opens = 0;
  bool commitWon = false;
  Completer<void>? commitGate;
  final commitEntered = Completer<void>();
  @override
  Future<ReceiveScope> openScope({
    required String key,
    required int deadlineMicros,
  }) async => ReceiveScope(
    token: 'receiver${++opens}',
    key: key,
    deadlineMicros: deadlineMicros,
  );
  @override
  Future<ReceiveStopState> stopScope(
    ReceiveScope scope,
    ReceiveStopMode mode,
  ) async => commitWon
      ? ReceiveStopState.committing
      : mode == ReceiveStopMode.pause
      ? ReceiveStopState.paused
      : ReceiveStopState.cancelled;
  @override
  Future<void> closeScope(ReceiveScope scope) async {}
  @override
  Future<ReceiveFile> begin({
    required ReceiveDirectory directory,
    required ReceiveScope scope,
    required ReceiveMetadata metadata,
  }) async => ReceiveFile(
    token: 'temp',
    metadata: metadata,
    key: scope.key,
    deadlineMicros: scope.deadlineMicros,
  );
  @override
  Future<int> append(
    ReceiveFile file,
    ReceiveScope scope,
    int offset,
    Uint8List chunk,
  ) async {
    expect(offset, bytes.length);
    bytes.addAll(chunk);
    return bytes.length;
  }

  @override
  Future<ReceiveReceipt> commit(ReceiveFile file, ReceiveScope scope) async {
    commitEntered.complete();
    if (commitGate != null) await commitGate!.future;
    expect(bytes.length, file.metadata.size);
    expect(hashes.sha256.convert(bytes).toString(), file.metadata.sha256);
    commits++;
    return ReceiveReceipt(
      name: 'sample (1).bin',
      size: bytes.length,
      sha256: file.metadata.sha256,
    );
  }

  @override
  Future<ReceiveCheckpoint> checkpoint(ReceiveFile file) async =>
      ReceiveCheckpoint(
        offset: bytes.length,
        sha256: hashes.sha256.convert(bytes).toString(),
        identity: 'temp',
      );
  @override
  Future<void> resume(
    ReceiveFile file,
    ReceiveScope scope,
    ReceiveCheckpoint checkpoint,
  ) async {
    resumes++;
    if (checkpoint.offset != bytes.length ||
        checkpoint.sha256 != hashes.sha256.convert(bytes).toString()) {
      throw const ReceiveAccessFailure('integrity_mismatch');
    }
  }

  @override
  Future<void> abort(ReceiveFile file) async {}
  @override
  Future<void> retryCleanup(ReceiveFile file) async {}
  @override
  Future<void> release(ReceiveFile file) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
