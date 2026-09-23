import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/transfers/incoming_file_transfer.dart';
import 'package:share_hub_open/features/transfers/receive_access.dart';

void main() {
  late _Pair pair;
  setUp(() async => pair = await _Pair.create());
  tearDown(() async => pair.close());

  test(
    'same original grant rebinds native prefix before accepting more data',
    () async {
      await pair.task.start();
      await pair.append([1, 2]);
      await pair.task.pause();
      final request = await pair.resumeRequest(reconnect: true);
      final state = await pair.task.resume(request) as FileResumeState;
      expect(state.offset, 2);
      expect(state.prefixSha256, _hash([1, 2]));
      expect(
        pair.disk.events,
        containsAllInOrder(['resume:scope2', 'close:scope1']),
      );
      expect(pair.task.phase, IncomingFilePhase.awaitingResumeAccept);
      await pair.accept(state);
      await pair.append([3, 4]);
      final complete = await pair.finish();
      expect(complete.actualName, 'sample (1).bin');
      expect(pair.disk.bytes, [1, 2, 3, 4]);
      expect(pair.disk.begins, 1);
      expect(pair.disk.commits, 1);
    },
  );

  test('new chunks cannot skip resume acceptance', () async {
    await pair.task.start();
    await pair.task.pause();
    await pair.task.resume(await pair.resumeRequest());
    await expectLater(pair.append([1]), throwsA(isA<FileProtocolFailure>()));
    expect(pair.disk.bytes, isEmpty);
  });

  test('resume acceptance must echo exact retained prefix', () async {
    await pair.task.start();
    await pair.append([1]);
    await pair.task.pause();
    final state =
        await pair.task.resume(await pair.resumeRequest()) as FileResumeState;
    await expectLater(
      pair.accept(state, hash: '0' * 64),
      throwsA(isA<FileProtocolFailure>()),
    );
    expect(pair.task.phase, IncomingFilePhase.failed);
    await pair.task.cleanup();
    expect(pair.disk.aborts, 1);
  });

  test(
    'changed temporary contents fail native resume and never return state',
    () async {
      await pair.task.start();
      await pair.append([1, 2]);
      await pair.task.pause();
      pair.disk.bytes[0] = 9;
      await expectLater(
        pair.task.resume(await pair.resumeRequest()),
        throwsA(isA<ReceiveAccessFailure>()),
      );
      expect(pair.task.phase, IncomingFilePhase.failed);
      expect(pair.disk.commits, 0);
    },
  );

  test(
    'old authenticated signal cannot write into resumed operation',
    () async {
      await pair.task.start();
      final old = await pair.signal(
        FileChunk(transferId: _Pair.id, offset: 0, data: [1]),
      );
      await pair.task.pause();
      final state =
          await pair.task.resume(await pair.resumeRequest()) as FileResumeState;
      await pair.accept(state);
      await expectLater(
        pair.task.append(old),
        throwsA(isA<FileProtocolFailure>()),
      );
      expect(pair.disk.bytes, isEmpty);
    },
  );

  test(
    'repeated pause and resume preserves one file and original deadline',
    () async {
      await pair.task.start();
      final deadline = pair.task.context.authorization.expiresMicros;
      for (final byte in [1, 2, 3, 4]) {
        await pair.task.pause();
        final state = await pair.task.resume(
          await pair.resumeRequest(),
        ) as FileResumeState;
        await pair.accept(state);
        await pair.append([byte]);
        expect(pair.task.context.authorization.expiresMicros, deadline);
      }
      await pair.finish();
      expect(pair.disk.begins, 1);
      expect(pair.disk.resumes, 4);
      expect(pair.disk.closedScopes, ['scope1', 'scope2', 'scope3', 'scope4']);
    },
  );

  test(
    'cancel while native resume is blocked stops both old and fresh scopes',
    () async {
      await pair.task.start();
      await pair.task.pause();
      pair.disk.resumeGate = Completer<void>();
      final pending = pair.task.resume(await pair.resumeRequest());
      final rejected = expectLater(
        pending,
        throwsA(anyOf(isA<ReceiveAccessFailure>(), isA<SessionFailure>())),
      );
      await pair.disk.resumeEntered.future;
      await pair.task.cancel();
      expect(pair.disk.modes['scope1'], ReceiveStopMode.cancel);
      expect(pair.disk.modes['scope2'], ReceiveStopMode.cancel);
      pair.disk.resumeGate!.complete();
      await rejected;
      await pair.task.cleanup();
      expect(pair.disk.releases, 1);
      expect(pair.task.phase, IncomingFilePhase.cancelled);
    },
  );

  test(
    'cancel during fresh scope opening owns and closes the late scope',
    () async {
      await pair.task.start();
      await pair.task.pause();
      pair.disk.openGate = Completer<void>();
      final pending = pair.task.resume(await pair.resumeRequest());
      final rejected = expectLater(pending, throwsA(isA<SessionFailure>()));
      await pair.disk.openEntered.future;
      final stopping = pair.task.cancel();
      expect(pair.disk.modes['scope1'], ReceiveStopMode.cancel);
      pair.disk.openGate!.complete();
      await rejected;
      await stopping;
      await pair.task.close();
      expect(pair.disk.closedScopes, containsAll(['scope1', 'scope2']));
      expect(pair.disk.resumes, 0);
    },
  );

  test('retired scope close failure retains retryable ownership', () async {
    await pair.task.start();
    await pair.task.pause();
    pair.disk.failClose = 'scope1';
    await expectLater(
      pair.task.resume(await pair.resumeRequest()),
      throwsStateError,
    );
    await expectLater(pair.task.cleanup(), throwsStateError);
    expect(pair.disk.releases, 0);
    pair.disk.failClose = null;
    await pair.task.cleanup();
    await pair.task.close();
    expect(pair.disk.closedScopes, ['scope1', 'scope2']);
    expect(pair.disk.releases, 1);
  });

  test(
    'lost complete replays actual receipt without another native publish',
    () async {
      await pair.task.start();
      await pair.append([1, 2, 3, 4]);
      final receipt = await pair.finish();
      await pair.task.pause();
      final result = await pair.task.resume(
        await pair.resumeRequest(reconnect: true),
      ) as FileComplete;
      expect(result.actualName, receipt.actualName);
      expect(pair.disk.begins, 1);
      expect(pair.disk.opens, 1);
      expect(pair.disk.resumes, 0);
      expect(pair.disk.commits, 1);
      expect(pair.task.phase, IncomingFilePhase.completed);
    },
  );

  for (final terminal in ['cancel', 'close']) {
    test('$terminal cannot reopen paused file', () async {
      await pair.task.start();
      await pair.task.pause();
      final request = await pair.resumeRequest();
      if (terminal == 'cancel') {
        await pair.task.cancel();
      } else {
        await pair.task.close();
      }
      await expectLater(
        pair.task.resume(request),
        throwsA(isA<FileProtocolFailure>()),
      );
      expect(pair.disk.resumes, 0);
      expect(pair.disk.opens, 1);
    });
  }
  test('mismatched resume metadata cannot allocate another scope', () async {
    await pair.task.start();
    await pair.task.pause();
    final changed = await pair.sender.authorizeLocal(
      SessionOperation.file,
      'changed',
      FileCodec.encode(
        FileResume(
          transferOrdinal: 1,
          transferId: _Pair.id,
          name: 'different.bin',
          size: 4,
          sha256: _hash([1, 2, 3, 4]),
          chunkBytes: 32768,
          attemptId: 'f' * 32,
        ),
      ),
    );
    final incoming = await pair.receiver.open(
      await pair.sender.sealRequest(changed),
    );
    await expectLater(
      pair.task.resume(incoming),
      throwsA(isA<FileProtocolFailure>()),
    );
    expect(pair.disk.opens, 1);
    expect(pair.disk.resumes, 0);
  });
  test('wrong resume attempt cannot open the append gate', () async {
    await pair.task.start();
    await pair.task.pause();
    final state =
        await pair.task.resume(await pair.resumeRequest()) as FileResumeState;
    final wrong = await pair.signal(
      FileResumeAccept(
        transferId: _Pair.id,
        attemptId: 'f' * 32,
        offset: state.offset,
        prefixSha256: state.prefixSha256,
      ),
    );
    await expectLater(
      pair.task.acceptResume(wrong),
      throwsA(isA<FileProtocolFailure>()),
    );
    expect(pair.task.phase, IncomingFilePhase.failed);
    expect(pair.disk.bytes, isEmpty);
  });
  test(
    'completed receipt survives native metadata cleanup before replay',
    () async {
      await pair.task.start();
      await pair.append([1, 2, 3, 4]);
      await pair.finish();
      await pair.task.cleanup();
      final replay =
          await pair.task.resume(await pair.resumeRequest()) as FileComplete;
      expect(replay.actualName, 'sample (1).bin');
      expect(pair.disk.releases, 1);
      expect(pair.disk.opens, 1);
      expect(pair.disk.commits, 1);
    },
  );
  test('only one resume may own native work', () async {
    await pair.task.start();
    await pair.task.pause();
    final first = await pair.resumeRequest();
    final other = await pair.resumeRequest();
    pair.disk.resumeGate = Completer<void>();
    final pending = pair.task.resume(first);
    await pair.disk.resumeEntered.future;
    await expectLater(
      pair.task.resume(other),
      throwsA(isA<FileProtocolFailure>()),
    );
    expect(pair.disk.opens, 2);
    pair.disk.resumeGate!.complete();
    expect(await pending, isA<FileResumeState>());
  });
  test('revocation after new scope opens stops native prefix rebind', () async {
    await pair.task.start();
    await pair.task.pause();
    pair.disk.resumeGate = Completer<void>();
    final pending = pair.task.resume(await pair.resumeRequest());
    final rejected = expectLater(
      pending,
      throwsA(anyOf(isA<ReceiveAccessFailure>(), isA<SessionFailure>())),
    );
    await pair.disk.resumeEntered.future;
    pair.receiver.revoke();
    expect(pair.disk.modes['scope2'], ReceiveStopMode.cancel);
    pair.disk.resumeGate!.complete();
    await rejected;
    await pair.task.cleanup();
    expect(pair.disk.commits, 0);
  });
  test(
    'interrupted native rebind never reports a resumable checkpoint',
    () async {
      await pair.task.start();
      await pair.task.pause();
      pair.disk.resumeGate = Completer<void>();
      final pending = pair.task.resume(await pair.resumeRequest());
      final rejected = expectLater(
        pending,
        throwsA(anyOf(isA<ReceiveAccessFailure>(), isA<SessionFailure>())),
      );
      await pair.disk.resumeEntered.future;
      expect(await pair.task.pause(), isNull);
      pair.disk.resumeGate!.complete();
      await rejected;
      expect(pair.task.phase, IncomingFilePhase.cancelled);
    },
  );
}

