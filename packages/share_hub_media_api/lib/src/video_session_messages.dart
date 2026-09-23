import 'dart:convert';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'video_recovery.dart';

/// Versioned intent only. The sharing endpoint resolves its own source; a
/// remote request cannot name a display/window or widen capture permissions.
abstract final class VideoSessionRequest {
  static const body = '{"version":3,"kind":"video"}';

  static String recoveryBody(VideoRecoveryRequest recovery) => jsonEncode({
    'version': 4,
    'kind': 'video',
    'recovery': recovery.toJson(),
  });

  static Future<void> check(SessionAuthorization authorization) async {
    await recovery(authorization);
  }

  static Future<VideoRecoveryRequest?> recovery(
    SessionAuthorization authorization,
  ) async {
    await authorization.check();
    authorization.requireCurrent();
    if (authorization.operation != SessionOperation.watch &&
        authorization.operation != SessionOperation.cast) {
      throw const SessionFailure('capability_unavailable');
    }
    final value = _object(authorization.body, version: null);
    if (value['kind'] != 'video') {
      throw const SessionFailure('invalid_media_request');
    }
    if (value['version'] == 3 && value.length == 2) return null;
    if (value['version'] != 4 || value.length != 3) {
      throw const SessionFailure('incompatible_media_protocol');
    }
    final recovery = VideoRecoveryRequest.decode(value['recovery']);
    if (recovery.previousSessionId == authorization.sessionId ||
        recovery.previousTransportGeneration >=
            authorization.transportGeneration) {
      throw const SessionFailure('invalid_media_recovery');
    }
    return recovery;
  }
}

/// Fixed diagnostic vocabulary: no native messages, source names or paths.
enum VideoEndReason { stopped, busy, unavailable, failed }

final class VideoSessionEnd {
  const VideoSessionEnd(this.reason);
  final VideoEndReason reason;
  String encode() =>
      jsonEncode({'version': 1, 'kind': 'ended', 'reason': reason.name});

  /// A rejection may arrive before native resources have been allocated, so
  /// this verifies operation authority without requiring a media slot.
  static Future<VideoSessionEnd> receive(
    VerifiedSessionSignal signal, {
    required SessionAuthorization authorization,
  }) async {
    if (!identical(signal.authorization, authorization)) {
      throw const SessionFailure('foreign_media_signal');
    }
    await signal.check();
    signal.requireCurrent();
    final value = _object(signal.body);
    if (value.length != 3 || value['kind'] != 'ended') {
      throw const SessionFailure('invalid_media_end');
    }
    final reason = VideoEndReason.values
        .where((reason) => reason.name == value['reason'])
        .firstOrNull;
    if (reason == null) throw const SessionFailure('invalid_media_end');
    return VideoSessionEnd(reason);
  }
}

Map<String, dynamic> _object(String body, {int? version = 1}) {
  if (utf8.encode(body).length > 512) {
    throw const SessionFailure('media_signal_too_large');
  }
  Object? value;
  try {
    value = jsonDecode(body);
  } on FormatException {
    throw const SessionFailure('invalid_media_message');
  }
  if (value is! Map<String, dynamic> ||
      value['version'] is! int ||
      (version != null && value['version'] != version)) {
    throw const SessionFailure('incompatible_media_protocol');
  }
  return value;
}
