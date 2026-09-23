import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/desktop/desktop_lifecycle.dart';
import 'package:share_hub_open/features/devices/device_controller.dart';
import 'package:share_hub_open/features/preview/preview_controller.dart';
import 'package:share_hub_open/features/remote/control_clipboard_preference.dart';
import 'package:share_hub_open/features/remote/remote_session_controller.dart';
import 'package:share_hub_open/features/remote/windows_pointer_control_factory.dart';
import 'package:share_hub_open/features/transfers/transfer_queue.dart';
import 'package:share_hub_open/platform/client_platform.dart';
import 'package:share_hub_open/ui/field/appearance.dart';
import 'package:share_hub_open/ui/field/field_shell.dart';

import 'connection_controller_test.dart' show FakeConnectionPlatform;
import 'fakes.dart';
import 'file_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sharehub.client/desktop');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('clipboard switch writes a disabled setting for opt-in control', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final writes = <bool>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'controlClipboard.read') return true;
      if (call.method == 'controlClipboard.write') {
        writes.add(call.arguments as bool);
        return null;
      }
      throw MissingPluginException(call.method);
    });
    final platform = FakePlatform()
      ..status = const PermissionStatus(screenRecording: true);
    final devices = DeviceController(platform);
    final connections = ConnectionController(FakeConnectionPlatform());
    final engine = FakePreviewEngine();
    final preview = PreviewController(platform, engine);
    final transfers = TransferQueue(TestFileAccess());
    final setting = ControlClipboardPreference(channel: channel);
    await setting.load();
    final remote = RemoteSessionController(
      connections: connections,
      platform: platform,
      factory: createWindowsPointerControlFactory(
        clipboardText: true,
        clipboardSetting: setting,
      ),
      listSources: engine.sources,
    );
    final desktop = DesktopLifecycle(
      devices: devices,
      connections: connections,
      preview: preview,
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
          clipboardPreference: setting,
          targetPlatform: TargetPlatform.windows,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '设置'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('settings-control-clipboard'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(setting.value, isFalse);
    expect(writes, [false]);
    await tester.pumpWidget(const SizedBox());
    desktop.dispose();
    remote.dispose();
    connections.dispose();
    preview.dispose();
    transfers.dispose();
    devices.dispose();
    appearance.dispose();
    setting.dispose();
    await platform.events.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
