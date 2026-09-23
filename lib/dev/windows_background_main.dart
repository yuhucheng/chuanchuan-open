// Windows background lifecycle matrix (7.1/6.1), running inside the real host
// window and driven entirely through the platform's own desktop channel.
//
//   flutter run -d windows -t lib/dev/windows_background_main.dart
//
// Differences from the macOS matrix are recorded in the report, not smoothed
// over:
//   * No capture is started, so there is no frame delta. Windows resolves
//     createPreviewEngine() to WebRtcPreviewEngine, whose runtime statistics are
//     served by mac-only native bridge `dev.sharehub.client/preview`; there is
//     no Windows counterpart, so "still capturing while hidden" is NOT measured
//     here rather than being implied.
//   * There is no LaunchServices/Dock equivalent to wake the process from
//     outside. "reopen" below uses the same in-app ShowMainWindow() path and is
//     therefore labelled programmatic, never an external wake-up observation.
//   * connectionSupported is true on Windows since change plan-trusted-device-
//     -connections task 2.4, unlike the macOS run which passed false.
//
// Rebuilding the product afterwards is mandatory: any other entry overwrites
// the Debug kernel payload.

import 'dart:convert';
import 'dart:io';

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
const String _reportPath =
    r'D:\code\chuan-agent\.workbuddy\tmp\win_background_report.json';

Future<Map<String, dynamic>> _windowState() async {
  try {
    return await _desktop.invokeMapMethod<String, dynamic>('window.state') ??
        <String, dynamic>{};
  } catch (error) {
    return <String, dynamic>{'error': error.toString()};
  }
}

Future<Map<String, dynamic>> _windowAction(String action) async {
  try {
    return await _desktop.invokeMapMethod<String, dynamic>(
          'window.action',
          <String, Object>{'action': action},
        ) ??
        <String, dynamic>{};
  } catch (error) {
    return <String, dynamic>{'error': error.toString()};
  }
}

Future<Map<String, dynamic>> _stage(String stage, Duration settle) async {
  await Future<void>.delayed(settle);
  return <String, dynamic>{
    'stage': stage,
    'at': DateTime.now().toIso8601String(),
    'window': await _windowState(),
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'mode': 'windows-background-lifecycle',
    'startedAt': DateTime.now().toIso8601String(),
    'capturedFramesMeasured': false,
    'framesNotMeasuredReason':
        'Windows has no counterpart to the mac-only preview bridge that serves '
        'runtime capture statistics.',
  };
  final stages = <Map<String, dynamic>>[];
  DesktopLifecycle? desktop;

  try {
    final platform = MethodChannelClientPlatform();
    final preview = PreviewController(platform, createPreviewEngine());
    final transfers = TransferQueue(MethodChannelFileAccess());
    desktop = DesktopLifecycle(
      devices: DeviceController(platform),
      connections: ConnectionController(MethodChannelConnectionPlatform()),
      preview: preview,
      stopRemote: () async {}, // This probe creates no remote media owner.
      transfers: transfers,
      connectionSupported: true,
    );

    await desktop.initialize();
    final afterInit = await _windowState();
    report['trayAfterInitialize'] = afterInit;
    report['trayReady'] = afterInit['trayInstalled'] == true;
    report['desktopError'] = desktop.error;

    stages.add(await _stage('foreground', const Duration(milliseconds: 400)));
    await _windowAction('minimize');
    stages.add(await _stage('window-minimized', const Duration(seconds: 1)));
    await _windowAction('deminiaturize');
    stages.add(await _stage('window-restored', const Duration(seconds: 1)));
    await _windowAction('hide');
    stages.add(await _stage('app-hidden', const Duration(seconds: 1)));
    await _windowAction('unhide');
    stages.add(await _stage('app-unhidden', const Duration(seconds: 1)));

    if (report['trayReady'] == true) {
      await _windowAction('close');
      stages.add(
        await _stage('closed-to-background', const Duration(seconds: 1)),
      );
      // Reaching the native side again proves the process survived the close.
      final alive = await _windowState();
      report['processAliveAfterClose'] = !alive.containsKey('error');
      report['stateAfterClose'] = alive;

      // Programmatic, same ShowMainWindow() path a tray double-click takes.
      // Not an external wake-up observation: Windows has no Dock equivalent.
      await _windowAction('reopen');
      stages.add(await _stage('after-reopen', const Duration(seconds: 1)));
      report['reopenKind'] = 'programmatic-in-app-path';
    } else {
      report['closedToBackgroundSkipped'] = 'tray-unavailable';
    }

    report['stages'] = stages;

    final allowed = await desktop.requestExit();
    report['exit'] = <String, dynamic>{
      'allowed': allowed,
      'exited': desktop.exited,
      'error': desktop.error,
      'cleanupFailed': preview.cleanupFailed,
      'transfersRemaining': transfers.items.length,
    };
    report['outcome'] = 'complete';
    File(_reportPath)
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    if (allowed) await desktop.finishExit();
  } catch (error) {
    report['error'] = error.toString();
    report['stages'] = stages;
    File(_reportPath)
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  }
}
