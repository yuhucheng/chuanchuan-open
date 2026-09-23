import 'dart:async';

import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

void main() {
  late int now, stoppedA, stoppedB;
  late GrantEndpoint a, b;
  late GrantBinding binding;
  GrantEndpoint endpoint(
    GrantRole role, {
    List<int>? root,
    GrantBinding? other,
    Future<int> Function()? clock,
  }) => GrantEndpoint.fromAuthenticatedPairing(
    binding: other ?? binding,
    role: role,
    establishedMicros: 100,
    recoverySecret: root ?? List.filled(32, 7),
    clock: clock ?? () async => now,
    onInvalidated: () {
      if (role == GrantRole.initiator) {
        stoppedA++;
      } else {
        stoppedB++;
      }
    },
  );
  Future<void> resume() async {
    final hello = await a.beginResume();
    final response = await b.answerResume(hello);
    final finish = await a.finishResume(response);
    await b.acceptResume(finish);
  }

  setUp(() {
    now = 100;
    stoppedA = stoppedB = 0;
    binding = GrantBinding(
      id: List.filled(32, 1),
      initiatorKey: List.filled(32, 2),
      receiverKey: List.filled(32, 3),
    );
    a = endpoint(GrantRole.initiator);
    b = endpoint(GrantRole.receiver);
  });
  test(
    'grant profile is extensible; type and lifetime are authenticated',
    () async {
      final policy = GrantPolicy(
        type: 'test-session',
        lifetime: const Duration(minutes: 15),
      );
      final custom = GrantBinding(
        id: binding.id,
        initiatorKey: binding.initiatorKey,
        receiverKey: binding.receiverKey,
        policy: policy,
      );
      a = endpoint(GrantRole.initiator, other: custom);
      b = endpoint(GrantRole.receiver, other: custom);
      await resume();
      expect(a.binding.policy.type, 'test-session');
      expect(a.expiresMicros, 100 + policy.lifetime.inMicroseconds);
      expect(GrantPolicy.shortCode.lifetime, const Duration(hours: 8));
      now = a.expiresMicros;
      await expectLater(a.checkValidity(), throwsA(isA<SessionFailure>()));
    },
  );
  test('mismatched profile type or duration fails mutual possession', () async {
    for (final policy in [
      const GrantPolicy(type: 'other-profile', lifetime: Duration(hours: 8)),
      const GrantPolicy(type: 'short-code', lifetime: Duration(hours: 1)),
    ]) {
      a = endpoint(GrantRole.initiator);
      b = endpoint(
        GrantRole.receiver,
        other: GrantBinding(
          id: binding.id,
          initiatorKey: binding.initiatorKey,
          receiverKey: binding.receiverKey,
          policy: policy,
        ),
      );
      final hello = await a.beginResume();
      await expectLater(
        a.finishResume(await b.answerResume(hello)),
        throwsA(isA<SessionFailure>()),
      );
    }
  });
  test(
    'signaling is bidirectional within the original authorized operation',
    () async {
      await resume();
      final local = await a.authorizeLocal(
        SessionOperation.watch,
        'screen',
        '',
      );
      final remote = await b.open(
        await a.seal(SessionOperation.watch, 'screen', ''),
      );
      final reply = await a.openSignal(
        local,
        await b.sealSignal(remote, 'answer'),
      );
      expect(reply.body, 'answer');
      final update = await b.openSignal(
        remote,
        await a.sealSignal(local, 'candidate'),
      );
      expect(update.body, 'candidate');
      await expectLater(
        b.seal(SessionOperation.watch, 'reverse', ''),
        throwsA(isA<SessionFailure>()),
      );
      b.revoke();
      await expectLater(update.check(), throwsA(isA<SessionFailure>()));
    },
  );
  test(
    'native adapter receives only the exact registered live endpoint',
    () async {
      await resume();
      final registry = GrantRegistry()..register(a);
      final request = await a.authorizeLocal(
        SessionOperation.watch,
        'native-adapter',
        '',
      );
      GrantEndpoint? seen;
      await registry.withVerifiedEndpoint(request, (endpoint) {
        request.requireCurrent();
        seen = endpoint;
      });
      expect(seen, same(a));
      expect(seen?.binding, same(binding));

      // Identical public binding bytes are insufficient: membership is by the
      // authenticated endpoint instance that minted this sealed request.
      final foreign = GrantRegistry()..register(endpoint(GrantRole.initiator));
      await expectLater(
        foreign.withVerifiedEndpoint(request, (_) => fail('foreign import')),
        throwsA(isA<SessionFailure>()),
      );
      registry.revoke(a);
      await expectLater(
        registry.withVerifiedEndpoint(request, (_) => fail('revoked import')),
        throwsA(isA<SessionFailure>()),
      );
    },
  );
  test(
    'native endpoint handoff rejects revocation during clock verification',
    () async {
      Completer<int>? pending;
      a = endpoint(
        GrantRole.initiator,
        clock: () => pending?.future ?? Future.value(now),
      );
      await resume();
      final request = await a.authorizeLocal(
        SessionOperation.watch,
        'late-native-adapter',
        '',
      );
      final registry = GrantRegistry()..register(a);
      pending = Completer<int>();
      var imported = false;
      final handoff = registry.withVerifiedEndpoint(request, (_) {
        imported = true;
      });
      final rejected = expectLater(handoff, throwsA(isA<SessionFailure>()));
      a.suspend();
      pending.complete(now);
      await rejected;
      expect(imported, false);
    },
  );
  test(
    'native clock sample rejects a transient rollback before conversion',
    () async {
      var sample = now;
      a = endpoint(GrantRole.initiator, clock: () async => sample);
      await resume();
      final request = await a.authorizeLocal(
        SessionOperation.watch,
        'native-clock',
        '',
      );
      expect(await request.readCurrentMicros(), now);
      sample = now - 1;
      await expectLater(
        request.readCurrentMicros(),
        throwsA(isA<SessionFailure>()),
      );
      expect(a.phase, GrantPhase.revoked);
      sample = now;
      await expectLater(
        request.readCurrentMicros(),
        throwsA(isA<SessionFailure>()),
      );
    },
  );
  test(
    'signal cannot be used as a start request or in another operation',
    () async {
      await resume();
      final local = await a.authorizeLocal(SessionOperation.watch, 'one', '');
      final other = await a.authorizeLocal(SessionOperation.watch, 'two', '');
      final remote = await b.open(
        await a.seal(SessionOperation.watch, 'one', ''),
      );
      final envelope = await b.sealSignal(remote, 'answer');
      await expectLater(a.open(envelope), throwsA(isA<SessionFailure>()));
      await expectLater(
        a.openSignal(other, envelope),
        throwsA(isA<SessionFailure>()),
      );
      final signal = await a.openSignal(local, envelope);
      expect(signal.body, 'answer');
      await expectLater(
        a.openSignal(local, envelope),
        throwsA(isA<SessionFailure>()),
      );
    },
  );
  test(
    'foreign and previous transport authorities cannot send signals',
    () async {
      await resume();
      final local = await a.authorizeLocal(SessionOperation.cast, 'one', '');
      final remote = await b.open(
        await a.seal(SessionOperation.cast, 'one', ''),
      );
      await expectLater(
        b.sealSignal(local, 'foreign'),
        throwsA(isA<SessionFailure>()),
      );
      final old = await b.sealSignal(remote, 'old-answer');
      a.suspend();
      b.suspend();
      await resume();
      await expectLater(
        b.sealSignal(remote, 'old-permit'),
        throwsA(isA<SessionFailure>()),
      );
      final fresh = await a.authorizeLocal(SessionOperation.cast, 'one', '');
      await expectLater(
        a.openSignal(fresh, old),
        throwsA(isA<SessionFailure>()),
      );
    },
  );
  test(
    'mutual possession, directions and immutable original deadline',
    () async {
      await resume();
      expect(a.phase, GrantPhase.active);
      expect(b.phase, GrantPhase.active);
      for (final operation in SessionOperation.values) {
        final message = await b.open(
          await a.seal(operation, 'media-1', 'payload'),
        );
        expect(message.operation, operation);
        expect(message.sender, GrantRole.initiator);
        await message.check();
      }
      for (final operation in [
        SessionOperation.watch,
        SessionOperation.control,
        SessionOperation.cast,
      ]) {
        await expectLater(
          b.seal(operation, 'reverse', ''),
          throwsA(isA<SessionFailure>()),
        );
      }
      expect(
        (await a.open(await b.seal(SessionOperation.file, 'f', ''))).sender,
        GrantRole.receiver,
      );
      final deadline = a.expiresMicros;
      a.suspend();
      b.suspend();
      now += 10000;
      await resume();
      expect(a.expiresMicros, deadline);
      expect(b.expiresMicros, deadline);
    },
  );
  test('second grant provides independent reverse authorization', () async {
    final reverse = GrantBinding(
      id: List.filled(32, 4),
      initiatorKey: binding.receiverKey,
      receiverKey: binding.initiatorKey,
    );
    a = endpoint(GrantRole.initiator, other: reverse);
    b = endpoint(GrantRole.receiver, other: reverse);
    await resume();
    final message = await b.open(
      await a.seal(SessionOperation.control, 'reverse', ''),
    );
    expect(message.grant.initiatorKey, binding.receiverKey);
  });
  test('fresh keys reject old ciphertext even with forged new generation and sequence', () async {
    await resume();
    final old = await a.seal(SessionOperation.watch, 'm', '');
    final permit = await b.open(old);
    await expectLater(b.open(old), throwsA(isA<SessionFailure>()));
    a.suspend();
    b.suspend();
    await resume();
    expect(a.generation, 2);
    expect(permit.transportGeneration, 1);
    await expectLater(permit.check(), throwsA(isA<SessionFailure>()));
    await expectLater(b.open(old), throwsA(isA<SessionFailure>()));
    await expectLater(
      b.open(
        SessionEnvelope(
          generation: 2,
          sequence: 0,
          ciphertext: old.ciphertext,
          mac: old.mac,
        ),
      ),
      throwsA(anything),
    );
    expect(
      (await b.open(await a.seal(SessionOperation.watch, 'new', ''))).sessionId,
      'new',
    );
  });
  test(
    'replay response, reflection and changed identity cannot prove possession',
    () async {
      final hello = await a.beginResume();
      final response = await b.answerResume(hello);
      await expectLater(
        b.acceptResume(ResumeFinish(response.proof)),
        throwsA(isA<SessionFailure>()),
      );
      final finish = await a.finishResume(response);
      await b.acceptResume(finish);
      await expectLater(b.acceptResume(finish), throwsA(isA<SessionFailure>()));
      a.suspend();
      b.suspend();
      await a.beginResume();
      await expectLater(
        a.finishResume(response),
        throwsA(isA<SessionFailure>()),
      );
      a.suspend();
      b = endpoint(
        GrantRole.receiver,
        other: GrantBinding(
          id: binding.id,
          initiatorKey: binding.initiatorKey,
          receiverKey: List.filled(32, 4),
        ),
      );
      final changed = await b.answerResume(await a.beginResume());
      await expectLater(
        a.finishResume(changed),
        throwsA(isA<SessionFailure>()),
      );
    },
  );
  test(
    'different secret and post-restart registry cannot restore grant',
    () async {
      b = endpoint(GrantRole.receiver, root: List.filled(32, 8));
      final response = await b.answerResume(await a.beginResume());
      await expectLater(
        a.finishResume(response),
        throwsA(isA<SessionFailure>()),
      );
      a.revoke();
      b.revoke();
      await expectLater(a.beginResume(), throwsA(isA<SessionFailure>()));
      await expectLater(
        b.answerResume(response.hello),
        throwsA(isA<SessionFailure>()),
      );
    },
  );
  test('off/on cannot resurrect in-flight recovery', () async {
    final hello = await a.beginResume();
    final response = await b.answerResume(hello);
    final work = a.finishResume(response);
    a.revoke();
    a.suspend();
    await expectLater(work, throwsA(isA<SessionFailure>()));
    expect(a.phase, GrantPhase.revoked);
    expect(stoppedA, 1);
  });
  test('revocation while clock read waits blocks permit and resume', () async {
    await resume();
    final permit = await b.open(await a.seal(SessionOperation.watch, 'm', ''));
    b.revoke();
    await expectLater(permit.check(), throwsA(isA<SessionFailure>()));
    final gate = Completer<int>();
    a = endpoint(GrantRole.initiator, clock: () => gate.future);
    final work = a.beginResume();
    a.revoke();
    gate.complete(now);
    await expectLater(work, throwsA(isA<SessionFailure>()));
    expect(a.phase, GrantPhase.revoked);
  });
  test('sleep reaches exact eight-hour deadline and invalidates ongoing operations', () async {
    await resume();
    final permit = await b.open(await a.seal(SessionOperation.watch, 'm', ''));
    now = b.expiresMicros;
    await expectLater(permit.check(), throwsA(isA<SessionFailure>()));
    expect(b.phase, GrantPhase.revoked);
    expect(stoppedB, 1);
    a.suspend();
    await expectLater(a.beginResume(), throwsA(isA<SessionFailure>()));
  });
  test('clock rollback and clock failure fail closed', () async {
    await resume();
    now = 99;
    await expectLater(a.checkValidity(), throwsA(isA<SessionFailure>()));
    expect(a.phase, GrantPhase.revoked);
    b = endpoint(
      GrantRole.receiver,
      clock: () async => throw StateError('clock'),
    );
    await expectLater(b.checkValidity(), throwsStateError);
    expect(b.phase, GrantPhase.revoked);
  });
  test('concurrent attempts cannot overwrite the live challenge', () async {
    final first = a.beginResume();
    await expectLater(a.beginResume(), throwsA(isA<SessionFailure>()));
    final response = await b.answerResume(await first);
    final finish = await a.finishResume(response);
    await b.acceptResume(finish);
  });
  test('receive attempts serialize sequence consumption', () async {
    await resume();
    final frame = await a.seal(SessionOperation.watch, 'm', '');
    final first = b.open(frame);
    await expectLater(b.open(frame), throwsA(isA<SessionFailure>()));
    await first;
    await expectLater(b.open(frame), throwsA(isA<SessionFailure>()));
  });
  for (final lateFailure in [false, true]) {
    test(
      'old epoch clock ${lateFailure ? "failure" : "rollback"} cannot revoke a recovered grant',
      () async {
        Completer<int>? pending;
        a = endpoint(
          GrantRole.initiator,
          clock: () => pending?.future ?? Future.value(now),
        );
        await resume();
        final old = await a.authorizeLocal(SessionOperation.watch, 'old', '');
        pending = Completer<int>();
        final check = old.check();
        final rejected = expectLater(check, throwsA(isA<SessionFailure>()));
        final blocked = pending;
        pending = null;
        a.suspend();
        b.suspend();
        now = 1000;
        await resume();
        final fresh = await a.authorizeLocal(
          SessionOperation.watch,
          'fresh',
          '',
        );
        if (lateFailure) {
          blocked.completeError(StateError('old clock'));
        } else {
          blocked.complete(100);
        }
        await rejected;
        expect(a.phase, GrantPhase.active);
        expect(a.generation, 2);
        await fresh.check();
        fresh.requireCurrent();
      },
    );
  }
}
