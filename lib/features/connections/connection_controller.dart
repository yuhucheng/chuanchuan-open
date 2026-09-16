import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_hub_connection/share_hub_connection.dart';

abstract interface class ConnectionPlatform {
  Future<DeviceIdentity> identity();
  Future<int> now();
  Future<String?> advertise(int? port, String? key);
}

class MacConnectionPlatform implements ConnectionPlatform {
  static const _channel = MethodChannel('dev.sharehub.client/platform');
  @override
  Future<DeviceIdentity> identity() async {
    final seed = await _channel.invokeMethod<Uint8List>('connection.identity');
    if (seed == null) throw const ConnectionFailure('identity_unavailable');
    return DeviceIdentity.fromSeed(seed);
  }

  @override
  Future<int> now() async {
    final value = await _channel.invokeMethod<int>('connection.clock');
    if (value == null) throw const ConnectionFailure('clock_unavailable');
    return value;
  }

  @override
  Future<String?> advertise(int? port, String? key) => _channel
      .invokeMethod<String>('connection.advertise', {'port': port, 'key': key});
}

class ConnectionController extends ChangeNotifier {
  ConnectionController(this.platform);
  final ConnectionPlatform platform;
  DeviceIdentity? _identity;
  PairingHost? _host;
  PairingAttempt? _attempt;
  Timer? _timer;
  bool _disposed = false;
  int _generation = 0;
  bool busy = false;
  String? code;
  String? address;
  String? message;
  final List<TrustedConnection> _sessions = [];
  List<TrustedConnection> get sessions => List.unmodifiable(_sessions);
  bool get accepting => _host?.port != null;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<DeviceIdentity> _loadIdentity() async =>
      _identity ??= await platform.identity();

  Future<void> open() async {
    if (busy || _disposed) return;
    if (_sessions.length >= 8) {
      message = '连接数量已达上限，请先断开一个连接。';
      _emit();
      return;
    }
    final generation = ++_generation;
    busy = true;
    message = null;
    code = null;
    address = null;
    _emit();
    PairingHost? opening;
    try {
      final identity = await _loadIdentity();
      if (_disposed || generation != _generation) return;
      await _host?.stopAccepting();
      if (_disposed || generation != _generation) return;
      await _clearAdvertisement();
      if (_disposed || generation != _generation) return;
      final host = opening = PairingHost(
        identity: identity,
        clock: platform.now,
        onConnection: (connection) {
          if (_disposed) {
            connection.close();
            return;
          }
          _track(connection);
          code = null;
          message = '连接已建立，短接码已消费。授权有效 8 小时，可随时断开。';
          unawaited(_clearAdvertisement());
          _emit();
        },
      );
      _host = host;
      await host.open();
      if (_disposed || generation != _generation) {
        await host.stopAccepting();
        if (identical(_host, host)) await _clearAdvertisement();
        return;
      }
      final hostname = await platform.advertise(host.port, identity.encodedKey);
      if (_disposed || generation != _generation) {
        await host.stopAccepting();
        if (identical(_host, host)) await _clearAdvertisement();
        return;
      }
      code = host.offer!.code;
      address = hostname == null ? null : '$hostname:${host.port}';
      _timer ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_tick()),
      );
    } catch (_) {
      await opening?.stopAccepting();
      if (generation == _generation) await _clearAdvertisement();
      if (!_disposed && generation == _generation) {
        message = '接入启动失败，请检查钥匙串及本地网络权限。';
      }
    } finally {
      if (generation == _generation) busy = false;
      _emit();
    }
  }

  bool _ticking = false;
  Future<void> _tick() async {
    if (_disposed || _ticking) return;
    _ticking = true;
    try {
      final offer = _host?.offer;
      final now = await platform.now();
      if (_disposed || !identical(offer, _host?.offer)) return;
      if (code != null && (offer == null || !offer.reservable(now))) {
        code = null;
        message = '短接码已失效或尝试次数已用完，请重新生成。';
        await _clearAdvertisement();
      }
      _emit();
    } catch (_) {
      for (final session in _sessions.toList()) {
        session.close('clock_unavailable');
      }
      await stopAccepting();
    } finally {
      _ticking = false;
    }
  }

  Future<void> _clearAdvertisement() async {
    try {
      await platform.advertise(null, null);
    } catch (_) {
      /* Listener still enforces closed offers. */
    }
  }

  Future<void> stopAccepting() async {
    final generation = ++_generation;
    busy = false;
    _attempt?.cancel();
    _attempt = null;
    code = null;
    address = null;
    await _host?.stopAccepting();
    if (generation == _generation) await _clearAdvertisement();
    _emit();
  }

  Future<void> connect(
    String host,
    int port,
    String shortCode, {
    String? expectedPeerKey,
  }) async {
    if (busy || _disposed) return;
    if (_sessions.length >= 8) {
      message = '连接数量已达上限，请先断开一个连接。';
      _emit();
      return;
    }
    final generation = ++_generation;
    busy = true;
    message = '正在验证短接码和对端身份…';
    _emit();
    try {
      final identity = await _loadIdentity();
      if (_disposed || generation != _generation) return;
      final attempt = _attempt = PairingAttempt(
        identity: identity,
        clock: platform.now,
      );
      final connection = await attempt.connect(
        host,
        port,
        shortCode,
        expectedPeerKey: expectedPeerKey,
      );
      if (_disposed || generation != _generation) {
        connection.close('cancelled');
        return;
      }
      _attempt = null;
      _track(connection);
      message = '身份验证通过，已建立本地直连。授权有效 8 小时。';
    } catch (error) {
      if (!_disposed && generation == _generation) {
        message = switch (error) {
          ConnectionFailure(code: 'identity_mismatch') =>
            '对端身份与所选设备不一致，请重新发现设备。',
          ConnectionFailure(code: 'invalid_input') => '请输入完整的 6 位纯数字短接码及有效端口。',
          ConnectionFailure(code: 'cancelled') => '连接已取消或握手超时。',
          _ => '连接未建立，请检查短接码、对端接入状态及局域网连通性。',
        };
      }
    } finally {
      if (generation == _generation) {
        busy = false;
        _attempt = null;
      }
      _emit();
    }
  }

  void cancel() {
    _generation++;
    _attempt?.cancel();
    _attempt = null;
    busy = false;
    message = '已取消连接。';
    _emit();
  }

  void _track(TrustedConnection connection) {
    _sessions.add(connection);
    unawaited(
      connection.whenClosed.then((reason) {
        _sessions.remove(connection);
        if (!_disposed) {
          message = reason == 'expired'
              ? '八小时授权已到期，请使用新短接码连接。'
              : '连接已断开；再次连接需输入有效短接码。';
          _emit();
        }
      }),
    );
    _emit();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _attempt?.cancel();
    _timer?.cancel();
    for (final session in _sessions.toList()) {
      session.close();
    }
    unawaited(_host?.close() ?? Future.value());
    unawaited(_clearAdvertisement());
    super.dispose();
  }
}
