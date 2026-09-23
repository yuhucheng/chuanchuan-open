import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/transfers/receive_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sharehub.client/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late MethodChannelReceiveAccess access;
  final hash = 'a' * 64;
  final metadata = ReceiveMetadata(
    name: 'sample.bin',
    size: 5 * 1024 * 1024 * 1024,
    sha256: hash,
  );
  const directory = ReceiveDirectory(token: 'dir', label: '下载/串串');
  const scope = ReceiveScope(
    token: 'scope',
    key: 'authenticated-transfer',
    deadlineMicros: 429496729600,
  );
  final file = ReceiveFile(
    token: 'file',
    metadata: metadata,
    key: scope.key,
    deadlineMicros: scope.deadlineMicros,
  );

  setUp(() {
    calls.clear();
    access = MethodChannelReceiveAccess();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'files.receive.directoryConfigured' ||
        'files.receive.directoryPick' => {'token': 'dir', 'label': '下载/串串'},
        'files.receive.scopeOpen' => 'scope',
        'files.receive.scopeStop' => 'paused',
        'files.receive.begin' => 'file',
        'files.receive.append' =>
          (call.arguments['offset'] as int) +
              (call.arguments['bytes'] as Uint8List).length,
        'files.receive.checkpoint' => {
          'offset': 4294967296,
          'sha256': hash,
          'identity': 'file-id',
        },
        'files.receive.commit' => {
          'name': 'sample (1).bin',
          'size': metadata.size,
          'sha256': hash,
        },
        _ => null,
      };
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('native receipt is distinct from append acknowledgement and keeps actual name', () async {
    final target = await access.configuredDirectory();
    final permit = await access.openScope(
      key: scope.key,
      deadlineMicros: scope.deadlineMicros,
    );
    final entry = await access.begin(
      directory: target,
      scope: permit,
      metadata: metadata,
    );
    expect(
      await access.append(
        entry,
        permit,
        4294967296,
        Uint8List.fromList([1, 2]),
      ),
      4294967298,
    );
    final receipt = await access.commit(entry, permit);
    expect(receipt.name, 'sample (1).bin');
    expect(receipt.size, metadata.size);
    expect(calls[1].arguments, {
      'key': scope.key,
      'deadlineMicros': 429496729600,
    });
    expect(calls[2].arguments, {
      'directory': 'dir',
      'scope': 'scope',
      'name': 'sample.bin',
      'size': metadata.size,
      'sha256': hash,
    });
    expect(calls[3].arguments['offset'], 4294967296);
    expect(calls[3].arguments['bytes'], isA<Uint8List>());
    expect(calls.last.arguments, {'token': 'file', 'scope': 'scope'});
  });
  test(
    'pause checkpoint and resume preserve original deadline and file identity',
    () async {
      expect(
        await access.stopScope(scope, ReceiveStopMode.pause),
        ReceiveStopState.paused,
      );
      final snapshot = await access.checkpoint(file);
      final fresh = ReceiveScope(
        token: 'fresh',
        key: scope.key,
        deadlineMicros: scope.deadlineMicros,
      );
      await access.resume(file, fresh, snapshot);
      expect(calls.last.arguments, {
        'token': 'file',
        'scope': 'fresh',
        'offset': 4294967296,
        'sha256': hash,
        'identity': 'file-id',
      });
      expect(calls.first.arguments, {'scope': 'scope', 'mode': 'pause'});
    },
  );
  test('cancel exposes a commit already in progress instead of claiming cancellation', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => 'committing');
    expect(
      await access.stopScope(scope, ReceiveStopMode.cancel),
      ReceiveStopState.committing,
    );
  });
  test(
    'rebound key or extended deadline never reaches native storage',
    () async {
      for (final invalid in [
        ReceiveScope(
          token: 'wrong',
          key: 'other',
          deadlineMicros: scope.deadlineMicros,
        ),
        ReceiveScope(
          token: 'wrong',
          key: scope.key,
          deadlineMicros: scope.deadlineMicros + 1,
        ),
      ]) {
        await expectLater(
          access.append(file, invalid, 0, Uint8List(1)),
          throwsA(isA<ReceiveAccessFailure>()),
        );
        await expectLater(
          access.commit(file, invalid),
          throwsA(isA<ReceiveAccessFailure>()),
        );
        await expectLater(
          access.resume(
            file,
            invalid,
            ReceiveCheckpoint(offset: 0, sha256: hash, identity: 'id'),
          ),
          throwsA(isA<ReceiveAccessFailure>()),
        );
      }
      expect(calls, isEmpty);
    },
  );
  test(
    'invalid append and overrun are rejected before channel allocation',
    () async {
      for (final (offset, count) in [
        (0, 0),
        (0, 32769),
        (-1, 1),
        (metadata.size, 1),
      ]) {
        await expectLater(
          access.append(file, scope, offset, Uint8List(count)),
          throwsA(isA<ReceiveAccessFailure>()),
        );
      }
      expect(calls, isEmpty);
    },
  );
  test(
    'native short ack or invalid checkpoint is not accepted as progress',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => 0);
      await expectLater(
        access.append(file, scope, 0, Uint8List(1)),
        throwsA(isA<ReceiveAccessFailure>()),
      );
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'offset': metadata.size + 1,
          'sha256': hash,
          'identity': 'id',
        },
      );
      await expectLater(
        access.checkpoint(file),
        throwsA(isA<ReceiveAccessFailure>()),
      );
    },
  );
  test(
    'wrong native size digest or unsafe committed name never becomes receipt',
    () async {
      for (final result in [
        {'name': 'sample.bin', 'size': metadata.size - 1, 'sha256': hash},
        {'name': 'sample.bin', 'size': metadata.size, 'sha256': 'b' * 64},
        {'name': '../sample.bin', 'size': metadata.size, 'sha256': hash},
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => result);
        await expectLater(
          access.commit(file, scope),
          throwsA(isA<ReceiveAccessFailure>()),
        );
      }
    },
  );
  test('directory cancel and cleanup use exact opaque tokens only', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    expect(await access.pickDirectory(), isNull);
    await access.abort(file);
    await access.retryCleanup(file);
    await access.release(file);
    await access.closeScope(scope);
    await access.releaseDirectory(directory);
    expect(calls.map((call) => call.arguments), [
      null,
      'file',
      'file',
      'file',
      'scope',
      'dir',
    ]);
  });
  test('invalid native stop result is not treated as safe stop', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => 'unknown');
    await expectLater(
      access.stopScope(scope, ReceiveStopMode.cancel),
      throwsA(isA<ReceiveAccessFailure>()),
    );
  });
  test('native paused result cannot acknowledge cancellation', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => 'paused');
    await expectLater(
      access.stopScope(scope, ReceiveStopMode.cancel),
      throwsA(
        isA<ReceiveAccessFailure>().having(
          (error) => error.code,
          'code',
          'invalid_native_result',
        ),
      ),
    );
    expect(
      await access.stopScope(scope, ReceiveStopMode.pause),
      ReceiveStopState.paused,
    );
  });
  test('native disk failure remains a failure without a receipt', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'disk_full'),
    );
    await expectLater(
      access.commit(file, scope),
      throwsA(
        isA<ReceiveAccessFailure>().having((e) => e.code, 'code', 'disk_full'),
      ),
    );
  });
  test('native permission failure keeps its actionable code', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'permission_denied'),
    );
    await expectLater(
      access.begin(directory: directory, scope: scope, metadata: metadata),
      throwsA(
        isA<ReceiveAccessFailure>().having(
          (e) => e.code,
          'code',
          'permission_denied',
        ),
      ),
    );
  });
  test('unrecognized native error does not expose its code or details', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(
        code: r'C:\private\secret.txt',
        message: r'C:\private\secret.txt',
      ),
    );
    await expectLater(
      access.commit(file, scope),
      throwsA(
        isA<ReceiveAccessFailure>().having((e) => e.code, 'code', 'io_failure'),
      ),
    );
  });
}
