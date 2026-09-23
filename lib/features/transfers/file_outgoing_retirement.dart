part of 'file_transfer_channel.dart';

typedef SentFileHistory = ReceivedFileHistory;

/// A retained protocol slot, independent of the selected-file queue. Delivery
/// is determined only by [receipt], never by [retired].
final class FileOutgoingRetirement {
  FileOutgoingRetirement._(OutgoingFileTransfer task, this._terminal)
    : _task = task,
      _original = task.context.authorization,
      name = task.source.file.name,
      size = task.context.size;
  final String name;
  final int size;
  FileRetirementOutcome get outcome => switch (_terminal) {
    FileComplete() => FileRetirementOutcome.completed,
    FileCancelled() => FileRetirementOutcome.cancelled,
    FileFailed() => FileRetirementOutcome.failed,
    _ => throw StateError('Retirement requires a terminal observation.'),
  };
  OutgoingFileTransfer? _task;
  SessionAuthorization? _original;
  FileMessage _terminal;
  _OutgoingRetirementAttempt? _attempt;
  int _lastEpoch = -1;
  bool _confirmed = false, retired = false;
  Object? failure;
  FileComplete? get receipt =>
      _terminal is FileComplete ? _terminal as FileComplete : null;
  bool get pending => !retired;
}

final class _OutgoingRetirementAttempt {
  _OutgoingRetirementAttempt(this.epoch);
  final int epoch;
  final stopped = Completer<void>();
  final response = Completer<FileMessage>();
  final facts = <_FileTermination>[];
  LocalSessionRequest? request;
  FileRetirementContext? context;
  bool checking = false, issued = false;
  void stop() {
    if (!stopped.isCompleted) stopped.complete();
  }
}

extension OutgoingRetirementChannel on FileTransferChannel {
  List<FileOutgoingRetirement> get outgoingRetirements =>
      List.unmodifiable(_outgoingRetirements.values);
  FileOutgoingRetirement? outgoingRetirementFor(OutgoingFileTransfer task) =>
      _outgoingRetirements[task];
  void _admitOutgoing(OutgoingFileTransfer task) {
    final authority = task.context.authorization;
    final operation = FileOperationId.parse(authority.sessionId);
    if (operation.sender != authority.sender ||
        operation.ordinal != task.context.transferOrdinal) {
      throw const FileProtocolFailure('context_mismatch');
    }
    final original = _outgoingAuthority;
    if (original != null &&
        (!identical(original.grant, authority.grant) ||
            !original.hasSameGrantAs(authority) ||
            original.sender != authority.sender)) {
      throw const FileProtocolFailure('context_mismatch');
    }
    _outgoingAuthority ??= authority;
    final ledger = _outgoingLedger ??= FileTransferLedger(
      sender: authority.sender,
    );
    if (ledger.slots.any(
      (slot) => slot.transferId == task.context.transferId,
    )) {
      throw const FileProtocolFailure('context_mismatch');
    }
    ledger.admit(operation, task.context.transferId, task);
    _outgoingBoundEpoch[task] = _transportEpoch;
  }

  FileAttemptTicket<OutgoingFileTransfer> _observeOutgoing(
    OutgoingFileTransfer task,
    LocalSessionRequest request,
  ) {
    if (_closed ||
        !_outgoing.contains(task) ||
        _retirementRequested.contains(task)) {
      throw const FileProtocolFailure('invalid_state');
    }
    request.requireCurrent();
    final current = task.context,
        operation = FileOperationId.parse(request.sessionId);
    final message = FileCodec.decode(request.body);
    if (message is! FileResume ||
        !identical(request.grant, current.authorization.grant) ||
        !request.hasSameGrantAs(current.authorization) ||
        operation.sender != current.transferSender ||
        request.sender != current.transferSender ||
        operation.ordinal != current.transferOrdinal ||
        !_equalOffer(_offerOf(message), _offerOf(current.request))) {
      throw const FileProtocolFailure('context_mismatch');
    }
    return _outgoingLedger!.observeAttempt(operation, current.transferId);
  }

  FileMessage? _outgoingTerminal(OutgoingFileTransfer task) {
    final context = task.context;
    if (task.receipt != null) return task.receipt;
    for (final record in _cancellations) {
      if (record.acknowledged &&
          record._original.hasSameGrantAs(context.authorization) &&
          record.message.transferSender == context.transferSender &&
          record.message.transferOrdinal == context.transferOrdinal &&
          record.message.transferId == context.transferId) {
        return record.receipt ?? FileCancelled(transferId: context.transferId);
      }
    }
    for (final fact in _terminalFacts) {
      if (!fact.locallyInitiated &&
          fact.original is VerifiedSessionMessage &&
          fact.original.sender != context.transferSender &&
          fact.original.hasSameGrantAs(context.authorization) &&
          fact.message.transferSender == context.transferSender &&
          fact.message.transferOrdinal == context.transferOrdinal &&
          fact.message.transferId == context.transferId &&
          fact.settled is FileCancelled) {
        return fact.settled;
      }
    }
    return task.peerTerminal;
  }

