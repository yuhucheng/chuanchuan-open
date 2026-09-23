import 'dart:async';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

typedef RecoveryRoute = ({String host, int port});

/// Process-owned retry/cleanup. A caller-facing timeout never erases an
/// unsettled adapter; shutdown waits for run() to finish its actual owners.
class ConnectionRecovery {
  ConnectionRecovery({
    required this.previous,
    required this.route,
    required this.clock,
    required this.verifyIdentity,
    required this.onRecovered,
    required this.onFailed,
    required this.window,
    required this.backoff,
    required this.attemptTimeout,
  });
  final TrustedConnection previous;
  final RecoveryRoute? route;
  final Future<int> Function() clock;
  final Future<void> Function() verifyIdentity;
  final bool Function(TrustedConnection) onRecovered;
  final void Function() onFailed;
  final Duration window, attemptTimeout;
  final List<Duration> backoff;
  bool _cancelled = false;
  Timer? _deadline, _delayTimer;
  Completer<void>? _delay;
  ConnectionRecoveryAttempt? _attempt;
  StreamSubscription<void>? _invalidation;
  int? _began, _last;

  bool get cancelled => _cancelled;
  void _current() {
    if (_cancelled || previous.grant!.phase == GrantPhase.revoked) {
      throw const ConnectionFailure('cancelled');
    }
  }

  /// Recheck the process recovery deadline after asynchronous admission work.
  Future<void> checkCurrent() => _checkTime();

  Future<void> _checkTime() async {
    _current();
    final now = await clock();
    _current();
    _began ??= now;
    _last ??= now;
    if (now < _last! ||
        now - _began! >= window.inMicroseconds ||
        now >= previous.grant!.expiresMicros) {
      throw const ConnectionFailure('recovery_expired');
    }
    _last = now;
  }

  Future<void> _wait(Duration duration) {
    final done = _delay = Completer<void>();
    _delayTimer = Timer(duration, () {
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }

  void cancel({bool revoke = true}) {
    if (_cancelled) return;
    _cancelled = true;
    _deadline?.cancel();
    _delayTimer?.cancel();
    if (_delay case final wait? when !wait.isCompleted) wait.complete();
    if (revoke) {
      _attempt?.cancel();
      previous.close('revoked');
    }
  }

  void _failed() {
    if (_cancelled) return;
    cancel();
    onFailed();
  }

  Future<void> run() async {
    _deadline = Timer(window, _failed);
    _invalidation = previous.grant!.invalidated.listen((_) {
      if (previous.grant!.phase == GrantPhase.revoked) _failed();
    });
    try {
      await _checkTime();
      if (route == null) {
        await _wait(window); // Receiver waits for authenticated peer recovery.
        if (!_cancelled) _failed();
        return;
      }
      for (final delay in backoff) {
        await _wait(delay);
        _current();
        await _checkTime();
        await verifyIdentity();
        _current();
        final attempt = _attempt = ConnectionRecoveryAttempt(
          previous,
          timeout: attemptTimeout,
        );
        TrustedConnection? recovered;
        try {
          recovered = await attempt.connect(route!.host, route!.port);
          await verifyIdentity();
          await _checkTime();
          _attempt = null;
          bool accepted;
          try {
            accepted = onRecovered(recovered);
          } catch (_) {
            accepted = false;
          }
          if (!accepted) {
            recovered.close('admission_rejected');
            // Authentication alone is not admission. A rejected candidate
            // must not leave the original grant suspended with no retry owner.
            _failed();
            return;
          }
          cancel(revoke: false);
          return;
        } catch (_) {
          recovered?.close('recovery_rejected');
          if (_cancelled || previous.grant!.phase == GrantPhase.revoked) {
            rethrow;
          }
        } finally {
          // Even after the public deadline, do not overlap native/socket work.
          await attempt.settled;
          if (recovered?.isClosed ?? false) {
            await recovered!.whenTransportClosed;
          }
          if (identical(_attempt, attempt)) _attempt = null;
        }
      }
      _failed();
    } catch (_) {
      _failed();
    } finally {
      _deadline?.cancel();
      _delayTimer?.cancel();
      await _invalidation?.cancel();
      await _attempt?.settled;
    }
  }
}
