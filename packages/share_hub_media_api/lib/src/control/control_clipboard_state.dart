import 'dart:convert';

import 'package:share_hub_session_api/share_hub_session_api.dart';

const _maximumCounter = 0x7fffffffffffffff;
final _monotonicStopwatch = Stopwatch()..start();

int _defaultMonotonicMicros() => _monotonicStopwatch.elapsedMicroseconds;

final class _ClipboardRate {
  _ClipboardRate(this._clock);
  final int Function() _clock;
  int? _lastMicros;
  int _units = 2000000;

  bool tryTake() {
    final now = _clock();
    final last = _lastMicros;
    if (now < 0 || (last != null && now < last)) {
      throw const SessionFailure('invalid_state');
    }
    _lastMicros = now;
    if (last != null) {
      final elapsed = now - last;
      _units = elapsed >= 500000
          ? 2000000
          : (_units + elapsed * 4).clamp(0, 2000000);
    }
    if (_units < 1000000) return false;
    _units -= 1000000;
    return true;
  }
}

sealed class ClipboardWireMessage {
  const ClipboardWireMessage();
  bool? get fromController;
}

final class ClipboardSideState extends ClipboardWireMessage {
  ClipboardSideState({
    required this.revision,
    required this.enabled,
    required this.available,
  }) {
    _positive(revision);
  }
  final int revision;
  final bool enabled, available;
  bool get permitsSync => enabled && available;
  @override
  bool? get fromController => null;
}

/// Null text means no plain-text format. The empty string is valid text.
final class ClipboardReady extends ClipboardWireMessage {
  ClipboardReady({
    required this.epoch,
    required this.controllerStateRevision,
    required this.targetStateRevision,
    required this.text,
  }) {
    _positive(epoch);
    _positive(controllerStateRevision);
    _positive(targetStateRevision);
    _text(text);
  }
  final int epoch, controllerStateRevision, targetStateRevision;
  final String? text;
  @override
  bool? get fromController => false;
}

final class ClipboardProposal extends ClipboardWireMessage {
  ClipboardProposal({
    required this.epoch,
    required this.controllerStateRevision,
    required this.targetStateRevision,
    required this.updateSequence,
    required this.updateId,
    required this.baseRevision,
    required this.text,
  }) {
    for (final value in [
      epoch,
      controllerStateRevision,
      targetStateRevision,
      updateSequence,
      baseRevision,
    ]) {
      _positive(value);
    }
    _id(updateId);
    _text(text);
  }
  final int epoch, controllerStateRevision, targetStateRevision;
  final int updateSequence, baseRevision;
  final String updateId, text;
  @override
  bool? get fromController => true;
}

final class ClipboardCommit extends ClipboardWireMessage {
  ClipboardCommit({
    required this.epoch,
    required this.controllerStateRevision,
    required this.targetStateRevision,
    required this.revision,
    required this.text,
    this.sourceUpdateId,
  }) {
    for (final value in [
      epoch,
      controllerStateRevision,
      targetStateRevision,
      revision,
    ]) {
      _positive(value);
    }
    _text(text);
    if (sourceUpdateId != null) _id(sourceUpdateId!);
  }
  final int epoch, controllerStateRevision, targetStateRevision, revision;
  final String? text, sourceUpdateId;
  @override
  bool? get fromController => false;
}

sealed class ClipboardProposalDecision {
  const ClipboardProposalDecision();
}

final class ClipboardConflict extends ClipboardProposalDecision
    implements ClipboardWireMessage {
  ClipboardConflict({required this.updateId, required this.current}) {
    _id(updateId);
  }
  final String updateId;
  final ClipboardCommit current;
  @override
  bool? get fromController => false;
}

final class ClipboardWriteFailed extends ClipboardWireMessage {
  ClipboardWriteFailed({
    required this.epoch,
    required this.controllerStateRevision,
    required this.targetStateRevision,
    required this.updateId,
  }) {
    _positive(epoch);
    _positive(controllerStateRevision);
    _positive(targetStateRevision);
    _id(updateId);
  }
  final int epoch, controllerStateRevision, targetStateRevision;
  final String updateId;
  @override
  bool? get fromController => false;
}

