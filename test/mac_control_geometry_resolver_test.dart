import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';
import 'package:share_hub_open/features/remote/mac_control_geometry_resolver.dart';

void main() {
  const source = CaptureSource('opaque-screen-token', 'Screen');
  final presented = VideoPresentationReceipt(
    revision: 3,
    width: 2560,
    height: 1440,
  );
  var reads = 0;
  CaptureScreenGeometry frame = const CaptureScreenGeometry(
    'opaque-screen-token',
    -1440,
    100,
    1440,
    810,
  );
  late MacControlGeometryResolver resolver;

  setUp(() {
    reads = 0;
    frame = const CaptureScreenGeometry(
      'opaque-screen-token',
      -1440,
      100,
      1440,
      810,
    );
    resolver = MacControlGeometryResolver(
      readCurrentScreen: (_) async {
        reads++;
        return frame;
      },
      sourceToken: () => 'a' * 32,
    );
  });

  test(
    'binds the painted image to the captured display frame in points',
    () async {
      final geometry = await resolver.resolve(
        source: source,
        presented: presented,
        mediaRevision: 3,
        geometryRevision: 4,
      );
      expect(reads, 1);
      expect(geometry.sourceToken, 'a' * 32);
      expect((geometry.revision, geometry.mediaRevision), (4, 3));
      expect((geometry.width, geometry.height), (2560, 1440));
      expect((geometry.originX, geometry.originY), (-1440, 100));
      expect(geometry.scaleX, (1440 - 1) / (2560 - 1));
      expect(geometry.scaleY, (810 - 1) / (1440 - 1));
      expect(geometry.rotation, 0);
    },
  );

  test(
    'rejects a stale presented revision before asking native capture',
    () async {
      await expectLater(
        resolver.resolve(
          source: source,
          presented: presented,
          mediaRevision: 4,
        ),
        throwsA(isA<SessionFailure>()),
      );
      expect(reads, 0);
    },
  );

  test('rejects another source and malformed native frame', () async {
    await expectLater(
      resolver.resolve(
        source: const CaptureSource(
          'window',
          'Window',
          type: CaptureSourceType.window,
        ),
        presented: presented,
        mediaRevision: 3,
      ),
      throwsA(isA<SessionFailure>()),
    );
    expect(reads, 0);
    frame = const CaptureScreenGeometry('wrong-token', -1440, 100, 1440, 810);
    await expectLater(
      resolver.resolve(source: source, presented: presented, mediaRevision: 3),
      throwsA(isA<SessionFailure>()),
    );
    frame = const CaptureScreenGeometry(
      'opaque-screen-token',
      0,
      0,
      double.nan,
      810,
    );
    await expectLater(
      resolver.resolve(source: source, presented: presented, mediaRevision: 3),
      throwsA(isA<SessionFailure>()),
    );
  });

  test('rejects degenerate pixel-to-point mapping', () async {
    frame = const CaptureScreenGeometry('opaque-screen-token', 0, 0, 1440, 810);
    await expectLater(
      resolver.resolve(
        source: source,
        presented: VideoPresentationReceipt(
          revision: 3,
          width: 1,
          height: 1440,
        ),
        mediaRevision: 3,
      ),
      throwsA(isA<SessionFailure>()),
    );
  });
}
