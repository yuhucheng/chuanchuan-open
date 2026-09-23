import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

/// A live picture session as this client consumes it. The client codes against
/// this port, not against a media implementation, so the field can be exercised
/// without a capture device and the implementation stays replaceable.
abstract interface class RemotePicture {
  String get id;

  /// Direction of the operation this session belongs to, as authorized.
  SessionOperation get operation;

  /// True when this endpoint captures and sends; false when it receives.
  bool get sends;

  /// Real media events only. Transport readiness and a presented first frame
  /// stay separate, and this client never reports success without the latter.
  Stream<MediaSessionEvent> get events;

  Widget get view;
  int get mediaRevision;
  bool get stopped;

  /// Set when the peer ended the operation, so a refusal is shown as a refusal
  /// rather than as a local failure.
  VideoEndReason? get remoteEndReason;

  Future<void> pause();
  Future<void> resume();
  Future<void> stop({VideoEndReason reason = VideoEndReason.stopped});
}

/// Optional source selection, exposed only for the endpoint actually sending.
abstract interface class SourceSelectableRemotePicture
    implements RemotePicture {
  CaptureSource? get localSource;
  Future<void> changeSource(CaptureSource source);
}

/// A borrowed view of this operation's existing resources. Mounting/unmounting
/// it must neither allocate media nor dispose the operation or acknowledge its
/// first frame. No independent image cache is retained by the client.
abstract interface class ThumbnailRemotePicture implements RemotePicture {
  Widget get thumbnailView;
}

/// One trusted connection's media receiver. The client owns exactly one per
/// live connection, so a peer-initiated operation is routed instead of dropped.
abstract interface class RemotePictureLink {
  Future<RemotePicture> start(SessionOperation operation, String sessionId);
  Future<void> close();
}

/// Optional recovery port; older test/host implementations stay fail-closed.
abstract interface class RecoverableRemotePicture
    implements SourceSelectableRemotePicture {
  SessionAuthorization get authorization;
  bool get isRecovery;
}

abstract interface class RecoverableRemotePictureLink
    implements RemotePictureLink {
  Future<RemotePicture> startRecovered(
    SessionOperation operation,
    String sessionId,
    VideoRecoveryRequest recovery,
  );
}

abstract interface class RecoverableRemotePictureFactory
    implements RemotePictureFactory {
  RemotePictureLink createRecoverable({
    required SessionTransport transport,
    required MediaSessionBudget budget,
    required Future<CaptureSource> Function() resolveSource,
    required Future<VideoRecoveryAdmission> Function(
      SessionAuthorization,
      VideoRecoveryRequest,
    )
    authorizeRecovery,
    required void Function(RemotePicture session) onSession,
    required void Function(String sessionId, String code) onFailure,
  });
}

/// Declares only what this build implements. The peer's support is confirmed by
/// the session itself; nothing here is inferred from a platform name or UI flag.
abstract interface class RemotePictureFactory {
  MediaCapabilities get capabilities;
  RemotePictureLink create({
    required SessionTransport transport,
    required MediaSessionBudget budget,
    required Future<CaptureSource> Function() resolveSource,
    required void Function(RemotePicture session) onSession,
    required void Function(String sessionId, String code) onFailure,
  });
}

/// Adapter over the optional public SDK port. Legacy preview engines do not
/// require any remote SDK symbol and retain local preview through the same entry.
class ApiRemotePictureFactory implements RecoverableRemotePictureFactory {
  ApiRemotePictureFactory(this._media);

  final RemoteMediaFactory _media;

  @override
  MediaCapabilities get capabilities => _media.capabilities;

  @override
  RemotePictureLink create({
    required SessionTransport transport,
    required MediaSessionBudget budget,
    required Future<CaptureSource> Function() resolveSource,
    required void Function(RemotePicture session) onSession,
    required void Function(String sessionId, String code) onFailure,
    Future<VideoRecoveryAdmission> Function(
      SessionAuthorization,
      VideoRecoveryRequest,
    )?
    authorizeRecovery,
  }) => _SdkLink(
    _media.createLink(
      transport: transport,
      budget: budget,
      resolveSource: resolveSource,
      authorizeRecovery: authorizeRecovery,
      onSession: (session) => onSession(_SdkPicture(session)),
      onFailure: onFailure,
    ),
  );
  @override
  RemotePictureLink createRecoverable({
    required SessionTransport transport,
    required MediaSessionBudget budget,
    required Future<CaptureSource> Function() resolveSource,
    required Future<VideoRecoveryAdmission> Function(
      SessionAuthorization,
      VideoRecoveryRequest,
    )
    authorizeRecovery,
    required void Function(RemotePicture session) onSession,
    required void Function(String sessionId, String code) onFailure,
  }) => create(
    transport: transport,
    budget: budget,
    resolveSource: resolveSource,
    authorizeRecovery: authorizeRecovery,
    onSession: onSession,
    onFailure: onFailure,
  );
}

