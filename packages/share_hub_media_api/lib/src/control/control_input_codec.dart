import 'dart:convert';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'control_input.dart';
import 'control_wire.dart';

abstract final class ControlInputCodec {
  static const maximumBytes = 48 * 1024;
  static const ordinaryBytes = 4096;

  static String encode(ControlInput input) => jsonEncode({
    'v': 1,
    'type': switch (input) {
      ControlPointerMove() => 'pointer-move',
      ControlPointerButton() => 'pointer-button',
      ControlWheel() => 'wheel',
      ControlKey() => 'key',
      ControlTextInput() => 'text-input',
    },
    'sequence': '${input.sequence}',
    'inputEpoch': '${input.inputEpoch}',
    'geometryRevision': '${input.geometryRevision}',
    if (input is ControlPointer) ...{'x': input.x, 'y': input.y},
    if (input is ControlPointerButton) ...{
      'button': input.button.name,
      'down': input.down,
    },
    if (input is ControlWheel) ...{
      'deltaX': input.deltaX,
      'deltaY': input.deltaY,
    },
    if (input is ControlKey) ...{
      'usage': input.usage,
      'action': input.action.name,
    },
    if (input is ControlTextInput)
      'utf8': base64Url.encode(utf8.encode(input.text)).replaceAll('=', ''),
  });

  static ControlInput decode(String body) {
    final m = controlObject(body, maximumBytes: maximumBytes);
    if (m['v'] is! int) _invalid();
    if (m['v'] != 1) throw const SessionFailure('incompatible_version');
    final type = m['type'];
    final fields = switch (type) {
      'pointer-move' => {'x', 'y'},
      'pointer-button' => {'x', 'y', 'button', 'down'},
      'wheel' => {'x', 'y', 'deltaX', 'deltaY'},
      'key' => {'usage', 'action'},
      'text-input' => {'utf8'},
      _ => <String>{},
    };
    if (fields.isEmpty) _invalid();
    final expected = {
      'v',
      'type',
      'sequence',
      'inputEpoch',
      'geometryRevision',
      ...fields,
    };
    if (m.length != expected.length || !m.keys.toSet().containsAll(expected)) {
      _invalid();
    }
    if (type != 'text-input' && utf8.encode(body).length > ordinaryBytes) {
      throw const SessionFailure('message_limit');
    }
    final sequence = _counter(m['sequence']);
    final epoch = _counter(m['inputEpoch']);
    final geometry = _counter(m['geometryRevision']);
    return switch (type) {
      'pointer-move' => ControlPointerMove(
        sequence: sequence,
        inputEpoch: epoch,
        geometryRevision: geometry,
        x: _number(m['x']),
        y: _number(m['y']),
      ),
      'pointer-button' => ControlPointerButton(
        sequence: sequence,
        inputEpoch: epoch,
        geometryRevision: geometry,
        x: _number(m['x']),
        y: _number(m['y']),
        button: _enum(ControlButton.values, m['button']),
        down: _boolean(m['down']),
      ),
      'wheel' => ControlWheel(
        sequence: sequence,
        inputEpoch: epoch,
        geometryRevision: geometry,
        x: _number(m['x']),
        y: _number(m['y']),
        deltaX: _number(m['deltaX']),
        deltaY: _number(m['deltaY']),
      ),
      'key' => ControlKey(
        sequence: sequence,
        inputEpoch: epoch,
        geometryRevision: geometry,
        usage: _integer(m['usage']),
        action: _enum(ControlKeyAction.values, m['action']),
      ),
      'text-input' => ControlTextInput(
        sequence: sequence,
        inputEpoch: epoch,
        geometryRevision: geometry,
        text: _text(m['utf8']),
      ),
      _ => _invalid(),
    };
  }

  static int _counter(Object? value) {
    if (value is! String ||
        value.length > 19 ||
        !RegExp(r'^[1-9][0-9]*$').hasMatch(value)) {
      _invalid();
    }
    final number = int.tryParse(value);
    if (number == null || number < 1) _invalid();
    return number;
  }

  static double _number(Object? value) {
    if (value is! num || !value.isFinite) _invalid();
    return value.toDouble();
  }

  static int _integer(Object? value) {
    if (value is! int) _invalid();
    return value;
  }

  static bool _boolean(Object? value) {
    if (value is! bool) _invalid();
    return value;
  }

  static T _enum<T extends Enum>(List<T> values, Object? value) {
    final result = values.where((item) => item.name == value).firstOrNull;
    if (result == null) _invalid();
    return result;
  }

  static String _text(Object? value) {
    if (value is! String ||
        value.length > 10923 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
      _invalid();
    }
    try {
      final bytes = base64Url.decode(base64Url.normalize(value));
      if (bytes.length > ControlTextInput.maximumBytes ||
          base64Url.encode(bytes).replaceAll('=', '') != value) {
        _invalid();
      }
      final text = utf8.decode(bytes, allowMalformed: false);
      // Dart strips one leading BOM. Here it is authenticated user text, not
      // a file encoding marker, so restore precisely that one scalar.
      return bytes.length >= 3 &&
              bytes[0] == 0xef &&
              bytes[1] == 0xbb &&
              bytes[2] == 0xbf
          ? '\ufeff$text'
          : text;
    } on FormatException {
      return _invalid();
    }
  }

  static Never _invalid() => throw const SessionFailure('invalid_message');
}
