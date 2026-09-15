import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/platform/mac_platform.dart';
import 'package:share_hub_open/ui/client_app.dart';

import 'fakes.dart';
import 'file_fakes.dart';

void main() {
  testWidgets(
    'Windows keeps discovery opt-in and hides unavailable native actions',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = FakePlatform()
        ..status = const PermissionStatus(screenRecording: true);
      final engine = FakePreviewEngine();
      final files = TestFileAccess();
      await tester.pumpWidget(
        ShareHubApp(
          targetPlatform: TargetPlatform.windows,
          platform: platform,
          previewEngine: engine,
          fileAccess: files,
        ),
      );
      await tester.pumpAndSettle();
      expect(platform.starts, 0);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(platform.starts, 1);
      await tester.tap(find.byTooltip('文件传送'));
      await tester.pumpAndSettle();
      expect(find.text('选择文件'), findsNothing);
      expect(find.textContaining('Windows 文件准备功能开发中'), findsOneWidget);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('辅助功能'), findsNothing);
      expect(find.text('已允许'), findsNothing);
      expect(find.text('远程控制'), findsOneWidget);
      await tester.tap(find.byTooltip('屏幕预览'));
      await tester.pumpAndSettle();
      expect(find.text('屏幕录制设置'), findsNothing);
      await tester.tap(find.text('读取屏幕与窗口'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('开始预览'));
      engine.failStart = true;
      await tester.tap(find.text('开始预览'));
      await tester.pumpAndSettle();
      expect(find.textContaining('屏幕录制权限'), findsNothing);
      expect(find.textContaining('重新选择画面'), findsOneWidget);
      engine.failStart = false;
      await tester.tap(find.text('开始预览'));
      await tester.pumpAndSettle();
      expect(engine.starts, 2);
      expect(platform.permissionRequests, 0);
      engine.firstFrame!();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设备'));
      await tester.pumpAndSettle();
      expect(engine.released, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await platform.events.close();
      expect(files.picks, 0);
      expect(files.reads, isEmpty);
      expect(files.finished, isEmpty);
      expect(files.releases, isEmpty);
    },
  );

  testWidgets('honest empty state and opt-in discovery', (tester) async {
    tester.view.physicalSize = const Size(1180, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final platform = FakePlatform();
    await tester.pumpWidget(
      ShareHubApp(
        targetPlatform: TargetPlatform.macOS,
        platform: platform,
        previewEngine: FakePreviewEngine(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('从这台 Mac 开始'), findsOneWidget);
    expect(find.textContaining('尚未接入邀请码激活'), findsOneWidget);
    expect(platform.starts, 0);
    expect(platform.permissionRequests, 0);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(platform.starts, 1);
    expect(find.text('还没有发现其他设备'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await platform.events.close();
  });

  testWidgets(
    'preview stops when navigating away; compact window has no overflow',
    (tester) async {
      tester.view.physicalSize = const Size(860, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = FakePlatform()
        ..status = const PermissionStatus(screenRecording: true);
      final engine = FakePreviewEngine();
      await tester.pumpWidget(
        ShareHubApp(
          targetPlatform: TargetPlatform.macOS,
          platform: platform,
          previewEngine: engine,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('预览本机屏幕'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('读取屏幕与窗口'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('开始预览'));
      await tester.tap(find.text('开始预览'));
      await tester.pumpAndSettle();
      expect(engine.starts, 1);
      engine.firstFrame!();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(engine.released, true);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), '客厅 Mac');
      await tester.ensureVisible(find.text('保存名称'));
      await tester.tap(find.text('保存名称'));
      await tester.pumpAndSettle();
      expect(platform.device.name, '客厅 Mac');
      expect(find.text('设备名称已保存'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await platform.events.close();
    },
  );
}
