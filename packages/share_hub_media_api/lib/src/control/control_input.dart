import 'dart:convert';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'control_start.dart';

enum ControlButton { primary, secondary, middle, back, forward }

enum ControlKeyAction { down, up, repeat }

/// Validated data only. Current owner, geometry, sequence, permissions and
/// native execution must still be checked by the composite control owner.
sealed class ControlInput {
  ControlInput({
    required this.sequence,
    required this.inputEpoch,
    required this.geometryRevision,
  }) {
    for (final value in [sequence, inputEpoch, geometryRevision]) {
      if (value < 1 || value > 0x7fffffffffffffff) {
        throw const SessionFailure('invalid_range');
      }
    }
  }
  final int sequence, inputEpoch, geometryRevision;
  ControlCapability get capability;
}

sealed class ControlPointer extends ControlInput {
  ControlPointer({
    required super.sequence,
    required super.inputEpoch,
    required super.geometryRevision,
    required this.x,
    required this.y,
  }) {
    if (!x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
      throw const SessionFailure('invalid_range');
    }
  }
  final double x, y;
}

final class ControlPointerMove extends ControlPointer {
  ControlPointerMove({
    required super.sequence,
    required super.inputEpoch,
    required super.geometryRevision,
    required super.x,
    required super.y,
  });
  @override
  ControlCapability get capability => ControlCapability.pointer;
}

final class ControlPointerButton extends ControlPointer {
  ControlPointerButton({
    required super.sequence,
    required super.inputEpoch,
    required super.geometryRevision,
    required super.x,
    required super.y,
    required this.button,
    required this.down,
  });
  final ControlButton button;
  final bool down;
  @override
  ControlCapability get capability => ControlCapability.pointer;
}

final class ControlWheel extends ControlPointer {
  ControlWheel({
    required super.sequence,
    required super.inputEpoch,
    required super.geometryRevision,
    required super.x,
    required super.y,
    required this.deltaX,
    required this.deltaY,
  }) {
    if (!deltaX.isFinite ||
        !deltaY.isFinite ||
        deltaX.abs() > 120 ||
        deltaY.abs() > 120 ||
        (deltaX == 0 && deltaY == 0)) {
      throw const SessionFailure('invalid_range');
    }
  }
  final double deltaX, deltaY;
  @override
  ControlCapability get capability => ControlCapability.wheel;
}

final class ControlKey extends ControlInput {
  ControlKey({
    required super.sequence,
    required super.inputEpoch,
    required super.geometryRevision,
    required this.usage,
    required this.action,
  }) {
    // USB keyboard page: ordinary keys, keypad/F13-F24 and modifiers. Exclude
    // error/reserved codes and Power (0x66); never accept native scan codes.
    if (!((usage >= 0x04 && usage <= 0x65) ||
        (usage >= 0x67 && usage <= 0x73) ||
        (usage >= 0xe0 && usage <= 0xe7))) {
      throw const SessionFailure('invalid_range');
    }
  }
  final int usage;
  final ControlKeyAction action;
  @override
  ControlCapability get capability => ControlCapability.physicalKey;
}

final class ControlTextInput extends ControlInput {
  ControlTextInput({
    required super.sequence,
    required super.inputEpoch,
    required super.geometryRevision,
    required this.text,
  }) {
    if (text.isEmpty || text.length > maximumBytes) {
      throw const SessionFailure('message_limit');
    }
    // Dart's UTF-8 encoder replaces unpaired surrogates; reject rather than
    // silently changing text before authenticating or submitting it.
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= text.length ||
            text.codeUnitAt(i) < 0xdc00 ||
            text.codeUnitAt(i) > 0xdfff) {
          throw const SessionFailure('invalid_message');
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw const SessionFailure('invalid_message');
      }
    }
    if (utf8.encode(text).length > maximumBytes) {
      throw const SessionFailure('message_limit');
    }
  }
  static const maximumBytes = 8192;
  final String text;
  @override
  ControlCapability get capability => ControlCapability.textInput;
}
