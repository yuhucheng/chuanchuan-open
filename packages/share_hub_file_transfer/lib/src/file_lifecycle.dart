part of '../share_hub_file_transfer.dart';

/// Canonical data-operation identity for file protocol v2 lifecycle routing.
/// Parsing this value grants no authority; it must match the authenticated
/// producer, metadata and the original endpoint before entering a ledger.
final class FileOperationId {
  FileOperationId({
    required this.sender,
    required this.ordinal,
    required this.attempt,
  }) {
    _positiveOrdinal(ordinal);
    _positiveOrdinal(attempt);
  }

  final GrantRole sender;
  final int ordinal, attempt;

  String get encoded =>
      'file-v2-${sender == GrantRole.initiator ? 'i' : 'r'}-$ordinal-$attempt';

  static FileOperationId parse(String encoded) {
    if (encoded.length > 128) _fail('invalid_id');
    final parts = encoded.split('-');
    if (parts.length != 5 || parts[0] != 'file' || parts[1] != 'v2') {
      _fail('invalid_id');
    }
    final sender = switch (parts[2]) {
      'i' => GrantRole.initiator,
      'r' => GrantRole.receiver,
      _ => _fail('invalid_id'),
    };
    final result = FileOperationId(
      sender: sender,
      ordinal: _decimal(parts[3]),
      attempt: _decimal(parts[4]),
    );
    if (result.encoded != encoded) _fail('invalid_id');
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is FileOperationId &&
      sender == other.sender &&
      ordinal == other.ordinal &&
      attempt == other.attempt;

  @override
  int get hashCode => Object.hash(sender, ordinal, attempt);
}

void _positiveOrdinal(int value) {
  _range(value);
  if (value == 0) _fail('invalid_range');
}

void _lifecycleTransferId(String value) {
  if (value.length != 32) _fail('invalid_id');
  _id(value);
}

/// Immutable owner snapshot. An observation or bind creates a fresh snapshot,
/// so an asynchronous cleanup holding an older one cannot retire the new state.
final class FileTransferSlot<T> {
  FileTransferSlot._(
    this.operation,
    this.transferId,
    this.value,
    this.maxObservedAttempt,
  );

  final FileOperationId operation;
  final String transferId;
  final T value;
  final int maxObservedAttempt;
}

/// Single-use reservation to replace a resolver only after rebind succeeds.
/// Discarding a ticket (for example on busy) still consumes its attempt number.
final class FileAttemptTicket<T> {
  FileAttemptTicket._(this.operation, this._snapshot);
  final FileOperationId operation;
  final FileTransferSlot<T> _snapshot;
}

/// Bounded, process-local replay bookkeeping for one sealed endpoint/producer.
/// The caller must authenticate and validate ALL metadata before observation,
/// serialize first publication, and
/// keep this same ledger through physical reconnects of the original endpoint.
///
/// This class does not validate grants, stop I/O, determine terminal outcomes,
/// or release native resources. Retire only after peer outcome confirmation,
/// native cleanup and final authority/epoch checks; never evict pending owners.
final class FileTransferLedger<T> {
  FileTransferLedger({required this.sender, this.capacity = 64}) {
    RangeError.checkValueInInterval(capacity, 1, 64, 'capacity');
  }

  final GrantRole sender;
  final int capacity;
  final _retained = <int, FileTransferSlot<T>>{};
  int _highestOrdinal = 0;

  int get highestOrdinal => _highestOrdinal;
  int get retainedCount => _retained.length;
  List<FileTransferSlot<T>> get slots => List.unmodifiable(_retained.values);

  void _checkDirection(FileOperationId operation) {
    if (operation.sender != sender) _fail('context_mismatch');
  }

  /// Consume a first publication. Even a valid request rejected for capacity
  /// burns its ordinal; it cannot later bootstrap a supposedly unstarted file.
  FileTransferSlot<T> admit(
    FileOperationId operation,
    String transferId,
    T value,
  ) {
    _checkDirection(operation);
    _lifecycleTransferId(transferId);
    if (operation.ordinal <= _highestOrdinal) _fail('invalid_state');
    _highestOrdinal = operation.ordinal;
    if (_retained.length >= capacity) _fail('resource_limit');
    final slot = FileTransferSlot._(
      operation,
      transferId,
      value,
      operation.attempt,
    );
    _retained[operation.ordinal] = slot;
    return slot;
  }

  /// A missing owner is not permission to bootstrap: [admit] must also succeed.
  FileTransferSlot<T>? find(int ordinal, String transferId) {
    _positiveOrdinal(ordinal);
    _lifecycleTransferId(transferId);
    final slot = _retained[ordinal];
    if (slot != null && slot.transferId != transferId) {
      _fail('context_mismatch');
    }
    return slot;
  }

  FileAttemptTicket<T> observeAttempt(
    FileOperationId operation,
    String transferId,
  ) {
    _checkDirection(operation);
    final previous = find(operation.ordinal, transferId);
    if (previous == null || operation.attempt <= previous.maxObservedAttempt) {
      _fail('invalid_state');
    }
    // Preserve the currently bound operation while consuming the newer one.
    // Rotate snapshot identity before any asynchronous native rebind/cleanup.
    final snapshot = FileTransferSlot._(
      previous.operation,
      previous.transferId,
      previous.value,
      operation.attempt,
    );
    _retained[operation.ordinal] = snapshot;
    return FileAttemptTicket._(operation, snapshot);
  }

  /// A superseded ticket still fails after native rebind succeeds. The caller
  /// must then stop/clean that newly rebound scope; this table cannot own I/O.
  FileTransferSlot<T> bindAttempt(FileAttemptTicket<T> ticket) {
    final previous = ticket._snapshot;
    _requireCurrent(previous);
    final current = FileTransferSlot._(
      ticket.operation,
      previous.transferId,
      previous.value,
      previous.maxObservedAttempt,
    );
    _retained[ticket.operation.ordinal] = current;
    return current;
  }

  void retire(FileTransferSlot<T> slot) {
    _requireCurrent(slot);
    _retained.remove(slot.operation.ordinal);
  }

  void _requireCurrent(FileTransferSlot<T> slot) {
    if (!identical(_retained[slot.operation.ordinal], slot)) {
      _fail('invalid_state');
    }
  }
}
