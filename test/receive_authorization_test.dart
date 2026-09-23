import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/transfers/receive_access.dart';
import 'package:share_hub_open/features/transfers/receive_authorization.dart';

void main() {
  late GrantEndpoint sender, receiver;
  late GrantRegistry registry;
  late FileTransferContext context;
  late _ScopeAccess access;
  late int now;
  setUp(() async {
    now = 100;
    final binding = GrantBinding(
      id: List.filled(32, 21),
      initiatorKey: List.filled(32, 22),
      receiverKey: List.filled(32, 23),
    );
    GrantEndpoint endpoint(GrantRole role) =>
        GrantEndpoint.fromAuthenticatedPairing(
          binding: binding,
          role: role,
          establishedMicros: now,
          recoverySecret: List.filled(32, 24),
          clock: () async => now,
          onInvalidated: () {},
        );
    sender = endpoint(GrantRole.initiator);
    receiver = endpoint(GrantRole.receiver);
    registry = GrantRegistry()..register(receiver);
    final hello = await sender.beginResume();
    await receiver.acceptResume(
      await sender.finishResume(await receiver.answerResume(hello)),
    );
    final request = await sender.authorizeLocal(
      SessionOperation.file,
      'incoming',
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
    final incoming = await receiver.open(await sender.sealRequest(request));
    context = await FileTransferContext.fromRequest(registry, incoming);
    access = _ScopeAccess();
  });
  tearDown(() {
    sender.revoke();
    receiver.revoke();
  });

  test(
    'incoming sealed authority opens native scope with original deadline',
    () async {
      final owner = ReceiveAuthorization(context, access);
      final scope = await owner.open();
      expect(scope.key, context.transferKey);
      expect(scope.deadlineMicros, context.authorization.expiresMicros);
      expect(access.opens, 1);
      await owner.check();
      owner.requireCurrent();
      await owner.close();
    },
  );
  test(
    'revocation immediately starts native stop independent of queued disk work',
    () async {
      final owner = ReceiveAuthorization(context, access);
      await owner.open();
      receiver.revoke();
      await owner.whenStopped;
      expect(access.modes, [ReceiveStopMode.cancel]);
      await expectLater(owner.check(), throwsA(isA<SessionFailure>()));
      await owner.close();
      expect(access.closes, 1);
    },
  );
  test('cancellation before open allocates no native capability', () async {
    final owner = ReceiveAuthorization(context, access);
    await owner.stop(ReceiveStopMode.cancel);
    await expectLater(owner.open(), throwsA(isA<SessionFailure>()));
    expect(access.opens, 0);
    await owner.close();
  });
  test(
    'revocation while native scope is opening stops and closes late capability',
    () async {
      access.gate = Completer<void>();
      final owner = ReceiveAuthorization(context, access);
      final opening = owner.open();
      final rejected = expectLater(opening, throwsA(isA<SessionFailure>()));
      await access.entered.future;
      receiver.revoke();
      access.gate!.complete();
      await rejected;
      await owner.whenStopped;
      expect(access.modes, [ReceiveStopMode.cancel]);
      await owner.close();
      expect(access.closes, 1);
    },
  );
  test(
    'intentional pause survives transport invalidation but cannot execute I/O',
    () async {
      final owner = ReceiveAuthorization(context, access);
      await owner.open();
      await owner.stop(ReceiveStopMode.pause);
      receiver.suspend();
      expect(access.modes, [ReceiveStopMode.pause]);
      expect(() => owner.requireCurrent(), throwsA(isA<SessionFailure>()));
      await owner.close();
      expect(access.modes, [ReceiveStopMode.pause, ReceiveStopMode.cancel]);
    },
  );
  test('permanent revocation cancels an intentionally paused scope', () async {
    final owner = ReceiveAuthorization(context, access);
    await owner.open();
    await owner.stop(ReceiveStopMode.pause);
    receiver.revoke();
    await receiver.invalidated.drain<void>();
    expect(await owner.whenStopped, ReceiveStopState.cancelled);
    expect(access.modes, [ReceiveStopMode.pause, ReceiveStopMode.cancel]);
    expect(() => owner.requireCurrent(), throwsA(isA<SessionFailure>()));
    await owner.close();
  });
  test(
    'pause failure after suspension immediately escalates to cancel',
    () async {
      final owner = ReceiveAuthorization(context, access);
      await owner.open();
      access.pauseGate = Completer<void>();
      final pausing = owner.stop(ReceiveStopMode.pause);
      final failure = expectLater(pausing, throwsStateError);
      receiver.suspend();
      access.pauseGate!.completeError(StateError('pause failed'));
      await failure;
      expect(await owner.whenStopped, ReceiveStopState.cancelled);
      expect(access.modes, [ReceiveStopMode.pause, ReceiveStopMode.cancel]);
      await owner.close();
    },
  );
  test('suspension after failed pause dispatch retries as cancel', () async {
    final owner = ReceiveAuthorization(context, access);
    await owner.open();
    access.failPause = true;
    await expectLater(owner.stop(ReceiveStopMode.pause), throwsStateError);
    receiver.suspend();
    expect(await owner.whenStopped, ReceiveStopState.cancelled);
    expect(access.modes, [ReceiveStopMode.pause, ReceiveStopMode.cancel]);
    await owner.close();
  });
  test('successful pending pause keeps suspended scope recoverable', () async {
    final owner = ReceiveAuthorization(context, access);
    await owner.open();
    access.pauseGate = Completer<void>();
    final pausing = owner.stop(ReceiveStopMode.pause);
    receiver.suspend();
    access.pauseGate!.complete();
    expect(await pausing, ReceiveStopState.paused);
    expect(await owner.whenStopped, ReceiveStopState.paused);
    expect(access.modes, [ReceiveStopMode.pause]);
    await owner.close();
  });
  test(
    'revocation during pending pause preserves admitted publication',
    () async {
      final owner = ReceiveAuthorization(context, access);
      await owner.open();
      access.pauseGate = Completer<void>();
      access.stopState = ReceiveStopState.committing;
      final pausing = owner.stop(ReceiveStopMode.pause);
      try {
        receiver.revoke();
        await receiver.invalidated.drain<void>();
        expect(access.modes, [ReceiveStopMode.pause, ReceiveStopMode.cancel]);
        expect(await owner.whenStopped, ReceiveStopState.committing);
      } finally {
        access.pauseGate!.complete();
        await pausing;
        await owner.close();
      }
    },
  );
  test('expiry before open does not allocate a native scope', () async {
    final owner = ReceiveAuthorization(context, access);
    now = context.authorization.expiresMicros;
    await expectLater(owner.open(), throwsA(isA<SessionFailure>()));
    await owner.close();
    expect(access.opens, 0);
  });
  test('local authority cannot mint a receiving disk capability', () async {
    registry.register(sender);
    final local = await sender.authorizeLocal(
      SessionOperation.file,
      'local',
      FileCodec.encode(context.request),
    );
    final outgoing = await FileTransferContext.fromRequest(registry, local);
    expect(
      () => ReceiveAuthorization(outgoing, access),
      throwsA(isA<SessionFailure>()),
    );
    expect(access.opens, 0);
  });
  test('native stop failure is observable and close retries it', () async {
    final owner = ReceiveAuthorization(context, access);
    await owner.open();
    access.failStop = true;
    receiver.revoke();
    await expectLater(owner.whenStopped, throwsStateError);
    expect(() => owner.requireCurrent(), throwsA(isA<SessionFailure>()));
    access.failStop = false;
    await owner.close();
    expect(access.modes, [ReceiveStopMode.cancel, ReceiveStopMode.cancel]);
    expect(access.closes, 1);
  });
  test(
    'cancel does not wait behind pending pause or downgrade its barrier',
    () async {
      final owner = ReceiveAuthorization(context, access);
      await owner.open();
      access.pauseGate = Completer<void>();
      final pause = owner.stop(ReceiveStopMode.pause);
      expect(
        await owner.stop(ReceiveStopMode.cancel),
        ReceiveStopState.cancelled,
      );
      expect(access.modes, [ReceiveStopMode.pause, ReceiveStopMode.cancel]);
      access.pauseGate!.complete();
      await pause;
      expect(
        await owner.stop(ReceiveStopMode.pause),
        ReceiveStopState.cancelled,
      );
      expect(access.modes.length, 2);
      await owner.close();
    },
  );
  test(
    'publication already admitted remains committing when stopped',
    () async {
      final owner = ReceiveAuthorization(context, access);
      await owner.open();
      access.stopState = ReceiveStopState.committing;
      expect(
        await owner.stop(ReceiveStopMode.cancel),
        ReceiveStopState.committing,
      );
      expect(await owner.whenStopped, ReceiveStopState.committing);
      await owner.close();
    },
  );
  test(
    'native close failure remains retryable and never returns a usable scope',
    () async {
      final owner = ReceiveAuthorization(context, access);
      await owner.open();
      access.failClose = true;
      await expectLater(owner.close(), throwsStateError);
      expect(() => owner.requireCurrent(), throwsA(isA<SessionFailure>()));
      access.failClose = false;
      await owner.close();
      expect(access.closes, 2);
    },
  );
}

class _ScopeAccess implements ReceiveAccess {
  int opens = 0, closes = 0;
  bool failClose = false, failStop = false, failPause = false;
  Completer<void>? gate;
  Completer<void>? pauseGate;
  ReceiveStopState? stopState;
  final entered = Completer<void>();
  final modes = <ReceiveStopMode>[];
  @override
  Future<ReceiveScope> openScope({
    required String key,
    required int deadlineMicros,
  }) async {
    opens++;
    entered.complete();
    if (gate != null) await gate!.future;
    return ReceiveScope(
      token: 'native-scope',
      key: key,
      deadlineMicros: deadlineMicros,
    );
  }

  @override
  Future<ReceiveStopState> stopScope(
    ReceiveScope scope,
    ReceiveStopMode mode,
  ) async {
    modes.add(mode);
    if (failStop) throw StateError('stop failed');
    if (failPause && mode == ReceiveStopMode.pause) {
      throw StateError('pause failed');
    }
    if (mode == ReceiveStopMode.pause && pauseGate != null) {
      await pauseGate!.future;
    }
    if (stopState != null) return stopState!;
    return mode == ReceiveStopMode.pause
        ? ReceiveStopState.paused
        : ReceiveStopState.cancelled;
  }

  @override
  Future<void> closeScope(ReceiveScope scope) async {
    closes++;
    if (failClose) throw StateError('close failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