String _hash(List<int> bytes) => hashes.sha256.convert(bytes).toString();

class _Pair {
  static const id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  late GrantEndpoint sender, receiver;
  late LocalSessionRequest local;
  late IncomingFileTransfer task;
  final disk = _Disk();
  int attempt = 0;
  static Future<_Pair> create() async {
    final p = _Pair();
    final binding = GrantBinding(
      id: List.filled(32, 81),
      initiatorKey: List.filled(32, 82),
      receiverKey: List.filled(32, 83),
    );
    GrantEndpoint endpoint(GrantRole role) =>
        GrantEndpoint.fromAuthenticatedPairing(
          binding: binding,
          role: role,
          establishedMicros: 100,
          recoverySecret: List.filled(32, 84),
          clock: () async => 100,
          onInvalidated: () {},
        );
    p.sender = endpoint(GrantRole.initiator);
    p.receiver = endpoint(GrantRole.receiver);
    await p.connect();
    p.local = await p.sender.authorizeLocal(
      SessionOperation.file,
      'original',
      FileCodec.encode(
        FileOffer(
          transferOrdinal: 1,
          transferId: id,
          name: 'sample.bin',
          size: 4,
          sha256: _hash([1, 2, 3, 4]),
          chunkBytes: 32768,
        ),
      ),
    );
    final incoming = await p.receiver.open(await p.sender.sealRequest(p.local));
    p.task = IncomingFileTransfer(
      context: await FileTransferContext.fromRequest(
        GrantRegistry()..register(p.receiver),
        incoming,
      ),
      access: p.disk,
      directory: const ReceiveDirectory(token: 'downloads', label: 'Downloads'),
    );
    return p;
  }

