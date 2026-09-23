export 'package:share_hub_session_api/share_hub_session_api.dart';

export 'src/remote_session.dart';
export 'src/video_description.dart';
export 'src/video_ice_candidate.dart';
export 'src/video_presentation_receipt.dart';
export 'src/video_session_messages.dart';
export 'src/video_playback.dart';
export 'src/control/control_start.dart';
export 'src/control/control_context.dart';
export 'src/control/control_geometry.dart';
export 'src/control/control_input.dart';
export 'src/control/control_input_codec.dart';
export 'src/control/control_input_state.dart';
export 'src/control/control_stage.dart';
export 'src/control/control_stage_codec.dart';
export 'src/control/control_clipboard_state.dart';
export 'src/control/control_clipboard_codec.dart';
export 'src/control/control_clipboard_echo.dart';

import 'package:flutter/widgets.dart';

enum CaptureSourceType { screen, window }

class CaptureSource {
  const CaptureSource(
    this.id,
    this.name, {
    this.type = CaptureSourceType.screen,
    this.isPrimary = false,
  });
  final String id;
  final String name;
  final CaptureSourceType type;

  /// True only for a screen positively identified as primary by the platform.
  /// False also covers legacy engines without primary-display metadata.
  final bool isPrimary;
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
