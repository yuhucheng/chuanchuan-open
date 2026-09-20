import 'package:flutter/material.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import '../../features/remote/remote_session_controller.dart';

/// Inline surface for the single remote picture.
///
/// It stays mounted for as long as the session is live: on the receiving side
/// the view itself is what confirms presentation, so hiding it would stall the
/// peer's first-frame receipt. The panel therefore lives in the main shell, not
/// in a dismissible dialog.
class RemotePicturePanel extends StatelessWidget {
  const RemotePicturePanel({super.key, required this.controller});
  final RemoteSessionController controller;

  String _title() {
    final name = controller.peerLabel ?? '已连接设备';
    final operation = controller.operation;
    if (controller.sending) {
      return operation == SessionOperation.cast
          ? '正在投屏到 $name'
          : '$name 正在观看本机屏幕';
    }
    return operation == SessionOperation.cast
        ? '$name 已投屏到本机'
        : '正在观看 $name 的屏幕';
  }

  /// Each real state keeps its own wording; a channel that is up but has not
  /// presented a frame is never described as running.
  String _status() {
    if (controller.cleanupFailed) return '资源释放失败，尚未完全停止。';
    return switch (controller.phase) {
      RemotePhase.idle => controller.error ?? '未开始。',
      RemotePhase.connecting => controller.transportReady
          ? '媒体通道已建立，正在协商画面。'
          : '正在建立媒体通道并核验授权…',
      RemotePhase.waitingFirstFrame => controller.sending
          ? '已开始采集本机屏幕，等待对端呈现。'
          : '通道已建立，等待对端首帧。',
      RemotePhase.active => controller.sending
          ? '对端已呈现本机画面，正在共享。'
          : '已收到对端画面。',
      RemotePhase.paused => '已暂停；当前画面不是实时画面。',
      RemotePhase.failed => controller.error ?? '远端画面失败。',
    };
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_title(), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Semantics(liveRegion: true, child: Text(_status())),
          const Text('授权与画面分开：通道建立不代表对端已呈现，撤销或断开会立即释放。'),
          if (controller.receiving) ...[
            const SizedBox(height: 12),
            SizedBox(height: 280, child: controller.session!.view),
          ],
          if (controller.error != null && controller.cleanupFailed)
            Semantics(liveRegion: true, child: Text(controller.error!)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              if (controller.busy)
                TextButton(
                  onPressed: controller.cancel,
                  child: const Text('取消'),
                )
              else ...[
                if (controller.phase == RemotePhase.active)
                  OutlinedButton(
                    onPressed: controller.pause,
                    child: const Text('暂停'),
                  ),
                if (controller.phase == RemotePhase.paused)
                  FilledButton(
                    onPressed: controller.resume,
                    child: const Text('恢复'),
                  ),
              ],
              FilledButton(
                onPressed: controller.stop,
                child: Text(controller.cleanupFailed ? '重试释放' : '停止并释放'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
