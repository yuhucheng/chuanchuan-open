import 'dart:async';

import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import 'source_access.dart';
import 'file_publication_order.dart';
import 'verified_file_source.dart';

enum OutgoingFilePhase {
  selected,
  verifying,
  awaitingAccept,
  sending,
  awaitingAck,
  awaitingComplete,
  paused,
  resuming,
  awaitingResumeState,
  cancelling,
  cancelled,
  failed,
  completed,
}

/// One file attempt with a single outstanding block and authenticated response.
/// The coordinator owns the file-only transport receiver and must register this
/// owner's context before start. Closing releases the native scope, not the
/// selection token. A paused source must remain owned until recovery rebinds it.
final class OutgoingFileTransfer {
  OutgoingFileTransfer({
    required this._source,
    required this.transport,
    this.publication,
    this.onChanged,
  }) {
    if (context.request is! FileOffer) {
      throw const FileProtocolFailure('invalid_state');
    }
    if (publication != null &&
        publication!.ordinal != context.transferOrdinal) {
      throw const FileProtocolFailure('context_mismatch');
    }
    _chunkBytes = context.chunkBytes;
    _invalidations = context.authorization.invalidated.listen((_) {
      if (_phase != OutgoingFilePhase.paused) _invalidate();
    }, onDone: _invalidate);
  }

  VerifiedFileSource _source;
  VerifiedFileSource get source => _source;
  VerifiedFileSource? _retiredSource;
  final SessionTransport transport;
  final FilePublication? publication;

  /// Coalesced phase notification, after the current transition has finished.
  final void Function()? onChanged;
  FileTransferContext get context => source.context;
  late final StreamSubscription<void> _invalidations;
  OutgoingFilePhase _currentPhase = OutgoingFilePhase.selected;
  bool _changeScheduled = false;
  OutgoingFilePhase get _phase => _currentPhase;
  set _phase(OutgoingFilePhase value) {
    _currentPhase = value;
    if (onChanged == null || _changeScheduled) return;
    _changeScheduled = true;
    scheduleMicrotask(() {
      _changeScheduled = false;
      onChanged?.call();
    });
  }

  OutgoingFilePhase get phase => _phase;
  FileComplete? _receipt;
  FileComplete? get receipt => _receipt;
  FileMessage? _peerTerminal;

  /// Only authenticated, context-checked peer terminal observations. Local
  /// errors, cancellation intent and request rejection never set this value.
  FileMessage? get peerTerminal => _receipt ?? _peerTerminal;
  bool get mayHaveCommitted =>
      _finishIssued || _resumeMayComplete || _receipt != null;
  int _sentOffset = 0, _acknowledgedOffset = 0, _epoch = 0;
  int get sentOffset => _sentOffset;
  int get acknowledgedOffset => _acknowledgedOffset;
  // Offered to the wire, distinct from read locally or send Future completed.
  int _issuedOffset = 0;
  int _emittedOffset = 0, _peerAckOffset = 0;
  int _resumeMinimum = 0, _resumeMaximum = 0;
  late int _chunkBytes;
  bool _resumeMayComplete = false;
  bool _peerPaused = false;
  bool get peerPaused => _phase == OutgoingFilePhase.paused && _peerPaused;
  bool _offerIssued = false, _finishIssued = false, _closed = false;
  bool _decodingData = false, _decodingControl = false;
  bool _cancelSent = false,
      _failureSent = false,
      _pauseSent = false,
      _peerCancelRequested = false,
      _peerPauseRequested = false;
  _ResponseSlot? _pending;
  Completer<void>? _decodeIdle;
  Future<FileComplete>? _running;
  Future<void>? _closing;
  bool _retiring = false;
  final _wireWork = <Future<void>>{};
  Future<SourceStopState>? _stopping;
  Object? _notificationFailure, _stopFailure;
  Object? get notificationFailure => _notificationFailure;
  Object? get stopFailure => _stopFailure;

  Future<FileComplete> start() => _running ??= _start();

