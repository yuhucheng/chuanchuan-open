import 'package:flutter/material.dart';
import 'package:share_hub_connection/share_hub_connection.dart';

import '../../features/connections/connection_controller.dart';
import '../../features/connections/connection_panel.dart';
import '../../features/desktop/desktop_lifecycle.dart';
import '../../features/devices/device_controller.dart';
import '../../features/devices/device_directory.dart';
import '../../features/preview/preview_controller.dart';
import '../../features/preview/preview_engine.dart';
import '../../features/remote/remote_session_controller.dart';
import '../../features/transfers/transfer_queue.dart';
import '../../features/transfers/transfers_page.dart';
import '../../platform/client_platform.dart';
import '../remote/remote_panel.dart';
import 'appearance.dart';
import 'brand_mark.dart';
import 'device_field.dart';

class FieldShell extends StatefulWidget {
  const FieldShell({
    super.key,
    required this.devices,
    required this.connections,
    required this.preview,
    required this.remote,
    required this.transfers,
    required this.desktop,
    required this.appearance,
    required this.targetPlatform,
  });
  final DeviceController devices;
  final ConnectionController connections;
  final PreviewController preview;
  final RemoteSessionController remote;
  final TransferQueue transfers;
  final DesktopLifecycle desktop;
  final Appearance appearance;
  final TargetPlatform targetPlatform;
  @override
  State<FieldShell> createState() => _FieldShellState();
}

class _FieldShellState extends State<FieldShell> {
  final search = TextEditingController();
  final name = TextEditingController();

  /// Display material for identities verified during this run. It is never
  /// persisted and authorizes nothing: a saved entry must re-prove its identity
  /// with a new short code.
  final _verifiedNames = <String, String>{};

  /// Connection is shipped for macOS only; other hosts keep discovery read-only.
  bool get _connectionSupported =>
      widget.targetPlatform == TargetPlatform.macOS;

  /// Discovery, trust, reachability and capability are projected from the
  /// current snapshot and the live authenticated sessions only.
  ///
  /// The capability set is what this build can offer over that live connection.
  /// The peer's own support is confirmed by the session, so an entry that the
  /// peer cannot serve ends as a visible refusal rather than a silent omission.
  List<DirectoryDevice> _directory() {
    final connected = <String, TrustedConnection>{};
    for (final session in widget.connections.sessions) {
      if (!session.isClosed) connected[session.peerKey] = session;
    }
    final offered = widget.remote.offeredOperations;
    final advertised = <String, String>{};
    for (final device in widget.devices.discovery.devices) {
      if (device.publicKey != null) advertised[device.publicKey!] = device.name;
    }
    for (final key in connected.keys) {
      _verifiedNames[key] = advertised[key] ?? _verifiedNames[key] ?? '已保存设备';
    }
    final peers = <VerifiedPeer>[
      for (final key in {...connected.keys, ..._verifiedNames.keys})
        VerifiedPeer(
          publicKey: key,
          name: _verifiedNames[key],
          connected: connected.containsKey(key),
          capabilities: connected.containsKey(key) ? offered : const {},
        ),
    ];
    return buildDeviceDirectory(
      discovery: widget.devices.discovery,
      verified: peers,
    );
  }

