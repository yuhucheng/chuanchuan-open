import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('dev.sharehub.client/platform');
  const dropChannel = MethodChannel('dev.sharehub.client/files/drop');
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    MethodChannelFileAccess().setDropHandler(null);
  });

  test(
    'native drop passes only tokens and acknowledges queue ownership',
    () async {
      final access = MethodChannelFileAccess();
      List<SelectedFile>? received;
      access.setDropHandler((files) async {
        received = files;
      });
      const codec = StandardMethodCodec();
      final response = await messenger.handlePlatformMessage(
        dropChannel.name,
        codec.encodeMethodCall(
          const MethodCall('files.dropped', [
            {'token': 'native-token', 'name': 'file.txt', 'size': 3},
          ]),
        ),
        null,
      );
      expect(codec.decodeEnvelope(response!), true);
      expect(received?.single.token, 'native-token');
      expect(received?.single.name, 'file.txt');
    },
  );

  test(
    'native drop error is reported and malformed payload is refused',
    () async {
      final access = MethodChannelFileAccess();
      String? error;
      access.setDropHandler(
        (_) async {},
        onError: (message) => error = message,
      );
      const codec = StandardMethodCodec();
      final shown = await messenger.handlePlatformMessage(
        dropChannel.name,
        codec.encodeMethodCall(const MethodCall('files.dropError', '拒绝')),
        null,
      );
      expect(codec.decodeEnvelope(shown!), true);
      expect(error, '拒绝');
      final malformed = await messenger.handlePlatformMessage(
        dropChannel.name,
        codec.encodeMethodCall(
          const MethodCall('files.dropped', [
            {'path': r'C:\unauthorized.txt'},
          ]),
        ),
        null,
      );
    expect(() => codec.decodeEnvelope(malformed!), throwsA(isA<PlatformException>()));
    },
  );

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

  test('native picker cancellation is an empty selection', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => []);
    expect(await MethodChannelFileAccess().pickFiles(), isEmpty);
  });
}
