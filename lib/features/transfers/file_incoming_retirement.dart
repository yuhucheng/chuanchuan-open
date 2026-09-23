part of 'file_transfer_channel.dart';

/// Display-only history: no authorization, resolver, lease or native owner.
final class ReceivedFileHistory {
  const ReceivedFileHistory({
    required this.transferId,
    required this.transferOrdinal,
    required this.name,
    required this.size,
    required this.sha256,
    required this.outcome,
    this.actualName,
    this.failureCode,
  });
  final String transferId, name, sha256;
  final int transferOrdinal, size;
  final FileRetirementOutcome outcome;
  final String? actualName, failureCode;
}

final class _IncomingRetirement {
  _IncomingRetirement(this.request, this.message, this.epoch);
  final VerifiedSessionMessage request;
  final FileRetire message;
  final int epoch;
  final stopped = Completer<void>();
  FileTransferSlot<_IncomingRecord>? slot;
  final facts = <_FileTermination>[];
}

extension _IncomingRetirementChannel on FileTransferChannel {
  void _receiveRetirement(VerifiedSessionMessage request, FileRetire message) {
    if (!RegExp(r'^file-retire-[0-9a-f]{32}$').hasMatch(request.sessionId) ||
        message.transferSender != request.sender) {
      _reject(request, message.transferId, 'context_mismatch');
      return;
    }
    if (_incomingRetirements.containsKey(message.transferOrdinal) ||
        _incomingRetirements.length >= FileTransferChannel.maxTransfers) {
      _reject(request, message.transferId, 'resource_limit');
      return;
    }
    final job = _IncomingRetirement(request, message, _transportEpoch);
    _incomingRetirements[message.transferOrdinal] = job;
    _launch(_retireIncoming(job));
  }

  void _retirementCurrent(_IncomingRetirement job) {
    if (_closed ||
        job.epoch != _transportEpoch ||
        !identical(_incomingRetirements[job.message.transferOrdinal], job)) {
      throw const FileProtocolFailure('operation_stopped');
    }
    job.request.requireCurrent();
    final slot = job.slot;
    if (slot != null &&
        (!identical(slot.value.retirement, job) ||
            !identical(
              _incomingLedger?.find(slot.operation.ordinal, slot.transferId),
              slot,
            ))) {
      throw const FileProtocolFailure('invalid_state');
    }
  }

  Future<T> _retirementWait<T>(_IncomingRetirement job, Future<T> work) async {
    final value = await Future.any<T>([
      work,
      job.stopped.future.then<T>(
        (_) => throw const FileProtocolFailure('operation_stopped'),
      ),
    ]);
    _retirementCurrent(job);
    return value;
  }

  Future<void> _retirementDrain(_IncomingRetirement job, Future<void> work) =>
      _retirementWait(
        job,
        work.then<void>((_) {}, onError: (Object e, StackTrace s) {}),
      );

