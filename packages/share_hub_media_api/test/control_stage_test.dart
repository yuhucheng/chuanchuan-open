import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

void main() {
  ControlGeometry geometry(int revision, {int media = 1}) => ControlGeometry(
    sourceToken: 'a' * 32,
    revision: revision,
    mediaRevision: media,
    width: 1920,
    height: 1080,
    originX: -1920,
    originY: 0,
    scaleX: 1.5,
    scaleY: 1.5,
    rotation: 90,
  );
  ControlPointerMove move(int sequence, int epoch, int revision) =>
      ControlPointerMove(
        sequence: sequence,
        inputEpoch: epoch,
        geometryRevision: revision,
        x: .25,
        y: .75,
      );

  test('stage messages round-trip with exact role and geometry fields', () {
    final stages = <ControlStage>[
      ControlGeometryPublished(geometry(1)),
      ControlGeometryReady(
        sourceToken: 'a' * 32,
        geometryRevision: 1,
        mediaRevision: 1,
      ),
      ControlInputReady(geometryRevision: 1, inputEpoch: 1),
      ControlReleaseAll(inputEpoch: 1),
      ControlReleased(inputEpoch: 2),
      const ControlStop(),
      const ControlStopped(),
    ];
    for (final stage in stages) {
      final encoded = ControlStageCodec.encode(stage);
      final decoded = ControlStageCodec.decode(encoded);
      expect(decoded.runtimeType, stage.runtimeType);
      expect(ControlStageCodec.encode(decoded), encoded);
    }
    expect(
      (ControlStageCodec.decode(
        ControlStageCodec.encode(stages.first),
      ) as ControlGeometryPublished).geometry.originX,
      -1920,
    );
  });

  test(
    'geometry must be presented and acknowledged before input is admitted',
    () {
      final gate = ControlInputGate();
      expect(() => gate.admit(move(1, 1, 1)), throwsA(isA<SessionFailure>()));
      gate.publish(geometry(1));
      expect(() => gate.enable(inputEpoch: 1), throwsA(isA<SessionFailure>()));
      gate.geometryReady(
        ControlGeometryReady(
          sourceToken: 'a' * 32,
          geometryRevision: 1,
          mediaRevision: 1,
        ),
      );
      gate.enable(inputEpoch: 1);
      gate.admit(move(1, 1, 1));
      expect(() => gate.admit(move(1, 1, 1)), throwsA(isA<SessionFailure>()));
      gate.admit(move(3, 1, 1)); // Coalesced unsent moves may skip sequence 2.
    },
  );

  test('old and mismatched picture acknowledgements never enable input', () {
    final gate = ControlInputGate();
    gate.publish(geometry(1));
    gate.publish(geometry(2, media: 2));
    for (final ready in [
      ControlGeometryReady(
        sourceToken: 'a' * 32,
        geometryRevision: 1,
        mediaRevision: 1,
      ),
      ControlGeometryReady(
        sourceToken: 'b' * 32,
        geometryRevision: 2,
        mediaRevision: 2,
      ),
      ControlGeometryReady(
        sourceToken: 'a' * 32,
        geometryRevision: 2,
        mediaRevision: 1,
      ),
    ]) {
      expect(() => gate.geometryReady(ready), throwsA(isA<SessionFailure>()));
      expect(() => gate.enable(inputEpoch: 1), throwsA(isA<SessionFailure>()));
    }
    gate.geometryReady(
      ControlGeometryReady(
        sourceToken: 'a' * 32,
        geometryRevision: 2,
        mediaRevision: 2,
      ),
    );
    gate.enable(inputEpoch: 1);
    expect(() => gate.admit(move(1, 1, 1)), throwsA(isA<SessionFailure>()));
    gate.admit(move(2, 1, 2));
  });

  test(
    'release and stop gate input synchronously; new epoch needs cleanup',
    () {
      final gate = ControlInputGate();
      gate.publish(geometry(1));
      gate.geometryReady(
        ControlGeometryReady(
          sourceToken: 'a' * 32,
          geometryRevision: 1,
          mediaRevision: 1,
        ),
      );
      gate.enable(inputEpoch: 1);
      gate.admit(move(1, 1, 1));
      gate.beginRelease(ControlReleaseAll(inputEpoch: 1));
      expect(() => gate.admit(move(2, 1, 1)), throwsA(isA<SessionFailure>()));
      expect(() => gate.admit(move(2, 2, 1)), throwsA(isA<SessionFailure>()));
      expect(
        () => gate.finishRelease(inputEpoch: 1),
        throwsA(isA<SessionFailure>()),
      );
      gate.finishRelease(inputEpoch: 2);
      expect(() => gate.admit(move(2, 1, 1)), throwsA(isA<SessionFailure>()));
      gate.admit(move(2, 2, 1));
      gate.stop();
      expect(() => gate.admit(move(3, 2, 1)), throwsA(isA<SessionFailure>()));
      expect(() => gate.publish(geometry(2)), throwsA(isA<SessionFailure>()));
    },
  );

  test('geometry change during release never restores old input', () {
    final gate = ControlInputGate();
    gate.publish(geometry(1));
    gate.geometryReady(
      ControlGeometryReady(
        sourceToken: 'a' * 32,
        geometryRevision: 1,
        mediaRevision: 1,
      ),
    );
    gate.enable(inputEpoch: 1);
    gate.beginRelease(ControlReleaseAll(inputEpoch: 1));
    gate.publish(geometry(2, media: 2));
    gate.finishRelease(inputEpoch: 2);
    expect(gate.canAcceptInput, isFalse);
    expect(() => gate.admit(move(1, 2, 1)), throwsA(isA<SessionFailure>()));
    expect(() => gate.admit(move(1, 2, 2)), throwsA(isA<SessionFailure>()));
    gate.geometryReady(
      ControlGeometryReady(
        sourceToken: 'a' * 32,
        geometryRevision: 2,
        mediaRevision: 2,
      ),
    );
    gate.enable(inputEpoch: 3);
    gate.admit(move(1, 3, 2));
  });

  test('new geometry invalidates old input before the next handshake', () {
    final gate = ControlInputGate();
    gate.publish(geometry(1));
    gate.geometryReady(
      ControlGeometryReady(
        sourceToken: 'a' * 32,
        geometryRevision: 1,
        mediaRevision: 1,
      ),
    );
    gate.enable(inputEpoch: 1);
    gate.publish(geometry(2, media: 2));
    expect(() => gate.admit(move(1, 1, 1)), throwsA(isA<SessionFailure>()));
    gate.geometryReady(
      ControlGeometryReady(
        sourceToken: 'a' * 32,
        geometryRevision: 2,
        mediaRevision: 2,
      ),
    );
    expect(() => gate.enable(inputEpoch: 1), throwsA(isA<SessionFailure>()));
    gate.enable(inputEpoch: 2);
    gate.admit(move(1, 2, 2));
  });

  test('local picture loss seals old geometry until a newer handshake', () {
    final gate = ControlInputGate();
    gate.publish(geometry(1));
    gate.geometryReady(
      ControlGeometryReady(
        sourceToken: 'a' * 32,
        geometryRevision: 1,
        mediaRevision: 1,
      ),
    );
    gate.enable(inputEpoch: 1);
    expect(gate.invalidatePicture(), isTrue);
    expect(gate.canAcceptInput, isFalse);
    expect(() => gate.admit(move(1, 1, 1)), throwsA(isA<SessionFailure>()));
    gate.finishPictureInvalidation();
    expect(
      () => gate.geometryReady(
        ControlGeometryReady(
          sourceToken: 'a' * 32,
          geometryRevision: 1,
          mediaRevision: 1,
        ),
      ),
      throwsA(isA<SessionFailure>()),
    );
    expect(() => gate.publish(geometry(1)), throwsA(isA<SessionFailure>()));
    gate.publish(geometry(2, media: 2));
    gate.geometryReady(
      ControlGeometryReady(
        sourceToken: 'a' * 32,
        geometryRevision: 2,
        mediaRevision: 2,
      ),
    );
    gate.enable(inputEpoch: 2);
    expect(() => gate.admit(move(1, 1, 1)), throwsA(isA<SessionFailure>()));
    gate.admit(move(2, 2, 2));
  });

  test('malformed stage data cannot create a ready or stopped message', () {
    final valid = jsonDecode(
      ControlStageCodec.encode(
        ControlInputReady(geometryRevision: 1, inputEpoch: 1),
      ),
    ) as Map<String, dynamic>;
    for (final bad in [
      {...valid, 'inputEpoch': '01'},
      {...valid, 'inputEpoch': 1},
      {...valid, 'geometryRevision': '9223372036854775808'},
      {...valid, 'path': 'secret'},
      {...valid, 'type': 'input-ready', 'v': true},
    ]) {
      expect(
        () => ControlStageCodec.decode(jsonEncode(bad)),
        throwsA(isA<SessionFailure>()),
      );
    }
    expect(
      () => ControlStageCodec.decode('{"v":1,"v":1,"type":"stop"}'),
      throwsA(isA<SessionFailure>()),
    );
    final body = ControlStageCodec.encode(const ControlStopped())
        .padRight(4096);
    expect(ControlStageCodec.decode(body), isA<ControlStopped>());
    expect(
      () => ControlStageCodec.decode('$body '),
      throwsA(
        isA<SessionFailure>().having((e) => e.code, 'code', 'message_limit'),
      ),
    );
  });
}
