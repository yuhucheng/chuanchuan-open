/// Local observations only. A capture sample says nothing about the peer's
/// decoder or display, and a receiver sample says nothing about source changes.
enum MediaFrameStage { capture, receiver }

/// Independent from connection/first-frame state. Null activity means no valid
/// sample, not a stopped session. Ages include sleep and may only grow when a
/// consumer retains this snapshot. Sequence zero means no image observed yet.
final class MediaFrameProgress {
  const MediaFrameProgress.unknown(this.stage)
    : active = null,
      sequence = null,
      age = null,
      outputSequence = null,
      outputAge = null,
      sourceUnchanged = null,
      consumedSequence = null,
      consumedFrameAge = null;

  MediaFrameProgress({
    required this.stage,
    required bool this.active,
    required int this.sequence,
    required this.age,
    this.outputSequence,
    this.outputAge,
    this.sourceUnchanged,
    this.consumedSequence,
    this.consumedFrameAge,
  }) {
    bool invalidCount(int? count) =>
        count != null && (count < 0 || count > 0x7fffffffffffffff);
    bool invalidPair(int? count, Duration? age) =>
        (count == null || count == 0) != (age == null) ||
        (age?.isNegative ?? false);
    if ([sequence, outputSequence, consumedSequence].any(invalidCount) ||
        invalidPair(sequence, age) ||
        invalidPair(outputSequence, outputAge) ||
        invalidPair(consumedSequence, consumedFrameAge) ||
        (stage == MediaFrameStage.capture &&
            (outputSequence == null ||
                sourceUnchanged == null ||
                consumedSequence != null ||
                outputSequence! < sequence!)) ||
        (stage == MediaFrameStage.receiver &&
            (outputSequence != null ||
                sourceUnchanged != null ||
                consumedSequence == null ||
                consumedSequence! > sequence!)) ||
        (outputAge != null && age != null && outputAge! > age!) ||
        (consumedFrameAge != null && age != null && consumedFrameAge! < age!)) {
      throw ArgumentError('Invalid frame progress');
    }
  }

  final MediaFrameStage stage;
  final bool? active;

  /// Captured or decoded image sequence, according to [stage].
  final int? sequence;
  final Duration? age;

  /// Capture output includes idle callbacks; these do not increment [sequence].
  final int? outputSequence;
  final Duration? outputAge;
  final bool? sourceUnchanged;

  /// Texture consumption evidence, not a count of repeated cached repaints.
  final int? consumedSequence;
  final Duration? consumedFrameAge;

  MediaFrameProgress agedBy(Duration elapsed) {
    if (elapsed.isNegative) throw ArgumentError('Negative sample delay');
    if (active == null) return this;
    return MediaFrameProgress(
      stage: stage,
      active: active!,
      sequence: sequence!,
      age: age == null ? null : age! + elapsed,
      outputSequence: outputSequence,
      outputAge: outputAge == null ? null : outputAge! + elapsed,
      sourceUnchanged: sourceUnchanged,
      consumedSequence: consumedSequence,
      consumedFrameAge: consumedFrameAge == null
          ? null
          : consumedFrameAge! + elapsed,
    );
  }
}
