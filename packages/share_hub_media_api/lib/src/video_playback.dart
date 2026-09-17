import 'dart:convert';

import 'package:share_hub_session_api/share_hub_session_api.dart';

/// Revision changes only after both endpoints have quiesced the previous video.
/// The original operation initiator allocates revisions, independently of which
/// endpoint captures. Either endpoint may request pause or resume.
enum VideoPlaybackAction { pause, paused, resumeRequest, resume, ready }

final class VideoPlaybackMessage {
  VideoPlaybackMessage({required this.action, required this.revision}) {
    validateVideoRevision(revision);
  }
  final VideoPlaybackAction action;
  final int revision;
  String encode() => jsonEncode({
    'version': 1,
    'kind': 'playback',
    'action': action.name,
    'revision': revision,
  });

  static Future<VideoPlaybackMessage> receive(
    VerifiedSessionSignal signal, {
    required SessionAuthorization authorization,
  }) async {
    if (!identical(signal.authorization, authorization)) {
      throw const SessionFailure('foreign_media_signal');
    }
    await signal.check();
    signal.requireCurrent();
    if (utf8.encode(signal.body).length > 512) {
      throw const SessionFailure('media_signal_too_large');
    }
    Object? value;
    try {
      value = jsonDecode(signal.body);
    } on FormatException {
      throw const SessionFailure('invalid_media_playback');
    }
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['kind'] != 'playback' ||
        value['revision'] is! int) {
      throw const SessionFailure('invalid_media_playback');
    }
    final actionName = value['action'];
    final action = VideoPlaybackAction.values
        .where((action) => action.name == actionName)
        .firstOrNull;
    if (action == null) throw const SessionFailure('invalid_media_playback');
    return VideoPlaybackMessage(
      action: action,
      revision: value['revision'] as int,
    );
  }
}

void validateVideoRevision(int revision) {
  if (revision < 0 || revision > 0x7fffffff) {
    throw const SessionFailure('invalid_media_revision');
  }
}

void requireVideoRevision(Object? actual, int expected) {
  validateVideoRevision(expected);
  if (actual is! int || actual != expected) {
    throw const SessionFailure('stale_media_revision');
  }
}
