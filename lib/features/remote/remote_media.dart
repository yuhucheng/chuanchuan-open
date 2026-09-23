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
  Future<void> stop({VideoEndReason reason = VideoEndReason.stopped});
}

/// Optional source selection, exposed only for the endpoint actually sending.
abstract interface class SourceSelectableRemotePicture
    implements RemotePicture {
  CaptureSource? get localSource;
  Future<void> changeSource(CaptureSource source);
}

final class RemoteControlInputScope {
  const RemoteControlInputScope({
    required this.inputEpoch,
    required this.geometryRevision,
    required this.mediaRevision,
    required this.width,
    required this.height,
  });
  final int inputEpoch, geometryRevision, mediaRevision, width, height;
}

/// Input is available only after the SDK has matched an actual painted frame
/// with authenticated geometry and the target's input-ready acknowledgement.
abstract interface class RemoteControlPicture implements RemotePicture {
  Listenable get inputChanges;
  RemoteControlInputScope? get inputScope;
  Future<void> sendInput(ControlInput input);
  Future<void> releaseInput();
}

/// One trusted connection's media receiver. The client owns exactly one per
/// live connection, so a peer-initiated operation is routed instead of dropped.
abstract interface class RemotePictureLink {
  Future<RemotePicture> start(SessionOperation operation, String sessionId);
  Future<RemotePicture> startControl(String sessionId, ControlStart start);
  Future<void> close();
}

/// Declares only what this build implements. The peer's support is confirmed by
/// the session itself; nothing here is inferred from a platform name or UI flag.
abstract interface class RemotePictureFactory {
  MediaCapabilities get capabilities;
  Set<ControlCapability> get controlCapabilities;
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
  RtcRemotePictureFactory.withRelayLease(
    sdk.RelayIceLease? Function() currentRelayLease,
  ) : _media = sdk.RtcRemoteMediaFactory(currentRelayLease: currentRelayLease);

  final sdk.RtcRemoteMediaFactory _media;

  @override
  MediaCapabilities get capabilities => _media.capabilities;

  @override
  Set<ControlCapability> get controlCapabilities => _media.controlCapabilities;

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
      onControlSession: (session) => onSession(_SdkControlPicture(session)),
    ),
  );
}

class _SdkLink implements RemotePictureLink {
  _SdkLink(this._link);
  final sdk.RtcRemoteMediaLink _link;

  @override
  Future<RemotePicture> start(
    SessionOperation operation,
    String sessionId,
  ) async => _SdkPicture(await _link.start(operation, sessionId));

  @override
  Future<RemotePicture> startControl(
    String sessionId,
    ControlStart start,
  ) async => _SdkControlPicture(await _link.startControl(sessionId, start));

  @override
  Future<void> close() => _link.close();
}

class _SdkControlPicture implements RemoteControlPicture {
  _SdkControlPicture(this._operation);
  final sdk.RtcControlOperation _operation;

  @override
  Listenable get inputChanges => _operation.controllerInputChanges;
  @override
  RemoteControlInputScope? get inputScope {
    final state = _operation.controllerInputScope;
    if (state == null) return null;
    return RemoteControlInputScope(
      inputEpoch: state.inputEpoch,
      geometryRevision: state.geometryRevision,
      mediaRevision: state.mediaRevision,
      width: state.width,
      height: state.height,
    );
  }

  @override
  Future<void> sendInput(ControlInput input) => _operation.sendInput(input);
  @override
  Future<void> releaseInput() => _operation.releaseInput();

  @override
  String get id => _operation.picture.id;
  @override
  SessionOperation get operation => SessionOperation.control;
  @override
  bool get sends => !_operation.context.localIsController;
  @override
  Stream<MediaSessionEvent> get events => _operation.picture.events;
  @override
  Widget get view => _operation.view;
  @override
  int get mediaRevision => _operation.picture.mediaRevision;
  @override
  bool get stopped => _operation.stopped;
  @override
  VideoEndReason? get remoteEndReason => _operation.picture.remoteEndReason;
  @override
  Future<void> pause() => throw const SessionFailure('capability_unavailable');
  @override
  Future<void> resume() => throw const SessionFailure('capability_unavailable');
  @override
  Future<void> stop({VideoEndReason reason = VideoEndReason.stopped}) =>
      _operation.stop();
}

class _SdkPicture implements SourceSelectableRemotePicture {
  _SdkPicture(this._session);
  final sdk.RtcVideoSession _session;

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