  Future<void> connect() async {
    final hello = await sender.beginResume();
    await receiver.acceptResume(
      await sender.finishResume(await receiver.answerResume(hello)),
    );
  }

  Future<VerifiedSessionMessage> resumeRequest({bool reconnect = false}) async {
    if (reconnect) {
      sender.suspend();
      receiver.suspend();
      await connect();
    }
    local = await sender.authorizeLocal(
      SessionOperation.file,
      'resume-${++attempt}',
      FileCodec.encode(
        FileResume(
          transferOrdinal: 1,
          transferId: id,
          name: 'sample.bin',
          size: 4,
          sha256: _hash([1, 2, 3, 4]),
          chunkBytes: 32768,
          attemptId: attempt.toRadixString(16).padLeft(32, '0'),
        ),
      ),
    );
    return receiver.open(await sender.sealRequest(local));
  }

  Future<VerifiedSessionSignal> signal(FileMessage message) async =>
      receiver.openSignal(
        task.context.authorization,
        await sender.sealSignal(local, FileCodec.encode(message)),
      );
  Future<void> accept(FileResumeState state, {String? hash}) async =>
      task.acceptResume(
        await signal(
          FileResumeAccept(
            transferId: id,
            attemptId: state.attemptId,
            offset: state.offset,
            prefixSha256: hash ?? state.prefixSha256,
          ),
        ),
      );
  Future<FileAck> append(List<int> bytes) async => task.append(
    await signal(FileChunk(transferId: id, offset: task.offset, data: bytes)),
  );
  Future<FileComplete> finish() async => task.finish(
    await signal(
      FileFinish(transferId: id, size: 4, sha256: _hash([1, 2, 3, 4])),
    ),
  );
  Future<void> close() async {
    for (final gate in [disk.resumeGate, disk.openGate]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    disk.failClose = null;
    await task.close();
    sender.revoke();
    receiver.revoke();
  }
}

class _Disk implements ReceiveAccess {
  final bytes = <int>[];
  final modes = <String, ReceiveStopMode?>{};
  final events = <String>[], closedScopes = <String>[];
  int opens = 0, begins = 0, resumes = 0, commits = 0, aborts = 0, releases = 0;
  String? bound, failClose;
  bool aborted = false;
  Completer<void>? resumeGate, openGate;
  final resumeEntered = Completer<void>(), openEntered = Completer<void>();
  @override
  Future<ReceiveScope> openScope({
    required String key,
    required int deadlineMicros,
  }) async {
    final token = 'scope${++opens}';
    if (openGate != null) {
      if (!openEntered.isCompleted) openEntered.complete();
      await openGate!.future;
    }
    modes[token] = null;
    return ReceiveScope(token: token, key: key, deadlineMicros: deadlineMicros);
  }

