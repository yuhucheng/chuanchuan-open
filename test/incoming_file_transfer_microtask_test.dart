import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/transfers/incoming_file_transfer.dart';
import 'package:share_hub_open/features/transfers/receive_access.dart';

void main() {
  test('cancel during post-begin authorization remains cancelled after stop confirms', () async {
    void Function()? afterClock;
    Future<int> clock() async {
      final callback = afterClock;
      afterClock = null;
      callback?.call();
      return 100;
    }

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
          clock: clock,
          onInvalidated: () {},
        );
    final sender = endpoint(GrantRole.initiator);
    final receiver = endpoint(GrantRole.receiver);
    final hello = await sender.beginResume();
    await receiver.acceptResume(
      await sender.finishResume(await receiver.answerResume(hello)),
    );
    final local = await sender.authorizeLocal(
      SessionOperation.file,
      'microtask-receive',
      FileCodec.encode(
        FileOffer(
          transferOrdinal: 1,
          transferId: 'a' * 32,
          name: 'empty.bin',
          size: 0,
          sha256: 'b' * 64,
          chunkBytes: FileLimits.chunkBytes,
        ),
      ),
    );
    final context = await FileTransferContext.fromRequest(
      GrantRegistry()..register(receiver),
      await receiver.open(await sender.sealRequest(local)),
    );
    final storage = _BeginStorage();
    final owner = IncomingFileTransfer(
      context: context,
      access: storage,
      directory: const ReceiveDirectory(token: 'directory', label: 'Test'),
    );
    final cancelled = Completer<void>();
    Future<ReceiveStopState>? stopping;
    storage.onBegin = () {
      afterClock = () {
        // The next clock belongs to start's post-Begin authorization check.
        // Queue cancellation before that async clock result resumes the
        // check. The native stop returns an async confirmation, so start can
        // reject while the owner is still in its truthful stopping phase.
        scheduleMicrotask(() {
          stopping = owner.cancel();
          cancelled.complete();
        });
      };
    };
    FileMessage? accepted;
    Object? failure;
    try {
      await owner.start().then<void>(
        (value) {
          accepted = value;
        },
        onError: (Object error, StackTrace stack) {
          failure = error;
        },
      );
      await cancelled.future;
      expect(await stopping, ReceiveStopState.cancelled);
      expect(accepted, isNull);
      expect(failure, isA<SessionFailure>());
      expect(owner.phase, IncomingFilePhase.cancelled);
      await owner.cleanup();
      expect(storage.releases, 1);
    } finally {
      await owner.close();
      sender.revoke();
      receiver.revoke();
    }
  });
}

final class _BeginStorage implements ReceiveAccess {
  void Function()? onBegin;
  int releases = 0;
  @override
  Future<ReceiveScope> openScope({
    required String key,
    required int deadlineMicros,
  }) async =>
      ReceiveScope(token: 'scope', key: key, deadlineMicros: deadlineMicros);
  @override
  Future<ReceiveFile> begin({
    required ReceiveDirectory directory,
    required ReceiveScope scope,
    required ReceiveMetadata metadata,
  }) async {
    onBegin?.call();
    return ReceiveFile(
      token: 'file',
      metadata: metadata,
      key: scope.key,
      deadlineMicros: scope.deadlineMicros,
    );
  }

  @override
  Future<ReceiveStopState> stopScope(
    ReceiveScope scope,
    ReceiveStopMode mode,
  ) async => ReceiveStopState.cancelled;
  @override
  Future<void> abort(ReceiveFile file) async {}
  @override
  Future<void> retryCleanup(ReceiveFile file) async {}
  @override
  Future<void> release(ReceiveFile file) async {
    releases++;
  }

  @override
  Future<void> closeScope(ReceiveScope scope) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
