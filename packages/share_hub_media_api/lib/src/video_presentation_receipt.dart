import 'dart:convert';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'remote_session.dart';

/// A receiver's presentation report, not an authority to capture or a local
/// transport-ready flag. Emit only after decoded video participates in paint.
final class VideoPresentationReceipt {
  VideoPresentationReceipt({
    required this.revision,
    required this.width,
    required this.height,
  }) {
    if (revision < 0 ||
        revision > 0x7fffffff ||
        width < 1 ||
        height < 1 ||
        width > 65535 ||
        height > 65535) {
      throw const SessionFailure('invalid_presentation_receipt');
    }
  }
  final int revision, width, height;
  String encode() => jsonEncode({
    'version': 1,
    'kind': 'presented',
    'revision': revision,
    'width': width,
    'height': height,
  });

  static Future<VideoPresentationReceipt> receive(
    VerifiedSessionSignal signal, {
    required MediaSessionSlot slot,
    required int expectedRevision,
  }) async {
    if (!identical(signal.authorization, slot.authorization)) {
      throw const SessionFailure('foreign_media_signal');
    }
    await slot.check();
    slot.requireCurrent();
    signal.requireCurrent();
    if (utf8.encode(signal.body).length > 512) {
      throw const SessionFailure('media_signal_too_large');
    }
    Object? body;
    try {
      body = jsonDecode(signal.body);
    } on FormatException {
      throw const SessionFailure('invalid_presentation_receipt');
    }
    if (body is! Map<String, dynamic> ||
        body.length != 5 ||
        body['version'] is! int ||
        body['version'] != 1 ||
        body['kind'] != 'presented' ||
        body['revision'] is! int ||
        body['width'] is! int ||
        body['height'] is! int) {
      throw const SessionFailure('invalid_presentation_receipt');
    }
    final result = VideoPresentationReceipt(
      revision: body['revision'] as int,
      width: body['width'] as int,
      height: body['height'] as int,
    );
    if (result.revision != expectedRevision) {
      throw const SessionFailure('stale_presentation_receipt');
    }
    slot.requireCurrent();
    signal.requireCurrent();
    return result;
  }
}
