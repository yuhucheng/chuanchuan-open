import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/connections/connection_controller.dart';
import 'field/appearance.dart';
import 'field/field_shell.dart';
import '../features/desktop/desktop_lifecycle.dart';
import '../features/devices/device_controller.dart';
import '../features/preview/preview_controller.dart';
import '../features/preview/preview_engine.dart';
import '../features/transfers/file_access.dart';
import '../features/transfers/transfer_queue.dart';
import '../platform/client_platform.dart';

class ShareHubApp extends StatefulWidget {
  const ShareHubApp({
    super.key,
    this.platform,
    required this.previewEngine,
    this.fileAccess,
    this.targetPlatform,
    this.appTitle = 'Share Hub',
  });
  final ClientPlatform? platform;
  final PreviewEngine previewEngine;
  final FileAccess? fileAccess;
  final TargetPlatform? targetPlatform;
  final String appTitle;

  @override
  State<ShareHubApp> createState() => _ShareHubAppState();
}

class _ShareHubAppState extends State<ShareHubApp> with WidgetsBindingObserver {
  // Keep controller ownership and its rendered texture stable across rebuilds.
  final _appearance = Appearance();
  late final _platform = widget.platform ?? MethodChannelClientPlatform();
  late final _engine = widget.previewEngine;
  late final _fileAccess = widget.fileAccess ?? MethodChannelFileAccess();
  late final _devices = DeviceController(_platform);
  late final _connections = ConnectionController(MacConnectionPlatform());
  late final _preview = PreviewController(_platform, _engine);
  late final _transfers = TransferQueue(_fileAccess);
  late final _desktop = DesktopLifecycle(
    devices: _devices,
    connections: _connections,
    preview: _preview,
    transfers: _transfers,
    connectionSupported:
        (widget.targetPlatform ?? defaultTargetPlatform) ==
        TargetPlatform.macOS,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_appearance.load());
    unawaited(_devices.initialize());
    unawaited(_desktop.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_devices.refreshPermissions());
    }
    if (state == AppLifecycleState.detached) unawaited(_desktop.requestExit());
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async =>
      await _desktop.requestExit()
      ? AppExitResponse.exit
      : AppExitResponse.cancel;
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _appearance.dispose();
    _desktop.dispose();
    _devices.dispose();
    _connections.dispose();
    _preview.dispose();
    _transfers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _appearance,
    builder: (context, _) => MaterialApp(
      title: widget.appTitle,
      debugShowCheckedModeBanner: false,
      theme: fieldTheme(
        Brightness.light,
        widget.targetPlatform ?? defaultTargetPlatform,
      ),
      darkTheme: fieldTheme(
        Brightness.dark,
        widget.targetPlatform ?? defaultTargetPlatform,
      ),
      themeMode: _appearance.mode,
      home: FieldShell(
        devices: _devices,
        connections: _connections,
        preview: _preview,
        transfers: _transfers,
        desktop: _desktop,
        appearance: _appearance,
        targetPlatform: widget.targetPlatform ?? defaultTargetPlatform,
      ),
    ),
  );
}
