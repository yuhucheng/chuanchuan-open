import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;

import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import 'receive_access.dart';
import 'receive_authorization.dart';

enum IncomingFilePhase {
  offered,
  receiving,
  verifying,
  paused,
  resuming,
  awaitingResumeAccept,
  completed,
  stopping,
  cancelled,
  failed,
}

/// Owns one authenticated incoming file, its native staging token and receipt.
/// No networking or unbounded input queue: the coordinator must publish its
/// slot before sending returned messages and recheck the context before send.
/// A resume coordinator must retain this owner and checkpoint until native
/// rebind succeeds; this owner never reactivates old session authorization.
final class IncomingFileTransfer {
  IncomingFileTransfer({
    required FileTransferContext context,
    required this.access,
    required this.directory,
  }) : _context = context {
    if (context.request is! FileOffer && context.request is! FileResume) {
      throw const FileProtocolFailure('invalid_state');
    }
    _authorization = ReceiveAuthorization(context, access);
    _invalidations = context.authorization.invalidated.listen((_) {
      if (_phase != IncomingFilePhase.paused) unawaited(cancel());
    }, onDone: () => unawaited(cancel()));
  }

  FileTransferContext _context;
  FileTransferContext get context => _context;
  final ReceiveAccess access;
  final ReceiveDirectory directory;
  late ReceiveAuthorization _authorization;
  ReceiveAuthorization? _retiredAuthorization;
  late final StreamSubscription<void> _invalidations;
  IncomingFilePhase _phase = IncomingFilePhase.offered;
  IncomingFilePhase get phase => _phase;
  ReceiveFile? _file;
  ReceiveScope? _scope;
  ReceiveReceipt? _receipt;
  ReceiveReceipt? get receipt => _receipt;
  ReceiveCheckpoint? _checkpoint;
  int? _expectedResumeOffset;
  String? _expectedResumePrefix;
  ReceiveCheckpoint? get checkpoint => _checkpoint;
  int _offset = 0, _epoch = 0;
  int get offset => _offset;
  Completer<void>? _idle;
  Future<void>? _cleaning, _closing;
  Future<ReceiveCheckpoint?>? _pausing;
  ReceiveStopState? _cancelState;
  bool _workFailedDuringStop = false;
  Object? _cleanupFailure;
  Object? get cleanupFailure => _cleanupFailure;
  bool _closed = false, _closeRequested = false, _pauseReady = false;

  void _current(int epoch) {
    if (_epoch != epoch ||
        _closeRequested ||
        _phase == IncomingFilePhase.paused ||
        _phase == IncomingFilePhase.cancelled ||
        _phase == IncomingFilePhase.stopping) {
      throw const SessionFailure('operation_stopped');
    }
    _authorization.requireCurrent();
  }

  Future<void> _guard(int epoch) async {
    _current(epoch);
    await _authorization.check();
    _current(epoch);
  }

  Future<T> _run<T>(
    IncomingFilePhase expected,
    Future<T> Function(int) work,
  ) async {
    if (_idle != null || _phase != expected || _closeRequested) {
      throw const FileProtocolFailure('invalid_state');
    }
    final idle = Completer<void>();
    _idle = idle;
    final epoch = _epoch;
    try {
      await _guard(epoch);
      return await work(epoch);
    } catch (_) {
      _workFailed();
      rethrow;
    } finally {
      _idle = null;
      idle.complete();
    }
  }

  void _workFailed() {
    if (_receipt == null && _phase == IncomingFilePhase.stopping) {
      // The native stop response may still be pending. Its result decides
      // whether this rejected work was cancelled or admitted publication
      // failed; the order of async callbacks must not decide the UI state.
      _workFailedDuringStop = true;
      if (_cancelState case final state?) _observeStop(state);
    } else if (_receipt == null &&
        _phase != IncomingFilePhase.paused &&
        _phase != IncomingFilePhase.cancelled) {
      _phase = IncomingFilePhase.failed;
      _epoch++;
      _stopForCleanup();
      _scheduleCleanup();
    }
  }

