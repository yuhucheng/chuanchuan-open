import 'dart:math' as math;

import 'package:share_hub_media_api/share_hub_media_api.dart';

import 'windows_control_screen_geometry.dart';

/// Converts a verified control frame into the matching local Windows display
/// mapping. The native input lease must independently recheck this mapping.
final class WindowsControlGeometryResolver {
  WindowsControlGeometryResolver({
    WindowsControlScreenGeometryProbe? probe,
    String Function()? sourceToken,
  }) : _probe = probe ?? WindowsControlScreenGeometryProbe(),
       _sourceToken = sourceToken ?? _randomToken;

  final WindowsControlScreenGeometryProbe _probe;
  final String Function() _sourceToken;

  Future<ControlGeometry> resolve({
    required CaptureSource source,
    required VideoPresentationReceipt presented,
    required int mediaRevision,
    int geometryRevision = 1,
  }) async {
    if (presented.revision != mediaRevision) {
      throw const SessionFailure('stale_geometry');
    }
    final screen = await _probe.read(source);
    return ControlGeometry(
      sourceToken: _sourceToken(),
      revision: geometryRevision,
      mediaRevision: mediaRevision,
      width: presented.width,
      height: presented.height,
      originX: screen.left.toDouble(),
      originY: screen.top.toDouble(),
      scaleX: _scale(presented.width, screen.width),
      scaleY: _scale(presented.height, screen.height),
      rotation: screen.rotation,
    );
  }

  static double _scale(int imagePixels, int nativePixels) {
    if (imagePixels == 1 || nativePixels == 1) {
      if (imagePixels == 1 && nativePixels == 1) return 1;
      throw const SessionFailure('invalid_native_geometry');
    }
    return (nativePixels - 1) / (imagePixels - 1);
  }

  static String _randomToken() {
    final random = math.Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
