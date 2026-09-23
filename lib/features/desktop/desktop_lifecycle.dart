import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../connections/connection_controller.dart';
import '../devices/device_controller.dart';
import '../preview/preview_controller.dart';
import '../transfers/transfer_queue.dart';

/// Native windows retain their Flutter engine while hidden. This owner lives
/// above page navigation; every quit path awaits the same cleanup transaction.
class DesktopLifecycle extends ChangeNotifier {
  DesktopLifecycle({
    required this.devices,
    required this.connections,
    required this.preview,
    required this.transfers,
    this.closeNetworkTransfers,
    this.stopAuxiliary,
    this.controlActive,
    this.controlChanges,
    this.stopControl,
    this.stopRemotePicture,
    required this.connectionSupported,
    MethodChannel? channel,
  }) : channel = channel ?? const MethodChannel('dev.sharehub.client/desktop');
  final DeviceController devices;
  final ConnectionController connections;
  final PreviewController preview;
  final TransferQueue transfers;
  final Future<void> Function()? closeNetworkTransfers;
  final void Function()? stopAuxiliary;
  final bool Function()? controlActive;
  final Listenable? controlChanges;
  final Future<void> Function()? stopControl;
  final Future<bool> Function()? stopRemotePicture;
  final bool connectionSupported;
  final MethodChannel channel;
  Future<bool>? _exit;
  bool exiting = false, exited = false, _disposed = false, _ready = false;
  bool controlNoticeEnabled = true;
  String? error;
  Future<void> setControlNoticeEnabled(bool enabled) async {
    if (exiting || exited || _disposed || controlNoticeEnabled == enabled) {
      return;
    }
    controlNoticeEnabled = enabled;
    _notify();
    await _publish();
  }

  Future<void> initialize() async {
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'requestExit':
          return requestExit();
        case 'toggleAllow':
          if (!connectionSupported || exiting || exited) return false;
          if (connections.accepting) {
            await connections.disconnectAll();
          } else {
            await connections.open();
          }
          await _publish();
          return connections.accepting;
        case 'stopControl':
          if (exiting ||
              exited ||
              controlActive?.call() != true ||
              stopControl == null) {
            return false;
          }
          try {
            await stopControl!();
            await _publish();
            return controlActive?.call() != true;
          } catch (_) {
            error = '停止控制失败，请在主窗口重试。';
            _notify();
            return false;
          }
        default:
          throw MissingPluginException(call.method);
      }
    });
    connections.addListener(_connectionChanged);
    controlChanges?.addListener(_connectionChanged);
    try {
      final preferences = await channel.invokeMapMethod<String, dynamic>(
        'initialize',
        {'connectionSupported': connectionSupported},
      );
      if (_disposed) return;
      controlNoticeEnabled = preferences?['controlNoticeEnabled'] != false;
      _ready = true;
      if (preferences?['allowConnections'] == true &&
          connectionSupported &&
          !exiting &&
          !exited) {
        await connections.open();
      }
      if (!_disposed && !exiting && !exited) await _publish();
    } on MissingPluginException {
      // Unit tests and unsupported hosts have no desktop integration.
    } catch (_) {
      error = '后台入口初始化失败，请保持主窗口打开。';
      _notify();
    }
  }

  void _connectionChanged() {
    if (_ready && !_disposed && !exiting && !exited) unawaited(_publish());
  }

  Future<void> _publish() async {
    if (!_ready || _disposed) return;
    try {
      await channel.invokeMethod<void>('state', {
        'allowConnections': connections.accepting,
        'controlActive': controlActive?.call() == true,
        'controlNoticeEnabled': controlNoticeEnabled,
      });
    } catch (_) {
      if (!_disposed) {
        error = '无法更新后台入口状态，请在主窗口操作。';
        _notify();
      }
    }
  }

  Future<bool> requestExit() => _exit ??= _shutdown().whenComplete(() {
    _exit = null;
  });
  Future<bool> _shutdown() async {
    if (exited) return true;
    exiting = true;
    error = null;
    _notify();
    try {
      // Revoke authorization synchronously before any native cleanup await.
      final disconnect = connections.disconnectAll();
      stopAuxiliary?.call();
      final remoteStop = stopRemotePicture?.call();
      await _exitStep(
        'stop-capture+disconnect+remote',
        () => Future.wait([
          preview.stop(),
          disconnect,
          if (remoteStop != null)
            remoteStop.then<void>((clean) {
              if (!clean) throw StateError('remote cleanup');
            }),
        ]),
      );
      if (preview.cleanupFailed) throw StateError('capture cleanup');
      // Cancel a native picker before waiting for its queued result/releases.
      if (_ready) {
        await _exitStep(
          'cancel-picker',
          () => channel.invokeMethod<void>('prepareExit'),
        );
      }
      if (closeNetworkTransfers case final closeNetwork?) {
        await _exitStep('close-network-transfers', closeNetwork);
      }
      await _exitStep('close-transfers', () => transfers.close());
      if (transfers.items.isNotEmpty) throw StateError('file cleanup');
      await _exitStep('stop-discovery', () => devices.stopForExit());
      exited = true;
      return true;
    } catch (_) {
      error = '退出清理未完成，请保持窗口打开并重试退出。';
      return false;
    } finally {
      exiting = false;
      _notify();
    }
  }

  // Each cleanup step is bounded: a stuck await must surface as a timeout (and
  // be attributable to a named step), not freeze the whole quit silently. The
  // per-step lines also go to a log file so a hang is visible even when the app
  // was launched by double-clicking (no console attached).
  Future<void> _exitStep(String name, Future<void> Function() action) async {
    _exitLog('begin $name');
    try {
      await action().timeout(const Duration(seconds: 10));
      _exitLog('done  $name');
    } on TimeoutException {
      _exitLog('TIMEOUT $name');
      rethrow;
    } catch (error) {
      _exitLog('fail  $name: $error');
      rethrow;
    }
  }

  void _exitLog(String message) {
    debugPrint('[exit] $message');
    try {
      final temp = Platform.environment['TEMP'] ?? Platform.environment['TMP'];
      if (temp == null) return;
      File('$temp${Platform.pathSeparator}share_hub_exit.log')
          .writeAsStringSync(
            '${DateTime.now().toIso8601String()} $message\n',
            mode: FileMode.append,
          );
    } catch (_) {
      /* Logging must never break the quit path. */
    }
  }

  Future<void> finishExit() async {
    if (!exited) return;
    try {
      await channel.invokeMethod<void>('exit');
    } catch (_) {
      error = '资源已清理，请通过系统应用菜单退出。';
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    connections.removeListener(_connectionChanged);
    controlChanges?.removeListener(_connectionChanged);
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
