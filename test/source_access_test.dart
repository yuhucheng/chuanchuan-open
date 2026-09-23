import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/transfers/source_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sharehub.client/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final access = MethodChannelSourceAccess();
  const scope = SourceScope(
    token: 'scope',
    fileToken: 'picked',
    key: 'original',
    deadlineMicros: 429496729600,
  );
  const pass = SourceReadPass(id: 'pass', scope: scope);
  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'files.source.scopeOpen' => 'scope',
        'files.source.beginPass' => 'pass',
        'files.source.readPass' => Uint8List(call.arguments['length'] as int),
        'files.source.scopeStop' =>
          call.arguments['mode'] == 'pause' ? 'paused' : 'cancelled',
        _ => null,
      };
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'scope and each pass retain exact native selection and original deadline',
    () async {
      final opened = await access.openScope(
        fileToken: 'picked',
        key: 'original',
        deadlineMicros: scope.deadlineMicros,
      );
      final started = await access.beginPass(opened);
      expect((await access.readPass(started, 4294967296, 32768)).length, 32768);
      await access.finishPass(started);
      expect(calls[0].arguments, {
        'token': 'picked',
        'key': 'original',
        'deadlineMicros': scope.deadlineMicros,
      });
      expect(calls[1].arguments, {'token': 'picked', 'scope': 'scope'});
      expect(calls[2].arguments, {
        'token': 'picked',
        'scope': 'scope',
        'passId': 'pass',
        'offset': 4294967296,
        'length': 32768,
      });
      expect(calls[3].arguments, {
        'token': 'picked',
        'scope': 'scope',
        'passId': 'pass',
      });
    },
  );
  test(
    'stop and close use scope only and cannot claim cancellation from paused',
    () async {
      expect(
        await access.stopScope(scope, SourceStopMode.pause),
        SourceStopState.paused,
      );
      expect(
        await access.stopScope(scope, SourceStopMode.cancel),
        SourceStopState.cancelled,
      );
      await access.closeScope(scope);
      expect(calls.map((e) => e.arguments), [
        {'scope': 'scope', 'mode': 'pause'},
        {'scope': 'scope', 'mode': 'cancel'},
        'scope',
      ]);
      messenger.setMockMethodCallHandler(channel, (_) async => 'paused');
      await expectLater(
        access.stopScope(scope, SourceStopMode.cancel),
        throwsA(isA<SourceAccessFailure>()),
      );
    },
  );
  test('read range bounds fail before crossing channel', () async {
    for (final range in [
      (0, 0),
      (-1, 1),
      (0, 262145),
      (0x7fffffffffffffff, 1),
    ]) {
      await expectLater(
        access.readPass(pass, range.$1, range.$2),
        throwsA(isA<SourceAccessFailure>()),
      );
    }
    expect(calls, isEmpty);
  });
  test(
    'empty oversized or nul capabilities and invalid deadlines are rejected',
    () async {
      for (final token in ['', 'x\u0000y', '界' * 86]) {
        await expectLater(
          access.openScope(fileToken: token, key: 'key', deadlineMicros: 10),
          throwsA(isA<SourceAccessFailure>()),
        );
        await expectLater(
          access.openScope(fileToken: 'file', key: token, deadlineMicros: 10),
          throwsA(isA<SourceAccessFailure>()),
        );
      }
      for (final deadline in [0, -1]) {
        await expectLater(
          access.openScope(
            fileToken: 'file',
            key: 'key',
            deadlineMicros: deadline,
          ),
          throwsA(isA<SourceAccessFailure>()),
        );
      }
      expect(calls, isEmpty);
    },
  );
  test(
    'native malformed tokens and stop results are not usable capabilities',
    () async {
      for (final value in [null, '', 'x\u0000y', 'x' * 257, 42]) {
        messenger.setMockMethodCallHandler(channel, (_) async => value);
        await expectLater(
          access.beginPass(scope),
          throwsA(isA<SourceAccessFailure>()),
        );
        await expectLater(
          access.openScope(fileToken: 'file', key: 'key', deadlineMicros: 10),
          throwsA(isA<SourceAccessFailure>()),
        );
        await expectLater(
          access.stopScope(scope, SourceStopMode.pause),
          throwsA(isA<SourceAccessFailure>()),
        );
      }
    },
  );
  test(
    'short oversized or incorrectly typed native read is never accepted',
    () async {
      for (final value in [
        null,
        <int>[1, 2],
        Uint8List(1),
        Uint8List(3),
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => value);
        await expectLater(
          access.readPass(pass, 0, 2),
          throwsA(isA<SourceAccessFailure>()),
        );
      }
    },
  );
  test('native expiry failure remains observable', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'expired'),
    );
    await expectLater(
      access.readPass(pass, 0, 2),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'expired'),
      ),
    );
  });
}
