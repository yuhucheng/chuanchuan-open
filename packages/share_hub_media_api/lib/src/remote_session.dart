import 'package:share_hub_session_api/share_hub_session_api.dart';

import '../share_hub_media_api.dart' show CaptureSource, PreviewEngine;

/// API version and wire protocol version are independent. No capability is
/// inferred from PreviewEngine.unavailableReason, platform name or UI state.
final class MediaCapabilities {
  MediaCapabilities({
    required this.protocolVersion,
    required Set<SessionOperation> operations,
    required this.maxVideoSessions,
  }) : operations = Set.unmodifiable(operations) {
    if (maxVideoSessions < 0 || operations.contains(SessionOperation.file)) {
      throw ArgumentError('Invalid media capabilities');
    }
  }
  factory MediaCapabilities.previewOnly() => MediaCapabilities(
    protocolVersion: 0,
    operations: {},
    maxVideoSessions: 0,
  );
  final int protocolVersion;
  final Set<SessionOperation> operations;
  final int maxVideoSessions;
  MediaCapabilities negotiate(MediaCapabilities peer) {
    if (protocolVersion != sessionProtocolVersion ||
        peer.protocolVersion != sessionProtocolVersion) {
      return MediaCapabilities.previewOnly();
    }
    return MediaCapabilities(
      protocolVersion: sessionProtocolVersion,
      operations: operations.intersection(peer.operations),
      maxVideoSessions: maxVideoSessions < peer.maxVideoSessions
          ? maxVideoSessions
          : peer.maxVideoSessions,
    );
  }
}

/// Optional interface: existing PreviewEngine implementations are unchanged.
abstract interface class RemoteMediaEngine implements PreviewEngine {
  MediaCapabilities get mediaCapabilities;
  Future<RemoteMediaSession> startRemote(VerifiedSessionMessage request);
}

/// Optional extension for initiating a session using local grant authority.
/// Neither starting endpoint may report success before the receiver presents
/// its first frame; the incoming-only interface remains source compatible.
abstract interface class BidirectionalRemoteMediaEngine
    implements RemoteMediaEngine {
  Future<RemoteMediaSession> startOutgoing(LocalSessionRequest request);
}

MediaCapabilities capabilitiesOf(PreviewEngine engine) =>
    engine is RemoteMediaEngine
    ? engine.mediaCapabilities
    : MediaCapabilities.previewOnly();

/// Geometry describes the actual source at a revision; input consumers must
/// match that revision. It does not grant input or system capture permission.
final class SourceGeometry {
  SourceGeometry({
    required this.source,
    required this.revision,
    required this.width,
    required this.height,
    this.originX = 0,
    this.originY = 0,
    this.scale = 1,
    this.rotation = 0,
  }) {
    if (source.id.isEmpty ||
        revision < 0 ||
        width <= 0 ||
        height <= 0 ||
        !originX.isFinite ||
        !originY.isFinite ||
        !scale.isFinite ||
        scale <= 0 ||
        !const [0, 90, 180, 270].contains(rotation)) {
      throw ArgumentError('Invalid source geometry');
    }
  }
  final CaptureSource source;
  final int revision, width, height, rotation;
  final double originX, originY, scale;
}

enum MediaEventKind {
  connecting,
  transportReady,
  waitingFirstFrame,
  firstFrame,
  sourceChanged,
  paused,
  ended,
  failed,
  statistics,
}

/// Transport readiness and firstFrame are independent events from the actual
/// implementation. Unmeasured metrics are null, never synthesized as zero.
final class MediaSessionEvent {
  MediaSessionEvent({
    required this.grantId,
    required this.sessionId,
    required this.transportGeneration,
    required this.kind,
    this.mediaRevision = 0,
    this.geometry,
    this.roundTripTime,
    this.bitsPerSecond,
    this.failureCode,
  }) {
    if (grantId.isEmpty ||
        sessionId.isEmpty ||
        transportGeneration < 1 ||
        mediaRevision < 0 ||
        mediaRevision > 0x7fffffff ||
        (roundTripTime != null && roundTripTime!.isNegative) ||
        (bitsPerSecond != null && bitsPerSecond! < 0)) {
      throw ArgumentError('Invalid media event');
    }
  }
  final String grantId, sessionId;
  final int transportGeneration;
  final int mediaRevision;
  final MediaEventKind kind;
  final SourceGeometry? geometry;
  final Duration? roundTripTime;
  final int? bitsPerSecond;
  final String? failureCode;
}

abstract interface class RemoteMediaSession {
  String get id;
  Stream<MediaSessionEvent> get events;
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
}

/// Optional sender-only extension. Older preview/session implementations remain
/// usable without exposing a source-change entry. Receivers cannot select a
/// source on the other device. The selected source is local metadata only.
abstract interface class SourceSelectableMediaSession
    implements RemoteMediaSession {
  CaptureSource? get localSource;

  /// Quiesces the old media revision before starting this exact local source in
  /// a fresh revision under the same grant and budget. Native permission and
  /// source identity are rechecked. Failure never falls back to another source;
  /// cancellation or revoked authorization must not resume capture.
  /// Completion means negotiation, not proof of a presented remote frame.
  Future<void> changeSource(CaptureSource source);
}

/// Shared process-wide budget for watch/cast/control-with-video. Reserve before
/// asynchronous engine startup; retain on cleanup failure. Thumbnail reuse uses
/// the original slot. A stopped operation cannot be restarted with its old ID.
final class MediaSessionBudget {
  MediaSessionBudget(this.capabilities, {required this.grants});
  final GrantRegistry grants;
  final MediaCapabilities capabilities;
  final Set<(String, String)> _seen = {};
  final Map<(String, String), MediaSessionSlot> _active = {};
  int get activeCount => _active.length;
  Future<MediaSessionSlot> reserve(SessionAuthorization request) async {
    await grants.verify(request);
    request.requireCurrent();
    if (capabilities.protocolVersion != sessionProtocolVersion ||
        !capabilities.operations.contains(request.operation)) {
      throw const SessionFailure('capability_unavailable');
    }
    final key = (request.grant.encodedId, request.sessionId);
    // No await between the budget check and acquisition.
    if (_seen.contains(key)) {
      throw const SessionFailure('stale_operation');
    }
    if (_active.length >= capabilities.maxVideoSessions) {
      throw const SessionFailure('busy');
    }
    // Bounded per-process history, fail closed rather than evict replay guards.
    if (_seen.length >= 65536) throw const SessionFailure('operation_limit');
    final slot = MediaSessionSlot._(this, request);
    _seen.add(key);
    _active[key] = slot;
    return slot;
  }
}

final class MediaSessionSlot {
  MediaSessionSlot._(this._owner, this.authorization);
  final MediaSessionBudget _owner;
  final SessionAuthorization authorization;
  bool _released = false;
  String get id => authorization.sessionId;
  (String, String) get _key => (authorization.grant.encodedId, id);
  Future<void> check() async {
    await authorization.check();
    requireCurrent();
  }

  /// Synchronous final gate after an awaited check and before native effects.
  void requireCurrent() {
    authorization.requireCurrent();
    if (_released) throw const SessionFailure('operation_stopped');
  }

  Future<bool> accepts(MediaSessionEvent event) async {
    try {
      await check();
    } on SessionFailure {
      return false;
    }
    return event.grantId == authorization.grant.encodedId &&
        event.sessionId == id &&
        event.transportGeneration == authorization.transportGeneration;
  }

  /// Call only once native cleanup has succeeded; stop-control retains grant.
  void release() {
    _released = true;
    if (identical(_owner._active[_key], this)) _owner._active.remove(_key);
  }
}
