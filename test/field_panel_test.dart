import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/platform/client_platform.dart';
import 'package:share_hub_open/ui/client_app.dart';
import 'package:share_hub_open/ui/field/issue_banner.dart';
import 'package:share_hub_open/ui/field/device_field.dart';
import 'package:share_hub_open/features/devices/device_directory.dart';

import 'fakes.dart';
import 'field_test_helpers.dart';

void main() {
  testWidgets(
    'disappearing peer keeps an actionable identity-bound dialog at 200 percent',
    (tester) async {
      tester.view.physicalSize = const Size(640, 600);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final platform = FakePlatform();
      final engine = DialogRemotePreviewEngine();
      await tester.pumpWidget(
        ShareHubApp(
          targetPlatform: TargetPlatform.macOS,
          platform: platform,
          previewEngine: engine,
        ),
      );
      await tester.pumpAndSettle();
      const peer = NearbyDevice(
        'peer',
        '办公室',
        'macos',
        host: '192.168.1.21',
        port: 1234,
        publicKey: 'original-key',
      );
      platform.events.add(
        const DiscoverySnapshot(state: 'running', devices: [peer]),
      );
      await tester.pumpAndSettle();
      final node = find.byKey(const ValueKey('device-original-key'));
      await tester.ensureVisible(node);
      await tester.tap(node);
      await tester.pumpAndSettle();
      expect(find.text('连接并观看'), findsOneWidget);

      // A same-name replacement even reuses the discovery id and endpoint.
      // The open action sheet must remain bound to the original identity.
      platform.events.add(
        const DiscoverySnapshot(
          state: 'running',
          devices: [
            NearbyDevice(
              'peer',
              '办公室',
              'macos',
              host: '192.168.1.21',
              port: 1234,
              publicKey: 'replacement-key',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('该设备当前不可达，请刷新发现后重试。'), findsOneWidget);
      expect(find.text('连接并观看'), findsNothing);
      expect(find.text('连接并投屏'), findsNothing);
      await tester.ensureVisible(find.text('刷新设备'));
      final starts = platform.starts;
      await tester.tap(find.text('刷新设备'));
      await tester.pumpAndSettle();
      expect(platform.starts, greaterThan(starts));
      expect(find.byType(AlertDialog), findsOneWidget);

      // Only the original identity returning may restore its actions.
      platform.events.add(
        const DiscoverySnapshot(state: 'running', devices: [peer]),
      );
      await tester.pumpAndSettle();
      expect(find.text('该设备当前不可达，请刷新发现后重试。'), findsNothing);
      expect(find.text('连接并观看'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.widget<OutlinedButton>(node).focusNode!.hasFocus, true);
      expect(engine.starts, 0);
      expect(engine.sourceCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await platform.events.close();
    },
  );

  testWidgets(
    'only highest priority issue shows; dismissal does not run action and recurrence returns',
    (tester) async {
      var actions = 0;
      late StateSetter refresh;
      var present = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                refresh = setState;
                return IssueBanner(
                  issues: [
                    if (present)
                      FieldIssue('permission', '权限缺失', '授权', () => actions++),
                    FieldIssue('discovery', '发现失败', '重试', () => actions++),
                  ],
                );
              },
            ),
          ),
        ),
      );
      expect(find.text('权限缺失'), findsOneWidget);
      expect(find.text('发现失败'), findsNothing);
      await tester.tap(find.text('忽略'));
      await tester.pump();
      expect(actions, 0);
      expect(find.text('发现失败'), findsOneWidget);
      await tester.tap(find.text('重试'));
      expect(actions, 1);
      refresh(() => present = false);
      await tester.pump();
      refresh(() => present = true);
      await tester.pump();
      expect(find.text('权限缺失'), findsOneWidget);
      expect(find.byKey(const ValueKey('global-issue')), findsOneWidget);
    },
  );

  testWidgets(
    'local tools are prominent and settings has no navigation loop at 200 percent',
    (tester) async {
      tester.view.physicalSize = const Size(860, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
      expect(find.text('退出'), findsNothing);
      expect(find.text('屏幕预览'), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('local-device')));
      await tester.tap(find.byKey(const ValueKey('local-device')));
      await tester.pumpAndSettle();
      expect(find.text('我的短接码'), findsOneWidget);
      expect(find.text('已接入会话'), findsOneWidget);
      expect(find.text('本机工具'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('屏幕预览'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('设置'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await openFieldTool(tester, '设置');
      expect(find.text('允许连接与短接码'), findsNothing);
      expect(find.text('输入短接码连接设备'), findsNothing);
      expect(find.text('退出'), findsOneWidget);
      await tester.ensureVisible(find.text('退出'));
      expect(tester.takeException(), isNull);
      expect(engine.sourceCalls, 0);
      expect(engine.starts, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await platform.events.close();
    },
  );

  testWidgets(
    'duplicate names retain identity and visibly show address suffixes',
    (tester) async {
      final entries = [
        DirectoryDevice.fromDiscovered(
          const NearbyDevice('a', '办公室', 'macos', host: '192.168.1.21'),
        ),
        DirectoryDevice.fromDiscovered(
          const NearbyDevice('b', '办公室', 'macos', host: '192.168.1.22'),
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DeviceField(
                entries: entries,
                localName: '本机',
                allowConnections: false,
                onLocal: () {},
                onDevice: (_) async {},
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('…1.21'), findsOneWidget);
      expect(find.textContaining('…1.22'), findsOneWidget);
      expect(find.byKey(const ValueKey('device-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('device-b')), findsOneWidget);
    },
  );
}