/// A native write is allowed only while this exact ticket remains current.
final class ClipboardWriteTicket extends ClipboardProposalDecision {
  const ClipboardWriteTicket._(this.proposal, this.revisionAtAdmission);
  final ClipboardProposal proposal;
  final int revisionAtAdmission;
}

enum ClipboardApply { applyRemote, retainLocal }

/// Target is the protocol arbiter. Native owner must recheck [canWrite] under
/// its actual OS-write admission boundary and report the result.
final class ClipboardTargetState {
  ClipboardTargetState({int Function()? monotonicMicros})
    : _rate = _ClipboardRate(monotonicMicros ?? _defaultMonotonicMicros);

  final _ClipboardRate _rate;
  int _epoch = 0, _controllerStateRevision = 0, _targetStateRevision = 0;
  int _revision = 0, _sequence = 0;
  String? _authoritativeText, _lastUpdateId, _lastUpdateText;
  ClipboardWriteTicket? _pending;
  ClipboardCommit? _pendingLocalCommit, _pendingResult;
  bool _active = false;

  int get revision => _revision;
  String? get authoritativeText => _authoritativeText;
  int get pendingWrites => _pending == null ? 0 : 1;
  int get pendingCommits =>
      (_pendingLocalCommit == null ? 0 : 1) + (_pendingResult == null ? 0 : 1);

  ClipboardReady open({
    required int epoch,
    required ClipboardSideState controllerState,
    required ClipboardSideState targetState,
    required bool pictureReady,
    required String? initialText,
  }) {
    _positive(epoch);
    _text(initialText);
    if (!controllerState.permitsSync ||
        !targetState.permitsSync ||
        !pictureReady) {
      throw const SessionFailure('not_ready');
    }
    if (_active || epoch <= _epoch) {
      throw const SessionFailure('stale_operation');
    }
    _epoch = epoch;
    _controllerStateRevision = controllerState.revision;
    _targetStateRevision = targetState.revision;
    _revision = 1;
    _authoritativeText = initialText;
    _lastUpdateId = null;
    _lastUpdateText = null;
    _pending = null;
    _pendingLocalCommit = null;
    _pendingResult = null;
    _active = true;
    return ClipboardReady(
      epoch: epoch,
      controllerStateRevision: controllerState.revision,
      targetStateRevision: targetState.revision,
      text: initialText,
    );
  }

  void localCopy(String text) {
    _current();
    _text(text);
    _advance();
    _authoritativeText = text;
    _pendingLocalCommit = _commit();
  }

  /// A pending remote result is never dropped. Unsent local copies collapse to
  /// their latest authority revision under the 4/s, burst-2 send budget.
  ClipboardCommit? takeCommit() {
    _current();
    final result = _pendingResult;
    final next = result ?? _pendingLocalCommit;
    if (next == null || !_rate.tryTake()) return null;
    if (result != null) {
      _pendingResult = null;
      if (_pendingLocalCommit != null &&
          _pendingLocalCommit!.revision <= result.revision) {
        _pendingLocalCommit = null;
      }
    } else {
      _pendingLocalCommit = null;
    }
    return next;
  }

  ClipboardProposalDecision receiveProposal(ClipboardProposal proposal) {
    _current();
    _match(
      proposal.epoch,
      proposal.controllerStateRevision,
      proposal.targetStateRevision,
    );
    if (proposal.updateSequence <= _sequence) {
      throw const SessionFailure('stale_operation');
    }
    _sequence = proposal.updateSequence;
    if (proposal.updateId == _lastUpdateId) {
      throw SessionFailure(
        proposal.text == _lastUpdateText
            ? 'stale_operation'
            : 'invalid_message',
      );
    }
    _lastUpdateId = proposal.updateId;
    _lastUpdateText = proposal.text;
    if (_pending != null || _pendingResult != null) {
      throw const SessionFailure('busy');
    }
    if (proposal.baseRevision != _revision) {
      _pendingLocalCommit = null;
      return ClipboardConflict(updateId: proposal.updateId, current: _commit());
    }
    final ticket = ClipboardWriteTicket._(proposal, _revision);
    _pending = ticket;
    return ticket;
  }

  bool canWrite(ClipboardWriteTicket ticket) =>
      _active &&
      identical(_pending, ticket) &&
      ticket.revisionAtAdmission == _revision &&
      ticket.proposal.epoch == _epoch &&
      ticket.proposal.controllerStateRevision == _controllerStateRevision &&
      ticket.proposal.targetStateRevision == _targetStateRevision;

