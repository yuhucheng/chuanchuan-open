import 'dart:async';
import 'dart:convert';

import '../share_hub_media_api.dart';

/// Lineage only. No source identifier, permission, deadline, or new grant is
/// accepted from the peer. Both endpoints must retain their own matching intent.
final class VideoRecoveryRequest {
  VideoRecoveryRequest({
    required this.previousSessionId,
    required this.previousTransportGeneration,
    required this.previousRevision,
    required this.paused,
  }) {
    if (previousSessionId.isEmpty ||
        utf8.encode(previousSessionId).length > 128 ||
        previousTransportGeneration < 1 ||
        previousTransportGeneration > 0x7fffffff) {
      throw const SessionFailure('invalid_media_recovery');
    }
    validateVideoRevision(previousRevision);
  }
  final String previousSessionId;
  final int previousTransportGeneration, previousRevision;
  final bool paused;
  Map<String, Object> toJson() => {
    'session': previousSessionId,
    'generation': previousTransportGeneration,
    'revision': previousRevision,
    'paused': paused,
  };
  static VideoRecoveryRequest decode(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        value['session'] is! String ||
        value['generation'] is! int ||
        value['revision'] is! int ||
        value['paused'] is! bool) {
      throw const SessionFailure('invalid_media_recovery');
    }
    return VideoRecoveryRequest(
      previousSessionId: value['session'],
      previousTransportGeneration: value['generation'],
      previousRevision: value['revision'],
      paused: value['paused'],
    );
  }
}

/// Process-local intent recorded from an actual admitted picture. It cannot
/// authorize traffic: claim() additionally needs a fresh sealed authorization.
/// The owner must cancel it for explicit stop, failed source/permission, exit,
/// or abandonment, and supply the actual old-resource cleanup Future.
final class VideoRecoveryIntent {
  VideoRecoveryIntent({
    required this.previous,
    required int revision,
    required bool paused,
    required this.source,
    required this.released,
  }) : request = VideoRecoveryRequest(
         previousSessionId: previous.sessionId,
         previousTransportGeneration: previous.transportGeneration,
         previousRevision: revision,
         paused: paused,
       ) {
    if (previous.operation != SessionOperation.watch &&
        previous.operation != SessionOperation.cast) {
      throw const SessionFailure('capability_unavailable');
    }
    final sends = previous.operation == SessionOperation.cast
        ? previous is LocalSessionRequest
        : previous is VerifiedSessionMessage;
    if (sends != (source != null) || source?.id.isEmpty == true) {
      throw const SessionFailure('invalid_media_source');
    }
  }
  final SessionAuthorization previous;
  final VideoRecoveryRequest request;
  final CaptureSource? source;
  final Future<void> released;
  final _cancelled = StreamController<void>.broadcast(sync: true);
  bool _stopped = false;
  SessionAuthorization? _claim;
  bool get stopped => _stopped;
  void cancel() {
    if (_stopped) return;
    _stopped = true;
    _cancelled.add(null);
    unawaited(_cancelled.close());
  }

  Future<VideoRecoveryAdmission> claim(
    SessionAuthorization next,
    VideoRecoveryRequest received,
  ) async {
    if (_stopped ||
        _claim != null ||
        !identical(previous.grant, next.grant) ||
        previous.operation != next.operation ||
        previous.expiresMicros != next.expiresMicros ||
        previous.sender != next.sender ||
        (previous is LocalSessionRequest) != (next is LocalSessionRequest) ||
        next.sessionId == previous.sessionId ||
        next.transportGeneration <= previous.transportGeneration ||
        received.previousSessionId != request.previousSessionId ||
        received.previousTransportGeneration !=
            request.previousTransportGeneration ||
        received.previousRevision != request.previousRevision ||
        received.paused != request.paused) {
      throw const SessionFailure('media_recovery_unavailable');
    }
    _claim = next;
    void current() {
      if (_stopped || !identical(_claim, next)) {
        throw const SessionFailure('operation_stopped');
      }
      next.requireCurrent();
    }

    try {
      current();
      await released;
      current();
      final encoded = await VideoSessionRequest.recovery(next);
      if (encoded == null ||
          encoded.previousSessionId != received.previousSessionId ||
          encoded.previousTransportGeneration !=
              received.previousTransportGeneration ||
          encoded.previousRevision != received.previousRevision ||
          encoded.paused != received.paused) {
        throw const SessionFailure('invalid_media_recovery');
      }
      current();
      return VideoRecoveryAdmission._(
        next,
        source,
        request.paused,
        current,
        _cancelled.stream,
      );
    } catch (_) {
      cancel();
      rethrow;
    }
  }
}

/// Minted only after local lineage and old cleanup match a fresh authorization.
final class VideoRecoveryAdmission {
  VideoRecoveryAdmission._(
    this._authorization,
    this.source,
    this.paused,
    this.requireCurrent,
    this.cancelled,
  );
  final SessionAuthorization _authorization;
  bool _peerReady = false;
  final CaptureSource? source;
  final bool paused;
  final void Function() requireCurrent;
  final Stream<void> cancelled;
  Future<void> confirmPeer(VerifiedSessionSignal signal) async {
    requireCurrent();
    if (_peerReady) throw const SessionFailure('invalid_media_recovery');
    await VideoRecoveryReady.check(signal, _authorization);
    requireCurrent();
    _peerReady = true;
  }

  void requireStart() {
    requireCurrent();
    if (_authorization is LocalSessionRequest && !_peerReady) {
      throw const SessionFailure('media_recovery_unconfirmed');
    }
  }
}

/// Acknowledges the peer's retained intent and released old resources. It is
/// bound to the NEW operation by authenticated signaling; it is not a frame.
abstract final class VideoRecoveryReady {
  static const body = '{"version":1,"kind":"recovery-ready"}';
  static Future<void> check(
    VerifiedSessionSignal signal,
    SessionAuthorization authorization,
  ) async {
    if (!identical(signal.authorization, authorization) ||
        authorization is! LocalSessionRequest) {
      throw const SessionFailure('foreign_media_signal');
    }
    await signal.check();
    signal.requireCurrent();
    if (utf8.encode(signal.body).length > 128) {
      throw const SessionFailure('invalid_media_recovery');
    }
    Object? value;
    try {
      value = jsonDecode(signal.body);
    } on FormatException {
      throw const SessionFailure('invalid_media_recovery');
    }
    if (value is! Map<String, dynamic> ||
        value.length != 2 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['kind'] != 'recovery-ready') {
      throw const SessionFailure('invalid_media_recovery');
    }
  }
}
