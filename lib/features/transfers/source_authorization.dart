import 'dart:async';

import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import 'source_access.dart';

/// Couples one authenticated outgoing operation to a native source stop scope.
/// A recovered operation needs a new owner and a context obtained through
/// FileTransferContext.resumeWith; this owner can never become current again.
/// Keep a paused owner alive until a new owner has rebound the same selection.
/// Closing before that rebind terminally cancels its recovery eligibility.
/// The selection queue retains ownership of the selected file token.
final class SourceAuthorization {
  SourceAuthorization(this.context, this.access, {required this.fileToken}) {
    if (context.authorization is! LocalSessionRequest) {
      throw const SessionFailure('outgoing_authorization_required');
    }
    _invalidations = context.authorization.invalidated.listen(
      (_) {
        _invalidated = true;
        // A successful intentional pause retains the partial file across
        // suspension. A failed pause has not established that native barrier.
        if (_mode == null || (_mode == SourceStopMode.pause && _stopFailed)) {
          unawaited(stop(SourceStopMode.cancel));
        }
      },
      onDone: () {
        // GrantEndpoint closes this stream only on permanent revocation.
        // That terminal event must also revoke an intentionally paused scope.
        if (_mode != SourceStopMode.cancel) {
          unawaited(stop(SourceStopMode.cancel));
        }
      },
    );
  }

  final FileTransferContext context;
  final SourceAccess access;
  final String fileToken;
  late final StreamSubscription<void> _invalidations;
  final _stopRequested = Completer<void>();
  SourceScope? _native;
  Future<SourceScope>? _opening;
  SourceStopMode? _mode;
  Future<SourceStopState>? _stopping;
  bool _stopFailed = false;
  bool _invalidated = false;
  Future<void>? _closing;
  bool _closeRequested = false, _closed = false;

  Future<SourceScope> open() {
    if (_mode != null || _closeRequested) {
      return Future.error(const SessionFailure('operation_stopped'));
    }
    return _opening ??= _open();
  }

  Future<SourceScope> _open() async {
    await check();
    requireCurrent();
    final scope = await access.openScope(
      fileToken: fileToken,
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
        unawaited(stop(SourceStopMode.cancel));
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

  Future<SourceStopState> stop(SourceStopMode mode) {
    final effective = _mode == SourceStopMode.cancel
        ? SourceStopMode.cancel
        : mode;
    if (_mode == effective && _stopping != null && !_stopFailed) {
      return _stopping!;
    }
    _mode = effective;
    _stopFailed = false;
    final Future<SourceStopState> stopping;
    if (_closed) {
      stopping = Future.value(SourceStopState.cancelled);
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
            if (_mode == SourceStopMode.pause && _invalidated) {
              unawaited(stop(SourceStopMode.cancel));
            }
          }
        },
      ),
    );
    return stopping;
  }

  Future<SourceStopState> _dispatchStop(
    SourceScope scope,
    SourceStopMode mode,
  ) async => access.stopScope(scope, mode);

  Future<SourceStopState> _stopAfterOpen(SourceStopMode mode) async {
    try {
      await _opening;
    } catch (_) {
      // _open records the native token before checking for late invalidation.
    }
    final scope = _native;
    if (scope == null) {
      return mode == SourceStopMode.pause
          ? SourceStopState.paused
          : SourceStopState.cancelled;
    }
    // A cancel requested while open was pending always dominates a pause.
    return _dispatchStop(scope, _mode ?? mode);
  }

  Future<SourceStopState> get whenStopped =>
      _stopping ?? _stopRequested.future.then((_) => _stopping!);

  /// Scope release is retryable. It never releases the selected file token.
  /// Close a paused old owner only after the replacement scope has opened.
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
    await stop(SourceStopMode.cancel);
    final scope = _native;
    if (scope != null) await access.closeScope(scope);
    await _invalidations.cancel();
    _closed = true;
    _native = null;
  }
}
