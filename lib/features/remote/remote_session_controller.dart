import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import '../../platform/client_platform.dart';
import '../connections/connection_controller.dart';
import 'remote_media.dart';

/// Real states of a remote picture. `connecting` covers authorization and
/// channel setup; `waitingFirstFrame` means the channel is up but the peer has
/// not presented the source yet, so neither state is ever shown as success.
enum RemotePhase {
  idle,
  connecting,
  recovering,
  waitingFirstFrame,
  active,
  paused,
  failed,
}

/// Process-wide coordinator for remote send and watch.
///
/// It owns the shared single-picture budget, one media receiver per live
/// trusted connection, and the only place that decides whether a frame has
/// really arrived. Local preview and remote sending never run at once: this
/// controller refuses to start while the local capturer is active, and the
/// preview controller refuses while a remote picture is live.
class RemoteSessionController extends ChangeNotifier {
  RemoteSessionController({
    required this.connections,
    required this.platform,
    required this.factory,
    required this.listSources,
    this.localCaptureActive,
    this.relayCredentialAvailable,
    this.relayCredentialChanges,
    this.relayCredentialGrace = const Duration(seconds: 20),
    this.firstFrameDeadline = const Duration(seconds: 15),
    this.permissionPoll = const Duration(seconds: 2),
    this.statisticsLifetime = const Duration(seconds: 6),
    this.mediaRecoveryDeadline = const Duration(seconds: 45),
  }) : _capabilities = factory.capabilities,
       budget = MediaSessionBudget(
         factory.capabilities,
         grants: connections.grants,
       ) {
    connections.addListener(_reconcile);
    relayCredentialChanges?.addListener(_tryRelayRetry);
    _reconcile();
  }

  final ConnectionController connections;
  final ClientPlatform platform;
  final RemotePictureFactory factory;

  /// Enumerates this device's own sources. Used only to resolve the sharing
  /// endpoint's current primary screen; it never widens a remote request.
  final Future<List<CaptureSource>> Function() listSources;

  /// True while the local preview capturer is active or not yet released.
  final bool Function()? localCaptureActive;

  /// A snapshot only. Media never waits for the auxiliary service on admission.
  final bool Function()? relayCredentialAvailable;

  /// Notifies when a valid lease arrives after direct ICE has failed.
  final Listenable? relayCredentialChanges;
  final Duration relayCredentialGrace;
  final Duration firstFrameDeadline;
  final Duration permissionPoll;
  // Diagnostic freshness only; an expired sample does not mean capture failed.
  final Duration statisticsLifetime;
  final Duration mediaRecoveryDeadline;
  _MediaRecovery? _recovery;
  _RelayRetry? _relayRetry;
  bool get recovering => _recovery != null;

  /// One budget for watch, cast and (later) control-with-video in this process.
  final MediaSessionBudget budget;

  final MediaCapabilities _capabilities;
  // Two devices can hold independently authorized connections in both
  // directions. A peer key is identity, not a transport/receiver owner.
  final _links = <TrustedConnection, RemotePictureLink>{};
  // A disconnected link still owns native resources until close succeeds.
  final _retiredLinks = <RemotePictureLink>{};
  final _closingLinks = <RemotePictureLink, Future<void>>{};
  final _unreleasedPictures = <RemotePicture>{};
  final _stoppingPictures = <RemotePicture, Future<void>>{};
  final _unreleasedSubscriptions = <StreamSubscription<MediaSessionEvent>>{};
  final _cancellingSubscriptions =
      <StreamSubscription<MediaSessionEvent>, Future<void>>{};
  final _pendingStarts = <Future<void>>{};
  Future<void>? _shutdownFuture, _stopFuture;
  ({String? reason, bool failed})? _stopOutcome;
  bool _shuttingDown = false;
  _Attempt? _attempt;
  Timer? _deadline;
  Timer? _permissionTimer;
  Timer? _statisticsDeadline;
  MediaSessionEvent? _statistics;
  MediaFrameProgress? _frameProgress;
  Timer? _frameProgressDeadline;
  Stopwatch? _frameSampleAge;
  MediaFrameProgress? get frameProgress =>
      _frameProgress?.agedBy(_frameSampleAge?.elapsed ?? Duration.zero);
  MediaFrameProgress? _peerFrameProgress;
  Timer? _peerFrameDeadline;
  Stopwatch? _peerFrameAge;
  MediaFrameProgress? get peerFrameProgress =>
      _peerFrameProgress?.agedBy(_peerFrameAge?.elapsed ?? Duration.zero);

  void _clearPeerFrame() {
    _peerFrameDeadline?.cancel();
    _peerFrameDeadline = null;
    _peerFrameProgress = null;
    _peerFrameAge = null;
  }

  /// Presentation cache only. Window lifecycle changes clear displayed evidence
  /// without stopping process-owned sampling or changing any authorization.
  void clearFrameProgress() {
    _clearPeerFrame();
    _frameProgressDeadline?.cancel();
    _frameProgressDeadline = null;
    _frameProgress = null;
    _frameSampleAge = null;
    _notify();
  }

  int _generation = 0;
  int _sessionCounter = 0;
  bool _disposed = false;
  bool _busy = false;
  bool _stopping = false;
  bool _checkingPermission = false;
  RemotePhase _phase = RemotePhase.idle;
  String? _error;
  bool _cleanupFailed = false;
  List<CaptureSource> _sourceChoices = const [];
  String? _sourceError;
  List<CaptureSource> get sourceChoices => _sourceChoices;
  String? get sourceError => _sourceError;
  bool get sourceBusy =>
      (_attempt?.loadingSources ?? false) ||
      (_attempt?.changingSource ?? false);
  CaptureSource? get localSource => switch (session) {
    SourceSelectableRemotePicture picture when picture.sends =>
      picture.localSource,
    _ => null,
  };
  bool get supportsSourceSelection =>
      sending && session is SourceSelectableRemotePicture;
  bool get canChangeSource =>
      supportsSourceSelection &&
      !sourceBusy &&
      !_stopping &&
      (_phase == RemotePhase.active || _phase == RemotePhase.paused);

  /// Operations this build can offer. The peer's own support is confirmed by
  /// the session; a refusal is shown as a refusal, never as success.
  Set<String> get offeredOperations {
    if (_shuttingDown ||
        _capabilities.maxVideoSessions < 1 ||
        _capabilities.protocolVersion != sessionProtocolVersion) {
      return const {};
    }
    return {
      for (final operation in _capabilities.operations)
        if (operation == SessionOperation.watch ||
            operation == SessionOperation.cast)
          operation.name,
    };
  }

  Set<String> operationsFor(String peerKey) =>
      connections.outgoingFor(peerKey) != null ? offeredOperations : const {};

  RemotePicture? get session => _attempt?.picture;

