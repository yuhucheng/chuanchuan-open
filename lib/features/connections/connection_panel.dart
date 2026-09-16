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
            SelectableText(
              controller.code!,
              style: const TextStyle(fontSize: 32, letterSpacing: 6),
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
                child: Text(controller.accepting ? '重新生成短接码' : '开启接入'),
              ),
              if (controller.accepting)
                OutlinedButton(
                  onPressed: controller.stopAccepting,
                  child: const Text('关闭接入'),
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
  final values = await showDialog<(String, int, String)>(
    context: context,
    builder: (_) => _ConnectionDialog(device: device),
  );
  if (values != null) {
    await controller.connect(
      values.$1,
      values.$2,
      values.$3,
      expectedPeerKey: device?.publicKey,
    );
  }
}

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog({this.device});
  final NearbyDevice? device;
  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  late final host = TextEditingController(text: widget.device?.host ?? '');
  late final port = TextEditingController(
    text: widget.device?.port?.toString() ?? '',
  );
  final code = TextEditingController();
  @override
  void dispose() {
    host.dispose();
    port.dispose();
    code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.device == null ? '连接另一台设备' : '连接 ${widget.device!.name}',
    ),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: host,
            readOnly: widget.device != null,
            decoration: const InputDecoration(labelText: '对端地址'),
          ),
          TextField(
            controller: port,
            readOnly: widget.device != null,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: '端口'),
          ),
          TextField(
            controller: code,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: '对端显示的 6 位纯数字短接码'),
          ),
          const Text('验证通过即建立本次连接，对端无需再次点击确认。'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, (
          host.text.trim(),
          int.tryParse(port.text) ?? 0,
          code.text,
        )),
        child: const Text('连接'),
      ),
    ],
  );
}
