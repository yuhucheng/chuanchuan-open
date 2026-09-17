import 'package:flutter/material.dart';

import '../../features/connections/connection_controller.dart';
import '../../features/connections/connection_panel.dart';
import '../../features/desktop/desktop_lifecycle.dart';
import '../../features/devices/device_controller.dart';
import '../../features/preview/preview_controller.dart';
import '../../features/preview/preview_engine.dart';
import '../../features/transfers/transfer_queue.dart';
import '../../features/transfers/transfers_page.dart';
import '../../platform/client_platform.dart';
import 'appearance.dart';
import 'brand_mark.dart';
import 'device_field.dart';

class FieldShell extends StatefulWidget {
  const FieldShell({
    super.key,
    required this.devices,
    required this.connections,
    required this.preview,
    required this.transfers,
    required this.desktop,
    required this.appearance,
    required this.targetPlatform,
  });
  final DeviceController devices;
  final ConnectionController connections;
  final PreviewController preview;
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
                      ])
                        if (error != null)
                          Semantics(liveRegion: true, child: Text(error)),
                      if (widget.connections.message != null)
                        Semantics(
                          liveRegion: true,
                          child: Text(widget.connections.message!),
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
                            devices: widget.devices.discovery.devices,
                            verifiedPeers: widget.connections.sessions
                                .where((s) => !s.isClosed)
                                .map((s) => s.peerKey)
                                .toSet(),
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
  Future<void> deviceActions(NearbyDevice device) async {
    final available = widget.devices.discovery.devices.any(
      (d) => d.id == device.id && d.publicKey == device.publicKey,
    );
    if (!available) return;
    final action = await showDialog<bool>(
      context: context,
      builder: (context) => AnimatedBuilder(
        animation: widget.connections,
        builder: (_, _) {
          final connected = widget.connections.sessions.any(
            (s) => !s.isClosed && s.peerKey == device.publicKey,
          );
          final canConnect =
              widget.targetPlatform == TargetPlatform.macOS &&
              device.host != null &&
              device.port != null &&
              device.publicKey != null;
          return AlertDialog(
            title: Text(device.name),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(connected ? '身份已验证 · 本次连接有效' : '发现设备 · 尚未验证身份'),
                  const Text('时延未测。当前可建立可信连接。'),
                  const SizedBox(height: 16),
                  if (!connected && canConnect)
                    FilledButton(
                      onPressed: widget.connections.busy
                          ? null
                          : () => Navigator.pop(context, true),
                      child: const Text('连接设备'),
                    ),
                  if (!connected && !canConnect)
                    const Text('对端未提供可验证的连接入口，或本平台尚未支持连接。'),
                  for (final session in widget.connections.sessions.where(
                    (s) => s.peerKey == device.publicKey,
                  ))
                    TextButton(
                      onPressed: session.close,
                      child: const Text('断开并撤销授权'),
                    ),
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
    if (action == true && mounted) {
      final current = widget.devices.discovery.devices
          .where((d) => d.id == device.id && d.publicKey == device.publicKey)
          .firstOrNull;
      if (current != null) {
        await showConnectionDialog(
          context,
          widget.connections,
          device: current,
        );
      }
    }
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
