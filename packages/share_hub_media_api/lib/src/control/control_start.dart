import 'dart:convert';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'control_wire.dart';

/// Requested operations, not a claim that a native executor supports them.
enum ControlCapability {
  pointer('pointer'),
  wheel('wheel'),
  physicalKey('physical-key'),
  textInput('text-input'),
  clipboardText('clipboard-text');

  const ControlCapability(this.wireName);
  final String wireName;
}

/// Versioned control-start profile. It cannot select a source, extend a
/// grant, reserve a picture or authorize native input by itself.
final class ControlStart {
  ControlStart(Set<ControlCapability> capabilities)
    : capabilities = Set.unmodifiable(capabilities) {
    if (capabilities.isEmpty) throw const SessionFailure('invalid_message');
  }

  static const version = 1;
  static const maximumBytes = 4096;
  final Set<ControlCapability> capabilities;

  String encode() => jsonEncode({
    'v': version,
    'type': 'start',
    'capabilities': [
      for (final capability in ControlCapability.values)
        if (capabilities.contains(capability)) capability.wireName,
    ],
  });

  static ControlStart decode(String body) {
    final decoded = controlObject(body, maximumBytes: maximumBytes);
    if (decoded.length != 3 ||
        !decoded.keys.toSet().containsAll({'v', 'type', 'capabilities'}) ||
        decoded['v'] is! int ||
        decoded['type'] != 'start' ||
        decoded['capabilities'] is! List) {
      throw const SessionFailure('invalid_message');
    }
    if (decoded['v'] != version) {
      throw const SessionFailure('incompatible_version');
    }
    final values = decoded['capabilities'] as List;
    if (values.isEmpty || values.length > ControlCapability.values.length) {
      throw const SessionFailure('invalid_message');
    }
    final capabilities = <ControlCapability>{};
    for (final value in values) {
      final capability = ControlCapability.values
          .where((capability) => capability.wireName == value)
          .firstOrNull;
      if (capability == null || !capabilities.add(capability)) {
        throw const SessionFailure('invalid_message');
      }
    }
    return ControlStart(capabilities);
  }
}
