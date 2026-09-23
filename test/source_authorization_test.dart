import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/transfers/source_access.dart';
import 'package:share_hub_open/features/transfers/source_authorization.dart';

void main() {
  late GrantEndpoint sender, receiver;
  late GrantRegistry registry;
  late FileTransferContext context;
  late _ScopeAccess access;
  late int now;
  setUp(() async {
    now = 100;
    final binding = GrantBinding(
      id: List.filled(32, 31),
      initiatorKey: List.filled(32, 32),
      receiverKey: List.filled(32, 33),
    );
    GrantEndpoint endpoint(GrantRole role) =>
        GrantEndpoint.fromAuthenticatedPairing(
          binding: binding,
          role: role,
          establishedMicros: now,
          recoverySecret: List.filled(32, 34),
          clock: () async => now,
          onInvalidated: () {},
        );
    sender = endpoint(GrantRole.initiator);
    receiver = endpoint(GrantRole.receiver);
    registry = GrantRegistry()..register(sender);
    final hello = await sender.beginResume();
    await receiver.acceptResume(
      await sender.finishResume(await receiver.answerResume(hello)),
    );
    final request = await sender.authorizeLocal(
      SessionOperation.file,
      'outgoing',
      FileCodec.encode(
        FileOffer(
          transferOrdinal: 1,
          transferId: 'a' * 32,
          name: 'sample.bin',
          size: 1,
          sha256: 'b' * 64,
          chunkBytes: 32768,
        ),
      ),
    );
    context = await FileTransferContext.fromRequest(registry, request);
    access = _ScopeAccess();
  });
  tearDown(() {
    sender.revoke();
    receiver.revoke();
  });
  SourceAuthorization owner() =>
      SourceAuthorization(context, access, fileToken: 'picked');

  test(
    'sealed local authority retains selected token and original deadline',
    () async {
      final auth = owner();
      final scope = await auth.open();
      expect(scope.fileToken, 'picked');
      expect(scope.key, context.transferKey);
      expect(scope.deadlineMicros, context.authorization.expiresMicros);
      expect(identical(scope, await auth.open()), isTrue);
      expect(access.opens, 1);
      await auth.close();
    },
  );
  test('remote request cannot mint a sending scope', () async {
    registry.register(receiver);
    final incoming = await receiver.open(
      await sender.sealRequest(context.authorization as LocalSessionRequest),
    );
    final incomingContext = await FileTransferContext.fromRequest(
      registry,
      incoming,
    );
    expect(
      () => SourceAuthorization(incomingContext, access, fileToken: 'picked'),
      throwsA(isA<SessionFailure>()),
    );
    expect(access.opens, 0);
  });
  test('cancel before opening never creates native capability', () async {
    final auth = owner();
    await auth.stop(SourceStopMode.cancel);
    await expectLater(auth.open(), throwsA(isA<SessionFailure>()));
    expect(access.opens, 0);
    await auth.close();
  });
  test('revocation dispatches native cancel synchronously', () async {
    final auth = owner();
    await auth.open();
    sender.revoke();
    expect(access.modes, [SourceStopMode.cancel]);
    expect(await auth.whenStopped, SourceStopState.cancelled);
    expect(() => auth.requireCurrent(), throwsA(isA<SessionFailure>()));
    await auth.close();
  });
  test('close during open retains and stops the late capability', () async {
    access.openGate = Completer<void>();
    final auth = owner();
    final opening = auth.open();
    final rejected = expectLater(opening, throwsA(isA<SessionFailure>()));
    await access.entered.future;
    final closing = auth.close();
    access.openGate!.complete();
    await rejected;
    await closing;
    expect(access.modes, [SourceStopMode.cancel]);
    expect(access.closes, ['scope-1']);
  });
  test('revocation during scope opening stops late scope', () async {
    access.openGate = Completer<void>();
    final auth = owner();
    final opening = auth.open();
    final rejected = expectLater(opening, throwsA(isA<SessionFailure>()));
    await access.entered.future;
    sender.revoke();
    access.openGate!.complete();
    await rejected;
    await auth.whenStopped;
    expect(access.modes, [SourceStopMode.cancel]);
    await auth.close();
  });
  test('expiry before opening does not allocate native state', () async {
    final auth = owner();
    now = context.authorization.expiresMicros;
    await expectLater(auth.open(), throwsA(isA<SessionFailure>()));
    expect(access.opens, 0);
    await auth.close();
  });
  test(
    'intentional pause precedes suspend and permanent revoke still cancels',
    () async {
      final auth = owner();
      await auth.open();
      await auth.stop(SourceStopMode.pause);
      sender.suspend();
      expect(access.modes, [SourceStopMode.pause]);
      expect(() => auth.requireCurrent(), throwsA(isA<SessionFailure>()));
      sender.revoke();
      await sender.invalidated.drain<void>();
      expect(await auth.whenStopped, SourceStopState.cancelled);
      expect(access.modes, [SourceStopMode.pause, SourceStopMode.cancel]);
      await auth.close();
    },
  );
  test(
    'failed pending pause after suspend escalates to native cancel',
    () async {
      final auth = owner();
      await auth.open();
      access.pauseGate = Completer<void>();
      final pausing = auth.stop(SourceStopMode.pause);
      final rejected = expectLater(pausing, throwsStateError);
      sender.suspend();
      access.pauseGate!.completeError(StateError('pause failed'));
      await rejected;
      expect(await auth.whenStopped, SourceStopState.cancelled);
      expect(access.modes, [SourceStopMode.pause, SourceStopMode.cancel]);
      await auth.close();
    },
  );
  test('cancel preempts pending pause and pause cannot downgrade it', () async {
    final auth = owner();
    await auth.open();
    access.pauseGate = Completer<void>();
    final pending = auth.stop(SourceStopMode.pause);
    expect(await auth.stop(SourceStopMode.cancel), SourceStopState.cancelled);
    access.pauseGate!.complete();
    await pending;
    expect(await auth.stop(SourceStopMode.pause), SourceStopState.cancelled);
    expect(access.modes, [SourceStopMode.pause, SourceStopMode.cancel]);
    await auth.close();
  });
  test(
    'native stop and close failures remain observable and retryable',
    () async {
      final auth = owner();
      await auth.open();
      access.failStop = true;
      sender.revoke();
      await expectLater(auth.whenStopped, throwsStateError);
      access.failStop = false;
      access.failClose = true;
      await expectLater(auth.close(), throwsStateError);
      access.failClose = false;
      await auth.close();
      expect(access.modes, [SourceStopMode.cancel, SourceStopMode.cancel]);
      expect(access.closes, ['scope-1', 'scope-1']);
    },
  );
  test(
    'paused old owner remains alive until original-context rebind succeeds',
    () async {
      final old = owner();
      final original = await old.open();
      await old.stop(SourceStopMode.pause);
      sender.suspend();
      receiver.suspend();
      final hello = await sender.beginResume();
      await receiver.acceptResume(
        await sender.finishResume(await receiver.answerResume(hello)),
      );
      final request = await sender.authorizeLocal(
        SessionOperation.file,
        'resumed',
        FileCodec.encode(
          FileResume(
            transferOrdinal: 1,
            transferId: 'a' * 32,
            attemptId: 'c' * 32,
            name: 'sample.bin',
            size: 1,
            sha256: 'b' * 64,
            chunkBytes: 32768,
          ),
        ),
      );
      final resumed = await context.resumeWith(request);
      final fresh = SourceAuthorization(resumed, access, fileToken: 'picked');
      final replacement = await fresh.open();
      expect(replacement.key, original.key);
      expect(replacement.deadlineMicros, original.deadlineMicros);
      expect(access.closes, isEmpty);
      await old.close();
      expect(access.closes, ['scope-1']);
      await fresh.check();
      await fresh.close();
    },
  );
}

class _ScopeAccess implements SourceAccess {
  int opens = 0;
  bool failStop = false, failClose = false;
  Completer<void>? openGate, pauseGate;
  final entered = Completer<void>();
  final modes = <SourceStopMode>[];
  final closes = <String>[];
  @override
  Future<SourceScope> openScope({
    required String fileToken,
    required String key,
    required int deadlineMicros,
  }) async {
    final id = ++opens;
    if (!entered.isCompleted) entered.complete();
    if (openGate != null) await openGate!.future;
    return SourceScope(
      token: 'scope-$id',
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
    modes.add(mode);
    if (failStop) throw StateError('stop failed');
    if (mode == SourceStopMode.pause && pauseGate != null) {
      await pauseGate!.future;
    }
    return mode == SourceStopMode.pause
        ? SourceStopState.paused
        : SourceStopState.cancelled;
  }

  @override
  Future<void> closeScope(SourceScope scope) async {
    closes.add(scope.token);
    if (failClose) throw StateError('close failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
