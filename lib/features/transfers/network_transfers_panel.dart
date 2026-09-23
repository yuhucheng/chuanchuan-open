import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';

import 'incoming_file_transfer.dart';
import 'network_transfers.dart';
import 'network_progress_view.dart';
import 'transfers_page.dart' show formatFileSize;

class NetworkTransfersPanel extends StatefulWidget {
  const NetworkTransfersPanel({
    super.key,
    required this.controller,
    this.initialPeerKey,
    this.peerName,
  });
  final NetworkTransfers controller;
  final String? initialPeerKey;
  final String Function(String)? peerName;
  @override
  State<NetworkTransfersPanel> createState() => _NetworkTransfersPanelState();
}

class _NetworkTransfersPanelState extends State<NetworkTransfersPanel> {
  TrustedConnection? _target;
  String? _error;
  @override
  void initState() {
    super.initState();
    _loadDestination();
  }

  @override
  void didUpdateWidget(covariant NetworkTransfersPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) _loadDestination();
  }

  void _loadDestination() {
    // ReceiveDirectories publishes a user-facing error and keeps the picker
    // available when the persisted capability cannot be reopened.
    unawaited(
      widget.controller.directories.load().then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {},
      ),
    );
  }

  String _name(String key) =>
      widget.peerName?.call(key) ?? '已验证设备 ${key.substring(0, 8)}';
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (_, _) {
      final c = widget.controller;
      final targets = c.targets;
      if (!targets.contains(_target)) {
        _target =
            targets
                .where((t) => t.peerKey == widget.initialPeerKey)
                .firstOrNull ??
            targets.firstOrNull;
      }
      final ready = c.queue.items.where((item) => item.canSend).toList();
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('文件传送', style: Theme.of(context).textTheme.titleMedium),
            NetworkProgressView(controller: c),
            const SizedBox(height: 12),
            if (targets.isEmpty)
              const Text('连接设备后，可以向它发送已准备的文件。')
            else
              DropdownButton<TrustedConnection>(
                isExpanded: true,
                value: _target,
                items: [
                  for (final target in targets)
                    DropdownMenuItem(
                      value: target,
                      child: Text(
                        _name(target.peerKey),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() {
                  _target = value;
                }),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _target == null || ready.isEmpty
                  ? null
                  : () {
                      try {
                        for (final item in ready) {
                          c.send(item, _target!);
                        }
                        setState(() {
                          _error = null;
                        });
                      } catch (_) {
                        setState(() {
                          _error = '暂时无法发送，请检查连接及队列容量。';
                        });
                      }
                    },
              icon: const Icon(Icons.send_outlined),
              label: Text('发送已准备的文件（${ready.length}）'),
            ),
            const SizedBox(height: 18),
            Text(
              '接收位置：${c.directories.current?.label ?? (c.directories.error == null ? '正在读取…' : '不可用，请重新选择')}',
            ),
            const Text('有效连接内自动接收，重名文件会保留两份。'),
            const Text('保存位置会保留；更改仅影响新接收的文件。'),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: c.directories.picking ? null : c.pickDirectory,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('更改保存位置'),
              ),
            ),
            for (final error in [?_error, ?c.error, ?c.directories.error])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (c.sends.isNotEmpty ||
                c.sendHistory.isNotEmpty ||
                c.pendingRetirements.isNotEmpty)
              Text('发送', style: Theme.of(context).textTheme.titleSmall),
            for (final sent in c.sendHistory) _historyRow(sent, sending: true),
            for (final pending in c.pendingRetirements)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('${pending.record.name} → ${_name(pending.peerKey)}'),
                    Text(switch (pending.record.outcome) {
                      FileRetirementOutcome.completed =>
                        '对方已保存：${pending.record.receipt!.actualName}',
                      FileRetirementOutcome.cancelled => '已取消',
                      FileRetirementOutcome.failed => '传送失败',
                    }),
                    if (pending.record.failure != null && pending.canRetry)
                      TextButton(
                        onPressed: () => c.retryPendingRetirement(pending),
                        child: const Text('重试收尾'),
                      ),
                  ],
                ),
              ),
            for (final sent in c.sends)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${sent.item.file.name} → ${_name(sent.connection.peerKey)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(switch (sent.phase) {
                      NetworkSendPhase.queued => '排队中',
                      NetworkSendPhase.verifying => '重新检查源文件',
                      NetworkSendPhase.sending => '正在发送',
                      NetworkSendPhase.paused =>
                        sent.canResume ? '已暂停' : '已暂停，等待对端确认',
                      NetworkSendPhase.resuming => '正在恢复',
                      NetworkSendPhase.completing => '等待接收方校验',
                      NetworkSendPhase.completed =>
                        '对方已保存：${sent.receipt!.actualName}',
                      NetworkSendPhase.cancelling => '正在停止',
                      NetworkSendPhase.cancelled => '已取消',
                      NetworkSendPhase.failed => '传送失败',
                    }),
                    Text(
                      '已确认 ${formatFileSize(sent.acknowledgedBytes)} / ${formatFileSize(sent.item.file.size)}',
                    ),
                    if (sent.cancellationPending) const Text('本机已停止，等待对端确认取消。'),
                    if (sent.retirementFailure != null &&
                        sent.connection.isConnected)
                      TextButton(
                        onPressed: () => c.retryRetirement(sent),
                        child: const Text('重试收尾'),
                      ),
                    if (sent.cancellationFailure != null &&
                        sent.connection.isConnected)
                      TextButton(
                        onPressed: () => c.retryCancelNotification(sent),
                        child: const Text('重试通知对端'),
                      ),
                    if (sent.canPause)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () async {
                            try {
                              await c.pause(sent);
                            } catch (_) {
                              if (mounted) {
                                setState(() {
                                  _error = '暂时无法暂停，请检查文件状态或取消传送。';
                                });
                              }
                            }
                          },
                          child: const Text('暂停发送'),
                        ),
                      ),
                    if (sent.canResume)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () {
                            try {
                              c.resume(sent);
                              setState(() {
                                _error = null;
                              });
                            } catch (_) {
                              setState(() {
                                _error = '暂时无法继续，请检查连接和文件状态。';
                              });
                            }
                          },
                          child: const Text('继续发送'),
                        ),
                      ),
                    if (sent.canCancel)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => c.cancel(sent),
                          child: const Text('取消发送'),
                        ),
                      ),
                    if (sent.cleanupFailure != null)
                      Text(
                        '文件访问清理失败，请重试。',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (sent.cleanupFailure != null)
                      TextButton(
                        onPressed: () => c.cancel(sent),
                        child: const Text('重试清理'),
                      ),
                    if (sent.error != null)
                      Text(
                        sent.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            if (c.received.isNotEmpty || c.receiveHistory.isNotEmpty)
              Text('接收', style: Theme.of(context).textTheme.titleSmall),
            for (final incoming in c.receiveHistory)
              _historyRow(incoming, sending: false),
            for (final incoming in c.received)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${incoming.entry.offer.name} ← ${_name(incoming.connection.peerKey)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      incoming.entry.task?.receipt != null
                          ? '已保存：${incoming.entry.task!.receipt!.name}'
                          : incoming.entry.failure != null
                          ? NetworkTransfers.messageFor(
                              FileProtocolFailure(incoming.entry.failure!),
                            )
                          : switch (incoming.entry.task?.phase) {
                              IncomingFilePhase.receiving => '接收中',
                              IncomingFilePhase.verifying => '正在校验',
                              IncomingFilePhase.paused => '已暂停',
                              IncomingFilePhase.resuming ||
                              IncomingFilePhase.awaitingResumeAccept => '正在恢复',
                              IncomingFilePhase.cancelled => '已取消',
                              IncomingFilePhase.stopping => '正在停止',
                              IncomingFilePhase.failed => '接收失败',
                              _ => incoming.entry.canCancel ? '准备接收' : '已取消',
                            },
                    ),
                    Text(
                      '已写入 ${formatFileSize(incoming.entry.task?.offset ?? 0)} / ${formatFileSize(incoming.entry.offer.size)}',
                    ),
                    if (incoming.entry.cancellationPending)
                      const Text('本机已停止，等待对端确认取消。'),
                    if (incoming.entry.notificationFailure != null &&
                        incoming.connection.isConnected)
                      TextButton(
                        onPressed: () => c.retryReceiveNotification(incoming),
                        child: const Text('重试通知对端'),
                      ),
                    if (incoming.entry.canCancel)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => c.cancelReceive(incoming),
                          child: const Text('取消接收'),
                        ),
                      ),
                    if (incoming.entry.cleanupFailure != null)
                      TextButton(
                        onPressed: () => c.retryReceiveCleanup(incoming),
                        child: const Text('重试清理'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );

  Widget _historyRow(NetworkFileHistory item, {required bool sending}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${item.file.name} ${sending ? '→' : '←'} ${_name(item.peerKey)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(NetworkTransfers.historyStatus(item.file, sending: sending)),
          ],
        ),
      );
}
