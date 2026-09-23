import 'dart:async';
import 'dart:convert';

import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

import 'file_protocol_test.dart' show Peers;

const id = '0123456789abcdef0123456789abcdef';
final metadata = <String, Object>{
  'v': 2,
  'type': 'offer',
  'transferId': id,
  'transferOrdinal': '1',
  'name': 'report.txt',
  'size': '3',
  'sha256': 'a' * 64,
  'chunkBytes': 32768,
};

void main() {
  test('completed retirement cannot accept a different saved name', () async {
    final peers = await Peers.create();
    addTearDown(() {
      peers.a.revoke();
      peers.b.revoke();
    });
    final request = await peers.a.authorizeLocal(
      SessionOperation.file,
      'retire-completed',
      jsonEncode({
        ...metadata,
        'type': 'retire',
        'transferSender': 'initiator',
        'outcome': 'completed',
        'actualName': 'report (1).txt',
      }),
    );
    final remote = await peers.b.open(await peers.a.sealRequest(request));
    final localContext = await FileRetirementContext.fromRequest(
      peers.registry,
      request,
    );
    final remoteContext = await FileRetirementContext.fromRequest(
      peers.registry,
      remote,
    );
    for (final name in ['report (1).txt', 'report.txt']) {
      final receipt = FileComplete(
        transferId: id,
        actualName: name,
        size: 3,
        sha256: metadata['sha256']! as String,
      );
      final signal = await peers.a.openSignal(
        request,
        await peers.b.sealSignal(remote, FileCodec.encode(receipt)),
      );
      if (name == 'report (1).txt') {
        await remoteContext.validateReply(receipt);
        expect(await localContext.decodeSignal(signal), isA<FileComplete>());
      } else {
        await expectLater(
          remoteContext.validateReply(receipt),
          throwsA(isA<FileProtocolFailure>()),
        );
        await expectLater(
          localContext.decodeSignal(signal),
          throwsA(isA<FileProtocolFailure>()),
        );
      }
    }
  });

  for (final decoding in [true, false]) {
    test(
      'retirement ${decoding ? 'decode' : 'reply'} rejects suspension during the asynchronous clock check',
      () async {
        Completer<int>? clockGate;
        final peers = await Peers.create(
          clock: () => clockGate?.future ?? Future.value(0),
        );
        addTearDown(() {
          peers.a.revoke();
          peers.b.revoke();
        });
        final request = await peers.a.authorizeLocal(
          SessionOperation.file,
          'retire-suspend',
          jsonEncode({
            ...metadata,
            'type': 'retire',
            'transferSender': 'initiator',
            'outcome': 'cancelled',
          }),
        );
        final remote = await peers.b.open(await peers.a.sealRequest(request));
        final context = await FileRetirementContext.fromRequest(
          peers.registry,
          decoding ? request : remote,
        );
        final retired = FileRetired(transferId: id, transferOrdinal: 1);
        final signal = await peers.a.openSignal(
          request,
          await peers.b.sealSignal(remote, FileCodec.encode(retired)),
        );
        clockGate = Completer<int>();
        final operation = decoding
            ? context.decodeSignal(signal)
            : context.validateReply(retired);
        final assertion = expectLater(
          operation,
          throwsA(isA<SessionFailure>()),
        );
        // Invalidation must win while the authorization clock is unresolved.
        scheduleMicrotask(() {
          (decoding ? peers.a : peers.b).suspend();
          clockGate!.complete(0);
        });
        await assertion;
      },
    );
  }

  test('v2 metadata binds a mandatory positive transfer ordinal', () {
    final message = FileCodec.decode(jsonEncode(metadata));
    expect(message, isA<FileOffer>());
    expect(jsonDecode(FileCodec.encode(message)), metadata);
  });

  test(
    'v1 and missing zero noncanonical or overflowing ordinals are rejected',
    () {
      final bad = throwsA(isA<FileProtocolFailure>());
      for (final ordinal in <Object>[
        '0',
        '-1',
        '01',
        1,
        '9223372036854775808',
      ]) {
        expect(
          () => FileCodec.decode(
            jsonEncode({...metadata, 'transferOrdinal': ordinal}),
          ),
          bad,
        );
      }
      expect(() => FileCodec.decode(jsonEncode({...metadata, 'v': 1})), bad);
      expect(
        () => FileCodec.decode(
          jsonEncode({...metadata}..remove('transferOrdinal')),
        ),
        bad,
      );
      final maximum = {...metadata, 'transferOrdinal': '9223372036854775807'};
      expect(
        jsonDecode(FileCodec.encode(FileCodec.decode(jsonEncode(maximum)))),
        maximum,
      );
    },
  );

  test('retirement has exact mutually exclusive terminal evidence', () {
    final bad = throwsA(isA<FileProtocolFailure>());
    final base = {...metadata, 'type': 'retire', 'transferSender': 'initiator'};
    final vectors = [
      {...base, 'outcome': 'completed', 'actualName': 'report (1).txt'},
      {...base, 'outcome': 'cancelled'},
      {...base, 'outcome': 'failed', 'failureCode': 'integrity_mismatch'},
    ];
    for (final vector in vectors) {
      final decoded = FileCodec.decode(jsonEncode(vector));
      expect(decoded, isA<FileRetire>());
      expect(jsonDecode(FileCodec.encode(decoded)), vector);
    }
    for (final vector in [
      {...base, 'outcome': 'completed'},
      {...base, 'outcome': 'cancelled', 'actualName': 'report.txt'},
      {...base, 'outcome': 'failed'},
      {...base, 'outcome': 'failed', 'failureCode': 'C:/private/path'},
      {...base, 'outcome': 'pending'},
      {...base, 'outcome': 'completed', 'actualName': '../escape'},
      {...vectors.first, 'failureCode': 'cancelled'},
    ]) {
      expect(
        () => FileCodec.decode(jsonEncode(vector)),
        bad,
        reason: '$vector',
      );
    }
  });

  test(
    'retired and rejected are not delivery or terminal-failure receipts',
    () {
      final retired = FileCodec.decode(
        jsonEncode({
          'v': 2,
          'type': 'retired',
          'transferId': id,
          'transferOrdinal': '1',
        }),
      );
      final rejected = FileCodec.decode(
        jsonEncode({
          'v': 2,
          'type': 'rejected',
          'transferId': id,
          'code': 'resource_limit',
        }),
      );
      expect(retired, isA<FileRetired>());
      expect(retired, isNot(isA<FileComplete>()));
      expect(rejected, isA<FileRejected>());
      expect(rejected, isNot(isA<FileFailed>()));
    },
  );

  test(
    'resume cannot change ordinal and native keys separate the same random ID',
    () async {
      final peers = await Peers.create();
      addTearDown(() {
        peers.a.revoke();
        peers.b.revoke();
      });
      final initial = await peers.a.authorizeLocal(
        SessionOperation.file,
        'original',
        jsonEncode(metadata),
      );
      final original = await FileTransferContext.fromRequest(
        peers.registry,
        initial,
      );
      final different = await peers.a.authorizeLocal(
        SessionOperation.file,
        'other',
        jsonEncode({...metadata, 'transferOrdinal': '2'}),
      );
      final other = await FileTransferContext.fromRequest(
        peers.registry,
        different,
      );
      expect(original.transferKey, isNot(other.transferKey));
      expect(original.transferOrdinal, 1);
      final wrongResume = await peers.a.authorizeLocal(
        SessionOperation.file,
        'resume',
        jsonEncode({
          ...metadata,
          'type': 'resume',
          'attemptId': id,
          'transferOrdinal': '2',
        }),
      );
      await expectLater(
        original.resumeWith(wrongResume),
        throwsA(isA<FileProtocolFailure>()),
      );
      final correctResume = await peers.a.authorizeLocal(
        SessionOperation.file,
        'resume-correct',
        jsonEncode({...metadata, 'type': 'resume', 'attemptId': id}),
      );
      final resumed = await original.resumeWith(correctResume);
      expect(resumed.transferOrdinal, original.transferOrdinal);
      expect(resumed.transferKey, original.transferKey);
      expect(
        resumed.authorization.expiresMicros,
        original.authorization.expiresMicros,
      );
    },
  );

  test(
    'retirement controls cannot masquerade as data-session replies',
    () async {
      final peers = await Peers.create();
      addTearDown(() {
        peers.a.revoke();
        peers.b.revoke();
      });
      final initial = await peers.a.authorizeLocal(
        SessionOperation.file,
        'original',
        jsonEncode(metadata),
      );
      final original = await FileTransferContext.fromRequest(
        peers.registry,
        initial,
      );
      final remote = await peers.b.open(await peers.a.sealRequest(initial));
      for (final fields in [
        {'v': 2, 'type': 'retired', 'transferId': id, 'transferOrdinal': '1'},
        {
          ...metadata,
          'type': 'retire',
          'transferSender': 'initiator',
          'outcome': 'cancelled',
        },
      ]) {
        final control = FileCodec.decode(jsonEncode(fields));
        final signal = await peers.a.openSignal(
          initial,
          await peers.b.sealSignal(remote, FileCodec.encode(control)),
        );
        await expectLater(
          original.decodeSignal(signal),
          throwsA(isA<FileProtocolFailure>()),
        );
        await expectLater(
          original.validateOutgoing(control),
          throwsA(isA<FileProtocolFailure>()),
        );
      }
    },
  );

  test('retirement binds only the original authenticated file sender and grants no I/O', () async {
    final peers = await Peers.create();
    addTearDown(() {
      peers.a.revoke();
      peers.b.revoke();
    });
    final wire = jsonEncode({
      ...metadata,
      'type': 'retire',
      'transferSender': 'initiator',
      'outcome': 'cancelled',
    });
    final request = await peers.a.authorizeLocal(
      SessionOperation.file,
      'retire-1',
      wire,
    );
    final local = await FileRetirementContext.fromRequest(
      peers.registry,
      request,
    );
    expect(local.request.transferOrdinal, 1);
    await expectLater(
      FileTransferContext.fromRequest(peers.registry, request),
      throwsA(isA<FileProtocolFailure>()),
    );
    final reverse = await peers.b.authorizeLocal(
      SessionOperation.file,
      'retire-wrong-role',
      wire,
    );
    await expectLater(
      FileRetirementContext.fromRequest(peers.registry, reverse),
      throwsA(isA<FileProtocolFailure>()),
    );
    final wrongOperation = await peers.a.authorizeLocal(
      SessionOperation.watch,
      'retire-wrong-operation',
      wire,
    );
    await expectLater(
      FileRetirementContext.fromRequest(peers.registry, wrongOperation),
      throwsA(isA<FileProtocolFailure>()),
    );
    peers.a.revoke();
    await expectLater(
      FileRetirementContext.fromRequest(peers.registry, request),
      throwsA(isA<SessionFailure>()),
    );
  });

  test('retirement replies require the exact sealed operation and matching evidence', () async {
    final peers = await Peers.create();
    addTearDown(() {
      peers.a.revoke();
      peers.b.revoke();
    });
    final wire = jsonEncode({
      ...metadata,
      'type': 'retire',
      'transferSender': 'initiator',
      'outcome': 'cancelled',
    });
    final request = await peers.a.authorizeLocal(
      SessionOperation.file,
      'retire-1',
      wire,
    );
    final remote = await peers.b.open(await peers.a.sealRequest(request));
    final context = await FileRetirementContext.fromRequest(
      peers.registry,
      request,
    );
    final server = await FileRetirementContext.fromRequest(
      peers.registry,
      remote,
    );
    Future<FileMessage> reply(FileMessage message) async {
      final packet = await peers.b.sealSignal(
        remote,
        FileCodec.encode(message),
      );
      return context.decodeSignal(await peers.a.openSignal(request, packet));
    }

    final retired = FileRetired(transferId: id, transferOrdinal: 1);
    await server.validateReply(retired);
    expect(await reply(retired), isA<FileRetired>());
    final complete = FileComplete(
      transferId: id,
      actualName: 'report (1).txt',
      size: 3,
      sha256: metadata['sha256']! as String,
    );
    expect(await reply(complete), isA<FileComplete>());
    expect(
      await reply(FileRejected(transferId: id, code: 'invalid_state')),
      isA<FileRejected>(),
    );
    for (final message in <FileMessage>[
      FileRetired(transferId: id, transferOrdinal: 2),
      FileRetired(transferId: 'b' * 32, transferOrdinal: 1),
      FileComplete(
        transferId: id,
        actualName: 'report.txt',
        size: 4,
        sha256: metadata['sha256']! as String,
      ),
      FileFailed(transferId: id, code: 'io_failure'),
      FileCancelled(transferId: id),
      FileAck(transferId: id, nextOffset: 3),
    ]) {
      await expectLater(reply(message), throwsA(isA<FileProtocolFailure>()));
      await expectLater(
        server.validateReply(message),
        throwsA(isA<FileProtocolFailure>()),
      );
    }
    await expectLater(
      context.validateReply(retired),
      throwsA(isA<FileProtocolFailure>()),
    );
    final other = await peers.a.authorizeLocal(
      SessionOperation.file,
      'retire-2',
      wire,
    );
    final remoteOther = await peers.b.open(await peers.a.sealRequest(other));
    final foreignSignal = await peers.a.openSignal(
      other,
      await peers.b.sealSignal(remoteOther, FileCodec.encode(retired)),
    );
    await expectLater(
      context.decodeSignal(foreignSignal),
      throwsA(isA<FileProtocolFailure>()),
    );
  });
}