  /// Continue this retained file under a fresh request from the original grant.
  /// The coordinator's resolver must follow [context] before any wire reply.
  Future<FileComplete> resume(
    LocalSessionRequest request, {
    void Function(FileTransferContext)? onRebind,
  }) {
    if (_closed || _retiring || _phase != OutgoingFilePhase.paused) {
      return Future.error(const FileProtocolFailure('invalid_state'));
    }
    final previous = _running;
    final epoch = ++_epoch;
    _peerPaused = false;
    _phase = OutgoingFilePhase.resuming;
    return _running = _resume(request, previous, epoch, onRebind);
  }

  Future<FileComplete> _resume(
    LocalSessionRequest request,
    Future<FileComplete>? previous,
    int epoch,
    void Function(FileTransferContext)? onRebind,
  ) async {
    var attempt = context;
    try {
      final stopped = await source.whenStopped;
      if (stopped != SourceStopState.paused) {
        throw const FileProtocolFailure('invalid_state');
      }
      if (previous != null) {
        await previous.then<void>((_) {}, onError: (Object e, StackTrace s) {});
      }
      await _decodeIdle?.future;
      // The old authorization is suspended; validate the fresh one instead.
      if (_epoch != epoch || _closed) {
        throw const FileProtocolFailure('operation_stopped');
      }
      await _closeRetired();
      final fresh = await context.resumeWith(request);
      if (_epoch != epoch || _closed) {
        throw const FileProtocolFailure('operation_stopped');
      }
      fresh.requireCurrent();
      onRebind?.call(fresh);
      _resumeMinimum = _peerAckOffset;
      _resumeMaximum = _emittedOffset;
      _resumeMayComplete =
          (_finishIssued || _resumeMayComplete) &&
          _resumeMaximum == context.size;
      _retiredSource = source;
      _source = VerifiedFileSource(
        access: source.access,
        file: source.file,
        context: fresh,
      );
      attempt = fresh;
      _offerIssued = false;
      _finishIssued = false;
      _cancelSent = _failureSent = _pauseSent = false;
      _peerCancelRequested = _peerPauseRequested = false;
      _notificationFailure = null;
      _phase = OutgoingFilePhase.verifying;
      await source.verify();
      _current(epoch);
      await _closeRetired();
      _current(epoch);
      final response = await _exchange(
        OutgoingFilePhase.awaitingResumeState,
        () {
          _current(epoch);
          return _publishRequest(request, epoch);
        },
      );
      _current(epoch);
      if (response is FileComplete) return _receipt!;
      final state = response as FileResumeState;
      await source.beginSend(
        offset: state.offset,
        prefixSha256: state.prefixSha256,
      );
      _current(epoch);
      final accept = FileResumeAccept(
        transferId: context.transferId,
        attemptId: state.attemptId,
        offset: state.offset,
        prefixSha256: state.prefixSha256,
      );
      await context.validateOutgoing(accept);
      _current(epoch);
      await _exchange(OutgoingFilePhase.resuming, () {
        _current(epoch);
        return _trackWire(
          () => transport.sendSignal(
            context.authorization,
            FileCodec.encode(accept),
          ),
        );
      }, localResult: accept);
      _current(epoch);
      _sentOffset = _issuedOffset = _acknowledgedOffset = _peerAckOffset =
          state.offset;
      _phase = OutgoingFilePhase.sending;
      return await _sendRemainder(epoch);
    } catch (error, stack) {
      return _attemptFailure(error, stack, epoch, attempt);
    }
  }

  void _current(int epoch) {
    if (_epoch != epoch ||
        _closed ||
        _phase == OutgoingFilePhase.paused ||
        _phase == OutgoingFilePhase.cancelling ||
        _phase == OutgoingFilePhase.cancelled ||
        _phase == OutgoingFilePhase.failed) {
      throw const FileProtocolFailure('operation_stopped');
    }
    context.requireCurrent();
  }

  Future<FileComplete> _start() async {
    final epoch = _epoch;
    final attempt = context;
    try {
      _current(epoch);
      _phase = OutgoingFilePhase.verifying;
      await source.verify();
      _current(epoch);
      final accept = await _exchange(OutgoingFilePhase.awaitingAccept, () {
        _current(epoch);
        return _publishRequest(
          context.authorization as LocalSessionRequest,
          epoch,
        );
      }) as FileAccept;
      _current(epoch);
      _phase = OutgoingFilePhase.sending;
      _chunkBytes = accept.acceptedChunkBytes;
      await source.beginSend();
      _current(epoch);
      return await _sendRemainder(epoch);
    } catch (error, stack) {
      return _attemptFailure(error, stack, epoch, attempt);
    }
  }

