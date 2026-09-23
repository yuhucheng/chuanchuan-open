import 'dart:async';

import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import 'incoming_file_transfer.dart';
import 'outgoing_file_transfer.dart';
import 'receive_access.dart';
import 'receive_directories.dart';
import 'file_publication_order.dart';

part 'file_cancellation.dart';
part 'file_incoming_history.dart';
part 'file_incoming_retirement.dart';
part 'file_outgoing_retirement.dart';

/// An incoming queue entry is reserved before any asynchronous directory or
/// native work. Its terminal record stays owned for late packets and recovery.
final class ReceivedTransfer {
  ReceivedTransfer._(this._authority, this.offer);
  SessionAuthorization _authority;
  final FileOffer offer;
  IncomingFileTransfer? _task;
  IncomingFileTransfer? get task => _task;
  String? _failure;
  String? get failure => _failure;
  ReceiveDirectoryLease? _directory;
  Future<void>? _directoryCleanup, _localCancel;
  Future<void>? _dataIdle;
  Future<void>? _cancelPending, _pausePending;
  final _replyWork = <Future<void>>{};
  _IncomingRetirement? _retirement;
  Object? _cleanupFailure;
  Object? get cleanupFailure => _cleanupFailure ?? _task?.cleanupFailure;
  FileCancellation? _cancellation;
  Object? _notificationFailure;
  bool get cancellationPending => _cancellation?.pending ?? false;
  Object? get notificationFailure =>
      _notificationFailure ?? _cancellation?.failure;
  bool get canCancel =>
      !_cancelled && _failure == null && _task?.receipt == null;
  bool _cancelled = false, _paused = false, _busy = false;
  bool _cancelling = false, _pausing = false, _failureSent = false;
  VerifiedSessionSignal? _queued;
  _IncomingAdmission? _rebinding;
  int _epoch = 0;
}

/// Owns a file-only operation port. It never attaches to the media port, owns
/// arbitrary paths, or releases selected-file tokens. Owned directory leases
/// remain with their receiving file until cleanup; a borrowed provider must
/// instead retain its directory until the channel has closed.
///
/// Work is bounded: 64 retained entries per direction, one admitted data message
/// plus one waiting message per incoming file, independent pause/cancel lanes,
/// and one rejection reply. Both directions use ordinal/attempt ledgers;
/// authenticated retirement releases cleaned owners into bounded value history.
/// Reaching a budget fails closed instead of evicting resumable/terminal state.
final class FileTransferChannel {
  FileTransferChannel({
    required this.registry,
    required this.transport,
    required this.access,
    Future<ReceiveDirectory> Function()? directory,
    Future<ReceiveDirectoryLease> Function()? acquireDirectory,
    this.onChanged,
  }) : _acquireDirectory =
           acquireDirectory ??
           (() async => ReceiveDirectoryLease.borrowed(await directory!())) {
    if ((directory == null) == (acquireDirectory == null)) {
      throw ArgumentError('Provide exactly one directory provider.');
    }
    transport.attachReceiver(
      onRequest: _request,
      resolveSession: _resolve,
      onSignal: _signal,
    );
  }

  static const maxTransfers = 64;
  final GrantRegistry registry;
  final SessionTransport transport;
  final ReceiveAccess access;
  final Future<ReceiveDirectoryLease> Function() _acquireDirectory;
  final void Function()? onChanged;
  final _received = <ReceivedTransfer>[];
  final _outgoing = <OutgoingFileTransfer>[];
  FileTransferLedger<OutgoingFileTransfer>? _outgoingLedger;
  SessionAuthorization? _outgoingAuthority;
  final _outgoingBoundEpoch = <OutgoingFileTransfer, int>{};
  final _outgoingRetirements = <OutgoingFileTransfer, FileOutgoingRetirement>{};
  final _retirementRequested = <OutgoingFileTransfer>{};
  final _sendHistory = <SentFileHistory>[];
  List<SentFileHistory> get sendHistory => List.unmodifiable(_sendHistory);
  FileTransferLedger<_IncomingRecord>? _incomingLedger;
  SessionAuthorization? _incomingAuthority;
  final _heldAdmissions = <String, _IncomingAdmission>{};
  final _incomingRetirements = <int, _IncomingRetirement>{};
  final _receiveHistory = <ReceivedFileHistory>[];
  List<ReceivedFileHistory> get receiveHistory =>
      List.unmodifiable(_receiveHistory);
  late final _publicationOrder = FilePublicationOrder(
    onAdvanced: _flushCancellations,
  );

