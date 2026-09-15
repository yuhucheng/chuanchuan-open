import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/devices/device_controller.dart';
import '../features/preview/preview_controller.dart';
import '../features/preview/preview_engine.dart';
import '../features/transfers/file_access.dart';
import '../features/transfers/transfer_queue.dart';
import '../features/transfers/transfers_page.dart';
import '../platform/client_platform.dart';

const _ink = Color(0xFF1D3430);
const _green = Color(0xFF247A68);
const _muted = Color(0xFF697A74);

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

class _ShareHubAppState extends State<ShareHubApp> {
  // Keep controller ownership and its rendered texture stable across rebuilds.
  late final _platform = widget.platform ?? MethodChannelClientPlatform();
  late final _engine = widget.previewEngine;
  late final _fileAccess = widget.fileAccess ?? MethodChannelFileAccess();

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: widget.appTitle,
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _green,
        surface: const Color(0xFFF6F7F3),
      ),
      scaffoldBackgroundColor: const Color(0xFFF6F7F3),
      platform: widget.targetPlatform ?? defaultTargetPlatform,
      fontFamily:
          (widget.targetPlatform ?? defaultTargetPlatform) ==
              TargetPlatform.windows
          ? 'Microsoft YaHei UI'
          : '.AppleSystemUIFont',
      textTheme: ThemeData.light().textTheme.apply(
        bodyColor: _ink,
        displayColor: _ink,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: _green,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    ),
    home: ClientWindow(
      appTitle: widget.appTitle,
      platform: _platform,
      engine: _engine,
      fileAccess: _fileAccess,
      targetPlatform: widget.targetPlatform ?? defaultTargetPlatform,
    ),
  );
}

class ClientWindow extends StatefulWidget {
  const ClientWindow({
    super.key,
    required this.platform,
    required this.engine,
    required this.fileAccess,
    this.targetPlatform = TargetPlatform.macOS,
    this.appTitle = 'Share Hub',
  });
  final ClientPlatform platform;
  final PreviewEngine engine;
  final FileAccess fileAccess;
  final TargetPlatform targetPlatform;
  final String appTitle;

  @override
  State<ClientWindow> createState() => _ClientWindowState();
}