  Future<void> _publishRequest(LocalSessionRequest request, int epoch) {
    Future<void> write() {
      _current(epoch);
      _offerIssued = true;
      return _trackWire(() => transport.sendRequest(request));
    }

    return publication?.publish(write, stopped: _pending!.stopped.future) ??
        write();
  }

  FileComplete _attemptFailure(
    Object error,
    StackTrace stack,
    int epoch,
    FileTransferContext attempt,
  ) {
    if (_receipt != null && identical(context, attempt)) return _receipt!;
    if (_epoch == epoch &&
        _phase != OutgoingFilePhase.paused &&
        _phase != OutgoingFilePhase.cancelling &&
        _phase != OutgoingFilePhase.cancelled) {
      _fail(error, stack);
    }
    Error.throwWithStackTrace(error, stack);
  }

  Future<FileComplete> _sendRemainder(int epoch) async {
    final attempt = context;
    while (_acknowledgedOffset < context.size) {
      final bytes = await source.readNext(maxBytes: _chunkBytes);
      _current(epoch);
      if (bytes == null) throw const FileProtocolFailure('source_incomplete');
      final end = _acknowledgedOffset + bytes.length;
      final chunk = FileChunk(
        transferId: context.transferId,
        offset: _acknowledgedOffset,
        data: bytes,
      );
      await context.validateOutgoing(chunk);
      _current(epoch);
      await _exchange(OutgoingFilePhase.awaitingAck, () async {
        _current(epoch);
        _issuedOffset = end;
        await _trackWire(
          () => transport.sendSignal(
            context.authorization,
            FileCodec.encode(chunk),
          ),
        );
        if (identical(context, attempt)) {
          _sentOffset = end;
          if (end > _emittedOffset) _emittedOffset = end;
        }
      }, nextOffset: end);
      _current(epoch);
      _acknowledgedOffset = end;
      _phase = OutgoingFilePhase.sending;
    }
    await source.finishSend();
    _current(epoch);
    final finish = FileFinish(
      transferId: context.transferId,
      size: context.size,
      sha256: context.sha256,
    );
    await context.validateOutgoing(finish);
    _current(epoch);
    await _exchange(OutgoingFilePhase.awaitingComplete, () {
      _current(epoch);
      _finishIssued = true;
      return _trackWire(
        () => transport.sendSignal(
          context.authorization,
          FileCodec.encode(finish),
        ),
      );
    });
    return _receipt!;
  }

  Future<FileMessage> _exchange(
    OutgoingFilePhase phase,
    Future<void> Function() send, {
    int? nextOffset,
    FileMessage? localResult,
  }) async {
    final slot = _ResponseSlot(phase, nextOffset);
    _phase = phase;
    _pending = slot;
    if (localResult != null) slot.response.complete(localResult);
    try {
      // A peer can reply before send returns. Install the slot first, and await
      // BOTH sides before reading again. eagerError lets stop preempt a blocked
      // write while still observing its eventual error/completion.
      await Future.any<void>([
        Future.wait<void>([
          Future<void>.sync(send),
          slot.response.future.then<void>((_) {}),
        ], eagerError: true),
        slot.stopped.future,
      ]);
      return await slot.response.future;
    } finally {
      if (identical(_pending, slot)) _pending = null;
      if (!slot.stopped.isCompleted) slot.stopped.complete();
    }
  }