  Future<FileMessage> start() => _run(IncomingFilePhase.offered, (epoch) async {
    final scope = await _authorization.open();
    _scope = scope;
    await _guard(epoch);
    await _begin(scope, epoch);
    if (context.request is FileResume) return _startFromZero();
    _phase = IncomingFilePhase.receiving;
    return FileAccept(
      transferId: context.transferId,
      acceptedChunkBytes: context.chunkBytes,
      window: FileLimits.window,
      offset: 0,
    );
  });

  Future<void> _begin(ReceiveScope scope, int epoch) async {
    final name = switch (context.request) {
      FileOffer(:final name) || FileResume(:final name) => name,
      _ => throw const FileProtocolFailure('invalid_state'),
    };
    final file = await access.begin(
      directory: directory,
      scope: scope,
      metadata: ReceiveMetadata(
        name: name,
        size: context.size,
        sha256: context.sha256,
      ),
    );
    // Ownership precedes the late-result check so cancellation can clean it.
    _file = file;
    await _guard(epoch);
  }

  FileResumeState _startFromZero() {
    _expectedResumeOffset = _offset = 0;
    _expectedResumePrefix = hashes.sha256.convert([]).toString();
    _phase = IncomingFilePhase.awaitingResumeAccept;
    return FileResumeState(
      transferId: context.transferId,
      attemptId: (context.request as FileResume).attemptId,
      offset: 0,
      prefixSha256: _expectedResumePrefix!,
    );
  }

  Future<FileAck> append(VerifiedSessionSignal signal) =>
      _run(IncomingFilePhase.receiving, (epoch) async {
        final message = await context.decodeSignal(signal);
        await _guard(epoch);
        if (message is! FileChunk || message.offset != _offset) {
          throw const FileProtocolFailure('invalid_state');
        }
        final written = await access.append(
          _file!,
          _scope!,
          message.offset,
          Uint8List.fromList(message.data),
        );
        await _guard(epoch);
        if (written != message.offset + message.data.length) {
          throw const ReceiveAccessFailure('invalid_native_result');
        }
        _offset = written;
        return FileAck(transferId: context.transferId, nextOffset: written);
      });

  Future<FileComplete> finish(VerifiedSessionSignal signal) =>
      _run(IncomingFilePhase.receiving, (epoch) async {
        final message = await context.decodeSignal(signal);
        await _guard(epoch);
        if (message is! FileFinish || _offset != context.size) {
          throw const FileProtocolFailure('invalid_state');
        }
        _phase = IncomingFilePhase.verifying;
        final committed = await access.commit(_file!, _scope!);
        // Native publication cannot be undone by a late authorization failure.
        // Retain this actual receipt before any await or stale-epoch rejection.
        _receipt = committed;
        _phase = IncomingFilePhase.completed;
        await _guard(epoch);
        return FileComplete(
          transferId: context.transferId,
          actualName: committed.name,
          size: committed.size,
          sha256: committed.sha256,
        );
      });

