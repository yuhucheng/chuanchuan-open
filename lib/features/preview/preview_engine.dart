import 'package:flutter/widgets.dart';

enum CaptureSourceType { screen, window }

class CaptureSource {
  const CaptureSource(
    this.id,
    this.name, {
    this.type = CaptureSourceType.screen,
  });
  final String id;
  final String name;
  final CaptureSourceType type;
}

abstract interface class PreviewEngine {
  /// Null when this build provides a media implementation.
  String? get unavailableReason;
  Future<List<CaptureSource>> sources();
  Future<void> start(
    CaptureSource source, {
    required VoidCallback onEnded,
    required VoidCallback onFirstFrame,
  });
  Future<void> stop();
  Future<void> dispose();
  Widget get view;
}

/// Default for independently built open clients; never accesses native capture.
class UnavailablePreviewEngine implements PreviewEngine {
  const UnavailablePreviewEngine();

  @override
  String get unavailableReason => '当前版本未包含投屏引擎。设备发现与已实现的文件准备功能仍可使用。';

  @override
  Future<List<CaptureSource>> sources() async => const [];

  @override
  Future<void> start(
    CaptureSource source, {
    required VoidCallback onEnded,
    required VoidCallback onFirstFrame,
  }) async => throw UnsupportedError(unavailableReason);

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}

  @override
  Widget get view => const SizedBox.shrink();
}
