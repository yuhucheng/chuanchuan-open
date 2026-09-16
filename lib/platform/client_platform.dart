import 'package:flutter/services.dart';

class LocalDevice {
  const LocalDevice(this.id, this.name);
  final String id;
  final String name;

  factory LocalDevice.fromMap(Map<dynamic, dynamic> map) =>
      LocalDevice(map['id'] as String, map['name'] as String);
}

class PermissionStatus {
  const PermissionStatus({
    this.screenRecording = false,
    this.accessibility = false,
  });
  // macOS: TCC screen permission. Windows: capture can be attempted; this
  // does not guarantee a frame or grant remote input/system-wide access.
  final bool screenRecording;
  final bool accessibility;
}

class NearbyDevice {
  const NearbyDevice(
    this.id,
    this.name,
    this.platform, {
    this.host,
    this.port,
    this.publicKey,
  });
  final String? host;
  final int? port;
  final String? publicKey;
  final String id;
  final String name;
  final String platform;
}

class DiscoverySnapshot {
  const DiscoverySnapshot({
    this.state = 'stopped',
    this.devices = const [],
    this.message,
  });
  final String state;
  final List<NearbyDevice> devices;
  final String? message;
  bool get enabled => ['starting', 'searching', 'waiting'].contains(state);

  factory DiscoverySnapshot.fromMap(Map<dynamic, dynamic> map) =>
      DiscoverySnapshot(
        state: map['state'] as String,
        message: map['message'] as String?,
        devices: (map['devices'] as List)
            .map(
              (item) => NearbyDevice(
                item['id'] as String,
                item['name'] as String,
                item['platform'] as String,
                host: item['host'] as String?,
                port: int.tryParse(item['port']?.toString() ?? ''),
                publicKey: item['key'] as String?,
              ),
            )
            .toList(growable: false),
      );
}

abstract interface class ClientPlatform {
  Future<LocalDevice> loadDevice();
  Future<LocalDevice> setDeviceName(String name);
  Future<PermissionStatus> permissions();
  Future<bool> requestScreenRecording();
  Future<void> openSettings(String permission);
  Stream<DiscoverySnapshot> get discoveryEvents;
  Future<void> startDiscovery();
  Future<void> stopDiscovery();
}

class MethodChannelClientPlatform implements ClientPlatform {
  static const _methods = MethodChannel('dev.sharehub.client/platform');
  static const _events = EventChannel('dev.sharehub.client/discovery');

  @override
  Future<LocalDevice> loadDevice() async => LocalDevice.fromMap(
    (await _methods.invokeMapMethod<String, dynamic>('loadDevice'))!,
  );

  @override
  Future<LocalDevice> setDeviceName(String name) async => LocalDevice.fromMap(
    (await _methods.invokeMapMethod<String, dynamic>('setDeviceName', name))!,
  );

  @override
  Future<PermissionStatus> permissions() async {
    final result = (await _methods.invokeMapMethod<String, bool>(
      'permissions',
    ))!;
    return PermissionStatus(
      screenRecording: result['screenRecording'] == true,
      accessibility: result['accessibility'] == true,
    );
  }

  @override
  Future<bool> requestScreenRecording() async =>
      await _methods.invokeMethod<bool>('requestScreenRecording') ?? false;

  @override
  Future<void> openSettings(String permission) async {
    if (await _methods.invokeMethod<bool>('openSettings', permission) != true) {
      throw StateError('无法打开系统设置，请手动打开系统设置。');
    }
  }

  @override
  Stream<DiscoverySnapshot> get discoveryEvents => _events
      .receiveBroadcastStream()
      .map((event) => DiscoverySnapshot.fromMap(event as Map));

  @override
  Future<void> startDiscovery() => _methods.invokeMethod('startDiscovery');
  @override
  Future<void> stopDiscovery() => _methods.invokeMethod('stopDiscovery');
}
