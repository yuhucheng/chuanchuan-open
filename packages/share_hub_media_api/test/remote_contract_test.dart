import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

class LegacyEngine implements PreviewEngine {
  @override
  String? get unavailableReason => null;
  @override
  Future<List<CaptureSource>> sources() async => [];
  @override
  Future<void> start(
    CaptureSource source, {
    required VoidCallback onEnded,
    required VoidCallback onFirstFrame,
  }) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  Widget get view => const SizedBox();
}

void main() {
  late GrantEndpoint a, b;
  Future<int> Function()? clockRead;
  final caps = MediaCapabilities(
    protocolVersion: 2,
    operations: {
      SessionOperation.watch,
      SessionOperation.cast,
      SessionOperation.control,
    },
    maxVideoSessions: 1,
  );
  setUp(() async {
    clockRead = null;
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
          clock: () => clockRead?.call() ?? Future.value(0),
          onInvalidated: () {},
        );
    a = endpoint(GrantRole.initiator);
    b = endpoint(GrantRole.receiver);
    await b.acceptResume(
      await a.finishResume(await b.answerResume(await a.beginResume())),
    );
  });
  Future<VerifiedSessionMessage> request(
    String id, [
    SessionOperation op = SessionOperation.watch,
  ]) async => b.open(await a.seal(op, id, ''));
  test(
    'outgoing authority is local, directional and shares the video budget',
    () async {
      final local = await a.authorizeLocal(SessionOperation.cast, 'cast-1', '');
      final aGrants = GrantRegistry()..register(a);
      final bGrants = GrantRegistry()..register(b);
      final budget = MediaSessionBudget(caps, grants: aGrants);
      final slot = await budget.reserve(local);
      expect(local.sender, GrantRole.initiator);
      await expectLater(bGrants.verify(local), throwsA(isA<SessionFailure>()));
      await expectLater(
        b.authorizeLocal(SessionOperation.watch, 'reverse', ''),
        throwsA(
          isA<SessionFailure>().having(
            (e) => e.code,
            'code',
            'direction_denied',
          ),
        ),
      );
      await expectLater(
        budget.reserve(
          await a.authorizeLocal(SessionOperation.watch, 'watch-2', ''),
        ),
        throwsA(isA<SessionFailure>().having((e) => e.code, 'code', 'busy')),
      );
      a.suspend();
      await expectLater(slot.check(), throwsA(isA<SessionFailure>()));
      expect(budget.activeCount, 1); // Native cleanup still owns the slot.
      slot.release();
      expect(budget.activeCount, 0);
    },
  );

  test('local request checks expiry and revocation after an asynchronous clock read', () async {
    final pendingClock = Completer<int>();
    clockRead = () => pendingClock.future;
    final pending = a.authorizeLocal(SessionOperation.watch, 'late', '');
    a.revoke();
    pendingClock.complete(0);
    await expectLater(pending, throwsA(isA<SessionFailure>()));
    clockRead = () async => grantLifetime.inMicroseconds;
    await expectLater(
      b.authorizeLocal(SessionOperation.file, 'expired', ''),
      throwsA(isA<SessionFailure>()),
    );
  });
  test('legacy implementation stays source compatible and preview only', () {
    final old = LegacyEngine();
    expect(old.unavailableReason, isNull);
    expect(capabilitiesOf(old).maxVideoSessions, 0);
    expect(caps.negotiate(capabilitiesOf(old)).operations, isEmpty);
    expect(
      caps
          .negotiate(
            MediaCapabilities(
              protocolVersion: 99,
              operations: {SessionOperation.watch},
              maxVideoSessions: 8,
            ),
          )
          .operations,
      isEmpty,
    );
  });
  test(
    'one video budget rejects busy without takeover, releasing preserves grant',
    () async {
      final budget = MediaSessionBudget(
        caps,
        grants: GrantRegistry()..register(b),
      );
      final first = await budget.reserve(await request('one'));
      await expectLater(
        budget.reserve(await request('two', SessionOperation.cast)),
        throwsA(isA<SessionFailure>().having((e) => e.code, 'code', 'busy')),
      );
      expect(budget.activeCount, 1);
      await first.check();
      first.release();
      await expectLater(first.check(), throwsA(isA<SessionFailure>()));
      await budget.reserve(await request('three', SessionOperation.control));
      expect(b.phase, GrantPhase.active);
      await expectLater(
        budget.reserve(await request('one')),
        throwsA(isA<SessionFailure>()),
      );
    },
  );
  test(
    'revoked messages and stale event generations cannot reach the view',
    () async {
      final slot = await MediaSessionBudget(
        caps,
        grants: GrantRegistry()..register(b),
      ).reserve(await request('one'));
      MediaSessionEvent event(int generation, MediaEventKind kind) =>
          MediaSessionEvent(
            grantId: b.binding.encodedId,
            sessionId: 'one',
            transportGeneration: generation,
            kind: kind,
          );
      expect(await slot.accepts(event(2, MediaEventKind.firstFrame)), isFalse);
      expect(
        await slot.accepts(event(1, MediaEventKind.waitingFirstFrame)),
        isTrue,
      );
      expect(event(1, MediaEventKind.statistics).roundTripTime, isNull);
      b.suspend();
      expect(await slot.accepts(event(1, MediaEventKind.firstFrame)), isFalse);
    },
  );
  test('negotiation intersects operations and concurrency rather than inventing them', () {
    final negotiated = caps.negotiate(
      MediaCapabilities(
        protocolVersion: 2,
        operations: {SessionOperation.cast},
        maxVideoSessions: 3,
      ),
    );
    expect(negotiated.operations, {SessionOperation.cast});
    expect(negotiated.maxVideoSessions, 1);
  });
  test('geometry rejects invalid dimensions, scale and rotation', () {
    expect(
      () => SourceGeometry(
        source: const CaptureSource('screen', 'Screen'),
        revision: 0,
        width: 10,
        height: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => SourceGeometry(
        source: const CaptureSource('screen', 'Screen'),
        revision: 0,
        width: 10,
        height: 10,
        scale: double.nan,
      ),
      throwsArgumentError,
    );
  });
  test(
    'self-issued proof is rejected outside the trusted local grant registry',
    () async {
      final permit = await request('forged-registry');
      final budget = MediaSessionBudget(caps, grants: GrantRegistry());
      await expectLater(
        budget.reserve(permit),
        throwsA(
          isA<SessionFailure>().having(
            (e) => e.code,
            'code',
            'unknown_local_grant',
          ),
        ),
      );
      expect(budget.activeCount, 0);
    },
  );
  test(
    'revocation while the authoritative clock is pending has no side effect',
    () async {
      final permit = await request('racing');
      final budget = MediaSessionBudget(
        caps,
        grants: GrantRegistry()..register(b),
      );
      final gate = Completer<int>();
      clockRead = () => gate.future;
      final reservation = budget.reserve(permit);
      b.revoke();
      gate.complete(0);
      await expectLater(reservation, throwsA(isA<SessionFailure>()));
      expect(budget.activeCount, 0);
    },
  );
  test(
    'equal grant fields cannot impersonate a registered endpoint instance',
    () async {
      GrantEndpoint endpoint(GrantRole role) =>
          GrantEndpoint.fromAuthenticatedPairing(
            binding: b.binding,
            role: role,
            establishedMicros: 0,
            recoverySecret: List.filled(32, 4),
            clock: () => clockRead?.call() ?? Future.value(0),
            onInvalidated: () {},
          );
      final fakeA = endpoint(GrantRole.initiator),
          fakeB = endpoint(GrantRole.receiver);
      await fakeB.acceptResume(
        await fakeA.finishResume(
          await fakeB.answerResume(await fakeA.beginResume()),
        ),
      );
      final fakePermit = await fakeB.open(
        await fakeA.seal(SessionOperation.watch, 'fake', ''),
      );
      final budget = MediaSessionBudget(
        caps,
        grants: GrantRegistry()..register(b),
      );
      await expectLater(
        budget.reserve(fakePermit),
        throwsA(
          isA<SessionFailure>().having(
            (e) => e.code,
            'code',
            'unknown_local_grant',
          ),
        ),
      );
      expect(budget.activeCount, 0);
      fakeA.revoke();
      fakeB.revoke();
    },
  );
}
