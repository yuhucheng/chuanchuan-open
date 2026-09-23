import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';
import 'package:share_hub_open/features/transfers/source_access.dart';
import 'package:share_hub_open/features/transfers/verified_file_source.dart';

void main() {
  late _MemoryFile access;
  late GrantEndpoint grant, peer;
  late GrantRegistry registry;
  late int now;
  setUp(() async {
    now = 100;
    final binding = GrantBinding(
      id: List.filled(32, 41),
      initiatorKey: List.filled(32, 42),
      receiverKey: List.filled(32, 43),
    );
    GrantEndpoint make(GrantRole role) =>
        GrantEndpoint.fromAuthenticatedPairing(
          binding: binding,
          role: role,
          establishedMicros: now,
          recoverySecret: List.filled(32, 44),
          clock: () async => now,
          onInvalidated: () {},
        );
    grant = make(GrantRole.initiator);
    peer = make(GrantRole.receiver);
    registry = GrantRegistry()..register(grant);
    final hello = await grant.beginResume();
    final response = await peer.answerResume(hello);
    await peer.acceptResume(await grant.finishResume(response));
    access = _MemoryFile(
      Uint8List.fromList(List.generate(70000, (i) => i % 251)),
    );
  });
  tearDown(() {
    grant.revoke();
    peer.revoke();
  });

  Future<VerifiedFileSource> source() async {
    final request = await grant.authorizeLocal(
      SessionOperation.file,
      'file',
      FileCodec.encode(
        FileOffer(
          transferOrdinal: 1,
          transferId: 'a' * 32,
          name: 'sample.bin',
          size: access.bytes.length,
          sha256: hashes.sha256.convert(access.bytes).toString(),
          chunkBytes: FileLimits.chunkBytes,
        ),
      ),
    );
    final context = await FileTransferContext.fromRequest(registry, request);
    return VerifiedFileSource(
      access: access,
      file: SelectedFile(
        token: 'picked',
        name: 'sample.bin',
        size: access.bytes.length,
      ),
      context: context,
    );
  }

  Future<VerifiedFileSource> resumedSource() async {
    final original = await source();
    await original.pause();
    final metadata = original.context.request as FileOffer;
    final request = await grant.authorizeLocal(
      SessionOperation.file,
      'resumed',
      FileCodec.encode(
        FileResume(
          transferOrdinal: 1,
          transferId: metadata.transferId,
          name: metadata.name,
          size: metadata.size,
          sha256: metadata.sha256,
          chunkBytes: metadata.chunkBytes,
          attemptId: 'b' * 32,
        ),
      ),
    );
    final context = await original.context.resumeWith(request);
    final resumed = VerifiedFileSource(
      access: access,
      file: original.file,
      context: context,
    );
    await resumed.verify();
    await original.close();
    return resumed;
  }

  for (final offset in [0, 32769, 70000]) {
    test(
      'resume rehashes prefix $offset sequentially in the sending pass',
      () async {
        final s = await resumedSource();
        final prefix = hashes.sha256
            .convert(access.bytes.sublist(0, offset))
            .toString();
        await s.beginSend(offset: offset, prefixSha256: prefix);
        expect(access.offset, offset);
        expect(
          access.readLengths.skip(1),
          everyElement(lessThanOrEqualTo(FileLimits.chunkBytes)),
        );
        expect(
          access.readLengths.every((length) => length <= 256 * 1024),
          isTrue,
        );
        final remainder = <int>[];
        while (true) {
          final block = await s.readNext();
          if (block == null) break;
          remainder.addAll(block);
        }
        expect(remainder, access.bytes.sublist(offset));
        await s.finishSend();
        expect(access.finished, [1, 2]);
        await s.close();
      },
    );
  }
  test('wrong resume prefix fails before sending remainder', () async {
    final s = await resumedSource();
    await expectLater(
      s.beginSend(offset: 32769, prefixSha256: '0' * 64),
      throwsA(isA<FileSourceFailure>()),
    );
    expect(s.phase, SourcePhase.failed);
    expect(access.offset, 32769);
    await s.close();
  });
  test('initial offer cannot use a peer chosen resume offset', () async {
    final s = await source();
    await s.verify();
    await expectLater(
      s.beginSend(offset: 3, prefixSha256: '0' * 64),
      throwsA(isA<FileSourceFailure>()),
    );
    expect(access.passes, 1);
    await s.close();
  });
  test('resume requires a prefix even at offset zero', () async {
    final s = await resumedSource();
    await expectLater(s.beginSend(), throwsA(isA<FileSourceFailure>()));
    expect(access.passes, 1);
    await s.close();
  });
  test('cancel during prefix reading cannot activate resumed send', () async {
    final s = await resumedSource();
    access.gate = Completer<void>();
    final sending = s.beginSend(
      offset: 3,
      prefixSha256: hashes.sha256
          .convert(access.bytes.sublist(0, 3))
          .toString(),
    );
    final rejected = expectLater(sending, throwsA(isA<FileSourceFailure>()));
    await access.entered.future;
    await s.cancel();
    access.gate!.complete();
    await rejected;
    expect(s.phase, SourcePhase.cancelled);
    await s.close();
  });

  test(
    'ready EOF is rehashed then a separate pass pulls bounded send blocks',
    () async {
      final s = await source();
      await s.verify();
      expect(access.passes, 1);
      expect(access.finished, [1]);
      await s.beginSend();
      expect(access.passes, 2);
      expect(access.offset, 0);
      final first = await s.readNext();
      expect(first!.length, 32768);
      expect(
        access.offset,
        32768,
      ); // No read-ahead while peer acknowledgement waits.
      final collected = <int>[...first];
      while (true) {
        final next = await s.readNext();
        if (next == null) break;
        collected.addAll(next);
      }
      await s.finishSend();
      expect(collected, access.bytes);
      expect(access.finished, [1, 2]);
      expect(s.phase, SourcePhase.finished);
    },
  );
  test(
    'same-length mutation after ready refuses the offer prerequisite',
    () async {
      final s = await source();
      access.bytes[0] ^= 1;
      await expectLater(s.verify(), throwsA(isA<FileSourceFailure>()));
      expect(s.phase, SourcePhase.failed);
      await expectLater(s.beginSend(), throwsA(isA<FileSourceFailure>()));
      expect(access.passes, 1);
    },
  );
  test(
    'cancellation during native read discards late bytes and stops reads',
    () async {
      final s = await source();
      await s.verify();
      await s.beginSend();
      access.gate = Completer<void>();
      final pending = s.readNext();
      await access.entered.future;
      s.cancel();
      expect(access.stops, [SourceStopMode.cancel]);
      access.gate!.complete();
      await expectLater(pending, throwsA(isA<FileSourceFailure>()));
      final count = access.reads;
      await expectLater(s.readNext(), throwsA(isA<FileSourceFailure>()));
      expect(access.reads, count);
    },
  );
  test('revocation during native read rejects the result', () async {
    final s = await source();
    await s.verify();
    await s.beginSend();
    access.gate = Completer<void>();
    final pending = s.readNext();
    await access.entered.future;
    grant.revoke();
    expect(access.stops, [SourceStopMode.cancel]);
    access.gate!.complete();
    await expectLater(pending, throwsA(isA<SessionFailure>()));
    expect(s.phase, SourcePhase.failed);
  });
  test('expiry prevents a new native pass', () async {
    final s = await source();
    now += grantLifetime.inMicroseconds;
    await expectLater(s.verify(), throwsA(isA<SessionFailure>()));
    expect(access.passes, 0);
  });
  test('empty file runs both final native checks without data reads', () async {
    access = _MemoryFile(Uint8List(0));
    final s = await source();
    await s.verify();
    await s.beginSend();
    expect(await s.readNext(), isNull);
    await s.finishSend();
    expect(access.finished, [1, 2]);
    expect(access.reads, 0);
  });
  test('parallel reads do not allocate or advance another block', () async {
    final s = await source();
    await s.verify();
    await s.beginSend();
    access.gate = Completer<void>();
    final pending = s.readNext();
    await access.entered.future;
    await expectLater(s.readNext(), throwsA(isA<FileSourceFailure>()));
    access.gate!.complete();
    expect((await pending)!.length, 32768);
  });
  test(
    'send pass independently hashes content and rejects silent mutation',
    () async {
      final s = await source();
      await s.verify();
      access.bytes[0] ^= 1; // Model a mutation not caught by native metadata.
      await s.beginSend();
      while (await s.readNext() != null) {}
      await expectLater(s.finishSend(), throwsA(isA<FileSourceFailure>()));
      await s.whenStopped;
      expect(access.stops, [SourceStopMode.cancel]);
    },
  );
  test('pause gates immediately and discards an admitted late read', () async {
    final s = await source();
    await s.verify();
    await s.beginSend();
    access.gate = Completer<void>();
    final reading = s.readNext();
    final rejected = expectLater(reading, throwsA(isA<FileSourceFailure>()));
    await access.entered.future;
    await s.pause();
    expect(access.stops, [SourceStopMode.pause]);
    grant.suspend();
    access.gate!.complete();
    await rejected;
    expect(s.phase, SourcePhase.paused);
    expect(access.stops, [SourceStopMode.pause]);
    await s.close();
  });
  test(
    'cancel during scope opening owns and stops late native scope',
    () async {
      access.scopeGate = Completer<void>();
      final s = await source();
      final pending = s.verify();
      final rejected = expectLater(pending, throwsA(isA<SessionFailure>()));
      await access.scopeEntered.future;
      final stopping = s.cancel();
      access.scopeGate!.complete();
      await rejected;
      await stopping;
      expect(access.stops, [SourceStopMode.cancel]);
      expect(access.passes, 0);
      await s.close();
      expect(access.closed, 1);
    },
  );
  test(
    'cancel during final native check cannot report source finished',
    () async {
      final s = await source();
      await s.verify();
      await s.beginSend();
      while (await s.readNext() != null) {}
      access.finishGate = Completer<void>();
      final pending = s.finishSend();
      final rejected = expectLater(pending, throwsA(isA<FileSourceFailure>()));
      await access.finishEntered.future;
      await s.cancel();
      access.finishGate!.complete();
      await rejected;
      expect(s.phase, SourcePhase.cancelled);
      await s.close();
    },
  );
}

