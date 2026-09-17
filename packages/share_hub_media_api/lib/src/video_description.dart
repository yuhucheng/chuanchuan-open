import 'dart:convert';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'remote_session.dart';
import 'video_playback.dart';

/// The initial video negotiation profile, carried inside authenticated operation
/// signaling. This is not a new authority or proof of a received video frame.
final class VideoSessionDescription {
  VideoSessionDescription._(
    this.type,
    this.sdp,
    this.fingerprint,
    this.sends,
    this.mid,
    this.iceUsernameFragment,
  );

  static const profileVersion = 2;
  static const maxSdpBytes = 48 * 1024;
  final String type;
  final String sdp;
  final String fingerprint;
  final bool sends;
  final String mid;
  final String iceUsernameFragment;

  /// Validate the actual local native SDP before transmitting it. The native
  /// DTLS implementation must still verify the remote certificate against SDP.
  factory VideoSessionDescription.local({
    required String type,
    required String sdp,
    required bool sends,
  }) => _validate(type, sdp, sends);

  /// Only a signal authenticated for this exact reserved operation is accepted.
  /// The caller determines the peer's role from watch/cast and endpoint role;
  /// the peer cannot choose its own capture direction through SDP.
  static Future<VideoSessionDescription> receive(
    VerifiedSessionSignal signal, {
    required MediaSessionSlot slot,
    required String expectedType,
    required bool peerSends,
    int expectedRevision = 0,
  }) async {
    if (!identical(signal.authorization, slot.authorization)) {
      throw const SessionFailure('foreign_media_signal');
    }
    await slot.check();
    slot.requireCurrent();
    signal.requireCurrent();
    if (utf8.encode(signal.body).length > 65536) {
      throw const SessionFailure('media_signal_too_large');
    }
    Object? data;
    try {
      data = jsonDecode(signal.body);
    } on FormatException {
      throw const SessionFailure('invalid_media_description');
    }
    if (data is! Map<String, dynamic> ||
        data.length != 6 ||
        data['version'] is! int ||
        data['version'] != profileVersion ||
        data['kind'] != 'description' ||
        data['type'] != expectedType ||
        data['sdp'] is! String ||
        data['fingerprint'] is! String) {
      throw const SessionFailure('invalid_media_description');
    }
    requireVideoRevision(data['revision'], expectedRevision);
    final result = _validate(expectedType, data['sdp'] as String, peerSends);
    if (data['fingerprint'] != result.fingerprint) {
      throw const SessionFailure('media_fingerprint_mismatch');
    }
    slot.requireCurrent();
    signal.requireCurrent();
    return result;
  }

  String encode({int revision = 0}) {
    validateVideoRevision(revision);
    final encoded = jsonEncode({
      'version': profileVersion,
      'kind': 'description',
      'revision': revision,
      'type': type,
      'sdp': sdp,
      'fingerprint': fingerprint,
    });
    // JSON escaping can expand otherwise bounded SDP beyond transport limits.
    if (utf8.encode(encoded).length > 65536) {
      throw const SessionFailure('media_signal_too_large');
    }
    return encoded;
  }

  static VideoSessionDescription _validate(
    String type,
    String sdp,
    bool sends,
  ) {
    Never invalid() => throw const SessionFailure('invalid_media_description');
    if (!const ['offer', 'answer'].contains(type) ||
        sdp.isEmpty ||
        utf8.encode(sdp).length > maxSdpBytes ||
        sdp.contains('\u0000')) {
      invalid();
    }
    final lines = const LineSplitter().convert(sdp);
    if (lines.isEmpty ||
        lines.first != 'v=0' ||
        lines.any((line) => line.contains('\r'))) {
      invalid();
    }
    final media = lines.where((line) => line.startsWith('m=')).toList();
    // No rejected audio/data sections, extra videos, or insecure RTP profiles.
    if (media.length != 1 ||
        !RegExp(r'^m=video [1-9][0-9]* UDP/TLS/RTP/SAVPF [0-9]+(?: [0-9]+)*$')
            .hasMatch(media.single)) {
      invalid();
    }
    final mediaStart = lines.indexOf(media.single);
    final attributes = lines.skip(mediaStart + 1).toList();
    final directions = lines
        .where(
          (line) => const [
            'a=sendonly',
            'a=recvonly',
            'a=sendrecv',
            'a=inactive',
          ].contains(line),
        )
        .toList();
    if (directions.length != 1 ||
        directions.single != (sends ? 'a=sendonly' : 'a=recvonly') ||
        !attributes.contains('a=rtcp-mux')) {
      invalid();
    }
    final mids = attributes.where((line) => line.startsWith('a=mid:')).toList();
    if (mids.length != 1 ||
        !RegExp(r'^a=mid:[A-Za-z0-9_-]{1,64}$').hasMatch(mids.single)) {
      invalid();
    }
    final ufrags = lines
        .where((line) => line.startsWith('a=ice-ufrag:'))
        .toSet();
    if (ufrags.length != 1 ||
        !RegExp(r'^a=ice-ufrag:[A-Za-z0-9+/]{4,256}$')
            .hasMatch(ufrags.single)) {
      invalid();
    }
    final fingerprints = lines
        .where((line) => line.startsWith('a=fingerprint:'))
        .toList();
    final pattern = RegExp(
      r'^a=fingerprint:sha-256 ((?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2})$',
    );
    if (fingerprints.isEmpty) invalid();
    final digests = <String>{};
    for (final line in fingerprints) {
      final match = pattern.firstMatch(line);
      if (match == null) invalid();
      digests.add(match.group(1)!.toUpperCase());
    }
    if (digests.length != 1) invalid();
    final setups = lines.where((line) => line.startsWith('a=setup:')).toSet();
    if (setups.length != 1 ||
        (type == 'offer'
            ? setups.single != 'a=setup:actpass'
            : !const [
                'a=setup:active',
                'a=setup:passive',
              ].contains(setups.single))) {
      invalid();
    }
    return VideoSessionDescription._(
      type,
      sdp,
      digests.single,
      sends,
      mids.single.substring(6),
      ufrags.single.substring(12),
    );
  }
}