  /// Bounded decode lanes allow stop controls to preempt an ordinary response.
  /// Neither lane queues work behind disk or transport sends.
  Future<void> handleSignal(VerifiedSessionSignal signal) async {
    final attempt = context;
    // A retired or foreign operation cannot fail the current attempt merely by
    // reaching a stale application callback. The router normally drops it.
    if (!identical(signal.authorization, attempt.authorization)) {
      throw const FileProtocolFailure('context_mismatch');
    }
    final epoch = _epoch;
    bool? controlLane;
    final slot = _pending;
    try {
      if (_closed || _retiring) {
        throw const FileProtocolFailure('operation_stopped');
      }
      final hint = FileCodec.decode(signal.body);
      final control =
          hint is FileCancel ||
          hint is FileCancelled ||
          hint is FilePause ||
          hint is FilePaused ||
          hint is FileFailed ||
          hint is FileRejected;
      if (control ? _decodingControl : _decodingData) {
        throw const FileProtocolFailure('resource_limit');
      }
      controlLane = control;
      _decodeIdle ??= Completer<void>();
      if (control) {
        _decodingControl = true;
      } else {
        _decodingData = true;
      }
      final message = await attempt.decodeSignal(signal);
      if (!identical(context, attempt)) {
        throw const FileProtocolFailure('operation_stopped');
      }
      if (_closed) throw const FileProtocolFailure('operation_stopped');
      context.requireCurrent();
      if (message is FileComplete) {
        if (!_finishIssued && !(_resumeMayComplete && _offerIssued)) {
          throw const FileProtocolFailure('invalid_state');
        }
        final previous = _receipt;
        if (previous != null && previous.actualName != message.actualName) {
          throw const FileProtocolFailure('integrity_mismatch');
        }
        publication?.confirmReceived();
        _receipt ??= message;
        _phase = OutgoingFilePhase.completed;
        if (slot != null &&
            identical(slot, _pending) &&
            !slot.response.isCompleted &&
            (slot.phase == OutgoingFilePhase.awaitingComplete ||
                slot.phase == OutgoingFilePhase.awaitingResumeState)) {
          slot.response.complete(message);
        }
        return;
      }
      if (_receipt != null) return;
      if (message is FileCancel || message is FileCancelled) {
        if (!_offerIssued) throw const FileProtocolFailure('invalid_state');
        publication?.confirmReceived();
        _peerTerminal = FileCancelled(transferId: context.transferId);
        if (_peerCancelRequested) return;
        _peerCancelRequested = true;
        final stopping = cancel(notifyPeer: false);
        unawaited(
          _finishPeerCancel(stopping, context, reply: message is FileCancel),
        );
        return;
      }
      if (message is FileFailed) {
        if (!_offerIssued) throw const FileProtocolFailure('invalid_state');
        if (_offerIssued) publication?.confirmReceived();
        _peerTerminal = message;
        _failureSent = true; // A terminal peer error must not be echoed back.
        _phase = OutgoingFilePhase.failed;
        _fail(
          FileProtocolFailure(message.code),
          StackTrace.current,
          notifyPeer: false,
        );
        return;
      }
      // Local pause/cancel can race authenticated terminal facts above. They
      // still belong to this attempt; ordinary responses cannot cross epochs.
      if (_epoch != epoch) throw const FileProtocolFailure('operation_stopped');
      if (message is FileRejected) {
        if (_offerIssued) publication?.confirmReceived();
        // This attempt cannot proceed, but the peer has not confirmed a file
        // terminal state. Preserve a local pause and leave cross-attempt
        // termination to the channel's explicit cancellation control.
        _fail(
          FileProtocolFailure(message.code),
          StackTrace.current,
          notifyPeer: false,
        );
        return;
      }
      if (message is FilePause || message is FilePaused) {
        if (!_offerIssued ||
            (message is FilePaused && message.offset > _issuedOffset)) {
          throw const FileProtocolFailure('invalid_state');
        }
        publication?.confirmReceived();
        if (_peerPauseRequested) return;
        _peerPauseRequested = true;
        final stopping = pause(notifyPeer: false);
        _peerPaused = message is FilePaused;
        unawaited(
          _finishPeerPause(stopping, _epoch, reply: message is FilePause),
        );
        return;
      }
      if (slot == null ||
          !identical(slot, _pending) ||
          slot.response.isCompleted ||
          _phase != slot.phase) {
        throw const FileProtocolFailure('invalid_state');
      }
      final valid = switch (message) {
        FileAccept() =>
          slot.phase == OutgoingFilePhase.awaitingAccept &&
              message.offset == 0 &&
              message.window == FileLimits.window,
        FileAck() =>
          slot.phase == OutgoingFilePhase.awaitingAck &&
              message.nextOffset == slot.nextOffset,
        FileResumeState() =>
          slot.phase == OutgoingFilePhase.awaitingResumeState &&
              message.offset >= _resumeMinimum &&
              message.offset <= _resumeMaximum,
        _ => false,
      };
      if (!valid) throw const FileProtocolFailure('invalid_state');
      publication?.confirmReceived();
      if (message is FileResumeState) _resumeMayComplete = false;
      if (message is FileAck) {
        _peerAckOffset = message.nextOffset;
        if (message.nextOffset > _emittedOffset) {
          _emittedOffset = message.nextOffset;
        }
      }
      slot.response.complete(message);
    } catch (error, stack) {
      if (_epoch == epoch && identical(context, attempt)) _fail(error, stack);
      rethrow;
    } finally {
      if (controlLane == true) _decodingControl = false;
      if (controlLane == false) _decodingData = false;
      if (!_decodingControl && !_decodingData) {
        final idle = _decodeIdle;
        _decodeIdle = null;
        idle?.complete();
      }
    }
  }

