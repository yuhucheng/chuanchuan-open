import 'package:flutter/material.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import '../../features/remote/remote_session_controller.dart';

/// Inline surface for the single remote picture.
///
/// It stays mounted for as long as the session is live: on the receiving side
/// the view itself is what confirms presentation, so hiding it would stall the
/// peer's first-frame receipt. The panel therefore lives in the main shell, not
/// in a dismissible dialog.
class RemotePicturePanel extends StatefulWidget {
  const RemotePicturePanel({super.key, required this.controller});
  final RemoteSessionController controller;

  @override
  State<RemotePicturePanel> createState() => _RemotePicturePanelState();
}

class _RemotePicturePanelState extends State<RemotePicturePanel>
    with WidgetsBindingObserver {
  RemoteSessionController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      controller.clearFrameProgress();
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String _frameStatus() {
    final sample = controller.frameProgress;
    final stage = controller.sending ? '本机采集' : '本机接收';
    if (sample?.active == null) return '$stage帧状态：未测。';
    if (sample!.active == false) return '$stage已停止产帧。';
    if (sample.sequence == 0) return '$stage尚未观察到图像。';
    // A short-age observation is not an end-to-end success claim. Older samples
    // remain non-realtime/unknown until fresh evidence or a recovery decision.
    const recent = Duration(seconds: 5);
    if (sample.stage == MediaFrameStage.capture) {
      if (sample.sourceUnchanged == true) {
        return sample.outputAge! <= recent
            ? '本机采集最近报告画面未变化；对端持续呈现尚待确认。'
            : '本机画面曾未变化，当前采集状态待确认。';
      }
      return sample.age! <= recent
          ? '本机采集最近有新帧；对端持续呈现尚待确认。'
          : '本机采集暂未观察到新帧，当前画面非实时状态待确认。';
    }
    if (sample.age! > recent) return '接收端暂未解码新帧；画面是否变化待确认，不标为实时。';
    if (sample.consumedSequence != sample.sequence) return '接收端最近已解码，尚未消费最新画面。';
    return '接收端最近已解码并消费画面；持续状态仍由后续帧确认。';
  }

  String _title() {
    final name = controller.peerLabel ?? '已连接设备';
    if (controller.phase == RemotePhase.recovering) return '正在恢复与 $name 的画面连接';
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

  String _peerFrameStatus() {
    final sample = controller.peerFrameProgress;
    if (sample?.active == null) return '对端帧状态：未测。';
    if (sample!.active == false) return '对端报告画面已停止。';
    if (sample.sequence == 0) return '对端尚未报告图像。';
    if (sample.stage == MediaFrameStage.capture) {
      if (sample.sourceUnchanged == true) {
        return sample.outputAge! <= const Duration(seconds: 5)
            ? '对端最近报告来源未变化；持续状态仍待后续证据。'
            : '对端来源曾未变化，当前状态待确认。';
      }
      return sample.age! <= const Duration(seconds: 5)
          ? '对端最近报告采集到新画面。'
          : '对端采集证据已变旧，当前状态待确认。';
    }
    if (sample.age! > const Duration(seconds: 5)) return '对端暂未解码新帧，当前画面不标为实时。';
    return sample.sequence == sample.consumedSequence
        ? '对端最近报告已解码并消费画面。'
        : '对端最近已解码，最新画面尚未消费。';
  }

  /// Each real state keeps its own wording; a channel that is up but has not
  /// presented a frame is never described as running.
  String _status() {
    if (controller.cleanupFailed) return '资源释放失败，尚未完全停止。';
    return switch (controller.phase) {
      RemotePhase.idle => controller.error ?? '未开始。',
      RemotePhase.connecting =>
        controller.transportReady ? '媒体通道已建立，正在协商画面。' : '正在建立媒体通道并核验授权…',
      RemotePhase.recovering => '连接中断，旧画面已停止；正在核验原来源和授权，可随时停止恢复。',
      RemotePhase.waitingFirstFrame =>
        controller.sending ? '已开始采集本机屏幕，等待对端呈现。' : '通道已建立，等待对端首帧。',
      RemotePhase.active => controller.sending ? '对端已呈现过本机画面。' : '已收到对端画面。',
      RemotePhase.paused => '已暂停；当前画面不是实时画面。',
      RemotePhase.failed => controller.error ?? '远端画面失败。',
    };
  }

  String _statistics() {
    final path = switch (controller.transportPath) {
      MediaTransportPath.direct => '直连',
      MediaTransportPath.relay => '中继',
      null => '未测',
    };
    final rtt = controller.roundTripTime;
    final delay = rtt == null
        ? '未测'
        : '${(rtt.inMicroseconds / 1000).toStringAsFixed(1)} ms';
    final rate = controller.bitsPerSecond;
    final throughput = rate == null
        ? '未测'
        : '${(rate / 1000).toStringAsFixed(1)} kbit/s';
    final direction = controller.sending ? '发送' : '接收';
    return '媒体路径：$path · 往返时延：$delay · $direction速率：$throughput';
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
          Text(_frameStatus(), key: const ValueKey('media-frame-status')),
          Text(_peerFrameStatus(), key: const ValueKey('peer-frame-status')),
          Text(_statistics()),
          Text(
            controller.frameWidth == null
                ? '画面尺寸：未测'
                : '画面尺寸：${controller.frameWidth} × ${controller.frameHeight}',
          ),
          const Text('授权与画面分开：通道建立不代表对端已呈现，撤销或断开会立即释放。'),
          if (controller.receiving) ...[
            const SizedBox(height: 12),
            SizedBox(height: 280, child: controller.session!.view),
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
                if (controller.phase == RemotePhase.active)
                  OutlinedButton(
                    onPressed: controller.sourceBusy ? null : controller.pause,
                    child: const Text('暂停'),
                  ),
                if (controller.phase == RemotePhase.paused)
                  FilledButton(
                    onPressed: controller.sourceBusy ? null : controller.resume,
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
