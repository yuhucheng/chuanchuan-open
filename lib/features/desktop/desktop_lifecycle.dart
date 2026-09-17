import 'dart:async';

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
    required this.connectionSupported,
    MethodChannel? channel,
  }) : channel = channel ?? const MethodChannel('dev.sharehub.client/desktop');
  final DeviceController devices;
  final ConnectionController connections;
  final PreviewController preview;
  final TransferQueue transfers;
  final bool connectionSupported;
  final MethodChannel channel;
  Future<bool>? _exit;
  bool exiting = false, exited = false, _disposed = false, _ready = false;
  String? error;
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
          // No remote input engine is shipped yet; never disconnect a grant
          // or pretend that stopping local preview stops remote control.
          return false;
        default:
          throw MissingPluginException(call.method);
      }
    });
    connections.addListener(_connectionChanged);
    try {
      final preferences = await channel.invokeMapMethod<String, dynamic>(
        'initialize',
        {'connectionSupported': connectionSupported},
      );
      if (_disposed) return;
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
      await Future.wait([preview.stop(), disconnect]);
      if (preview.cleanupFailed) throw StateError('capture cleanup');
      // Cancel a native picker before waiting for its queued result/releases.
      if (_ready) await channel.invokeMethod<void>('prepareExit');
      await transfers.close();
      if (transfers.items.isNotEmpty) throw StateError('file cleanup');
      await devices.stopForExit();
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
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
