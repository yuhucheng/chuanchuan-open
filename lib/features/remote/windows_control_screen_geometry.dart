import 'package:flutter/services.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

/// Read-only local bounds for a pinned Windows WebRTC screen source. The
/// composite control owner must still bind its private source token, presented
/// image revision and native lease before any OS input is admitted.
final class WindowsControlScreenGeometry {
  const WindowsControlScreenGeometry._({
    required this.sourceId,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.rotation,
  });

  final String sourceId;
  final int left, top, width, height, rotation;
}

final class WindowsControlScreenGeometryProbe {
  WindowsControlScreenGeometryProbe({
    this.channel = const MethodChannel('dev.sharehub.client/platform'),
  });

  final MethodChannel channel;

  Future<WindowsControlScreenGeometry> read(CaptureSource source) async {
    final id = source.id;
    if (source.type != CaptureSourceType.screen ||
        !RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(id) ||
        int.parse(id) >= 256) {
      throw const SessionFailure('invalid_media_source');
    }
    Object? value;
    try {
      value = await channel.invokeMethod<Object?>('control.screenGeometry', {
        'sourceId': id,
      });
    } on PlatformException catch (error) {
      throw SessionFailure(
        error.code == 'source_unavailable'
            ? 'source_unavailable'
            : 'platform_unavailable',
      );
    } on MissingPluginException {
      throw const SessionFailure('platform_unavailable');
    }
    if (value is! Map ||
        value.length != 6 ||
        value.keys.toSet().difference(const {
          'sourceId',
          'left',
          'top',
          'width',
          'height',
          'rotation',
        }).isNotEmpty ||
        value['sourceId'] != id) {
      throw const SessionFailure('invalid_native_geometry');
    }
    final left = value['left'], top = value['top'];
    final width = value['width'], height = value['height'];
    final rotation = value['rotation'];
    if (left is! int ||
        top is! int ||
        width is! int ||
        height is! int ||
        rotation is! int ||
        left < -0x80000000 ||
        left > 0x7fffffff ||
        top < -0x80000000 ||
        top > 0x7fffffff ||
        width < 1 ||
        width > 65535 ||
        height < 1 ||
        height > 65535 ||
        left + width - 1 > 0x7fffffff ||
        top + height - 1 > 0x7fffffff ||
        !const [0, 90, 180, 270].contains(rotation)) {
      throw const SessionFailure('invalid_native_geometry');
    }
    return WindowsControlScreenGeometry._(
      sourceId: id,
      left: left,
      top: top,
      width: width,
      height: height,
      rotation: rotation,
    );
  }
}