  /// Rebind the retained file, never begin a second temporary file. The caller
  /// publishes [context] in its resolver before sending the returned message.
  /// Completed receipts can be replayed under fresh same-grant authorization.
  Future<FileMessage> resume(VerifiedSessionMessage next) async {
    if (_closeRequested ||
        _idle != null ||
        (_receipt == null &&
            (_phase != IncomingFilePhase.paused ||
                !_pauseReady ||
                (_file != null && _checkpoint == null)))) {
      throw const FileProtocolFailure('invalid_state');
    }
    final idle = Completer<void>();
    _idle = idle;
    final epoch = ++_epoch;
    if (_receipt == null) _phase = IncomingFilePhase.resuming;
    try {
      // At most one retired scope: release any earlier retryable metadata before
      // allocating another authorization or native scope.
      await _closeRetired();
      final freshContext = await context.resumeWith(next);
      if (_epoch != epoch ||
          _closeRequested ||
          (_receipt == null && _phase != IncomingFilePhase.resuming)) {
        throw const SessionFailure('operation_stopped');
      }
      freshContext.requireCurrent();
      _retiredAuthorization = _authorization;
      _authorization = ReceiveAuthorization(freshContext, access);
      _context = freshContext;
      _scope = null;
      _pausing = null;
      _pauseReady = false;
      _cancelState = null;
      _workFailedDuringStop = false;
      if (_receipt case final saved?) {
        // Publication already happened. No rehash/rebind/write can reproduce it.
        await _closeRetired();
        await _guard(epoch);
        _phase = IncomingFilePhase.completed;
        return FileComplete(
          transferId: context.transferId,
          actualName: saved.name,
          size: saved.size,
          sha256: saved.sha256,
        );
      }
      final scope = await _authorization.open();
      _scope = scope;
      await _guard(epoch);
      if (_file == null) {
        await _closeRetired();
        await _guard(epoch);
        await _begin(scope, epoch);
        return _startFromZero();
      }
      final checkpoint = _checkpoint!;
      await access.resume(_file!, scope, checkpoint);
      await _guard(epoch);
      // Closing the old scope before native rebind would cancel the original
      // file. After rebind it is detached and cannot stop the replacement.
      await _closeRetired();
      await _guard(epoch);
      _offset = checkpoint.offset;
      _expectedResumeOffset = checkpoint.offset;
      _expectedResumePrefix = checkpoint.sha256;
      _phase = IncomingFilePhase.awaitingResumeAccept;
      return FileResumeState(
        transferId: context.transferId,
        attemptId: (context.request as FileResume).attemptId,
        offset: checkpoint.offset,
        prefixSha256: checkpoint.sha256,
      );
    } catch (_) {
      _workFailed();
      rethrow;
    } finally {
      _idle = null;
      idle.complete();
    }
  }

  /// Require the sender's acknowledgement of this exact retained prefix before
  /// more writes. Its own source owner performs the independent prefix rehash.
  Future<void> acceptResume(VerifiedSessionSignal signal) =>
      _run(IncomingFilePhase.awaitingResumeAccept, (epoch) async {
        final message = await context.decodeSignal(signal);
        await _guard(epoch);
        if (message is! FileResumeAccept ||
            message.offset != _expectedResumeOffset ||
            message.prefixSha256 != _expectedResumePrefix) {
          throw const FileProtocolFailure('resume_mismatch');
        }
        _checkpoint = null;
        _expectedResumeOffset = null;
        _expectedResumePrefix = null;
        _phase = IncomingFilePhase.receiving;
      });

  Future<void> _closeRetired() async {
    final retired = _retiredAuthorization;
    if (retired == null) return;
    await retired.close();
    if (identical(_retiredAuthorization, retired)) _retiredAuthorization = null;
  }

  Future<ReceiveStopState> _stopAll(ReceiveStopMode mode) {
    // Dispatch both before awaiting either. During native resume the old scope
    // guards the file and the fresh scope guards prefix reads and the new bind.
    final stopping = _authorization.stop(mode);
    final retired = _retiredAuthorization;
    if (retired == null) return stopping;
    final older = retired.stop(mode);
    final both = Future.wait([stopping, older], eagerError: true).then((
      states,
    ) {
      if (states.contains(ReceiveStopState.committed)) {
        return ReceiveStopState.committed;
      }
      if (states.contains(ReceiveStopState.committing)) {
        return ReceiveStopState.committing;
      }
      return states.first;
    });
    unawaited(
      both.then<void>((_) {}, onError: (Object error, StackTrace stack) {}),
    );
    return both;
  }

  void _stopForCleanup() {
    unawaited(_stopAll(ReceiveStopMode.cancel));
  }

  /// Stops new native I/O immediately; cleanup waits for any admitted call and
  /// is separately observable/retryable. Committing is never called cancelled.
  Future<ReceiveStopState> cancel() {
    _epoch++;
    if (_receipt == null &&
        _phase != IncomingFilePhase.failed &&
        _phase != IncomingFilePhase.cancelled) {
      _phase = IncomingFilePhase.stopping;
    }
    final stopping = _stopAll(ReceiveStopMode.cancel);
    unawaited(
      stopping.then<void>(
        _observeStop,
        onError: (Object error, StackTrace stack) {},
      ),
    );
    _scheduleCleanup();
    return stopping;
  }

