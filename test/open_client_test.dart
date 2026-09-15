import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/preview/preview_controller.dart';
import 'package:share_hub_open/features/preview/preview_engine.dart';
import 'package:share_hub_open/ui/client_app.dart';

import 'fakes.dart';
import 'file_fakes.dart';

void main() {
  test(
    'unavailable media never requests capture permission or starts',
    () async {
      final platform = FakePlatform();
      final controller = PreviewController(
        platform,
        const UnavailablePreviewEngine(),
      );
      await controller.loadSources();
      expect(controller.error, contains('未包含投屏引擎'));
      expect(controller.sources, isEmpty);
      controller.select(const CaptureSource('screen:1', 'screen'));
      await controller.start();
      expect(controller.active, isFalse);
      expect(platform.permissionRequests, 0);
      expect(controller.error, contains('未包含投屏引擎'));
      controller.dispose();
      await platform.events.close();
    },
  );

  for (final target in [TargetPlatform.windows, TargetPlatform.macOS]) {
    testWidgets('default open app keeps media unavailable on $target', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1180, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = FakePlatform();
      await tester.pumpWidget(
        ShareHubApp(
          platform: platform,
          fileAccess: TestFileAccess(),
          targetPlatform: target,
        ),
      );
      await tester.pumpAndSettle();
      expect(platform.starts, 0);
      await tester.tap(find.byTooltip('屏幕预览'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未包含投屏引擎'), findsOneWidget);
      expect(find.text('读取屏幕与窗口'), findsNothing);
      expect(find.text('开始预览'), findsNothing);
      expect(find.text('屏幕录制设置'), findsNothing);
      expect(platform.permissionRequests, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await platform.events.close();
    });
  }
}
