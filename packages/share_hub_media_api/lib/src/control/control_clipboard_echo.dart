import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';

enum ClipboardObservation { noText, ownEcho, localText }

final class _EchoMarker {
  const _EchoMarker(this.changeToken, this.digest);
  final String changeToken, digest;
}

/// Bounded observer aid for host-reported OS change tokens. Call
/// [recordOwnWrite] only after a successful native write returns its token.
/// A matching text value without a matching token is a new local edit.
final class ClipboardEchoGuard {
  static const maximumRemembered = 4;
  final List<_EchoMarker> _markers = <_EchoMarker>[];

  int get rememberedCount => _markers.length;

  void recordOwnWrite({required String changeToken, required String text}) {
    _token(changeToken);
    final digest = _digest(text);
    final existing = _markers
        .where((marker) => marker.changeToken == changeToken)
        .firstOrNull;
    if (existing != null) {
      if (existing.digest == digest) return;
      clear();
      throw const SessionFailure('platform_unavailable');
    }
    if (_markers.length == maximumRemembered) _markers.removeAt(0);
    _markers.add(_EchoMarker(changeToken, digest));
  }

  ClipboardObservation observe({
    required String changeToken,
    required String? text,
  }) {
    _token(changeToken);
    if (text == null) return ClipboardObservation.noText;
    final digest = _digest(text);
    for (var i = 0; i < _markers.length; i++) {
      final marker = _markers[i];
      if (marker.changeToken != changeToken) continue;
      if (marker.digest == digest) return ClipboardObservation.ownEcho;
      _markers.removeAt(i);
      break;
    }
    return ClipboardObservation.localText;
  }

  void clear() => _markers.clear();

  void _token(String value) {
    if (value.isEmpty || value.length > 128 || value.contains('\u0000')) {
      throw const SessionFailure('platform_unavailable');
    }
  }

  String _digest(String text) {
    if (text.length > 32768) throw const SessionFailure('message_limit');
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= text.length ||
            text.codeUnitAt(i) < 0xdc00 ||
            text.codeUnitAt(i) > 0xdfff) {
          throw const SessionFailure('invalid_message');
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw const SessionFailure('invalid_message');
      }
    }
    final bytes = utf8.encode(text);
    if (bytes.length > 32768) throw const SessionFailure('message_limit');
    return sha256.convert(bytes).toString();
  }
}
