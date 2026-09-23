enum TransferProgressState { active, completed, cancelled, failed }

/// A measurement of one network transfer. Local preparation is never included.
final class TransferProgressFile {
  TransferProgressFile({
    required this.size,
    required this.transferred,
    required this.state,
  }) {
    if (size < 0 || transferred < 0 || transferred > size) {
      throw RangeError('Invalid transfer progress.');
    }
  }
  final int size, transferred;
  final TransferProgressState state;
}

/// Separate byte and file completion totals: ACKs are not commit receipts, and
/// zero-byte files still need a receipt. BigInt avoids summing 64 legal int64
/// file lengths into an overflowing machine integer.
final class TransferProgress {
  TransferProgress._(
    this.totalFiles,
    this.completedFiles,
    this.cancelledFiles,
    this.failedFiles,
    this.totalBytes,
    this.transferredBytes,
  );

  factory TransferProgress.fromFiles(Iterable<TransferProgressFile> files) {
    var total = 0, completed = 0, cancelled = 0, failed = 0;
    var bytes = BigInt.zero, transferred = BigInt.zero;
    for (final file in files) {
      total++;
      bytes += BigInt.from(file.size);
      transferred += BigInt.from(file.transferred);
      switch (file.state) {
        case TransferProgressState.completed:
          completed++;
        case TransferProgressState.cancelled:
          cancelled++;
        case TransferProgressState.failed:
          failed++;
        case TransferProgressState.active:
          break;
      }
    }
    return TransferProgress._(
      total,
      completed,
      cancelled,
      failed,
      bytes,
      transferred,
    );
  }

  final int totalFiles, completedFiles, cancelledFiles, failedFiles;
  final BigInt totalBytes, transferredBytes;
  int get activeFiles =>
      totalFiles - completedFiles - cancelledFiles - failedFiles;
  bool get isComplete => totalFiles > 0 && completedFiles == totalFiles;
  double? get progressValue {
    if (isComplete) return 1;
    if (activeFiles > 0 &&
        (totalBytes == BigInt.zero || transferredBytes == totalBytes)) {
      return null;
    }
    if (totalBytes == BigInt.zero) return 0;
    return transferredBytes.toDouble() / totalBytes.toDouble();
  }
}