class _MemoryFile implements SourceAccess {
  _MemoryFile(this.bytes) : offset = bytes.length;
  final Uint8List bytes;
  int passes = 0, offset, reads = 0;
  final finished = <int>[];
  final readLengths = <int>[];
  Completer<void>? gate;
  final entered = Completer<void>();
  Completer<void>? scopeGate, finishGate;
  final scopeEntered = Completer<void>(), finishEntered = Completer<void>();
  final stops = <SourceStopMode>[];
  int closed = 0;
  @override
  Future<SourceScope> openScope({
    required String fileToken,
    required String key,
    required int deadlineMicros,
  }) async {
    scopeEntered.complete();
    if (scopeGate != null) await scopeGate!.future;
    return SourceScope(
      token: 'scope',
      fileToken: fileToken,
      key: key,
      deadlineMicros: deadlineMicros,
    );
  }

  @override
  Future<SourceStopState> stopScope(
    SourceScope scope,
    SourceStopMode mode,
  ) async {
    stops.add(mode);
    return mode == SourceStopMode.pause
        ? SourceStopState.paused
        : SourceStopState.cancelled;
  }

  @override
  Future<void> closeScope(SourceScope scope) async {
    closed++;
  }

  @override
  Future<SourceReadPass> beginPass(SourceScope scope) async {
    offset = 0;
    return SourceReadPass(id: '${++passes}', scope: scope);
  }

  @override
  Future<Uint8List> readPass(SourceReadPass pass, int at, int length) async {
    expect(pass.id, '$passes');
    expect(at, offset);
    expect(length, lessThanOrEqualTo(256 * 1024));
    reads++;
    readLengths.add(length);
    if (gate != null) {
      if (!entered.isCompleted) entered.complete();
      await gate!.future;
    }
    final result = Uint8List.fromList(bytes.sublist(at, at + length));
    offset += length;
    return result;
  }

  @override
  Future<void> finishPass(SourceReadPass pass) async {
    expect(pass.id, '$passes');
    expect(offset, bytes.length);
    if (finishGate != null) {
      finishEntered.complete();
      await finishGate!.future;
    }
    finished.add(passes);
  }
}
