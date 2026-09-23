import 'dart:async';

import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import 'receive_access.dart';

/// Couples one authenticated incoming operation to a native disk stop scope.
/// A recovered operation needs a new owner and a context obtained through
/// FileTransferContext.resumeWith; this owner can never become current again.
/// File cleanup and receipt retention remain with the receiving transfer.
final class ReceiveAuthorization {
  ReceiveAuthorization(this.context, this.access) {
    if (context.authorization is! VerifiedSessionMessage) {
      throw const SessionFailure('incoming_authorization_required');
    }
    _invalidations = context.authorization.invalidated.listen(
      (_) {
        _invalidated = true;
        // A successful intentional pause retains the partial file across
        // suspension. A failed pause has not established that native barrier.
        if (_mode == null || (_mode == ReceiveStopMode.pause && _stopFailed)) {
          unawaited(stop(ReceiveStopMode.cancel));
        }
      },
      onDone: () {
        // GrantEndpoint closes this stream only on permanent revocation.
        // That terminal event must also revoke an intentionally paused scope.
        if (_mode != ReceiveStopMode.cancel) {
          unawaited(stop(ReceiveStopMode.cancel));
        }
      },
    );
  }

  final FileTransferContext context;
  final ReceiveAccess access;
  late final StreamSubscription<void> _invalidations;
  final _stopRequested = Completer<void>();
  ReceiveScope? _native;
  Future<ReceiveScope>? _opening;
  ReceiveStopMode? _mode;
  Future<ReceiveStopState>? _stopping;
  bool _stopFailed = false;
  bool _invalidated = false;
  Future<void>? _closing;
  bool _closeRequested = false, _closed = false;

  Future<ReceiveScope> open() {
    if (_mode != null || _closeRequested) {
      return Future.error(const SessionFailure('operation_stopped'));
    }
    return _opening ??= _open();
  }

  Future<ReceiveScope> _open() async {
    await check();
    requireCurrent();
    final scope = await access.openScope(
      key: context.transferKey,
      deadlineMicros: context.authorization.expiresMicros,
    );
    // Retain a late capability even when the operation was cancelled while
    // opening. stop() waits for this call and then closes its native I/O gate.
    _native = scope;
    try {
      await check();
      requireCurrent();
      return scope;
    } catch (_) {
      if (_mode == null) {
        unawaited(stop(ReceiveStopMode.cancel));
      }
      rethrow;
    }
  }

  Future<void> check() async {
    requireCurrent();
    await context.check();
    requireCurrent();
  }

  void requireCurrent() {
    if (_mode != null || _closeRequested) {
      throw const SessionFailure('operation_stopped');
    }
    context.requireCurrent();
  }

  /// Local effects are gated synchronously. When the capability already
  /// exists, dispatch the native stop immediately, bypassing queued disk work.
  /// A native 'committing' result must not be reported as successful cancel.
  Future<ReceiveStopState> stop(ReceiveStopMode mode) {
    final effective = _mode == ReceiveStopMode.cancel
        ? ReceiveStopMode.cancel
        : mode;
    if (_mode == effective && _stopping != null && !_stopFailed) {
      return _stopping!;
    }
    _mode = effective;
    _stopFailed = false;
    final Future<ReceiveStopState> stopping;
    if (_closed) {
      stopping = Future.value(ReceiveStopState.cancelled);
    } else if (_native case final scope?) {
      stopping = _dispatchStop(scope, effective);
    } else {
      stopping = _stopAfterOpen(effective);
    }
    _stopping = stopping;
    if (!_stopRequested.isCompleted) _stopRequested.complete();
    // Also observe invalidation-triggered failures. Keep the error available
    // to callers, but allow stop/close to retry a failed platform dispatch.
    unawaited(
      stopping.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (identical(_stopping, stopping)) {
            _stopFailed = true;
            // Suspension may have arrived while native pause was pending.
            // Never leave a possibly active capability behind that failure.
            if (_mode == ReceiveStopMode.pause && _invalidated) {
              unawaited(stop(ReceiveStopMode.cancel));
            }
          }
        },
      ),
    );
    return stopping;
  }

  Future<ReceiveStopState> _dispatchStop(
    ReceiveScope scope,
    ReceiveStopMode mode,
  ) async => access.stopScope(scope, mode);

  Future<ReceiveStopState> _stopAfterOpen(ReceiveStopMode mode) async {
    try {
      await _opening;
    } catch (_) {
      // _open records the native token before checking for late invalidation.
    }
    final scope = _native;
    if (scope == null) {
      return mode == ReceiveStopMode.pause
          ? ReceiveStopState.paused
          : ReceiveStopState.cancelled;
    }
    // A cancel requested while open was pending always dominates a pause.
    return _dispatchStop(scope, _mode ?? mode);
  }

  Future<ReceiveStopState> get whenStopped =>
      _stopping ?? _stopRequested.future.then((_) => _stopping!);

  /// Scope release is retryable. It never releases a receive-file token or
  /// deletes a published file; the transfer owner retains that responsibility.
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
    await stop(ReceiveStopMode.cancel);
    final scope = _native;
    if (scope != null) await access.closeScope(scope);
    await _invalidations.cancel();
    _closed = true;
    _native = null;
  }
}
