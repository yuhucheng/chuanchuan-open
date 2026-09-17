import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

void main() {
  late GrantEndpoint a, b;
  late LocalSessionRequest local;
  late VerifiedSessionMessage remote;
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
    await b.acceptResume(
      await a.finishResume(await b.answerResume(await a.beginResume())),
    );
    local = await a.authorizeLocal(
      SessionOperation.cast,
      'video',
      VideoSessionRequest.body,
    );
    remote = await b.open(await a.sealRequest(local));
  });
  tearDown(() {
    a.revoke();
    b.revoke();
  });

  test('playback control is bounded, authenticated and carries an integer revision', () async {
    for (final action in VideoPlaybackAction.values) {
      final signal = await a.openSignal(
        local,
        await b.sealSignal(
          remote,
          VideoPlaybackMessage(action: action, revision: 3).encode(),
        ),
      );
      final result = await VideoPlaybackMessage.receive(
        signal,
        authorization: local,
      );
      expect(result.action, action);
      expect(result.revision, 3);
      await expectLater(
        VideoPlaybackMessage.receive(signal, authorization: remote),
        throwsA(isA<SessionFailure>()),
      );
    }
    for (final data in [
      {'version': 1, 'kind': 'playback', 'action': 'pause', 'revision': -1},
      {
        'version': 1,
        'kind': 'playback',
        'action': 'pause',
        'revision': 0x80000000,
      },
      {'version': 1, 'kind': 'playback', 'action': 'pause', 'revision': 1.0},
      {'version': 1, 'kind': 'playback', 'action': 'unknown', 'revision': 0},
      {
        'version': 1,
        'kind': 'playback',
        'action': 'pause',
        'revision': 0,
        'source': 'larger',
      },
      {'version': 2, 'kind': 'playback', 'action': 'pause', 'revision': 0},
    ]) {
      final signal = await a.openSignal(
        local,
        await b.sealSignal(remote, jsonEncode(data)),
      );
      await expectLater(
        VideoPlaybackMessage.receive(signal, authorization: local),
        throwsA(isA<SessionFailure>()),
      );
    }
    final old = await a.openSignal(
      local,
      await b.sealSignal(
        remote,
        VideoPlaybackMessage(
          action: VideoPlaybackAction.resume,
          revision: 1,
        ).encode(),
      ),
    );
    a.revoke();
    await expectLater(
      VideoPlaybackMessage.receive(old, authorization: local),
      throwsA(isA<SessionFailure>()),
    );
  });

  test('versioned intent permits either video direction without remote source selection', () async {
    await VideoSessionRequest.check(local);
    await VideoSessionRequest.check(remote);
    for (final body in [
      '',
      '{"version":1,"kind":"video"}',
      '{"version":2.0,"kind":"video"}',
      '{"version":2,"kind":"video","source":"entire-screen"}',
      '{"version":2,"kind":"audio"}',
      'x' * 513,
    ]) {
      final request = await a.authorizeLocal(
        SessionOperation.watch,
        'other',
        body,
      );
      await expectLater(
        VideoSessionRequest.check(request),
        throwsA(isA<SessionFailure>()),
      );
    }
    final file = await a.authorizeLocal(
      SessionOperation.file,
      'file',
      VideoSessionRequest.body,
    );
    await expectLater(
      VideoSessionRequest.check(file),
      throwsA(isA<SessionFailure>()),
    );
  });

  test(
    'termination uses exact live authority and a fixed diagnostic vocabulary',
    () async {
      for (final reason in VideoEndReason.values) {
        final signal = await a.openSignal(
          local,
          await b.sealSignal(remote, VideoSessionEnd(reason).encode()),
        );
        expect(
          (await VideoSessionEnd.receive(signal, authorization: local)).reason,
          reason,
        );
        await expectLater(
          VideoSessionEnd.receive(signal, authorization: remote),
          throwsA(isA<SessionFailure>()),
        );
      }
      for (final value in [
        {'version': 1, 'kind': 'ended', 'reason': 'native private path'},
        {'version': 1, 'kind': 'ended', 'reason': 'stopped', 'extra': true},
        {'version': 2, 'kind': 'ended', 'reason': 'stopped'},
        {'version': 1, 'kind': 'video', 'reason': 'stopped'},
      ]) {
        final signal = await a.openSignal(
          local,
          await b.sealSignal(remote, jsonEncode(value)),
        );
        await expectLater(
          VideoSessionEnd.receive(signal, authorization: local),
          throwsA(isA<SessionFailure>()),
        );
      }
      final old = await a.openSignal(
        local,
        await b.sealSignal(
          remote,
          const VideoSessionEnd(VideoEndReason.stopped).encode(),
        ),
      );
      a.revoke();
      await expectLater(
        VideoSessionEnd.receive(old, authorization: local),
        throwsA(isA<SessionFailure>()),
      );
    },
  );
}