  /// Reads the current process-owned picture; this never starts/refreshes media.
  /// A same-name device or a new grant cannot borrow another operation's view.
  ThumbnailRemotePicture? thumbnailFor(String key) {
    final attempt = _attempt;
    final picture = attempt?.picture;
    if (_disposed ||
        _shuttingDown ||
        _stopping ||
        _cleanupFailed ||
        _phase != RemotePhase.active ||
        attempt == null ||
        attempt.cancelled ||
        attempt.changingSource ||
        attempt.peerKey != key ||
        attempt.connection.isClosed ||
        !connections.sessions.contains(attempt.connection) ||
        attempt.connection.grant?.phase != GrantPhase.active ||
        picture is! ThumbnailRemotePicture ||
        picture.stopped) {
      return null;
    }
    return picture;
  }

  SessionOperation? get operation =>
      _attempt?.operation ?? _recovery?.intent.previous.operation;
  String? get peerKey => _attempt?.peerKey ?? _recovery?.previous.peerKey;
  String? get peerLabel => _attempt?.label ?? _recovery?.label;
  RemotePhase get phase => _phase;
  String? get error => _error;
  bool get busy => _busy;
  bool get cleanupFailed => _cleanupFailed;
  bool get shuttingDown => _shuttingDown;
  bool get transportReady => _attempt?.transportReady ?? false;
  bool get sending =>
      !_shuttingDown &&
      _attempt?.cancelled == false &&
      _attempt?.picture?.sends == true;
  bool get receiving =>
      !_shuttingDown &&
      _attempt?.cancelled == false &&
      _attempt?.picture?.sends == false;
  int get mediaRevision => _attempt?.picture?.mediaRevision ?? 0;
  MediaTransportPath? get transportPath => _statistics?.transportPath;
  Duration? get roundTripTime => _statistics?.roundTripTime;
  int? get bitsPerSecond => _statistics?.bitsPerSecond;
  int? get frameWidth => _statistics?.frameWidth;
  int? get frameHeight => _statistics?.frameHeight;

  /// A live picture occupies the single picture budget for the whole process.
  bool get occupied =>
      _attempt != null ||
      _recovery != null ||
      _unreleasedPictures.isNotEmpty ||
      budget.activeCount != 0;

  @override
  void dispose() {
    // Explicit desktop exit awaits shutdown. Widget disposal is only a final
    // best-effort fallback and must not open admission again.
    unawaited(shutdown().catchError((Object _) {}));
    _disposed = true;
    connections.removeListener(_reconcile);
    relayCredentialChanges?.removeListener(_tryRelayRetry);
    super.dispose();
  }

  /// Permanently gates this process owner's admission, then awaits every
  /// owned cleanup, including disconnected links and late/rejected sessions.
  /// A failed attempt retains handles for retry; concurrent callers join the
  /// same future, including after the desktop's bounded wait has timed out.
  Future<void> shutdown() {
    if (_shutdownFuture case final pending?) return pending;
    final completion = Completer<void>();
    _shutdownFuture = completion.future;
    unawaited(
      _shutdown().then<void>(
        (_) {
          _shutdownFuture = null;
          completion.complete();
        },
        onError: (Object error, StackTrace stack) {
          _shutdownFuture = null;
          completion.completeError(error, stack);
        },
      ),
    );
    return completion.future;
  }

  Future<void> _shutdown() async {
    _shuttingDown = true;
    connections.removeListener(_reconcile);
    // stop() gates current display/callbacks synchronously, before disconnect
    // can trigger native or transport callbacks in the desktop exit sequence.
    final currentStop = stop();
    _retiredLinks.addAll(_links.values);
    _links.clear();
    final cleanup = <Future<void>>[
      currentStop,
      for (final link in _retiredLinks.toList()) _closeLink(link),
      for (final picture in _unreleasedPictures.toList()) _stopPicture(picture),
      for (final subscription in _unreleasedSubscriptions.toList())
        _cancelSubscription(subscription),
      ..._pendingStarts,
    ];
    try {
      await Future.wait(cleanup);
      // Pending starts may hand back an owner after the initial snapshot.
      // Drain work already started by their rejection; never discard a handle
      // or spin retrying a failed native release within the same exit request.
      while (_closingLinks.isNotEmpty ||
          _stoppingPictures.isNotEmpty ||
          _cancellingSubscriptions.isNotEmpty) {
        await Future.wait([
          ..._closingLinks.values,
          ..._stoppingPictures.values,
          ..._cancellingSubscriptions.values,
        ]);
      }
      if (_attempt != null &&
          !_busy &&
          _unreleasedSubscriptions.isEmpty &&
          !_unreleasedPictures.contains(_attempt?.picture)) {
        await stop();
      }
      if (_retiredLinks.isNotEmpty ||
          _unreleasedPictures.isNotEmpty ||
          _unreleasedSubscriptions.isNotEmpty ||
          _attempt != null ||
          budget.activeCount != 0) {
        throw const SessionFailure('media_cleanup_failed');
      }
      _cleanupFailed = false;
    } catch (_) {
      _cleanupProblem();
      throw const SessionFailure('media_cleanup_failed');
    }
  }

  Future<void> _closeLink(RemotePictureLink link) =>
      _releaseOwned(link, _retiredLinks, _closingLinks, link.close);

  Future<void> _stopPicture(
    RemotePicture picture, {
    VideoEndReason reason = VideoEndReason.stopped,
  }) {
    return _releaseOwned(
      picture,
      _unreleasedPictures,
      _stoppingPictures,
      () => picture.stop(reason: reason),
    );
  }

  Future<void> _cancelSubscription(
    StreamSubscription<MediaSessionEvent> subscription,
  ) => _releaseOwned(
    subscription,
    _unreleasedSubscriptions,
    _cancellingSubscriptions,
    subscription.cancel,
  );

  // Register before calling native code: synchronous reentry joins this work.
  Future<void> _releaseOwned<T>(
    T owner,
    Set<T> retained,
    Map<T, Future<void>> pending,
    Future<void> Function() release,
  ) {
    retained.add(owner);
    if (pending[owner] case final existing?) return existing;
    final completion = Completer<void>();
    pending[owner] = completion.future;
    unawaited(
      Future<void>.sync(release).then<void>(
        (_) {
          retained.remove(owner);
          pending.remove(owner);
          completion.complete();
        },
        onError: (Object error, StackTrace stack) {
          pending.remove(owner);
          completion.completeError(error, stack);
        },
      ),
    );
    return completion.future;
  }

  void _cleanupProblem() {
    _cleanupFailed = true;
    _phase = RemotePhase.failed;
    _error = '远端画面资源释放失败，请再次停止或重试退出。';
    _notify();
  }

  // ------------------------------------------------------------------ starting

