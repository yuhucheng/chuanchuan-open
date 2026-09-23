import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

void main() {
  late GrantEndpoint a, b;
  late LocalSessionRequest oldA;
  late VerifiedSessionMessage oldB;
  const source = CaptureSource(
    'window-17',
    'Original',
    type: CaptureSourceType.window,
  );
  Future<void> activate() async => b.acceptResume(
    await a.finishResume(await b.answerResume(await a.beginResume())),
  );
  setUp(() async {
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
          clock: () async => 0,
          recoverySecret: List.filled(32, 4),
          onInvalidated: () {},
        );
    a = endpoint(GrantRole.initiator);
    b = endpoint(GrantRole.receiver);
    await activate();
    oldA = await a.authorizeLocal(
      SessionOperation.cast,
      'old',
      VideoSessionRequest.body,
    );
    oldB = await b.open(await a.sealRequest(oldA));
    a.suspend();
    b.suspend();
    await activate();
  });
  tearDown(() {
    a.revoke();
    b.revoke();
  });
  VideoRecoveryIntent intent(
    SessionAuthorization previous, {
    Future<void>? released,
    bool paused = false,
  }) => VideoRecoveryIntent(
    previous: previous,
    revision: 2,
    paused: paused,
    source: previous is LocalSessionRequest ? source : null,
    released: released ?? Future.value(),
  );
  Future<LocalSessionRequest> request(
    VideoRecoveryRequest recovery, {
    String id = 'new',
    SessionOperation operation = SessionOperation.cast,
  }) => a.authorizeLocal(
    operation,
    id,
    VideoSessionRequest.recoveryBody(recovery),
  );

  test('matching fresh authorizations claim local lineage once and preserve exact local source', () async {
    final ia = intent(oldA), ib = intent(oldB);
    final nextA = await request(ia.request);
    final nextB = await b.open(await a.sealRequest(nextA));
    final aa = await ia.claim(
      nextA,
      (await VideoSessionRequest.recovery(nextA))!,
    );
    final ab = await ib.claim(
      nextB,
      (await VideoSessionRequest.recovery(nextB))!,
    );
    expect(aa.source, same(source));
    expect(ab.source, isNull);
    expect(nextA.transportGeneration, 2);
    expect(nextA.expiresMicros, oldA.expiresMicros);
    await expectLater(
      ia.claim(nextA, ia.request),
      throwsA(isA<SessionFailure>()),
    );
    ia.cancel();
    expect(aa.requireCurrent, throwsA(isA<SessionFailure>()));
    ib.cancel();
  });
  test('cleanup completion is required; explicit stop while pending prevents a late claim', () async {
    final release = Completer<void>();
    final saved = intent(oldA, released: release.future);
    final next = await request(saved.request);
    var completed = false;
    final pending = saved.claim(next, saved.request).then((value) {
      completed = true;
      return value;
    });
    final failed = expectLater(pending, throwsA(isA<SessionFailure>()));
    await Future<void>.delayed(Duration.zero);
    expect(completed, false);
    saved.cancel();
    release.complete();
    await failed;
  });
  test(
    'failed cleanup and authorization invalidation cannot mint admission',
    () async {
      final release = Completer<void>();
      final saved = intent(oldA, released: release.future);
      final failed = expectLater(
        saved.claim(await request(saved.request), saved.request),
        throwsStateError,
      );
      release.completeError(StateError('cleanup'));
      await failed;
      expect(saved.stopped, true);
      final saved2 = intent(oldA);
      final next = await request(saved2.request, id: 'next');
      a.revoke();
      await expectLater(
        saved2.claim(next, saved2.request),
        throwsA(isA<SessionFailure>()),
      );
    },
  );
  test('wrong lineage, pause, revision, direction or reused operation cannot be admitted', () async {
    final saved = intent(oldA, paused: true);
    for (final recovery in [
      VideoRecoveryRequest(
        previousSessionId: 'other',
        previousTransportGeneration: 1,
        previousRevision: 2,
        paused: true,
      ),
      VideoRecoveryRequest(
        previousSessionId: 'old',
        previousTransportGeneration: 1,
        previousRevision: 1,
        paused: true,
      ),
      VideoRecoveryRequest(
        previousSessionId: 'old',
        previousTransportGeneration: 1,
        previousRevision: 2,
        paused: false,
      ),
    ]) {
      await expectLater(
        saved.claim(await request(recovery), recovery),
        throwsA(isA<SessionFailure>()),
      );
    }
    await expectLater(
      saved.claim(
        await request(saved.request, operation: SessionOperation.watch),
        saved.request,
      ),
      throwsA(isA<SessionFailure>()),
    );
    final reused = await request(saved.request, id: 'old');
    await expectLater(
      VideoSessionRequest.check(reused),
      throwsA(isA<SessionFailure>()),
    );
    await expectLater(
      saved.claim(reused, saved.request),
      throwsA(isA<SessionFailure>()),
    );
    saved.cancel();
  });
  test('recovery body rejects fields, types, future generations and source injection', () async {
    final saved = intent(oldA);
    final valid = jsonDecode(
      VideoSessionRequest.recoveryBody(saved.request),
    ) as Map<String, dynamic>;
    final lineage = valid['recovery'] as Map<String, dynamic>;
    for (final value in [
      {...valid, 'source': 'full-screen'},
      {...valid, 'version': 4.0},
      {
        ...valid,
        'recovery': {...lineage, 'generation': 2},
      },
      {
        ...valid,
        'recovery': {...lineage, 'revision': 2.0},
      },
      {
        ...valid,
        'recovery': {...lineage, 'paused': 'true'},
      },
      {
        ...valid,
        'recovery': {...lineage, 'session': 'x' * 129},
      },
      {
        ...valid,
        'recovery': {...lineage, 'extra': true},
      },
    ]) {
      final next = await a.authorizeLocal(
        SessionOperation.cast,
        'new',
        jsonEncode(value),
      );
      await expectLater(
        VideoSessionRequest.check(next),
        throwsA(isA<SessionFailure>()),
      );
    }
    final normal = await a.authorizeLocal(
      SessionOperation.cast,
      'fresh',
      VideoSessionRequest.body,
    );
    expect(await VideoSessionRequest.recovery(normal), isNull);
    saved.cancel();
  });
  test(
    'ready is authenticated for the exact new initiating operation',
    () async {
      final saved = intent(oldA);
      final next = await request(saved.request);
      final remote = await b.open(await a.sealRequest(next));
      final ready = await a.openSignal(
        next,
        await b.sealSignal(remote, VideoRecoveryReady.body),
      );
      await VideoRecoveryReady.check(ready, next);
      final admission = await saved.claim(next, saved.request);
      expect(admission.requireStart, throwsA(isA<SessionFailure>()));
      await admission.confirmPeer(ready);
      admission.requireStart();
      await expectLater(
        VideoRecoveryReady.check(ready, oldA),
        throwsA(isA<SessionFailure>()),
      );
      final malformed = await a.openSignal(
        next,
        await b.sealSignal(remote, '{"version":1.0,"kind":"recovery-ready"}'),
      );
      await expectLater(
        VideoRecoveryReady.check(malformed, next),
        throwsA(isA<SessionFailure>()),
      );
      a.revoke();
      await expectLater(
        VideoRecoveryReady.check(ready, next),
        throwsA(isA<SessionFailure>()),
      );
      saved.cancel();
    },
  );
}
