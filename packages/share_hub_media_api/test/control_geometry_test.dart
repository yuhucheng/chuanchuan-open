import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

void main() {
  ControlGeometry geometry({
    String? sourceToken,
    int revision = 1,
    int mediaRevision = 0,
    int width = 1920,
    int height = 1080,
    double originX = -1920,
    double originY = 0,
    double scaleX = 1.5,
    double scaleY = 2,
    int rotation = 90,
  }) => ControlGeometry(
    sourceToken: sourceToken ?? 'a' * 32,
    revision: revision,
    mediaRevision: mediaRevision,
    width: width,
    height: height,
    originX: originX,
    originY: originY,
    scaleX: scaleX,
    scaleY: scaleY,
    rotation: rotation,
  );

  test('negative desktop origins and nonuniform DPI remain metadata', () {
    final value = geometry();
    expect(value.originX, -1920);
    expect(value.scaleX, 1.5);
    expect(value.scaleY, 2);
    // Coordinates are on the already oriented presented image. No second
    // rotation, scaling or untrusted remote-to-OS mapping happens here.
    expect(value.imagePoint(0, 0), (x: 0.0, y: 0.0));
    expect(value.imagePoint(1, 1), (x: 1919.0, y: 1079.0));
    expect(value.imagePoint(.5, .5), (x: 959.5, y: 539.5));
  });

  test(
    'single-pixel and largest supported image coordinates stay in bounds',
    () {
      expect(geometry(width: 1, height: 1).imagePoint(1, 1), (x: 0.0, y: 0.0));
      final value = geometry(
        width: 65535,
        height: 65535,
        revision: 0x7fffffffffffffff,
        mediaRevision: 0x7fffffff,
      );
      expect(value.imagePoint(1, 1), (x: 65534.0, y: 65534.0));
    },
  );

  final invalid = <String, ControlGeometry Function()>{
    'empty token': () => geometry(sourceToken: ''),
    'token is not opaque ID': () => geometry(sourceToken: 'C:/secret/screen'),
    'uppercase token': () => geometry(sourceToken: 'A' * 32),
    'trailing newline token': () => geometry(sourceToken: '${'a' * 32}\n'),
    'zero revision': () => geometry(revision: 0),
    'negative revision': () => geometry(revision: -1),
    'negative media revision': () => geometry(mediaRevision: -1),
    'large media revision': () => geometry(mediaRevision: 0x80000000),
    'zero width': () => geometry(width: 0),
    'negative height': () => geometry(height: -1),
    'large width': () => geometry(width: 65536),
    'large height': () => geometry(height: 65536),
    'nan origin': () => geometry(originX: double.nan),
    'infinite origin': () => geometry(originY: double.infinity),
    'nan scale': () => geometry(scaleX: double.nan),
    'infinite scale': () => geometry(scaleY: double.infinity),
    'zero scale': () => geometry(scaleX: 0),
    'negative scale': () => geometry(scaleY: -1),
    'invalid rotation': () => geometry(rotation: 45),
  };
  for (final entry in invalid.entries) {
    test('geometry rejects ${entry.key}', () {
      expect(entry.value, throwsA(isA<SessionFailure>()));
    });
  }
  for (final value in [
    -.001,
    1.001,
    double.nan,
    double.infinity,
    double.negativeInfinity,
  ]) {
    test('normalized pointer rejects $value on either axis', () {
      expect(
        () => geometry().imagePoint(value, .5),
        throwsA(isA<SessionFailure>()),
      );
      expect(
        () => geometry().imagePoint(.5, value),
        throwsA(isA<SessionFailure>()),
      );
    });
  }
}