  void completeWrite(ClipboardWriteTicket ticket, {required bool succeeded}) {
    if (!canWrite(ticket)) {
      if (identical(_pending, ticket)) _pending = null;
      throw const SessionFailure('stale_operation');
    }
    _pending = null;
    if (!succeeded) {
      invalidate();
      throw const SessionFailure('execution_failed');
    }
    _advance();
    _authoritativeText = ticket.proposal.text;
    _pendingResult = _commit(sourceUpdateId: ticket.proposal.updateId);
  }

  /// The OS change token moved before the remote write. Promote the newly
  /// observed local plain text and tell the controller to rebase. The host must
  /// read that text from the same scoped clipboard lease after the conflict.
  ClipboardConflict nativeConflict(
    ClipboardWriteTicket ticket, {
    required String observedText,
  }) {
    _current();
    if (!canWrite(ticket)) throw const SessionFailure('stale_operation');
    _text(observedText);
    _advance();
    _pending = null;
    _pendingLocalCommit = null;
    _authoritativeText = observedText;
    return ClipboardConflict(
      updateId: ticket.proposal.updateId,
      current: _commit(),
    );
  }

  /// Input focus only changes inputEpoch, never clipboardEpoch.
  void inputFocusLost() {}

  void settingsChanged({
    required ClipboardSideState controllerState,
    required ClipboardSideState targetState,
  }) {
    if (_active &&
        (!controllerState.permitsSync ||
            !targetState.permitsSync ||
            controllerState.revision != _controllerStateRevision ||
            targetState.revision != _targetStateRevision)) {
      invalidate();
    }
  }

  void pictureLost() => invalidate();

  void invalidate() {
    _active = false;
    _pending = null;
    _pendingLocalCommit = null;
    _pendingResult = null;
    _authoritativeText = null;
    _lastUpdateId = null;
    _lastUpdateText = null;
  }

  ClipboardCommit _commit({String? sourceUpdateId}) => ClipboardCommit(
    epoch: _epoch,
    controllerStateRevision: _controllerStateRevision,
    targetStateRevision: _targetStateRevision,
    revision: _revision,
    text: _authoritativeText,
    sourceUpdateId: sourceUpdateId,
  );

  void _advance() {
    if (_revision == _maximumCounter) {
      invalidate();
      throw const SessionFailure('operation_limit');
    }
    _revision++;
  }

  void _current() {
    if (!_active) throw const SessionFailure('operation_stopped');
  }

  void _match(int epoch, int controllerRevision, int targetRevision) {
    if (epoch != _epoch ||
        controllerRevision != _controllerStateRevision ||
        targetRevision != _targetStateRevision) {
      throw const SessionFailure('stale_operation');
    }
  }
}

typedef _LocalCopy = ({String text, String updateId, int generation});
typedef _SentCopy = ({ClipboardProposal proposal, int generation});

/// Controller keeps only its newest unsent local text and one sent proposal.
final class ClipboardControllerState {
  ClipboardControllerState({int Function()? monotonicMicros})
    : _rate = _ClipboardRate(monotonicMicros ?? _defaultMonotonicMicros);

  final _ClipboardRate _rate;
  int _epoch = 0, _controllerStateRevision = 0, _targetStateRevision = 0;
  int _revision = 0, _sequence = 0, _localGeneration = 0;
  String? _authoritativeText;
  _LocalCopy? _pendingLocal;
  _SentCopy? _inFlight;
  bool _active = false;

  int get revision => _revision;
  String? get authoritativeText => _authoritativeText;
  int get pendingUpdates =>
      (_pendingLocal == null ? 0 : 1) + (_inFlight == null ? 0 : 1);

  void acceptReady(
    ClipboardReady ready, {
    required ClipboardSideState controllerState,
    required ClipboardSideState targetState,
    required bool pictureReady,
  }) {
    if (!controllerState.permitsSync ||
        !targetState.permitsSync ||
        !pictureReady ||
        _active ||
        ready.epoch <= _epoch ||
        ready.controllerStateRevision != controllerState.revision ||
        ready.targetStateRevision != targetState.revision) {
      throw const SessionFailure('stale_operation');
    }
    _epoch = ready.epoch;
    _controllerStateRevision = controllerState.revision;
    _targetStateRevision = targetState.revision;
    _revision = 1;
    _authoritativeText = ready.text;
    _pendingLocal = null;
    _inFlight = null;
    _active = true;
  }

