import 'dart:convert';

import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

const id = '0123456789abcdef0123456789abcdef';
final hash = 'a' * 64;
Map<String, Object> offer() => {
  'v': fileProtocolVersion,
  'type': 'offer',
  'transferOrdinal': '1',
  'transferId': id,
  'name': '报告.txt',
  'size': '32769',
  'sha256': hash,
  'chunkBytes': 32768,
};
FileMessage decode(Map<String, Object> fields) =>
    FileCodec.decode(jsonEncode(fields));
final bad = throwsA(isA<FileProtocolFailure>());
void main() {
  test(
    'terminal request is strictly directional metadata and grants no file I/O',
    () async {
      final fields = {
        ...offer(),
        'type': 'terminate',
        'transferSender': 'initiator',
      };
      final message = decode(fields);
      expect(message.type, 'terminate');
      expect(jsonDecode(FileCodec.encode(message)), fields);
      for (final invalid in ['both', 'sender', '', 'INITIATOR']) {
        expect(() => decode({...fields, 'transferSender': invalid}), bad);
      }
      expect(() => decode({...fields, 'offset': '0'}), bad);
      final peers = await Peers.create();
      addTearDown(() {
        peers.a.revoke();
        peers.b.revoke();
      });
      final request = await peers.a.authorizeLocal(
        SessionOperation.file,
        'cancel-file',
        FileCodec.encode(message),
      );
      await expectLater(
        FileTransferContext.fromRequest(peers.registry, request),
        bad,
      );
    },
  );
  test('fixed offer vector and maximum integer preserve wire semantics', () {
    final m = decode(offer()) as FileOffer;
    expect(m.name, '报告.txt');
    expect(m.size, 32769);
    expect(jsonDecode(FileCodec.encode(m)), offer());
    expect(
      (decode({...offer(), 'size': '9223372036854775807'}) as FileOffer).size,
      0x7fffffffffffffff,
    );
  });
  test('strict schema numeric hash identity and filename error vectors', () {
    for (final patch in <Map<String, Object>>[
      {'v': 3},
      {'v': '1'},
      {'type': 'other'},
      {'size': 1},
      {'size': '-1'},
      {'size': '01'},
      {'size': '9223372036854775808'},
      {'size': '1e3'},
      {'sha256': 'A' * 64},
      {'transferId': 'A' * 32},
      {'chunkBytes': 32769},
      {'name': '../x'},
      {'name': 'a/b'},
      {'name': r'a\b'},
      {'name': 'C:x'},
      {'name': '/tmp/x'},
      {'name': 'a\u0000b'},
      {'name': 'CON.txt'},
      {'name': 'a.'},
      {'name': 'a '},
      {'name': '😀' * 64},
      {'extra': true},
    ]) {
      expect(() => decode({...offer(), ...patch}), bad, reason: '$patch');
    }
    final missing = offer()..remove('name');
    expect(() => decode(missing), bad);
    expect(() => FileCodec.decode('[]'), bad);
    expect(
      () => FileCodec.decode(jsonEncode(offer()).replaceFirst('{', '{"v":2,')),
      bad,
    );
    expect(() => FileCodec.decode('{'), bad);
  });
  test('canonical chunks reject bad encoding, empty and oversize data', () {
    Map<String, Object> chunk(String data, [String offset = '0']) => {
      'v': fileProtocolVersion,
      'type': 'chunk',
      'transferId': id,
      'offset': offset,
      'data': data,
    };
    expect((decode(chunk('AAE')) as FileChunk).data, [0, 1]);
    for (final data in ['', 'AA==', 'AB', '++//', 'A', 'a b']) {
      expect(() => decode(chunk(data)), bad, reason: data);
    }
    expect(
      () => decode(
        chunk(base64Url.encode(List.filled(32769, 0)).replaceAll('=', '')),
      ),
      bad,
    );
    expect(() => decode(chunk('AAE', '9223372036854775807')), bad);
  });
  test('Windows console device names cannot appear in offer or complete', () {
    final invalidName = throwsA(
      isA<FileProtocolFailure>().having((e) => e.code, 'code', 'invalid_name'),
    );
    for (final name in [r'CONIN$', r'CONOUT$', r'conin$', r'conout$']) {
      expect(() => decode({...offer(), 'name': name}), invalidName);
      expect(
        () => decode({
          'v': fileProtocolVersion,
          'type': 'complete',
          'transferId': id,
          'actualName': name,
          'size': '32769',
          'sha256': hash,
        }),
        invalidName,
      );
    }
  });
  test('every control variant has an executable fixed vector', () {
    for (final fields in <Map<String, Object>>[
      {
        'type': 'accept',
        'acceptedChunkBytes': 32768,
        'window': 1,
        'offset': '0',
      },
      {'type': 'ack', 'nextOffset': '32768'},
      {'type': 'finish', 'size': '32769', 'sha256': hash},
      {
        'type': 'complete',
        'actualName': '报告 (1).txt',
        'size': '32769',
        'sha256': hash,
      },
      {'type': 'pause'},
      {'type': 'paused', 'offset': '32768'},
      {...offer(), 'type': 'resume', 'attemptId': id},
      {
        'type': 'resume-state',
        'attemptId': id,
        'offset': '32768',
        'prefixSha256': hash,
      },
      {
        'type': 'resume-accept',
        'attemptId': id,
        'offset': '32768',
        'prefixSha256': hash,
      },
      {'type': 'cancel'},
      {'type': 'cancelled'},
      {'type': 'failed', 'code': 'integrity_mismatch'},
    ]) {
      final wire = {'v': fileProtocolVersion, 'transferId': id, ...fields};
      expect(jsonDecode(FileCodec.encode(decode(wire))), wire);
    }
    expect(
      () => decode({
        'v': fileProtocolVersion,
        'type': 'accept',
        'transferId': id,
        'acceptedChunkBytes': 32768,
        'window': 2,
        'offset': '0',
      }),
      bad,
    );
    expect(
      () => decode({
        'v': fileProtocolVersion,
        'type': 'failed',
        'transferId': id,
        'code': 'C:/secret',
      }),
      bad,
    );
  });
  test(
    'bounded UTF8 framing counts whitespace bytes and envelope escaping',
    () {
      final raw = jsonEncode(offer());
      final padding = FileLimits.controlBytes - utf8.encode(raw).length;
      expect(FileCodec.decode('$raw${' ' * padding}'), isA<FileOffer>());
      expect(() => FileCodec.decode('$raw${' ' * (padding + 1)}'), bad);
      final c = FileChunk(
        transferId: id,
        offset: 0,
        data: List.filled(32768, 255),
      );
      final body = FileCodec.encode(c);
      expect(
        utf8.encode(jsonEncode(['signal', 'file', 'x' * 128, body])).length,
        lessThanOrEqualTo(65536),
      );
      expect((FileCodec.decode(body) as FileChunk).data.length, 32768);
      expect(() => c.data[0] = 2, throwsUnsupportedError);
    },
  );
  test(
    'stop-and-wait rejects gaps overlap premature completion and late data',
    () {
      var p = FileProgress(size: 5, chunkBytes: 3);
      expect(() => p.chunk(offset: 1, length: 3), bad);
      p = p.chunk(offset: 0, length: 3);
      expect(() => p.chunk(offset: 3, length: 2), bad);
      expect(() => p.ack(2), bad);
      p = p.ack(3);
      expect(() => p.finish(), bad);
      expect(() => p.chunk(offset: 0, length: 2), bad);
      p = p.chunk(offset: 3, length: 2).ack(5).finish();
      expect(p.phase, FileProgressPhase.verifying);
      p = p.complete();
      expect(p.phase, FileProgressPhase.completed);
      expect(() => p.chunk(offset: 5, length: 1), bad);
      expect(
        () => FileProgress(
          size: 1,
          chunkBytes: 1,
        ).cancel().chunk(offset: 0, length: 1),
        bad,
      );
      expect(
        FileProgress(size: 0).finish().complete().phase,
        FileProgressPhase.completed,
      );
    },
  );
  test(
    'resume retains original grant metadata deadline and a new session',
    () async {
      final peers = await Peers.create();
      final local = await peers.a.authorizeLocal(
        SessionOperation.file,
        'original',
        jsonEncode(offer()),
      );
      final original = await FileTransferContext.fromRequest(
        peers.registry,
        local,
      );
      final body = jsonEncode({...offer(), 'type': 'resume', 'attemptId': id});
      final same = await peers.a.authorizeLocal(
        SessionOperation.file,
        'original',
        body,
      );
      await expectLater(original.resumeWith(same), bad);
      final changed = await peers.a.authorizeLocal(
        SessionOperation.file,
        'changed',
        jsonEncode({
          ...offer(),
          'type': 'resume',
          'attemptId': id,
          'size': '1',
        }),
      );
      await expectLater(original.resumeWith(changed), bad);
      final foreign = await Peers.create();
      final foreignRequest = await foreign.a.authorizeLocal(
        SessionOperation.file,
        'foreign',
        body,
      );
      peers.registry.register(foreign.a);
      await expectLater(original.resumeWith(foreignRequest), bad);
      final reversed = await peers.b.authorizeLocal(
        SessionOperation.file,
        'reverse',
        body,
      );
      await expectLater(original.resumeWith(reversed), bad);
      peers.a.suspend();
      peers.b.suspend();
      await peers.activate();
      await expectLater(local.check(), throwsA(isA<SessionFailure>()));
      final fresh = await peers.a.authorizeLocal(
        SessionOperation.file,
        'resumed',
        body,
      );
      final resumed = await original.resumeWith(fresh);
      expect(resumed.authorization.expiresMicros, local.expiresMicros);
      await expectLater(
        resumed.validateOutgoing(
          FileResumeAccept(
            transferId: id,
            attemptId: '1' * 32,
            offset: 0,
            prefixSha256: hash,
          ),
        ),
        bad,
      );
      await resumed.validateOutgoing(
        FileResumeAccept(
          transferId: id,
          attemptId: id,
          offset: 0,
          prefixSha256: hash,
        ),
      );
      peers.a.revoke();
      peers.b.revoke();
      foreign.a.revoke();
      foreign.b.revoke();
    },
  );
  test(
    'resume rejects replacement endpoints reusing a revoked grant binding',
    () async {
      final peers = await Peers.create();
      final local = await peers.a.authorizeLocal(
        SessionOperation.file,
        'original',
        jsonEncode(offer()),
      );
      final original = await FileTransferContext.fromRequest(
        peers.registry,
        local,
      );
      peers.a.revoke();
      peers.b.revoke();
      final replacement = await Peers.create(
        binding: local.grant,
        recoverySecret: List.filled(32, 99),
      );
      addTearDown(() {
        replacement.a.revoke();
        replacement.b.revoke();
      });
      peers.registry.register(replacement.a);
      final next = await replacement.a.authorizeLocal(
        SessionOperation.file,
        'replacement',
        jsonEncode({...offer(), 'type': 'resume', 'attemptId': id}),
      );
      await peers.registry.verify(next);
      expect(identical(next.grant, local.grant), isTrue);
      expect(next.expiresMicros, local.expiresMicros);
      await expectLater(
        original.resumeWith(next),
        throwsA(
          isA<FileProtocolFailure>().having(
            (e) => e.code,
            'code',
            'resume_mismatch',
          ),
        ),
      );
    },
  );
  for (final reverse in [false, true]) {
    test(
      'unstarted receiver resume requires a fresh grant generation (reverse=$reverse)',
      () async {
        final peers = await Peers.create();
        addTearDown(() {
          peers.a.revoke();
          peers.b.revoke();
        });
        final sender = reverse ? peers.b : peers.a;
        final receiver = reverse ? peers.a : peers.b;
        final body = jsonEncode({
          ...offer(),
          'type': 'resume',
          'attemptId': id,
        });
        Future<VerifiedSessionMessage> request(
          String session,
          String payload,
        ) async {
          final local = await sender.authorizeLocal(
            SessionOperation.file,
            session,
            payload,
          );
          return receiver.open(await sender.sealRequest(local));
        }

        final old = await request('initial-resume', body);
        await expectLater(
          FileTransferContext.fromUnstartedResume(peers.registry, old),
          bad,
        );
        peers.a.suspend();
        peers.b.suspend();
        await peers.activate();
        final fresh = await request('fresh-resume', body);
        final context = await FileTransferContext.fromUnstartedResume(
          peers.registry,
          fresh,
        );
        expect(context.authorization.expiresMicros, old.expiresMicros);
        expect(context.transferSender, sender.role);
        await expectLater(
          FileTransferContext.fromUnstartedResume(
            peers.registry,
            await request('wrong-type', jsonEncode(offer())),
          ),
          bad,
        );
        await expectLater(
          FileTransferContext.fromUnstartedResume(peers.registry, old),
          throwsA(isA<SessionFailure>()),
        );
        peers.now = grantLifetime.inMicroseconds;
        await expectLater(context.check(), throwsA(isA<SessionFailure>()));
      },
    );
    test(
      'real grants authenticate ${reverse ? 'reverse' : 'forward'} file roles and full max block',
      () async {
        final peers = await Peers.create();
        final sender = reverse ? peers.b : peers.a,
            receiver = reverse ? peers.a : peers.b;
        final local = await sender.authorizeLocal(
          SessionOperation.file,
          'file-session',
          jsonEncode(offer()),
        );
        final remote = await receiver.open(await sender.sealRequest(local));
        final outbound = await FileTransferContext.fromRequest(
          peers.registry,
          local,
        );
        final inbound = await FileTransferContext.fromRequest(
          peers.registry,
          remote,
        );
        final chunk = FileChunk(
          transferId: id,
          offset: 0,
          data: List.filled(32768, 255),
        );
        await outbound.validateOutgoing(chunk);
        final signal = await receiver.openSignal(
          remote,
          await sender.sealSignal(local, FileCodec.encode(chunk)),
        );
        await expectLater(await inbound.decodeSignal(signal), isA<FileChunk>());
        final complete = FileComplete(
          transferId: id,
          actualName: 'ok.txt',
          size: 32769,
          sha256: hash,
        );
        await inbound.validateOutgoing(complete);
        await expectLater(outbound.validateOutgoing(complete), bad);
        final wrong = await receiver.openSignal(
          remote,
          await sender.sealSignal(local, FileCodec.encode(complete)),
        );
        await expectLater(inbound.decodeSignal(wrong), bad);
        await expectLater(
          outbound.validateOutgoing(
            FileChunk(transferId: '1' * 32, offset: 0, data: [1]),
          ),
          bad,
        );
        final other = await sender.authorizeLocal(
          SessionOperation.file,
          'other',
          jsonEncode(offer()),
        );
        final otherContext = await FileTransferContext.fromRequest(
          peers.registry,
          other,
        );
        final reply = await sender.openSignal(
          local,
          await receiver.sealSignal(remote, FileCodec.encode(complete)),
        );
        await expectLater(otherContext.decodeSignal(reply), bad);
        peers.a.revoke();
        peers.b.revoke();
      },
    );
  }
  test(
    'expired revoked foreign and old generation authority fail closed',
    () async {
      final peers = await Peers.create();
      final local = await peers.a.authorizeLocal(
        SessionOperation.file,
        's',
        jsonEncode(offer()),
      );
      final ctx = await FileTransferContext.fromRequest(peers.registry, local);
      final msg = FilePause(transferId: id);
      await expectLater(
        FileTransferContext.fromRequest(GrantRegistry(), local),
        throwsA(isA<SessionFailure>()),
      );
      final watch = await peers.a.authorizeLocal(
        SessionOperation.watch,
        'w',
        jsonEncode(offer()),
      );
      await expectLater(
        FileTransferContext.fromRequest(peers.registry, watch),
        bad,
      );
      peers.a.suspend();
      peers.b.suspend();
      await peers.activate();
      await expectLater(
        ctx.validateOutgoing(msg),
        throwsA(isA<SessionFailure>()),
      );
      final fresh = await peers.a.authorizeLocal(
        SessionOperation.file,
        'fresh',
        jsonEncode(offer()),
      );
      final current = await FileTransferContext.fromRequest(
        peers.registry,
        fresh,
      );
      peers.now = grantLifetime.inMicroseconds;
      await expectLater(
        current.validateOutgoing(msg),
        throwsA(isA<SessionFailure>()),
      );
      await expectLater(peers.a.phase, GrantPhase.revoked);
      peers.b.revoke();
    },
  );
}

class Peers {
  int now = 0;
  late GrantEndpoint a, b;
  final registry = GrantRegistry();
  static Future<Peers> create({
    GrantBinding? binding,
    List<int>? recoverySecret,
    Future<int> Function()? clock,
  }) async {
    final p = Peers();
    binding ??= GrantBinding(
      id: List.filled(32, 1),
      initiatorKey: List.filled(32, 2),
      receiverKey: List.filled(32, 3),
    );
    GrantEndpoint make(GrantRole role) =>
        GrantEndpoint.fromAuthenticatedPairing(
          binding: binding!,
          role: role,
          establishedMicros: 0,
          recoverySecret: recoverySecret ?? List.filled(32, 4),
          clock: clock ?? () async => p.now,
          onInvalidated: () {},
        );
    p.a = make(GrantRole.initiator);
    p.b = make(GrantRole.receiver);
    p.registry.register(p.a);
    p.registry.register(p.b);
    await p.activate();
    return p;
  }

  Future<void> activate() async {
    final hello = await a.beginResume();
    final response = await b.answerResume(hello);
    await b.acceptResume(await a.finishResume(response));
  }
}
