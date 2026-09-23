import 'dart:convert';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'frame_progress.dart';
import 'remote_session.dart';
import 'video_playback.dart';

/// An authenticated, revision-bound question or answer, not a presentation
/// receipt. The consumer must match one outstanding probe and add the complete
/// local round-trip age; receipt time alone never makes a sample fresh.
final class VideoFrameProbe {
  VideoFrameProbe({
    required this.revision,
    required this.probe,
    this.progress,
  }) {
    validateVideoRevision(revision);
    if (probe < 1 || probe > 0x7fffffff) {
      throw const SessionFailure('invalid_frame_probe');
    }
  }
  final int revision, probe;
  final MediaFrameProgress? progress;
  bool get isReply => progress != null;

  String encode() => jsonEncode({
    'version': 1,
    'kind': 'frameProbe',
    'revision': revision,
    'probe': probe,
    'progress': progress == null
        ? null
        : {
            'stage': progress!.stage.name,
            'active': progress!.active,
            'sequence': progress!.sequence,
            'age': progress!.age?.inMicroseconds,
            'outputSequence': progress!.outputSequence,
            'outputAge': progress!.outputAge?.inMicroseconds,
            'sourceUnchanged': progress!.sourceUnchanged,
            'consumedSequence': progress!.consumedSequence,
            'consumedFrameAge': progress!.consumedFrameAge?.inMicroseconds,
          },
  });

  static Future<VideoFrameProbe> receive(
    VerifiedSessionSignal signal, {
    required MediaSessionSlot slot,
    required int expectedRevision,
    required MediaFrameStage peerStage,
  }) async {
    if (!identical(signal.authorization, slot.authorization)) {
      throw const SessionFailure('foreign_media_signal');
    }
    await slot.check();
    slot.requireCurrent();
    signal.requireCurrent();
    if (utf8.encode(signal.body).length > 1024) {
      throw const SessionFailure('media_signal_too_large');
    }
    try {
      final value = jsonDecode(signal.body);
      if (value is! Map<String, dynamic> ||
          value.length != 5 ||
          !value.containsKey('progress') ||
          value['version'] is! int ||
          value['version'] != 1 ||
          value['kind'] != 'frameProbe' ||
          value['probe'] is! int) {
        throw const FormatException();
      }
      requireVideoRevision(value['revision'], expectedRevision);
      MediaFrameProgress? sample;
      final raw = value['progress'];
      if (raw != null) {
        const fields = {
          'stage',
          'active',
          'sequence',
          'age',
          'outputSequence',
          'outputAge',
          'sourceUnchanged',
          'consumedSequence',
          'consumedFrameAge',
        };
        if (raw is! Map<String, dynamic> ||
            raw.keys.toSet().difference(fields).isNotEmpty ||
            raw.length != fields.length ||
            raw['stage'] != peerStage.name) {
          throw const FormatException();
        }
        if (raw['active'] == null) {
          if (raw.entries.any((e) => e.key != 'stage' && e.value != null)) {
            throw const FormatException();
          }
          sample = MediaFrameProgress.unknown(peerStage);
        } else {
          Duration? age(String key) {
            final v = raw[key];
            if (v == null) return null;
            if (v is! int || v < 0 || v > 0x7fffffffffffffff) {
              throw const FormatException();
            }
            return Duration(microseconds: v);
          }

          sample = MediaFrameProgress(
            stage: peerStage,
            active: raw['active'] as bool,
            sequence: raw['sequence'] as int,
            age: age('age'),
            outputSequence: raw['outputSequence'] as int?,
            outputAge: age('outputAge'),
            sourceUnchanged: raw['sourceUnchanged'] as bool?,
            consumedSequence: raw['consumedSequence'] as int?,
            consumedFrameAge: age('consumedFrameAge'),
          );
        }
      }
      final result = VideoFrameProbe(
        revision: expectedRevision,
        probe: value['probe'] as int,
        progress: sample,
      );
      slot.requireCurrent();
      signal.requireCurrent();
      return result;
    } on SessionFailure {
      rethrow;
    } catch (_) {
      throw const SessionFailure('invalid_frame_probe');
    }
  }
}
