import 'dart:convert';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:test/test.dart';

void main() {
  final room = List<int>.generate(32, (index) => index);
  final sender = List<int>.generate(32, (index) => index + 32);
  final other = List<int>.generate(32, (index) => index + 64);

  RelaySignalEnvelope data(int sequence, {int generation = 7}) =>
      RelaySignalEnvelope(
        room: room,
        sender: sender,
        generation: generation,
        sequence: sequence,
        kind: RelaySignalKind.data,
        payload: [1, 2, 3],
      );

  test('canonical opaque wire preserves sender, generation and bytes', () {
    final original = data(0);
    final wire = original.encode();
    expect(
      wire,
      '{"v":1,"room":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",'
      '"sender":"ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=",'
      '"generation":7,"seq":0,"kind":"data","payload":"AQID"}',
    );
    final decoded = RelaySignalEnvelope.decode(wire);
    expect(decoded.room, room);
    expect(decoded.sender, sender);
    expect(decoded.generation, 7);
    expect(decoded.sequence, 0);
    expect(decoded.payload, [1, 2, 3]);
    expect(decoded.encode(), wire);
    expect(wire, contains('"payload":"AQID"'));
    expect(wire, isNot(contains('SDP')));
  });

  test('noncanonical and ambiguous wire cannot reach an inbox', () {
    final wire = data(0).encode();
    final invalid = <String>[
      '$wire ',
      wire.replaceFirst('"v":1,', '"v":1,"v":1,'),
      wire.replaceFirst('"v":1', '"v":2'),
      wire.replaceFirst('"payload":"AQID"', '"payload":"AQID="'),
      wire.replaceFirst('"generation":7', '"generation":-1'),
      wire.replaceFirst('"seq":0', '"seq":4294967296'),
      wire.replaceFirst('"kind":"data"', '"kind":"unknown"'),
      wire.replaceFirst('"sender":', '"extra":0,"sender":'),
      jsonEncode({...jsonDecode(wire) as Map<String, dynamic>, 'payload': ''}),
    ];
    for (final sample in invalid) {
      expect(
        () => RelaySignalEnvelope.decode(sample),
        throwsA(isA<ConnectionFailure>()),
        reason: sample,
      );
    }
  });

  test('wrong member, old generation, replay and cancel fail closed', () {
    final inbox = RelaySignalInbox(room: room, sender: sender, generation: 7);
    inbox.accept(data(0));
    expect(() => inbox.accept(data(0)), throwsA(isA<ConnectionFailure>()));
    expect(
      () => inbox.accept(data(1, generation: 6)),
      throwsA(isA<ConnectionFailure>()),
    );
    expect(
      () => inbox.accept(
        RelaySignalEnvelope(
          room: room,
          sender: other,
          generation: 7,
          sequence: 1,
          kind: RelaySignalKind.data,
          payload: [9],
        ),
      ),
      throwsA(isA<ConnectionFailure>()),
    );
    inbox.accept(data(1));
    inbox.accept(
      RelaySignalEnvelope(
        room: room,
        sender: sender,
        generation: 7,
        sequence: 2,
        kind: RelaySignalKind.cancel,
        payload: const [],
      ),
    );
    expect(inbox.cancelled, isTrue);
    expect(() => inbox.accept(data(3)), throwsA(isA<ConnectionFailure>()));
  });

  test('oversized and malformed payloads are rejected before routing', () {
    expect(
      () => RelaySignalEnvelope(
        room: room,
        sender: sender,
        generation: 0,
        sequence: 0,
        kind: RelaySignalKind.data,
        payload: List<int>.filled(RelaySignalEnvelope.maxPayloadBytes + 1, 0),
      ),
      throwsA(isA<ConnectionFailure>()),
    );
    expect(
      () => RelaySignalEnvelope(
        room: room,
        sender: sender,
        generation: 0,
        sequence: 0,
        kind: RelaySignalKind.cancel,
        payload: [1],
      ),
      throwsA(isA<ConnectionFailure>()),
    );
    expect(
      () => RelaySignalEnvelope.decode(
        'x' * (RelaySignalEnvelope.maxWireBytes + 1),
      ),
      throwsA(isA<ConnectionFailure>()),
    );
  });
}
