import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/remote/remote_media.dart';

/// Only native media is simulated. Requests, reply authentication, grants,
/// recovery intent and resource budget use the production public contracts.
class RecoveryMedia implements RecoverableRemotePictureFactory {
  final pictures = <RecoveryPicture>[];
  final links = <RecoveryLink>[];
  int captures = 0;
  @override
  MediaCapabilities get capabilities => MediaCapabilities(
    protocolVersion: sessionProtocolVersion,
    operations: {SessionOperation.watch, SessionOperation.cast},
    maxVideoSessions: 1,
  );
  @override
  RemotePictureLink create({
    required SessionTransport transport,
    required MediaSessionBudget budget,
    required Future<CaptureSource> Function() resolveSource,
    required void Function(RemotePicture) onSession,
    required void Function(String, String) onFailure,
  }) => createRecoverable(
    transport: transport,
    budget: budget,
    resolveSource: resolveSource,
    authorizeRecovery: (_, _) =>
        throw const SessionFailure('media_recovery_unavailable'),
    onSession: onSession,
    onFailure: onFailure,
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
    required void Function(RemotePicture) onSession,
    required void Function(String, String) onFailure,
  }) {
    final link = RecoveryLink(
      this,
      transport,
      budget,
      resolveSource,
      authorizeRecovery,
      onSession,
      onFailure,
    );
    links.add(link);
    return link;
  }
}

class _Entry {
  _Entry(this.authorization) {
    unawaited(ready.future.catchError((Object _) {}));
  }
  final SessionAuthorization authorization;
  final ready = Completer<void>();
  RecoveryPicture? picture;
  VideoRecoveryAdmission? admission;
  void abort() {
    if (!ready.isCompleted) {
      ready.completeError(const SessionFailure('operation_stopped'));
    }
  }
}

class RecoveryLink implements RecoverableRemotePictureLink {
  RecoveryLink(
    this.factory,
    this.transport,
    this.budget,
    this.resolveSource,
    this.authorizeRecovery,
    this.onSession,
    this.onFailure,
  ) {
    transport.attachReceiver(
      onRequest: (request) {
        final entry = _entries[request.sessionId] = _Entry(request);
        _own(() => _admit(entry)).catchError((Object _) {});
      },
      resolveSession: (id) => _entries[id]?.authorization,
      onSignal: (signal) {
        final entry = _entries[signal.authorization.sessionId];
        if (entry != null) {
          unawaited(_signal(entry, signal).catchError((Object _) {}));
        }
      },
    );
  }
  final RecoveryMedia factory;
  final SessionTransport transport;
  final MediaSessionBudget budget;
  final Future<CaptureSource> Function() resolveSource;
  final Future<VideoRecoveryAdmission> Function(
    SessionAuthorization,
    VideoRecoveryRequest,
  )
  authorizeRecovery;
  final void Function(RemotePicture) onSession;
  final void Function(String, String) onFailure;
  final _entries = <String, _Entry>{};
  final _pending = <Future<void>>{};
  bool closed = false;
  Future<void> _own(Future<void> Function() action) {
    final completion = Completer<void>();
    _pending.add(completion.future);
    completion.complete(
      Future<void>.sync(action)
          .whenComplete(() => _pending.remove(completion.future)),
    );
    return completion.future;
  }

  @override
  Future<RemotePicture> start(SessionOperation operation, String id) =>
      _start(operation, id, null);
  @override
  Future<RemotePicture> startRecovered(
    SessionOperation operation,
    String id,
    VideoRecoveryRequest recovery,
  ) => _start(operation, id, recovery);
  Future<RemotePicture> _start(
    SessionOperation operation,
    String id,
    VideoRecoveryRequest? recovery,
  ) async {
    final authorization = await transport.createRequest(
      operation,
      id,
      recovery == null
          ? VideoSessionRequest.body
          : VideoSessionRequest.recoveryBody(recovery),
    );
    final entry = _entries[id] = _Entry(authorization);
    await _own(() => _admit(entry));
    return entry.picture!;
  }

  void _check(_Entry entry) {
    if (closed || entry.picture?.stopped == true) {
      throw const SessionFailure('operation_stopped');
    }
    entry.authorization.requireCurrent();
    entry.admission?.requireCurrent();
  }

