import 'dart:math' as math;

import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';

/// Maps a painted control frame to the active macOS capture's display frame.
/// The SDK resource must resolve the exact captured source; a future native
/// input lease must recheck it at the point of each OS effect.
final class MacControlGeometryResolver {
  MacControlGeometryResolver({
    required this.readCurrentScreen,
    String Function()? sourceToken,
  }) : _sourceToken = sourceToken ?? _randomToken;

  final Future<CaptureScreenGeometry> Function(CaptureSource source)
  readCurrentScreen;
  final String Function() _sourceToken;

  Future<ControlGeometry> resolve({
    required CaptureSource source,
    required VideoPresentationReceipt presented,
    required int mediaRevision,
    int geometryRevision = 1,
  }) async {
    if (source.type != CaptureSourceType.screen || source.id.isEmpty) {
      throw const SessionFailure('invalid_media_source');
    }
    if (presented.revision != mediaRevision) {
      throw const SessionFailure('stale_geometry');
    }
    final frame = await readCurrentScreen(source);
    if (frame.sourceId != source.id ||
        !frame.left.isFinite ||
        !frame.top.isFinite ||
        !frame.width.isFinite ||
        !frame.height.isFinite ||
        frame.left.abs() > 0x7fffffff ||
        frame.top.abs() > 0x7fffffff ||
        frame.width < 1 ||
        frame.height < 1 ||
        frame.width > 65535 ||
        frame.height > 65535 ||
        frame.left + frame.width > 0x7fffffff ||
        frame.top + frame.height > 0x7fffffff) {
      throw const SessionFailure('invalid_native_geometry');
    }
    return ControlGeometry(
      sourceToken: _sourceToken(),
      revision: geometryRevision,
      mediaRevision: mediaRevision,
      width: presented.width,
      height: presented.height,
      originX: frame.left,
      originY: frame.top,
      scaleX: _scale(presented.width, frame.width),
      scaleY: _scale(presented.height, frame.height),
      // ScreenCaptureKit's display frame and captured image are both in their
      // current orientation. Native input still needs real rotation QA.
      rotation: 0,
    );
  }

  static double _scale(int imagePixels, double displayPoints) {
    if (imagePixels == 1 || displayPoints == 1) {
      if (imagePixels == 1 && displayPoints == 1) return 1;
      throw const SessionFailure('invalid_native_geometry');
    }
    return (displayPoints - 1) / (imagePixels - 1);
  }

  static String _randomToken() {
    final random = math.Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
