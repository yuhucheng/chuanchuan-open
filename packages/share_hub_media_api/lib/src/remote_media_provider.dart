import 'package:flutter/widgets.dart';

import '../share_hub_media_api.dart';

/// Optional composition capability of the SDK's existing preview entry point.
/// Legacy PreviewEngine implementations need not implement this interface.
/// Obtaining the factory must not enumerate sources, capture or open a peer.
abstract interface class RemoteMediaProvider implements PreviewEngine {
  RemoteMediaFactory get remoteMedia;
}

/// Public connection-level media port. The SDK owns the implementation, while
/// the client supplies verified transport, local source policy and one shared
/// process budget. No SDK concrete type is part of the consumer contract.
abstract interface class RemoteMediaFactory {
  MediaCapabilities get capabilities;

  /// Attaches one receiver. Allocation requires valid operation authority and a
  /// budget slot; incoming callbacks never imply a presented first frame.
  RemoteMediaLink createLink({
    required SessionTransport transport,
    required MediaSessionBudget budget,
    required Future<CaptureSource> Function() resolveSource,
    required void Function(RemoteVideoSession session) onSession,
    required void Function(String sessionId, String code) onFailure,
    Future<VideoRecoveryAdmission> Function(
      SessionAuthorization,
      VideoRecoveryRequest,
    )?
    authorizeRecovery,
  });
}

abstract interface class RemoteMediaLink {
  Future<RemoteVideoSession> start(
    SessionOperation operation,
    String id, {
    VideoRecoveryRequest? recovery,
  });

  /// Gates admission, detaches the receiver and waits for actual owned cleanup.
  /// Closing media does not revoke or close the trusted device connection.
  Future<void> close();
}

/// A concrete admitted video operation exposed entirely through public types.
/// Source selection remains local and sender-only. Recovery uses the original
/// authorization policy and explicit new-operation lineage from profile 4.
abstract interface class RemoteVideoSession
    implements SourceSelectableMediaSession {
  SessionAuthorization get authorization;
  bool get sends;
  int get mediaRevision;
  bool get stopped;
  VideoEndReason? get remoteEndReason;
  Widget get view;

  /// Borrows existing resources without creating media, owning cleanup or
  /// acknowledging first presentation. Mounting it must not allocate capture.
  Widget get thumbnailView;

  @override
  Future<void> stop({VideoEndReason reason = VideoEndReason.stopped});
}