  /// Starts a watch or cast towards an already verified peer. A peer that is not
  /// connected yet is refused here: the caller runs the short-code flow first
  /// and only then asks for the operation.
  Future<void> start(
    SessionOperation operation, {
    required String peerKey,
    String? label,
  }) {
    _clearRelayRetry();
    return _trackWork(() => _start(operation, peerKey: peerKey, label: label));
  }

  Future<void> _trackWork(Future<void> Function() action) {
    final completion = Completer<void>();
    _pendingStarts.add(completion.future);
    completion.complete(
      Future<void>.sync(action).whenComplete(() {
        _pendingStarts.remove(completion.future);
      }),
    );
    return completion.future;
  }

  Future<void> _start(
    SessionOperation operation, {
    required String peerKey,
    String? label,
    _MediaRecovery? recovery,
    TrustedConnection? restoredConnection,
    bool relayRetry = false,
  }) async {
    if (_disposed || _shuttingDown || _busy) return;
    if (_recovery != null && !identical(_recovery, recovery)) {
      _fail('正在恢复原画面，请先停止恢复再开始新的画面。');
      return;
    }
    if (operation != SessionOperation.watch &&
        operation != SessionOperation.cast) {
      _fail('本版本不提供该远端操作。');
      return;
    }
    if (_attempt != null) {
      _fail('已有远端画面会话占用单画面预算，请先结束再开始新的。');
      return;
    }
    if (!offeredOperations.contains(operation.name)) {
      _fail('当前构建未协商出该远端操作。');
      return;
    }
    if (localCaptureActive?.call() ?? false) {
      _fail('本机预览正在进行，请先停止预览再开始远端画面。');
      return;
    }
    final connection = restoredConnection ?? connections.outgoingFor(peerKey);
    if (connection == null) {
      _fail(
        connections.sessions.any((s) => !s.isClosed && s.peerKey == peerKey)
            ? '当前连接方向不允许该操作，请输入对方的短接码建立反向连接。'
            : '该设备尚未完成身份验证；请先输入 6 位短接码连接。',
      );
      return;
    }
    final token = ++_generation;
    final attempt = _Attempt(token, connection, operation, label: label)
      ..sessionId = 'remote-${++_sessionCounter}'
      ..relayRetried = relayRetry || recovery != null
      ..relayAvailableAtStart = _relayReady();
    _attempt = attempt;
    recovery?.replacementId = attempt.sessionId;
    _busy = true;
    _cleanupFailed = false;
    _error = null;
    _phase = recovery == null ? RemotePhase.connecting : RemotePhase.recovering;
    _notify();
    try {
      if (_shuttingDown || attempt.cancelled) {
        throw const SessionFailure('operation_stopped');
      }
      final link = _linkFor(connection);
      final started = recovery == null
          ? await link.start(operation, attempt.sessionId)
          : link is RecoverableRemotePictureLink
          ? await link.startRecovered(
              operation,
              attempt.sessionId,
              recovery.intent.request,
            )
          : throw const SessionFailure('media_recovery_unavailable');
      if (_disposed || attempt.cancelled || token != _generation) {
        // A cancelled or superseded start must not leave a live session behind.
        if (!_disposed && identical(_attempt, attempt)) {
          // Adoption may have been refused after cancellation. Keep its late
          // owner reachable until cleanup succeeds, including a failed retry.
          attempt.picture ??= started;
          attempt.cancelled = true;
        } else {
          await _silentStop(started);
        }
        return;
      }
      attempt.picture ??= started;
      if (attempt.picture!.stopped) {
        // stopped gates callbacks; it does not prove native cleanup succeeded.
        attempt.cancelled = true;
        return;
      }
      if (!attempt.firstFrame &&
          attempt.transportReady &&
          _phase != RemotePhase.paused) {
        _armFirstFrameDeadline(attempt);
      }
    } catch (failure) {
      if (recovery != null) _dropRecovery(recovery);
      if (!_disposed && token == _generation) {
        _phase = RemotePhase.failed;
        _error = _failureMessage(failure);
      }
      // Admission can fail after acquiring native resources. An adopted owner
      // must remain reachable until stop confirms that cleanup completed.
      attempt.cancelled = true;
    } finally {
      _busy = false;
      if (attempt.cancelled && identical(_attempt, attempt)) {
        if (_recovery?.previous == attempt.connection) {
          await _stopTracked(reason: _error, failed: false);
        } else {
          await stop(reason: _error, failed: _phase == RemotePhase.failed);
        }
      }
      _notify();
      if (identical(_relayRetry?.attempt, attempt)) _tryRelayRetry();
    }
  }

  /// Cancels an in-flight start. On an established session use [stop]: it ends
  /// the operation, notifies the peer and releases the resources.
  Future<void> cancel() => stop(reason: '已取消远端画面，未建立远端画面。');

  Future<void> pause() async {
    final attempt = _attempt;
    final picture = attempt?.picture;
    if (_disposed ||
        _shuttingDown ||
        attempt == null ||
        picture == null ||
        sourceBusy) {
      return;
    }
    try {
      await picture.pause();
    } catch (failure) {
      if (!_isCurrent(attempt)) return;
      _clearObservations();
      _phase = RemotePhase.failed;
      _error = _failureMessage(failure);
      _notify();
    }
  }

  Future<void> resume() async {
    final attempt = _attempt;
    final picture = attempt?.picture;
    if (_disposed ||
        _shuttingDown ||
        attempt == null ||
        picture == null ||
        sourceBusy) {
      return;
    }
    try {
      attempt.firstFrame = false;
      attempt.transportReady = false;
      attempt.minimumRevision = picture.mediaRevision + 1;
      _clearObservations();
      _phase = RemotePhase.connecting;
      _notify();
      await picture.resume();
      if (_isCurrent(attempt)) {
        _armFirstFrameDeadline(attempt, afterSourceChange: true);
      }
    } catch (failure) {
      if (!_isCurrent(attempt)) return;
      _clearObservations();
      _phase = RemotePhase.failed;
      _error = _failureMessage(failure);
      _notify();
    }
  }

  /// Stops the current picture and releases its resources. A failed release
  /// stays visible and the same session can be stopped again.
  Future<void> stop({String? reason, bool failed = false}) {
    _clearRelayRetry();
    if (_recovery case final recovery?) _dropRecovery(recovery);
    return _stopTracked(reason: reason, failed: failed, explicit: true);
  }