  Future<void> _retireIncoming(_IncomingRetirement job) async {
    final request = job.request, message = job.message;
    try {
      final context = await _retirementWait(
        job,
        FileRetirementContext.fromRequest(registry, request),
      );
      final ledger = _ledgerFor(request);
      final slot = _findIncoming(ledger, _offerOf(message));
      final retired = FileRetired(
        transferId: message.transferId,
        transferOrdinal: message.transferOrdinal,
      );
      if (slot == null) {
        if (message.transferOrdinal > ledger.highestOrdinal) {
          throw const FileProtocolFailure('invalid_state');
        }
        await _sendRetirementReply(job, context, retired);
        return;
      }
      final entry = slot.value.entry;
      if (slot.value.retirement != null ||
          entry?._rebinding != null ||
          (entry != null && !_terminal(entry))) {
        throw const FileProtocolFailure('invalid_state');
      }
      job.slot = slot;
      slot.value.retirement = job;
      if (entry != null) entry._retirement = job;
      job.facts.addAll(
        _terminalFacts.where(
          (fact) =>
              fact.original.hasSameGrantAs(request) &&
              fact.message.transferSender == message.transferSender &&
              fact.message.transferOrdinal == message.transferOrdinal &&
              fact.message.transferId == message.transferId,
        ),
      );
      for (final fact in job.facts) {
        fact.retiring = true;
      }

      // Freeze new ingress, but drain previously admitted work outside the
      // global reply queue. Waiting for whenIdle here would wait for ourselves.
      for (final work in <Future<void>?>[
        entry?._dataIdle,
        entry?._cancelPending,
        entry?._pausePending,
        entry?._localCancel,
      ]) {
        if (work != null) await _retirementDrain(job, work);
      }
      FileMessage? settled;
      for (final fact in job.facts) {
        settled = await _retirementWait(job, _settleTermination(fact));
        if (fact.replyWork case final work?) await _retirementDrain(job, work);
      }
      if (entry != null) {
        await _retirementDrain(
          job,
          Future.wait(List.of(entry._replyWork)).then<void>((_) {}),
        );
      }
      final epoch = entry?._epoch;
      FileMessage actual() {
        if (entry?.task?.receipt case final receipt?) {
          return _complete(entry!, receipt);
        }
        if (settled is FileComplete || settled is FileCancelled) {
          return settled!;
        }
        if (entry?._failure case final code?) {
          return FileFailed(transferId: message.transferId, code: code);
        }
        if (entry != null &&
            (entry._cancelled ||
                entry.task?.phase == IncomingFilePhase.cancelled)) {
          return FileCancelled(transferId: message.transferId);
        }
        throw const FileProtocolFailure('invalid_state');
      }

      final terminal = actual();
      if (terminal is FileComplete &&
          message.outcome != FileRetirementOutcome.completed) {
        await _sendRetirementReply(job, context, terminal);
        return;
      }
      final matches = switch (terminal) {
        FileComplete(:final actualName) =>
          message.outcome == FileRetirementOutcome.completed &&
              message.actualName == actualName,
        FileCancelled() => message.outcome == FileRetirementOutcome.cancelled,
        FileFailed(:final code) =>
          message.outcome == FileRetirementOutcome.failed &&
              message.failureCode == code,
        _ => false,
      };
      if (!matches) throw const FileProtocolFailure('context_mismatch');

      final notifications = _cancellations
          .where(
            (record) =>
                record._original.hasSameGrantAs(request) &&
                record.message.transferSender == message.transferSender &&
                record.message.transferOrdinal == message.transferOrdinal &&
                record.message.transferId == message.transferId,
          )
          .toList();
      for (final record in notifications) {
        record._stopped = true;
        record._request = null;
        // Wait for local callbacks, never for the peer's cancellation ACK.
        if (record._sendingWork case final work?) {
          await _retirementDrain(job, work);
        }
        if (record._checkingWork case final work?) {
          await _retirementDrain(job, work);
        }
      }
      if (entry != null) {
        try {
          if (entry.task case final task?) {
            await _retirementWait(job, task.close());
          }
          await _retirementWait(job, _cleanupDirectory(entry));
        } catch (error) {
          entry._cleanupFailure = error;
          rethrow;
        }
      }
      await _retirementWait(job, context.validateReply(retired));
      if (epoch != entry?._epoch ||
          FileCodec.encode(actual()) != FileCodec.encode(terminal)) {
        throw const FileProtocolFailure('invalid_state');
      }
      final history = ReceivedFileHistory(
        transferId: message.transferId,
        transferOrdinal: message.transferOrdinal,
        name: message.name,
        size: message.size,
        sha256: message.sha256,
        outcome: message.outcome,
        actualName: message.actualName,
        failureCode: message.failureCode,
      );
      // No await between the last authority/identity check and all removals.
      _retirementCurrent(job);
      ledger.retire(slot);
      for (final admission
          in _heldAdmissions.values
              .where((admission) => identical(admission.entry, entry))
              .toList()) {
        final id = admission.request.sessionId;
        _heldAdmissions.remove(id);
        if (identical(_heldRequests[id], admission.request)) {
          _heldRequests.remove(id);
          _heldTerminal.remove(id);
        }
      }
      slot.value.retirement = null;
      if (entry != null) entry._retirement = null;
      job.slot = null;
      if (entry != null) _received.remove(entry);
      for (final fact in job.facts) {
        fact.detached = true;
        fact.replyNonce++;
        _terminalFacts.remove(fact);
      }
      _cancellations.removeWhere(notifications.contains);
      _receiveHistory.add(history);
      if (_receiveHistory.length > FileTransferChannel.maxTransfers) {
        _receiveHistory.removeAt(0);
      }
      await _sendRetirementReply(job, context, retired);
    } catch (error) {
      if (!_closed && job.epoch == _transportEpoch) {
        _reject(request, message.transferId, FileTransferChannel._code(error));
      }
    } finally {
      if (!job.stopped.isCompleted) job.stopped.complete();
      final slot = job.slot;
      if (identical(slot?.value.retirement, job)) slot!.value.retirement = null;
      if (identical(slot?.value.entry?._retirement, job)) {
        slot!.value.entry!._retirement = null;
      }
      for (final fact in job.facts) {
        fact.retiring = false;
      }
      if (identical(_incomingRetirements[message.transferOrdinal], job)) {
        _incomingRetirements.remove(message.transferOrdinal);
      }
    }
  }

  Future<void> _sendRetirementReply(
    _IncomingRetirement job,
    FileRetirementContext context,
    FileMessage reply,
  ) async {
    await _retirementWait(job, context.validateReply(reply));
    await _retirementWait(
      job,
      _queueReply(
        () {
          _retirementCurrent(job);
          return transport.sendSignal(job.request, FileCodec.encode(reply));
        },
        priority: true,
        allowSuspended: true,
      ),
    );
  }
}