  /// Process-local allocation for this original connection. It survives
  /// physical recovery and never reuses a retired ordinal.
  FilePublication reserveOutgoing() {
    if (_closed) {
      throw const FileProtocolFailure('resource_limit');
    }
    return _publicationOrder.reserve();
  }

  final _work = <Future<void>>{};
  final _replies = <_ReplyWrite>[];
  _ReplyWrite? _sending;
  bool _draining = false;
  List<ReceivedTransfer> get received => List.unmodifiable(_received);
  List<OutgoingFileTransfer> get outgoing => List.unmodifiable(_outgoing);
  bool _closed = false, _rejecting = false;
  Future<void>? _closing;
  bool _suspended = false;
  bool _controlReady = true;
  int _transportEpoch = 0;
  Future<void>? _suspending;
  Completer<void> _transportStopped = Completer<void>();
  final _heldRequests = <String, VerifiedSessionMessage>{};
  final _heldTerminal = <String, FileMessage>{};
  final _cancellations = <FileCancellation>[];
  final _terminalFacts = <_FileTermination>[];
  int? _flushingCancellations;
  Completer<void> _nextTransportChange = Completer<void>();

  /// Synchronous native stop intent must precede grant.suspend(). Retain the
  /// original owners and directories until a fresh operation rebinds them.
  Future<void> suspendTransport() {
    if (_closed) return Future.value();
    _transportEpoch++;
    for (final record in _outgoingRetirements.values) {
      record._attempt?.stop();
    }
    for (final job in _incomingRetirements.values) {
      if (!job.stopped.isCompleted) job.stopped.complete();
    }
    _controlReady = false;
    _publicationOrder.suspend();
    _nextTransportChange.complete();
    _nextTransportChange = Completer<void>();
    _heldRequests.clear();
    _heldAdmissions.clear();
    _heldTerminal.clear();
    for (final cancellation in _cancellations) {
      cancellation._request = null;
    }
    if (_suspended) return _suspending ?? Future.value();
    _suspended = true;
    _transportStopped.complete();
    _discardReplies();
    final stopping = <Future<void>>[];
    for (final task in _outgoing) {
      if (task.receipt == null &&
          task.phase != OutgoingFilePhase.cancelled &&
          task.phase != OutgoingFilePhase.cancelling &&
          task.phase != OutgoingFilePhase.failed) {
        stopping.add(task.pause(notifyPeer: false).then<void>((_) {}));
      }
    }
    for (final entry in _received) {
      if (_terminal(entry)) continue;
      entry._paused = true;
      entry._pausing = true;
      entry._epoch++;
      entry._queued = null;
      // Calling pause is deliberately outside the async wait below.
      final paused = entry.task?.pause();
      final dataIdle = entry._dataIdle;
      stopping.add(() async {
        try {
          await paused;
          await dataIdle;
        } catch (error) {
          if (!entry._cancelled && entry.task?.receipt == null) {
            entry._failure = _code(error);
            await entry.task?.cancel();
          }
        } finally {
          entry._pausing = false;
          if (_terminal(entry)) _launch(_cleanupDirectory(entry));
        }
      }());
    }
    final result = _suspending = Future.wait(stopping).then<void>((_) {});
    _launch(result);
    return result;
  }

