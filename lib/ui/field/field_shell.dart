import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import '../../features/connections/connection_controller.dart';
import '../../features/connections/connection_panel.dart';
import '../../features/desktop/desktop_lifecycle.dart';
import '../../features/devices/device_controller.dart';
import '../../features/devices/device_directory.dart';
import '../../features/preview/preview_controller.dart';
import '../../features/preview/preview_engine.dart';
import '../../features/remote/remote_session_controller.dart';
import '../../features/remote/control_clipboard_preference.dart';
import '../../features/transfers/transfer_queue.dart';
import '../../features/transfers/transfers_page.dart';
import '../../features/transfers/network_transfers.dart';
import '../../features/transfers/network_progress_view.dart';
import '../../features/transfers/native_file_drop.dart';
import '../../platform/client_platform.dart';
import '../remote/remote_panel.dart';
import 'appearance.dart';
import 'brand_mark.dart';
import 'device_field.dart';
import 'issue_banner.dart';

class FieldShell extends StatefulWidget {
  const FieldShell({
    super.key,
    required this.devices,
    required this.connections,
    required this.preview,
    required this.remote,
    required this.transfers,
    this.networkTransfers,
    required this.desktop,
    required this.appearance,
    this.clipboardPreference,
    required this.targetPlatform,
  });
  final DeviceController devices;
  final ConnectionController connections;
  final PreviewController preview;
  final RemoteSessionController remote;
  final TransferQueue transfers;
  final NetworkTransfers? networkTransfers;
  final DesktopLifecycle desktop;
  final Appearance appearance;
  final ControlClipboardPreference? clipboardPreference;
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

  /// Trusted connections ship for the desktop hosts; every other host keeps
  /// discovery read-only.
  bool get _connectionSupported =>
      connectionHostSupported(widget.targetPlatform);

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
          capabilities: connected.containsKey(key)
              ? widget.remote.operationsFor(key)
              : const {},
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
                  ?widget.networkTransfers,
                  widget.appearance,
                  ?widget.clipboardPreference,
                  widget.desktop,
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