  void localCopy(String text, {required String updateId}) {
    _current();
    _text(text);
    _id(updateId);
    if (_localGeneration == _maximumCounter) {
      invalidate();
      throw const SessionFailure('operation_limit');
    }
    _localGeneration++;
    _pendingLocal = (
      text: text,
      updateId: updateId,
      generation: _localGeneration,
    );
  }

  ClipboardProposal? takeProposal() {
    _current();
    final copy = _pendingLocal;
    if (copy == null || _inFlight != null) return null;
    if (_sequence == _maximumCounter) {
      invalidate();
      throw const SessionFailure('operation_limit');
    }
    if (!_rate.tryTake()) return null;
    final proposal = ClipboardProposal(
      epoch: _epoch,
      controllerStateRevision: _controllerStateRevision,
      targetStateRevision: _targetStateRevision,
      updateSequence: ++_sequence,
      updateId: copy.updateId,
      baseRevision: _revision,
      text: copy.text,
    );
    _pendingLocal = null;
    _inFlight = (proposal: proposal, generation: copy.generation);
    return proposal;
  }

  ClipboardApply receiveCommit(ClipboardCommit commit) {
    _current();
    _match(
      commit.epoch,
      commit.controllerStateRevision,
      commit.targetStateRevision,
    );
    if (commit.revision <= _revision) {
      throw const SessionFailure('stale_operation');
    }
    _revision = commit.revision;
    _authoritativeText = commit.text;
    final sent = _inFlight;
    if (sent != null && commit.sourceUpdateId == sent.proposal.updateId) {
      _inFlight = null;
    }
    return _pendingLocal == null
        ? ClipboardApply.applyRemote
        : ClipboardApply.retainLocal;
  }

  ClipboardApply receiveConflict(ClipboardConflict conflict) {
    _current();
    final current = conflict.current;
    _match(
      current.epoch,
      current.controllerStateRevision,
      current.targetStateRevision,
    );
    final sent = _inFlight;
    if (sent == null ||
        sent.proposal.updateId != conflict.updateId ||
        current.revision < _revision) {
      throw const SessionFailure('stale_operation');
    }
    _inFlight = null;
    _revision = current.revision;
    _authoritativeText = current.text;
    return _pendingLocal == null
        ? ClipboardApply.applyRemote
        : ClipboardApply.retainLocal;
  }

  void inputFocusLost() {}

  void settingsChanged({
    required ClipboardSideState controllerState,
    required ClipboardSideState targetState,
  }) {
    if (_active &&
        (!controllerState.permitsSync ||
            !targetState.permitsSync ||
            controllerState.revision != _controllerStateRevision ||
            targetState.revision != _targetStateRevision)) {
      invalidate();
    }
  }

  void pictureLost() => invalidate();

  void invalidate() {
    _active = false;
    _authoritativeText = null;
    _pendingLocal = null;
    _inFlight = null;
  }

  void _current() {
    if (!_active) throw const SessionFailure('operation_stopped');
  }

  void _match(int epoch, int controllerRevision, int targetRevision) {
    if (epoch != _epoch ||
        controllerRevision != _controllerStateRevision ||
        targetRevision != _targetStateRevision) {
      throw const SessionFailure('stale_operation');
    }
  }
}

void _positive(int value) {
  if (value < 1 || value > _maximumCounter) {
    throw const SessionFailure('invalid_range');
  }
}

void _id(String value) {
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    throw const SessionFailure('invalid_range');
  }
}

void _text(String? value) {
  if (value == null) return;
  if (value.length > 32768) throw const SessionFailure('message_limit');
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= value.length ||
          value.codeUnitAt(i) < 0xdc00 ||
          value.codeUnitAt(i) > 0xdfff) {
        throw const SessionFailure('invalid_message');
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw const SessionFailure('invalid_message');
    }
  }
  if (utf8.encode(value).length > 32768) {
    throw const SessionFailure('message_limit');
  }
}
