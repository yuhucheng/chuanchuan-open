import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'control_start.dart';
import 'control_input.dart';
import 'control_input_codec.dart';
import 'control_stage.dart';
import 'control_stage_codec.dart';
import 'control_clipboard_codec.dart';
import 'control_clipboard_state.dart';

/// Exact authenticated operation binding, not native admission. A composite
/// owner still needs a shared picture slot, geometry/permission gates and typed
/// signal-role validation. A public context is not native execution consent.
final class ControlContext {
  ControlContext._(this._registry, this.authorization, this.start);

  final GrantRegistry _registry;
  final SessionAuthorization authorization;
  final ControlStart start;
  bool _stopped = false;

  bool get localIsController => authorization is LocalSessionRequest;

  static Future<ControlContext> fromRequest(
    GrantRegistry registry,
    SessionAuthorization authorization,
  ) async {
    await registry.verify(authorization);
    authorization.requireCurrent();
    if (authorization.operation != SessionOperation.control ||
        authorization.sender != GrantRole.initiator) {
      throw const SessionFailure('direction_denied');
    }
    final start = ControlStart.decode(authorization.body);
    authorization.requireCurrent();
    return ControlContext._(registry, authorization, start);
  }

  Future<void> check() async {
    requireCurrent();
    await _registry.verify(authorization);
    requireCurrent();
  }

  void requireCurrent() {
    if (_stopped) throw const SessionFailure('operation_stopped');
    authorization.requireCurrent();
  }

  /// Checks provenance only. Callers must decode a typed message and enforce
  /// its role, stage, sequence and current geometry before any side effect.
  Future<void> verifySignal(VerifiedSessionSignal signal) async {
    if (!identical(signal.authorization, authorization)) {
      throw const SessionFailure('foreign_control_signal');
    }
    await check();
    signal.requireCurrent();
    requireCurrent();
  }

  /// Synchronous gate; does not revoke the connection or claim native cleanup.
  void stop() => _stopped = true;

  /// Typed sender and requested-capability checks. The native owner must still
  /// check negotiated capability, sequence, epoch and currently presented geometry.
  Future<ControlInput> decodeInput(VerifiedSessionSignal signal) async {
    await verifySignal(signal);
    if (localIsController) throw const SessionFailure('direction_denied');
    final input = ControlInputCodec.decode(signal.body);
    _requireRequested(input);
    requireCurrent();
    return input;
  }

  void validateOutgoingInput(ControlInput input) {
    requireCurrent();
    if (!localIsController) throw const SessionFailure('direction_denied');
    _requireRequested(input);
  }

  void _requireRequested(ControlInput input) {
    if (!start.capabilities.contains(input.capability)) {
      throw const SessionFailure('capability_unavailable');
    }
  }

  Future<ControlStage> decodeStage(VerifiedSessionSignal signal) async {
    if (!identical(signal.authorization, authorization)) {
      throw const SessionFailure('foreign_control_signal');
    }
    final stage = ControlStageCodec.decode(signal.body);
    if (_isTerminalStage(stage)) {
      authorization.requireCurrent();
      await _registry.verify(authorization);
      signal.requireCurrent();
      authorization.requireCurrent();
    } else {
      await verifySignal(signal);
    }
    _requirePeerStageRole(stage);
    if (!_isTerminalStage(stage)) requireCurrent();
    return stage;
  }

  void validateOutgoingStage(ControlStage stage) {
    if (_isTerminalStage(stage)) {
      authorization.requireCurrent();
    } else {
      requireCurrent();
    }
    if (stage.fromController != null &&
        stage.fromController != localIsController) {
      throw const SessionFailure('direction_denied');
    }
  }

  bool _isTerminalStage(ControlStage stage) =>
      stage is ControlStop || stage is ControlStopped;

  void _requirePeerStageRole(ControlStage stage) {
    if (stage.fromController != null &&
        stage.fromController == localIsController) {
      throw const SessionFailure('direction_denied');
    }
  }

  Future<ClipboardWireMessage> decodeClipboard(
    VerifiedSessionSignal signal,
  ) async {
    await verifySignal(signal);
    _requireClipboardRequested();
    final message = ControlClipboardCodec.decode(signal.body);
    if (message.fromController != null &&
        message.fromController == localIsController) {
      throw const SessionFailure('direction_denied');
    }
    requireCurrent();
    return message;
  }

  void validateOutgoingClipboard(ClipboardWireMessage message) {
    requireCurrent();
    _requireClipboardRequested();
    if (message.fromController != null &&
        message.fromController != localIsController) {
      throw const SessionFailure('direction_denied');
    }
  }

  void _requireClipboardRequested() {
    if (!start.capabilities.contains(ControlCapability.clipboardText)) {
      throw const SessionFailure('capability_unavailable');
    }
  }
}
