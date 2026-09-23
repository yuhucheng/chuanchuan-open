import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

void main() {
  test(
    'unknown and unchanged capture do not become decoded or presented evidence',
    () {
      const unknown = MediaFrameProgress.unknown(MediaFrameStage.capture);
      expect(unknown.active, isNull);
      expect(unknown.sequence, isNull);
      final idle = MediaFrameProgress(
        stage: MediaFrameStage.capture,
        active: true,
        sequence: 1,
        age: const Duration(seconds: 20),
        outputSequence: 5,
        outputAge: const Duration(seconds: 1),
        sourceUnchanged: true,
      );
      expect(idle.consumedSequence, isNull);
      expect(
        idle.agedBy(const Duration(seconds: 60)).age,
        const Duration(seconds: 80),
      );
      expect(
        () => idle.agedBy(const Duration(seconds: -1)),
        throwsArgumentError,
      );
      MediaSessionEvent event(
        MediaEventKind kind,
        MediaFrameProgress? progress,
      ) => MediaSessionEvent(
        grantId: 'g',
        sessionId: 's',
        transportGeneration: 1,
        kind: kind,
        frameProgress: progress,
      );
      expect(
        event(MediaEventKind.frameProgress, idle).kind,
        MediaEventKind.frameProgress,
      );
      expect(() => event(MediaEventKind.firstFrame, idle), throwsArgumentError);
      expect(
        () => event(MediaEventKind.frameProgress, null),
        throwsArgumentError,
      );
    },
  );

  test('invalid ages, counters and cross-stage observations are rejected', () {
    MediaFrameProgress received({
      int sequence = 2,
      Duration? age = const Duration(seconds: 1),
      int consumed = 1,
      Duration? consumedAge = const Duration(seconds: 2),
      int? output,
    }) => MediaFrameProgress(
      stage: MediaFrameStage.receiver,
      active: true,
      sequence: sequence,
      age: age,
      consumedSequence: consumed,
      consumedFrameAge: consumedAge,
      outputSequence: output,
    );
    expect(received().sequence, 2);
    expect(() => received(sequence: -1), throwsArgumentError);
    expect(() => received(consumed: 3), throwsArgumentError);
    expect(() => received(age: null), throwsArgumentError);
    expect(() => received(consumedAge: Duration.zero), throwsArgumentError);
    expect(() => received(output: 0), throwsArgumentError);
    expect(
      () => received(age: const Duration(seconds: -1)),
      throwsArgumentError,
    );
  });
}