class _ClientWindowState extends State<ClientWindow>
    with WidgetsBindingObserver {
  late final _devices = DeviceController(widget.platform);
  late final _preview = PreviewController(widget.platform, widget.engine);
  late final _transfers = TransferQueue(widget.fileAccess);
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  int _page = 0;
  bool get _windows => widget.targetPlatform == TargetPlatform.windows;
  String get _deviceLabel => _windows ? 'Windows 电脑' : 'Mac';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      _devices.initialize().then((_) {
        if (mounted) _name.text = _devices.device?.name ?? '';
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_devices.refreshPermissions());
    }
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_preview.stop());
    }
  }

  void _navigate(int index) {
    if (index == _page) return;
    if (index == 3 && !_nameFocus.hasFocus) {
      _name.text = _devices.device?.name ?? '';
    }
    // Capture remains visible while running; navigating away ends it.
    if (_page == 1) unawaited(_preview.stop());
    setState(() => _page = index);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _devices.dispose();
    _preview.dispose();
    _transfers.dispose();
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_devices, _preview]),
    builder: (context, _) => Scaffold(
      body: Row(
        children: [
          _sidebar(MediaQuery.sizeOf(context).width >= 1000),
          Expanded(
            child: Column(
              children: [
                _topbar(),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1100),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_devices.error != null) ...[
                              _notice(_devices.error!, error: true),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(
                                  onPressed: _devices.busy
                                      ? null
                                      : () => _devices.device == null
                                            ? _devices.initialize()
                                            : _devices.refreshPermissions(),
                                  child: const Text('重新检查'),
                                ),
                              ),
                            ],
                            if (_page != 1 && _preview.cleanupFailed) ...[
                              _notice(_preview.error!, error: true),
                              TextButton(
                                onPressed: _preview.stopping
                                    ? null
                                    : _preview.stop,
                                child: const Text('重试停止屏幕采集'),
                              ),
                            ],
                            switch (_page) {
                              0 => _devicesPage(),
                              1 => _previewPage(),
                              2 =>
                                _windows
                                    ? _notice(
                                        'Windows 文件准备功能开发中。当前可以发现附近设备和预览本机画面。',
                                      )
                                    : TransfersPage(queue: _transfers),
                              _ => _settingsPage(),
                            },
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _sidebar(bool expanded) => Container(
    width: expanded ? 220 : 80,
    color: const Color(0xFF183C33),
    padding: EdgeInsets.symmetric(horizontal: expanded ? 18 : 10, vertical: 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: expanded
              ? MainAxisAlignment.start
              : MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: const Color(0xFFC3ECD5),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(
                Icons.hub_outlined,
                color: Color(0xFF183C33),
                size: 25,
              ),
            ),
            if (expanded)
              Flexible(
                child: Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: Text(
                    widget.appTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 48),
        for (final item in [
          (Icons.devices_rounded, '设备'),
          (Icons.desktop_windows_outlined, '屏幕预览'),
          (Icons.folder_copy_outlined, '文件传送'),
          (Icons.tune_rounded, '设置'),
        ].indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Tooltip(
              message: item.$2.$2,
              child: Material(
                color: _page == item.$1
                    ? const Color(0xFF30594C)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _navigate(item.$1),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 15,
                    ),
                    child: Row(
                      mainAxisAlignment: expanded
                          ? MainAxisAlignment.start
                          : MainAxisAlignment.center,
                      children: [
                        Icon(
                          item.$2.$1,
                          color: _page == item.$1
                              ? const Color(0xFFCAF1D8)
                              : const Color(0xFFA3BCB0),
                          size: 22,
                        ),
                        if (expanded)
                          Padding(
                            padding: const EdgeInsets.only(left: 13),
                            child: Text(
                              item.$2.$2,
                              style: TextStyle(
                                color: _page == item.$1
                                    ? Colors.white
                                    : const Color(0xFFC0D0C6),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        const Spacer(),
        if (expanded) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF24483D),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.spa_outlined, color: Color(0xFFBCE3CA)),
                SizedBox(height: 10),
                Text(
                  '让设备，靠近一点。',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  '免费 · 无订阅',
                  style: TextStyle(color: Color(0xFFA8C1B2), fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '${_windows ? 'Windows' : 'macOS'}  ·  0.1 开发预览',
            style: const TextStyle(color: Color(0xFFA8C1B2), fontSize: 11),
          ),
        ],
      ],
    ),
  );

  Widget _topbar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xFFE1E6DE))),
    ),
    child: Row(
      children: [
        Text(
          ['设备', '屏幕预览', '文件传送', '设置'][_page],
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const Spacer(),
        if (_preview.active || _preview.cleanupFailed) ...[
          TextButton.icon(
            onPressed: _preview.stopping ? null : _preview.stop,
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('停止预览'),
          ),
          const SizedBox(width: 12),
        ],
        Icon(
          _windows ? Icons.desktop_windows : Icons.laptop_mac,
          size: 18,
          color: _muted,
        ),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(
            _devices.device?.name ?? '正在读取本机信息',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _muted, fontSize: 13),
          ),
        ),
      ],
    ),
  );

  Widget _devicesPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: const Color(0xFFE5EEE3),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Tag('你的局域网工作空间'),
                  const SizedBox(height: 18),
                  Text(
                    '从这台 $_deviceLabel 开始',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.8,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '发现身边的设备，先准备好你的画面。',
                    style: TextStyle(color: _muted, height: 1.6),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => _navigate(1),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('预览本机屏幕'),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Icon(
                Icons.devices_rounded,
                size: 94,
                color: Color(0xFF76A48D),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const _IconTile(Icons.radar_rounded),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '局域网设备发现',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        '开启后，附近设备可看到你设置的名称。',
                        style: TextStyle(color: _muted, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: _devices.discovery.enabled,
                  onChanged: _devices.busy || _devices.device == null
                      ? null
                      : _devices.setDiscovery,
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Divider(height: 1, color: Color(0xFFEBEEE7)),
            const SizedBox(height: 20),
            Row(
              children: [
                const Text(
                  '附近设备',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                _Tag(switch (_devices.discovery.state) {
                  'starting' => '正在启动',
                  'searching' => '正在发现',
                  'waiting' => '等待网络',
                  'failed' => '发现失败',
                  _ => '未开启',
                }),
              ],
            ),
            if (_devices.discovery.message != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: _notice(_devices.discovery.message!, error: true),
              ),
            if (_devices.discovery.devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Column(
                  children: [
                    const Icon(
                      Icons.wifi_tethering_rounded,
                      size: 34,
                      color: Color(0xFF8CA295),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _devices.discovery.enabled ? '还没有发现其他设备' : '开启发现，看看谁在附近',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '另一台设备也需运行此开发版，并开启发现。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _muted, fontSize: 13),
                    ),
                  ],
                ),
              )
            else
              ..._devices.discovery.devices.map(
                (device) => ListTile(
                  contentPadding: const EdgeInsets.only(top: 12),
                  leading: _IconTile(
                    device.platform == 'android'
                        ? Icons.phone_android
                        : Icons.computer,
                  ),
                  title: Text(
                    device.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${device.platform} · 身份尚未验证'),
                  trailing: const _Tag('未配对'),
                ),
              ),
            const Text(
              '设备配对开发中；当前仅发现设备，暂不能建立连接。',
              style: TextStyle(color: _muted, fontSize: 12),
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      _notice('当前为开发预览，尚未接入邀请码激活。跨设备投屏、文件传送和远程控制将在后续阶段开放。'),
    ],
  );

  Widget _previewPage() => widget.engine.unavailableReason != null
      ? _notice(widget.engine.unavailableReason!)
      : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _heading('先看看，你的画面', '选择一个显示器或窗口，只在这台 $_deviceLabel 上预览。'),
            _card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '画面来源',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            _preview.busy ||
                                _preview.active ||
                                _preview.stopping ||
                                _preview.cleanupFailed
                            ? null
                            : _preview.loadSources,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('读取屏幕与窗口'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_preview.sources.isNotEmpty) ...[
                    DropdownButtonFormField<CaptureSource>(
                      key: ValueKey((
                        _preview.selected?.id,
                        _preview.selected?.type,
                      )),
                      initialValue: _preview.selected,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '选择画面'),
                      hint: const Text('请选择一个显示器或窗口'),
                      items: _preview.sources
                          .map(
                            (source) => DropdownMenuItem(
                              value: source,
                              child: Text(
                                '${source.type == CaptureSourceType.screen ? '显示器' : '窗口'} · ${source.name}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged:
                          _preview.busy ||
                              _preview.active ||
                              _preview.stopping ||
                              _preview.cleanupFailed
                          ? null
                          : _preview.select,
                    ),
                    const SizedBox(height: 18),
                  ],
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox(
                      height: (MediaQuery.sizeOf(context).height - 520).clamp(
                        180.0,
                        380.0,
                      ),
                      child: ColoredBox(
                        color: const Color(0xFF172B26),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (_preview.active) widget.engine.view,
                            if (!_preview.firstFrame)
                              Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _preview.active
                                          ? Icons.hourglass_top
                                          : Icons.desktop_windows_outlined,
                                      color: const Color(0xFF8CB7A3),
                                      size: 48,
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      _preview.active
                                          ? '等待第一帧画面'
                                          : '你的画面将在这里出现',
                                      style: const TextStyle(
                                        color: Color(0xFFD7E9DE),
                                        fontSize: 16,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      _windows
                                          ? '选择来源后，由你手动开始采集'
                                          : '开始前会检查屏幕录制权限',
                                      style: const TextStyle(
                                        color: Color(0xFF91AA9D),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            if (_preview.active)
                              Positioned(
                                top: 14,
                                left: 14,
                                child: _Tag(
                                  _preview.firstFrame ? '本机预览中' : '正在读取画面',
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 12,
                    spacing: 20,
                    children: [
                      const Text(
                        '仅本机显示 · 不录音 · 不保存',
                        style: TextStyle(color: _muted, fontSize: 12),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_preview.active ||
                              _preview.busy ||
                              _preview.cleanupFailed)
                            OutlinedButton.icon(
                              onPressed: _preview.stopping
                                  ? null
                                  : _preview.stop,
                              icon: const Icon(Icons.stop_rounded),
                              label: const Text('停止预览'),
                            )
                          else
                            FilledButton.icon(
                              onPressed:
                                  _preview.selected == null || _preview.stopping
                                  ? null
                                  : _preview.start,
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: const Text('开始预览'),
                            ),
                          if (_preview.busy || _preview.stopping)
                            const Padding(
                              padding: EdgeInsets.only(left: 14),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                  if (_preview.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: _notice(_preview.error!, error: true),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Icon(Icons.privacy_tip_outlined, size: 19, color: _muted),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '离开本页或隐藏应用时，预览会停止。',
                    style: TextStyle(color: _muted, fontSize: 13),
                  ),
                ),
                if (!_windows)
                  TextButton(
                    onPressed: () => _devices.openSettings('screenRecording'),
                    child: const Text('屏幕录制设置'),
                  ),
              ],
            ),
          ],
        );

  Widget _settingsPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _heading('为这台 $_deviceLabel 做好准备', '设备名称保存在本机；画面采集由你手动开启。'),
      _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '本机设备',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _name,
              focusNode: _nameFocus,
              enabled: _devices.device != null && !_devices.busy,
              maxLength: 42,
              decoration: const InputDecoration(
                labelText: '设备名称',
                helperText: '开启发现时，此名称会展示给局域网中的其他设备。',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _devices.busy || _devices.device == null
                  ? null
                  : () async {
                      _nameFocus.unfocus();
                      await _devices.rename(_name.text);
                      if (mounted && _devices.error == null) {
                        _name.text = _devices.device!.name;
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('设备名称已保存')),
                        );
                      }
                    },
              child: const Text('保存名称'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      if (_windows)
        _windowsCapabilities()
      else
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '系统权限',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _devices.busy
                        ? null
                        : _devices.refreshPermissions,
                    icon: const Icon(Icons.refresh, size: 17),
                    label: const Text('刷新状态'),
                  ),
                ],
              ),
              if (widget.engine.unavailableReason == null)
                _permissionRow(
                  Icons.screen_share_outlined,
                  '屏幕录制',
                  '预览和分享你选择的画面',
                  _devices.permissions.screenRecording,
                  'screenRecording',
                ),
              if (widget.engine.unavailableReason == null)
                const Divider(color: Color(0xFFEBEEE7)),
              _permissionRow(
                Icons.touch_app_outlined,
                '辅助功能',
                '远程被控开发中，当前无需开启',
                _devices.permissions.accessibility,
                'accessibility',
              ),
              const Divider(color: Color(0xFFEBEEE7)),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const _IconTile(Icons.wifi_outlined),
                title: const Text('本地网络'),
                subtitle: const Text(
                  '开启发现时由系统检查；macOS 15+ 可在设置中管理。',
                  style: TextStyle(fontSize: 12),
                ),
                trailing: TextButton(
                  onPressed: () => _devices.openSettings('localNetwork'),
                  child: const Text('系统设置'),
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 22),
      _notice('${widget.appTitle} 0.1 开发预览\n邀请码激活、可信设备配对与连接服务尚未接入。当前版本仅供开发验证。'),
    ],
  );

  Widget _windowsCapabilities() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Windows 功能状态',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const _IconTile(Icons.screen_share_outlined),
          title: const Text('屏幕预览'),
          subtitle: Text(
            widget.engine.unavailableReason ?? '选择显示器或窗口后手动开始；锁屏或受保护的画面可能无法采集。',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        const Divider(color: Color(0xFFEBEEE7)),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _IconTile(Icons.touch_app_outlined),
          title: Text('远程控制'),
          subtitle: Text(
            '开发中，当前不会接收或注入键盘、鼠标输入。',
            style: TextStyle(fontSize: 12),
          ),
        ),
        const Divider(color: Color(0xFFEBEEE7)),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const _IconTile(Icons.wifi_outlined),
          title: const Text('本地网络'),
          subtitle: const Text(
            '在信任的家庭或工作网络中开启发现；系统网络策略可能限制设备可见性。',
            style: TextStyle(fontSize: 12),
          ),
          trailing: TextButton(
            onPressed: () => _devices.openSettings('localNetwork'),
            child: const Text('网络设置'),
          ),
        ),
      ],
    ),
  );

  Widget _permissionRow(
    IconData icon,
    String title,
    String detail,
    bool granted,
    String key,
  ) => ListTile(
    contentPadding: const EdgeInsets.symmetric(vertical: 8),
    leading: _IconTile(icon),
    title: Text(title),
    subtitle: Text(detail, style: const TextStyle(fontSize: 12)),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          granted ? '已允许' : '未允许',
          style: TextStyle(fontSize: 12, color: granted ? _green : _muted),
        ),
        const SizedBox(width: 10),
        TextButton(
          onPressed: () => _devices.openSettings(key),
          child: const Text('系统设置'),
        ),
      ],
    ),
  );

  Widget _heading(String title, String detail) => Padding(
    padding: const EdgeInsets.only(bottom: 26),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 10),
        Text(detail, style: const TextStyle(color: _muted, height: 1.5)),
      ],
    ),
  );
}

Widget _card(Widget child) => Container(
  padding: const EdgeInsets.all(24),
  decoration: BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(18),
    border: Border.all(color: const Color(0xFFE3E8DF)),
  ),
  child: child,
);

Widget _notice(String message, {bool error = false}) => Container(
  padding: const EdgeInsets.all(16),
  decoration: BoxDecoration(
    color: error ? const Color(0xFFFFEDE5) : const Color(0xFFEBEFE7),
    borderRadius: BorderRadius.circular(12),
  ),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        error ? Icons.info_outline : Icons.construction_outlined,
        size: 18,
        color: error ? const Color(0xFF96512F) : _muted,
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          message,
          style: TextStyle(
            fontSize: 12,
            height: 1.7,
            color: error ? const Color(0xFF96512F) : _muted,
          ),
        ),
      ),
    ],
  ),
);

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFFD7E6D8),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Color(0xFF406B52),
        fontSize: 11,
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}

class _IconTile extends StatelessWidget {
  const _IconTile(this.icon);
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFF0F4EC),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Icon(icon, color: _green, size: 23),
  );
}