  Future<void> _stopTracked({
    String? reason,
    bool failed = false,
    bool explicit = false,
  }) {
    if (explicit) {
      _stopOutcome = (reason: reason, failed: failed);
    } else if (_stopFuture == null) {
      _stopOutcome = null;
    }
    if (_stopFuture case final pending?) return pending;
    final completion = Completer<void>();
    _stopFuture = completion.future;
    final stopped = _stop(reason: reason, failed: failed);
    final generation = _generation;
    unawaited(
      stopped.then<void>(
        (_) {
          final outcome = _stopOutcome;
          if (outcome != null &&
              !_disposed &&
              _generation == generation &&
              !_cleanupFailed &&
              _recovery == null) {
            _phase = outcome.failed ? RemotePhase.failed : RemotePhase.idle;
            _error = outcome.reason;
            _notify();
          }
          _stopOutcome = null;
          _stopFuture = null;
          completion.complete();
        },
        onError: (Object error, StackTrace stack) {
          _stopOutcome = null;
          _stopFuture = null;
          completion.completeError(error, stack);
        },
      ),
    );
    return completion.future;
  }

  Future<void> _stop({String? reason, bool failed = false}) async {
    final attempt = _attempt;
    if (_disposed || _stopping) return;
    if (attempt == null) {
      _stopping = true;
      try {
        await Future.wait([
          for (final link in _retiredLinks.toList()) _closeLink(link),
          for (final picture in _unreleasedPictures.toList())
            _stopPicture(picture),
          for (final subscription in _unreleasedSubscriptions.toList())
            _cancelSubscription(subscription),
        ]);
        _cleanupFailed = false;
        _phase = _recovery != null
            ? RemotePhase.recovering
            : failed
            ? RemotePhase.failed
            : RemotePhase.idle;
        _error = reason;
      } catch (_) {
        _cleanupProblem();
      } finally {
        _stopping = false;
        _notify();
      }
      return;
    }
    _stopping = true;
    _clearObservations();
    _sourceChoices = const [];
    _sourceError = null;
    // Late frames, receipts and remote signals of this attempt are now stale.
    _generation++;
    _deadline?.cancel();
    _deadline = null;
    _permissionTimer?.cancel();
    _permissionTimer = null;
    // Admission may still be in flight; it must not adopt a session afterwards.
    attempt.cancelled = true;
    attempt.transportReady = false;
    attempt.firstFrame = false;
    final pendingAdmission = attempt.picture == null && _busy;
    _phase = _recovery != null
        ? RemotePhase.recovering
        : failed
        ? RemotePhase.failed
        : RemotePhase.idle;
    _error = reason;
    _notify();
    try {
      final picture = attempt.picture;
      await Future.wait([
        _cancelEvents(attempt),
        if (picture != null) _stopPicture(picture),
        for (final link in _retiredLinks.toList()) _closeLink(link),
      ]);
      _cleanupFailed = false;
      if (!pendingAdmission && identical(_attempt, attempt)) _attempt = null;
      _phase = _recovery != null
          ? RemotePhase.recovering
          : failed
          ? RemotePhase.failed
          : RemotePhase.idle;
      _error = reason;
      if (_unreleasedPictures.isNotEmpty ||
          _unreleasedSubscriptions.isNotEmpty) {
        _cleanupProblem();
      }
    } catch (_) {
      // Keep the attempt so the user can retry the release; a failed cleanup is
      // never shown as fully stopped.
      _cleanupFailed = true;
      _phase = RemotePhase.failed;
      _error = '远端画面资源释放失败，请再次停止，或退出 Share Hub。';
    } finally {
      _stopping = false;
      _notify();
    }
  }

  // ----------------------------------------------------------- reconciliation

  void _reconcile() {
    if (_disposed || _shuttingDown) return;
    final live = connections.sessions.where((c) => !c.isClosed).toSet();
    if (_relayRetry case final retry?) {
      if (!live.contains(retry.attempt.connection) ||
          retry.attempt.connection.grant?.phase != GrantPhase.active) {
        _clearRelayRetry();
      }
    }
    final lost = _attempt;
    if (lost != null && !live.contains(lost.connection)) _retainRecovery(lost);
    for (final connection in _links.keys.toList()) {
      if (!live.contains(connection)) {
        final link = _links.remove(connection);
        if (link != null) {
          _retiredLinks.add(link);
          unawaited(
            _closeLink(link).catchError((Object _) {
              _cleanupProblem();
            }),
          );
        }
      }
    }
    // Each authenticated transport keeps its receiver, even for the same peer.
    for (final connection in live) {
      _linkFor(connection);
    }
    final attempt = _attempt;
    if (attempt != null &&
        !live.contains(attempt.connection) &&
        _recovery?.previous != attempt.connection) {
      unawaited(stop(reason: '连接已断开，远端画面已停止并释放。', failed: true));
    }
    _tryRecoverMedia();
  }

  RemotePictureLink _linkFor(TrustedConnection connection) {
    if (_shuttingDown || _disposed) {
      throw const SessionFailure('operation_stopped');
    }
    final existing = _links[connection];
    if (existing != null) return existing;
    final capable = factory;
    final link = capable is RecoverableRemotePictureFactory
        ? capable.createRecoverable(
            transport: connection,
            budget: budget,
            resolveSource: _resolveLocalSource,
            authorizeRecovery: (authorization, request) =>
                _authorizeRecovery(connection, authorization, request),
            onSession: (session) => _adopt(connection, session),
            onFailure: (id, code) => _onLinkFailure(connection, id, code),
          )
        : factory.create(
            transport: connection,
            budget: budget,
            resolveSource: _resolveLocalSource,
            onSession: (session) => _adopt(connection, session),
            onFailure: (sessionId, code) =>
                _onLinkFailure(connection, sessionId, code),
          );
    _links[connection] = link;
    return link;
  }

