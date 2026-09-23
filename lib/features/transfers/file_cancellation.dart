part of 'file_transfer_channel.dart';

/// A process-local terminal notification, independent of selected-file/native
/// ownership. A completed local cancellation may still await this peer fact.
final class FileCancellation {
  FileCancellation._(
    this._original,
    this.message,
    this._allowReceipt,
    this._publication,
  );
  final SessionAuthorization _original;
  final FileTerminate message;
  final bool _allowReceipt;
  final FilePublication? _publication;
  LocalSessionRequest? _request;
  int _attemptEpoch = -1;
  bool _stopped = false, acknowledged = false;
  bool get pending => !_stopped && !acknowledged;
  FileComplete? receipt;
  Object? failure;
  bool _checking = false;
  Future<void>? _sendingWork, _checkingWork;
}

final class _FileTermination {
  _FileTermination(
    this.original,
    this.message, {
    this.locallyInitiated = false,
  });
  final SessionAuthorization original;
  final bool locallyInitiated;
  VerifiedSessionMessage? replyRequest;
  final FileTerminate message;
  Future<FileMessage>? settling;
  FileMessage? settled;
  bool settlingFailed = false, replying = false;
  int replyNonce = 0;
  Future<void>? replyWork;
  bool retiring = false, detached = false;
}

extension FileCancellationChannel on FileTransferChannel {
  void retryCancellation(FileCancellation record) {
    if (_closed ||
        !_controlReady ||
        !_cancellations.contains(record) ||
        !record.pending) {
      throw const FileProtocolFailure('invalid_state');
    }
    record.failure = null;
    record._attemptEpoch = -1;
    _flushCancellations();
  }

  Future<void> retryReceivedCancellation(ReceivedTransfer entry) async {
    if (!_received.contains(entry) || entry.canCancel) {
      throw const FileProtocolFailure('invalid_state');
    }
    final record = entry._cancellation;
    if (record == null) {
      await cancelReceived(entry);
    } else {
      retryCancellation(record);
    }
  }

  FileCancellation cancelOutgoing(OutgoingFileTransfer task) {
    final context = task.context;
    final name = switch (context.request) {
      FileOffer(:final name) || FileResume(:final name) => name,
      _ => throw const FileProtocolFailure('invalid_state'),
    };
    return _queueCancellation(
      context.authorization,
      FileOffer(
        transferId: context.transferId,
        transferOrdinal: context.transferOrdinal,
        name: name,
        size: context.size,
        sha256: context.sha256,
        chunkBytes: context.chunkBytes,
      ),
      context.transferSender,
      allowReceipt: task.mayHaveCommitted,
      publication: task.publication,
    );
  }

  FileCancellation _queueCancellation(
    SessionAuthorization original,
    FileOffer offer,
    GrantRole sender, {
    bool allowReceipt = false,
    FilePublication? publication,
  }) {
    for (final record in _cancellations) {
      if (record._original.hasSameGrantAs(original) &&
          record.message.transferSender == sender &&
          record.message.transferId == offer.transferId) {
        return record;
      }
    }
    if (_closed ||
        _cancellations.length >= FileTransferChannel.maxTransfers * 2) {
      throw const FileProtocolFailure('resource_limit');
    }
    final result = FileCancellation._(
      original,
      FileTerminate(
        transferId: offer.transferId,
        transferOrdinal: offer.transferOrdinal,
        transferSender: sender,
        name: offer.name,
        size: offer.size,
        sha256: offer.sha256,
        chunkBytes: offer.chunkBytes,
      ),
      allowReceipt,
      publication,
    );
    final fact = _terminalFacts
        .where(
          (r) =>
              r.original.hasSameGrantAs(original) &&
              r.message.transferSender == sender &&
              r.message.transferId == offer.transferId,
        )
        .firstOrNull;
    if (fact == null) {
      if (_terminalFacts.length >= FileTransferChannel.maxTransfers * 2) {
        throw const FileProtocolFailure('resource_limit');
      }
      final retained = _FileTermination(
        original,
        result.message,
        locallyInitiated: true,
      );
      _terminalFacts.add(retained);
      _settleTermination(retained);
    }
    _cancellations.add(result);
    _flushCancellations();
    return result;
  }