  @override
  Future<ReceiveStopState> stopScope(
    ReceiveScope scope,
    ReceiveStopMode mode,
  ) async {
    if (modes[scope.token] != ReceiveStopMode.cancel) modes[scope.token] = mode;
    return commits > 0
        ? ReceiveStopState.committed
        : modes[scope.token] == ReceiveStopMode.cancel
        ? ReceiveStopState.cancelled
        : ReceiveStopState.paused;
  }

  @override
  Future<void> closeScope(ReceiveScope scope) async {
    if (failClose == scope.token) throw StateError('native scope close failed');
    events.add('close:${scope.token}');
    closedScopes.add(scope.token);
  }

  @override
  Future<ReceiveFile> begin({
    required ReceiveDirectory directory,
    required ReceiveScope scope,
    required ReceiveMetadata metadata,
  }) async {
    begins++;
    bound = scope.token;
    return ReceiveFile(
      token: 'original-file',
      metadata: metadata,
      key: scope.key,
      deadlineMicros: scope.deadlineMicros,
    );
  }

  void active(ReceiveScope scope) {
    if (aborted || scope.token != bound || modes[scope.token] != null) {
      throw const ReceiveAccessFailure('cancelled');
    }
  }

  @override
  Future<int> append(
    ReceiveFile file,
    ReceiveScope scope,
    int offset,
    Uint8List chunk,
  ) async {
    active(scope);
    expect(offset, bytes.length);
    bytes.addAll(chunk);
    return bytes.length;
  }

  @override
  Future<ReceiveCheckpoint> checkpoint(ReceiveFile file) async =>
      ReceiveCheckpoint(
        offset: bytes.length,
        sha256: _hash(bytes),
        identity: file.token,
      );
  @override
  Future<void> resume(
    ReceiveFile file,
    ReceiveScope scope,
    ReceiveCheckpoint checkpoint,
  ) async {
    resumes++;
    if (!resumeEntered.isCompleted) resumeEntered.complete();
    final old = bound;
    if (resumeGate != null) await resumeGate!.future;
    if (aborted ||
        modes[old] != ReceiveStopMode.pause ||
        modes[scope.token] != null) {
      throw const ReceiveAccessFailure('cancelled');
    }
    if (checkpoint.identity != file.token ||
        checkpoint.offset != bytes.length ||
        checkpoint.sha256 != _hash(bytes)) {
      throw const ReceiveAccessFailure('integrity_mismatch');
    }
    bound = scope.token;
    events.add('resume:${scope.token}');
  }

  @override
  Future<ReceiveReceipt> commit(ReceiveFile file, ReceiveScope scope) async {
    active(scope);
    expect(bytes.length, file.metadata.size);
    expect(_hash(bytes), file.metadata.sha256);
    commits++;
    return ReceiveReceipt(
      name: 'sample (1).bin',
      size: bytes.length,
      sha256: _hash(bytes),
    );
  }

  @override
  Future<void> abort(ReceiveFile file) async {
    aborted = true;
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