  Future<void> _admit(_Entry entry) async {
    MediaSessionSlot? slot;
    try {
      final recovery = await VideoSessionRequest.recovery(entry.authorization);
      if (recovery != null) {
        entry.admission = await authorizeRecovery(
          entry.authorization,
          recovery,
        );
      }
      _check(entry);
      slot = await budget.reserve(entry.authorization);
      _check(entry);
      if (recovery != null && entry.authorization is LocalSessionRequest) {
        await transport.sendRequest(entry.authorization as LocalSessionRequest);
        await entry.ready.future.timeout(const Duration(seconds: 1));
        _check(entry);
        entry.admission!.requireStart();
      }
      final picture = entry.picture = RecoveryPicture(
        this,
        slot,
        recovery != null,
      );
      factory.pictures.add(picture);
      onSession(picture);
      _check(entry);
      picture.localSource = entry.admission != null
          ? entry.admission!.source
          : picture.sends
          ? await resolveSource()
          : null;
      _check(entry);
      if (recovery != null && entry.authorization is VerifiedSessionMessage) {
        await transport.sendSignal(
          entry.authorization,
          VideoRecoveryReady.body,
        );
        _check(entry);
      }
      if (entry.admission?.paused == true) {
        picture.emit(MediaEventKind.paused);
      } else {
        if (picture.sends) factory.captures++;
        picture.emit(MediaEventKind.waitingFirstFrame);
      }
      if (recovery == null && entry.authorization is LocalSessionRequest) {
        await transport.sendRequest(entry.authorization as LocalSessionRequest);
      }
    } catch (error) {
      final picture = entry.picture;
      if (picture == null) {
        slot?.release();
      } else {
        await picture.stop();
      }
      if (!closed) {
        onFailure(
          entry.authorization.sessionId,
          error is SessionFailure ? error.code : 'media_start_failed',
        );
        try {
          await transport.sendSignal(
            entry.authorization,
            const VideoSessionEnd(VideoEndReason.failed).encode(),
          );
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> _signal(_Entry entry, VerifiedSessionSignal signal) async {
    await signal.check();
    signal.requireCurrent();
    final kind = (jsonDecode(signal.body) as Map)['kind'];
    if (kind == 'recovery-ready') {
      await entry.admission!.confirmPeer(signal);
      if (!entry.ready.isCompleted) entry.ready.complete();
    } else if (kind == 'ended') {
      final end = await VideoSessionEnd.receive(
        signal,
        authorization: entry.authorization,
      );
      entry.abort();
      final picture = entry.picture;
      if (picture != null) {
        picture.endedBy = end.reason;
        await picture.stop(notify: false);
      }
    } else if (kind == 'fixture-pause') {
      entry.picture!.emit(MediaEventKind.paused);
    } else if (kind == 'fixture-source') {
      entry.picture!.revision++;
      entry.picture!.emit(MediaEventKind.waitingFirstFrame);
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    transport.detachReceiver();
    for (final entry in _entries.values) {
      entry.abort();
    }
    await Future.wait([
      for (final entry in _entries.values)
        if (entry.picture != null) entry.picture!.stop(),
    ]);
    await Future.wait(
      _pending.map((future) => future.catchError((Object _) {})),
    );
  }
}

class RecoveryPicture implements RecoverableRemotePicture {
  RecoveryPicture(this.link, this.slot, this.isRecovery) {
    _invalidation = authorization.invalidated.listen((_) {
      emit(MediaEventKind.failed, failure: 'authorization_invalid');
      unawaited(stop(notify: false).catchError((Object _) {}));
    });
  }
  final RecoveryLink link;
  final MediaSessionSlot slot;
  late final StreamSubscription<void> _invalidation;
  final _events = StreamController<MediaSessionEvent>.broadcast(sync: true);
  Completer<void>? stopGate;
  bool failStop = false;
  Future<void>? _stopping;
  bool _stopped = false;
  bool _released = false;
  int revision = 0;
  VideoEndReason? endedBy;
  @override
  SessionAuthorization get authorization => slot.authorization;
  @override
  final bool isRecovery;
  @override
  String get id => authorization.sessionId;
  @override
  SessionOperation get operation => authorization.operation;
  @override
  bool get sends => operation == SessionOperation.cast
      ? authorization is LocalSessionRequest
      : authorization is VerifiedSessionMessage;
  @override
  CaptureSource? localSource;
  @override
  int get mediaRevision => revision;
  @override
  bool get stopped => _stopped;
  @override
  VideoEndReason? get remoteEndReason => endedBy;
  @override
  Stream<MediaSessionEvent> get events => _events.stream;
  @override
  Widget get view => const SizedBox();
  void emit(MediaEventKind kind, {String? failure}) {
    if (_events.isClosed) return;
    _events.add(
      MediaSessionEvent(
        grantId: authorization.grant.encodedId,
        sessionId: id,
        transportGeneration: authorization.transportGeneration,
        mediaRevision: revision,
        kind: kind,
        failureCode: failure,
      ),
    );
  }

  @override
  Future<void> pause() async {
    emit(MediaEventKind.paused);
    await link.transport.sendSignal(authorization, '{"kind":"fixture-pause"}');
  }

  @override
  Future<void> resume() async {
    revision++;
    emit(MediaEventKind.waitingFirstFrame);
  }

  @override
  Future<void> changeSource(CaptureSource source) async {
    localSource = source;
    revision++;
    emit(MediaEventKind.waitingFirstFrame);
    await link.transport.sendSignal(authorization, '{"kind":"fixture-source"}');
  }

  @override
  Future<void> stop({
    VideoEndReason reason = VideoEndReason.stopped,
    bool notify = true,
  }) {
    if (_stopping != null) return _stopping!;
    if (_released) return Future.value();
    _stopped = true;
    return _stopping = () async {
      try {
        if (notify) {
          try {
            await link.transport.sendSignal(
              authorization,
              VideoSessionEnd(reason).encode(),
            );
          } catch (_) {}
        }
        await stopGate?.future;
        if (failStop) throw StateError('native release');
        await _invalidation.cancel();
        slot.release();
        _released = true;
        emit(MediaEventKind.ended);
        unawaited(_events.close());
      } finally {
        _stopping = null;
      }
    }();
  }
}