  /// May be called as soon as the new connection publishes. New authenticated
  /// requests wait in a bounded queue until old native I/O has settled.
  Future<void> resumeTransport() async {
    if (_closed || !_suspended) return;
    _controlReady = true;
    _publicationOrder.resume();
    _flushCancellations();
    _flushOutgoingRetirements();
    final epoch = _transportEpoch;
    await _suspending;
    if (_closed || !_suspended || epoch != _transportEpoch) return;
    _suspended = false;
    _transportStopped = Completer<void>();
    final requests = List.of(_heldRequests.values);
    _heldRequests.clear();
    for (final request in requests) {
      final admission = _heldAdmissions.remove(request.sessionId);
      if (admission != null) {
        _dispatchIncoming(
          admission,
          terminal: _heldTerminal.remove(request.sessionId),
        );
      }
    }
    _heldTerminal.clear();
    _flushCancellations();
    onChanged?.call();
  }

  void _discardReplies() {
    for (final job in [..._replies, ?_sending]) {
      if (!job.done.isCompleted) {
        job.done.completeError(const FileProtocolFailure('operation_stopped'));
      }
    }
    _replies.clear();
    _sending = null;
    _draining = false;
  }

  /// Local cancellation does not wait for a clock check or a network write to
  /// dispatch native stop. Reply and cleanup failures remain independently owned.
  Future<void> cancelReceived(ReceivedTransfer entry) {
    if (_closed || !_received.contains(entry) || entry._retirement != null) {
      return Future.error(const FileProtocolFailure('invalid_state'));
    }
    if (entry.task?.receipt != null) return Future.value();
    if (entry._localCancel != null) return entry._localCancel!;
    entry._cancelled = true;
    entry._epoch++;
    entry._queued = null;
    final stopping = entry.task?.cancel();
    try {
      entry._cancellation = _queueCancellation(
        entry._authority,
        entry.offer,
        entry._authority.sender,
      );
      entry._notificationFailure = null;
    } catch (error) {
      // Admission of the peer notification cannot abandon local stop/cleanup.
      entry._notificationFailure = error;
    }
    final authority = entry._authority;
    final result =
        () async {
          try {
            await stopping;
            _launch(
              _reply(
                entry,
                authority,
                FileCancel(transferId: entry.offer.transferId),
              ),
            );
          } catch (error) {
            entry._cleanupFailure = error;
            rethrow;
          } finally {
            _launch(_cleanupDirectory(entry));
          }
        }().whenComplete(() {
          entry._localCancel = null;
        });
    entry._localCancel = result;
    _launch(result);
    return result;
  }

  bool _terminal(ReceivedTransfer entry) =>
      _closed ||
      entry._cancelled ||
      entry._failure != null ||
      entry.task?.receipt != null ||
      entry.task?.phase == IncomingFilePhase.cancelled ||
      entry.task?.phase == IncomingFilePhase.failed ||
      entry.task?.phase == IncomingFilePhase.stopping;

  Future<void> retryCleanup(ReceivedTransfer entry) {
    if (!_received.contains(entry) || !_terminal(entry)) {
      return Future.error(const FileProtocolFailure('invalid_state'));
    }
    final retry = _cleanupDirectory(entry);
    _launch(retry);
    return retry;
  }

  Future<void> _cleanupDirectory(ReceivedTransfer entry) {
    if (!_terminal(entry)) return Future.value();
    return entry._directoryCleanup ??=
        () async {
          try {
            await entry.task?.cleanup();
            await entry._directory?.release();
            entry._directory = null;
            entry._cleanupFailure = null;
          } catch (error) {
            entry._cleanupFailure = error;
            rethrow;
          }
        }().whenComplete(() {
          entry._directoryCleanup = null;
        });
  }

  /// Call before start(), so even an immediate acceptance resolves to the exact
  /// sealed local authority. The caller continues owning its selected token.
  void trackOutgoing(OutgoingFileTransfer task) {
    final authority = task.context.authorization;
    if (_terminalFacts.any(
      (r) =>
          r.original.hasSameGrantAs(authority) &&
          r.message.transferSender == task.context.transferSender &&
          r.message.transferId == task.context.transferId,
    )) {
      throw const FileProtocolFailure('cancelled');
    }
    if (_closed ||
        !identical(task.transport, transport) ||
        authority is! LocalSessionRequest ||
        _outgoing.length >= maxTransfers) {
      throw const FileProtocolFailure('resource_limit');
    }
    authority.requireCurrent();
    _admitOutgoing(task);
    _outgoing.add(task);
  }