class _SdkLink implements RecoverableRemotePictureLink {
  _SdkLink(this._link);
  final RemoteMediaLink _link;

  @override
  Future<RemotePicture> start(
    SessionOperation operation,
    String sessionId,
  ) async => _SdkPicture(await _link.start(operation, sessionId));

  @override
  Future<RemotePicture> startRecovered(
    SessionOperation operation,
    String sessionId,
    VideoRecoveryRequest recovery,
  ) async =>
      _SdkPicture(await _link.start(operation, sessionId, recovery: recovery));

  @override
  Future<void> close() => _link.close();
}

class _SdkPicture implements RecoverableRemotePicture, ThumbnailRemotePicture {
  _SdkPicture(this._session);
  final RemoteVideoSession _session;
  @override
  SessionAuthorization get authorization => _session.authorization;
  // SDK checks the authenticated request before calling onSession. This hint
  // only prevents accidental fresh admission when a recovery owner was stopped.
  @override
  bool get isRecovery =>
      (jsonDecode(authorization.body) as Map)['version'] == 4;

  @override
  String get id => _session.id;
  @override
  CaptureSource? get localSource => _session.localSource;
  @override
  Future<void> changeSource(CaptureSource source) =>
      _session.changeSource(source);
  @override
  SessionOperation get operation => _session.authorization.operation;
  @override
  bool get sends => _session.sends;
  @override
  Stream<MediaSessionEvent> get events => _session.events;
  @override
  Widget get view => _session.view;
  @override
  Widget get thumbnailView => _session.thumbnailView;
  @override
  int get mediaRevision => _session.mediaRevision;
  @override
  bool get stopped => _session.stopped;
  @override
  VideoEndReason? get remoteEndReason => _session.remoteEndReason;
  @override
  Future<void> pause() => _session.pause();
  @override
  Future<void> resume() => _session.resume();
  @override
  Future<void> stop({VideoEndReason reason = VideoEndReason.stopped}) =>
      _session.stop(reason: reason);
}

/// Missing optional SDK capabilities are never inferred from preview readiness.
RemotePictureFactory remotePicturesFor(PreviewEngine engine) {
  if (engine is! RemoteMediaProvider) return const PreviewOnlyPictureFactory();
  final media = engine.remoteMedia;
  final declared = media.capabilities;
  if (declared.protocolVersion != sessionProtocolVersion ||
      declared.maxVideoSessions < 1 ||
      !declared.operations.any(
        (operation) =>
            operation == SessionOperation.watch ||
            operation == SessionOperation.cast,
      )) {
    return const PreviewOnlyPictureFactory();
  }
  return ApiRemotePictureFactory(media);
}

/// Preserves legacy preview while refusing remote operations before allocation.
class PreviewOnlyPictureFactory implements RemotePictureFactory {
  const PreviewOnlyPictureFactory();
  @override
  MediaCapabilities get capabilities => MediaCapabilities.previewOnly();
  @override
  RemotePictureLink create({
    required SessionTransport transport,
    required MediaSessionBudget budget,
    required Future<CaptureSource> Function() resolveSource,
    required void Function(RemotePicture session) onSession,
    required void Function(String sessionId, String code) onFailure,
  }) => _UnavailableLink(transport, budget);
}

class _UnavailableLink implements RemotePictureLink {
  _UnavailableLink(this.transport, this.budget) {
    transport.attachReceiver(
      onRequest: _request,
      resolveSession: (_) => null,
      onSignal: (_) {},
    );
  }
  final SessionTransport transport;
  final MediaSessionBudget budget;
  final _pending = <Future<void>>{};
  bool _closed = false;

  void _request(VerifiedSessionMessage request) {
    if (_closed ||
        _pending.length >= 8 ||
        (request.operation != SessionOperation.watch &&
            request.operation != SessionOperation.cast)) {
      return;
    }
    final work = _refuse(request);
    _pending.add(work);
    unawaited(work.then((_) => _pending.remove(work)));
  }

  Future<void> _refuse(VerifiedSessionMessage request) async {
    try {
      await budget.grants.verify(request);
      request.requireCurrent();
      if (_closed) return;
      await transport.sendSignal(
        request,
        const VideoSessionEnd(VideoEndReason.unavailable).encode(),
      );
    } catch (_) {
      // The connection owns transport errors. No capture or retry is started.
    }
  }

  @override
  Future<RemotePicture> start(
    SessionOperation operation,
    String sessionId,
  ) async {
    throw SessionFailure(
      _closed ? 'operation_stopped' : 'capability_unavailable',
    );
  }

  @override
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      transport.detachReceiver();
    }
    await Future.wait(_pending.toList());
  }
}
