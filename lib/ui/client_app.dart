import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/connections/connection_controller.dart';
import '../features/connections/auxiliary_route_controller.dart';
import 'field/appearance.dart';
import 'field/field_shell.dart';
import '../features/desktop/desktop_lifecycle.dart';
import '../features/devices/device_controller.dart';
import '../features/preview/preview_controller.dart';
import '../features/preview/preview_engine.dart';
import '../features/remote/remote_media.dart';
import '../features/remote/remote_session_controller.dart';
import '../features/transfers/file_access.dart';
import '../features/transfers/transfer_queue.dart';
import '../platform/client_platform.dart';

class ShareHubApp extends StatefulWidget {
  const ShareHubApp({
    super.key,
    this.platform,
    required this.previewEngine,
    this.fileAccess,
    this.remoteMedia,
    this.auxiliaryRoutes,
    this.setAuxiliaryNeeded,
    this.relayCredentialAvailable,
    this.relayCredentialChanges,
    this.stopAuxiliary,
    this.targetPlatform,
    this.appTitle = 'Share Hub',
  });
  final ClientPlatform? platform;
  final PreviewEngine previewEngine;
  final FileAccess? fileAccess;

  /// Remote send/watch implementation. Defaults to the optional public SDK port; tests
  /// inject a fake so no capture device or peer is needed.
  final RemotePictureFactory? remoteMedia;
  final AuxiliaryRouteController? auxiliaryRoutes;
  final void Function(bool)? setAuxiliaryNeeded;
  final bool Function()? relayCredentialAvailable;
  final Listenable? relayCredentialChanges;
  final void Function()? stopAuxiliary;
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
  late final _connections = ConnectionController(
    MethodChannelConnectionPlatform(),
  );
  // Both sides consult the other so the single picture budget is respected in
  // either direction. The closures are lazy, so a late field is only read after
  // the tree is built.
  late final PreviewController _preview = PreviewController(
    _platform,
    _engine,
    blockedByRemotePicture: () => _remote.shuttingDown || _remote.occupied,
  );
  late final RemoteSessionController _remote = RemoteSessionController(
    connections: _connections,
    platform: _platform,
    factory: widget.remoteMedia ?? remotePicturesFor(_engine),
    listSources: _engine.sources,
    localCaptureActive: () => _preview.occupiesPicture,
    relayCredentialAvailable: widget.relayCredentialAvailable,
    relayCredentialChanges: widget.relayCredentialChanges,
  );
  late final _transfers = TransferQueue(_fileAccess);
  late final _desktop = DesktopLifecycle(
    devices: _devices,
    connections: _connections,
    preview: _preview,
    stopRemote: _remote.shutdown,
    stopAuxiliary: widget.stopAuxiliary,
    transfers: _transfers,
    connectionSupported: connectionHostSupported(
      widget.targetPlatform ?? defaultTargetPlatform,
    ),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connections.addListener(_connectionChanged);
    _connectionChanged();
    unawaited(_appearance.load());
    unawaited(_devices.initialize());
    unawaited(_desktop.initialize());
  }

  void _connectionChanged() {
    widget.setAuxiliaryNeeded?.call(
      _connections.connecting ||
          _connections.sessions.any((session) => !session.isClosed) ||
          _connections.recoveringCount > 0,
    );
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
    _connections.removeListener(_connectionChanged);
    widget.setAuxiliaryNeeded?.call(false);
    _appearance.dispose();
    _desktop.dispose();
    _devices.dispose();
    _connections.dispose();
    _preview.dispose();
    _remote.dispose();
    widget.stopAuxiliary?.call();
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
        remote: _remote,
        transfers: _transfers,
        desktop: _desktop,
        appearance: _appearance,
        auxiliaryRoutes: widget.auxiliaryRoutes,
        targetPlatform: widget.targetPlatform ?? defaultTargetPlatform,
      ),
    ),
  );
}
