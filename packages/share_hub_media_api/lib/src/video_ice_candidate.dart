import 'dart:convert';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'remote_session.dart';
import 'video_description.dart';
import 'video_playback.dart';

/// Bounded trickle-ICE payload within authenticated video-operation signaling.
/// Contains network addresses: never include this value in ordinary logs.
final class VideoIceCandidate {
  VideoIceCandidate._(this.candidate, this.mid, this.usernameFragment);
  static const maxCandidateBytes = 2048;
  final String candidate;
  final String mid;
  final String? usernameFragment;
  bool get isEnd => candidate.isEmpty;

  factory VideoIceCandidate.local({
    required String candidate,
    required String mid,
    required int mLineIndex,
  }) {
    if (mLineIndex != 0 ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(mid) ||
        candidate.length > maxCandidateBytes ||
        !RegExp(r'^[\x20-\x7E]*$').hasMatch(candidate)) {
      throw const SessionFailure('invalid_media_candidate');
    }
    if (candidate.isEmpty) return VideoIceCandidate._('', mid, null);
    final fields = candidate.split(' ');
    int? integer(String value) =>
        RegExp(r'^[0-9]+$').hasMatch(value) ? int.tryParse(value) : null;
    if (fields.length < 8 ||
        fields.length.isOdd ||
        !RegExp(r'^candidate:[A-Za-z0-9+/]{1,32}$').hasMatch(fields[0]) ||
        fields[1] != '1' ||
        !['udp', 'tcp'].contains(fields[2].toLowerCase()) ||
        integer(fields[3]) == null ||
        integer(fields[3])! > 0xffffffff ||
        !RegExp(r'^[A-Za-z0-9:.%_-]{1,253}$').hasMatch(fields[4]) ||
        integer(fields[5]) == null ||
        integer(fields[5])! < 1 ||
        integer(fields[5])! > 65535 ||
        fields[6] != 'typ' ||
        !['host', 'srflx', 'prflx', 'relay'].contains(fields[7])) {
      throw const SessionFailure('invalid_media_candidate');
    }
    String? ufrag;
    final names = <String>{};
    for (var i = 8; i < fields.length; i += 2) {
      if (fields[i].isEmpty || fields[i + 1].isEmpty || !names.add(fields[i])) {
        throw const SessionFailure('invalid_media_candidate');
      }
      if (fields[i] == 'ufrag') {
        if (!RegExp(r'^[A-Za-z0-9+/]{4,256}$').hasMatch(fields[i + 1])) {
          throw const SessionFailure('invalid_media_candidate');
        }
        ufrag = fields[i + 1];
      }
    }
    return VideoIceCandidate._(candidate, mid, ufrag);
  }

  void matchDescription(VideoSessionDescription description) {
    if (mid != description.mid ||
        (usernameFragment != null &&
            usernameFragment != description.iceUsernameFragment)) {
      throw const SessionFailure('media_candidate_mismatch');
    }
  }

  String encode({int revision = 0}) {
    validateVideoRevision(revision);
    return jsonEncode({
      'version': 2,
      'kind': 'candidate',
      'revision': revision,
      'candidate': candidate,
      'mid': mid,
      'mLineIndex': 0,
    });
  }

  static Future<VideoIceCandidate> receive(
    VerifiedSessionSignal signal, {
    required MediaSessionSlot slot,
    int expectedRevision = 0,
  }) async {
    if (!identical(signal.authorization, slot.authorization)) {
      throw const SessionFailure('foreign_media_signal');
    }
    await slot.check();
    slot.requireCurrent();
    signal.requireCurrent();
    if (utf8.encode(signal.body).length > 4096) {
      throw const SessionFailure('media_signal_too_large');
    }
    Object? body;
    try {
      body = jsonDecode(signal.body);
    } on FormatException {
      throw const SessionFailure('invalid_media_candidate');
    }
    if (body is! Map<String, dynamic> ||
        body.length != 6 ||
        body['version'] is! int ||
        body['version'] != 2 ||
        body['kind'] != 'candidate' ||
        body['candidate'] is! String ||
        body['mid'] is! String ||
        body['mLineIndex'] is! int) {
      throw const SessionFailure('invalid_media_candidate');
    }
    requireVideoRevision(body['revision'], expectedRevision);
    final result = VideoIceCandidate.local(
      candidate: body['candidate'] as String,
      mid: body['mid'] as String,
      mLineIndex: body['mLineIndex'] as int,
    );
    slot.requireCurrent();
    signal.requireCurrent();
    return result;
  }
}