  void _rejectPending(Object error, [StackTrace? stack]) {
    final slot = _pending;
    if (slot != null && !slot.stopped.isCompleted) {
      slot.stopped.completeError(error, stack);
    }
    if (slot != null && !slot.response.isCompleted) {
      slot.response.completeError(error, stack);
    }
  }

  Future<void> _finishPeerCancel(
    Future<SourceStopState> stopping,
    FileTransferContext attempt, {
    required bool reply,
  }) async {
    try {
      await stopping;
      if (!identical(context, attempt) || _closed) return;
      if (_receipt == null && _phase == OutgoingFilePhase.cancelling) {
        _phase = OutgoingFilePhase.cancelled;
      }
      if (reply && _receipt == null) {
        _notify(FileCancelled(transferId: context.transferId));
      }
    } catch (_) {
      // The observed native stop error remains retryable through cancel/close.
      if (identical(context, attempt)) _peerCancelRequested = false;
    }
  }

  Future<void> _finishPeerPause(
    Future<SourceStopState> stopping,
    int epoch, {
    required bool reply,
  }) async {
    try {
      await stopping;
      if (_epoch != epoch || _closed) return;
      if (reply && _phase == OutgoingFilePhase.paused) {
        _notify(
          FilePaused(
            transferId: context.transferId,
            offset: _acknowledgedOffset,
          ),
        );
      }
    } catch (error, stack) {
      if (_epoch == epoch && _phase == OutgoingFilePhase.paused) {
        _phase = OutgoingFilePhase.failed;
        _fail(error, stack);
      }
    }
  }

  Future<SourceStopState> _observeStop(Future<SourceStopState> stopping) {
    _stopping = stopping;
    unawaited(
      stopping.then<void>(
        (_) {
          if (identical(_stopping, stopping)) _stopFailure = null;
        },
        onError: (Object error, StackTrace stack) {
          if (identical(_stopping, stopping)) _stopFailure = error;
        },
      ),
    );
    return stopping;
  }

  void _fail(Object error, StackTrace stack, {bool notifyPeer = true}) {
    _epoch++;
    if (_receipt == null &&
        _phase != OutgoingFilePhase.cancelled &&
        _phase != OutgoingFilePhase.cancelling &&
        _phase != OutgoingFilePhase.paused) {
      _phase = OutgoingFilePhase.failed;
    }
    _rejectPending(error, stack);
    if (_phase != OutgoingFilePhase.paused) {
      _observeStop(_stopSources(SourceStopMode.cancel));
    }
    if (notifyPeer &&
        _phase == OutgoingFilePhase.failed &&
        _offerIssued &&
        !_closed &&
        !_failureSent) {
      _failureSent = true;
      // Only protocol codes cross the wire, never native errors or paths.
      final code = switch (error) {
        FileSourceFailure(code: 'source_changed') => 'source_changed',
        FileProtocolFailure() => 'invalid_message',
        _ => 'io_failure',
      };
      _notify(FileFailed(transferId: context.transferId, code: code));
    }
  }

  Future<SourceStopState> cancel({bool notifyPeer = true}) {
    _epoch++;
    if (_receipt == null &&
        _phase != OutgoingFilePhase.failed &&
        _phase != OutgoingFilePhase.cancelled) {
      _phase = _offerIssued
          ? OutgoingFilePhase.cancelling
          : OutgoingFilePhase.cancelled;
    }
    _rejectPending(const FileProtocolFailure('cancelled'));
    final stopping = _observeStop(_stopSources(SourceStopMode.cancel));
    if (notifyPeer &&
        _offerIssued &&
        !_cancelSent &&
        _receipt == null &&
        !_closed) {
      _cancelSent = true;
      _notify(FileCancel(transferId: context.transferId));
    }
    return stopping;
  }

