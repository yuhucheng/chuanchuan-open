import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

void main() {
  test(
    'requested capabilities round-trip without enabling a native engine',
    () {
      final requested = {
        ControlCapability.pointer,
        ControlCapability.clipboardText,
      };
      final start = ControlStart(requested);
      requested.clear();
      expect(ControlStart.decode(start.encode()).capabilities, {
        ControlCapability.pointer,
        ControlCapability.clipboardText,
      });
      expect(() => start.capabilities.clear(), throwsUnsupportedError);
    },
  );

  for (final body in [
    '{}',
    '{"v":true,"type":"start","capabilities":["pointer"]}',
    '{"v":1,"v":1,"type":"start","capabilities":["pointer"]}',
    r'{"v":1,"\u0076":1,"type":"start","capabilities":["pointer"]}',
    '{"v":1,"type":"start","capabilities":["pointer","pointer"]}',
    '{"v":1,"type":"start","capabilities":["arbitrary-native-code"]}',
    '{"v":1,"type":"start","capabilities":[]}',
    '{"v":1,"type":"start","capabilities":[true]}',
    '{"v":1,"type":"start","capabilities":{"pointer":true}}',
    '{"v":1,"type":"start","capabilities":["pointer"],"source":"secret-path"}',
    '{"v":1,"type":"start","capabilities":["pointer"],"deadline":"999"}',
    '{"v":1,"type":"start","capabilities":["pointer"],}',
    '[1,"start",["pointer"]]',
  ]) {
    test(
      'invalid start vector ${body.hashCode} fails without echoing content',
      () {
        expect(() => ControlStart.decode(body), throwsA(isA<SessionFailure>()));
        try {
          ControlStart.decode(body);
        } on SessionFailure catch (error) {
          expect(error.toString(), isNot(contains('secret-path')));
          expect(error.toString(), isNot(contains('999')));
        }
      },
    );
  }

  test('unsupported version has a stable error', () {
    expect(
      () => ControlStart.decode(
        '{"v":2,"type":"start","capabilities":["pointer"]}',
      ),
      throwsA(
        isA<SessionFailure>().having(
          (e) => e.code,
          'code',
          'incompatible_version',
        ),
      ),
    );
  });

  test('valid start accepts exactly 4096 bytes but rejects 4097 bytes', () {
    final body = ControlStart({ControlCapability.pointer}).encode();
    final boundary = body.padRight(4096);
    expect(ControlStart.decode(boundary).capabilities, {
      ControlCapability.pointer,
    });
    expect(
      () => ControlStart.decode('$boundary '),
      throwsA(
        isA<SessionFailure>().having((e) => e.code, 'code', 'message_limit'),
      ),
    );
  });

  test('byte limit precedes parsing for multibyte content', () {
    final body = '{"v":1,"type":"start","capabilities":["${'中' * 1400}"]}';
    expect(body.length, lessThan(4096));
    expect(
      () => ControlStart.decode(body),
      throwsA(
        isA<SessionFailure>().having((e) => e.code, 'code', 'message_limit'),
      ),
    );
  });

  test('oversized bodies and empty local requests fail closed', () {
    expect(
      () => ControlStart.decode(' ' * 4097),
      throwsA(isA<SessionFailure>()),
    );
    expect(() => ControlStart({}), throwsA(isA<SessionFailure>()));
  });
}
