import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

void main() {
  test('rejected input never echoes text or source fields in its error', () {
    const privateText = '诊断不可回显-秘密文本';
    const privateSource = 'C:/private/control-source';
    final valid = ControlInputCodec.encode(
      ControlTextInput(
        sequence: 1,
        inputEpoch: 1,
        geometryRevision: 1,
        text: privateText,
      ),
    );
    final fields = jsonDecode(valid) as Map<String, dynamic>;
    fields['source'] = privateSource;
    try {
      ControlInputCodec.decode(jsonEncode(fields));
      fail('extra source field must be rejected');
    } on SessionFailure catch (error) {
      expect(error.toString(), isNot(contains(privateText)));
      expect(error.toString(), isNot(contains(privateSource)));
    }
  });

  test('wire numeric and enum types cannot bypass constructor validation', () {
    final button = ControlPointerButton(
      sequence: 1,
      inputEpoch: 1,
      geometryRevision: 1,
      x: 0,
      y: 0,
      button: ControlButton.primary,
      down: true,
    );
    final key = ControlKey(
      sequence: 1,
      inputEpoch: 1,
      geometryRevision: 1,
      usage: 4,
      action: ControlKeyAction.down,
    );
    for (final (input, field, invalid) in <(ControlInput, String, Object)>[
      (button, 'down', 1),
      (button, 'button', 'unknown'),
      (key, 'usage', 4.0),
      (key, 'action', 'unknown'),
    ]) {
      final fields =
          jsonDecode(ControlInputCodec.encode(input)) as Map<String, dynamic>;
      fields[field] = invalid;
      expect(
        () => ControlInputCodec.decode(jsonEncode(fields)),
        throwsA(isA<SessionFailure>()),
      );
    }
    final body = ControlInputCodec.encode(button)
        .replaceFirst('"x":0.0', '"x":1e309');
    expect(body, contains('1e309'));
    expect(
      () => ControlInputCodec.decode(body),
      throwsA(isA<SessionFailure>()),
    );
  });

  test(
    'decoded UTF-8 bytes and full text body each enforce their own limit',
    () {
      expect(
        () => ControlTextInput(
          sequence: 1,
          inputEpoch: 1,
          geometryRevision: 1,
          text: '中' * 2731,
        ),
        throwsA(
          isA<SessionFailure>().having((e) => e.code, 'code', 'message_limit'),
        ),
      );
      final input = ControlTextInput(
        sequence: 1,
        inputEpoch: 1,
        geometryRevision: 1,
        text: '中',
      );
      final body = ControlInputCodec.encode(input).padRight(48 * 1024);
      expect((ControlInputCodec.decode(body) as ControlTextInput).text, '中');
      expect(
        () => ControlInputCodec.decode('$body '),
        throwsA(
          isA<SessionFailure>().having((e) => e.code, 'code', 'message_limit'),
        ),
      );
    },
  );
  test('leading BOM is text content and survives UTF-8 decoding unchanged', () {
    final input = ControlTextInput(
      sequence: 1,
      inputEpoch: 1,
      geometryRevision: 1,
      text: '\ufeff中文\ufeff',
    );
    final decoded = ControlInputCodec.decode(
      ControlInputCodec.encode(input),
    ) as ControlTextInput;
    expect(decoded.text, input.text);
  });
  Map<String, Object?> move() => {
    'v': 1,
    'type': 'pointer-move',
    'sequence': '1',
    'inputEpoch': '2',
    'geometryRevision': '3',
    'x': .5,
    'y': 1,
  };

  test('typed input families round-trip with exact operation stamps', () {
    final events = <ControlInput>[
      ControlPointerMove(
        sequence: 1,
        inputEpoch: 2,
        geometryRevision: 3,
        x: 0,
        y: 1,
      ),
      ControlPointerButton(
        sequence: 2,
        inputEpoch: 2,
        geometryRevision: 3,
        x: .3,
        y: .4,
        button: ControlButton.secondary,
        down: true,
      ),
      ControlWheel(
        sequence: 3,
        inputEpoch: 2,
        geometryRevision: 3,
        x: .5,
        y: .5,
        deltaX: -120,
        deltaY: .25,
      ),
      ControlKey(
        sequence: 4,
        inputEpoch: 2,
        geometryRevision: 3,
        usage: 0xe0,
        action: ControlKeyAction.down,
      ),
      ControlTextInput(
        sequence: 5,
        inputEpoch: 2,
        geometryRevision: 3,
        text: '中文\n🙂\t"\\',
      ),
    ];
    for (final event in events) {
      final encoded = ControlInputCodec.encode(event);
      final decoded = ControlInputCodec.decode(encoded);
      expect(decoded.runtimeType, event.runtimeType);
      expect(decoded.sequence, event.sequence);
      expect(decoded.inputEpoch, 2);
      expect(decoded.geometryRevision, 3);
      expect(ControlInputCodec.encode(decoded), encoded);
    }
  });

  final invalid = <String, void Function(Map<String, Object?>)>{
    'missing epoch': (m) => m.remove('inputEpoch'),
    'unknown field': (m) => m['path'] = 'sensitive-path',
    'numeric sequence': (m) => m['sequence'] = 1,
    'leading zero': (m) => m['sequence'] = '01',
    'overflow': (m) => m['sequence'] = '9223372036854775808',
    'zero geometry': (m) => m['geometryRevision'] = '0',
    'bool coordinate': (m) => m['x'] = true,
    'negative coordinate': (m) => m['x'] = -.01,
    'large coordinate': (m) => m['y'] = 1.01,
    'float version': (m) => m['v'] = 1.0,
    'unknown type': (m) => m['type'] = 'native-inject',
  };
  for (final entry in invalid.entries) {
    test('input rejects ${entry.key}', () {
      final fields = move();
      entry.value(fields);
      expect(
        () => ControlInputCodec.decode(jsonEncode(fields)),
        throwsA(isA<SessionFailure>()),
      );
    });
  }

  test('duplicate and escaped duplicate properties are rejected', () {
    for (final extra in ['"sequence":"2",', r'"\u0078":0,']) {
      final body = jsonEncode(move()).replaceFirst('{', '{$extra');
      expect(
        () => ControlInputCodec.decode(body),
        throwsA(isA<SessionFailure>()),
      );
    }
  });

  test('constructors cannot bypass numeric, HID and Unicode validation', () {
    expect(
      () => ControlPointerMove(
        sequence: 0,
        inputEpoch: 1,
        geometryRevision: 1,
        x: 0,
        y: 0,
      ),
      throwsA(isA<SessionFailure>()),
    );
    expect(
      () => ControlPointerMove(
        sequence: 1,
        inputEpoch: 1,
        geometryRevision: 1,
        x: double.nan,
        y: 0,
      ),
      throwsA(isA<SessionFailure>()),
    );
    for (final usage in [0, 3, 0x66, 0x74, 0xdf, 0xe8, 0x70004]) {
      expect(
        () => ControlKey(
          sequence: 1,
          inputEpoch: 1,
          geometryRevision: 1,
          usage: usage,
          action: ControlKeyAction.down,
        ),
        throwsA(isA<SessionFailure>()),
      );
    }
    for (final text in ['', '\ud800', '\udc00', 'x' * 8193]) {
      expect(
        () => ControlTextInput(
          sequence: 1,
          inputEpoch: 1,
          geometryRevision: 1,
          text: text,
        ),
        throwsA(isA<SessionFailure>()),
      );
    }
    for (final delta in [0.0, 120.1, double.infinity, double.nan]) {
      expect(
        () => ControlWheel(
          sequence: 1,
          inputEpoch: 1,
          geometryRevision: 1,
          x: 0,
          y: 0,
          deltaX: delta,
          deltaY: 0,
        ),
        throwsA(isA<SessionFailure>()),
      );
    }
  });

  test(
    'text is strict canonical base64url UTF-8, not a clipboard operation',
    () {
      final text = ControlTextInput(
        sequence: 1,
        inputEpoch: 1,
        geometryRevision: 1,
        text: '中\n文🙂',
      );
      final fields =
          jsonDecode(ControlInputCodec.encode(text)) as Map<String, dynamic>;
      expect(fields['type'], 'text-input');
      expect(fields.containsKey('text'), isFalse);
      for (final malformed in ['YQ==', 'YR', '_w', '8J8', 'a+b/', '']) {
        fields['utf8'] = malformed;
        expect(
          () => ControlInputCodec.decode(jsonEncode(fields)),
          throwsA(isA<SessionFailure>()),
        );
      }
    },
  );

  test(
    'max text with escaping fits body bound; ordinary messages remain 4 KiB',
    () {
      final text = ControlTextInput(
        sequence: 0x7fffffffffffffff,
        inputEpoch: 1,
        geometryRevision: 1,
        text: '\u0000' * 8192,
      );
      final encoded = ControlInputCodec.encode(text);
      expect(utf8.encode(encoded).length, lessThan(48 * 1024));
      expect(
        (ControlInputCodec.decode(encoded) as ControlTextInput).text,
        text.text,
      );
      final moveBody = jsonEncode(move()).padRight(4096);
      expect(ControlInputCodec.decode(moveBody), isA<ControlPointerMove>());
      expect(
        () => ControlInputCodec.decode('$moveBody '),
        throwsA(
          isA<SessionFailure>().having((e) => e.code, 'code', 'message_limit'),
        ),
      );
    },
  );
}
