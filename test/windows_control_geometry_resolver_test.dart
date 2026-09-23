import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/remote/windows_control_geometry_resolver.dart';
import 'package:share_hub_open/features/remote/windows_control_pointer_input.dart';
import 'package:share_hub_open/features/remote/windows_control_screen_geometry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sharehub.client/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const source = CaptureSource('0', 'screen', type: CaptureSourceType.screen);
  final presented = VideoPresentationReceipt(
    revision: 2,
    width: 1280,
    height: 720,
  );
  var calls = 0;

  setUp(() {
    calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      expect(call.method, 'control.screenGeometry');
      expect(call.arguments, {'sourceId': '0'});
      return {
        'sourceId': '0',
        'left': -1920,
        'top': 100,
        'width': 1920,
        'height': 1080,
        'rotation': 90,
      };
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('binds authenticated frame pixels to native display extent', () async {
    final resolver = WindowsControlGeometryResolver(
      probe: WindowsControlScreenGeometryProbe(channel: channel),
      sourceToken: () => 'a' * 32,
    );
    final geometry = await resolver.resolve(
      source: source,
      presented: presented,
      mediaRevision: 2,
    );
    expect(calls, 1);
    expect(geometry.sourceToken, 'a' * 32);
    expect(geometry.revision, 1);
    expect(geometry.mediaRevision, 2);
    expect((geometry.width, geometry.height), (1280, 720));
    expect((geometry.originX, geometry.originY), (-1920, 100));
    expect(geometry.scaleX, (1920 - 1) / (1280 - 1));
    expect(geometry.scaleY, (1080 - 1) / (720 - 1));
    expect(geometry.rotation, 90);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'control.pointer.open') {
        return {
          'lease': 7,
          'sourceId': '0',
          'left': -1920,
          'top': 100,
          'width': 1920,
          'height': 1080,
          'rotation': 90,
        };
      }
      expect(call.method, 'control.pointer.close');
      return null;
    });
    final input = await WindowsControlPointerInput.open(
      source: source,
      geometry: geometry,
      channel: channel,
    );
    await input.close();
  });

  test('rejects stale frame before probing native source', () async {
    final resolver = WindowsControlGeometryResolver(
      probe: WindowsControlScreenGeometryProbe(channel: channel),
      sourceToken: () => 'a' * 32,
    );
    await expectLater(
      resolver.resolve(source: source, presented: presented, mediaRevision: 3),
      throwsA(isA<SessionFailure>()),
    );
    expect(calls, 0);
  });

  test(
    'rejects one-pixel frame when native extent spans many pixels',
    () async {
      final resolver = WindowsControlGeometryResolver(
        probe: WindowsControlScreenGeometryProbe(channel: channel),
        sourceToken: () => 'a' * 32,
      );
      await expectLater(
        resolver.resolve(
          source: source,
          presented: VideoPresentationReceipt(
            revision: 2,
            width: 1,
            height: 720,
          ),
          mediaRevision: 2,
        ),
        throwsA(isA<SessionFailure>()),
      );
      expect(calls, 1);
    },
  );
}
