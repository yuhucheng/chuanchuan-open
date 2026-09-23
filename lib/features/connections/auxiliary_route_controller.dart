import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_hub_connection/share_hub_connection.dart';

import 'relay_credential_owner.dart';

enum AuxiliaryRouteMode { official, custom }

final class AuxiliaryRouteChoice {
  const AuxiliaryRouteChoice(this.mode, this.customOrigin);
  final AuxiliaryRouteMode mode;
  final String customOrigin;
}

abstract interface class AuxiliaryRouteStore {
  Future<AuxiliaryRouteChoice?> read();
  Future<void> write(AuxiliaryRouteChoice choice);
}

final class NativeAuxiliaryRouteStore implements AuxiliaryRouteStore {
  const NativeAuxiliaryRouteStore();
  static const channel = MethodChannel('dev.sharehub.client/desktop');

  @override
  Future<AuxiliaryRouteChoice?> read() async {
    final value = await channel.invokeMapMethod<String, String>(
      'auxiliary.read',
    );
    if (value == null) return null;
    final mode = AuxiliaryRouteMode.values
        .where((item) => item.name == value['mode'])
        .firstOrNull;
    if (mode == null || value['origin'] == null) {
      throw const FormatException('Invalid stored auxiliary route');
    }
    return AuxiliaryRouteChoice(mode, value['origin']!);
  }

  @override
  Future<void> write(AuxiliaryRouteChoice choice) => channel.invokeMethod<void>(
    'auxiliary.write',
    {'mode': choice.mode.name, 'origin': choice.customOrigin},
  );
}

typedef AuxiliaryTransportFactory =
    ({AuxiliaryTransport transport, void Function() close}) Function(Uri);

/// Owns exactly one auxiliary origin. Switching first cancels the old network
/// owner and discards its lease; no failure can silently select the other route.
final class AuxiliaryRouteController extends ChangeNotifier {
  AuxiliaryRouteController({
    required this.identity,
    required this.officialOrigin,
    required this.store,
    AuxiliaryTransportFactory? transportFactory,
  }) : _transportFactory = transportFactory ?? _httpsTransport;

  final Future<DeviceIdentity> Function() identity;
  final String officialOrigin;
  final AuxiliaryRouteStore store;
  final AuxiliaryTransportFactory _transportFactory;
  RelayCredentialOwner? _owner;
  bool _needed = false, _stopped = false, _loaded = false;
  int _revision = 0;
  Future<void> _writeQueue = Future.value();
  AuxiliaryRouteChoice choice = const AuxiliaryRouteChoice(
    AuxiliaryRouteMode.official,
    '',
  );
  String? error;

  bool get loaded => _loaded;
  AuxiliaryTurnCredential? get current => _owner?.current;
  String? get connectionFailure => _owner?.lastFailure;
  Future<void> refresh() => _owner?.refresh() ?? Future.value();

  static ({AuxiliaryTransport transport, void Function() close})
  _httpsTransport(Uri uri) {
    final transport = HttpsAuxiliaryTransport(uri);
    return (transport: transport, close: transport.close);
  }

  RelayCredentialOwner? _create(AuxiliaryRouteChoice selected) {
    final origin = selected.mode == AuxiliaryRouteMode.official
        ? officialOrigin
        : selected.customOrigin;
    if (origin.isEmpty) return null;
    if (origin.length > 2048 || origin.contains('\u0000')) {
      throw const FormatException('Invalid auxiliary origin length');
    }
    final uri = Uri.parse(origin);
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Invalid auxiliary origin');
    }
    final endpoint = _transportFactory(uri);
    return RelayCredentialOwner(
      identity,
      AuxiliaryServiceClient(endpoint.transport),
      endpoint.close,
    );
  }

  void _install(AuxiliaryRouteChoice selected, RelayCredentialOwner? next) {
    final previous = _owner;
    previous?.removeListener(notifyListeners);
    previous?.stop();
    _owner = next;
    choice = selected;
    next?.addListener(notifyListeners);
    if (_needed && next != null) unawaited(next.start());
    notifyListeners();
  }

  /// An unread or corrupt preference is not permission to use the official
  /// service. Local signaling continues while the auxiliary route is closed.
  Future<void> load() async {
    if (_stopped) return;
    final revision = ++_revision;
    try {
      final saved = await store.read();
      if (_stopped || revision != _revision) return;
      final selected = saved ?? choice;
      final next = _create(selected);
      _install(selected, next);
      error =
          selected.mode == AuxiliaryRouteMode.official && officialOrigin.isEmpty
          ? '未配置官方辅助服务；本地直连仍可使用。'
          : null;
    } on MissingPluginException {
      if (_stopped || revision != _revision) return;
      // Unsupported hosts have no persisted custom choice or auxiliary route.
      _install(choice, null);
      error = '当前平台不支持辅助服务偏好。';
    } catch (_) {
      if (_stopped || revision != _revision) return;
      _install(choice, null);
      error = '无法读取辅助服务配置；辅助链路保持关闭。';
    } finally {
      if (!_stopped && revision == _revision) {
        _loaded = true;
        notifyListeners();
      }
    }
  }

  Future<void> select(AuxiliaryRouteChoice selected) async {
    if (_stopped) return;
    RelayCredentialOwner? next;
    try {
      if (selected.mode == AuxiliaryRouteMode.custom &&
          selected.customOrigin.isEmpty) {
        throw const FormatException('Empty custom origin');
      }
      next = _create(selected);
    } catch (_) {
      error = '请输入有效的 HTTPS 辅助服务 origin。';
      notifyListeners();
      return;
    }
    final revision = ++_revision; // An older read cannot replace this choice.
    _loaded = true;
    _install(selected, next);
    error =
        selected.mode == AuxiliaryRouteMode.official && officialOrigin.isEmpty
        ? '未配置官方辅助服务；本地直连仍可使用。'
        : null;
    notifyListeners();
    final previousWrite = _writeQueue;
    _writeQueue = previousWrite.catchError((Object _) {}).then((_) async {
      if (!_stopped && revision == _revision) await store.write(selected);
    });
    try {
      await _writeQueue;
    } catch (_) {
      if (!_stopped && revision == _revision) {
        error = '当前选择已生效，但保存失败；重启后请重新确认辅助服务。';
        notifyListeners();
      }
    }
  }

  void setNeeded(bool needed) {
    if (_stopped) return;
    _needed = needed;
    _owner?.setNeeded(needed);
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    ++_revision;
    _owner?.removeListener(notifyListeners);
    _owner?.stop();
    _owner = null;
    notifyListeners();
  }
}
