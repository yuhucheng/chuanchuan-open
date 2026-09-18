import 'field_test_helpers.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/platform/client_platform.dart';
import 'package:share_hub_open/ui/client_app.dart';
import 'package:share_hub_open/features/devices/device_directory.dart';
import 'package:share_hub_open/ui/field/device_field.dart';
import 'package:share_hub_open/ui/field/appearance.dart';

import 'fakes.dart';
import 'connection_controller_test.dart' show FakeConnectionPlatform;

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/connections/connection_panel.dart';

void main() {
  testWidgets(
    'arrival ordering, focused Enter action, aggregation and search remain in field',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var devices = List.generate(
        9,
        (i) => NearbyDevice('$i', '设备 $i', 'macos'),
      );
      var query = '';
      var opened = '';
      late StateSetter refresh;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                refresh = setState;
                return SingleChildScrollView(
                  child: DeviceField(
                    entries: devices
                        .map(DirectoryDevice.fromDiscovered)
                        .toList(),
                    localName: '本机',
                    allowConnections: false,
                    query: query,
                    onLocal: () {},
                    onDevice: (d) async {
                      opened = d.identityId;
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );
      final first = find.byKey(const ValueKey('device-0'));
      final before = tester.getTopLeft(first);
      final button = tester.widget<OutlinedButton>(first);
      button.focusNode!.requestFocus();
      await tester.pump();
      refresh(() => devices = devices.reversed.toList());
      await tester.pump();
      expect(tester.getTopLeft(first), before);
      expect(button.focusNode!.hasFocus, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(opened, '0');
      await tester.ensureVisible(find.byKey(const ValueKey('aggregate')));
      await tester.tap(find.byKey(const ValueKey('aggregate')));
      await tester.pump();
      expect(find.byKey(const ValueKey('device-8')), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
      await tester.ensureVisible(find.text('返回设备场'));
      await tester.tap(find.text('返回设备场'));
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('aggregate')))
            .focusNode!
            .hasFocus,
        true,
      );
      refresh(() => query = '设备 8');
      await tester.pump();
      expect(find.byKey(const ValueKey('device-8')), findsOneWidget);
      expect(find.byKey(const ValueKey('device-0')), findsNothing);
    },
  );

  testWidgets('dark long Chinese names remain usable at 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(860, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: DeviceField(
              entries: [
                DirectoryDevice.fromDiscovered(
                  const NearbyDevice(
                    'long',
                    '办公室里名称非常长的中文电脑设备用于布局验收',
                    'macos',
                  ),
                ),
              ],
              localName: '本机名称也很长但依然应保持可读和可操作',
              allowConnections: false,
              onLocal: () {},
              onDevice: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('device-long')), findsOneWidget);
  });

  testWidgets(
    'available connection action opens code dialog; unreleased capabilities have no entries',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = FakePlatform();
      final engine = FakePreviewEngine();
      await tester.pumpWidget(
        ShareHubApp(
          targetPlatform: TargetPlatform.macOS,
          platform: platform,
          previewEngine: engine,
        ),
      );
      await tester.pumpAndSettle();
      platform.events.add(
        const DiscoverySnapshot(
          state: 'running',
          devices: [
            NearbyDevice(
              'other',
              '另一台电脑',
              'macos',
              host: 'test.local',
              port: 1234,
              publicKey: 'key',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('屏幕预览'), findsNothing);
      expect(find.byTooltip('文件传送'), findsNothing);
      expect(find.byType(NavigationRail), findsNothing);
      // The field keys a node by identity, not by the display name.
      final node = find.byKey(const ValueKey('device-key'));
      await tester.tap(node);
      await tester.pumpAndSettle();
      expect(find.text('远控 · 尚未交付'), findsNothing);
      expect(find.text('投屏 · 尚未交付'), findsNothing);
      expect(find.text('发送文件 · 尚未交付'), findsNothing);
      expect(find.text('观看暂不可用'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byWidgetPredicate(
            (w) => w is ButtonStyleButton && w.onPressed == null,
          ),
        ),
        findsNothing,
      );
      await tester.tap(find.text('连接设备'));
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(field, findsOneWidget);
      await tester.enterText(field, '12a34567');
      expect(tester.widget<TextField>(field).controller!.text, '123456');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(node).focusNode!.hasFocus, true);
      expect(engine.sourceCalls, 0);
      expect(engine.starts, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await platform.events.close();
    },
  );

  testWidgets('cancel during identity loading prevents a late connection', (
    tester,
  ) async {
    final platform = FakeConnectionPlatform();
    final controller = ConnectionController(platform);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showConnectionDialog(
                context,
                controller,
                device: const NearbyDevice(
                  'peer',
                  '测试设备',
                  'macos',
                  host: '127.0.0.1',
                  port: 12345,
                  publicKey: 'key',
                ),
              ),
              child: const Text('请求观看'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('请求观看'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('连接'));
    await tester.pump();
    expect(find.text('正在验证，可随时取消'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    platform.seed.complete(await DeviceIdentity.fromSeed(List.filled(32, 7)));
    await tester.pumpAndSettle();
    expect(controller.sessions, isEmpty);
    expect(controller.busy, false);
    expect(find.byType(AlertDialog), findsNothing);
    controller.dispose();
  });

  testWidgets('long press shortcut waits 600ms and fires once', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DeviceField(
            entries: const [],
            localName: '本机',
            allowConnections: false,
            onLocal: () => calls++,
            onDevice: (_) async {},
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('local-device'))),
    );
    await tester.pump(const Duration(milliseconds: 550));
    expect(calls, 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(calls, 1);
    await gesture.up();
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets(
    'full shell follows system theme at 200 percent without recreating capture owner',
    (tester) async {
      tester.view.physicalSize = const Size(860, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final platform = FakePlatform();
      final engine = FakePreviewEngine();
      await tester.pumpWidget(
        ShareHubApp(platform: platform, previewEngine: engine),
      );
      await tester.pumpAndSettle();
      final fieldState = tester.state(find.byType(DeviceField));
      expect(
        Theme.of(tester.element(find.byType(DeviceField))).brightness,
        Brightness.dark,
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(DeviceField))).brightness,
        Brightness.light,
      );
      expect(tester.state(find.byType(DeviceField)), same(fieldState));
      expect(engine.starts, 0);
      expect(engine.closed, false);
      await openFieldTool(tester, '设置');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await platform.events.close();
    },
  );

  test(
    'theme load cannot overwrite a newer choice and persists exact preference',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final read = Completer<String>();
      final saved = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(Appearance.channel, (call) async {
            if (call.method == 'appearance.read') return read.future;
            if (call.method == 'appearance.write') {
              saved.add(call.arguments as String);
            }
            return null;
          });
      final preferences = Appearance();
      final loading = preferences.load();
      await preferences.select(ThemeMode.dark);
      read.complete('light');
      await loading;
      expect(preferences.mode, ThemeMode.dark);
      expect(saved, ['dark']);
      preferences.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(Appearance.channel, null);
    },
  );
}