  bool _retainRecovery(_Attempt attempt) {
    if (_recovery?.previous == attempt.connection) return true;
    final picture = attempt.picture;
    if (_disposed ||
        _shuttingDown ||
        attempt.cancelled ||
        _stopping ||
        !attempt.connection.canRecover ||
        factory is! RecoverableRemotePictureFactory ||
        picture is! RecoverableRemotePicture ||
        picture.remoteEndReason != null ||
        attempt.changingSource ||
        !{
          RemotePhase.active,
          RemotePhase.paused,
          RemotePhase.waitingFirstFrame,
        }.contains(_phase)) {
      return false;
    }
    final oldStarts = _pendingStarts.toList();
    final released = Completer<void>();
    unawaited(released.future.catchError((Object _) {}));
    late final VideoRecoveryIntent intent;
    try {
      intent = VideoRecoveryIntent(
        previous: picture.authorization,
        revision: picture.mediaRevision,
        paused: _phase == RemotePhase.paused,
        source: picture.sends ? picture.localSource : null,
        released: released.future,
      );
    } catch (_) {
      return false;
    }
    final recovery = _recovery = _MediaRecovery(
      attempt.connection,
      intent,
      attempt.label,
    );
    recovery.deadline = Timer(mediaRecoveryDeadline, () {
      if (identical(_recovery, recovery)) {
        unawaited(stop(reason: '画面恢复超时，已停止；可重新发起。', failed: true));
      }
    });
    recovery.invalidation = attempt.connection.grant!.invalidated.listen((_) {
      if (attempt.connection.grant!.phase == GrantPhase.revoked &&
          identical(_recovery, recovery)) {
        unawaited(stop(reason: '原授权已撤销，画面不再恢复。', failed: true));
      }
    });
    final link = _links.remove(attempt.connection);
    if (link != null) _retiredLinks.add(link);
    unawaited(
      _trackWork(() async {
        try {
          // Register this owner before stop can synchronously notify an exit
          // listener. Never start a clock read after that listener cancels us.
          await Future.wait<void>([
            _stopTracked(),
            if (link != null) _closeLink(link),
            ...oldStarts,
            if (identical(_recovery, recovery) && !_shuttingDown)
              connections.platform.now().then((now) {
                recovery.began = recovery.last = now;
              }),
          ]);
          if (_cleanupFailed ||
              _attempt != null ||
              budget.activeCount != 0 ||
              _unreleasedPictures.isNotEmpty ||
              _unreleasedSubscriptions.isNotEmpty) {
            throw const SessionFailure('media_cleanup_failed');
          }
          if (!released.isCompleted) released.complete();
          if (identical(_recovery, recovery)) _tryRecoverMedia();
        } catch (error, stack) {
          if (!released.isCompleted) released.completeError(error, stack);
          if (identical(_recovery, recovery)) {
            _dropRecovery(recovery);
            _phase = RemotePhase.failed;
            _error = '旧画面资源尚未成功释放，未恢复采集；请重试停止。';
            _notify();
          }
        }
      }),
    );
    if (identical(_recovery, recovery)) {
      _phase = RemotePhase.recovering;
      _error = null;
      _notify();
    }
    return true;
  }

  void _dropRecovery(_MediaRecovery recovery, {bool promoted = false}) {
    if (!identical(_recovery, recovery)) return;
    _recovery = null;
    recovery.deadline?.cancel();
    unawaited(recovery.invalidation?.cancel());
    if (!promoted) recovery.intent.cancel();
  }

  void _requireRecovery(_MediaRecovery recovery, TrustedConnection connection) {
    if (_disposed ||
        _shuttingDown ||
        !identical(_recovery, recovery) ||
        recovery.intent.stopped ||
        connection.isClosed ||
        !connections.sessions.contains(connection) ||
        !identical(connection.grant, recovery.previous.grant) ||
        connection.grant?.phase != GrantPhase.active) {
      throw const SessionFailure('operation_stopped');
    }
  }

  Future<void> _checkRecoveryClock(
    _MediaRecovery recovery,
    TrustedConnection connection,
  ) async {
    _requireRecovery(recovery, connection);
    final now = await connections.platform.now();
    _requireRecovery(recovery, connection);
    if (recovery.began == null ||
        now < recovery.last! ||
        now - recovery.began! >= mediaRecoveryDeadline.inMicroseconds) {
      _dropRecovery(recovery);
      _phase = RemotePhase.failed;
      _error = '已超过画面恢复时限，未重新开始采集。';
      _notify();
      throw const SessionFailure('media_recovery_expired');
    }
    recovery.last = now;
  }

  Future<VideoRecoveryAdmission> _authorizeRecovery(
    TrustedConnection connection,
    SessionAuthorization authorization,
    VideoRecoveryRequest request,
  ) async {
    final recovery = _recovery;
    if (recovery == null) {
      throw const SessionFailure('media_recovery_unavailable');
    }
    _requireRecovery(recovery, connection);
    await recovery.intent.released;
    await _checkRecoveryClock(recovery, connection);
    final admission = await recovery.intent.claim(authorization, request);
    _requireRecovery(recovery, connection);
    recovery.replacementId = authorization.sessionId;
    try {
      if (localCaptureActive?.call() ?? false) {
        throw const SessionFailure('busy');
      }
      if (recovery.intent.source case final source?) {
        if (!(await platform.permissions()).screenRecording) {
          throw const SessionFailure('permission_unavailable');
        }
        _requireRecovery(recovery, connection);
        final sources = await listSources();
        _requireRecovery(recovery, connection);
        final found = sources
            .where((s) => s.id == source.id && s.type == source.type)
            .toList();
        if (found.length != 1 ||
            (source.isPrimary &&
                (!found.single.isPrimary ||
                    sources
                            .where(
                              (s) =>
                                  s.type == CaptureSourceType.screen &&
                                  s.isPrimary,
                            )
                            .length !=
                        1))) {
          throw const SessionFailure('source_unavailable');
        }
      }
      await _checkRecoveryClock(recovery, connection);
      admission.requireCurrent();
      return admission;
    } catch (error) {
      if (identical(_recovery, recovery)) {
        _dropRecovery(recovery);
        _phase = RemotePhase.failed;
        _error = error is SessionFailure && error.code == 'source_unavailable'
            ? '原分享来源已失效或主屏身份已变化，未采集其他来源。'
            : _failureMessage(error);
        _notify();
      }
      rethrow;
    }
  }

  void _tryRecoverMedia() {
    final recovery = _recovery;
    if (recovery == null ||
        recovery.started ||
        recovery.previous.grant?.role != GrantRole.initiator) {
      return;
    }
    final connection = connections.sessions
        .where(
          (c) => !c.isClosed && identical(c.grant, recovery.previous.grant),
        )
        .firstOrNull;
    if (connection == null) return;
    recovery.started = true;
    unawaited(
      _trackWork(() async {
        try {
          await recovery.intent.released;
          await _checkRecoveryClock(recovery, connection);
          await _start(
            recovery.intent.previous.operation,
            peerKey: connection.peerKey,
            label: recovery.label,
            recovery: recovery,
            restoredConnection: connection,
          );
        } catch (failure) {
          if (identical(_recovery, recovery)) {
            await stop(reason: _failureMessage(failure), failed: true);
          }
        }
      }),
    );
  }

  // ------------------------------------------------------------------ routing

