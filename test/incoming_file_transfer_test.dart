import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/transfers/incoming_file_transfer.dart';
import 'package:share_hub_open/features/transfers/receive_access.dart';

void main() {
  late GrantEndpoint sender, receiver;
  late LocalSessionRequest local;
  late FileTransferContext context;
  late _Storage disk;
  final content = Uint8List.fromList([1, 2, 3]);
  final digest = hashes.sha256.convert(content).toString();
  const id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  setUp(() async {
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
          clock: () async => 100,
          onInvalidated: () {},
        );
    sender = endpoint(GrantRole.initiator);
    receiver = endpoint(GrantRole.receiver);
    final hello = await sender.beginResume();
    await receiver.acceptResume(
      await sender.finishResume(await receiver.answerResume(hello)),
    );
    local = await sender.authorizeLocal(
      SessionOperation.file,
      'incoming',
      FileCodec.encode(
        FileOffer(
          transferOrdinal: 1,
          transferId: id,
          name: 'sample.bin',
          size: 3,
          sha256: digest,
          chunkBytes: 32768,
        ),
      ),
    );
    context = await FileTransferContext.fromRequest(
      GrantRegistry()..register(receiver),
      await receiver.open(await sender.sealRequest(local)),
    );
    disk = _Storage();
  });
  tearDown(() {
    sender.revoke();
    receiver.revoke();
  });
  IncomingFileTransfer transfer() => IncomingFileTransfer(
    context: context,
    access: disk,
    directory: const ReceiveDirectory(token: 'directory', label: 'Downloads'),
  );
  Future<VerifiedSessionSignal> signal(FileMessage message) async =>
      receiver.openSignal(
        context.authorization,
        await sender.sealSignal(local, FileCodec.encode(message)),
      );
  Future<VerifiedSessionSignal> chunk({int offset = 0, List<int>? bytes}) =>
      signal(FileChunk(transferId: id, offset: offset, data: bytes ?? content));
  Future<VerifiedSessionSignal> finish() =>
      signal(FileFinish(transferId: id, size: 3, sha256: digest));

  test(
    'accept follows native creation and completion follows actual publication',
    () async {
      final task = transfer();
      expect(
        await task.start(),
        isA<FileAccept>().having((v) => v.offset, 'offset', 0),
      );
      expect(task.phase, IncomingFilePhase.receiving);
      expect((await task.append(await chunk())).nextOffset, 3);
      expect(task.receipt, isNull);
      final result = await task.finish(await finish());
      expect(result.actualName, 'sample (1).bin');
      expect(result.sha256, digest);
      expect(task.phase, IncomingFilePhase.completed);
      await task.close();
      expect(disk.aborts, 0);
      expect(disk.releases, 1);
      expect(task.receipt!.name, 'sample (1).bin');
    },
  );
  test('failed begin never returns acceptance', () async {
    disk.failBegin = true;
    final task = transfer();
    await expectLater(task.start(), throwsStateError);
    expect(task.phase, IncomingFilePhase.failed);
    expect(disk.appends, 0);
    await task.close();
  });
  test(
    'empty incoming file still requires native commit and actual receipt',
    () async {
      final emptyHash = hashes.sha256.convert([]).toString();
      local = await sender.authorizeLocal(
        SessionOperation.file,
        'empty',
        FileCodec.encode(
          FileOffer(
            transferOrdinal: 1,
            transferId: id,
            name: 'empty.bin',
            size: 0,
            sha256: emptyHash,
            chunkBytes: 32768,
          ),
        ),
      );
      context = await FileTransferContext.fromRequest(
        GrantRegistry()..register(receiver),
        await receiver.open(await sender.sealRequest(local)),
      );
      final task = transfer();
      await task.start();
      expect(task.receipt, isNull);
      final complete = await task.finish(
        await signal(FileFinish(transferId: id, size: 0, sha256: emptyHash)),
      );
      expect(complete.size, 0);
      expect(complete.sha256, emptyHash);
      expect(disk.appends, 0);
      expect(disk.commitEntered.isCompleted, isTrue);
      await task.close();
    },
  );
  test(
    'another authenticated operation cannot append to this retained slot',
    () async {
      final task = transfer();
      await task.start();
      final other = await sender.authorizeLocal(
        SessionOperation.file,
        'other',
        local.body,
      );
      final incoming = await receiver.open(await sender.sealRequest(other));
      final crossSignal = await receiver.openSignal(
        incoming,
        await sender.sealSignal(
          other,
          FileCodec.encode(FileChunk(transferId: id, offset: 0, data: [1])),
        ),
      );
      await expectLater(
        task.append(crossSignal),
        throwsA(isA<FileProtocolFailure>()),
      );
      expect(disk.appends, 0);
      await task.close();
    },
  );
  test('finish before all bytes never starts native publication', () async {
    final task = transfer();
    await task.start();
    await expectLater(
      task.finish(await finish()),
      throwsA(isA<FileProtocolFailure>()),
    );
    expect(disk.commitEntered.isCompleted, isFalse);
    expect(task.receipt, isNull);
    await task.close();
  });
  test('nonsequential data fails before any disk append', () async {
    final task = transfer();
    await task.start();
    await expectLater(
      task.append(await chunk(offset: 1, bytes: [1])),
      throwsA(isA<FileProtocolFailure>()),
    );
    expect(disk.appends, 0);
    await task.close();
  });
  test(
    'one pending append rejects concurrent work without another write',
    () async {
      final task = transfer();
      await task.start();
      disk.appendGate = Completer<void>();
      final first = task.append(await chunk());
      await disk.appendEntered.future;
      await expectLater(
        task.append(await chunk()),
        throwsA(isA<FileProtocolFailure>()),
      );
      expect(disk.appends, 1);
      disk.appendGate!.complete();
      expect((await first).nextOffset, 3);
      await task.close();
    },
  );
  test('cancel during begin owns and cleans a late file token', () async {
    disk.beginGate = Completer<void>();
    final task = transfer();
    final starting = task.start();
    final rejected = expectLater(starting, throwsA(isA<SessionFailure>()));
    await disk.beginEntered.future;
    await task.cancel();
    expect(disk.stops, contains(ReceiveStopMode.cancel));
    disk.beginGate!.complete();
    await rejected;
    await task.cleanup();
    expect(disk.aborts, 1);
    expect(disk.releases, 1);
    await task.close();
  });
  test(
    'publication wins cancel: retain receipt before rejecting stale reply',
    () async {
      final task = transfer();
      await task.start();
      await task.append(await chunk());
      disk.commitGate = Completer<void>();
      final finishing = task.finish(await finish());
      final rejected = expectLater(finishing, throwsA(isA<SessionFailure>()));
      await disk.commitEntered.future;
      disk.commitWon = true;
      final stopped = await task.cancel();
      final phaseBeforeReceipt = task.phase;
      disk.commitGate!.complete();
      await rejected;
      expect(stopped, ReceiveStopState.committing);
      expect(phaseBeforeReceipt, isNot(IncomingFilePhase.cancelled));
      expect(task.phase, IncomingFilePhase.completed);
      expect(task.receipt!.name, 'sample (1).bin');
      await task.cleanup();
      expect(disk.aborts, 0);
      await task.close();
    },
  );
  test('cancel wins failed commit never manufactures a receipt', () async {
    final task = transfer();
    await task.start();
    await task.append(await chunk());
    disk.commitGate = Completer<void>();
    disk.failCommit = true;
    final finishing = task.finish(await finish());
    final rejected = expectLater(finishing, throwsStateError);
    await disk.commitEntered.future;
    await task.cancel();
    disk.commitGate!.complete();
    await rejected;
    expect(task.receipt, isNull);
    expect(task.phase, IncomingFilePhase.cancelled);
    await task.close();
  });
  test(
    'failed publication after committing stop becomes terminal failure',
    () async {
      final task = transfer();
      await task.start();
      await task.append(await chunk());
      disk.commitGate = Completer<void>();
      disk.failCommit = true;
      final finishing = task.finish(await finish());
      final rejected = expectLater(finishing, throwsStateError);
      await disk.commitEntered.future;
      disk.commitWon = true;
      await task.cancel();
      disk.commitGate!.complete();
      await rejected;
      expect(task.receipt, isNull);
      expect(task.phase, IncomingFilePhase.failed);
      await task.close();
    },
  );
  test(
    'pause gates in-flight append and checkpoints only after it settles',
    () async {
      final task = transfer();
      await task.start();
      disk.appendGate = Completer<void>();
      final appending = task.append(await chunk());
      final rejected = expectLater(appending, throwsA(isA<SessionFailure>()));
      await disk.appendEntered.future;
      final pausing = task.pause();
      expect(disk.stops, [ReceiveStopMode.pause]);
      receiver.suspend();
      expect(disk.checkpoints, 0);
      disk.appendGate!.complete();
      await rejected;
      expect((await pausing)!.offset, 3);
      expect(task.phase, IncomingFilePhase.paused);
      expect(task.offset, 3);
      await task.close();
    },
  );
  test(
    'failed cleanup retains ownership and explicit retry releases exactly once',
    () async {
      final task = transfer();
      await task.start();
      disk.failCleanup = true;
      await task.cancel();
      await expectLater(task.cleanup(), throwsStateError);
      expect(task.cleanupFailure, isA<StateError>());
      expect(disk.releases, 0);
      disk.failCleanup = false;
      await task.cleanup();
      expect(disk.releases, 1);
      expect(task.cleanupFailure, isNull);
      await task.close();
      expect(disk.releases, 1);
    },
  );
  test(
    'idle permanent revoke stops native scope and retains no active task',
    () async {
      final task = transfer();
      await task.start();
      receiver.revoke();
      await task.cleanup();
      expect(task.phase, IncomingFilePhase.cancelled);
      expect(disk.stops, contains(ReceiveStopMode.cancel));
      expect(disk.releases, 1);
      await task.close();
    },
  );
  for (final terminal in ['cancel', 'close', 'revoke']) {
    test('cached pause cannot survive $terminal', () async {
      final task = transfer();
      await task.start();
      expect(await task.pause(), isNotNull);
      if (terminal == 'cancel') {
        await task.cancel();
        await task.cleanup();
      } else if (terminal == 'close') {
        await task.close();
      } else {
        receiver.revoke();
        await task.cleanup();
      }
      await expectLater(task.pause(), throwsA(isA<FileProtocolFailure>()));
      await task.close();
    });
  }
  test(
    'cleanup retries a failed native stop before releasing its token',
    () async {
      final task = transfer();
      await task.start();
      disk.failStop = true;
      await expectLater(task.cancel(), throwsStateError);
      await expectLater(task.cleanup(), throwsStateError);
      expect(disk.releases, 0);
      disk.failStop = false;
      await task.cleanup();
      expect(disk.stops.length, greaterThanOrEqualTo(2));
      expect(disk.releases, 1);
      expect(task.phase, IncomingFilePhase.cancelled);
      await task.close();
    },
  );
}

