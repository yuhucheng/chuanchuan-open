import 'package:flutter/widgets.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

export 'package:share_hub_media_api/share_hub_media_api.dart';

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
