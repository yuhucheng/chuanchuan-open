// Windows exit-path acceptance entry: wires the shipped background owner
// exactly as the client does, then drives the real quit path (tray 退出 ->
// requestExit -> cleanup -> DestroyWindow) and holds the process so the quit
// transaction owns it.
//
//   flutter run -d windows -t lib/dev/windows_exit_main.dart
//
// A clean quit destroys the window and ends the process. A stuck one leaves the
// process alive past the budget, with the hung step named in
// %TEMP%\share_hub_exit.log (each cleanup step is bounded to 10s). Rebuild the
// product afterwards: any -t entry overwrites the Debug kernel payload.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';

import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/desktop/desktop_lifecycle.dart';
import 'package:share_hub_open/features/devices/device_controller.dart';
import 'package:share_hub_open/features/preview/preview_controller.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';
import 'package:share_hub_open/features/transfers/transfer_queue.dart';
import 'package:share_hub_open/platform/client_platform.dart';

const MethodChannel _desktop = MethodChannel('dev.sharehub.client/desktop');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final platform = MethodChannelClientPlatform();
  final preview = PreviewController(platform, createPreviewEngine());
  final transfers = TransferQueue(MethodChannelFileAccess());
  final desktop = DesktopLifecycle(
    devices: DeviceController(platform),
    connections: ConnectionController(MethodChannelConnectionPlatform()),
    preview: preview,
    transfers: transfers,
    connectionSupported: true,
  );
  await desktop.initialize();
  // Drive the real quit path. Then return immediately: the quit transaction
  // (cleanup -> DestroyWindow -> PostQuitMessage) owns process exit. Holding a
  // Timer here would itself keep the Dart isolate alive and fake a hang, so we
  // deliberately do not await anything further.
  try {
    await _desktop.invokeMapMethod<String, dynamic>(
      'window.action',
      <String, Object>{'action': 'quit'},
    );
  } catch (error) {
    debugPrint('[exit-acceptance] quit dispatch error: $error');
  }
}
