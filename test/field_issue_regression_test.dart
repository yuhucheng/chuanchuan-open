import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/desktop/desktop_lifecycle.dart';
import 'package:share_hub_open/features/devices/device_controller.dart';
import 'package:share_hub_open/features/preview/preview_controller.dart';
import 'package:share_hub_open/features/remote/remote_media.dart';
import 'package:share_hub_open/features/remote/remote_session_controller.dart';
import 'package:share_hub_open/features/transfers/transfer_queue.dart';
import 'package:share_hub_open/platform/client_platform.dart';
import 'package:share_hub_open/ui/client_app.dart';
import 'package:share_hub_open/ui/field/appearance.dart';
import 'package:share_hub_open/ui/field/field_shell.dart';

import 'connection_controller_test.dart' show FakeConnectionPlatform;
import 'fakes.dart';
import 'field_test_helpers.dart';
import 'file_fakes.dart';

class _NoticeConnections extends ConnectionController {
  _NoticeConnections() : super(FakeConnectionPlatform());
  @override
  ConnectionNotice? notice = const ConnectionNotice.status('连接已成功建立。');

  void report(ConnectionNotice value) {
    notice = value;
    notifyListeners();
  }
}

void main() {
  testWidgets('connection status cannot mask a failed media operation', (
    tester,
  ) async {
    final platform = FakePlatform()
      ..status = const PermissionStatus(screenRecording: true);
    final devices = DeviceController(platform);
    final connections = _NoticeConnections();
    final engine = FakePreviewEngine();
    final preview = PreviewController(platform, engine);
    final transfers = TransferQueue(TestFileAccess());
    final remote = RemoteSessionController(
      connections: connections,
      platform: platform,
      factory: remotePicturesFor(engine),
      listSources: engine.sources,
    );
    final desktop = DesktopLifecycle(
      devices: devices,
      connections: connections,
      preview: preview,
      stopRemote: remote.shutdown,
      transfers: transfers,
      connectionSupported: true,
    );
    final appearance = Appearance();
    await devices.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: FieldShell(
          devices: devices,
          connections: connections,
          preview: preview,
          remote: remote,
          transfers: transfers,
          desktop: desktop,
          appearance: appearance,
          targetPlatform: TargetPlatform.macOS,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('global-issue')), findsNothing);

    // Exercise a real controller failure while a normal connection status is
    // retained. No peer or capture resource is needed for this refusal.
    await remote.start(SessionOperation.watch, peerKey: 'unconnected-peer');
    await tester.pumpAndSettle();
    final mediaError = remote.error!;
    expect(find.text(mediaError), findsOneWidget);
    expect(find.text('连接已成功建立。'), findsNothing);

    connections.report(const ConnectionNotice.problem('连接发生异常。'));
    await tester.pumpAndSettle();
    expect(find.text('连接发生异常。'), findsOneWidget);
    expect(find.text(mediaError), findsNothing);
    await tester.tap(find.text('忽略'));
    await tester.pumpAndSettle();
    expect(find.text(mediaError), findsOneWidget);

    // Normal status remains available from its own context, rather than being
    // discarded in order to make the global problem queue work.
    connections.report(const ConnectionNotice.status('连接已成功建立。'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('local-device')));
    await tester.tap(find.byKey(const ValueKey('local-device')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('连接已成功建立。'),
      ),
      findsOneWidget,
    );
    expect(engine.starts, 0);
    await tester.pumpWidget(const SizedBox());
    desktop.dispose();
    remote.dispose();
    connections.dispose();
    preview.dispose();
    transfers.dispose();
    devices.dispose();
    appearance.dispose();
    await tester.pumpAndSettle();
    await platform.events.close();
  });

  testWidgets('settings keeps exit failures visible and permits retry', (
    tester,
  ) async {
    const channel = MethodChannel('dev.sharehub.client/desktop');
    var nativeExitCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'initialize') return {'allowConnections': false};
          if (call.method == 'appearance.read') return 'system';
          if (call.method == 'exit') {
            nativeExitCalls++;
            throw PlatformException(code: 'native_exit_failed');
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final platform = FakePlatform()
      ..status = const PermissionStatus(screenRecording: true);
    final engine = FakePreviewEngine()..failStop = true;
    await tester.pumpWidget(
      ShareHubApp(
        targetPlatform: TargetPlatform.macOS,
        platform: platform,
        previewEngine: engine,
        fileAccess: TestFileAccess(),
      ),
    );
    await tester.pumpAndSettle();
    await openFieldTool(tester, '设置');
    await tester.ensureVisible(find.text('退出'));
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    final inDialog = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byKey(const ValueKey('settings-exit-error')),
    );
    expect(inDialog, findsOneWidget);
    expect(tester.widget<Text>(inDialog).data, contains('退出清理未完成'));
    await tester.ensureVisible(inDialog);
    expect(inDialog.hitTestable(), findsOneWidget);
    expect(nativeExitCalls, 0);

    final firstStops = engine.stops;
    await tester.ensureVisible(find.text('退出'));
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(engine.stops, greaterThan(firstStops));
    expect(nativeExitCalls, 0);
    expect(tester.widget<Text>(inDialog).data, contains('退出清理未完成'));
    await tester.ensureVisible(inDialog);
    expect(inDialog.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await platform.events.close();
  });
}
