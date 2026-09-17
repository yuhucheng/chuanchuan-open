import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:share_hub_open/features/preview/preview_engine.dart';
import 'package:share_hub_open/platform/mac_platform.dart';

class FakePlatform implements MacPlatform {
  LocalDevice device = const LocalDevice('local', '书房 Mac');
  PermissionStatus status = const PermissionStatus();
  final events = StreamController<DiscoverySnapshot>.broadcast();
  int starts = 0;
  int stops = 0;
  int permissionRequests = 0;
  bool grantPermission = false;
  Object? loadError;
  Object? discoveryError;
  Completer<void>? discoveryGate;
  Object? renameError;
  Completer<bool>? permissionCompleter;
  final openedSettings = <String>[];

  @override
  Future<LocalDevice> loadDevice() async {
    if (loadError != null) throw loadError!;
    return device;
  }

  @override
  Future<LocalDevice> setDeviceName(String name) async {
    if (renameError != null) throw renameError!;
    return device = LocalDevice(device.id, name.trim());
  }

  @override
  Future<PermissionStatus> permissions() async => status;
  @override
  Future<bool> requestScreenRecording() async {
    permissionRequests++;
    return permissionCompleter?.future ?? grantPermission;
  }

  @override
  Future<void> openSettings(String permission) async {
    openedSettings.add(permission);
  }

  @override
  Stream<DiscoverySnapshot> get discoveryEvents => events.stream;
  @override
  Future<void> startDiscovery() async {
    starts++;
    if (discoveryGate != null) await discoveryGate!.future;
    if (discoveryError != null) throw discoveryError!;
    events.add(const DiscoverySnapshot(state: 'searching'));
  }

  @override
  Future<void> stopDiscovery() async {
    stops++;
    if (!events.isClosed) events.add(const DiscoverySnapshot());
  }
}

class FakePreviewEngine implements PreviewEngine {
  @override
  String? get unavailableReason => null;
  int sourceCalls = 0;
  List<CaptureSource> availableSources = [
    const CaptureSource('screen:1', '内建显示器', isPrimary: true),
  ];
  CaptureSource? startedSource;
  int starts = 0;
  int stops = 0;
  bool released = false;
  bool closed = false;
  bool failStart = false;
  bool failStop = false;
  Completer<void>? startCompleter;
  VoidCallback? ended;
  VoidCallback? firstFrame;

  @override
  Future<List<CaptureSource>> sources() async {
    sourceCalls++;
    return availableSources;
  }

  @override
  Future<void> start(
    CaptureSource source, {
    required VoidCallback onEnded,
    required VoidCallback onFirstFrame,
  }) async {
    starts++;
    startedSource = source;
    ended = onEnded;
    firstFrame = onFirstFrame;
    await startCompleter?.future;
    if (failStart) throw StateError('capture failed');
  }

  @override
  Future<void> stop() async {
    stops++;
    if (failStop) throw StateError('cleanup failed');
    released = true;
  }

  @override
  Future<void> dispose() async {
    closed = true;
  }

  @override
  Widget get view => const ColoredBox(color: Color(0xFF30594C));
}
