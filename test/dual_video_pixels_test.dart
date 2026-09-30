import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../integration_test/owned_video_pixels.dart';
import '../integration_test/owned_video_view.dart';

void main() {
  test(
    'readback discards samples spanning session, revision or stop changes',
    () async {
      final initial = OwnedVideoSampleState(Object(), 0, false);
      for (final changed in [
        OwnedVideoSampleState(Object(), 0, false),
        OwnedVideoSampleState(initial.session, 1, false),
        OwnedVideoSampleState(initial.session, 0, true),
      ]) {
        var current = initial;
        final readback = Completer<OwnedVideoPixels>();
        final pending = readStableOwnedVideoPixels(
          initial,
          () => current,
          () => readback.future,
        );
        current = changed;
        readback.complete(
          const OwnedVideoPixels(readable: true, ownedPattern: true),
        );
        expect(await pending, isNull);
      }
      final sample = await readStableOwnedVideoPixels(
        initial,
        () => initial,
        () async => const OwnedVideoPixels(readable: true, cleared: true),
      );
      expect(sample!.cleared, isTrue);
    },
  );
  testWidgets('empty video paints a readable opaque cleared region', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(ownedVideoProbeView(key, const SizedBox.shrink()));
    await tester.pump();
    final sample = await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        return inspectOwnedVideoPixels(
          await image.toByteData(format: ui.ImageByteFormat.rawRgba),
          image.width,
          image.height,
        );
      } finally {
        image.dispose();
      }
    });
    expect(sample!.readable, isTrue);
    expect(sample.cleared, isTrue);
    expect(sample.ownedPattern, isFalse);
  });
  test('missing and truncated readback cannot prove a cleared view', () {
    expect(inspectOwnedVideoPixels(null, 32, 32).cleared, isFalse);
    expect(inspectOwnedVideoPixels(ByteData(4), 32, 32).readable, isFalse);
  });
  test('unknown marker retains evidence of the owned video pattern', () {
    final data = ByteData(32 * 32 * 4);
    const colors = [
      [224, 32, 32],
      [32, 208, 64],
      [32, 64, 224],
      [224, 208, 32],
    ];
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 32; x++) {
        final color = colors[(y < 16 ? 0 : 2) + (x < 16 ? 0 : 1)];
        for (var c = 0; c < 3; c++) {
          data.setUint8((y * 32 + x) * 4 + c, color[c]);
        }
        data.setUint8((y * 32 + x) * 4 + 3, 255);
      }
    }
    for (var c = 0; c < 3; c++) {
      data.setUint8((8 * 32 + 16) * 4 + c, 128);
    }
    final sample = inspectOwnedVideoPixels(data, 32, 32);
    expect(sample.readable, isTrue);
    expect(sample.ownedPattern, isTrue);
    expect(sample.marker, isNull);
    expect(sample.cleared, isFalse);
  });
  test('clear requires the entire opaque white display region', () {
    final data = ByteData.sublistView(
      Uint8List(32 * 32 * 4)..fillRange(0, 32 * 32 * 4, 255),
    );
    expect(inspectOwnedVideoPixels(data, 32, 32).cleared, isTrue);
    data.setUint8(0, 0);
    expect(inspectOwnedVideoPixels(data, 32, 32).cleared, isFalse);
    data.setUint8(0, 255);
    data.setUint8(3, 0);
    expect(inspectOwnedVideoPixels(data, 32, 32).cleared, isFalse);
  });
}
