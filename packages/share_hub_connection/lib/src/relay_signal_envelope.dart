import 'dart:convert';

import 'identity.dart';

/// Opaque relay framing for an already authenticated, live grant. Parsing an
/// envelope never authenticates its sender or grants an operation: the relay
/// must check both joined members, and the endpoint must open the sealed body.
enum RelaySignalKind { data, cancel }

final class RelaySignalEnvelope {
  RelaySignalEnvelope({
    required List<int> room,
    required List<int> sender,
    required this.generation,
    required this.sequence,
    required this.kind,
    required List<int> payload,
  }) : room = List<int>.unmodifiable(room),
       sender = List<int>.unmodifiable(sender),
       payload = List<int>.unmodifiable(payload) {
    _validate();
  }

  static const version = 1;
  // An implementation safety ceiling, not a promised service quota or RTT.
  static const maxPayloadBytes = 131072;
  static const maxWireBytes = 200000;
  static const _maxCounter = 0xffffffff;

  final List<int> room, sender, payload;
  final int generation, sequence;
  final RelaySignalKind kind;

  void _validate() {
    if (room.length != 32 ||
        sender.length != 32 ||
        [
          ...room,
          ...sender,
          ...payload,
        ].any((byte) => byte < 0 || byte > 255) ||
        generation < 0 ||
        generation > _maxCounter ||
        sequence < 0 ||
        sequence > _maxCounter ||
        payload.length > maxPayloadBytes ||
        (kind == RelaySignalKind.data && payload.isEmpty) ||
        (kind == RelaySignalKind.cancel && payload.isNotEmpty)) {
      throw const ConnectionFailure('invalid_relay_envelope');
    }
  }

  /// Fixed field order makes duplicate keys, noncanonical base64 and alternate
  /// JSON spellings fail the decode/re-encode check on both implementations.
  String encode() => jsonEncode({
    'v': version,
    'room': encodeBytes(room),
    'sender': encodeBytes(sender),
    'generation': generation,
    'seq': sequence,
    'kind': kind.name,
    'payload': encodeBytes(payload),
  });

  static RelaySignalEnvelope decode(String wire) {
    if (wire.length > maxWireBytes) {
      throw const ConnectionFailure('relay_message_limit');
    }
    try {
      final value = jsonDecode(wire);
      if (value is! Map<String, dynamic> ||
          value.length != 7 ||
          value['v'] != version ||
          value['generation'] is! int ||
          value['seq'] is! int ||
          value['kind'] is! String ||
          value['payload'] is! String) {
        throw const ConnectionFailure('invalid_relay_envelope');
      }
      final kind = RelaySignalKind.values
          .where((item) => item.name == value['kind'])
          .firstOrNull;
      if (kind == null) {
        throw const ConnectionFailure('invalid_relay_envelope');
      }
      final payload = _decodePayload(value['payload'] as String);
      final envelope = RelaySignalEnvelope(
        room: _decodeFixed(value['room']),
        sender: _decodeFixed(value['sender']),
        generation: value['generation'] as int,
        sequence: value['seq'] as int,
        kind: kind,
        payload: payload,
      );
      if (envelope.encode() != wire) {
        throw const ConnectionFailure('invalid_relay_envelope');
      }
      return envelope;
    } on FormatException {
      throw const ConnectionFailure('invalid_relay_envelope');
    } on TypeError {
      throw const ConnectionFailure('invalid_relay_envelope');
    }
  }

  static List<int> _decodePayload(String encoded) {
    if (encoded.length > ((maxPayloadBytes + 2) ~/ 3) * 4) {
      throw const ConnectionFailure('relay_message_limit');
    }
    final bytes = base64Url.decode(encoded);
    if (bytes.length > maxPayloadBytes || encodeBytes(bytes) != encoded) {
      throw const ConnectionFailure('invalid_relay_envelope');
    }
    return bytes;
  }

  static List<int> _decodeFixed(Object? encoded) {
    try {
      return decodeBytes(encoded, 32);
    } on ConnectionFailure {
      throw const ConnectionFailure('invalid_relay_envelope');
    }
  }
}

/// One sender's ordered receive gate within a *separately verified* room.
/// A cancelled or old-generation stream cannot deliver to a new operation.
final class RelaySignalInbox {
  RelaySignalInbox({
    required List<int> room,
    required List<int> sender,
    required this.generation,
  }) : _room = encodeBytes(room),
       _sender = encodeBytes(sender) {
    if (room.length != 32 ||
        sender.length != 32 ||
        [...room, ...sender].any((byte) => byte < 0 || byte > 255) ||
        generation < 0 ||
        generation > 0xffffffff) {
      throw const ConnectionFailure('invalid_relay_envelope');
    }
  }

  final String _room, _sender;
  final int generation;
  int _nextSequence = 0;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void accept(RelaySignalEnvelope envelope) {
    if (_cancelled ||
        encodeBytes(envelope.room) != _room ||
        encodeBytes(envelope.sender) != _sender ||
        envelope.generation != generation ||
        envelope.sequence != _nextSequence) {
      throw const ConnectionFailure('stale_relay_message');
    }
    _nextSequence++;
    if (envelope.kind == RelaySignalKind.cancel) _cancelled = true;
  }
}
