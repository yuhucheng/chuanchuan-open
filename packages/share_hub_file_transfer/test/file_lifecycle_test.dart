import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

const transfer = '0123456789abcdef0123456789abcdef';
const otherTransfer = 'abcdef0123456789abcdef0123456789';
final invalid = throwsA(isA<FileProtocolFailure>());

FileOperationId operation(int ordinal, [int attempt = 1]) => FileOperationId(
  sender: GrantRole.initiator,
  ordinal: ordinal,
  attempt: attempt,
);

void main() {
  test('canonical operation IDs bind direction ordinal and attempt', () {
    for (final sender in GrantRole.values) {
      final id = FileOperationId(
        sender: sender,
        ordinal: 9223372036854775807,
        attempt: 9223372036854775807,
      );
      final prefix = sender == GrantRole.initiator ? 'i' : 'r';
      expect(
        id.encoded,
        'file-v2-$prefix-9223372036854775807-9223372036854775807',
      );
      expect(FileOperationId.parse(id.encoded), id);
      expect(FileOperationId.parse(id.encoded).hashCode, id.hashCode);
      expect(id.encoded.length, lessThanOrEqualTo(128));
    }
    expect(operation(1), isNot(operation(1, 2)));
    expect(operation(1), isNot(operation(2)));
  });

  test('operation parser rejects aliases unknown versions and overflow', () {
    for (final encoded in [
      '',
      'file-v1-i-1-1',
      'file-v2-I-1-1',
      'file-v2-x-1-1',
      'file-v2-i-01-1',
      'file-v2-i-1-01',
      'file-v2-i-0-1',
      'file-v2-i-1-0',
      'file-v2-i--1-1',
      'file-v2-i-1-1-tail',
      'file-v2-i-9223372036854775808-1',
      'file-v2-i-1-9223372036854775808',
      'file-v2-i-1-1\n',
      'file-v2-i-${'1' * 200}-1',
    ]) {
      expect(() => FileOperationId.parse(encoded), invalid, reason: encoded);
    }
    expect(() => operation(0), invalid);
    expect(() => operation(-1), invalid);
    expect(() => operation(1, 0), invalid);
  });

  test('ten thousand retired files retain only a fixed watermark', () {
    final ledger = FileTransferLedger<Object>(sender: GrantRole.initiator);
    for (var ordinal = 1; ordinal <= 10000; ordinal++) {
      final slot = ledger.admit(operation(ordinal), transfer, Object());
      expect(ledger.retainedCount, 1);
      ledger.retire(slot);
      expect(ledger.retainedCount, 0);
    }
    expect(ledger.highestOrdinal, 10000);
    for (final ordinal in [1, 64, 512, 9999, 10000]) {
      expect(
        () => ledger.admit(operation(ordinal), transfer, Object()),
        invalid,
      );
    }
    expect(ledger.find(1, transfer), isNull);
    expect(
      ledger.admit(operation(10001), transfer, Object()).operation.ordinal,
      10001,
    );
  });

  test('a retained lower ordinal resumes after newer files retire', () {
    final ledger = FileTransferLedger<Object>(sender: GrantRole.initiator);
    final owner = Object();
    final first = ledger.admit(operation(1), transfer, owner);
    for (var ordinal = 2; ordinal <= 1000; ordinal++) {
      ledger.retire(ledger.admit(operation(ordinal), otherTransfer, Object()));
    }
    final ticket = ledger.observeAttempt(operation(1, 2), transfer);
    expect(ledger.find(1, transfer)!.operation, first.operation);
    final resumed = ledger.bindAttempt(ticket);
    expect(resumed.operation, operation(1, 2));
    expect(resumed.value, same(owner));
    expect(ledger.retainedCount, 1);
    expect(ledger.highestOrdinal, 1000);
  });

  test(
    'full capacity burns rejected ordinal without evicting existing owners',
    () {
      final ledger = FileTransferLedger<Object>(
        sender: GrantRole.initiator,
        capacity: 1,
      );
      final retained = ledger.admit(operation(1), transfer, Object());
      expect(
        () => ledger.admit(operation(2), otherTransfer, Object()),
        throwsA(
          isA<FileProtocolFailure>().having(
            (e) => e.code,
            'code',
            'resource_limit',
          ),
        ),
      );
      expect(ledger.highestOrdinal, 2);
      expect(ledger.find(1, transfer), same(retained));
      ledger.retire(retained);
      expect(
        () => ledger.admit(operation(2), otherTransfer, Object()),
        invalid,
      );
      expect(
        ledger.admit(operation(3), otherTransfer, Object()).operation.ordinal,
        3,
      );
    },
  );

  test('wrong role or malformed identity cannot consume a new ordinal', () {
    final ledger = FileTransferLedger<Object>(sender: GrantRole.initiator);
    expect(
      () => ledger.admit(
        FileOperationId(sender: GrantRole.receiver, ordinal: 100, attempt: 1),
        transfer,
        Object(),
      ),
      invalid,
    );
    expect(() => ledger.admit(operation(100), 'invalid', Object()), invalid);
    expect(ledger.highestOrdinal, 0);
    expect(ledger.retainedCount, 0);
    ledger.admit(operation(1), transfer, Object());
  });

  test('duplicate ordinal with a different random ID never replaces owner', () {
    final ledger = FileTransferLedger<Object>(sender: GrantRole.initiator);
    final current = ledger.admit(operation(1), transfer, Object());
    expect(() => ledger.admit(operation(1), otherTransfer, Object()), invalid);
    expect(() => ledger.find(1, otherTransfer), invalid);
    expect(
      () => ledger.observeAttempt(operation(1, 2), otherTransfer),
      invalid,
    );
    expect(ledger.find(1, transfer), same(current));
    expect(current.maxObservedAttempt, 1);
  });

  test(
    'a refused newer attempt is burned without replacing the current resolver',
    () {
      final ledger = FileTransferLedger<Object>(sender: GrantRole.initiator);
      final original = ledger.admit(operation(1), transfer, Object());
      ledger.observeAttempt(operation(1, 8), transfer); // Caller rejects busy.
      final current = ledger.find(1, transfer)!;
      expect(current.operation, original.operation);
      expect(current.maxObservedAttempt, 8);
      for (final attempt in [1, 2, 7, 8]) {
        expect(
          () => ledger.observeAttempt(operation(1, attempt), transfer),
          invalid,
        );
      }
      final resumed = ledger.bindAttempt(
        ledger.observeAttempt(operation(1, 9), transfer),
      );
      expect(resumed.operation, operation(1, 9));
      expect(resumed.maxObservedAttempt, 9);
    },
  );

  test(
    'stale bind and retirement callbacks cannot affect a newer observation',
    () {
      final ledger = FileTransferLedger<Object>(sender: GrantRole.initiator);
      final original = ledger.admit(operation(1), transfer, Object());
      final oldTicket = ledger.observeAttempt(operation(1, 2), transfer);
      final observed = ledger.find(1, transfer)!;
      final newTicket = ledger.observeAttempt(operation(1, 3), transfer);
      expect(() => ledger.bindAttempt(oldTicket), invalid);
      expect(() => ledger.retire(original), invalid);
      expect(() => ledger.retire(observed), invalid);
      final current = ledger.bindAttempt(newTicket);
      expect(() => ledger.bindAttempt(newTicket), invalid);
      ledger.retire(current);
      expect(() => ledger.bindAttempt(newTicket), invalid);
      expect(() => ledger.retire(current), invalid);
      expect(() => ledger.observeAttempt(operation(1, 4), transfer), invalid);
    },
  );

  test('separate grant ledgers cannot exchange slots or attempt tickets', () {
    final first = FileTransferLedger<Object>(sender: GrantRole.initiator);
    final second = FileTransferLedger<Object>(sender: GrantRole.initiator);
    final owner = Object();
    final foreign = first.admit(operation(1), transfer, owner);
    final local = second.admit(operation(1), transfer, owner);
    final ticket = first.observeAttempt(operation(1, 2), transfer);
    expect(() => second.retire(foreign), invalid);
    expect(() => second.bindAttempt(ticket), invalid);
    expect(second.find(1, transfer), same(local));
    expect(second.find(1, transfer)!.maxObservedAttempt, 1);
  });

  test(
    'opposite senders may independently use the same ordinal and random ID',
    () {
      final first = FileTransferLedger<Object>(sender: GrantRole.initiator);
      final second = FileTransferLedger<Object>(sender: GrantRole.receiver);
      final a = first.admit(operation(1), transfer, Object());
      final b = second.admit(
        FileOperationId(sender: GrantRole.receiver, ordinal: 1, attempt: 1),
        transfer,
        Object(),
      );
      expect(() => first.retire(b), invalid);
      first.retire(a);
      expect(second.retainedCount, 1);
      expect(second.find(1, transfer), same(b));
    },
  );

  test('maximum ordinal and attempt never wrap or reopen after retirement', () {
    final ledger = FileTransferLedger<Object>(sender: GrantRole.initiator);
    final max = FileLimits.maxOffset;
    ledger.admit(operation(max), transfer, Object());
    final current = ledger.bindAttempt(
      ledger.observeAttempt(operation(max, max), transfer),
    );
    expect(() => ledger.observeAttempt(operation(max, max), transfer), invalid);
    expect(() => operation(max + 1), invalid);
    expect(() => operation(max, max + 1), invalid);
    ledger.retire(current);
    expect(() => ledger.admit(operation(1), transfer, Object()), invalid);
    expect(ledger.highestOrdinal, max);
  });

  test('capacity and snapshots cannot bypass the bounded ledger', () {
    expect(
      () =>
          FileTransferLedger<Object>(sender: GrantRole.initiator, capacity: 0),
      throwsRangeError,
    );
    expect(
      () =>
          FileTransferLedger<Object>(sender: GrantRole.initiator, capacity: 65),
      throwsRangeError,
    );
    final ledger = FileTransferLedger<Object>(sender: GrantRole.initiator);
    for (var ordinal = 1; ordinal <= 64; ordinal++) {
      ledger.admit(operation(ordinal), transfer, Object());
    }
    final snapshot = ledger.slots;
    expect(() => snapshot.clear(), throwsUnsupportedError);
    ledger.retire(snapshot.first);
    expect(snapshot.length, 64);
    expect(ledger.retainedCount, 63);
    expect(() => ledger.find(0, transfer), invalid);
    expect(() => ledger.find(1, 'bad'), invalid);
  });
}
