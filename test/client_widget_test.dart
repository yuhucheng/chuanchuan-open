import 'field_test_helpers.dart';

import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/platform/mac_platform.dart';
import 'package:share_hub_open/features/preview/preview_engine.dart';
import 'package:share_hub_open/ui/client_app.dart';

import 'fakes.dart';
import 'file_fakes.dart';

void main() {
  testWidgets(
    'macOS native drop reaches the local queue and releases on removal',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const drops = MethodChannel('dev.sharehub.client/file-drop');
      const native = MethodChannel('dev.sharehub.client/platform');
      const codec = StandardMethodCodec();
      final events = <String>[], released = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(drops, (
        call,
      ) async {
        events.add(call.method);
        return null;
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        if (call.method == 'files.finish') return null;
        if (call.method == 'files.release') {
          released.add(call.arguments as String);
          return null;
        }
        throw MissingPluginException();
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          drops,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          native,
          null,
        );
      });
      final platform = FakePlatform();
      await tester.pumpWidget(
        ShareHubApp(
          targetPlatform: TargetPlatform.macOS,
          platform: platform,
          previewEngine: FakePreviewEngine(),
        ),
      );
      await tester.pumpAndSettle();
      expect(events, ['listen']);
      Future<Object?> invoke(String method, Object? arguments) {
        final result = Completer<Object?>();
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          drops.name,
          codec.encodeMethodCall(MethodCall(method, arguments)),
          (reply) => result.complete(
            reply == null ? null : codec.decodeEnvelope(reply),
          ),
        );
        return result.future;
      }

      final point = tester.getCenter(
        find.byKey(const ValueKey('local-device')),
      );
      expect(await invoke('locate', {'x': point.dx, 'y': point.dy}), true);
      expect(
        await invoke('drop', {
          'x': point.dx,
          'y': point.dy,
          'files': [
            {'token': 'os-drop', 'name': '来自访达.txt', 'size': 0},
          ],
        }),
        true,
      );
      await tester.pumpAndSettle();
      expect(find.text('来自访达.txt'), findsOneWidget);
      await tester.tap(find.text('清空队列'));
      await tester.pumpAndSettle();
      expect(released, ['os-drop']);
      expect(find.text('来自访达.txt'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(events, ['listen', 'cancel']);
      await platform.events.close();
    },
  );
  testWidgets(
    'parent rebuild keeps capture and visible texture on the same engine',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = FakePlatform()
        ..status = const PermissionStatus(screenRecording: true);
      final engine = _NamedEngine('original texture');
      await tester.pumpWidget(
        ShareHubApp(
          targetPlatform: TargetPlatform.macOS,
          platform: platform,
          previewEngine: engine,
        ),
      );
      await tester.pumpAndSettle();
      await openFieldTool(tester, '屏幕预览');
      await tester.pumpAndSettle();
      await tester.tap(find.text('读取屏幕与窗口'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<CaptureSource>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示器 · 内建显示器').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始预览'));
      await tester.pumpAndSettle();
      engine.firstFrame!();
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        ShareHubApp(
          targetPlatform: TargetPlatform.macOS,
          platform: platform,
          previewEngine: _NamedEngine('replacement texture'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('original texture'), findsOneWidget);
      expect(find.text('replacement texture'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(engine.closed, true);
      await platform.events.close();
    },
  );
  testWidgets(
    'Windows automatically discovers and exposes local file preparation',
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
      expect(find.byType(Switch), findsNothing);
      expect(platform.starts, 1);
      await openFieldTool(tester, '文件传送');
      await tester.pumpAndSettle();
      expect(find.text('选择文件'), findsOneWidget);
      await tester.tap(find.text('选择文件'));
      await tester.pumpAndSettle();
      expect(files.picks, 1);
      expect(find.text('先加入想分享的文件'), findsOneWidget);
      await openFieldTool(tester, '设置');
      await tester.pumpAndSettle();
      expect(find.text('辅助功能'), findsNothing);
      expect(find.text('已允许'), findsNothing);
      expect(find.textContaining('文件接收位置可在文件页面更改'), findsOneWidget);
      await openFieldTool(tester, '屏幕预览');
      await tester.pumpAndSettle();
      expect(find.text('屏幕录制设置'), findsNothing);
      await tester.tap(find.text('读取屏幕与窗口'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<CaptureSource>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示器 · 内建显示器').last);
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
      final stopsBeforeNavigation = engine.stops;
      await closeFieldPanel(tester);
      await tester.pumpAndSettle();
      expect(engine.stops, stopsBeforeNavigation);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await platform.events.close();
      expect(files.picks, 1);
      expect(files.reads, isEmpty);
      expect(files.finished, isEmpty);
      expect(files.releases, isEmpty);
    },
  );

  testWidgets('honest empty state and automatic discovery', (tester) async {
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
    expect(find.byKey(const ValueKey('local-device')), findsOneWidget);

    expect(platform.starts, 1);
    expect(platform.permissionRequests, 0);
    expect(find.text('你 · 允许连接已关闭'), findsOneWidget);
    expect(platform.starts, 1);
    expect(find.text('还没有发现其他设备'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await platform.events.close();
  });

  testWidgets(
    'preview survives navigation and hidden window without duplicate capture',
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
      await openFieldTool(tester, '屏幕预览');
      await tester.pumpAndSettle();
      await tester.tap(find.text('读取屏幕与窗口'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<CaptureSource>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示器 · 内建显示器').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('开始预览'));
      await tester.tap(find.text('开始预览'));
      await tester.pumpAndSettle();
      expect(engine.starts, 1);
      engine.firstFrame!();
      await tester.pumpAndSettle();
      await openFieldTool(tester, '设置');
      await tester.pumpAndSettle();
      expect(engine.released, false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(engine.released, false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(engine.starts, 1);
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.byKey(const ValueKey('device-name')),
        '客厅 Mac',
      );
      await tester.ensureVisible(find.text('保存名称'));
      await tester.tap(find.text('保存名称'));
      await tester.pumpAndSettle();
      expect(platform.device.name, '客厅 Mac');
      expect(find.text('客厅 Mac'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await platform.events.close();
    },
  );

  testWidgets('Windows exit waits for active capture to stop', (tester) async {
    tester.view.physicalSize = const Size(1180, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final platform = FakePlatform()
      ..status = const PermissionStatus(screenRecording: true);
    final engine = _DelayedStopEngine();
    await tester.pumpWidget(
      ShareHubApp(
        targetPlatform: TargetPlatform.windows,
        platform: platform,
        previewEngine: engine,
      ),
    );
    await tester.pumpAndSettle();
    await openFieldTool(tester, '屏幕预览');
    await tester.pumpAndSettle();
    await tester.tap(find.text('读取屏幕与窗口'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<CaptureSource>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示器 · 内建显示器').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始预览'));
    await tester.pumpAndSettle();
    engine.firstFrame!();
    await tester.pump();

    engine.stopGate = Completer<void>();
    final exitRequest = WidgetsBinding.instance.handleRequestAppExit();
    final repeatedExitRequest = WidgetsBinding.instance.handleRequestAppExit();
    var answered = false;
    exitRequest.then((_) => answered = true);
    await tester.pump();
    expect(engine.stopEntered, 1);
    expect(answered, false);
    engine.stopGate!.complete();
    expect(await finishExit(tester, exitRequest), AppExitResponse.exit);
    expect(await finishExit(tester, repeatedExitRequest), AppExitResponse.exit);
    expect(engine.released, true);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await platform.events.close();
  });

  testWidgets(
    'Windows exit cancels after failed capture cleanup and permits retry',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = FakePlatform()
        ..status = const PermissionStatus(screenRecording: true);
      final engine = FakePreviewEngine();
      await tester.pumpWidget(
        ShareHubApp(
          targetPlatform: TargetPlatform.windows,
          platform: platform,
          previewEngine: engine,
        ),
      );
      await tester.pumpAndSettle();
      await openFieldTool(tester, '屏幕预览');
      await tester.pumpAndSettle();
      await tester.tap(find.text('读取屏幕与窗口'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<CaptureSource>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示器 · 内建显示器').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始预览'));
      await tester.pumpAndSettle();
      engine.firstFrame!();
      await tester.pump();

      engine.failStop = true;
      final cancelledExit = WidgetsBinding.instance.handleRequestAppExit();
      await tester.pumpAndSettle();
      expect(await cancelledExit, AppExitResponse.cancel);
      await tester.pump();
      expect(find.textContaining('屏幕采集释放失败'), findsOneWidget);
      engine.failStop = false;
      await tester.tap(find.text('停止预览').last);
      await tester.pump();
      expect(engine.released, true);
      expect(
        await finishExit(
          tester,
          WidgetsBinding.instance.handleRequestAppExit(),
        ),
        AppExitResponse.exit,
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await platform.events.close();
    },
  );
}

class _NamedEngine extends FakePreviewEngine {
  _NamedEngine(this.label);
  final String label;
  @override
  Widget get view => Text(label);
}

class _DelayedStopEngine extends FakePreviewEngine {
  Completer<void>? stopGate;
  int stopEntered = 0;

  @override
  Future<void> stop() async {
    stopEntered++;
    await stopGate?.future;
    await super.stop();
  }
}

// Cancellation can await a shared Future created outside the widget fake clock.
// Flush both queues and fail with a bounded assertion instead of hanging.
Future<AppExitResponse> finishExit(
  WidgetTester tester,
  Future<AppExitResponse> request,
) async {
  AppExitResponse? response;
  request.then((value) => response = value);
  for (var i = 0; i < 20 && response == null; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  expect(response, isNotNull, reason: 'Exit cleanup must complete');
  return response!;
}