  Widget _fileDropRegion(DirectoryDevice? entry, Widget child) {
    final connection = entry == null
        ? null
        : widget.networkTransfers?.targets
              .where((target) => target.peerKey == entry.publicKey)
              .firstOrNull;
    if (entry != null && connection == null) return child;
    return NativeFileDropRegion(
      onDrop: (files) {
        if (!mounted || widget.desktop.exiting || widget.desktop.exited) {
          return false;
        }
        final accepted = connection == null
            ? widget.transfers.admitDroppedFiles(files) != null
            : widget.networkTransfers!.acceptDrop(files, connection);
        if (accepted) {
          unawaited(
            openPanel(
              '文件传送',
              () => TransfersPage(
                queue: widget.transfers,
                network: widget.networkTransfers,
                initialPeerKey: connection?.peerKey,
                peerName: (key) =>
                    _directory()
                        .where((d) => d.publicKey == key)
                        .firstOrNull
                        ?.name ??
                    '已验证设备',
              ),
            ),
          );
        }
        return accepted;
      },
      child: child,
    );
  }

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
                        label: Text(
                          widget.remote.operation == SessionOperation.control
                              ? '停止控制'
                              : '停止远端画面',
                        ),
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
                      IssueBanner(issues: _issues()),
                      if (widget.remote.occupied &&
                          widget.remote.operation == SessionOperation.control &&
                          widget.remote.sending &&
                          widget.desktop.controlNoticeEnabled)
                        Semantics(
                          liveRegion: true,
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  const Expanded(
                                    child: Text('此设备正在被远程控制；停止本次控制后，连接仍保持有效。'),
                                  ),
                                  TextButton(
                                    onPressed: widget.remote.stop,
                                    child: const Text('停止控制'),
                                  ),
                                ],
                              ),
                            ),
                          ),
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
                          DeviceField(
                            entries: _directory(),
                            localName: widget.devices.device?.name ?? '正在读取本机',
                            allowConnections: widget.connections.accepting,
                            query: search.text,
                            onLocal: localActions,
                            onDevice: deviceActions,
                            fileDropRegion: _fileDropRegion,
                            fileProgress: (entry) =>
                                widget.networkTransfers != null &&
                                    entry.publicKey != null
                                ? NetworkProgressView(
                                    controller: widget.networkTransfers!,
                                    peerKey: entry.publicKey,
                                    compact: true,
                                  )
                                : null,
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
              if (_connectionSupported)
                AnimatedBuilder(
                  animation: Listenable.merge([
                    widget.connections,
                    widget.devices,
                  ]),
                  builder: (_, _) => ConnectionPanel(
                    controller: widget.connections,
                    peerName: (key) =>
                        _directory()
                            .where((d) => d.publicKey == key)
                            .firstOrNull
                            ?.name ??
                        '已验证设备',
                  ),
                ),
              const SizedBox(height: 24),
              const Divider(),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '本机工具',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(context);
                      openPanel('本机屏幕预览', previewPage);
                    },
                    icon: const Icon(Icons.desktop_windows_outlined),
                    label: const Text('屏幕预览'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(context);
                      openPanel(
                        '文件传送',
                        () => TransfersPage(
                          queue: widget.transfers,
                          network: widget.networkTransfers,
                          peerName: (key) =>
                              _directory()
                                  .where((d) => d.publicKey == key)
                                  .firstOrNull
                                  ?.name ??
                              '已验证设备',
                        ),
                      );
                    },
                    icon: const Icon(Icons.folder_open),
                    label: const Text('文件传送'),
                  ),
                ],
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
        animation: Listenable.merge([
          widget.connections,
          widget.devices,
          widget.remote,
        ]),
        builder: (_, _) {
          final live = _directory()
              .where((item) => item.identityId == entry.identityId)
              .firstOrNull;
          if (live == null) return const SizedBox.shrink();
          final canInitiate =
              widget.connections.outgoingFor(live.publicKey ?? '') != null;
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
                  Text('${live.platform} · ${live.host ?? '地址未提供'}'),
                  Text('指纹摘要：${deviceFingerprint(live.publicKey)}'),
                  const Text('名称与网络可见性都不是身份凭证。'),
                  const SizedBox(height: 16),
                  const Divider(),
                  Text('会话操作', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  const Text('时延未测。'),
                  if (live.connected && widget.networkTransfers != null)
                    FilledButton.tonalIcon(
                      onPressed: () => Navigator.pop(context, 'files'),
                      icon: const Icon(Icons.file_present_outlined),
                      label: const Text('发送文件'),
                    ),
                  if (widget.remote.offeredOperations.isEmpty)
                    const Text('本构建未提供远端画面操作能力。'),
                  if (live.connected && !canInitiate)
                    const Text('当前连接由对方发起。若要发起远端操作，请让对方开启「允许连接」，再输入对方的短接码。'),
                  if (canInitiate) ...[
                    const Text('对端是否支持由会话本身确认；被拒绝会明确显示失败原因。'),
                    const Text('观看：我看它的屏幕 · 投屏：它看我的屏幕 · 控制：我操作它的电脑'),
                    const SizedBox(height: 12),
                    for (final operation in const [
                      SessionOperation.watch,
                      SessionOperation.cast,
                      SessionOperation.control,
                    ])
                      if (live.hasCapability(operation.name))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: FilledButton(
                            onPressed: widget.remote.occupied
                                ? null
                                : () => Navigator.pop(context, operation.name),
                            child: Text(
                              operation == SessionOperation.watch
                                  ? '观看该设备屏幕'
                                  : operation == SessionOperation.cast
                                  ? '投屏到该设备'
                                  : '控制该设备',
                            ),
                          ),
                        ),
                  ],
                  const SizedBox(height: 16),
                  if (!canInitiate &&
                      live.hasPairingEndpoint &&
                      _connectionSupported &&
                      widget.remote.offeredOperations.isNotEmpty) ...[
                    // The code is entered first; the operation only starts once
                    // the connection actually exists.
                    const Text('连接本身不采集任何画面。'),
                    const Text('观看：我看它的屏幕 · 投屏：它看我的屏幕 · 控制：我操作它的电脑'),
                    const SizedBox(height: 12),
                    if (widget.remote.offeredOperations.contains(
                      SessionOperation.watch.name,
                    ))
                      FilledButton(
                        onPressed: widget.remote.occupied
                            ? null
                            : () => Navigator.pop(
                                context,
                                SessionOperation.watch.name,
                              ),
                        child: const Text('连接并观看'),
                      ),
                    const SizedBox(height: 12),
                    if (widget.remote.offeredOperations.contains(
                      SessionOperation.cast.name,
                    ))
                      OutlinedButton(
                        onPressed: widget.remote.occupied
                            ? null
                            : () => Navigator.pop(
                                context,
                                SessionOperation.cast.name,
                              ),
                        child: const Text('连接并投屏'),
                      ),
                    if (widget.remote.offeredOperations.contains(
                      SessionOperation.control.name,
                    )) ...[
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: widget.remote.occupied
                            ? null
                            : () => Navigator.pop(
                                context,
                                SessionOperation.control.name,
                              ),
                        child: const Text('连接并控制'),
                      ),
                    ],
                  ] else if (!canInitiate &&
                      live.hasPairingEndpoint &&
                      _connectionSupported)
                    FilledButton(
                      onPressed: widget.connections.busy
                          ? null
                          : () => Navigator.pop(context, 'connect'),
                      child: const Text('连接设备'),
                    )
                  else if (!_connectionSupported)
                    const Text('本平台尚未支持连接。')
                  else if (!canInitiate) ...[
                    const Text('对端当前未开放连接入口。'),
                    const Text(
                      '连接入口只在对方开启「允许连接」后的有效期内广播，过时即撤下；'
                      '请让对方重新开启，再点「刷新设备」立即重试。',
                    ),
                    TextButton(
                      onPressed: widget.devices.busy
                          ? null
                          : widget.devices.retryDiscovery,
                      child: const Text('刷新设备'),
                    ),
                  ],
                  if (live.connected) ...[
                    const SizedBox(height: 28),
                    const Divider(),
                    Text('危险区', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      onPressed: () {
                        for (final session
                            in widget.connections.sessions
                                .where(
                                  (s) =>
                                      !s.isClosed &&
                                      s.peerKey == live.publicKey,
                                )
                                .toList()) {
                          session.close();
                        }
                      },
                      child: const Text('断开该设备并撤销全部授权'),
                    ),
                  ],
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
    if (action == 'files') {
      await openPanel(
        '文件传送',
        () => TransfersPage(
          queue: widget.transfers,
          network: widget.networkTransfers,
          initialPeerKey: entry.publicKey,
          peerName: (key) =>
              _directory().where((d) => d.publicKey == key).firstOrNull?.name ??
              '已验证设备',
        ),
      );
      return;
    }
    final target = _directory()
        .where((item) => item.identityId == entry.identityId)
        .firstOrNull;
    if (target == null) return;
    if (widget.connections.outgoingFor(target.publicKey ?? '') == null) {
      if (!target.hasPairingEndpoint || !_connectionSupported) return;
      final connection = await showConnectionDialog(
        context,
        widget.connections,
        nextActionLabel: action == SessionOperation.watch.name
            ? '观看该设备屏幕'
            : action == SessionOperation.cast.name
            ? '投屏到该设备'
            : action == SessionOperation.control.name
            ? '控制该设备'
            : null,
        device: NearbyDevice(
          target.identityId,
          target.name,
          target.platform,
          host: target.host,
          port: target.port,
          publicKey: target.publicKey,
        ),
      );
      if (!mounted ||
          connection == null ||
          connection.isClosed ||
          connection.peerKey != target.publicKey ||
          connection.grant?.role != GrantRole.initiator ||
          !widget.connections.sessions.any((s) => identical(s, connection))) {
        return;
      }
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
          : action == SessionOperation.control.name
          ? SessionOperation.control
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

  Future<void> _exit() async {
    if (await widget.desktop.requestExit() && mounted) {
      await widget.desktop.finishExit();
    }
  }

  List<FieldIssue> _issues() => [
    if (widget.desktop.error case final String message)
      FieldIssue('desktop', message, '打开设置', () {
        name.text = widget.devices.device?.name ?? '';
        openPanel('设置', settingsPage);
      }),
    if (widget.devices.device != null &&
        widget.targetPlatform == TargetPlatform.macOS &&
        !widget.devices.permissions.screenRecording)
      FieldIssue(
        'screen-permission',
        '屏幕录制未允许，分享画面前需要授权。',
        '打开系统设置',
        () => widget.devices.openSettings('screenRecording'),
      ),
    if (widget.devices.discovery.state == 'failed')
      FieldIssue(
        'discovery',
        widget.devices.error ??
            widget.devices.discovery.message ??
            '发现设备失败，请重试。',
        '重试发现',
        widget.devices.retryDiscovery,
      ),
    if (widget.devices.error != null &&
        widget.devices.discovery.state != 'failed')
      FieldIssue(
        'device',
        widget.devices.error!,
        widget.devices.device == null ? '重新加载本机' : '打开设置',
        widget.devices.device == null
            ? widget.devices.initialize
            : () {
                name.text = widget.devices.device?.name ?? '';
                openPanel('设置', settingsPage);
              },
      ),
    if (widget.connections.problem case final String message)
      FieldIssue('connection', message, '查看连接', localActions),
    if (!widget.remote.occupied && widget.remote.error != null)
      FieldIssue('media', widget.remote.error!, '查看本机', localActions),
    if (widget.appearance.error case final String message)
      FieldIssue(
        'appearance',
        message,
        widget.appearance.retryLabel,
        widget.appearance.retry,
      ),
  ];

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
      if (widget.appearance.error case final String message) ...[
        const SizedBox(height: 8),
        Semantics(
          liveRegion: true,
          child: Text(
            message,
            key: const ValueKey('settings-appearance-error'),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: widget.appearance.retry,
            child: Text(widget.appearance.retryLabel),
          ),
        ),
      ],
      SwitchListTile(
        title: const Text('被控提示'),
        subtitle: const Text('默认开启；关闭提示后仍可在主窗口或托盘停止控制。'),
        value: widget.desktop.controlNoticeEnabled,
        onChanged: widget.desktop.setControlNoticeEnabled,
      ),
      if (widget.clipboardPreference case final setting?)
        if (widget.remote.factory.controlCapabilities.contains(
          ControlCapability.clipboardText,
        )) ...[
          SwitchListTile(
            key: const ValueKey('settings-control-clipboard'),
            title: const Text('远程控制期间同步纯文本剪贴板'),
            subtitle: const Text('默认双向开启；任意一端关闭即暂停当前控制对的同步。'),
            value: setting.value,
            onChanged: setting.setEnabled,
          ),
          if (setting.error case final String message) ...[
            Semantics(liveRegion: true, child: Text(message)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: setting.retry,
                child: const Text('重试剪贴板设置'),
              ),
            ),
          ],
        ],
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
        ],
      ),
      Text(
        widget.targetPlatform == TargetPlatform.windows
            ? 'Windows 可尝试本地采集；是否可用以真实首帧为准。'
            : widget.devices.permissions.screenRecording
            ? '屏幕录制已允许'
            : '屏幕录制未允许',
      ),
      if (widget.devices.error case final String message) ...[
        const SizedBox(height: 8),
        Semantics(
          liveRegion: true,
          child: Text(message, key: const ValueKey('settings-device-error')),
        ),
      ],
      const Text('Windows、macOS 无需激活或激活码。文件接收位置可在文件页面更改。'),
      const SizedBox(height: 24),
      const Divider(),
      if (widget.desktop.error case final String message)
        Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(message, key: const ValueKey('settings-exit-error')),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: widget.desktop.exiting ? null : _exit,
          icon: const Icon(Icons.logout),
          label: const Text('退出'),
        ),
      ),
    ],
  );
}