  bool canRetireOutgoing(OutgoingFileTransfer task) =>
      !_closed && _outgoing.contains(task) && _outgoingTerminal(task) != null;

  FileOutgoingRetirement retireOutgoing(OutgoingFileTransfer task) {
    final existing = _outgoingRetirements[task];
    if (existing != null) return existing;
    if (!canRetireOutgoing(task)) {
      throw const FileProtocolFailure('invalid_state');
    }
    final record = FileOutgoingRetirement._(task, _outgoingTerminal(task)!);
    _outgoingRetirements[task] = record;
    _retirementRequested.add(task);
    _flushOutgoingRetirements();
    return record;
  }

  void retryOutgoingRetirement(FileOutgoingRetirement record) {
    if (_closed ||
        !_controlReady ||
        record._attempt != null ||
        record.retired ||
        !_outgoingRetirements.containsValue(record)) {
      throw const FileProtocolFailure('invalid_state');
    }
    record._lastEpoch = -1;
    record.failure = null;
    _flushOutgoingRetirements();
  }

  void _flushOutgoingRetirements() {
    if (_closed || !_controlReady) return;
    for (final task in _retirementRequested.toList()) {
      final terminal = _outgoingTerminal(task);
      if (terminal == null) continue;
      final record = _outgoingRetirements.putIfAbsent(
        task,
        () => FileOutgoingRetirement._(task, terminal),
      );
      if (record._attempt != null || record._lastEpoch == _transportEpoch) {
        continue;
      }
      final attempt = _OutgoingRetirementAttempt(_transportEpoch);
      record._lastEpoch = _transportEpoch;
      record._attempt = attempt;
      _launch(_runOutgoingRetirement(record, attempt));
      onChanged?.call();
    }
  }

  void _outgoingRetirementCurrent(
    FileOutgoingRetirement record,
    _OutgoingRetirementAttempt attempt,
  ) {
    if (_closed ||
        !_controlReady ||
        attempt.epoch != _transportEpoch ||
        attempt.stopped.isCompleted ||
        !identical(record._attempt, attempt) ||
        !identical(_outgoingRetirements[record._task], record)) {
      throw const FileProtocolFailure('operation_stopped');
    }
    attempt.request?.requireCurrent();
  }

  Future<T> _outgoingRetirementWait<T>(
    FileOutgoingRetirement record,
    _OutgoingRetirementAttempt attempt,
    Future<T> work,
  ) async {
    final result = await Future.any<T>([
      work,
      attempt.stopped.future.then<T>(
        (_) => throw const FileProtocolFailure('operation_stopped'),
      ),
    ]);
    _outgoingRetirementCurrent(record, attempt);
    return result;
  }