  void _flushCancellations() {
    if (_closed ||
        !_controlReady ||
        _flushingCancellations == _transportEpoch) {
      return;
    }
    final epoch = _transportEpoch;
    _flushingCancellations = epoch;
    final stopped = _nextTransportChange.future;
    _launch(() async {
      try {
        while (!_closed && _controlReady && epoch == _transportEpoch) {
          final record = _cancellations
              .where(
                (r) =>
                    r.pending &&
                    r._attemptEpoch != epoch &&
                    (r._publication?.canPublish ?? true),
              )
              .firstOrNull;
          if (record == null) return;
          record._attemptEpoch = epoch;
          try {
            await (record._sendingWork = Future.any<void>([
              _sendCancellation(record, epoch),
              stopped.then(
                (_) => throw const FileProtocolFailure('operation_stopped'),
              ),
            ]));
          } catch (error) {
            if (epoch == _transportEpoch) record.failure = error;
          }
        }
      } finally {
        if (_flushingCancellations == epoch) _flushingCancellations = null;
      }
    }());
  }

  Future<void> _sendCancellation(FileCancellation record, int epoch) async {
    final stopped = _nextTransportChange.future;
    final request = await transport.createRequest(
      SessionOperation.file,
      'file-stop-${newTransferId()}',
      FileCodec.encode(record.message),
    );
    if (_closed ||
        !_controlReady ||
        epoch != _transportEpoch ||
        !record.pending) {
      return;
    }
    if (!request.hasSameGrantAs(record._original)) {
      throw const FileProtocolFailure('context_mismatch');
    }
    request.requireCurrent();
    if (_resolve(request.sessionId) != null) {
      throw const FileProtocolFailure('invalid_state');
    }
    record._request = request;
    Future<void> write() {
      if (_closed ||
          !_controlReady ||
          epoch != _transportEpoch ||
          !record.pending) {
        throw const FileProtocolFailure('operation_stopped');
      }
      request.requireCurrent();
      return transport.sendRequest(request);
    }

    await (record._publication?.publish(write, stopped: stopped) ?? write());
  }

  bool _cancellationReply(VerifiedSessionSignal signal) {
    final record = _cancellations
        .where((r) => identical(r._request, signal.authorization))
        .firstOrNull;
    if (record == null) return false;
    if (record._checking || record.acknowledged) return true;
    record._checking = true;
    final changed = _nextTransportChange.future;
    _launch(
      record._checkingWork = () async {
        try {
          await Future.any<void>([
            registry.verify(signal.authorization),
            changed.then(
              (_) => throw const FileProtocolFailure('operation_stopped'),
            ),
          ]);
          if (_closed || !identical(record._request, signal.authorization)) {
            return;
          }
          signal.requireCurrent();
          final message = FileCodec.decode(signal.body);
          if (message.transferId != record.message.transferId) {
            throw const FileProtocolFailure('context_mismatch');
          }
          if (message is FileComplete &&
              record._allowReceipt &&
              message.size == record.message.size &&
              message.sha256 == record.message.sha256) {
            record.receipt = message;
          } else if (message is FileFailed || message is FileRejected) {
            throw FileProtocolFailure(switch (message) {
              FileFailed(:final code) || FileRejected(:final code) => code,
              _ => throw StateError('failure'),
            });
          } else if (message is! FileCancelled) {
            throw const FileProtocolFailure('invalid_state');
          }
          record._publication?.confirmReceived();
          record.acknowledged = true;
          record.failure = null;
          _flushOutgoingRetirements();
        } catch (error) {
          if (identical(record._request, signal.authorization)) {
            record.failure = error;
          }
        } finally {
          record._checking = false;
        }
      }(),
    );
    return true;
  }