class _Storage implements ReceiveAccess {
  final stops = <ReceiveStopMode>[];
  int appends = 0, aborts = 0, releases = 0, checkpoints = 0, written = 0;
  bool failBegin = false,
      failCommit = false,
      failCleanup = false,
      failStop = false,
      commitWon = false;
  Completer<void>? beginGate, appendGate, commitGate;
  final beginEntered = Completer<void>(),
      appendEntered = Completer<void>(),
      commitEntered = Completer<void>();
  ReceiveFile? file;
  @override
  Future<ReceiveScope> openScope({
    required String key,
    required int deadlineMicros,
  }) async =>
      ReceiveScope(token: 'scope', key: key, deadlineMicros: deadlineMicros);
  @override
  Future<ReceiveStopState> stopScope(
    ReceiveScope scope,
    ReceiveStopMode mode,
  ) async {
    stops.add(mode);
    if (failStop) throw StateError('stop dispatch failed');
    return commitWon
        ? ReceiveStopState.committing
        : mode == ReceiveStopMode.pause
        ? ReceiveStopState.paused
        : ReceiveStopState.cancelled;
  }

  @override
  Future<void> closeScope(ReceiveScope scope) async {}
  @override
  Future<ReceiveFile> begin({
    required ReceiveDirectory directory,
    required ReceiveScope scope,
    required ReceiveMetadata metadata,
  }) async {
    beginEntered.complete();
    if (beginGate != null) await beginGate!.future;
    if (failBegin) throw StateError('begin failed');
    return file = ReceiveFile(
      token: 'file',
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
    Uint8List bytes,
  ) async {
    appends++;
    if (!appendEntered.isCompleted) appendEntered.complete();
    if (appendGate != null) await appendGate!.future;
    return written = offset + bytes.length;
  }

  @override
  Future<ReceiveReceipt> commit(ReceiveFile file, ReceiveScope scope) async {
    commitEntered.complete();
    if (commitGate != null) await commitGate!.future;
    if (failCommit) throw StateError('commit failed');
    return ReceiveReceipt(
      name: 'sample (1).bin',
      size: file.metadata.size,
      sha256: file.metadata.sha256,
    );
  }

  @override
  Future<ReceiveCheckpoint> checkpoint(ReceiveFile file) async {
    checkpoints++;
    return ReceiveCheckpoint(
      offset: written,
      sha256: 'b' * 64,
      identity: 'original',
    );
  }

  @override
  Future<void> abort(ReceiveFile file) async {
    aborts++;
  }

  @override
  Future<void> retryCleanup(ReceiveFile file) async {
    if (failCleanup) throw StateError('cleanup failed');
  }

  @override
  Future<void> release(ReceiveFile file) async {
    releases++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