  Future<SourceStopState> pause({bool notifyPeer = true}) {
    if (_closed ||
        _receipt != null ||
        _phase == OutgoingFilePhase.cancelling ||
        _phase == OutgoingFilePhase.cancelled ||
        _phase == OutgoingFilePhase.failed) {
      return Future.error(const FileProtocolFailure('invalid_state'));
    }
    _epoch++;
    _phase = OutgoingFilePhase.paused;
    _rejectPending(const FileProtocolFailure('paused'));
    final stopping = _observeStop(_stopSources(SourceStopMode.pause));
    if (notifyPeer && _offerIssued && !_pauseSent) {
      _pauseSent = true;
      _notify(FilePause(transferId: context.transferId));
    }
    return stopping;
  }

  void _invalidate() {
    if (_closed) return;
    cancel(notifyPeer: false);
    if (_receipt == null) _phase = OutgoingFilePhase.cancelled;
  }

  void _notify(FileMessage message) {
    final attempt = context;
    unawaited(
      _sendControl(message).then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (identical(context, attempt)) _notificationFailure = error;
        },
      ),
    );
  }

  Future<void> _sendControl(FileMessage message) async {
    final attempt = context;
    final epoch = _epoch;
    await attempt.validateOutgoing(message);
    if (_closed || _epoch != epoch || !identical(context, attempt)) return;
    if (message is FilePause && _phase != OutgoingFilePhase.paused) return;
    if (message is FilePaused && _phase != OutgoingFilePhase.paused) return;
    context.requireCurrent();
    await _trackWire(
      () => transport.sendSignal(
        context.authorization,
        FileCodec.encode(message),
      ),
    );
  }

  Future<void> _trackWire(Future<void> Function() write) {
    late final Future<void> work;
    work = Future<void>.sync(write).whenComplete(() => _wireWork.remove(work));
    _wireWork.add(work);
    return work;
  }

  /// Freeze ingress and drain the current generation before retiring. A fresh
  /// physical generation may detach old wire callbacks; closed-owner checks
  /// continue to prevent those callbacks from starting any new work.
  Future<void> prepareRetirement({required bool drainWire}) async {
    _retiring = true;
    if (drainWire) await _decodeIdle?.future;
    await close();
    if (drainWire) {
      if (_running case final running?) {
        await running.then<void>((_) {}, onError: (Object e, StackTrace s) {});
      }
      await Future.wait(
        _wireWork
            .map(
              (work) =>
                  work.then<void>((_) {}, onError: (Object e, StackTrace s) {}),
            )
            .toList(),
      );
    }
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    final closing = _close();
    _closing = closing;
    unawaited(
      closing.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (identical(_closing, closing)) _closing = null;
        },
      ),
    );
    return closing;
  }

  Future<void> _close() async {
    await cancel(notifyPeer: false);
    await source.close();
    await _closeRetired();
    await _invalidations.cancel();
  }

  Future<void> _closeRetired() async {
    final retired = _retiredSource;
    if (retired == null) return;
    await retired.close();
    if (identical(_retiredSource, retired)) _retiredSource = null;
  }

  Future<SourceStopState> _stopSources(SourceStopMode mode) {
    Future<SourceStopState> stop(VerifiedFileSource source) =>
        mode == SourceStopMode.pause ? source.pause() : source.cancel();
    final stopping = stop(source);
    final retired = _retiredSource;
    if (retired == null) return stopping;
    return Future.wait([
      stopping,
      stop(retired),
    ], eagerError: true).then((states) => states.first);
  }
}

final class _ResponseSlot {
  _ResponseSlot(this.phase, this.nextOffset) {
    // Cancellation may precede registration of the send wait's error handler.
    unawaited(
      response.future.then<void>((_) {}, onError: (Object e, StackTrace s) {}),
    );
    unawaited(
      stopped.future.then<void>((_) {}, onError: (Object e, StackTrace s) {}),
    );
  }
  final OutgoingFilePhase phase;
  final int? nextOffset;
  final response = Completer<FileMessage>();
  final stopped = Completer<void>();
}