  @override
  void dispose() {
    search.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> openPanel(String title, Widget Function() content) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  widget.devices,
                  widget.preview,
                  widget.transfers,
                  widget.appearance,
                ]),
                builder: (_, _) => content(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.devices,
      widget.connections,
      widget.preview,
      widget.remote,
      widget.desktop,
      widget.appearance,
    ]),
    builder: (context, _) => Scaffold(
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: widget.desktop.exiting,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const BrandMark(),
                    Text(
                      '串串',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    SizedBox(
                      width: 240,
                      child: TextField(
                        controller: search,
                        onChanged: (_) {
                          setState(() {});
                        },
                        decoration: const InputDecoration(
                          labelText: '搜索设备',
                          prefixIcon: Icon(Icons.search),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        name.text = widget.devices.device?.name ?? '';
                        openPanel('设置', settingsPage);
                      },
                      child: const Text('设置'),
                    ),
                    if (widget.preview.active || widget.preview.cleanupFailed)
                      TextButton.icon(
                        onPressed: widget.preview.stopping
                            ? null
                            : widget.preview.stop,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('停止预览'),
                      ),
                    if (widget.remote.occupied)
                      TextButton.icon(
                        onPressed: widget.remote.stop,
                        icon: const Icon(Icons.stop_screen_share_outlined),
                        label: const Text('停止远端画面'),
                      ),
                    TextButton(
                      onPressed: () async {
                        if (await widget.desktop.requestExit() &&
                            context.mounted) {
                          await widget.desktop.finishExit();
                        }
                      },
                      child: const Text('退出'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final error in [
                        widget.desktop.error,
                        widget.devices.error,
                        widget.appearance.error,
                        if (!widget.remote.occupied) widget.remote.error,
                      ])
                        if (error != null)
                          Semantics(liveRegion: true, child: Text(error)),
                      if (widget.connections.message != null)
                        Semantics(
                          liveRegion: true,
                          child: Text(widget.connections.message!),
                        ),
                      // The single remote picture stays in the main surface so a
                      // receiving view never unmounts mid-session.
                      if (widget.remote.occupied)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 24),
                          child: RemotePicturePanel(controller: widget.remote),
                        ),
                      // Device field remains the main surface; tools are contextual dialogs.
                      Column(
                        children: [
                          Text(
                            widget.devices.discovery.state == 'failed'
                                ? '发现失败'
                                : widget.devices.discovery.enabled
                                ? '正在发现附近设备'
                                : '正在准备发现',
                          ),
                          if (!widget.devices.discovery.enabled)
                            TextButton(
                              onPressed: widget.devices.busy
                                  ? null
                                  : widget.devices.retryDiscovery,
                              child: const Text('重试发现'),
                            ),
                          DeviceField(
                            entries: _directory(),
                            localName: widget.devices.device?.name ?? '正在读取本机',
                            allowConnections: widget.connections.accepting,
                            query: search.text,
                            onLocal: localActions,
                            onDevice: deviceActions,
                          ),
                          const Text('设备名称不是身份凭证 · 时延未测'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Future<void> localActions() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('本机与连接'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.targetPlatform == TargetPlatform.macOS)
                AnimatedBuilder(
                  animation: widget.connections,
                  builder: (_, _) =>
                      ConnectionPanel(controller: widget.connections),
                ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  openPanel('本机屏幕预览', previewPage);
                },
                child: const Text('屏幕预览'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  openPanel(
                    '本机文件准备',
                    () => TransfersPage(queue: widget.transfers),
                  );
                },
                child: const Text('文件准备'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
  Future<void> deviceActions(DirectoryDevice entry) async {
    // Actions bind to the identity of the selected entry and are re-derived
    // before anything is attempted.
    final selected = _directory()
        .where((item) => item.identityId == entry.identityId)
        .firstOrNull;
    if (selected == null || !selected.online) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AnimatedBuilder(
        animation: widget.connections,
        builder: (_, _) {
          final live = _directory()
              .where((item) => item.identityId == entry.identityId)
              .firstOrNull;
          if (live == null) return const SizedBox.shrink();
          return AlertDialog(
            title: Text(live.name),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    live.connected
                        ? '身份已验证 · 本次连接有效'
                        : live.verified
                        ? '身份已验证 · 当前未连接'
                        : '发现设备 · 尚未验证身份',
                  ),
                  const Text('设备名称与网络可见性都不是身份凭证，连接始终需要 6 位短接码。'),
                  const Text('时延未测。'),
                  if (live.connected && live.capabilities.isEmpty)
                    const Text('本构建未提供观看或投屏能力。'),
                  if (live.connected) ...[
                    const Text('对端是否支持由会话本身确认；被拒绝会明确显示失败原因。'),
                    const SizedBox(height: 8),
                    for (final operation in const [
                      SessionOperation.watch,
                      SessionOperation.cast,
                    ])
                      if (live.hasCapability(operation.name))
                        FilledButton(
                          onPressed: widget.remote.occupied
                              ? null
                              : () => Navigator.pop(context, operation.name),
                          child: Text(
                            operation == SessionOperation.watch
                                ? '观看该设备屏幕'
                                : '投屏到该设备',
                          ),
                        ),
                  ],
                  const SizedBox(height: 16),
                  if (live.connected)
                    for (final session in widget.connections.sessions.where(
                      (s) => !s.isClosed && s.peerKey == live.publicKey,
                    ))
                      TextButton(
                        onPressed: session.close,
                        child: const Text('断开并撤销授权'),
                      )
                  else if (live.connectable &&
                      _connectionSupported &&
                      widget.remote.offeredOperations.isNotEmpty) ...[
                    // The code is entered first; the operation only starts once
                    // the connection actually exists.
                    const Text('连接本身不采集任何画面。'),
                    FilledButton(
                      onPressed: widget.remote.occupied
                          ? null
                          : () => Navigator.pop(
                              context,
                              SessionOperation.watch.name,
                            ),
                      child: const Text('连接并观看'),
                    ),
                    OutlinedButton(
                      onPressed: widget.remote.occupied
                          ? null
                          : () => Navigator.pop(
                              context,
                              SessionOperation.cast.name,
                            ),
                      child: const Text('连接并投屏'),
                    ),
                  ] else if (live.connectable && _connectionSupported)
                    FilledButton(
                      onPressed: widget.connections.busy
                          ? null
                          : () => Navigator.pop(context, 'connect'),
                      child: const Text('连接设备'),
                    )
                  else
                    const Text('对端未提供可验证的连接入口，或本平台尚未支持连接。'),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          );
        },
      ),
    );
    if (action == null || !mounted) return;
    final target = _directory()
        .where((item) => item.identityId == entry.identityId)
        .firstOrNull;
    if (target == null) return;
    if (!target.connected) {
      if (!target.connectable || !_connectionSupported) return;
      await showConnectionDialog(
        context,
        widget.connections,
        device: NearbyDevice(
          target.identityId,
          target.name,
          target.platform,
          host: target.host,
          port: target.port,
          publicKey: target.publicKey,
        ),
      );
      if (!mounted) return;
      // The dialog already reported why a connection did not come up.
      final connected = _directory()
          .where((item) => item.identityId == entry.identityId)
          .firstOrNull;
      if (connected == null || !connected.connected) return;
    }
    if (action == 'connect') return;
    final live = _directory()
        .where((item) => item.identityId == entry.identityId)
        .firstOrNull;
    final peerKey = live?.publicKey;
    if (peerKey == null) return;
    await widget.remote.start(
      action == SessionOperation.cast.name
          ? SessionOperation.cast
          : SessionOperation.watch,
      peerKey: peerKey,
      label: live?.name,
    );
  }

  Widget previewPage() {
    final p = widget.preview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('本机屏幕预览', style: Theme.of(context).textTheme.headlineSmall),
        const Text('明确开始后采集当前主屏；也可先选择窗口或其他显示器。只在本机显示，不录音、不保存。'),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            OutlinedButton(
              onPressed: p.busy || p.active || p.stopping
                  ? null
                  : p.loadSources,
              child: const Text('读取屏幕与窗口'),
            ),
            if (p.sources.isNotEmpty)
              SizedBox(
                width: 360,
                child: DropdownButtonFormField<CaptureSource>(
                  key: ValueKey(p.selected?.id),
                  initialValue: p.selected,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '选择画面'),
                  items: [
                    for (final source in p.sources)
                      DropdownMenuItem(
                        value: source,
                        child: Text(
                          '${source.type == CaptureSourceType.screen ? '显示器' : '窗口'} · ${source.name}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: p.busy || p.active || p.stopping ? null : p.select,
                ),
              ),
            if (p.active || p.busy || p.cleanupFailed)
              OutlinedButton(
                onPressed: p.stopping ? null : p.stop,
                child: const Text('停止预览'),
              )
            else
              FilledButton(
                onPressed: p.stopping ? null : p.start,
                child: const Text('开始预览'),
              ),
          ],
        ),
        if (p.error != null) Semantics(liveRegion: true, child: Text(p.error!)),
        const SizedBox(height: 16),
        SizedBox(height: 340, child: p.engine.view),
        Text(
          p.firstFrame
              ? '本机预览中'
              : p.active
              ? '等待首帧'
              : '尚未采集',
        ),
        const Text('离页、隐藏或关闭主窗保留预览；停止或退出才结束。'),
      ],
    );
  }

  Widget settingsPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('设置', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 16),
      DropdownButtonFormField<ThemeMode>(
        initialValue: widget.appearance.mode,
        decoration: const InputDecoration(labelText: '主题'),
        items: const [
          DropdownMenuItem(value: ThemeMode.system, child: Text('跟随系统')),
          DropdownMenuItem(value: ThemeMode.light, child: Text('浅色')),
          DropdownMenuItem(value: ThemeMode.dark, child: Text('深色')),
        ],
        onChanged: (v) {
          if (v != null) widget.appearance.select(v);
        },
      ),
      const SizedBox(height: 24),
      TextField(
        key: const ValueKey('device-name'),
        controller: name,
        decoration: const InputDecoration(labelText: '设备名称'),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          onPressed: widget.devices.busy
              ? null
              : () => widget.devices.rename(name.text),
          child: const Text('保存名称'),
        ),
      ),
      const SizedBox(height: 24),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          if (widget.targetPlatform == TargetPlatform.macOS)
            TextButton(
              onPressed: () => widget.devices.openSettings('screenRecording'),
              child: const Text('屏幕录制设置'),
            ),
          TextButton(
            onPressed: widget.devices.refreshPermissions,
            child: const Text('刷新权限'),
          ),
          TextButton(onPressed: localActions, child: const Text('允许连接与短接码')),
        ],
      ),
      Text(
        widget.targetPlatform == TargetPlatform.windows
            ? 'Windows 可尝试本地采集；是否可用以真实首帧为准。'
            : widget.devices.permissions.screenRecording
            ? '屏幕录制已允许'
            : '屏幕录制未允许',
      ),
      const Text('Windows、macOS 无需激活或激活码。远控提示、网络文件和剪贴板设置在对应能力交付后开放。'),
    ],
  );
}
