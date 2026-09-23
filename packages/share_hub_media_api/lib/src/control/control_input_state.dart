import 'dart:collection';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'control_geometry.dart';
import 'control_input.dart';
import 'control_stage.dart';

/// Pure target-side admission and dispatch ledger. The caller serializes
/// native execution, reports its actual result, and releases held OS state.
final class ControlInputState {
  ControlInputState({required int Function() monotonicMicros})
    : _clock = monotonicMicros;

  static const maximumPending = 64;
  static const maximumKeys = 32;
  static const _tokenUnit = 1000000;
  static const _burstUnits = 64 * _tokenUnit;

  final int Function() _clock;
  final ControlInputGate _gate = ControlInputGate();
  final Queue<ControlInput> _pending = Queue<ControlInput>();
  final Set<int> _pressedKeys = <int>{};
  final Set<ControlButton> _pressedButtons = <ControlButton>{};
  ControlInput? _inFlight;
  int? _lastMicros;
  int _tokenUnits = _burstUnits;
  bool _stopped = false;

  bool get isStopped => _stopped;
  bool get hasInFlight => _inFlight != null;
  int get pendingCount => _pending.length;
  List<int> get pressedKeys => List<int>.unmodifiable(_pressedKeys);
  List<ControlButton> get pressedButtons =>
      List<ControlButton>.unmodifiable(_pressedButtons);

  void publish(ControlGeometry geometry) {
    _gate.publish(geometry);
    _pending.clear();
  }

  void geometryReady(ControlGeometryReady message) =>
      _gate.geometryReady(message);

  ControlInputReady enable({required int inputEpoch}) {
    if (_inFlight != null ||
        _pressedKeys.isNotEmpty ||
        _pressedButtons.isNotEmpty) {
      throw const SessionFailure('invalid_state');
    }
    return _gate.enable(inputEpoch: inputEpoch);
  }

  /// A failed edge or rate admission stops the operation so key-up cannot be
  /// silently lost. The native owner must still drain and release held state.
  void offer(ControlInput input) {
    _gate.admit(input);
    _refill();
    if (_tokenUnits < _tokenUnit) {
      stop();
      throw const SessionFailure('rate_limit');
    }
    _tokenUnits -= _tokenUnit;
    if (input is ControlPointerMove &&
        _pending.isNotEmpty &&
        _pending.last is ControlPointerMove) {
      _pending.removeLast();
      _pending.addLast(input);
      return;
    }
    if (_pending.length >= maximumPending) {
      stop();
      throw const SessionFailure('rate_limit');
    }
    _pending.addLast(input);
  }

  /// At most one native call is outstanding. Duplicate transitions are
  /// discarded before a call; results are entered only by [complete].
  ControlInput? takeNext({bool Function(int usage)? canRepeat}) {
    if (_inFlight != null) throw const SessionFailure('invalid_state');
    if (!_gate.canAcceptInput || _stopped) return null;
    while (_pending.isNotEmpty) {
      final input = _pending.removeFirst();
      if (!_shouldExecute(input, canRepeat)) continue;
      _inFlight = input;
      return input;
    }
    return null;
  }

  void complete(ControlInput input, {required bool succeeded}) {
    if (!identical(_inFlight, input)) {
      throw const SessionFailure('invalid_state');
    }
    _inFlight = null;
    if (!succeeded) {
      stop();
      return;
    }
    if (input is ControlKey) {
      switch (input.action) {
        case ControlKeyAction.down:
          _pressedKeys.add(input.usage);
        case ControlKeyAction.up:
          _pressedKeys.remove(input.usage);
        case ControlKeyAction.repeat:
          break;
      }
    } else if (input is ControlPointerButton) {
      if (input.down) {
        _pressedButtons.add(input.button);
      } else {
        _pressedButtons.remove(input.button);
      }
    }
  }

  /// Only for a call that was taken from the queue but has not entered the OS.
  /// The native owner must never use this after invoking its adapter.
  void cancelUnexecuted(ControlInput input) {
    if (!identical(_inFlight, input)) {
      throw const SessionFailure('invalid_state');
    }
    _inFlight = null;
  }

  void beginRelease(ControlReleaseAll request) {
    _gate.beginRelease(request);
    _pending.clear();
  }

  bool invalidatePicture() {
    final ownsRelease = _gate.invalidatePicture();
    _pending.clear();
    return ownsRelease;
  }

  void finishPictureInvalidation() {
    if (_inFlight != null ||
        _pressedKeys.isNotEmpty ||
        _pressedButtons.isNotEmpty) {
      throw const SessionFailure('invalid_state');
    }
    _gate.finishPictureInvalidation();
  }

  ControlReleased finishRelease({required int inputEpoch}) {
    if (_inFlight != null ||
        _pressedKeys.isNotEmpty ||
        _pressedButtons.isNotEmpty) {
      throw const SessionFailure('invalid_state');
    }
    return _gate.finishRelease(inputEpoch: inputEpoch);
  }

  /// Call only after the native release of this exact held key succeeded.
  void markKeyReleased(int usage) {
    if (_inFlight != null) throw const SessionFailure('invalid_state');
    if (!_pressedKeys.remove(usage)) {
      throw const SessionFailure('invalid_state');
    }
  }

  /// Call only after the native release of this exact held button succeeded.
  void markButtonReleased(ControlButton button) {
    if (_inFlight != null) throw const SessionFailure('invalid_state');
    if (!_pressedButtons.remove(button)) {
      throw const SessionFailure('invalid_state');
    }
  }

  void stop() {
    _stopped = true;
    _gate.stop();
    _pending.clear();
  }

  bool _shouldExecute(ControlInput input, bool Function(int usage)? canRepeat) {
    if (input is ControlKey) {
      final held = _pressedKeys.contains(input.usage);
      switch (input.action) {
        case ControlKeyAction.down:
          if (held) return false;
          if (_pressedKeys.length >= maximumKeys) {
            stop();
            throw const SessionFailure('operation_limit');
          }
          return true;
        case ControlKeyAction.up:
          return held;
        case ControlKeyAction.repeat:
          return held && (canRepeat?.call(input.usage) ?? false);
      }
    }
    if (input is ControlPointerButton) {
      return _pressedButtons.contains(input.button) != input.down;
    }
    return true;
  }

  void _refill() {
    final now = _clock();
    final last = _lastMicros;
    if (now < 0 || (last != null && now < last)) {
      stop();
      throw const SessionFailure('invalid_state');
    }
    _lastMicros = now;
    if (last == null) return;
    final elapsed = now - last;
    if (elapsed >= _tokenUnit) {
      _tokenUnits = _burstUnits;
    } else {
      final refilled = _tokenUnits + elapsed * 240;
      _tokenUnits = refilled < _burstUnits ? refilled : _burstUnits;
    }
  }
}
