import 'dart:convert';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'control_clipboard_state.dart';
import 'control_wire.dart';

/// Versioned flat clipboard messages. A typed value is not authority to read
/// or write the system clipboard; the exact control context still gates it.
abstract final class ControlClipboardCodec {
  static const maximumBytes = 48 * 1024;
  static const ordinaryBytes = 4096;

  static String encode(ClipboardWireMessage message) => jsonEncode({
    'v': 1,
    'type': switch (message) {
      ClipboardSideState() => 'clipboard-state',
      ClipboardReady() => 'clipboard-ready',
      ClipboardProposal() => 'clipboard-proposal',
      ClipboardCommit() => 'clipboard-commit',
      ClipboardConflict() || ClipboardWriteFailed() => 'clipboard-result',
    },
    if (message is ClipboardSideState) ...{
      'stateRevision': '${message.revision}',
      'enabled': message.enabled,
      'available': message.available,
    },
    if (message is ClipboardReady) ...{
      ..._pair(
        message.epoch,
        message.controllerStateRevision,
        message.targetStateRevision,
      ),
      ..._textFields(message.text),
    },
    if (message is ClipboardProposal) ...{
      ..._pair(
        message.epoch,
        message.controllerStateRevision,
        message.targetStateRevision,
      ),
      'updateSequence': '${message.updateSequence}',
      'updateId': message.updateId,
      'baseRevision': '${message.baseRevision}',
      'textUtf8': _encodeText(message.text),
    },
    if (message is ClipboardCommit) ...{
      ..._pair(
        message.epoch,
        message.controllerStateRevision,
        message.targetStateRevision,
      ),
      'revision': '${message.revision}',
      'sourceUpdateId': message.sourceUpdateId,
      ..._textFields(message.text),
    },
    if (message is ClipboardConflict) ...{
      'status': 'conflict',
      ..._pair(
        message.current.epoch,
        message.current.controllerStateRevision,
        message.current.targetStateRevision,
      ),
      'updateId': message.updateId,
      'revision': '${message.current.revision}',
      'sourceUpdateId': message.current.sourceUpdateId,
      ..._textFields(message.current.text),
    },
    if (message is ClipboardWriteFailed) ...{
      'status': 'write-failed',
      ..._pair(
        message.epoch,
        message.controllerStateRevision,
        message.targetStateRevision,
      ),
      'updateId': message.updateId,
    },
  });

