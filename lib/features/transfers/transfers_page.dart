import 'package:flutter/material.dart';

import 'transfer_queue.dart';
import 'network_transfers.dart';
import 'network_transfers_panel.dart';
import 'native_file_drop.dart';

class TransfersPage extends StatelessWidget {
  const TransfersPage({
    super.key,
    required this.queue,
    this.network,
    this.initialPeerKey,
    this.peerName,
  });
  final TransferQueue queue;
  final NetworkTransfers? network;
  final String? initialPeerKey;
  final String Function(String)? peerName;

  @override
  Widget build(BuildContext context) => NativeFileDropRegion(
    onDrop: (files) => queue.admitDroppedFiles(files) != null,
    child: AnimatedBuilder(
      animation: Listenable.merge([queue, ?network]),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '把文件，准备好',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
            ),
          ),
          SizedBox(height: 10),
          Text(
            '选好文件，检查内容，等待与你的另一台设备连接。',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          SizedBox(height: 26),
          Container(
            padding: EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: 12,
                  spacing: 16,
                  children: [
                    Text(
                      '文件队列 · ${queue.items.length}',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: queue.items.isEmpty && !queue.selecting
                              ? null
                              : queue.clear,
                          child: Text('清空队列'),
                        ),
                        SizedBox(width: 12),
                        FilledButton.icon(
                          onPressed:
                              queue.selecting ||
                                  queue.items.length >= TransferQueue.maxFiles
                              ? null
                              : queue.selectFiles,
                          icon: Icon(Icons.add_rounded, size: 20),
                          label: Text(queue.selecting ? '正在选择' : '选择文件'),
                        ),
                      ],
                    ),
                  ],
                ),
                SizedBox(height: 22),
                Divider(
                  height: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                if (queue.items.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 52),
                    child: Column(
                      children: [
                        Icon(
                          Icons.file_copy_outlined,
                          size: 44,
                          color: Color(0xFF83A392),
                        ),
                        SizedBox(height: 16),
                        Text(
                          '先加入想分享的文件',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          '支持一次选择多个文件；准备过程不会修改原文件。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  ...queue.items.map(
                    (item) => _FileRow(
                      key: ValueKey(item.file.token),
                      item: item,
                      queue: queue,
                    ),
                  ),
                if (queue.error != null)
                  Padding(
                    padding: EdgeInsets.only(top: 14),
                    child: Text(
                      queue.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(height: 20),
          if (network case final controller?) ...[
            NetworkTransfersPanel(
              controller: controller,
              initialPeerKey: initialPeerKey,
              peerName: peerName,
            ),
            const SizedBox(height: 20),
          ],
          Container(
            padding: EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.link_off_rounded,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '本地检查完成不表示送达；尚未发送的文件需要选择已连接设备。退出会清空本次队列。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      height: 1.7,
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
}

class _FileRow extends StatelessWidget {
  const _FileRow({super.key, required this.item, required this.queue});
  final TransferItem item;
  final TransferQueue queue;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.insert_drive_file_outlined,
                color: Theme.of(context).colorScheme.primary,
                size: 24,
              ),
            ),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 5),
                  Text(
                    '${formatFileSize(item.file.size)} · ${switch (item.state) {
                      PreparationState.queued => '等待准备',
                      PreparationState.preparing => '正在检查文件',
                      PreparationState.ready => item.canSend ? '已检查 · 等待连接' : '已用于传送 · 结果见下方',
                      PreparationState.cancelled => '已取消准备',
                      PreparationState.failed => '准备失败',
                    }}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (item.canCancel)
              TextButton(
                onPressed: () => queue.cancel(item),
                child: Text('取消准备'),
              ),
            IconButton(
              tooltip: '移除 ${item.file.name}',
              onPressed: () => queue.remove(item),
              icon: Icon(Icons.close_rounded, size: 19),
            ),
          ],
        ),
        if (item.state == PreparationState.preparing) ...[
          SizedBox(height: 14),
          LinearProgressIndicator(
            value: item.file.size == 0 ? 0 : item.checkedBytes / item.file.size,
            minHeight: 4,
            borderRadius: BorderRadius.circular(4),
          ),
          SizedBox(height: 6),
          Text(
            '已检查 ${formatFileSize(item.checkedBytes)} / ${formatFileSize(item.file.size)}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
        ],
        if (item.sha256 != null)
          Material(
            type: MaterialType.transparency,
            child: ExpansionTile(
              tilePadding: EdgeInsets.only(left: 62),
              dense: true,
              title: Text('查看文件校验值', style: TextStyle(fontSize: 12)),
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(62, 0, 12, 12),
                  child: SelectableText(
                    'SHA-256\n${item.sha256}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (item.error != null)
          Padding(
            padding: EdgeInsets.only(top: 10, left: 62),
            child: Text(
              item.error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
        SizedBox(height: 18),
        Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
      ],
    ),
  );
}

String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
}
