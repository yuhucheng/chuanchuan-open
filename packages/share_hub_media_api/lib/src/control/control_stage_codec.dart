import 'dart:convert';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'control_geometry.dart';
import 'control_stage.dart';
import 'control_wire.dart';

abstract final class ControlStageCodec {
  static const maximumBytes = 4096;

  static String encode(ControlStage stage) => jsonEncode({
    'v': 1,
    'type': switch (stage) {
      ControlGeometryPublished() => 'geometry',
      ControlGeometryReady() => 'geometry-ready',
      ControlInputReady() => 'input-ready',
      ControlReleaseAll() => 'release-all',
      ControlReleased() => 'released',
      ControlStop() => 'stop',
      ControlStopped() => 'stopped',
    },
    if (stage is ControlGeometryPublished) ...{
      'sourceToken': stage.geometry.sourceToken,
      'geometryRevision': '${stage.geometry.revision}',
      'mediaRevision': '${stage.geometry.mediaRevision}',
      'width': stage.geometry.width,
      'height': stage.geometry.height,
      'originX': stage.geometry.originX,
      'originY': stage.geometry.originY,
      'scaleX': stage.geometry.scaleX,
      'scaleY': stage.geometry.scaleY,
      'rotation': stage.geometry.rotation,
    },
    if (stage is ControlGeometryReady) ...{
      'sourceToken': stage.sourceToken,
      'geometryRevision': '${stage.geometryRevision}',
      'mediaRevision': '${stage.mediaRevision}',
    },
    if (stage is ControlInputReady) ...{
      'geometryRevision': '${stage.geometryRevision}',
      'inputEpoch': '${stage.inputEpoch}',
    },
    if (stage is ControlReleaseAll) 'inputEpoch': '${stage.inputEpoch}',
    if (stage is ControlReleased) 'inputEpoch': '${stage.inputEpoch}',
  });

  static ControlStage decode(String body) {
    final fields = controlObject(body, maximumBytes: maximumBytes);
    if (fields['v'] is! int) _invalid();
    if (fields['v'] != 1) throw const SessionFailure('incompatible_version');
    final type = fields['type'];
    final expected = switch (type) {
      'geometry' => {
        'sourceToken',
        'geometryRevision',
        'mediaRevision',
        'width',
        'height',
        'originX',
        'originY',
        'scaleX',
        'scaleY',
        'rotation',
      },
      'geometry-ready' => {'sourceToken', 'geometryRevision', 'mediaRevision'},
      'input-ready' => {'geometryRevision', 'inputEpoch'},
      'release-all' || 'released' => {'inputEpoch'},
      'stop' || 'stopped' => <String>{},
      _ => _invalid(),
    };
    final names = {'v', 'type', ...expected};
    if (fields.length != names.length ||
        !fields.keys.toSet().containsAll(names)) {
      _invalid();
    }
    return switch (type) {
      'geometry' => ControlGeometryPublished(
        ControlGeometry(
          sourceToken: _string(fields['sourceToken']),
          revision: _counter(fields['geometryRevision']),
          mediaRevision: _zeroCounter(fields['mediaRevision']),
          width: _integer(fields['width']),
          height: _integer(fields['height']),
          originX: _number(fields['originX']),
          originY: _number(fields['originY']),
          scaleX: _number(fields['scaleX']),
          scaleY: _number(fields['scaleY']),
          rotation: _integer(fields['rotation']),
        ),
      ),
      'geometry-ready' => ControlGeometryReady(
        sourceToken: _string(fields['sourceToken']),
        geometryRevision: _counter(fields['geometryRevision']),
        mediaRevision: _zeroCounter(fields['mediaRevision']),
      ),
      'input-ready' => ControlInputReady(
        geometryRevision: _counter(fields['geometryRevision']),
        inputEpoch: _counter(fields['inputEpoch']),
      ),
      'release-all' => ControlReleaseAll(
        inputEpoch: _counter(fields['inputEpoch']),
      ),
      'released' => ControlReleased(inputEpoch: _counter(fields['inputEpoch'])),
      'stop' => const ControlStop(),
      'stopped' => const ControlStopped(),
      _ => _invalid(),
    };
  }

  static int _counter(Object? value) {
    if (value is! String ||
        value.length > 19 ||
        !RegExp(r'^[1-9][0-9]*$').hasMatch(value)) {
      _invalid();
    }
    final parsed = int.tryParse(value);
    if (parsed == null || parsed < 1) _invalid();
    return parsed;
  }

  static int _zeroCounter(Object? value) {
    if (value == '0') return 0;
    return _counter(value);
  }

  static int _integer(Object? value) {
    if (value is! int) _invalid();
    return value;
  }

  static double _number(Object? value) {
    if (value is! num || !value.isFinite) _invalid();
    return value.toDouble();
  }

  static String _string(Object? value) {
    if (value is! String) _invalid();
    return value;
  }

  static Never _invalid() => throw const SessionFailure('invalid_message');
}
