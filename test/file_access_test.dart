import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('dev.sharehub.client/platform');
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'picker and chunk calls use tokens, typed bytes, and 64-bit offsets',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'files.pick') {
          return [
            {
              'token': 'selected',
              'name': 'large.bin',
              'size': 5 * 1024 * 1024 * 1024,
            },
          ];
        }
        if (call.method == 'files.read') return Uint8List.fromList([1, 2]);
        return null;
      });
      final access = MethodChannelFileAccess();
      final file = (await access.pickFiles()).single;
      expect(file.size, 5 * 1024 * 1024 * 1024);
      expect(await access.read(file.token, 4 * 1024 * 1024 * 1024, 2), [1, 2]);
      await access.finish(file.token);
      await access.release(file.token);
      expect(calls[1].arguments, {
        'token': 'selected',
        'offset': 4294967296,
        'length': 2,
      });
      expect(calls.map((call) => call.method), [
        'files.pick',
        'files.read',
        'files.finish',
        'files.release',
      ]);
    },
  );

  test('read passes carry the native generation unchanged', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'files.beginReadPass') return 'pass-2';
      if (call.method == 'files.readPass') return Uint8List.fromList([7]);
      return null;
    });
    final ReReadableFileAccess access = MethodChannelFileAccess();
    final pass = await access.beginReadPass('selected');
    expect(await access.readPass('selected', pass, 4294967296, 1), [7]);
    await access.finishPass('selected', pass);
    expect(calls.map((call) => call.method), [
      'files.beginReadPass',
      'files.readPass',
      'files.finishPass',
    ]);
    expect(calls.first.arguments, 'selected');
    expect(calls[1].arguments, {
      'token': 'selected',
      'passId': 'pass-2',
      'offset': 4294967296,
      'length': 1,
    });
    expect(calls.last.arguments, {'token': 'selected', 'passId': 'pass-2'});
  });

  test('native picker cancellation is an empty selection', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => []);
    expect(await MethodChannelFileAccess().pickFiles(), isEmpty);
  });
}
