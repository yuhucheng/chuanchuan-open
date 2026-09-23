part of 'file_transfer_channel.dart';

/// Retained metadata also represents a terminal publication with no native
/// owner. Such a record consumes capacity until the retirement handshake.
final class _IncomingRecord {
  _IncomingRecord(this.offer, [this.entry]);
  final FileOffer offer;
  final ReceivedTransfer? entry;
  _IncomingRetirement? retirement;
}

final class _IncomingAdmission {
  _IncomingAdmission(this.request, this.operation, this.entry, this.ticket);
  final VerifiedSessionMessage request;
  final FileOperationId operation;
  final ReceivedTransfer entry;
  final FileAttemptTicket<_IncomingRecord>? ticket;
}

extension _IncomingHistory on FileTransferChannel {
  FileTransferLedger<_IncomingRecord> _ledgerFor(SessionAuthorization request) {
    final original = _incomingAuthority;
    if (original != null &&
        (!identical(original.grant, request.grant) ||
            !original.hasSameGrantAs(request) ||
            original.sender != request.sender)) {
      throw const FileProtocolFailure('context_mismatch');
    }
    _incomingAuthority ??= request;
    return _incomingLedger ??= FileTransferLedger(sender: request.sender);
  }

  FileOffer _offerOf(FileMessage message) => switch (message) {
    FileOffer() => message,
    FileResume(
      :final transferOrdinal,
      :final transferId,
      :final name,
      :final size,
      :final sha256,
      :final chunkBytes,
    ) ||
    FileTerminate(
      :final transferOrdinal,
      :final transferId,
      :final name,
      :final size,
      :final sha256,
      :final chunkBytes,
    ) ||
    FileRetire(
      :final transferOrdinal,
      :final transferId,
      :final name,
      :final size,
      :final sha256,
      :final chunkBytes,
    ) => FileOffer(
      transferOrdinal: transferOrdinal,
      transferId: transferId,
      name: name,
      size: size,
      sha256: sha256,
      chunkBytes: chunkBytes,
    ),
    _ => throw const FileProtocolFailure('invalid_state'),
  };

  bool _equalOffer(FileOffer a, FileOffer b) =>
      a.transferOrdinal == b.transferOrdinal &&
      a.transferId == b.transferId &&
      a.name == b.name &&
      a.size == b.size &&
      a.sha256 == b.sha256 &&
      a.chunkBytes == b.chunkBytes;

  FileTransferSlot<_IncomingRecord>? _findIncoming(
    FileTransferLedger<_IncomingRecord> ledger,
    FileOffer offer,
  ) {
    // A random file ID cannot acquire a second ordinal while retained.
    if (ledger.slots.any(
      (slot) =>
          slot.transferId == offer.transferId &&
          slot.operation.ordinal != offer.transferOrdinal,
    )) {
      throw const FileProtocolFailure('context_mismatch');
    }
    final slot = ledger.find(offer.transferOrdinal, offer.transferId);
    if (slot != null && !_equalOffer(slot.value.offer, offer)) {
      throw const FileProtocolFailure('context_mismatch');
    }
    return slot;
  }

  _IncomingAdmission? _admitIncoming(
    VerifiedSessionMessage request,
    FileMessage message,
    FileOperationId operation,
  ) {
    final ledger = _ledgerFor(request), offer = _offerOf(message);
    final slot = _findIncoming(ledger, offer);
    if (slot?.value.retirement != null) {
      throw const FileProtocolFailure('invalid_state');
    }
    if (slot != null && _replyRetainedTermination(request, message)) {
      return null;
    }
    if (slot == null) {
      if (message is FileResume && request.transportGeneration <= 1) {
        throw const FileProtocolFailure('invalid_state');
      }
      final entry = ReceivedTransfer._(request, offer);
      ledger.admit(operation, offer.transferId, _IncomingRecord(offer, entry));
      _received.add(entry);
      return _IncomingAdmission(request, operation, entry, null);
    }
    // Consume a valid new attempt even if the owner is busy. Metadata mismatch
    // above must never rotate a live owner's snapshot or invalidate its ticket.
    final entry = slot.value.entry;
    if (message is! FileResume || entry == null) {
      throw const FileProtocolFailure('invalid_state');
    }
    final ticket = ledger.observeAttempt(operation, offer.transferId);
    return _IncomingAdmission(request, operation, entry, ticket);
  }

