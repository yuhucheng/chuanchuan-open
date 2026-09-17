import 'field_test_helpers.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/main.dart' as client;
import 'package:share_hub_open/ui/client_app.dart';

void main() {
  testWidgets('normal entry supplies the SDK without starting capture', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1180, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const platform = MethodChannel('dev.sharehub.client/platform');
    const discovery = MethodChannel('dev.sharehub.client/discovery');
    const media = MethodChannel('FlutterWebRTC.Method');
    final calls = <String>[];
    messenger.setMockMethodCallHandler(platform, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'loadDevice' => {'id': 'test-device', 'name': '测试电脑'},
        'permissions' => {'screenRecording': false, 'accessibility': false},
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(discovery, (_) async => null);
    messenger.setMockMethodCallHandler(media, (call) async {
      calls.add('media:${call.method}');
      return null;
    });
    addTearDown(() {
      for (final channel in [platform, discovery, media]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    client.main();
    await tester.pumpAndSettle();
    final app = tester.widget<ShareHubApp>(find.byType(ShareHubApp));
    expect(app.previewEngine, isNotNull);
    expect(app.previewEngine.unavailableReason, isNull);
    await openFieldTool(tester, '屏幕预览');
    await tester.pumpAndSettle();
    expect(find.text('读取屏幕与窗口'), findsOneWidget);
    expect(calls, isNot(contains('requestScreenRecording')));
    expect(calls.where((call) => call.startsWith('media:')), isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
