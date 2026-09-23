import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

void main() {
  test('public control contract is importable without private src paths', () {
    final start = ControlStart({
      ControlCapability.pointer,
      ControlCapability.clipboardText,
    });
    expect(ControlStart.decode(start.encode()).capabilities,
        contains(ControlCapability.clipboardText));
    final geometry = ControlGeometry(
      sourceToken: 'a' * 32,
      revision: 1,
      mediaRevision: 0,
      width: 1920,
      height: 1080,
      originX: 0,
      originY: 0,
      scaleX: 1,
      scaleY: 1,
      rotation: 0,
    );
    expect(ControlStageCodec.decode(
      ControlStageCodec.encode(ControlGeometryPublished(geometry)),
    ), isA<ControlGeometryPublished>());
    final input = ControlPointerMove(
      sequence: 1,
      inputEpoch: 1,
      geometryRevision: 1,
      x: .5,
      y: .5,
    );
    expect(ControlInputCodec.decode(ControlInputCodec.encode(input)),
        isA<ControlPointerMove>());
    final state = ControlInputState(monotonicMicros: () => 0);
    state.publish(geometry);
    expect(state.isStopped, isFalse);
    final clipboard = ClipboardSideState(
      revision: 1,
      enabled: true,
      available: true,
    );
    expect(ControlClipboardCodec.decode(ControlClipboardCodec.encode(clipboard)),
        isA<ClipboardSideState>());
    final echo = ClipboardEchoGuard();
    expect(echo.observe(changeToken: 'first', text: null),
        ClipboardObservation.noText);
    expect(ControlContext, isNotNull);
  });
}
