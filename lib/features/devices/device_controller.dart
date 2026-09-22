import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../platform/client_platform.dart';

class DeviceController extends ChangeNotifier {
  DeviceController(this.platform);
  final ClientPlatform platform;
  LocalDevice? device;
  PermissionStatus permissions = const PermissionStatus();
  DiscoverySnapshot discovery = const DiscoverySnapshot();
  String? error;
  bool busy = false;
  bool _disposed = false;
  Future<void>? _pending;
  StreamSubscription<DiscoverySnapshot>? _subscription;

  Future<void> initialize() => _perform(() async {
    final loadedDevice = await platform.loadDevice();
    final loadedPermissions = await platform.permissions();
    if (_disposed) return;
    // Publish initialization prerequisites together: a permission-query failure
    // must not look like a ready device whose discovery has never been started.
    device = loadedDevice;
    permissions = loadedPermissions;
    _subscription ??= platform.discoveryEvents.listen(
      (event) {
        if (_disposed) return;
        discovery = event;
        _notify();
      },
      onError: (Object _) {
        if (_disposed) return;
        discovery = const DiscoverySnapshot(state: 'failed');
        error = '无法读取局域网发现状态，请重新启动客户端。';
        _notify();
      },
    );
    await _startDiscovery();
  });

  Future<void> refreshPermissions() => _perform(() async {
    permissions = await platform.permissions();
  });

  Future<void> rename(String name) => _perform(() async {
    device = await platform.setDeviceName(name);
    if (!_disposed && discovery.enabled) await platform.startDiscovery();
  });

  Future<void> retryDiscovery() => _perform(_startDiscovery);

  Future<void> _startDiscovery() async {
    if (_disposed) return;
    try {
      await platform.startDiscovery();
    } catch (_) {
      if (!_disposed) discovery = const DiscoverySnapshot(state: 'failed');
      rethrow;
    }
  }

  Future<void> openSettings(String permission) =>
      _perform(() => platform.openSettings(permission));

  Future<void> _perform(Future<void> Function() action) {
    if (busy || _disposed) return Future.value();
    return _pending = _execute(action);
  }

  Future<void> _execute(Future<void> Function() action) async {
    busy = true;
    error = null;
    _notify();
    try {
      await action();
    } on PlatformException catch (exception) {
      error = exception.message ?? '系统操作失败，请重试。';
    } on MissingPluginException {
      error = '系统组件尚未加载，请使用完整构建的桌面客户端。';
    } catch (_) {
      error = '操作未完成，请检查系统权限后重试。';
    } finally {
      busy = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> stopForExit() async {
    _disposed = true;
    await _pending;
    await _subscription?.cancel();
    _subscription = null;
    await platform.stopDiscovery();
    discovery = const DiscoverySnapshot();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stopForExit().catchError((Object _) {}));
    super.dispose();
  }
}
