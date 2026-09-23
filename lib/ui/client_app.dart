import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart' as sdk;

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
import '../features/remote/control_clipboard_preference.dart';
import '../features/transfers/file_access.dart';
import '../features/transfers/transfer_queue.dart';
import '../features/transfers/network_transfers.dart';
import '../features/transfers/native_file_drop.dart';
import '../features/transfers/receive_access.dart';
import '../features/transfers/source_access.dart';
import '../platform/client_platform.dart';

class ShareHubApp extends StatefulWidget {
  const ShareHubApp({
    super.key,
    this.platform,
    required this.previewEngine,
    this.fileAccess,
    this.receiveAccess,
    this.sourceAccess,
    this.remoteMedia,
    this.currentRelayLease,
    this.auxiliaryRoutes,
    this.setAuxiliaryNeeded,
    this.stopAuxiliary,
    this.controlClipboardPreference,
    this.targetPlatform,
    this.appTitle = 'Share Hub',
  });
  final ClientPlatform? platform;
  final PreviewEngine previewEngine;
  final FileAccess? fileAccess;
  final ReceiveAccess? receiveAccess;
  final SourceAccess? sourceAccess;

  /// Remote send/watch implementation. Defaults to the media SDK adapter; tests
  /// inject a fake so no capture device or peer is needed.
  final RemotePictureFactory? remoteMedia;
  final sdk.RelayIceLease? Function()? currentRelayLease;
  final AuxiliaryRouteController? auxiliaryRoutes;
  final void Function(bool)? setAuxiliaryNeeded;
  final void Function()? stopAuxiliary;
  final ControlClipboardPreference? controlClipboardPreference;
  final TargetPlatform? targetPlatform;
  final String appTitle;

  @override
  State<ShareHubApp> createState() => _ShareHubAppState();
}

class _ShareHubAppState extends State<ShareHubApp> with WidgetsBindingObserver {
  // Keep controller ownership and its rendered texture stable across rebuilds.
  final _appearance = Appearance();
  late final _clipboardPreference =
      widget.controlClipboardPreference ?? ControlClipboardPreference();
  final _messages = GlobalKey<ScaffoldMessengerState>();
  late final _platform = widget.platform ?? MethodChannelClientPlatform();
  late final _engine = widget.previewEngine;
  late final _fileAccess = widget.fileAccess ?? MethodChannelFileAccess();
  late final _devices = DeviceController(_platform);
  late final _connections = ConnectionController(
    MethodChannelConnectionPlatform(),
    auxiliaryRoutes: widget.auxiliaryRoutes,
  );
  // Both sides consult the other so the single picture budget is respected in
  // either direction. The closures are lazy, so a late field is only read after
  // the tree is built.
  late final PreviewController _preview = PreviewController(
    _platform,
    _engine,
    blockedByRemotePicture: () => _remote.occupied,
  );
  late final RemoteSessionController _remote = RemoteSessionController(
    connections: _connections,
    platform: _platform,
    factory:
        widget.remoteMedia ??
        (widget.currentRelayLease == null
            ? RtcRemotePictureFactory()
            : RtcRemotePictureFactory.withRelayLease(
                widget.currentRelayLease!,
              )),
    listSources: _engine.sources,
    localCaptureActive: () => _preview.occupiesPicture,
  );
  late final _transfers = TransferQueue(_fileAccess);
  late final _networkTransfers = NetworkTransfers(
    connections: _connections,
    queue: _transfers,
    source: widget.sourceAccess ?? MethodChannelSourceAccess(),
    receive: widget.receiveAccess ?? MethodChannelReceiveAccess(),
  );
  late final _desktop = DesktopLifecycle(
    devices: _devices,
    connections: _connections,
    preview: _preview,
    transfers: _transfers,
    closeNetworkTransfers: _networkTransfers.close,
    stopAuxiliary: widget.stopAuxiliary,
    controlActive: () =>
        _remote.occupied && _remote.operation == SessionOperation.control,
    controlChanges: _remote,
    stopControl: _remote.stop,
    stopRemotePicture: () async {
      await _remote.stop();
      return !_remote.occupied;
    },
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
    unawaited(_clipboardPreference.load());
    unawaited(_devices.initialize());
    unawaited(_desktop.initialize());
  }

  void _connectionChanged() {
    widget.setAuxiliaryNeeded?.call(
      _connections.busy ||
          _connections.sessions.any((session) => !session.isClosed),
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
    if (widget.controlClipboardPreference == null) {
      _clipboardPreference.dispose();
    }
    _desktop.dispose();
    _devices.dispose();
    _connections.dispose();
    _preview.dispose();
    _remote.dispose();
    _networkTransfers.dispose();
    widget.stopAuxiliary?.call();
    _transfers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NativeFileDropHost(
    enabled:
        _fileAccess is MethodChannelFileAccess &&
        {
          TargetPlatform.windows,
          TargetPlatform.macOS,
        }.contains(widget.targetPlatform ?? defaultTargetPlatform),
    canAccept: () => !_desktop.exiting && !_desktop.exited,
    onError: (message) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _messages.currentState?.showSnackBar(
            SnackBar(content: Text(message)),
          );
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    },
    child: AnimatedBuilder(
      animation: _appearance,
      builder: (context, _) => MaterialApp(
        title: widget.appTitle,
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: _messages,
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
          networkTransfers: _networkTransfers,
          desktop: _desktop,
          appearance: _appearance,
          clipboardPreference: _clipboardPreference,
          auxiliaryRoutes: widget.auxiliaryRoutes,
          targetPlatform: widget.targetPlatform ?? defaultTargetPlatform,
        ),
      ),
    ),
  );
}
