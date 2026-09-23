import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

void main() {
  late GrantEndpoint controller, target;
  late GrantRegistry controllerRegistry, targetRegistry;
  Future<int> Function()? clock;
  final start = ControlStart({
    ControlCapability.pointer,
    ControlCapability.textInput,
  });
  setUp(() async {
    clock = null;
    final binding = GrantBinding(
      id: List.filled(32, 1),
      initiatorKey: List.filled(32, 2),
      receiverKey: List.filled(32, 3),
    );
    GrantEndpoint endpoint(GrantRole role) =>
        GrantEndpoint.fromAuthenticatedPairing(
          binding: binding,
          role: role,
          establishedMicros: 0,
          recoverySecret: List.filled(32, 4),
          clock: () => clock?.call() ?? Future.value(0),
          onInvalidated: () {},
        );
    controller = endpoint(GrantRole.initiator);
    target = endpoint(GrantRole.receiver);
    await target.acceptResume(
      await controller.finishResume(
        await target.answerResume(await controller.beginResume()),
      ),
    );
    controllerRegistry = GrantRegistry()..register(controller);
    targetRegistry = GrantRegistry()..register(target);
  });

  Future<(LocalSessionRequest, VerifiedSessionMessage)> requests({
    String id = 'control-1',
    SessionOperation operation = SessionOperation.control,
    String? body,
  }) async {
    final local = await controller.authorizeLocal(
      operation,
      id,
      body ?? start.encode(),
    );
    final remote = await target.open(await controller.sealRequest(local));
    return (local, remote);
  }

  test(
    'authenticated control context retains original deadline and roles',
    () async {
      final (local, remote) = await requests();
      final a = await ControlContext.fromRequest(controllerRegistry, local);
      final b = await ControlContext.fromRequest(targetRegistry, remote);
      expect(a.localIsController, isTrue);
      expect(b.localIsController, isFalse);
      expect(a.authorization, same(local));
      expect(b.authorization.expiresMicros, target.expiresMicros);
      expect(b.start.capabilities, start.capabilities);
      await a.check();
      await b.check();
    },
  );

  for (final operation in [
    SessionOperation.watch,
    SessionOperation.cast,
    SessionOperation.file,
  ]) {
    test(
      '$operation cannot become control by supplying a control body',
      () async {
        final (_, remote) = await requests(operation: operation);
        await expectLater(
          ControlContext.fromRequest(targetRegistry, remote),
          throwsA(isA<SessionFailure>()),
        );
      },
    );
  }

  test(
    'unregistered and opposite local registries reject real authority',
    () async {
      final (local, remote) = await requests();
      await expectLater(
        ControlContext.fromRequest(GrantRegistry(), remote),
        throwsA(isA<SessionFailure>()),
      );
      await expectLater(
        ControlContext.fromRequest(targetRegistry, local),
        throwsA(isA<SessionFailure>()),
      );
    },
  );

  test('receiver cannot create reverse control request', () async {
    await expectLater(
      target.authorizeLocal(
        SessionOperation.control,
        'reverse',
        start.encode(),
      ),
      throwsA(
        isA<SessionFailure>().having((e) => e.code, 'code', 'direction_denied'),
      ),
    );
  });

  test(
    'signals require the exact authority even when operation IDs match',
    () async {
      final (local, remote) = await requests();
      final context = await ControlContext.fromRequest(targetRegistry, remote);
      final (_, anotherRemote) = await requests();
      final signal = await target.openSignal(
        anotherRemote,
        await controller.sealSignal(local, 'sensitive-content'),
      );
      await expectLater(
        context.verifySignal(signal),
        throwsA(
          isA<SessionFailure>().having(
            (e) => e.code,
            'code',
            'foreign_control_signal',
          ),
        ),
      );
    },
  );

  test('current authenticated signals work in both directions without reverse admission', () async {
    final (local, remote) = await requests();
    final a = await ControlContext.fromRequest(controllerRegistry, local);
    final b = await ControlContext.fromRequest(targetRegistry, remote);
    await b.verifySignal(
      await target.openSignal(remote, await controller.sealSignal(local, 'a')),
    );
    await a.verifySignal(
      await controller.openSignal(local, await target.sealSignal(remote, 'b')),
    );
  });

  test(
    'local stop synchronously invalidates context and preserves grant',
    () async {
      final (local, remote) = await requests();
      final context = await ControlContext.fromRequest(targetRegistry, remote);
      final signal = await target.openSignal(
        remote,
        await controller.sealSignal(local, 'a'),
      );
      context.stop();
      context.stop();
      expect(context.requireCurrent, throwsA(isA<SessionFailure>()));
      await expectLater(
        context.verifySignal(signal),
        throwsA(isA<SessionFailure>()),
      );
      expect(target.phase, GrantPhase.active);
      final (_, next) = await requests(id: 'control-2');
      await (await ControlContext.fromRequest(targetRegistry, next)).check();
    },
  );

  test(
    'stop while registry clock check is pending cannot pass final gate',
    () async {
      final (_, remote) = await requests();
      final context = await ControlContext.fromRequest(targetRegistry, remote);
      final gate = Completer<int>();
      clock = () => gate.future;
      final checking = context.check();
      final rejected = expectLater(checking, throwsA(isA<SessionFailure>()));
      context.stop();
      gate.complete(0);
      await rejected;
    },
  );

  test('expiry invalidates current context', () async {
    final (_, remote) = await requests();
    final context = await ControlContext.fromRequest(targetRegistry, remote);
    clock = () async => grantLifetime.inMicroseconds;
    await expectLater(context.check(), throwsA(isA<SessionFailure>()));
  });

  test(
    'revocation during context creation cannot return fresh authority',
    () async {
      final (_, remote) = await requests();
      final gate = Completer<int>();
      clock = () => gate.future;
      final creating = ControlContext.fromRequest(targetRegistry, remote);
      final rejected = expectLater(creating, throwsA(isA<SessionFailure>()));
      targetRegistry.revoke(target);
      gate.complete(0);
      await rejected;
    },
  );

  test(
    'physical suspension immediately rejects old context before recovery',
    () async {
      final (_, remote) = await requests();
      final context = await ControlContext.fromRequest(targetRegistry, remote);
      target.suspend();
      expect(context.requireCurrent, throwsA(isA<SessionFailure>()));
      await expectLater(context.check(), throwsA(isA<SessionFailure>()));
    },
  );

  test(
    'same binding and deadline cannot substitute another local endpoint',
    () async {
      GrantEndpoint replacement(GrantRole role) =>
          GrantEndpoint.fromAuthenticatedPairing(
            binding: target.binding,
            role: role,
            establishedMicros: 0,
            recoverySecret: List.filled(32, 4),
            clock: () async => 0,
            onInvalidated: () {},
          );
      final a = replacement(GrantRole.initiator);
      final b = replacement(GrantRole.receiver);
      await b.acceptResume(
        await a.finishResume(await b.answerResume(await a.beginResume())),
      );
      final impostor = await b.open(
        await a.seal(SessionOperation.control, 'control-1', start.encode()),
      );
      expect(impostor.grant, same(target.binding));
      expect(impostor.expiresMicros, target.expiresMicros);
      await expectLater(
        ControlContext.fromRequest(targetRegistry, impostor),
        throwsA(
          isA<SessionFailure>().having(
            (e) => e.code,
            'code',
            'unknown_local_grant',
          ),
        ),
      );
    },
  );

  test('physical recovery never revives old control context', () async {
    final (_, remote) = await requests();
    final context = await ControlContext.fromRequest(targetRegistry, remote);
    controller.suspend();
    target.suspend();
    await target.acceptResume(
      await controller.finishResume(
        await target.answerResume(await controller.beginResume()),
      ),
    );
    await expectLater(context.check(), throwsA(isA<SessionFailure>()));
    final (_, next) = await requests(id: 'fresh-after-recovery');
    final fresh = await ControlContext.fromRequest(targetRegistry, next);
    expect(fresh.authorization.expiresMicros, remote.expiresMicros);
    await fresh.check();
  });

  test(
    'max Unicode and escape-heavy text survive real authenticated framing',
    () async {
      final (local, remote) = await requests();
      final a = await ControlContext.fromRequest(controllerRegistry, local);
      final b = await ControlContext.fromRequest(targetRegistry, remote);
      var sequence = 0;
      for (final text in [
        '\u0000' * 8192,
        '🙂' * 2048,
        '${'中' * 2730}ab',
        '"\\\n\t' * 2048,
      ]) {
        final input = ControlTextInput(
          sequence: ++sequence,
          inputEpoch: 1,
          geometryRevision: 1,
          text: text,
        );
        a.validateOutgoingInput(input);
        final envelope = await controller.sealSignal(
          local,
          ControlInputCodec.encode(input),
        );
        expect(envelope.ciphertext.length, lessThanOrEqualTo(65536));
        final received = await b.decodeInput(
          await target.openSignal(remote, envelope),
        );
        expect((received as ControlTextInput).text, text);
      }
    },
  );

  test('target cannot submit input in the reverse direction', () async {
    final (local, remote) = await requests();
    final a = await ControlContext.fromRequest(controllerRegistry, local);
    final b = await ControlContext.fromRequest(targetRegistry, remote);
    final input = ControlPointerMove(
      sequence: 1,
      inputEpoch: 1,
      geometryRevision: 1,
      x: 0,
      y: 0,
    );
    expect(
      () => b.validateOutgoingInput(input),
      throwsA(isA<SessionFailure>()),
    );
    final signal = await controller.openSignal(
      local,
      await target.sealSignal(remote, ControlInputCodec.encode(input)),
    );
    await expectLater(
      a.decodeInput(signal),
      throwsA(
        isA<SessionFailure>().having((e) => e.code, 'code', 'direction_denied'),
      ),
    );
  });

  test(
    'unrequested input capability fails even with current control authority',
    () async {
      final (local, remote) = await requests();
      final a = await ControlContext.fromRequest(controllerRegistry, local);
      final b = await ControlContext.fromRequest(targetRegistry, remote);
      final input = ControlWheel(
        sequence: 1,
        inputEpoch: 1,
        geometryRevision: 1,
        x: 0,
        y: 0,
        deltaX: 1,
        deltaY: 0,
      );
      expect(
        () => a.validateOutgoingInput(input),
        throwsA(isA<SessionFailure>()),
      );
      final signal = await target.openSignal(
        remote,
        await controller.sealSignal(local, ControlInputCodec.encode(input)),
      );
      await expectLater(b.decodeInput(signal), throwsA(isA<SessionFailure>()));
    },
  );
  test(
    'local stop permits only terminal stages with current authority',
    () async {
      final (local, remote) = await requests();
      final a = await ControlContext.fromRequest(controllerRegistry, local);
      final b = await ControlContext.fromRequest(targetRegistry, remote);
      b.stop();
      b.validateOutgoingStage(const ControlStopped());
      expect(
        () => b.validateOutgoingStage(
          ControlInputReady(geometryRevision: 1, inputEpoch: 1),
        ),
        throwsA(isA<SessionFailure>()),
      );
      final ack = await controller.openSignal(
        local,
        await target.sealSignal(
          remote,
          ControlStageCodec.encode(const ControlStopped()),
        ),
      );
      expect(await a.decodeStage(ack), isA<ControlStopped>());
      a.stop();
      final stopSignal = await target.openSignal(
        remote,
        await controller.sealSignal(
          local,
          ControlStageCodec.encode(const ControlStop()),
        ),
      );
      expect(await b.decodeStage(stopSignal), isA<ControlStop>());
      expect(
        () => a.validateOutgoingStage(
          ControlGeometryReady(
            sourceToken: 'a' * 32,
            geometryRevision: 1,
            mediaRevision: 1,
          ),
        ),
        throwsA(isA<SessionFailure>()),
      );
    },
  );

  test(
    'stopped context rejects a terminal signal after grant revocation',
    () async {
      final (local, remote) = await requests();
      final context = await ControlContext.fromRequest(targetRegistry, remote);
      final signal = await target.openSignal(
        remote,
        await controller.sealSignal(
          local,
          ControlStageCodec.encode(const ControlStop()),
        ),
      );
      context.stop();
      targetRegistry.revoke(target);
      await expectLater(
        context.decodeStage(signal),
        throwsA(isA<SessionFailure>()),
      );
    },
  );

  test(
    'geometry and readiness signals have authenticated fixed roles',
    () async {
      final (local, remote) = await requests();
      final a = await ControlContext.fromRequest(controllerRegistry, local);
      final b = await ControlContext.fromRequest(targetRegistry, remote);
      final ready = ControlGeometryReady(
        sourceToken: 'a' * 32,
        geometryRevision: 1,
        mediaRevision: 1,
      );
      a.validateOutgoingStage(ready);
      expect(
        () => b.validateOutgoingStage(ready),
        throwsA(isA<SessionFailure>()),
      );
      final wrong = await controller.openSignal(
        local,
        await target.sealSignal(remote, ControlStageCodec.encode(ready)),
      );
      await expectLater(
        a.decodeStage(wrong),
        throwsA(
          isA<SessionFailure>().having(
            (e) => e.code,
            'code',
            'direction_denied',
          ),
        ),
      );
      final signal = await target.openSignal(
        remote,
        await controller.sealSignal(local, ControlStageCodec.encode(ready)),
      );
      expect(await b.decodeStage(signal), isA<ControlGeometryReady>());
      final message = ControlInputReady(geometryRevision: 1, inputEpoch: 1);
      b.validateOutgoingStage(message);
      expect(
        () => a.validateOutgoingStage(message),
        throwsA(isA<SessionFailure>()),
      );
    },
  );

  test(
    'clipboard wire keeps exact control authority and fixed roles',
    () async {
      final body = ControlStart({ControlCapability.clipboardText}).encode();
      final (local, remote) = await requests(body: body);
      final a = await ControlContext.fromRequest(controllerRegistry, local);
      final b = await ControlContext.fromRequest(targetRegistry, remote);
      final proposal = ClipboardProposal(
        epoch: 1,
        controllerStateRevision: 1,
        targetStateRevision: 1,
        updateSequence: 1,
        updateId: 'a' * 32,
        baseRevision: 1,
        text: '中' * 10922,
      );
      a.validateOutgoingClipboard(proposal);
      expect(
        () => b.validateOutgoingClipboard(proposal),
        throwsA(isA<SessionFailure>()),
      );
      final envelope = await controller.sealSignal(
        local,
        ControlClipboardCodec.encode(proposal),
      );
      expect(envelope.ciphertext.length, lessThanOrEqualTo(65536));
      final received = await b.decodeClipboard(
        await target.openSignal(remote, envelope),
      );
      expect((received as ClipboardProposal).text, proposal.text);
      final forged = await controller.openSignal(
        local,
        await target.sealSignal(remote, ControlClipboardCodec.encode(proposal)),
      );
      await expectLater(
        a.decodeClipboard(forged),
        throwsA(isA<SessionFailure>()),
      );
      final commit = ClipboardCommit(
        epoch: 1,
        controllerStateRevision: 1,
        targetStateRevision: 1,
        revision: 2,
        text: 'done',
        sourceUpdateId: proposal.updateId,
      );
      b.validateOutgoingClipboard(commit);
      expect(
        () => a.validateOutgoingClipboard(commit),
        throwsA(isA<SessionFailure>()),
      );
      final state = ClipboardSideState(
        revision: 1,
        enabled: true,
        available: true,
      );
      a.validateOutgoingClipboard(state);
      b.validateOutgoingClipboard(state);
      final (otherLocal, _) = await requests(id: 'without-clipboard');
      final other = await ControlContext.fromRequest(
        controllerRegistry,
        otherLocal,
      );
      expect(
        () => other.validateOutgoingClipboard(state),
        throwsA(isA<SessionFailure>()),
      );
    },
  );
}