  void _dispatchIncoming(
    _IncomingAdmission admission, {
    FileMessage? terminal,
  }) {
    final request = admission.request, entry = admission.entry;
    try {
      request.requireCurrent();
      if (_closed ||
          _suspended ||
          !_received.contains(entry) ||
          entry._retirement != null) {
        throw const FileProtocolFailure('operation_stopped');
      }
      if (admission.ticket == null) {
        // This operation was bound by admit. A higher busy observation must not
        // invalidate the already admitted owner or its original native begin.
        if (terminal != null) {
          _launch(
            _cancel(
              entry,
              request,
              reply: terminal is FileCancel,
              failure: terminal is FileFailed ? terminal.code : null,
            ),
          );
        } else {
          entry._paused = false;
          _data(entry, () => _startIncoming(entry, request));
        }
        return;
      }
      final current = _incomingLedger!.find(
        admission.operation.ordinal,
        entry.offer.transferId,
      )!;
      if (current.maxObservedAttempt != admission.operation.attempt) {
        throw const FileProtocolFailure('invalid_state');
      }
      if (entry._busy ||
          entry._cancelling ||
          entry._pausing ||
          (terminal == null &&
              entry.task?.receipt == null &&
              (entry._cancelled ||
                  entry._failure != null ||
                  (entry.task != null &&
                      entry.task!.phase != IncomingFilePhase.paused) ||
                  (entry.task == null &&
                      (!entry._paused ||
                          request.transportGeneration <=
                              entry._authority.transportGeneration))))) {
        throw const FileProtocolFailure('resume_mismatch');
      }
      if (terminal != null) {
        // Terminal signals may settle a held request without opening a scope.
        _incomingLedger!.bindAttempt(admission.ticket!);
        entry._authority = request;
        _launch(
          _cancel(
            entry,
            request,
            reply: terminal is FileCancel,
            failure: terminal is FileFailed ? terminal.code : null,
          ),
        );
        return;
      }
      entry._epoch++;
      entry._queued = null;
      entry._rebinding = admission;
      _heldRequests[request.sessionId] = request;
      _data(entry, () => _resumeIncoming(admission), replyAuthority: request);
    } catch (error) {
      _reject(
        request,
        entry.offer.transferId,
        FileTransferChannel._code(error),
      );
    }
  }

  Future<FileMessage?> _resumeIncoming(_IncomingAdmission admission) async {
    final request = admission.request, entry = admission.entry;
    final epoch = entry._epoch, transportEpoch = _transportEpoch;
    try {
      final response = entry.task != null
          ? await entry.task!.resume(request)
          : await _startIncoming(entry, request);
      request.requireCurrent();
      if (_closed ||
          _suspended ||
          transportEpoch != _transportEpoch ||
          epoch != entry._epoch ||
          (entry.task?.receipt == null &&
              (entry._cancelled || entry._failure != null)) ||
          !identical(entry._rebinding, admission)) {
        throw const FileProtocolFailure('operation_stopped');
      }
      // Nothing asynchronous may separate ticket commit and resolver switch.
      _incomingLedger!.bindAttempt(admission.ticket!);
      entry._authority = request;
      entry._paused = false;
      entry._queued = null;
      return response;
    } catch (error) {
      // Native rebind may already have succeeded before its ticket became
      // stale. Keep ownership until cancellation and cleanup have completed.
      if (entry.task?.receipt == null) {
        if (epoch == entry._epoch && !entry._cancelled && !_suspended) {
          entry._failure = FileTransferChannel._code(error);
        }
        try {
          await entry.task?.cancel();
          await entry.task?.cleanup();
        } catch (cleanupError) {
          entry._cleanupFailure = cleanupError;
        }
      }
      if (!_closed && !_suspended && transportEpoch == _transportEpoch) {
        final terminal = _heldTerminal[request.sessionId];
        if (terminal != null) {
          // Bind was stopped by an authenticated cancellation. Reply using the
          // pending request without replacing the retained data resolver.
          final saved = entry.task?.receipt;
          if (saved != null ||
              entry.task?.phase == IncomingFilePhase.cancelled ||
              entry.task == null) {
            final result = saved != null
                ? _complete(entry, saved)
                : FileCancelled(transferId: entry.offer.transferId);
            if (terminal is FileCancel) {
              _launch(
                _queueReply(() {
                  request.requireCurrent();
                  return transport.sendSignal(
                    request,
                    FileCodec.encode(result),
                  );
                }, priority: true),
              );
            }
          }
        } else {
          _reject(
            request,
            entry.offer.transferId,
            FileTransferChannel._code(error),
          );
        }
      }
      return null;
    } finally {
      if (identical(entry._rebinding, admission)) entry._rebinding = null;
      if (identical(_heldRequests[request.sessionId], request)) {
        _heldRequests.remove(request.sessionId);
        _heldTerminal.remove(request.sessionId);
      }
    }
  }

  /// Unknown incoming termination is first publication, too. Its synthetic
  /// operation only reserves the ordinal; it never installs a data resolver.
  void _admitIncomingTermination(
    VerifiedSessionMessage request,
    FileTerminate message,
  ) {
    final ledger = _ledgerFor(request), offer = _offerOf(message);
    if (_findIncoming(ledger, offer) != null) return;
    ledger.admit(
      FileOperationId(
        sender: request.sender,
        ordinal: offer.transferOrdinal,
        attempt: 1,
      ),
      offer.transferId,
      _IncomingRecord(offer),
    );
  }
}
