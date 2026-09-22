import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/platform/client_platform.dart';
import 'package:share_hub_open/ui/client_app.dart';
import 'package:share_hub_open/ui/field/appearance.dart';

import 'fakes.dart';
import 'field_test_helpers.dart';

class _PermissionReadPlatform extends FakePlatform {
  bool fail = true;
  @override
  Future<PermissionStatus> permissions() async {
    if (fail) throw PlatformException(code: 'permission_query_failed');
    return super.permissions();
  }
}

void main() {
  Future<void> mount(WidgetTester tester, FakePlatform platform) async {
    await tester.pumpWidget(
      ShareHubApp(
        targetPlatform: TargetPlatform.macOS,
        platform: platform,
        previewEngine: FakePreviewEngine(),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await platform.events.close();
    });
  }

  Finder inDialog(Key key) =>
      find.descendant(of: find.byType(AlertDialog), matching: find.byKey(key));

  testWidgets('initial device failure retries loading and starts discovery', (
    tester,
  ) async {
    final platform = FakePlatform()
      ..loadError = PlatformException(code: 'load_failed', message: '无法读取本机资料');
    await mount(tester, platform);
    expect(platform.starts, 0);
    expect(find.text('无法读取本机资料'), findsOneWidget);
    expect(find.text('重新加载本机'), findsOneWidget);

    platform.loadError = null;
    await tester.tap(find.text('重新加载本机'));
    await tester.pumpAndSettle();
    expect(platform.starts, 1);
    expect(find.text('无法读取本机资料'), findsNothing);
    expect(find.text(platform.device.name), findsOneWidget);
    expect(platform.permissionRequests, 0);
  });

  testWidgets('name failure is visible in settings and can be corrected', (
    tester,
  ) async {
    final platform = FakePlatform()
      ..status = const PermissionStatus(screenRecording: true)
      ..renameError = PlatformException(
        code: 'invalid_name',
        message: '设备名称不能为空',
      );
    await mount(tester, platform);
    await openFieldTool(tester, '设置');
    await tester.enterText(find.byKey(const ValueKey('device-name')), '');
    await tester.tap(find.text('保存名称'));
    await tester.pumpAndSettle();
    final error = inDialog(const ValueKey('settings-device-error'));
    expect(error, findsOneWidget);
    expect(tester.widget<Text>(error).data, '设备名称不能为空');
    await tester.ensureVisible(error);
    expect(error.hitTestable(), findsOneWidget);
    expect(platform.device.name, '书房 Mac');

    platform.renameError = null;
    await tester.enterText(find.byKey(const ValueKey('device-name')), '工作室');
    await tester.ensureVisible(find.text('保存名称'));
    await tester.tap(find.text('保存名称'));
    await tester.pumpAndSettle();
    expect(error, findsNothing);
    expect(platform.device.name, '工作室');
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed first permission query cannot strand discovery', (
    tester,
  ) async {
    final platform = _PermissionReadPlatform();
    await mount(tester, platform);
    expect(platform.starts, 0);
    expect(find.text('重新加载本机'), findsOneWidget);
    platform.fail = false;
    await tester.tap(find.text('重新加载本机'));
    await tester.pumpAndSettle();
    expect(platform.starts, 1);
    expect(find.text('重新加载本机'), findsNothing);
    platform.events.add(
      const DiscoverySnapshot(
        state: 'running',
        devices: [NearbyDevice('after-retry', '重试后发现的设备', 'macos')],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-after-retry')), findsOneWidget);
  });

  testWidgets('theme save failure stays actionable inside its settings route', (
    tester,
  ) async {
    const channel = MethodChannel('dev.sharehub.client/desktop');
    var failWrite = true;
    final writes = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'initialize') return {'allowConnections': false};
          if (call.method == 'appearance.read') return 'system';
          if (call.method == 'appearance.write') {
            writes.add(call.arguments as String);
            if (failWrite) throw PlatformException(code: 'preference_failed');
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final platform = FakePlatform()
      ..status = const PermissionStatus(screenRecording: true);
    await mount(tester, platform);
    await openFieldTool(tester, '设置');
    await tester.tap(find.text('跟随系统').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色').last);
    await tester.pumpAndSettle();
    final error = inDialog(const ValueKey('settings-appearance-error'));
    expect(error, findsOneWidget);
    await tester.ensureVisible(error);
    expect(error.hitTestable(), findsOneWidget);
    final retry = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('重试保存主题'),
    );
    expect(retry, findsOneWidget);
    failWrite = false;
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(writes, ['dark', 'dark']);
    expect(error, findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry reading theme preserves the existing stored preference', (
    tester,
  ) async {
    const channel = MethodChannel('dev.sharehub.client/desktop');
    var failRead = true;
    final writes = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'initialize') return {'allowConnections': false};
          if (call.method == 'appearance.read') {
            if (failRead) throw PlatformException(code: 'preference_failed');
            return 'dark';
          }
          if (call.method == 'appearance.write') {
            writes.add(call.arguments as String);
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final platform = FakePlatform()
      ..status = const PermissionStatus(screenRecording: true);
    await mount(tester, platform);
    await openFieldTool(tester, '设置');
    final retry = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('重试读取主题'),
    );
    expect(retry, findsOneWidget);
    failRead = false;
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(inDialog(const ValueKey('settings-appearance-error')), findsNothing);
    expect(
      Theme.of(tester.element(find.byType(AlertDialog))).brightness,
      Brightness.dark,
    );
  });

  testWidgets('late failed read cannot replace a newer saved theme', (
    tester,
  ) async {
    const channel = MethodChannel('dev.sharehub.client/desktop');
    final pendingRead = Completer<String>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'appearance.read') return pendingRead.future;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final appearance = Appearance();
    final loading = appearance.load();
    await appearance.select(ThemeMode.dark);
    pendingRead.completeError(PlatformException(code: 'late_read_failure'));
    await loading;
    expect(appearance.mode, ThemeMode.dark);
    expect(appearance.error, isNull);
    expect(appearance.failure, isNull);
    appearance.dispose();
  });
}
