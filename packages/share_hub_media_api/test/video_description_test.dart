import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

final fingerprint = List.filled(32, 'A1').join(':');
String offer({bool sends = true}) => [
  'v=0',
  'o=- 1 1 IN IP4 127.0.0.1',
  's=-',
  't=0 0',
  'a=group:BUNDLE 0',
  'm=video 9 UDP/TLS/RTP/SAVPF 96',
  'c=IN IP4 0.0.0.0',
  'a=mid:0',
  'a=ice-ufrag:test',
  'a=ice-pwd:generated-test-password',
  'a=fingerprint:sha-256 $fingerprint',
  'a=setup:actpass',
  sends ? 'a=sendonly' : 'a=recvonly',
  'a=rtcp-mux',
  'a=rtpmap:96 VP8/90000',
  '',
].join('\r\n');

void main() {
  test('local SDP preserves native fingerprint and unilateral role', () {
    final description = VideoSessionDescription.local(
      type: 'offer',
      sdp: offer(),
      sends: true,
    );
    expect(description.fingerprint, fingerprint);
    expect(description.sdp, offer());
    expect(description.sends, isTrue);
    final answer = offer(sends: false)
        .replaceAll('a=setup:actpass', 'a=setup:active');
    expect(
      VideoSessionDescription.local(
        type: 'answer',
        sdp: answer,
        sends: false,
      ).type,
      'answer',
    );
  });
  test('JSON expansion cannot exceed the transport envelope', () {
    final description = VideoSessionDescription.local(
      type: 'offer',
      sdp: '${offer()}a=x:${'"' * 34000}\r\n',
      sends: true,
    );
    expect(description.encode, throwsA(isA<SessionFailure>()));
  });

  test('rejects extra media, direction widening and invalid DTLS binding', () {
    for (final sdp in [
      '${offer()}m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n',
      '${offer()}m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n',
      '${offer()}m=video 9 UDP/TLS/RTP/SAVPF 96\r\n',
      offer().replaceAll('a=sendonly', 'a=sendrecv'),
      offer().replaceAll('a=sendonly', 'a=recvonly'),
      offer().replaceAll('a=sendonly', 'a=inactive'),
      offer().replaceAll('UDP/TLS/RTP/SAVPF', 'RTP/AVP'),
      offer().replaceAll('sha-256', 'sha-1'),
      offer().replaceAll('a=fingerprint:sha-256 $fingerprint\r\n', ''),
      '${offer()}a=fingerprint:sha-256 ${List.filled(32, 'B2').join(':')}\r\n',
      offer().replaceAll('a=setup:actpass', 'a=setup:active'),
      offer().replaceAll('a=rtcp-mux\r\n', ''),
      offer().replaceAll('m=video 9', 'm=video 0'),
      '${offer()}a=mid:other\r\n',
      '${offer()}${'x' * VideoSessionDescription.maxSdpBytes}',
    ]) {
      expect(
        () =>
            VideoSessionDescription.local(type: 'offer', sdp: sdp, sends: true),
        throwsA(isA<SessionFailure>()),
      );
    }
  });

  late GrantEndpoint a, b;
  late LocalSessionRequest local;
  late VerifiedSessionMessage incoming;
  late MediaSessionSlot slot;
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
    local = await a.authorizeLocal(SessionOperation.cast, 'video-1', '');
    incoming = await b.open(await a.sealRequest(local));
    slot = await MediaSessionBudget(
      MediaCapabilities(
        protocolVersion: 2,
        operations: {SessionOperation.cast},
        maxVideoSessions: 1,
      ),
      grants: GrantRegistry()..register(b),
    ).reserve(incoming);
  });
  tearDown(() {
    a.revoke();
    b.revoke();
    slot.release();
  });
  Future<VerifiedSessionSignal> signal(String body) async =>
      b.openSignal(incoming, await a.sealSignal(local, body));

  test('SDP and ICE explicitly bind to the current media revision', () async {
    final description = VideoSessionDescription.local(
      type: 'offer',
      sdp: offer(),
      sends: true,
    );
    final incomingSdp = await signal(description.encode(revision: 1));
    await VideoSessionDescription.receive(
      incomingSdp,
      slot: slot,
      expectedType: 'offer',
      peerSends: true,
      expectedRevision: 1,
    );
    await expectLater(
      VideoSessionDescription.receive(
        incomingSdp,
        slot: slot,
        expectedType: 'offer',
        peerSends: true,
      ),
      throwsA(isA<SessionFailure>()),
    );
    final ice = VideoIceCandidate.local(
      candidate: 'candidate:1 1 udp 1 192.0.2.1 50000 typ host ufrag test',
      mid: '0',
      mLineIndex: 0,
    );
    final incomingIce = await signal(ice.encode(revision: 1));
    await VideoIceCandidate.receive(
      incomingIce,
      slot: slot,
      expectedRevision: 1,
    );
    await expectLater(
      VideoIceCandidate.receive(incomingIce, slot: slot),
      throwsA(isA<SessionFailure>()),
    );
    for (final bad in [-1, 0x80000000]) {
      expect(
        () => description.encode(revision: bad),
        throwsA(isA<SessionFailure>()),
      );
      expect(() => ice.encode(revision: bad), throwsA(isA<SessionFailure>()));
    }
    final malformed = jsonDecode(description.encode()) as Map<String, dynamic>;
    malformed.remove('revision');
    await expectLater(
      VideoSessionDescription.receive(
        await signal(jsonEncode(malformed)),
        slot: slot,
        expectedType: 'offer',
        peerSends: true,
      ),
      throwsA(isA<SessionFailure>()),
    );
  });

  test(
    'authenticated description is usable only by its exact live slot',
    () async {
      final body = VideoSessionDescription.local(
        type: 'offer',
        sdp: offer(),
        sends: true,
      ).encode();
      final authenticated = await signal(body);
      final parsed = await VideoSessionDescription.receive(
        authenticated,
        slot: slot,
        expectedType: 'offer',
        peerSends: true,
      );
      expect(parsed.fingerprint, fingerprint);
      slot.release();
      await expectLater(
        VideoSessionDescription.receive(
          authenticated,
          slot: slot,
          expectedType: 'offer',
          peerSends: true,
        ),
        throwsA(isA<SessionFailure>()),
      );
    },
  );
  test(
    'authenticated but mismatched fingerprint or profile is rejected',
    () async {
      final body = jsonDecode(
        VideoSessionDescription.local(
          type: 'offer',
          sdp: offer(),
          sends: true,
        ).encode(),
      ) as Map<String, dynamic>;
      for (final malformed in [
        {...body, 'fingerprint': List.filled(32, 'B2').join(':')},
        {...body, 'version': 1},
        {...body, 'version': 1.0},
        {...body, 'type': 'answer'},
        {...body, 'extra': true},
        {...body, 'sdp': null},
      ]) {
        final authenticated = await signal(jsonEncode(malformed));
        await expectLater(
          VideoSessionDescription.receive(
            authenticated,
            slot: slot,
            expectedType: 'offer',
            peerSends: true,
          ),
          throwsA(isA<SessionFailure>()),
        );
      }
    },
  );
  test('revocation and foreign operation both reject valid SDP', () async {
    final body = VideoSessionDescription.local(
      type: 'offer',
      sdp: offer(),
      sends: true,
    ).encode();
    final another = await a.authorizeLocal(
      SessionOperation.cast,
      'video-2',
      '',
    );
    final otherIncoming = await b.open(await a.sealRequest(another));
    final foreign = await b.openSignal(
      otherIncoming,
      await a.sealSignal(another, body),
    );
    await expectLater(
      VideoSessionDescription.receive(
        foreign,
        slot: slot,
        expectedType: 'offer',
        peerSends: true,
      ),
      throwsA(isA<SessionFailure>()),
    );
    final authenticated = await signal(body);
    b.revoke();
    await expectLater(
      VideoSessionDescription.receive(
        authenticated,
        slot: slot,
        expectedType: 'offer',
        peerSends: true,
      ),
      throwsA(isA<SessionFailure>()),
    );
  });

  const candidate =
      'candidate:1 1 udp 2122260223 192.0.2.1 50000 typ host ufrag test';
  test(
    'ICE accepts bounded native UDP/TCP and mDNS, rejects malformed fields',
    () {
      for (final text in [
        candidate,
        candidate.replaceAll('192.0.2.1', 'fixture.local'),
        candidate.replaceAll('192.0.2.1', '2001:db8::1'),
        'candidate:2 1 tcp 2122260223 192.0.2.1 9 typ host tcptype active',
        '',
      ]) {
        expect(
          VideoIceCandidate.local(
            candidate: text,
            mid: '0',
            mLineIndex: 0,
          ).candidate,
          text,
        );
      }
      for (final text in [
        '$candidate\r\na=sendrecv',
        '$candidate\u0000',
        candidate.replaceAll(' 1 udp', ' 2 udp'),
        candidate.replaceAll('50000', '70000'),
        candidate.replaceAll('50000', '0'),
        candidate.replaceAll('2122260223', '4294967296'),
        candidate.replaceAll('typ host', 'typ unknown'),
        '$candidate ufrag other',
        '$candidate incomplete',
        'x' * 2049,
      ]) {
        expect(
          () =>
              VideoIceCandidate.local(candidate: text, mid: '0', mLineIndex: 0),
          throwsA(isA<SessionFailure>()),
        );
      }
      expect(
        () => VideoIceCandidate.local(
          candidate: candidate,
          mid: '0',
          mLineIndex: 1,
        ),
        throwsA(isA<SessionFailure>()),
      );
    },
  );

  test(
    'ICE authenticated payload remains bound to MID, ufrag and slot lifetime',
    () async {
      final encoded = VideoIceCandidate.local(
        candidate: candidate,
        mid: '0',
        mLineIndex: 0,
      ).encode();
      final authenticated = await signal(encoded);
      final parsed = await VideoIceCandidate.receive(authenticated, slot: slot);
      parsed.matchDescription(
        VideoSessionDescription.local(type: 'offer', sdp: offer(), sends: true),
      );
      expect(
        () => parsed.matchDescription(
          VideoSessionDescription.local(
            type: 'offer',
            sdp: offer().replaceAll('a=ice-ufrag:test', 'a=ice-ufrag:other'),
            sends: true,
          ),
        ),
        throwsA(isA<SessionFailure>()),
      );
      slot.release();
      expect(slot.requireCurrent, throwsA(isA<SessionFailure>()));
      await expectLater(
        VideoIceCandidate.receive(authenticated, slot: slot),
        throwsA(isA<SessionFailure>()),
      );
    },
  );

  test(
    'ICE rejects authenticated malformed JSON shapes and large bodies',
    () async {
      final encoded = jsonDecode(
        VideoIceCandidate.local(
          candidate: candidate,
          mid: '0',
          mLineIndex: 0,
        ).encode(),
      ) as Map<String, dynamic>;
      for (final body in [
        jsonEncode({...encoded, 'version': 1.0}),
        jsonEncode({...encoded, 'mLineIndex': 0.0}),
        jsonEncode({...encoded, 'mid': null}),
        jsonEncode({...encoded, 'extra': true}),
        jsonEncode({...encoded, 'candidate': 'x' * 5000}),
        'not-json',
      ]) {
        await expectLater(
          VideoIceCandidate.receive(await signal(body), slot: slot),
          throwsA(isA<SessionFailure>()),
        );
      }
    },
  );

  test(
    'presentation receipt requires live exact slot and current revision',
    () async {
      final encoded = VideoPresentationReceipt(
        revision: 3,
        width: 640,
        height: 360,
      ).encode();
      final authenticated = await signal(encoded);
      final parsed = await VideoPresentationReceipt.receive(
        authenticated,
        slot: slot,
        expectedRevision: 3,
      );
      expect((parsed.width, parsed.height), (640, 360));
      await expectLater(
        VideoPresentationReceipt.receive(
          authenticated,
          slot: slot,
          expectedRevision: 4,
        ),
        throwsA(isA<SessionFailure>()),
      );
      slot.release();
      await expectLater(
        VideoPresentationReceipt.receive(
          authenticated,
          slot: slot,
          expectedRevision: 3,
        ),
        throwsA(isA<SessionFailure>()),
      );
    },
  );

  test(
    'presentation receipt rejects malformed and unbounded dimensions',
    () async {
      final valid = jsonDecode(
        VideoPresentationReceipt(revision: 0, width: 640, height: 360).encode(),
      ) as Map<String, dynamic>;
      for (final data in [
        {...valid, 'revision': -1},
        {...valid, 'revision': 0.5},
        {...valid, 'width': 0},
        {...valid, 'width': 65536},
        {...valid, 'height': null},
        {...valid, 'version': 1.0},
        {...valid, 'extra': true},
        {...valid, 'kind': 'connected'},
      ]) {
        await expectLater(
          VideoPresentationReceipt.receive(
            await signal(jsonEncode(data)),
            slot: slot,
            expectedRevision: 0,
          ),
          throwsA(isA<SessionFailure>()),
        );
      }
    },
  );
}
