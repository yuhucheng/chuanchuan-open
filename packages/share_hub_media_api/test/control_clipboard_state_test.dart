import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

void main() {
  const a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const c = 'cccccccccccccccccccccccccccccccc';
  final controllerOn = ClipboardSideState(
    revision: 1,
    enabled: true,
    available: true,
  );
  final targetOn = ClipboardSideState(
    revision: 1,
    enabled: true,
    available: true,
  );

  (ClipboardTargetState, ClipboardControllerState) ready({
    String? initial,
    int Function()? clock,
  }) {
    final target = ClipboardTargetState(monotonicMicros: clock);
    final controller = ClipboardControllerState(monotonicMicros: clock);
    final baseline = target.open(
      epoch: 1,
      controllerState: controllerOn,
      targetState: targetOn,
      pictureReady: true,
      initialText: initial,
    );
    controller.acceptReady(
      baseline,
      controllerState: controllerOn,
      targetState: targetOn,
      pictureReady: true,
    );
    return (target, controller);
  }

  test('B wins simultaneous baseline copy; later C survives and converges', () {
    final (target, controller) = ready(initial: 'baseline');
    controller.localCopy('A', updateId: a);
    final proposalA = controller.takeProposal()!;
    expect(proposalA.baseRevision, 1);
    target.localCopy('B');
    final commitB = target.takeCommit()!;
    controller.localCopy('C', updateId: c);
    expect(controller.receiveCommit(commitB), ClipboardApply.retainLocal);
    final conflict = target.receiveProposal(proposalA);
    expect(conflict, isA<ClipboardConflict>());
    expect(
      controller.receiveConflict(conflict as ClipboardConflict),
      ClipboardApply.retainLocal,
    );
    final proposalC = controller.takeProposal()!;
    expect(proposalC.baseRevision, 2);
    expect(proposalC.text, 'C');
    final ticket = target.receiveProposal(proposalC);
    expect(ticket, isA<ClipboardWriteTicket>());
    expect(target.canWrite(ticket as ClipboardWriteTicket), isTrue);
    target.completeWrite(ticket, succeeded: true);
    final commitC = target.takeCommit()!;
    expect(commitC.revision, 3);
    expect(controller.receiveCommit(commitC), ClipboardApply.applyRemote);
    expect(controller.authoritativeText, 'C');
    expect(controller.takeProposal(), isNull);
  });

  test('empty text is a valid baseline; no text format stays distinct', () {
    final (target, controller) = ready();
    expect(target.authoritativeText, isNull);
    expect(controller.authoritativeText, isNull);
    target.localCopy('');
    final empty = target.takeCommit()!;
    expect(empty.text, '');
    expect(controller.receiveCommit(empty), ClipboardApply.applyRemote);
    expect(controller.authoritativeText, '');
  });

  test('setting change invalidates old epoch; focus release does not', () {
    final (target, controller) = ready(initial: 'base');
    controller.localCopy('A', updateId: a);
    final old = controller.takeProposal()!;
    target.inputFocusLost();
    expect(target.receiveProposal(old), isA<ClipboardWriteTicket>());
    final changed = ClipboardSideState(
      revision: 2,
      enabled: false,
      available: true,
    );
    target.settingsChanged(controllerState: changed, targetState: targetOn);
    controller.settingsChanged(controllerState: changed, targetState: targetOn);
    expect(() => target.receiveProposal(old), throwsA(isA<SessionFailure>()));
    final next = target.open(
      epoch: 2,
      controllerState: ClipboardSideState(
        revision: 2,
        enabled: true,
        available: true,
      ),
      targetState: targetOn,
      pictureReady: true,
      initialText: 'B',
    );
    controller.acceptReady(
      next,
      controllerState: ClipboardSideState(
        revision: 2,
        enabled: true,
        available: true,
      ),
      targetState: targetOn,
      pictureReady: true,
    );
    expect(() => target.receiveProposal(old), throwsA(isA<SessionFailure>()));
    expect(controller.authoritativeText, 'B');
  });

  test('proposal becomes stale if local copy arrives before host write', () {
    final (target, controller) = ready(initial: 'base');
    controller.localCopy('A', updateId: a);
    final ticket = target.receiveProposal(controller.takeProposal()!);
    expect(ticket, isA<ClipboardWriteTicket>());
    target.localCopy('B');
    expect(target.canWrite(ticket as ClipboardWriteTicket), isFalse);
    expect(
      () => target.completeWrite(ticket, succeeded: true),
      throwsA(isA<SessionFailure>()),
    );
    expect(target.authoritativeText, 'B');
  });

  test('native sequence conflict makes observed local copy authoritative', () {
    final (target, controller) = ready(initial: 'base');
    controller.localCopy('remote', updateId: a);
    final ticket = target.receiveProposal(
      controller.takeProposal()!,
    ) as ClipboardWriteTicket;
    final conflict = target.nativeConflict(ticket, observedText: 'local');
    expect(target.pendingWrites, 0);
    expect(conflict.current.revision, 2);
    expect(conflict.current.text, 'local');
    expect(controller.receiveConflict(conflict), ClipboardApply.applyRemote);
    expect(controller.authoritativeText, 'local');
    controller.localCopy('newer', updateId: c);
    final next = controller.takeProposal()!;
    expect(next.baseRevision, 2);
    expect(target.receiveProposal(next), isA<ClipboardWriteTicket>());
    expect(
      () => target.nativeConflict(ticket, observedText: 'late'),
      throwsA(isA<SessionFailure>()),
    );
  });

  test('one thousand commits retain no growing update ID history', () {
    var now = 0;
    final (target, controller) = ready(initial: '0', clock: () => now);
    for (var i = 1; i <= 1000; i++) {
      now += 250000;
      target.localCopy('$i');
      final commit = target.takeCommit()!;
      expect(controller.receiveCommit(commit), ClipboardApply.applyRemote);
    }
    expect(target.revision, 1001);
    expect(controller.revision, 1001);
    expect(target.pendingWrites, 0);
    expect(controller.pendingUpdates, 0);
  });

  test(
    'target sends at most two burst updates then coalesces local copies',
    () {
      var now = 0;
      final (target, controller) = ready(initial: 'base', clock: () => now);
      for (final text in ['A', 'B']) {
        target.localCopy(text);
        expect(
          controller.receiveCommit(target.takeCommit()!),
          ClipboardApply.applyRemote,
        );
      }
      target.localCopy('C');
      expect(target.takeCommit(), isNull);
      target.localCopy('D');
      now = 250000;
      final latest = target.takeCommit()!;
      expect(latest.text, 'D');
      expect(latest.revision, 5);
      expect(controller.receiveCommit(latest), ClipboardApply.applyRemote);
      expect(target.takeCommit(), isNull);
    },
  );

  test(
    'controller waits for rate budget without losing newest unsent copy',
    () {
      var now = 0;
      final (target, controller) = ready(initial: 'base', clock: () => now);
      for (final (index, text, id) in [
        (1, 'A', a),
        (2, 'B', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
      ]) {
        controller.localCopy(text, updateId: id);
        final proposal = controller.takeProposal()!;
        expect(proposal.updateSequence, index);
        final ticket = target.receiveProposal(proposal) as ClipboardWriteTicket;
        target.completeWrite(ticket, succeeded: true);
        controller.receiveCommit(target.takeCommit()!);
      }
      controller.localCopy('C', updateId: c);
      expect(controller.takeProposal(), isNull);
      controller.localCopy('D', updateId: 'dddddddddddddddddddddddddddddddd');
      now = 250000;
      final latest = controller.takeProposal()!;
      expect(latest.text, 'D');
      expect(latest.updateSequence, 3);
    },
  );

  test('remote write result is not replaced by a later local copy', () {
    var now = 0;
    final (target, controller) = ready(initial: 'base', clock: () => now);
    for (final text in ['A', 'B']) {
      target.localCopy(text);
      controller.receiveCommit(target.takeCommit()!);
    }
    controller.localCopy('C', updateId: c);
    final ticket = target.receiveProposal(
      controller.takeProposal()!,
    ) as ClipboardWriteTicket;
    target.completeWrite(ticket, succeeded: true);
    target.localCopy('D');
    expect(target.pendingCommits, 2);
    expect(target.takeCommit(), isNull);
    now = 250000;
    final result = target.takeCommit()!;
    expect(result.text, 'C');
    expect(result.sourceUpdateId, c);
    expect(controller.receiveCommit(result), ClipboardApply.applyRemote);
    now = 500000;
    final local = target.takeCommit()!;
    expect(local.text, 'D');
    expect(local.revision, result.revision + 1);
    expect(controller.receiveCommit(local), ClipboardApply.applyRemote);
  });

  test('same update ID with different text cannot become a new edit', () {
    final (target, controller) = ready(initial: 'base');
    controller.localCopy('A', updateId: a);
    final first = controller.takeProposal()!;
    final ticket = target.receiveProposal(first) as ClipboardWriteTicket;
    target.completeWrite(ticket, succeeded: true);
    final forged = ClipboardProposal(
      epoch: 1,
      controllerStateRevision: 1,
      targetStateRevision: 1,
      updateSequence: 2,
      updateId: a,
      baseRevision: 2,
      text: 'different',
    );
    expect(
      () => target.receiveProposal(forged),
      throwsA(
        isA<SessionFailure>().having(
          (failure) => failure.code,
          'code',
          'invalid_message',
        ),
      ),
    );
  });

  test('wrong settings revision and failed host write cannot commit', () {
    final (target, controller) = ready(initial: 'base');
    controller.localCopy('A', updateId: a);
    final proposal = controller.takeProposal()!;
    final wrong = ClipboardProposal(
      epoch: proposal.epoch,
      controllerStateRevision: 2,
      targetStateRevision: proposal.targetStateRevision,
      updateSequence: proposal.updateSequence,
      updateId: proposal.updateId,
      baseRevision: proposal.baseRevision,
      text: proposal.text,
    );
    expect(() => target.receiveProposal(wrong), throwsA(isA<SessionFailure>()));
    final ticket = target.receiveProposal(proposal) as ClipboardWriteTicket;
    expect(
      () => target.completeWrite(ticket, succeeded: false),
      throwsA(isA<SessionFailure>()),
    );
    expect(target.pendingWrites, 0);
    expect(() => target.localCopy('B'), throwsA(isA<SessionFailure>()));
  });

  test('UTF-8 text limit counts bytes and keeps an empty string valid', () {
    final (target, controller) = ready(initial: '');
    expect(target.authoritativeText, '');
    controller.localCopy('中' * 10922, updateId: a);
    expect(controller.takeProposal()!.text.length, 10922);
    expect(
      () => controller.localCopy('中' * 10923, updateId: c),
      throwsA(isA<SessionFailure>()),
    );
  });

  test('off, unavailable or unpresented picture cannot open text sync', () {
    final off = ClipboardSideState(
      revision: 1,
      enabled: false,
      available: true,
    );
    final unavailable = ClipboardSideState(
      revision: 1,
      enabled: true,
      available: false,
    );
    for (final pair in [
      (off, targetOn, true),
      (controllerOn, unavailable, true),
      (controllerOn, targetOn, false),
    ]) {
      final target = ClipboardTargetState();
      expect(
        () => target.open(
          epoch: 1,
          controllerState: pair.$1,
          targetState: pair.$2,
          pictureReady: pair.$3,
          initialText: 'base',
        ),
        throwsA(isA<SessionFailure>()),
      );
    }
  });

  test(
    'picture loss invalidates pending write without changing input epoch',
    () {
      final (target, controller) = ready(initial: 'base');
      controller.localCopy('A', updateId: a);
      final ticket = target.receiveProposal(
        controller.takeProposal()!,
      ) as ClipboardWriteTicket;
      target.pictureLost();
      controller.pictureLost();
      expect(target.canWrite(ticket), isFalse);
      expect(
        () => target.completeWrite(ticket, succeeded: true),
        throwsA(isA<SessionFailure>()),
      );
      expect(controller.pendingUpdates, 0);
    },
  );
}
