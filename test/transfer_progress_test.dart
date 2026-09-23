import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/transfers/transfer_progress.dart';

void main() {
  test('aggregate byte totals do not overflow when multiple legal files are combined', () {
    final progress = TransferProgress.fromFiles([
      TransferProgressFile(
        size: 9223372036854775807,
        transferred: 9223372036854775807,
        state: TransferProgressState.completed,
      ),
      TransferProgressFile(
        size: 9223372036854775807,
        transferred: 0,
        state: TransferProgressState.active,
      ),
    ]);
    expect(progress.totalBytes.toString(), '18446744073709551614');
    expect(progress.transferredBytes.toString(), '9223372036854775807');
    expect(progress.progressValue, 0.5);
    expect(progress.completedFiles, 1);
    expect(progress.isComplete, isFalse);
  });

  test('failure and cancellation remain visible even if every byte was acknowledged', () {
    final progress = TransferProgress.fromFiles([
      TransferProgressFile(
        size: 4,
        transferred: 4,
        state: TransferProgressState.failed,
      ),
      TransferProgressFile(
        size: 0,
        transferred: 0,
        state: TransferProgressState.cancelled,
      ),
    ]);
    expect(progress.isComplete, isFalse);
    expect(progress.failedFiles, 1);
    expect(progress.cancelledFiles, 1);
    expect(progress.activeFiles, 0);
    expect(progress.completedFiles, 0);
  });
}