  bool _sameMetadata(FileTerminate terminal, FileMessage request) {
    return switch (request) {
      FileOffer(
        :final name,
        :final size,
        :final sha256,
        :final chunkBytes,
        :final transferOrdinal,
      ) ||
      FileResume(
        :final name,
        :final size,
        :final sha256,
        :final chunkBytes,
        :final transferOrdinal,
      ) ||
      FileTerminate(
        :final transferOrdinal,
        :final name,
        :final size,
        :final sha256,
        :final chunkBytes,
      ) =>
        terminal.transferId == request.transferId &&
            terminal.transferOrdinal == transferOrdinal &&
            terminal.name == name &&
            terminal.size == size &&
            terminal.sha256 == sha256 &&
            terminal.chunkBytes == chunkBytes,
      _ => false,
    };
  }

  void _receiveTermination(
    VerifiedSessionMessage request,
    FileTerminate message,
  ) {
    if (_outgoingRetirements.keys.any(
      (task) =>
          task.context.authorization.hasSameGrantAs(request) &&
          task.context.transferSender == message.transferSender &&
          task.context.transferOrdinal == message.transferOrdinal &&
          task.context.transferId == message.transferId,
    )) {
      _reject(request, message.transferId, 'invalid_state');
      return;
    }
    if (_resolve(request.sessionId) != null) {
      return;
    }
    var record = _terminalFacts
        .where(
          (r) =>
              r.original.hasSameGrantAs(request) &&
              r.message.transferSender == message.transferSender &&
              r.message.transferId == message.transferId,
        )
        .firstOrNull;
    if (record != null && !_sameMetadata(record.message, message)) {
      _reject(request, message.transferId, 'context_mismatch');
      return;
    }
    if (record?.retiring == true ||
        record?.detached == true ||
        _incomingLedger?.slots.any(
              (s) =>
                  s.operation.sender == message.transferSender &&
                  s.operation.ordinal == message.transferOrdinal &&
                  s.value.retirement != null,
            ) ==
            true) {
      _reject(request, message.transferId, 'invalid_state');
      return;
    }
    if (record == null) {
      if (_terminalFacts.length >= FileTransferChannel.maxTransfers * 2) {
        _reject(request, message.transferId, 'resource_limit');
        return;
      }
      // A mismatched control must not create a tombstone over an existing file.
      final incoming = _received
          .where(
            (e) =>
                e._authority.hasSameGrantAs(request) &&
                e._authority.sender == message.transferSender &&
                e.offer.transferId == message.transferId,
          )
          .firstOrNull;
      final outgoing = _outgoing
          .where(
            (t) =>
                t.context.authorization.hasSameGrantAs(request) &&
                t.context.transferSender == message.transferSender &&
                t.context.transferId == message.transferId,
          )
          .firstOrNull;
      if ((incoming != null && !_sameMetadata(message, incoming.offer)) ||
          (outgoing != null &&
              !_sameMetadata(message, outgoing.context.request))) {
        _reject(request, message.transferId, 'context_mismatch');
        return;
      }
      if (message.transferSender == request.sender) {
        try {
          _admitIncomingTermination(request, message);
        } catch (error) {
          _reject(
            request,
            message.transferId,
            FileTransferChannel._code(error),
          );
          return;
        }
      } else if (outgoing == null) {
        // The peer cannot reserve or terminate an unknown locally produced
        // ordinal. It can only refer to an exact retained local owner.
        _reject(request, message.transferId, 'invalid_state');
        return;
      }
      record = _FileTermination(request, message);
      _terminalFacts.add(record);
      // Request is already authenticated/current at dispatch. Persist the
      // terminal fact and stop a matching native owner before any further await.
      _settleTermination(record);
    }
    record.replyRequest = request;
    _respondTermination(record);
  }

  Future<FileMessage> _settleTermination(_FileTermination record) {
    if (record.settling != null && !record.settlingFailed) {
      return record.settling!;
    }
    record.settlingFailed = false;
    final pending = record.settling = _terminateNative(record);
    unawaited(
      pending.then<void>(
        (message) {
          if (identical(record.settling, pending)) {
            record.settled = message;
            _flushOutgoingRetirements();
          }
        },
        onError: (Object e, StackTrace s) {
          if (identical(record.settling, pending)) record.settlingFailed = true;
        },
      ),
    );
    return pending;
  }

