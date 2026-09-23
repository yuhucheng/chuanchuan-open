import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'control_geometry.dart';
import 'control_input.dart';

/// Typed control handshake. Authorization and native cleanup belong to the
/// composite owner; these values cannot grant input by themselves.
sealed class ControlStage {
  const ControlStage();

  /// Null means either authenticated side may send this stage.
  bool? get fromController;
}

final class ControlGeometryPublished extends ControlStage {
  const ControlGeometryPublished(this.geometry);
  final ControlGeometry geometry;
  @override
  bool? get fromController => false;
}

final class ControlGeometryReady extends ControlStage {
  ControlGeometryReady({
    required this.sourceToken,
    required this.geometryRevision,
    required this.mediaRevision,
  }) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(sourceToken) ||
        geometryRevision < 1 ||
        geometryRevision > 0x7fffffffffffffff ||
        mediaRevision < 0 ||
        mediaRevision > 0x7fffffff) {
      throw const SessionFailure('invalid_range');
    }
  }
  final String sourceToken;
  final int geometryRevision, mediaRevision;
  @override
  bool? get fromController => true;
}

final class ControlInputReady extends ControlStage {
  ControlInputReady({
    required this.geometryRevision,
    required this.inputEpoch,
  }) {
    _positive(geometryRevision);
    _positive(inputEpoch);
  }
  final int geometryRevision, inputEpoch;
  @override
  bool? get fromController => false;
}

final class ControlReleaseAll extends ControlStage {
  ControlReleaseAll({required this.inputEpoch}) {
    _positive(inputEpoch);
  }
  final int inputEpoch;
  @override
  bool? get fromController => true;
}

final class ControlReleased extends ControlStage {
  ControlReleased({required this.inputEpoch}) {
    _positive(inputEpoch);
  }
  final int inputEpoch;
  @override
  bool? get fromController => false;
}

final class ControlStop extends ControlStage {
  const ControlStop();
  @override
  bool? get fromController => null;
}

final class ControlStopped extends ControlStage {
  const ControlStopped();
  @override
  bool? get fromController => null;
}

void _positive(int value) {
  if (value < 1 || value > 0x7fffffffffffffff) {
    throw const SessionFailure('invalid_range');
  }
}

/// One target-side gate. Caller first stops native admission and drains owned
/// work before completing release; this pure state does not claim OS cleanup.
final class ControlInputGate {
  ControlGeometry? _geometry;
  bool _ready = false, _enabled = false, _releasing = false, _stopped = false;
  bool _geometryChangedDuringRelease = false;
  bool _pictureInvalidated = false, _localPictureRelease = false;
  int _epoch = 0, _sequence = 0;

  bool get canAcceptInput => !_stopped && _enabled && !_releasing;
  void publish(ControlGeometry geometry) {
    _current();
    if (_geometry != null && geometry.revision <= _geometry!.revision) {
      throw const SessionFailure('stale_geometry');
    }
    _enabled = false;
    _ready = false;
    if (_releasing) _geometryChangedDuringRelease = true;
    _geometry = geometry;
    _pictureInvalidated = false;
  }

  void geometryReady(ControlGeometryReady message) {
    _current();
    final current = _geometry;
    if (current == null ||
        _enabled ||
        _releasing ||
        _ready ||
        _pictureInvalidated ||
        current.sourceToken != message.sourceToken ||
        current.revision != message.geometryRevision ||
        current.mediaRevision != message.mediaRevision) {
      throw const SessionFailure('stale_geometry');
    }
    _ready = true;
  }

  ControlInputReady enable({required int inputEpoch}) {
    _current();
    _positive(inputEpoch);
    if (_epoch == 0x7fffffffffffffff) {
      throw const SessionFailure('operation_limit');
    }
    if (!_ready ||
        _enabled ||
        _releasing ||
        _geometry == null ||
        inputEpoch != _epoch + 1) {
      throw const SessionFailure('invalid_state');
    }
    _epoch = inputEpoch;
    _enabled = true;
    return ControlInputReady(
      geometryRevision: _geometry!.revision,
      inputEpoch: inputEpoch,
    );
  }

  void admit(ControlInput input) {
    _current();
    if (!_enabled ||
        _releasing ||
        input.inputEpoch != _epoch ||
        input.geometryRevision != _geometry?.revision ||
        input.sequence <= _sequence) {
      throw const SessionFailure('stale_operation');
    }
    _sequence = input.sequence;
  }

  void beginRelease(ControlReleaseAll request) {
    _current();
    if (!_enabled || _releasing || request.inputEpoch != _epoch) {
      throw const SessionFailure('invalid_state');
    }
    _enabled = false;
    _releasing = true;
    _geometryChangedDuringRelease = false;
  }

  /// Local capture/source loss, independent of a peer focus message. Returns
  /// false when an existing focus barrier already owns native cleanup.
  bool invalidatePicture() {
    _current();
    _pictureInvalidated = true;
    _enabled = false;
    _ready = false;
    _geometryChangedDuringRelease = true;
    if (_releasing) return false;
    _releasing = true;
    _localPictureRelease = true;
    return true;
  }

  void finishPictureInvalidation() {
    _current();
    if (!_releasing || !_localPictureRelease) {
      throw const SessionFailure('invalid_state');
    }
    _releasing = false;
    _localPictureRelease = false;
    _geometryChangedDuringRelease = false;
  }

  ControlReleased finishRelease({required int inputEpoch}) {
    _current();
    _positive(inputEpoch);
    if (_epoch == 0x7fffffffffffffff) {
      throw const SessionFailure('operation_limit');
    }
    if (!_releasing || _localPictureRelease || inputEpoch != _epoch + 1) {
      throw const SessionFailure('invalid_state');
    }
    _epoch = inputEpoch;
    _releasing = false;
    _enabled = !_geometryChangedDuringRelease;
    _geometryChangedDuringRelease = false;
    return ControlReleased(inputEpoch: inputEpoch);
  }

  void stop() {
    _stopped = true;
    _enabled = false;
    _ready = false;
  }

  void _current() {
    if (_stopped) throw const SessionFailure('operation_stopped');
  }
}
