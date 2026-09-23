import 'dart:async';

import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart' show GrantRole;

/// Orders the first publication of locally produced files per transport, until
/// a checked peer reply confirms observation across recovery. A ticket stays
/// with its original owner; offers, bootstrap resumes and terminal controls all
/// use it. This does not authenticate, retire or stop file owners.
final class FilePublicationOrder {
  FilePublicationOrder({this.onAdvanced});

  final void Function()? onAdvanced;
  final _pending = <FilePublication>[];
  final _unconfirmed = <FilePublication>{};
  final _attempts = <_PublicationAttempt>{};
  int _lastOrdinal = 0, _epoch = 0;
  bool _closed = false, _suspended = false;
  int get pendingCount => _pending.length;

  FilePublication reserve() {
    if (_closed ||
        _unconfirmed.length >= 64 ||
        _lastOrdinal == FileLimits.maxOffset) {
      throw const FileProtocolFailure('resource_limit');
    }
    final result = FilePublication._(this, ++_lastOrdinal);
    _pending.add(result);
    _unconfirmed.add(result);
    return result;
  }

  void _advance(FilePublication ticket) {
    _pending.remove(ticket);
    if (ticket._confirmed || ticket._abandoned) _unconfirmed.remove(ticket);
    _pending.firstOrNull?._wake();
    if (!_closed) onAdvanced?.call();
  }

  /// A local write is only ordered within its physical transport. Until a
  /// checked peer reply confirms observation, replay its barrier on recovery.
  void suspend() {
    if (_closed) return;
    _suspended = true;
    _epoch++;
    for (final attempt in _attempts.toList()) {
      if (!attempt.closed.isCompleted) attempt.closed.complete();
    }
    _pending
      ..clear()
      ..addAll(
        _unconfirmed.toList()..sort((a, b) => a.ordinal.compareTo(b.ordinal)),
      );
  }

  void resume() {
    if (_closed) return;
    _suspended = false;
    _pending.firstOrNull?._wake();
    onAdvanced?.call();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final attempt in _attempts.toList()) {
      if (!attempt.closed.isCompleted) attempt.closed.complete();
    }
    _pending.clear();
    _unconfirmed.clear();
  }
}

/// Unforgeable local reservation. Abandon only when no file owner was created;
/// an owned file publishes its terminal control even if no offer was sent.
final class FilePublication {
  FilePublication._(this._order, this.ordinal);
  final FilePublicationOrder _order;
  final int ordinal;
  final _writes = <_PublicationAttempt>[];
  bool _confirmed = false, _abandoned = false, _attempted = false;
  GrantRole? _sender;
  int _operationAttempt = 0;
  int _writtenEpoch = -1, _issuedEpoch = -1;
  bool get _published => _confirmed || _writtenEpoch == _order._epoch;

  bool get canPublish =>
      !_order._closed &&
      !_order._suspended &&
      !_abandoned &&
      (_published || identical(_order._pending.firstOrNull, this));

  /// Allocate before creating an authenticated data request. Failed creation
  /// still consumes an attempt; physical recovery never resets this counter.
  FileOperationId nextOperation(GrantRole sender) {
    _check();
    if (_sender != null && _sender != sender) {
      throw const FileProtocolFailure('context_mismatch');
    }
    if (_operationAttempt == FileLimits.maxOffset) {
      throw const FileProtocolFailure('resource_limit');
    }
    _sender = sender;
    return FileOperationId(
      sender: sender,
      ordinal: ordinal,
      attempt: ++_operationAttempt,
    );
  }

  void abandon() {
    if (_attempted || _published) {
      throw const FileProtocolFailure('invalid_state');
    }
    _abandoned = true;
    _order._advance(this);
  }

  /// The host has authenticated a reply to this file's exact control request.
  /// This proves first publication even if the local write Future is lost.
  /// It is not a delivery receipt or permission to retire the file owner.
  void confirmReceived() {
    _check();
    if (!_attempted || !canPublish || _issuedEpoch != _order._epoch) {
      throw const FileProtocolFailure('invalid_state');
    }
    if (!_confirmed) {
      _confirmed = true;
      _order._advance(this);
    }
  }

  /// [write] must recheck the original authority and owner immediately before
  /// sending: waiting here never extends their lifetime or makes them current.
  Future<void> publish(Future<void> Function() write, {Future<void>? stopped}) {
    if (_writes.length >= 2 || _order._attempts.length >= 128) {
      return Future.error(const FileProtocolFailure('resource_limit'));
    }
    _attempted = true;
    final attempt = _PublicationAttempt(_order._epoch);
    _writes.add(attempt);
    _order._attempts.add(attempt);
    _wake();
    return _publish(attempt, write, stopped);
  }

  void _wake() {
    final first = _writes.firstOrNull;
    if (canPublish && first != null && !first.ready.isCompleted) {
      first.ready.complete();
    }
  }

  void _check([int? epoch]) {
    if (_order._closed ||
        _order._suspended ||
        _abandoned ||
        (epoch != null && epoch != _order._epoch)) {
      throw const FileProtocolFailure('operation_stopped');
    }
  }

  Future<void> _publish(
    _PublicationAttempt attempt,
    Future<void> Function() write,
    Future<void>? interrupted,
  ) async {
    try {
      _check(attempt.epoch);
      final interruption = interrupted?.then<void>((_) {
        throw const FileProtocolFailure('operation_stopped');
      });
      await Future.any<void>([
        attempt.ready.future,
        attempt.closed.future,
        ?interruption,
      ]);
      _check(attempt.epoch);
      _issuedEpoch = attempt.epoch;
      await Future.any<void>([write(), attempt.closed.future, ?interruption]);
      _check(attempt.epoch);
      if (!_published) {
        _writtenEpoch = attempt.epoch;
        _order._advance(this);
      }
    } finally {
      _order._attempts.remove(attempt);
      _writes.remove(attempt);
      _wake();
    }
  }
}

// Each attempt owns its readiness/close promises. Removing a stopped queue
// entry cannot leave listeners on an earlier file's unresolved Future, and
// cannot release a different attempt that is still writing.
final class _PublicationAttempt {
  _PublicationAttempt(this.epoch);
  final int epoch;
  final ready = Completer<void>(), closed = Completer<void>();
}