  void _adopt(TrustedConnection connection, RemotePicture session) {
    if (_disposed ||
        _shuttingDown ||
        connection.isClosed ||
        !connections.sessions.contains(connection)) {
      unawaited(_silentStop(session));
      return;
    }
    final recovery = _recovery;
    if (session is RecoverableRemotePicture && session.isRecovery) {
      if (recovery == null ||
          recovery.replacementId != session.id ||
          !identical(connection.grant, recovery.previous.grant)) {
        unawaited(_silentStop(session));
        return;
      }
    } else if (recovery != null) {
      unawaited(_silentStop(session, reason: VideoEndReason.busy));
      return;
    }
    if (localCaptureActive?.call() ?? false) {
      // The SDK reports admission before resolving or capturing a source.
      // stop gates this unstarted session synchronously before its next await;
      // an incoming request cannot bypass local preview's occupied budget.
      unawaited(_silentStop(session, reason: VideoEndReason.busy));
      return;
    }
    // A peer-initiated picture supersedes any pending direct-path fallback.
    if (_attempt == null) _clearRelayRetry();
    var attempt = _attempt;
    if (attempt != null &&
        (!identical(attempt.connection, connection) ||
            attempt.sessionId != session.id)) {
      // The single picture budget is already spent on another peer.
      unawaited(_silentStop(session, reason: VideoEndReason.busy));
      return;
    }
    if (attempt == null) {
      // Peer-initiated: own it here so it stays visible and stoppable.
      attempt = _Attempt(++_generation, connection, session.operation)
        ..sessionId = session.id;
      _attempt = attempt;
      _phase = RemotePhase.connecting;
      _error = null;
      _cleanupFailed = false;
    } else if (attempt.cancelled || attempt.picture != null) {
      // One session per operation, and never for a cancelled one.
      if (attempt.cancelled && attempt.picture == null) {
        // SDK admission may throw after this callback, with no returned owner.
        // Retain only the cleanup handle; never subscribe or revive playback.
        attempt.picture = session;
      }
      unawaited(_silentStop(session));
      return;
    }
    if (recovery != null) _dropRecovery(recovery, promoted: true);
    final owned = attempt;
    owned.picture = session;
    owned.events = session.events.listen((event) => _onEvent(owned, event));
    _startPermissionWatch(owned);
    // ICE has its own connection deadline in the SDK. Starting the shorter
    // presentation deadline here would preempt that diagnostic and relay retry.
    _notify();
  }

  void _onLinkFailure(
    TrustedConnection connection,
    String sessionId,
    String code,
  ) {
    if (_disposed || _stopping) return;
    final attempt = _attempt;
    if (attempt == null ||
        !identical(attempt.connection, connection) ||
        attempt.sessionId != sessionId) {
      return;
    }
    if (_retainRecovery(attempt)) return;
    _considerRelayRetry(attempt, code);
    _deadline?.cancel();
    _deadline = null;
    _phase = RemotePhase.failed;
    _clearObservations();
    _error = _eventMessage(code);
    _notify();
  }

  void _onEvent(_Attempt attempt, MediaSessionEvent event) {
    if (_disposed ||
        !identical(_attempt, attempt) ||
        attempt.token != _generation) {
      return;
    }
    if ((event.kind == MediaEventKind.failed ||
            event.kind == MediaEventKind.ended) &&
        _retainRecovery(attempt)) {
      return;
    }
    if (event.mediaRevision < attempt.minimumRevision) return;
    if (event.kind == MediaEventKind.frameProgress ||
        event.kind == MediaEventKind.peerFrameProgress) {
      final peer = event.kind == MediaEventKind.peerFrameProgress;
      final sending = attempt.picture?.sends == true;
      if (event.sessionId != attempt.sessionId ||
          event.mediaRevision != attempt.minimumRevision ||
          attempt.cancelled ||
          _stopping ||
          _phase == RemotePhase.idle ||
          _phase == RemotePhase.paused ||
          _phase == RemotePhase.failed ||
          event.frameProgress?.stage !=
              (sending != peer
                  ? MediaFrameStage.capture
                  : MediaFrameStage.receiver)) {
        return;
      }
      if (peer) {
        _peerFrameDeadline?.cancel();
        _peerFrameProgress = event.frameProgress;
        _peerFrameAge = Stopwatch()..start();
        _peerFrameDeadline = Timer(statisticsLifetime, () {
          if (!_isCurrent(attempt)) return;
          _clearPeerFrame();
          _notify();
        });
        _notify();
        return;
      }
      _frameProgressDeadline?.cancel();
      _frameProgress = event.frameProgress;
      _frameSampleAge = Stopwatch()..start();
      _frameProgressDeadline = Timer(statisticsLifetime, () {
        if (!_isCurrent(attempt)) return;
        _frameProgress = null;
        _frameSampleAge = null;
        _frameProgressDeadline = null;
        _notify();
      });
      _notify();
      return;
    }
    if (event.kind == MediaEventKind.statistics) {
      // A sample cannot advance the media revision or establish readiness.
      if (event.mediaRevision != attempt.minimumRevision ||
          attempt.cancelled ||
          _stopping ||
          _phase == RemotePhase.idle ||
          _phase == RemotePhase.paused ||
          _phase == RemotePhase.failed) {
        return;
      }
      _clearStatistics();
      _statistics = event;
      _statisticsDeadline = Timer(statisticsLifetime, () {
        if (!_isCurrent(attempt)) return;
        _clearStatistics();
        _notify();
      });
      _notify();
      return;
    }
    if (event.mediaRevision > attempt.minimumRevision) {
      _clearObservations();
      attempt.firstFrame = false;
      attempt.transportReady = false;
      attempt.minimumRevision = event.mediaRevision;
    }
    switch (event.kind) {
      case MediaEventKind.connecting:
        _clearObservations();
        _phase = RemotePhase.connecting;
        break;
      case MediaEventKind.transportReady:
        attempt.transportReady = true;
        _armFirstFrameDeadline(attempt);
        break;
      case MediaEventKind.waitingFirstFrame:
        _phase = RemotePhase.waitingFirstFrame;
        if (attempt.transportReady) _armFirstFrameDeadline(attempt);
        break;
      case MediaEventKind.firstFrame:
        attempt.firstFrame = true;
        _deadline?.cancel();
        _deadline = null;
        _phase = RemotePhase.active;
        break;
      case MediaEventKind.paused:
        _clearObservations();
        attempt.firstFrame = false;
        attempt.transportReady = false;
        _deadline?.cancel();
        _deadline = null;
        _phase = RemotePhase.paused;
        break;
      case MediaEventKind.sourceChanged:
        // Selection/negotiation is not a remote presentation receipt.
        break;
      case MediaEventKind.statistics:
      case MediaEventKind.frameProgress:
      case MediaEventKind.peerFrameProgress:
        break;
      case MediaEventKind.ended:
        _remoteEnded(attempt);
        break;
      case MediaEventKind.failed:
        _considerRelayRetry(attempt, event.failureCode);
        _clearObservations();
        _deadline?.cancel();
        _deadline = null;
        _permissionTimer?.cancel();
        _permissionTimer = null;
        _phase = RemotePhase.failed;
        _error = _eventMessage(event.failureCode);
        break;
    }
    _notify();
  }

  void _remoteEnded(_Attempt attempt) {
    _clearObservations();
    _deadline?.cancel();
    _deadline = null;
    _permissionTimer?.cancel();
    _permissionTimer = null;
    final reason = attempt.picture?.remoteEndReason;
    if (reason == null) {
      _error ??= '远端画面已结束。';
      _phase = RemotePhase.idle;
    } else {
      _error = _remoteEndMessage(reason);
      _phase = reason == VideoEndReason.stopped
          ? RemotePhase.idle
          : RemotePhase.failed;
    }
    unawaited(_finishAttempt(attempt));
  }