  Future<void> _runOutgoingRetirement(
    FileOutgoingRetirement record,
    _OutgoingRetirementAttempt attempt,
  ) async {
    final task = record._task!;
    try {
      await _outgoingRetirementWait(
        record,
        attempt,
        task.prepareRetirement(
          drainWire: _outgoingBoundEpoch[task] == _transportEpoch,
        ),
      );
      // In-flight complete validation may have won before close. It supersedes
      // an earlier cancellation observation but is never inferred from close.
      record._terminal =
          task.receipt ??
          record.receipt ??
          _outgoingTerminal(task) ??
          record._terminal;
      final offer = _offerOf(task.context.request);
      final terminal = record._terminal;
      final outcome = switch (terminal) {
        FileComplete() => FileRetirementOutcome.completed,
        FileCancelled() => FileRetirementOutcome.cancelled,
        FileFailed() => FileRetirementOutcome.failed,
        _ => throw const FileProtocolFailure('invalid_state'),
      };
      final message = FileRetire(
        transferId: offer.transferId,
        transferOrdinal: offer.transferOrdinal,
        transferSender: task.context.transferSender,
        name: offer.name,
        size: offer.size,
        sha256: offer.sha256,
        chunkBytes: offer.chunkBytes,
        outcome: outcome,
        actualName: terminal is FileComplete ? terminal.actualName : null,
        failureCode: terminal is FileFailed ? terminal.code : null,
      );
      final request = await _outgoingRetirementWait(
        record,
        attempt,
        transport.createRequest(
          SessionOperation.file,
          'file-retire-${newTransferId()}',
          FileCodec.encode(message),
        ),
      );
      if (!identical(request.grant, record._original!.grant) ||
          !request.hasSameGrantAs(record._original!) ||
          request.sender != task.context.transferSender) {
        throw const FileProtocolFailure('context_mismatch');
      }
      attempt.request = request;
      attempt.context = await _outgoingRetirementWait(
        record,
        attempt,
        FileRetirementContext.fromRequest(registry, request),
      );
      if (!record._confirmed) {
        final result = await _outgoingRetirementWait(
          record,
          attempt,
          Future.wait<Object?>([
            Future<void>.sync(() {
              _outgoingRetirementCurrent(record, attempt);
              attempt.issued = true;
              return transport.sendRequest(request);
            }),
            attempt.response.future,
          ], eagerError: true),
        );
        final response = result[1];
        if (response is FileComplete) {
          if (outcome == FileRetirementOutcome.completed) {
            throw const FileProtocolFailure('invalid_state');
          }
          record._lastEpoch = -1;
          return; // Resend the corrected result with a new sealed request.
        }
        if (response is FileRejected) throw FileProtocolFailure(response.code);
      }
      final slot = _outgoingLedger!.find(
        offer.transferOrdinal,
        offer.transferId,
      )!;
      if (!identical(slot.value, task)) {
        throw const FileProtocolFailure('invalid_state');
      }
      final facts = _terminalFacts
          .where(
            (fact) =>
                fact.original.hasSameGrantAs(request) &&
                fact.message.transferSender == task.context.transferSender &&
                fact.message.transferOrdinal == offer.transferOrdinal &&
                fact.message.transferId == offer.transferId,
          )
          .toList();
      final notifications = _cancellations
          .where(
            (notification) =>
                notification._original.hasSameGrantAs(request) &&
                notification.message.transferSender ==
                    task.context.transferSender &&
                notification.message.transferOrdinal == offer.transferOrdinal &&
                notification.message.transferId == offer.transferId,
          )
          .toList();
      for (final fact in facts) {
        attempt.facts.add(fact);
        fact.retiring = true;
        if (fact.replyWork case final work?) {
          await _outgoingRetirementWait(
            record,
            attempt,
            work.then<void>((_) {}, onError: (Object e, StackTrace s) {}),
          );
        }
      }
      for (final notification in notifications) {
        notification._stopped = true;
        notification._request = null;
        for (final work in [
          notification._sendingWork,
          notification._checkingWork,
        ]) {
          if (work != null) {
            await _outgoingRetirementWait(
              record,
              attempt,
              work.then<void>((_) {}, onError: (Object e, StackTrace s) {}),
            );
          }
        }
      }
      await _outgoingRetirementWait(record, attempt, registry.verify(request));
      request.requireCurrent();
      final history = SentFileHistory(
        transferId: offer.transferId,
        transferOrdinal: offer.transferOrdinal,
        name: offer.name,
        size: offer.size,
        sha256: offer.sha256,
        outcome: outcome,
        actualName: message.actualName,
        failureCode: message.failureCode,
      );
      _outgoingLedger!.retire(slot);
      _outgoing.remove(task);
      _outgoingBoundEpoch.remove(task);
      for (final fact in facts) {
        fact.detached = true;
        fact.replyNonce++;
        _terminalFacts.remove(fact);
      }
      _cancellations.removeWhere(notifications.contains);
      _retirementRequested.remove(task);
      _outgoingRetirements.remove(task);
      _sendHistory.add(history);
      if (_sendHistory.length > FileTransferChannel.maxTransfers) {
        _sendHistory.removeAt(0);
      }
      record.retired = true;
      record.failure = null;
      record._task = null;
      record._original = null;
    } catch (error) {
      if (!_closed && attempt.epoch == _transportEpoch) record.failure = error;
    } finally {
      for (final fact in attempt.facts) {
        if (!fact.detached) fact.retiring = false;
      }
      attempt.stop();
      if (identical(record._attempt, attempt)) record._attempt = null;
      if (!_closed && !record.retired && record._lastEpoch != _transportEpoch) {
        _flushOutgoingRetirements();
      }
    }
  }

  bool _outgoingRetirementReply(VerifiedSessionSignal signal) {
    final record = _outgoingRetirements.values
        .where(
          (record) => identical(record._attempt?.request, signal.authorization),
        )
        .firstOrNull;
    if (record == null) return false;
    final attempt = record._attempt!;
    if (!attempt.issued ||
        attempt.context == null ||
        attempt.checking ||
        attempt.response.isCompleted) {
      return true;
    }
    attempt.checking = true;
    _launch(() async {
      try {
        final message = await _outgoingRetirementWait(
          record,
          attempt,
          attempt.context!.decodeSignal(signal),
        );
        signal.requireCurrent();
        if (message is FileComplete) {
          if (!record._task!.mayHaveCommitted ||
              (record.receipt != null &&
                  record.receipt!.actualName != message.actualName)) {
            throw const FileProtocolFailure('integrity_mismatch');
          }
          record._terminal = message;
        } else if (message is FileRetired) {
          record._confirmed = true;
        }
        if (!attempt.response.isCompleted) attempt.response.complete(message);
      } catch (error, stack) {
        if (!attempt.response.isCompleted) {
          attempt.response.completeError(error, stack);
        }
      } finally {
        attempt.checking = false;
      }
    }());
    return true;
  }
}
