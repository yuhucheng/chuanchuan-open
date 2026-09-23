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
    required this.stopRemote,
    this.stopAuxiliary,
    required this.transfers,
    required this.connectionSupported,
    MethodChannel? channel,
  }) : channel = channel ?? const MethodChannel('dev.sharehub.client/desktop');
  final DeviceController devices;
  final ConnectionController connections;
  final PreviewController preview;

  /// Must synchronously reject new remote operations before returning its
  /// cleanup future. Completion means all remote media resources are released.
  final Future<void> Function() stopRemote;
  final void Function()? stopAuxiliary;
  final TransferQueue transfers;
  final bool connectionSupported;
  final MethodChannel channel;
  Future<bool>? _exit;
  final _pendingExitSteps = <String, Future<void>>{};
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

  Future<bool> requestExit() {
    final pending = _exit;
    if (pending != null) return pending;
    final completion = Completer<bool>();
    // Publish the transaction before shutdown synchronously notifies listeners.
    // A listener requesting exit again must join this very same future.
    _exit = completion.future;
    completion.complete(
      _shutdown().whenComplete(() {
        _exit = null;
      }),
    );
    return completion.future;
  }

  Future<bool> _shutdown() async {
    if (exited) return true;
    exiting = true;
    error = null;
    _notify();
    try {
      await _exitStep('stop-media+disconnect', () {
        // Block new media first, then revoke grants before any cleanup await.
        // Capture a synchronous callback failure without skipping revocation.
        final remote = Future<void>.sync(stopRemote);
        final disconnect = Future<void>.sync(connections.shutdown);
        final auxiliary = Future<void>.sync(() => stopAuxiliary?.call());
        return Future.wait<void>([
          remote,
          disconnect,
          auxiliary,
          Future<void>.sync(preview.stop),
        ]).then<void>((_) {});
      });
      if (preview.cleanupFailed) throw StateError('capture cleanup');
      // Cancel a native picker before waiting for its queued result/releases.
      if (_ready) {
        await _exitStep(
          'cancel-picker',
          () => channel.invokeMethod<void>('prepareExit'),
        );
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
      // A timeout does not cancel native work. Keep its original future so a
      // retry never starts a second release while the first is still pending.
      final pending = _pendingExitSteps.putIfAbsent(
        name,
        () => Future<void>.sync(action).whenComplete(() {
          _pendingExitSteps.remove(name);
        }),
      );
      await pending.timeout(const Duration(seconds: 10));
      _exitLog('done  $name');
    } on TimeoutException {
      _exitLog('TIMEOUT $name');
      rethrow;
    } catch (error) {
      _exitLog('fail  $name (${error.runtimeType})');
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
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