  Future<void> _finishAttempt(_Attempt attempt) async {
    // Release the budget in the same turn, so no caller ever observes a
    // finished operation still occupying it.
    if (identical(_attempt, attempt)) {
      _attempt = null;
      _sourceChoices = const [];
      _sourceError = null;
      _notify();
    }
    try {
      await _cancelEvents(attempt);
    } catch (_) {
      _clearRelayRetry();
      _cleanupProblem();
      return;
    }
    // SDK emits ended only after native cleanup and budget release. A lease
    // notification may have arrived while subscription cancellation was busy.
    if (identical(_relayRetry?.attempt, attempt)) {
      _relayRetry!.released = true;
      _tryRelayRetry();
    }
  }

  void _clearRelayRetry() {
    _relayRetry?.deadline.cancel();
    _relayRetry = null;
  }

  void _tryRelayRetry() {
    final retry = _relayRetry;
    if (retry == null || !retry.released || !_relayReady()) return;
    // The failed start can still be unwinding after SDK cleanup. Its finally
    // block calls us again once it has released admission ownership.
    if (_busy) return;
    final attempt = retry.attempt;
    if (_disposed ||
        _shuttingDown ||
        _cleanupFailed ||
        _generation != attempt.token ||
        _attempt != null ||
        _recovery != null ||
        !identical(
          connections.outgoingFor(attempt.peerKey),
          attempt.connection,
        ) ||
        attempt.connection.grant?.phase != GrantPhase.active) {
      _clearRelayRetry();
      return;
    }
    _clearRelayRetry();
    // One new operation consumes the fallback. Its ID and Peer are fresh; a
    // second ICE failure cannot recursively create another fallback.
    unawaited(
      _trackWork(
        () => _start(
          attempt.operation,
          peerKey: attempt.peerKey,
          label: attempt.label,
          relayRetry: true,
        ),
      ),
    );
  }

