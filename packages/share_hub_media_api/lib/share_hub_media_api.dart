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
