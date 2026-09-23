import 'package:flutter/material.dart';

import 'network_transfers.dart';
import 'transfer_progress.dart';

/// Uses the same measurements in the file panel and each authenticated peer's
/// node. The receive direction reports local writes, not remote confirmation.
class NetworkProgressView extends StatelessWidget {
  const NetworkProgressView({
    super.key,
    required this.controller,
    this.peerKey,
    this.compact = false,
  });
  final NetworkTransfers controller;
  final String? peerKey;
  final bool compact;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final sending = controller.sendProgress(peerKey: peerKey);
      final receiving = controller.receiveProgress(peerKey: peerKey);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sending.totalFiles > 0)
            _direction(context, sending, '发送', '对端已确认'),
          if (receiving.totalFiles > 0)
            _direction(context, receiving, '接收', '本机已写入'),
        ],
      );
    },
  );

  Widget _direction(
    BuildContext context,
    TransferProgress progress,
    String direction,
    String measurement,
  ) {
    final status =
        '$direction · 已完成 ${progress.completedFiles}/${progress.totalFiles}'
        '${progress.activeFiles > 0 ? ' · 未完成 ${progress.activeFiles}' : ''}'
        '${progress.failedFiles > 0 ? ' · 失败 ${progress.failedFiles}' : ''}'
        '${progress.cancelledFiles > 0 ? ' · 已取消 ${progress.cancelledFiles}' : ''}';
    final bytes =
        '$measurement ${_bytes(progress.transferredBytes)} / ${_bytes(progress.totalBytes)}';
    final waiting =
        progress.activeFiles > 0 &&
        progress.transferredBytes == progress.totalBytes;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 4 : 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            status,
            textAlign: compact ? TextAlign.center : TextAlign.start,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: progress.progressValue,
            semanticsLabel: '$status，$bytes${waiting ? '，等待完成确认' : ''}',
          ),
          const SizedBox(height: 4),
          Text(
            '$bytes${waiting ? ' · 等待完成确认' : ''}',
            textAlign: compact ? TextAlign.center : TextAlign.start,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  static String _bytes(BigInt value) {
    if (value < BigInt.from(1024)) return '$value B';
    final units = ['KiB', 'MiB', 'GiB', 'TiB', 'PiB', 'EiB'];
    var amount = value.toDouble() / 1024;
    var index = 0;
    while (amount >= 1024 && index < units.length - 1) {
      amount /= 1024;
      index++;
    }
    return '${amount.toStringAsFixed(1)} ${units[index]}';
  }
}
