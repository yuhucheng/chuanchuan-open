import 'package:flutter/widgets.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart' as sdk;

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
  Future<void> stop();
}

/// One trusted connection's media receiver. The client owns exactly one per
/// live connection, so a peer-initiated operation is routed instead of dropped.
abstract interface class RemotePictureLink {
  Future<RemotePicture> start(SessionOperation operation, String sessionId);
  Future<void> close();
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

/// Production adapter over the media SDK. It is the only place that names an
/// SDK type, so the rest of the client depends on the port above.
class RtcRemotePictureFactory implements RemotePictureFactory {
  RtcRemotePictureFactory([sdk.RtcRemoteMediaFactory? media])
    : _media = media ?? sdk.RtcRemoteMediaFactory();

  final sdk.RtcRemoteMediaFactory _media;

  @override
  MediaCapabilities get capabilities => _media.capabilities;

  @override
  RemotePictureLink create({
    required SessionTransport transport,
    required MediaSessionBudget budget,
    required Future<CaptureSource> Function() resolveSource,
    required void Function(RemotePicture session) onSession,
    required void Function(String sessionId, String code) onFailure,
  }) => _SdkLink(
    _media.createLink(
      transport: transport,
      budget: budget,
      resolveSource: resolveSource,
      onSession: (session) => onSession(_SdkPicture(session)),
      onFailure: onFailure,
    ),
  );
}

class _SdkLink implements RemotePictureLink {
  _SdkLink(this._link);
  final sdk.RtcRemoteMediaLink _link;

  @override
  Future<RemotePicture> start(SessionOperation operation, String sessionId) async =>
      _SdkPicture(await _link.start(operation, sessionId));

  @override
  Future<void> close() => _link.close();
}

class _SdkPicture implements RemotePicture {
  _SdkPicture(this._session);
  final sdk.RtcVideoSession _session;

  @override
  String get id => _session.id;
  @override
  SessionOperation get operation => _session.authorization.operation;
  @override
  bool get sends => _session.sends;
  @override
  Stream<MediaSessionEvent> get events => _session.events;
  @override
  Widget get view => _session.view;
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
  Future<void> stop() => _session.stop();
}
