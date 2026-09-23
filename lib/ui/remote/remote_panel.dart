import 'package:flutter/material.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import '../../features/remote/remote_session_controller.dart';
import 'control_input_surface.dart';

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
    if (operation == SessionOperation.control) {
      return controller.sending ? '$name 的本机控制操作' : '控制 $name';
    }
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
    if (controller.operation == SessionOperation.control &&
        controller.phase == RemotePhase.active) {
      return controller.sending ? '本机控制画面已呈现；输入仍需单独核验。' : '已收到控制画面；输入仍需单独核验。';
    }
    return switch (controller.phase) {
      RemotePhase.idle => controller.error ?? '未开始。',
      RemotePhase.connecting =>
        controller.transportReady ? '媒体通道已建立，正在协商画面。' : '正在建立媒体通道并核验授权…',
      RemotePhase.waitingFirstFrame =>
        controller.sending ? '已开始采集本机屏幕，等待对端呈现。' : '通道已建立，等待对端首帧。',
      RemotePhase.active => controller.sending ? '对端已呈现本机画面，正在共享。' : '已收到对端画面。',
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
            SizedBox(
              height: controller.operation == SessionOperation.control
                  ? 360
                  : 280,
              child: controller.operation == SessionOperation.control
                  ? ControlInputSurface(
                      controller: controller,
                      child: controller.session!.view,
                    )
                  : controller.session!.view,
            ),
          ],
          if (controller.error != null && controller.cleanupFailed)
            Semantics(liveRegion: true, child: Text(controller.error!)),
          if (controller.supportsSourceSelection) ...[
            const SizedBox(height: 12),
            Text('本机分享来源：${controller.localSource?.name ?? '正在确认'}'),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: controller.canChangeSource
                    ? controller.loadSourceChoices
                    : null,
                child: Text(controller.sourceBusy ? '正在处理来源…' : '更换分享来源'),
              ),
            ),
            if (controller.sourceChoices.isNotEmpty)
              DropdownButtonFormField<String>(
                key: ValueKey(
                  '${controller.mediaRevision}:${controller.sourceChoices.map((s) => '${s.type.name}:${s.id}').join('|')}',
                ),
                isExpanded: true,
                initialValue: null,
                decoration: const InputDecoration(labelText: '选择本机显示器或窗口并分享'),
                items: [
                  for (final source in controller.sourceChoices)
                    DropdownMenuItem(
                      value: '${source.type.name}:${source.id}',
                      child: Text(
                        '${source.type == CaptureSourceType.screen ? '显示器' : '窗口'} · ${source.name}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: controller.canChangeSource
                    ? (value) {
                        final source = controller.sourceChoices
                            .where((s) => '${s.type.name}:${s.id}' == value)
                            .firstOrNull;
                        if (source != null) controller.changeSource(source);
                      }
                    : null,
              ),
            if (controller.sourceError case final String message)
              Semantics(liveRegion: true, child: Text(message)),
          ],
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
                if (controller.phase == RemotePhase.active &&
                    controller.operation != SessionOperation.control)
                  OutlinedButton(
                    onPressed: controller.sourceBusy ? null : controller.pause,
                    child: const Text('暂停'),
                  ),
                if (controller.phase == RemotePhase.paused &&
                    controller.operation != SessionOperation.control)
                  FilledButton(
                    onPressed: controller.sourceBusy ? null : controller.resume,
                    child: const Text('恢复'),
                  ),
              ],
              FilledButton(
                onPressed: controller.stop,
                child: Text(
                  controller.cleanupFailed
                      ? '重试释放'
                      : controller.operation == SessionOperation.control
                      ? '停止控制'
                      : '停止并释放',
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