  static ClipboardWireMessage decode(String body) {
    final fields = controlObject(body, maximumBytes: maximumBytes);
    if (fields['v'] is! int) _invalid();
    if (fields['v'] != 1) throw const SessionFailure('incompatible_version');
    final type = fields['type'];
    final pairNames = {
      'clipboardEpoch',
      'controllerStateRevision',
      'targetStateRevision',
    };
    final hasText = fields['hasText'];
    final snapshot =
        type == 'clipboard-ready' ||
        type == 'clipboard-commit' ||
        (type == 'clipboard-result' && fields['status'] == 'conflict');
    if (snapshot && hasText is! bool) _invalid();
    final textNames = switch (hasText) {
      true => {'hasText', 'textUtf8'},
      false => {'hasText'},
      _ => <String>{},
    };
    final expected = switch (type) {
      'clipboard-state' => {'stateRevision', 'enabled', 'available'},
      'clipboard-ready' => {...pairNames, ...textNames},
      'clipboard-proposal' => {
        ...pairNames,
        'updateSequence',
        'updateId',
        'baseRevision',
        'textUtf8',
      },
      'clipboard-commit' => {
        ...pairNames,
        'revision',
        'sourceUpdateId',
        ...textNames,
      },
      'clipboard-result' when fields['status'] == 'conflict' => {
        'status',
        ...pairNames,
        'updateId',
        'revision',
        'sourceUpdateId',
        ...textNames,
      },
      'clipboard-result' when fields['status'] == 'write-failed' => {
        'status',
        ...pairNames,
        'updateId',
      },
      _ => _invalid(),
    };
    final names = {'v', 'type', ...expected};
    if (fields.length != names.length ||
        !fields.keys.toSet().containsAll(names)) {
      _invalid();
    }
    final carriesText = type == 'clipboard-proposal' || hasText == true;
    if (!carriesText && utf8.encode(body).length > ordinaryBytes) {
      throw const SessionFailure('message_limit');
    }
    return switch (type) {
      'clipboard-state' => ClipboardSideState(
        revision: _counter(fields['stateRevision']),
        enabled: _boolean(fields['enabled']),
        available: _boolean(fields['available']),
      ),
      'clipboard-ready' => ClipboardReady(
        epoch: _counter(fields['clipboardEpoch']),
        controllerStateRevision: _counter(fields['controllerStateRevision']),
        targetStateRevision: _counter(fields['targetStateRevision']),
        text: _decodeOptionalText(fields),
      ),
      'clipboard-proposal' => ClipboardProposal(
        epoch: _counter(fields['clipboardEpoch']),
        controllerStateRevision: _counter(fields['controllerStateRevision']),
        targetStateRevision: _counter(fields['targetStateRevision']),
        updateSequence: _counter(fields['updateSequence']),
        updateId: _string(fields['updateId']),
        baseRevision: _counter(fields['baseRevision']),
        text: _decodeText(fields['textUtf8']),
      ),
      'clipboard-commit' => ClipboardCommit(
        epoch: _counter(fields['clipboardEpoch']),
        controllerStateRevision: _counter(fields['controllerStateRevision']),
        targetStateRevision: _counter(fields['targetStateRevision']),
        revision: _counter(fields['revision']),
        text: _decodeOptionalText(fields),
        sourceUpdateId: _optionalString(fields['sourceUpdateId']),
      ),
      'clipboard-result' when fields['status'] == 'conflict' =>
        ClipboardConflict(
          updateId: _string(fields['updateId']),
          current: ClipboardCommit(
            epoch: _counter(fields['clipboardEpoch']),
            controllerStateRevision: _counter(
              fields['controllerStateRevision'],
            ),
            targetStateRevision: _counter(fields['targetStateRevision']),
            revision: _counter(fields['revision']),
            text: _decodeOptionalText(fields),
            sourceUpdateId: _optionalString(fields['sourceUpdateId']),
          ),
        ),
      'clipboard-result' when fields['status'] == 'write-failed' =>
        ClipboardWriteFailed(
          epoch: _counter(fields['clipboardEpoch']),
          controllerStateRevision: _counter(fields['controllerStateRevision']),
          targetStateRevision: _counter(fields['targetStateRevision']),
          updateId: _string(fields['updateId']),
        ),
      _ => _invalid(),
    };
  }

  static Map<String, Object?> _pair(int epoch, int controller, int target) => {
    'clipboardEpoch': '$epoch',
    'controllerStateRevision': '$controller',
    'targetStateRevision': '$target',
  };

  static Map<String, Object?> _textFields(String? value) => {
    'hasText': value != null,
    if (value != null) 'textUtf8': _encodeText(value),
  };

  static String _encodeText(String text) =>
      base64Url.encode(utf8.encode(text)).replaceAll('=', '');

  static String? _decodeOptionalText(Map<String, dynamic> fields) =>
      fields['hasText'] == true ? _decodeText(fields['textUtf8']) : null;

  static String _decodeText(Object? value) {
    if (value is! String ||
        value.length > 43691 ||
        !RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(value)) {
      _invalid();
    }
    try {
      final bytes = base64Url.decode(base64Url.normalize(value));
      if (bytes.length > 32768 || _encodeTextBytes(bytes) != value) {
        _invalid();
      }
      final decoded = utf8.decode(bytes, allowMalformed: false);
      return bytes.length >= 3 &&
              bytes[0] == 0xef &&
              bytes[1] == 0xbb &&
              bytes[2] == 0xbf
          ? '\ufeff$decoded'
          : decoded;
    } on FormatException {
      return _invalid();
    }
  }

  static String _encodeTextBytes(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static int _counter(Object? value) {
    if (value is! String ||
        value.length > 19 ||
        !RegExp(r'^[1-9][0-9]*$').hasMatch(value)) {
      _invalid();
    }
    final parsed = int.tryParse(value);
    if (parsed == null || parsed < 1 || parsed > 0x7fffffffffffffff) {
      _invalid();
    }
    return parsed;
  }

  static bool _boolean(Object? value) {
    if (value is! bool) _invalid();
    return value;
  }

  static String _string(Object? value) {
    if (value is! String) _invalid();
    return value;
  }

  static String? _optionalString(Object? value) {
    if (value == null) return null;
    return _string(value);
  }

  static Never _invalid() => throw const SessionFailure('invalid_message');
}
