import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:share_hub_connection/share_hub_connection.dart';

/// Process-owned auxiliary credential cache. No connection or media grant is
/// created here; ICE reads only an already available, unexpired snapshot.
final class RelayCredentialOwner extends ChangeNotifier {
  RelayCredentialOwner(
    this._identity,
    this._service,
    this._closeTransport, {
    DateTime Function()? now,
    this.retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    this.recoveryDelay = const Duration(minutes: 1),
    this.maxRecoveryDelay = const Duration(minutes: 15),
  }) : assert(recoveryDelay > Duration.zero),
       assert(maxRecoveryDelay >= recoveryDelay),
       _now = now ?? DateTime.now;

  final Future<DeviceIdentity> Function() _identity;
  final AuxiliaryServiceClient _service;
  final void Function() _closeTransport;
  final DateTime Function() _now;
  final List<Duration> retryDelays;

  /// A failed burst cools down before another bounded burst. This lets an
  /// existing connection recover after service restart without busy polling.
  final Duration recoveryDelay, maxRecoveryDelay;
  AuxiliaryTurnCredential? _lease;
  AuxiliaryCancellation? _cancellation;
  Timer? _renewal, _expiry;
  Future<void>? _pending;
  bool _needed = false, _stopped = false;
  int _failedBursts = 0;
  String? _requestId;
  String? lastFailure;

  AuxiliaryTurnCredential? get current {
    final lease = _lease;
    if (_stopped || !_needed || lease == null) return null;
    if (!lease.validAt(_now())) {
      _lease = null;
      notifyListeners();
      return null;
    }
    return lease;
  }

  /// Call only while a connection is being made or retained. Local signaling
  /// and direct ICE are independent of this future and every renewal.
  Future<void> start() {
    if (_stopped) return Future.value();
    if (_needed) return _pending ?? Future.value();
    _needed = true;
    _failedBursts = 0;
    lastFailure = null;
    final previous = _pending;
    if (previous != null) {
      return previous.then((_) {
        if (_needed && !_stopped) return _attempt(0);
      });
    }
    return _attempt(0);
  }

  /// Releasing the last connection cancels pending requests, renewal and the
  /// in-memory secret; a later connection may start again with fresh proof.
  void suspend() {
    if (_stopped || !_needed) return;
    _needed = false;
    _failedBursts = 0;
    _requestId = null;
    _cancellation?.cancel();
    _renewal?.cancel();
    _expiry?.cancel();
    _lease = null;
    lastFailure = null;
    notifyListeners();
  }

  void setNeeded(bool needed) {
    if (needed) {
      unawaited(start());
    } else {
      suspend();
    }
  }

  /// Explicit retry is available after a bounded automatic retry series.
  Future<void> refresh() {
    if (!_needed || _stopped) return Future.value();
    _renewal?.cancel();
    _failedBursts = 0;
    _requestId = null;
    lastFailure = null;
    notifyListeners();
    final previous = _pending;
    if (previous != null) {
      // A refresh supersedes the in-flight request. Its late response must
      // never become the credential selected for this attempt.
      _cancellation?.cancel();
      return previous.then((_) {
        if (_needed && !_stopped) return _attempt(0);
      });
    }
    return _attempt(0);
  }

  Future<void> _attempt(int retryIndex) {
    if (_stopped || !_needed) return Future.value();
    final existing = _pending;
    if (existing != null) return existing;
    final cancellation = AuxiliaryCancellation();
    final requestId = _requestId ??= AuxiliaryServiceClient.newTurnRequestId();
    _cancellation = cancellation;
    late final Future<void> pending;
    pending = _fetch(cancellation, retryIndex, requestId).whenComplete(() {
      if (identical(_pending, pending)) _pending = null;
      if (identical(_cancellation, cancellation)) _cancellation = null;
    });
    _pending = pending;
    return pending;
  }

  Future<void> _fetch(
    AuxiliaryCancellation cancellation,
    int retryIndex,
    String requestId,
  ) async {
    try {
      final identity = await _identity();
      cancellation.throwIfCancelled();
      await _service.register(identity, cancellation: cancellation);
      final lease = await _service.issueTurn(
        identity,
        cancellation: cancellation,
        requestId: requestId,
      );
      cancellation.throwIfCancelled();
      if (_stopped || !_needed) return;
      final remaining = lease.expiresAt.difference(_now());
      if (remaining <= const Duration(seconds: 1)) {
        throw const AuxiliaryFailure('expired_credential');
      }
      _lease = lease;
      if (_requestId == requestId) _requestId = null;
      _failedBursts = 0;
      lastFailure = null;
      _renewal?.cancel();
      _expiry?.cancel();
      // Renew with overlap. The service must permit at least two active
      // credentials per device for uninterrupted long sessions.
      _renewal = Timer(remaining * 0.75, () => unawaited(_attempt(0)));
      _expiry = Timer(remaining, () {
        if (identical(_lease, lease)) {
          _lease = null;
          notifyListeners();
        }
      });
      // Publish only after timers are owned; a listener may synchronously
      // suspend or stop and must be able to cancel both of them.
      notifyListeners();
    } on AuxiliaryFailure catch (error) {
      if (_stopped || !_needed || cancellation.isCancelled) return;
      lastFailure = error.code;
      notifyListeners();
      if (_stopped || !_needed) return;
      if (_retryable(error.code)) {
        _renewal?.cancel();
        final shortRetry = retryIndex < retryDelays.length;
        final delay = shortRetry ? retryDelays[retryIndex] : _cooldownDelay();
        _renewal = Timer(
          delay,
          () => unawaited(_attempt(shortRetry ? retryIndex + 1 : 0)),
        );
      }
    } catch (_) {
      if (!_stopped && _needed && !cancellation.isCancelled) {
        lastFailure = 'unexpected';
        notifyListeners();
      }
    }
  }

  Duration _cooldownDelay() {
    final multiplier = 1 << math.min(_failedBursts++, 8);
    final candidate = recoveryDelay * multiplier;
    return candidate > maxRecoveryDelay ? maxRecoveryDelay : candidate;
  }

  bool _retryable(String code) =>
      code == 'timeout' ||
      code == 'unreachable' ||
      code == 'server_error' ||
      code == 'capacity_limited';

  /// Gates late network results and clears the only in-process secret copy.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _needed = false;
    _requestId = null;
    _cancellation?.cancel();
    _renewal?.cancel();
    _expiry?.cancel();
    _lease = null;
    lastFailure = null;
    notifyListeners();
    _closeTransport();
  }
}
