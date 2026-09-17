import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/client_platform.dart';
import 'connection_controller.dart';

class ConnectionPanel extends StatelessWidget {
  const ConnectionPanel({super.key, required this.controller});
  final ConnectionController controller;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '短接码连接',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text('让另一台设备输入本机短接码。连接成功后有效 8 小时，可随时断开。'),
          const SizedBox(height: 16),
          if (controller.code != null) ...[
            Semantics(
              label: '短接码 ${controller.code!.split('').join(' ')}',
              child: ExcludeSemantics(
                child: SelectableText(
                  controller.code!,
                  style: const TextStyle(fontSize: 32, letterSpacing: 6),
                ),
              ),
            ),
            const Text('5 分钟内有效，仅可成功使用一次。'),
            if (controller.address != null)
              SelectableText('连接地址：${controller.address}'),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: controller.busy ? null : controller.open,
                child: Text(controller.accepting ? '重新生成短接码' : '允许连接'),
              ),
              if (controller.accepting)
                OutlinedButton(
                  onPressed: controller.disconnectAll,
                  child: const Text('关闭允许连接并断开全部'),
                ),
              OutlinedButton(
                onPressed: controller.busy
                    ? null
                    : () => showConnectionDialog(context, controller),
                child: const Text('输入地址和短接码'),
              ),
              if (controller.busy)
                TextButton(
                  onPressed: controller.cancel,
                  child: const Text('取消连接'),
                ),
            ],
          ),
          if (controller.message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(controller.message!),
            ),
          for (final connection in controller.sessions)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('已验证 · 本地直连'),
              subtitle: Text(
                '设备 ${connection.peerId.substring(0, 16)}\n投屏、控制和文件权限尚未开放。',
              ),
              trailing: TextButton(
                onPressed: connection.close,
                child: const Text('断开并撤销'),
              ),
            ),
        ],
      ),
    ),
  );
}

Future<void> showConnectionDialog(
  BuildContext context,
  ConnectionController controller, {
  NearbyDevice? device,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _ConnectionDialog(device: device, controller: controller),
  );
}

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog({this.device, required this.controller});
  final NearbyDevice? device;
  final ConnectionController controller;
  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  late final host = TextEditingController(text: widget.device?.host ?? '');
  late final port = TextEditingController(
    text: widget.device?.port?.toString() ?? '',
  );
  final code = TextEditingController();
  bool submitting = false;
  bool attempted = false;
  String? error;
  @override
  void dispose() {
    if (submitting) widget.controller.cancel();
    host.dispose();
    port.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final number = int.tryParse(port.text);
    if (!RegExp(r'^\d{6}$').hasMatch(code.text) ||
        host.text.trim().isEmpty ||
        number == null ||
        number < 1 ||
        number > 65535) {
      setState(() => error = '请输入有效地址、端口和 6 位纯数字短接码。');
      return;
    }
    if (widget.controller.busy || submitting) return;
    setState(() {
      submitting = attempted = true;
      error = null;
    });
    await widget.controller.connect(
      host.text.trim(),
      number,
      code.text,
      expectedPeerKey: widget.device?.publicKey,
    );
    if (!mounted) return;
    setState(() => submitting = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.device == null ? '连接另一台设备' : '连接 ${widget.device!.name}',
    ),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.device == null) ...[
              TextField(
                controller: host,
                enabled: !submitting,
                decoration: const InputDecoration(labelText: '对端地址'),
              ),
              TextField(
                controller: port,
                enabled: !submitting,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: '端口'),
              ),
            ],
            TextField(
              controller: code,
              enabled: !submitting,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onSubmitted: (_) => submit(),
              decoration: const InputDecoration(labelText: '6 位纯数字短接码'),
            ),
            const Text('验证后建立 8 小时连接。当前版本观看尚未开放，不会开始远端采集。'),
            if (submitting) const Text('正在验证，可随时取消'),
            if (error != null) Semantics(liveRegion: true, child: Text(error!)),
            if (attempted && widget.controller.message != null)
              Semantics(
                liveRegion: true,
                child: Text(widget.controller.message!),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: submitting ? null : submit,
        child: const Text('连接'),
      ),
    ],
  );
}
