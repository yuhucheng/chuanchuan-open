import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/remote/windows_control_screen_geometry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sharehub.client/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final probe = WindowsControlScreenGeometryProbe();
  const source = CaptureSource('0', 'primary', type: CaptureSourceType.screen);

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('reads current native bounds for the exact screen source id', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'control.screenGeometry');
      expect(call.arguments, {'sourceId': '0'});
      return {
        'sourceId': '0',
        'left': -1920,
        'top': 0,
        'width': 1920,
        'height': 1080,
        'rotation': 90,
      };
    });
    final geometry = await probe.read(source);
    expect(geometry.left, -1920);
    expect(geometry.width, 1920);
    expect(geometry.rotation, 90);
  });

  test('never forwards window or noncanonical source ids', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return null;
    });
    await expectLater(
      probe.read(
        const CaptureSource('0', 'window', type: CaptureSourceType.window),
      ),
      throwsA(isA<SessionFailure>()),
    );
    await expectLater(
      probe.read(const CaptureSource('00', 'screen')),
      throwsA(isA<SessionFailure>()),
    );
    expect(calls, 0);
  });

  test('mismatched or malformed native geometry is rejected', () async {
    for (final value in [
      {
        'sourceId': '1',
        'left': 0,
        'top': 0,
        'width': 1920,
        'height': 1080,
        'rotation': 0,
      },
      {
        'sourceId': '0',
        'left': 0,
        'top': 0,
        'width': 0,
        'height': 1080,
        'rotation': 0,
      },
      {
        'sourceId': '0',
        'left': 0,
        'top': 0,
        'width': 1920,
        'height': 1080,
        'rotation': 45,
      },
      {
        'sourceId': '0',
        'left': 0x7fffffff,
        'top': 0,
        'width': 2,
        'height': 1080,
        'rotation': 0,
      },
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => value);
      await expectLater(probe.read(source), throwsA(isA<SessionFailure>()));
    }
  });

  test('native failures have fixed local error codes', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'source_unavailable',
        message: 'private device',
      );
    });
    await expectLater(
      probe.read(source),
      throwsA(
        isA<SessionFailure>().having(
          (e) => e.code,
          'code',
          'source_unavailable',
        ),
      ),
    );
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'other', message: 'private device');
    });
    await expectLater(
      probe.read(source),
      throwsA(
        isA<SessionFailure>().having(
          (e) => e.code,
          'code',
          'platform_unavailable',
        ),
      ),
    );
  });
}