  bool _relayReady() {
    try {
      return relayCredentialAvailable?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  void _considerRelayRetry(_Attempt attempt, String? code) {
    if ((code == 'media_connection_timeout' ||
            code == 'media_transport_lost') &&
        !attempt.transportReady &&
        !attempt.relayAvailableAtStart &&
        !attempt.relayRetried &&
        _recovery == null &&
        (_relayReady() || relayCredentialChanges != null) &&
        _relayRetry == null) {
      final retry = _RelayRetry(attempt);
      retry.deadline = Timer(relayCredentialGrace, () {
        if (identical(_relayRetry, retry)) _clearRelayRetry();
      });
      _relayRetry = retry;
    }
  }

  // ------------------------------------------------------------------ deadline

  void _clearStatistics() {
    _statisticsDeadline?.cancel();
    _statisticsDeadline = null;
    _statistics = null;
  }

  void _clearObservations() {
    _clearPeerFrame();
    _frameProgressDeadline?.cancel();
    _frameProgressDeadline = null;
    _frameProgress = null;
    _frameSampleAge = null;
    _clearStatistics();
  }

  /// Bounded policy: a channel that never presents a frame fails visibly. A
  /// locally produced frame is not evidence that the peer received anything.
  void _armFirstFrameDeadline(
    _Attempt attempt, {
    bool afterSourceChange = false,
  }) {
    if (_disposed ||
        attempt.firstFrame ||
        attempt.cancelled ||
        _phase == RemotePhase.paused ||
        (!attempt.transportReady && !afterSourceChange)) {
      return;
    }
    _deadline?.cancel();
    _deadline = Timer(firstFrameDeadline, () {
      if (_disposed ||
          !identical(_attempt, attempt) ||
          attempt.token != _generation ||
          attempt.firstFrame) {
        return;
      }
      final seconds = firstFrameDeadline.inSeconds;
      unawaited(
        stop(
          reason: attempt.picture?.sends ?? true
              ? '对端在 $seconds 秒内未呈现共享画面，已停止并释放采集。'
              : '未在 $seconds 秒内收到对端画面，已停止。',
          failed: true,
        ),
      );
    });
  }

  void _startPermissionWatch(_Attempt attempt) {
    _permissionTimer ??= Timer.periodic(
      permissionPoll,
      (_) => unawaited(_checkPermission(attempt)),
    );
  }

  Future<void> _checkPermission(_Attempt attempt) async {
    if (_disposed ||
        _checkingPermission ||
        !identical(_attempt, attempt) ||
        attempt.token != _generation ||
        attempt.picture?.sends != true) {
      return;
    }
    _checkingPermission = true;
    try {
      final allowed = (await platform.permissions()).screenRecording;
      if (!allowed &&
          identical(_attempt, attempt) &&
          attempt.token == _generation) {
        await stop(reason: '屏幕录制权限已关闭，已停止共享并通知对端。', failed: true);
      }
    } catch (_) {
      if (identical(_attempt, attempt) && attempt.token == _generation) {
        await stop(reason: '无法检查屏幕录制权限，已停止共享。', failed: true);
      }
    } finally {
      _checkingPermission = false;
    }
  }

  // ------------------------------------------------------------------- source

  /// Explicit user action only: merely opening the app or hovering a node
  /// never enumerates sources. Results belong to the current sharing operation.
  Future<void> loadSourceChoices() async {
    final attempt = _attempt;
    if (attempt == null || !canChangeSource) return;
    attempt.loadingSources = true;
    _sourceError = null;
    _notify();
    try {
      final found = await listSources();
      if (_isCurrent(attempt)) _sourceChoices = List.unmodifiable(found);
    } catch (_) {
      if (_isCurrent(attempt)) _sourceError = '无法读取本机画面来源，请重试。';
    } finally {
      attempt.loadingSources = false;
      _notify();
    }
  }

  bool _isCurrent(_Attempt attempt) =>
      !_disposed &&
      !_shuttingDown &&
      identical(_attempt, attempt) &&
      attempt.token == _generation &&
      !attempt.cancelled;

  Future<void> changeSource(CaptureSource selected) async {
    final attempt = _attempt;
    final picture = attempt?.picture;
    if (attempt == null ||
        picture is! SourceSelectableRemotePicture ||
        !canChangeSource) {
      return;
    }
    var changingRevision = false;
    attempt.changingSource = true;
    _sourceError = null;
    _notify();
    try {
      // A stale picker selection is never replaced by the first/primary item.
      if (!(await platform.permissions()).screenRecording) {
        throw const SessionFailure('permission_unavailable');
      }
      final found = await listSources();
      if (!_isCurrent(attempt)) return;
      final matching = found.where(
        (s) => s.id == selected.id && s.type == selected.type,
      );
      if (matching.length != 1) {
        throw const SessionFailure('source_unavailable');
      }
      _sourceChoices = List.unmodifiable(found);
      attempt.firstFrame = false;
      attempt.transportReady = false;
      attempt.minimumRevision = picture.mediaRevision + 1;
      _clearObservations();
      _deadline?.cancel();
      _phase = RemotePhase.connecting;
      _notify();
      changingRevision = true;
      await picture.changeSource(matching.single);
      if (_isCurrent(attempt) && !attempt.firstFrame) {
        _armFirstFrameDeadline(attempt, afterSourceChange: true);
      }
    } catch (failure) {
      if (_isCurrent(attempt)) {
        _sourceError =
            failure is SessionFailure && failure.code == 'source_unavailable'
            ? '所选来源已不可用，未切换到其他来源。请重新选择。'
            : _failureMessage(failure);
        // Once the old revision was gated, failure must end capture rather than
        // leave an unobservable old source running or silently fall back.
        if (changingRevision ||
            (failure is SessionFailure &&
                failure.code == 'permission_unavailable')) {
          await stop(reason: _sourceError, failed: true);
        }
      }
    } finally {
      attempt.changingSource = false;
      _notify();
    }
  }

  /// Resolves the sharing endpoint's own current primary screen, once per
  /// operation. It never falls back: an unidentifiable or missing primary
  /// screen fails the operation instead of capturing something else.
  Future<CaptureSource> _resolveLocalSource() async {
    if (_disposed || _shuttingDown) {
      throw const SessionFailure('operation_stopped');
    }
    if (!await _hasScreenPermission()) {
      throw const SessionFailure('permission_unavailable');
    }
    if (_disposed || _shuttingDown) {
      throw const SessionFailure('operation_stopped');
    }
    final found = await listSources();
    if (_disposed || _shuttingDown) {
      throw const SessionFailure('operation_stopped');
    }
    final primary = found
        .where(
          (item) => item.type == CaptureSourceType.screen && item.isPrimary,
        )
        .toList();
    if (primary.length != 1) {
      throw const SessionFailure('source_unavailable');
    }
    return primary.single;
  }

  Future<bool> _hasScreenPermission() async =>
      (await platform.permissions()).screenRecording ||
      await platform.requestScreenRecording();

  // ---------------------------------------------------------------- messaging

  void _fail(String message) {
    _error = message;
    _notify();
  }

  String _failureMessage(Object failure) {
    if (failure is SessionFailure) {
      return switch (failure.code) {
        'capability_unavailable' => '本版本没有该远端操作的实现。',
        'direction_denied' => '当前连接方向不允许该操作，需由对端主动发起。',
        'busy' => '已有远端画面会话占用单画面预算，请先结束。',
        'stale_operation' => '该操作已失效，请重新发起。',
        'operation_stopped' => '操作已停止。',
        'expired_or_clock_rollback' => '授权已到期或时钟异常，请重新用短接码连接。',
        'unknown_local_grant' => '本地授权已失效，请重新连接。',
        'permission_unavailable' => '屏幕录制权限不可用，请在系统设置中允许 Share Hub 后重试。',
        'source_unavailable' => '无法确认当前主屏，未开始采集；不会自动切换到其他来源。',
        'media_recovery_unavailable' => '原画面已停止或不再具备恢复条件，请重新发起。',
        'media_recovery_expired' => '画面恢复已超时，已停止。',
        'invalid_media_recovery' => '两端画面状态不一致，未自动恢复。',
        'media_recovery_unconfirmed' => '尚未获得对端恢复确认，未开始采集。',
        'source_required' => '没有可用的画面来源，未开始采集。',
        'stale_media_revision' => '画面代次已变化，本次更新被忽略。',
        _ => '远端画面启动失败（${failure.code}）。',
      };
    }
    if (failure is ConnectionFailure) {
      return '连接不可用，远端画面未能发起。';
    }
    return '远端画面启动失败，请重试。';
  }

  String _eventMessage(String? code) => switch (code) {
    'media_frames_stalled' => '源端持续产生新画面，但接收端未恢复解码，已结束本次画面。可重新发起。',
    'media_connection_timeout' => '媒体通道未在 30 秒内建立，已释放资源。',
    'media_transport_lost' => '媒体通道中断，已停止并释放资源。',
    'source_ended' => '所共享的来源已结束，已停止；不会自动切换到其他来源。',
    'media_cleanup_failed' => '远端画面资源释放失败，请再次停止。',
    'media_signal_backlog' => '对端信令积压，本次操作已拒绝。',
    'media_start_failed' => '远端画面启动失败，请重试。',
    'permission_unavailable' => '屏幕录制权限不可用，未开始采集。',
    'source_unavailable' => '共享来源不可用，未改采其他来源。',
    _ => '远端画面失败（${code ?? '未测'}）。',
  };

  String _remoteEndMessage(VideoEndReason reason) => switch (reason) {
    VideoEndReason.stopped => '对端已结束该远端操作。',
    VideoEndReason.busy => '对端已有画面会话，本次操作未开始（忙碌）。',
    VideoEndReason.unavailable => '对端未提供该远端操作能力，未创建画面会话。',
    VideoEndReason.failed => '对端在启动远端画面时失败。',
  };

  // ---------------------------------------------------------------- plumbing

  Future<void> _cancelEvents(_Attempt? attempt) async {
    final subscription = attempt?.events;
    if (subscription != null) {
      await _cancelSubscription(subscription);
      if (identical(attempt?.events, subscription)) attempt?.events = null;
    }
  }

  /// Rejects an unadopted session without losing its cleanup owner. A failed
  /// release remains reachable by shutdown even when there is no visible view.
  Future<void> _silentStop(
    RemotePicture session, {
    VideoEndReason reason = VideoEndReason.stopped,
  }) async {
    try {
      await _stopPicture(session, reason: reason);
    } catch (_) {
      _cleanupProblem();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

class _Attempt {
  _Attempt(this.token, this.connection, this.operation, {this.label});
  final int token;
  final TrustedConnection connection;
  String get peerKey => connection.peerKey;
  final SessionOperation operation;
  final String? label;
  String sessionId = '';
  RemotePicture? picture;
  StreamSubscription<MediaSessionEvent>? events;
  bool transportReady = false;
  bool firstFrame = false;
  int minimumRevision = 0;
  bool loadingSources = false, changingSource = false;
  bool cancelled = false;
  bool relayAvailableAtStart = false;
  bool relayRetried = false;
}

class _RelayRetry {
  _RelayRetry(this.attempt);
  final _Attempt attempt;
  late final Timer deadline;
  bool released = false;
}

class _MediaRecovery {
  _MediaRecovery(this.previous, this.intent, this.label);
  final TrustedConnection previous;
  final VideoRecoveryIntent intent;
  final String? label;
  Timer? deadline;
  StreamSubscription<void>? invalidation;
  int? began, last;
  bool started = false;
  String? replacementId;
}
