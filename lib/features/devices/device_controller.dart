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
  StreamSubscription<DiscoverySnapshot>? _subscription;

  Future<void> initialize() => _perform(() async {
    device = await platform.loadDevice();
    permissions = await platform.permissions();
    if (_disposed) return;
    _subscription ??= platform.discoveryEvents.listen(
      (event) {
        discovery = event;
        _notify();
      },
      onError: (Object _) {
        discovery = const DiscoverySnapshot(state: 'failed');
        error = '无法读取局域网发现状态，请重新启动客户端。';
        _notify();
      },
    );
  });

  Future<void> refreshPermissions() => _perform(() async {
    permissions = await platform.permissions();
  });

  Future<void> rename(String name) => _perform(() async {
    device = await platform.setDeviceName(name);
    if (!_disposed && discovery.enabled) await platform.startDiscovery();
  });

  Future<void> setDiscovery(bool enabled) => _perform(() async {
    if (enabled) {
      await platform.startDiscovery();
    } else {
      await platform.stopDiscovery();
    }
  });

  Future<void> openSettings(String permission) =>
      _perform(() => platform.openSettings(permission));

  Future<void> _perform(Future<void> Function() action) async {
    if (busy || _disposed) return;
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

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    // The native event channel also stops discovery on cancel.
    unawaited(platform.stopDiscovery().catchError((Object _) {}));
    super.dispose();
  }
}