  Future<FileMessage> _terminateNative(_FileTermination record) async {
    final message = record.message, request = record.original;
    final incoming = record.locallyInitiated
        ? request is VerifiedSessionMessage
        : message.transferSender == request.sender;
    if (incoming) {
      final entry = _received
          .where(
            (e) =>
                e._authority.hasSameGrantAs(request) &&
                e._authority.sender == message.transferSender &&
                e.offer.transferId == message.transferId,
          )
          .firstOrNull;
      if (entry != null) {
        if (!_sameMetadata(message, entry.offer)) {
          throw const FileProtocolFailure('context_mismatch');
        }
        entry._cancelled = true;
        entry._epoch++;
        entry._queued = null;
        final state = await entry.task?.cancel();
        if (state == ReceiveStopState.committing ||
            state == ReceiveStopState.committed) {
          await entry._dataIdle;
        }
        _launch(_cleanupDirectory(entry));
        if (entry.task?.receipt case final receipt?) {
          return _complete(entry, receipt);
        }
        if (state != null && state != ReceiveStopState.cancelled) {
          throw const FileProtocolFailure('io_failure');
        }
      }
    } else {
      final task = _outgoing
          .where(
            (t) =>
                t.context.authorization.hasSameGrantAs(request) &&
                t.context.transferSender == message.transferSender &&
                t.context.transferId == message.transferId,
          )
          .firstOrNull;
      if (task != null) {
        if (!_sameMetadata(message, task.context.request)) {
          throw const FileProtocolFailure('context_mismatch');
        }
        await task.cancel(notifyPeer: false);
      }
    }
    return FileCancelled(transferId: message.transferId);
  }

  void _respondTermination(_FileTermination record) {
    if (_closed || record.replying || record.retiring || record.detached) {
      return;
    }
    final request = record.replyRequest!;
    record.replying = true;
    final nonce = ++record.replyNonce;
    final epoch = _transportEpoch;
    final changed = _nextTransportChange.future;
    _launch(
      record.replyWork = () async {
        try {
          await Future.any<void>([
            () async {
              await registry.verify(request);
              final response = await _settleTermination(record);
              if (_closed ||
                  record.detached ||
                  nonce != record.replyNonce ||
                  !identical(record.replyRequest, request)) {
                return;
              }
              request.requireCurrent();
              await _queueReply(
                () {
                  if (_closed ||
                      record.detached ||
                      nonce != record.replyNonce ||
                      !identical(record.replyRequest, request)) {
                    return Future.value();
                  }
                  request.requireCurrent();
                  return transport.sendSignal(
                    request,
                    FileCodec.encode(response),
                  );
                },
                priority: true,
                allowSuspended: true,
              );
            }(),
            changed.then(
              (_) => throw const FileProtocolFailure('operation_stopped'),
            ),
          ]);
        } catch (error) {
          if (!_closed &&
              epoch == _transportEpoch &&
              identical(record.replyRequest, request)) {
            _reject(
              request,
              record.message.transferId,
              FileTransferChannel._code(error),
            );
          }
        } finally {
          record.replyNonce++;
          record.replying = false;
          if (!_closed &&
              !record.retiring &&
              !record.detached &&
              !identical(record.replyRequest, request)) {
            _respondTermination(record);
          }
        }
      }(),
    );
  }

  bool _replyRetainedTermination(
    VerifiedSessionMessage request,
    FileMessage message,
  ) {
    final record = _terminalFacts
        .where(
          (r) =>
              r.original.hasSameGrantAs(request) &&
              r.message.transferSender == request.sender &&
              r.message.transferId == message.transferId,
        )
        .firstOrNull;
    if (record == null) return false;
    if (record.retiring || record.detached) {
      _reject(request, message.transferId, 'invalid_state');
      return true;
    }
    if (!_sameMetadata(record.message, message)) {
      _reject(request, message.transferId, 'context_mismatch');
    } else {
      record.replyRequest = request;
      _respondTermination(record);
    }
    return true;
  }
}