  void _observeStop(ReceiveStopState state) {
    _cancelState = state;
    if (_receipt != null || _phase != IncomingFilePhase.stopping) return;
    if (state == ReceiveStopState.cancelled) {
      _phase = IncomingFilePhase.cancelled;
    } else if (_workFailedDuringStop &&
        (state == ReceiveStopState.committing ||
            state == ReceiveStopState.committed)) {
      _phase = IncomingFilePhase.failed;
    }
  }

  /// Establish this intent before grant suspension. Stable checkpointing waits
  /// for admitted I/O; it must not race an append that already reached the OS.
  Future<ReceiveCheckpoint?> pause() {
    if (_closeRequested ||
        _phase == IncomingFilePhase.cancelled ||
        _phase == IncomingFilePhase.stopping ||
        _phase == IncomingFilePhase.failed) {
      return Future.error(const FileProtocolFailure('invalid_state'));
    }
    // Native prefix rebind is transactional and fails terminally if stopped.
    // Do not claim a recoverable checkpoint after interrupting that transaction.
    if (_phase == IncomingFilePhase.resuming) {
      return cancel().then((_) => null);
    }
    if (_pausing != null) return _pausing!;
    _epoch++;
    _pauseReady = false;
    if (_receipt == null) _phase = IncomingFilePhase.paused;
    final stopping = _stopAll(ReceiveStopMode.pause);
    final pausing = _pause(stopping);
    _pausing = pausing;
    return pausing;
  }

  Future<ReceiveCheckpoint?> _pause(Future<ReceiveStopState> stopping) async {
    try {
      final state = await stopping;
      await _idle?.future;
      if (_receipt != null) {
        _pauseReady = true;
        return null;
      }
      if (_phase != IncomingFilePhase.paused) {
        throw const SessionFailure('operation_stopped');
      }
      if (state != ReceiveStopState.paused) {
        await cancel();
        return null;
      }
      final file = _file;
      if (file == null) {
        _pauseReady = true;
        return null;
      }
      final snapshot = await access.checkpoint(file);
      if (_phase != IncomingFilePhase.paused) {
        throw const SessionFailure('operation_stopped');
      }
      _checkpoint = snapshot;
      _offset = snapshot.offset;
      _pauseReady = true;
      return snapshot;
    } catch (_) {
      unawaited(cancel());
      rethrow;
    }
  }

  void _scheduleCleanup() {
    // Observe failures, retain the native token and expose explicit retry.
    unawaited(
      cleanup().then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {},
      ),
    );
  }

  Future<void> cleanup() {
    if (_cleaning != null) return _cleaning!;
    if (_phase != IncomingFilePhase.cancelled &&
        _phase != IncomingFilePhase.stopping &&
        _phase != IncomingFilePhase.failed &&
        _receipt == null) {
      return Future.error(const FileProtocolFailure('invalid_state'));
    }
    final cleaning = _cleanup();
    _cleaning = cleaning;
    unawaited(
      cleaning.then<void>(
        (_) {
          if (identical(_cleaning, cleaning)) _cleaning = null;
        },
        onError: (Object error, StackTrace stack) {
          _cleanupFailure = error;
          if (identical(_cleaning, cleaning)) _cleaning = null;
        },
      ),
    );
    return cleaning;
  }

  Future<void> _cleanup() async {
    // A previous dispatch may have failed. The authorization owner caches a
    // successful stop but retries a failed one, so cleanup itself is retryable.
    final state = await _stopAll(ReceiveStopMode.cancel);
    _observeStop(state);
    await _idle?.future;
    await _closeRetired();
    final file = _file;
    if (file != null) {
      if (_receipt == null) {
        await access.abort(file);
        await access.retryCleanup(file);
      }
      await access.release(file);
      _file = null;
    }
    _cleanupFailure = null;
  }

  Future<void> close() {
    _closeRequested = true;
    if (_closed) return Future.value();
    if (_closing != null) return _closing!;
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
    await cancel();
    await cleanup();
    await _authorization.close();
    await _invalidations.cancel();
    _closed = true;
  }
}