  /// Reserve the fresh operation ID before the owner changes its context.
  Future<FileComplete> resumeOutgoing(
    OutgoingFileTransfer task,
    LocalSessionRequest request,
  ) {
    try {
      final ticket = _observeOutgoing(task, request);
      return task.resume(
        request,
        onRebind: (_) {
          if (_closed || _retirementRequested.contains(task)) {
            throw const FileProtocolFailure('operation_stopped');
          }
          _outgoingLedger!.bindAttempt(ticket);
          _outgoingBoundEpoch[task] = _transportEpoch;
        },
      );
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  /// Request retirement after native cleanup and authenticated peer completion
  /// or termination. Ledger watermarks reject old packets after owner release.
  Future<void> forgetOutgoing(OutgoingFileTransfer task) async {
    if (!_outgoing.contains(task)) return;
    _retirementRequested.add(task);
    if (!canRetireOutgoing(task)) {
      await task.close();
      if (!_closed) cancelOutgoing(task);
    }
    _flushOutgoingRetirements();
  }

  SessionAuthorization? _resolve(String id) {
    if (_closed) return null;
    for (final record in _outgoingRetirements.values) {
      final request = record._attempt?.request;
      if (request?.sessionId == id) return request;
    }
    for (final cancellation in _cancellations) {
      if (cancellation._request?.sessionId == id) return cancellation._request;
    }
    SessionAuthorization? found = _heldRequests[id];
    for (final entry in _received) {
      if (entry._authority.sessionId == id) {
        if (found != null && !identical(found, entry._authority)) return null;
        found = entry._authority;
      }
    }
    for (final task in _outgoing) {
      if (task.context.authorization.sessionId == id) {
        if (found != null) return null;
        found = task.context.authorization;
      }
    }
    return found;
  }

  void _launch(Future<void> future) {
    // Install an error observer immediately; failed cleanup remains on the task.
    late final Future<void> observed;
    observed = future
        .then<void>((_) {}, onError: (Object e, StackTrace s) {})
        .whenComplete(() {
          _work.remove(observed);
          if (!_closed) onChanged?.call();
        });
    _work.add(observed);
  }

  Future<void> get whenIdle async {
    while (_work.isNotEmpty) {
      await Future.wait(List.of(_work));
    }
  }

  void _request(VerifiedSessionMessage request) {
    if (_closed || request.operation != SessionOperation.file) return;
    FileMessage message;
    late final FileOperationId operation;
    try {
      request.requireCurrent();
      message = FileCodec.decode(request.body);
    } catch (_) {
      return; // No validated transfer identifier for a reply.
    }
    if (message is FileTerminate) {
      _receiveTermination(request, message);
      return;
    }
    if (message is FileRetire) {
      _receiveRetirement(request, message);
      return;
    }
    // Validate the canonical data identity before retaining a resolver, replying
    // from terminal history, or touching a directory. Authentication alone does
    // not establish that its producer/ordinal agrees with the file metadata.
    try {
      final ordinal = switch (message) {
        FileOffer(:final transferOrdinal) ||
        FileResume(:final transferOrdinal) => transferOrdinal,
        _ => throw const FileProtocolFailure('invalid_state'),
      };
      operation = FileOperationId.parse(request.sessionId);
      if (operation.sender != request.sender || operation.ordinal != ordinal) {
        throw const FileProtocolFailure('context_mismatch');
      }
    } catch (error) {
      _reject(request, message.transferId, _code(error));
      return;
    }
    if (_resolve(request.sessionId) != null) {
      return;
    }
    try {
      final admission = _admitIncoming(request, message, operation);
      if (admission == null) return;
      if (_suspended) {
        if (admission.ticket == null) admission.entry._paused = true;
        if (_heldRequests.length >= maxTransfers) {
          if (admission.ticket == null) {
            admission.entry._failure = 'resource_limit';
          }
          throw const FileProtocolFailure('resource_limit');
        }
        _heldRequests[request.sessionId] = request;
        _heldAdmissions[request.sessionId] = admission;
        return;
      }
      _dispatchIncoming(admission);
    } catch (error) {
      _reject(request, message.transferId, _code(error));
    }
  }

  Future<FileMessage> _startIncoming(
    ReceivedTransfer entry,
    VerifiedSessionMessage request,
  ) async {
    final epoch = entry._epoch;
    void current() {
      if (_closed ||
          _suspended ||
          entry._epoch != epoch ||
          entry._cancelled ||
          entry._failure != null) {
        throw const FileProtocolFailure('operation_stopped');
      }
      request.requireCurrent();
    }

    final context = FileCodec.decode(request.body) is FileResume
        ? await FileTransferContext.fromUnstartedResume(registry, request)
        : await FileTransferContext.fromRequest(registry, request);
    current();
    final target = entry._directory ?? await _acquireDirectory();
    entry._directory = target;
    current();
    context.requireCurrent();
    final task = IncomingFileTransfer(
      context: context,
      access: access,
      directory: target.directory,
    );
    entry._task = task;
    return task.start();
  }

  void _data(
    ReceivedTransfer entry,
    Future<FileMessage?> Function() action, {
    SessionAuthorization? replyAuthority,
  }) {
    entry._busy = true;
    final epoch = entry._epoch;
    final authority = replyAuthority ?? entry._authority;
    final pending = () async {
      try {
        final reply = await action();
        if (reply != null &&
            !_closed &&
            (entry.task?.receipt != null ||
                (entry._epoch == epoch &&
                    !entry._cancelled &&
                    !entry._paused))) {
          await _reply(entry, authority, reply);
        }
      } catch (error) {
        if (!_closed &&
            entry._epoch == epoch &&
            !entry._cancelled &&
            !entry._paused &&
            entry.task?.receipt == null) {
          await _fail(entry, authority, error);
        }
      } finally {
        entry._busy = false;
        final queued = entry._queued;
        entry._queued = null;
        if (queued != null) _signal(queued);
        if (_terminal(entry)) _launch(_cleanupDirectory(entry));
      }
    }();
    entry._dataIdle = pending;
    _launch(pending);
    if (!_closed) onChanged?.call();
  }

  void _signal(VerifiedSessionSignal signal) {
    if (_closed) return;
    final authority = signal.authorization;
    if (_outgoingRetirementReply(signal)) return;
    if (_cancellationReply(signal)) return;
    if (!identical(_resolve(authority.sessionId), authority)) return;
    if (identical(_heldRequests[authority.sessionId], authority)) {
      if (_heldAdmissions[authority.sessionId]?.entry._retirement != null) {
        return;
      }
      try {
        signal.requireCurrent();
        final message = FileCodec.decode(signal.body);
        final request = FileCodec.decode(
          _heldRequests[authority.sessionId]!.body,
        );
        if (message.transferId == request.transferId &&
            (message is FileCancel ||
                message is FileCancelled ||
                message is FileFailed)) {
          // openSignal already authenticated this terminal fact. Preserve it
          // without admitting data or reopening a native scope before settle.
          _heldTerminal.putIfAbsent(authority.sessionId, () => message);
          _rememberHeldCancellation(
            _heldRequests[authority.sessionId]!,
            request,
            message,
          );
        }
      } catch (_) {
        /* No data is admitted on a suspended channel. */
      }
      return;
    }
    for (final task in _outgoing) {
      if (identical(task.context.authorization, authority)) {
        _launch(task.handleSignal(signal));
        return;
      }
    }
    final entry = _received.firstWhere(
      (e) => identical(e._authority, authority),
    );
    if (entry._retirement != null) return;
    FileMessage message;
    try {
      signal.requireCurrent();
      message = FileCodec.decode(signal.body);
      if (message.transferId != entry.offer.transferId) {
        throw const FileProtocolFailure('context_mismatch');
      }
      if (message is FilePaused && message.offset > entry.offer.size) {
        throw const FileProtocolFailure('invalid_range');
      }
    } catch (error) {
      _launch(_fail(entry, authority, error));
      return;
    }
    if (message is FileCancel ||
        message is FileCancelled ||
        message is FileFailed) {
      if (entry._cancelling) return;
      entry._cancelling = true;
      _launch(
        _cancel(
          entry,
          authority,
          reply: message is FileCancel,
          failure: message is FileFailed ? message.code : null,
        ),
      );
    } else if (entry._rebinding != null) {
      // The retained resolver has control authority only while native rebind
      // runs. Old data must never reach the owner's fresh protocol context.
      return;
    } else if (message is FilePause || message is FilePaused) {
      if (entry._pausing || entry._cancelled || entry._paused) return;
      entry._pausing = true;
      _launch(_pause(entry, authority, reply: message is FilePause));
    } else {
      if (entry._cancelled ||
          entry._paused ||
          entry._failure != null ||
          entry.task?.receipt != null) {
        return;
      }
      if (entry._busy) {
        if (entry._queued == null) {
          entry._queued = signal;
        } else {
          _launch(
            _fail(
              entry,
              authority,
              const FileProtocolFailure('resource_limit'),
            ),
          );
        }
        return;
      }
      final task = entry.task;
      if (task == null) return;
      _data(entry, () async {
        return switch (message) {
          FileChunk() => await task.append(signal),
          FileFinish() => await task.finish(signal),
          FileResumeAccept() =>
            await task.acceptResume(signal).then((_) => null),
          _ => throw const FileProtocolFailure('direction_denied'),
        };
      });
    }
  }

  void _rememberHeldCancellation(
    VerifiedSessionMessage authority,
    FileMessage request,
    FileMessage terminal,
  ) {
    if (request is! FileOffer && request is! FileResume) {
      return;
    }
    final offer = request is FileOffer
        ? request
        : FileOffer(
            transferId: request.transferId,
            transferOrdinal: (request as FileResume).transferOrdinal,
            name: request.name,
            size: request.size,
            sha256: request.sha256,
            chunkBytes: request.chunkBytes,
          );
    var entry = _received
        .where(
          (e) =>
              e.offer.transferId == offer.transferId &&
              e._authority.hasSameGrantAs(authority) &&
              e._authority.sender == authority.sender,
        )
        .firstOrNull;
    if (entry == null) {
      return; // Admission already retained every held file before any await.
    } else if (entry.offer.transferOrdinal != offer.transferOrdinal ||
        entry.offer.name != offer.name ||
        entry.offer.size != offer.size ||
        entry.offer.sha256 != offer.sha256 ||
        entry.offer.chunkBytes != offer.chunkBytes) {
      return;
    }
    if (entry.task?.receipt != null || entry._cancelled) return;
    // This signal was authenticated before dispatch. Native cancellation and
    // the retained terminal fact must survive another loss before any reply.
    entry._cancelled = true;
    entry._failure = terminal is FileFailed ? terminal.code : null;
    entry._epoch++;
    entry._queued = null;
    final stopping = entry.task?.cancel();
    if (stopping != null) _launch(stopping.then<void>((_) {}));
    _launch(_cleanupDirectory(entry));
  }

  Future<void> _cancel(
    ReceivedTransfer entry,
    SessionAuthorization authority, {
    required bool reply,
    String? failure,
  }) {
    if (entry._retirement != null) return Future.value();
    final work = _cancelWork(entry, authority, reply: reply, failure: failure);
    entry._cancelPending = work;
    return work.whenComplete(() {
      if (identical(entry._cancelPending, work)) entry._cancelPending = null;
    });
  }

  Future<void> _cancelWork(
    ReceivedTransfer entry,
    SessionAuthorization authority, {
    required bool reply,
    String? failure,
  }) async {
    try {
      await registry.verify(authority);
      if (_closed || !identical(entry._authority, authority)) return;
      entry._cancelled = true;
      entry._failure = failure;
      entry._epoch++;
      entry._queued = null;
      final state = await entry.task?.cancel();
      if (entry.task?.receipt case final receipt?) {
        if (reply) await _reply(entry, authority, _complete(entry, receipt));
      } else if (reply &&
          (state == null || state == ReceiveStopState.cancelled)) {
        await _reply(
          entry,
          authority,
          FileCancelled(transferId: entry.offer.transferId),
        );
      }
    } finally {
      entry._cancelling = false;
      if (_terminal(entry)) _launch(_cleanupDirectory(entry));
    }
  }

  Future<void> _pause(
    ReceivedTransfer entry,
    SessionAuthorization authority, {
    required bool reply,
  }) {
    if (entry._retirement != null) return Future.value();
    final work = _pauseWork(entry, authority, reply: reply);
    entry._pausePending = work;
    return work.whenComplete(() {
      if (identical(entry._pausePending, work)) entry._pausePending = null;
    });
  }

  Future<void> _pauseWork(
    ReceivedTransfer entry,
    SessionAuthorization authority, {
    required bool reply,
  }) async {
    final transportEpoch = _transportEpoch;
    try {
      await registry.verify(authority);
      if (_closed ||
          transportEpoch != _transportEpoch ||
          entry._cancelled ||
          !identical(entry._authority, authority)) {
        return;
      }
      entry._paused = true;
      entry._epoch++;
      entry._queued = null;
      final checkpoint = await entry.task?.pause();
      if (entry._cancelled ||
          transportEpoch != _transportEpoch ||
          !identical(entry._authority, authority)) {
        return;
      }
      if (entry.task?.receipt case final receipt?) {
        if (reply) await _reply(entry, authority, _complete(entry, receipt));
      } else if (checkpoint == null) {
        // No retained native file/prefix exists. A pause acknowledgement would
        // promise recovery that this task cannot perform.
        await _cancel(entry, authority, reply: reply);
      } else if (reply) {
        await _reply(
          entry,
          authority,
          FilePaused(
            transferId: entry.offer.transferId,
            offset: checkpoint.offset,
          ),
        );
      }
    } catch (error) {
      if (!entry._cancelled &&
          transportEpoch == _transportEpoch &&
          identical(entry._authority, authority)) {
        await _fail(entry, authority, error);
      }
    } finally {
      if (transportEpoch == _transportEpoch) entry._pausing = false;
    }
  }

  FileComplete _complete(ReceivedTransfer entry, ReceiveReceipt receipt) =>
      FileComplete(
        transferId: entry.offer.transferId,
        actualName: receipt.name,
        size: receipt.size,
        sha256: receipt.sha256,
      );

  Future<void> _fail(
    ReceivedTransfer entry,
    SessionAuthorization authority,
    Object error,
  ) async {
    if (_closed ||
        _suspended ||
        !identical(entry._authority, authority) ||
        entry._failureSent ||
        entry._cancelled ||
        entry.task?.receipt != null) {
      return;
    }
    entry._failureSent = true;
    entry._failure = _code(error);
    entry._epoch++;
    entry._queued = null;
    // Native stop is dispatched before the network notification await.
    final stopping = entry.task?.cancel();
    if (stopping != null) _launch(stopping.then<void>((_) {}));
    _launch(_cleanupDirectory(entry));
    await _reply(
      entry,
      authority,
      FileFailed(transferId: entry.offer.transferId, code: entry._failure!),
    );
  }

  static String _code(Object error) {
    final code = switch (error) {
      ReceiveAccessFailure(:final code) ||
      FileProtocolFailure(:final code) => code,
      _ => 'io_failure',
    };
    try {
      FileFailed(transferId: '0' * 32, code: code);
      return code;
    } catch (_) {
      return 'io_failure';
    }
  }

  Future<void> _reply(
    ReceivedTransfer entry,
    SessionAuthorization authority,
    FileMessage message,
  ) {
    late final Future<void> work;
    work = _writeReply(
      entry,
      authority,
      message,
    ).whenComplete(() => entry._replyWork.remove(work));
    entry._replyWork.add(work);
    return work;
  }

  Future<void> _writeReply(
    ReceivedTransfer entry,
    SessionAuthorization authority,
    FileMessage message,
  ) async {
    final epoch = entry._epoch;
    final stopped = _transportStopped.future;
    await Future.any<void>([
      registry.verify(authority),
      stopped.then<void>(
        (_) => throw const FileProtocolFailure('operation_stopped'),
      ),
    ]);
    final data =
        message is FileAccept ||
        message is FileAck ||
        message is FileResumeState;
    await _queueReply(() {
      if (_closed || !identical(entry._authority, authority)) {
        return Future.value();
      }
      authority.requireCurrent();
      if (data &&
          (entry._epoch != epoch ||
              entry._cancelled ||
              entry._paused ||
              entry._failure != null)) {
        return Future.value();
      }
      if (message is FilePaused &&
          (entry._epoch != epoch ||
              entry._cancelled ||
              entry._failure != null)) {
        return Future.value();
      }
      return transport.sendSignal(authority, FileCodec.encode(message));
    }, priority: !data);
  }

  Future<void> _queueReply(
    Future<void> Function() write, {
    required bool priority,
    bool allowSuspended = false,
  }) {
    if (_closed || (_suspended && !allowSuspended)) return Future.value();
    // One data response, pause, cancel and failure per retained entry, plus the
    // single admission rejection. No transport's eight-message queue is flooded.
    if (_replies.length >= maxTransfers * 4 + 1) {
      return Future.error(const FileProtocolFailure('resource_limit'));
    }
    final job = _ReplyWrite(write, priority);
    _replies.add(job);
    if (!_draining) unawaited(_drainReplies());
    return job.done.future;
  }

  Future<void> _drainReplies() async {
    final epoch = _transportEpoch;
    _draining = true;
    try {
      while (!_closed && epoch == _transportEpoch && _replies.isNotEmpty) {
        final urgent = _replies.indexWhere((job) => job.priority);
        final job = _sending = _replies.removeAt(urgent < 0 ? 0 : urgent);
        try {
          await job.write();
          if (!job.done.isCompleted) job.done.complete();
        } catch (error, stack) {
          if (!job.done.isCompleted) job.done.completeError(error, stack);
        } finally {
          if (identical(_sending, job)) _sending = null;
        }
      }
    } finally {
      if (epoch == _transportEpoch) _draining = false;
    }
  }

  void _reject(VerifiedSessionMessage request, String id, String code) {
    if (_rejecting) return;
    _rejecting = true;
    final changed = _nextTransportChange.future;
    _launch(() async {
      try {
        await Future.any<void>([
          registry.verify(request),
          changed.then(
            (_) => throw const FileProtocolFailure('operation_stopped'),
          ),
        ]);
        if (_closed) return;
        request.requireCurrent();
        await _queueReply(
          () {
            request.requireCurrent();
            return transport.sendSignal(
              request,
              FileCodec.encode(FileRejected(transferId: id, code: code)),
            );
          },
          priority: true,
          allowSuspended: true,
        );
      } finally {
        _rejecting = false;
      }
    }());
  }

  Future<void> close() {
    if (!_closed) {
      _closed = true;
      for (final record in _outgoingRetirements.values) {
        record._attempt?.stop();
      }
      for (final job in _incomingRetirements.values) {
        if (!job.stopped.isCompleted) job.stopped.complete();
      }
      _publicationOrder.close();
      _nextTransportChange.complete();
      _heldRequests.clear();
      _heldAdmissions.clear();
      _heldTerminal.clear();
      for (final cancellation in _cancellations) {
        cancellation._stopped = true;
      }
      if (!_transportStopped.isCompleted) _transportStopped.complete();
      transport.detachReceiver();
      for (final reply in [?_sending, ..._replies]) {
        if (!reply.done.isCompleted) reply.done.complete();
      }
      _replies.clear();
      for (final entry in _received) {
        entry._cancelled = true;
        entry._epoch++;
        entry._queued = null;
      }
    }
    return _closing ??= _close().whenComplete(() {
      _closing = null;
    });
  }

  Future<void> _close() async {
    // Start every native stop before waiting for any one file or directory call.
    await Future.wait([
      for (final entry in _received)
        if (entry.task != null) entry.task!.close(),
      for (final task in _outgoing) task.close(),
    ]);
    await whenIdle;
    await Future.wait([
      for (final entry in _received) _cleanupDirectory(entry),
    ]);
  }
}

final class _ReplyWrite {
  _ReplyWrite(this.write, this.priority);
  final Future<void> Function() write;
  final bool priority;
  final done = Completer<void>();
}
