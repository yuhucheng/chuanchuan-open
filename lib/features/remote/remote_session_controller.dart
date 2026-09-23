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
enum RemotePhase { idle, connecting, waitingFirstFrame, active, paused, failed }

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
    this.firstFrameDeadline = const Duration(seconds: 15),
    this.permissionPoll = const Duration(seconds: 2),
  }) : _capabilities = factory.capabilities,
       budget = MediaSessionBudget(
         factory.capabilities,
         grants: connections.grants,
       ) {
    connections.addListener(_reconcile);
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
  final Duration firstFrameDeadline;
  final Duration permissionPoll;

  /// One budget for watch, cast and control-with-video in this process.
  final MediaSessionBudget budget;

  final MediaCapabilities _capabilities;
  // Two devices can hold independently authorized connections in both
  // directions. A peer key is identity, not a transport/receiver owner.
  final _links = <TrustedConnection, RemotePictureLink>{};
  _Attempt? _attempt;
  Timer? _deadline;
  Timer? _permissionTimer;
  int _generation = 0;
  int _sessionCounter = 0;
  bool _disposed = false;
  bool _busy = false;
  bool _stopping = false;
  Future<void>? _stopInFlight;
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
    if (_capabilities.protocolVersion != sessionProtocolVersion) {
      return const {};
    }
    const requiredControlCapabilities = {
      ControlCapability.pointer,
      ControlCapability.wheel,
      ControlCapability.physicalKey,
      ControlCapability.textInput,
      ControlCapability.clipboardText,
    };
    return {
      for (final operation in _capabilities.operations)
        if (operation == SessionOperation.watch ||
            operation == SessionOperation.cast ||
            (operation == SessionOperation.control &&
                factory.controlCapabilities.containsAll(
                  requiredControlCapabilities,
                )))
          operation.name,
    };
  }

  Set<String> operationsFor(String peerKey) =>
      connections.outgoingFor(peerKey) != null ? offeredOperations : const {};

  RemotePicture? get session => _attempt?.picture;
  RemoteControlPicture? get controlSession => switch (session) {
    RemoteControlPicture control when !control.sends => control,
    _ => null,
  };
  RemoteControlInputScope? get controlInputScope => controlSession?.inputScope;
  SessionOperation? get operation => _attempt?.operation;
  String? get peerKey => _attempt?.peerKey;
  String? get peerLabel => _attempt?.label;
  RemotePhase get phase => _phase;
  String? get error => _error;
  bool get busy => _busy;
  bool get cleanupFailed => _cleanupFailed;
  bool get transportReady => _attempt?.transportReady ?? false;
  bool get sending => _attempt?.picture?.sends ?? false;
  bool get receiving => _attempt?.picture?.sends == false;
  int get mediaRevision => _attempt?.picture?.mediaRevision ?? 0;

  /// A live picture occupies the single picture budget for the whole process.
  bool get occupied => _attempt != null;

  Future<bool> sendControlPointerMove(double x, double y) => _sendControlInput(
    (scope, sequence) => ControlPointerMove(
      sequence: sequence,
      inputEpoch: scope.inputEpoch,
      geometryRevision: scope.geometryRevision,
      x: x,
      y: y,
    ),
  );

  Future<bool> sendControlPointerButton(
    double x,
    double y,
    ControlButton button,
    bool down,
  ) => _sendControlInput(
    (scope, sequence) => ControlPointerButton(
      sequence: sequence,
      inputEpoch: scope.inputEpoch,
      geometryRevision: scope.geometryRevision,
      x: x,
      y: y,
      button: button,
      down: down,
    ),
  );

  Future<bool> sendControlWheel(
    double x,
    double y,
    double deltaX,
    double deltaY,
  ) => _sendControlInput(
    (scope, sequence) => ControlWheel(
      sequence: sequence,
      inputEpoch: scope.inputEpoch,
      geometryRevision: scope.geometryRevision,
      x: x,
      y: y,
      deltaX: deltaX,
      deltaY: deltaY,
    ),
  );

  Future<bool> sendControlKey(int usage, ControlKeyAction action) =>
      _sendControlInput(
        (scope, sequence) => ControlKey(
          sequence: sequence,
          inputEpoch: scope.inputEpoch,
          geometryRevision: scope.geometryRevision,
          usage: usage,
          action: action,
        ),
      );

  Future<bool> sendControlText(String text) => _sendControlInput(
    (scope, sequence) => ControlTextInput(
      sequence: sequence,
      inputEpoch: scope.inputEpoch,
      geometryRevision: scope.geometryRevision,
      text: text,
    ),
  );

  Future<bool> _sendControlInput(
    ControlInput Function(RemoteControlInputScope scope, int sequence) build,
  ) async {
    final attempt = _attempt;
    final picture = attempt?.picture;
    if (attempt == null ||
        !_isCurrent(attempt) ||
        _phase != RemotePhase.active ||
        picture is! RemoteControlPicture ||
        picture.sends ||
        picture.inputScope == null) {
      return false;
    }
    final scope = picture.inputScope!;
    final ControlInput input;
    try {
      input = build(scope, attempt.inputSequence + 1);
    } on SessionFailure {
      return false;
    }
    attempt.inputSequence++;
    try {
      await picture.sendInput(input);
      return _isCurrent(attempt);
    } catch (_) {
      final currentScope = picture.inputScope;
      final scopeExpired =
          currentScope == null ||
          currentScope.inputEpoch != scope.inputEpoch ||
          currentScope.geometryRevision != scope.geometryRevision;
      if (_isCurrent(attempt) && !scopeExpired) {
        await stop(reason: '控制输入已失效，当前控制操作已停止。', failed: true);
      }
      return false;
    }
  }

  Future<void> releaseControlInput() async {
    final attempt = _attempt;
    final picture = attempt?.picture;
    if (attempt == null ||
        !_isCurrent(attempt) ||
        picture is! RemoteControlPicture ||
        picture.sends ||
        picture.inputScope == null) {
      return;
    }
    try {
      await picture.releaseInput();
    } catch (_) {
      if (_isCurrent(attempt)) {
        await stop(reason: '无法释放控制输入，当前控制操作已停止。', failed: true);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _deadline?.cancel();
    _permissionTimer?.cancel();
    final attempt = _attempt;
    _attempt = null;
    unawaited(() async {
      await _cancelEvents(attempt);
      final picture = attempt?.picture;
      if (picture != null) await _silentStop(picture);
    }());
    for (final link in _links.values.toList()) {
      unawaited(link.close().catchError((Object _) {}));
    }
    _links.clear();
    connections.removeListener(_reconcile);
    super.dispose();
  }

  // ------------------------------------------------------------------ starting

  /// Starts an offered operation towards an already verified peer. A peer that is not
  /// connected yet is refused here: the caller runs the short-code flow first
  /// and only then asks for the operation.
  Future<void> start(
    SessionOperation operation, {
    required String peerKey,
    String? label,
  }) async {
    if (_disposed || _busy) return;
    if (operation != SessionOperation.watch &&
        operation != SessionOperation.cast &&
        operation != SessionOperation.control) {
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
    final connection = connections.outgoingFor(peerKey);
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
      ..sessionId = 'remote-${++_sessionCounter}';
    _attempt = attempt;
    _busy = true;
    _cleanupFailed = false;
    _error = null;
    _phase = RemotePhase.connecting;
    _notify();
    try {
      final link = _linkFor(connection);
      final started = operation == SessionOperation.control
          ? await link.startControl(
              attempt.sessionId,
              ControlStart(factory.controlCapabilities),
            )
          : await link.start(operation, attempt.sessionId);
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
      if (!attempt.firstFrame) _armFirstFrameDeadline(attempt);
    } catch (failure) {
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
        await stop(reason: _error, failed: _phase == RemotePhase.failed);
      }
      _notify();
    }
  }

  /// Cancels an in-flight start. On an established session use [stop]: it ends
  /// the operation, notifies the peer and releases the resources.
  Future<void> cancel() => stop(reason: '已取消远端画面，未建立远端画面。');

  Future<void> pause() async {
    if (_attempt?.operation == SessionOperation.control) return;
    final picture = _attempt?.picture;
    if (_disposed || picture == null || sourceBusy) return;
    try {
      await picture.pause();
    } catch (failure) {
      _phase = RemotePhase.failed;
      _error = _failureMessage(failure);
      _notify();
    }
  }

  Future<void> resume() async {
    if (_attempt?.operation == SessionOperation.control) return;
    final attempt = _attempt;
    final picture = attempt?.picture;
    if (_disposed || attempt == null || picture == null || sourceBusy) return;
    try {
      attempt.firstFrame = false;
      attempt.transportReady = false;
      attempt.minimumRevision = picture.mediaRevision + 1;
      _phase = RemotePhase.connecting;
      _notify();
      await picture.resume();
      if (!_disposed && identical(_attempt, attempt)) {
        _armFirstFrameDeadline(attempt);
      }
    } catch (failure) {
      _phase = RemotePhase.failed;
      _error = _failureMessage(failure);
      _notify();
    }
  }

  /// Stops the current picture and releases its resources. A failed release
  /// stays visible and the same session can be stopped again.
  Future<void> stop({String? reason, bool failed = false}) {
    if (_disposed || _attempt == null) return Future<void>.value();
    return _stopInFlight ??= _stopNow(
      reason: reason,
      failed: failed,
    ).whenComplete(() => _stopInFlight = null);
  }

  Future<void> _stopNow({String? reason, bool failed = false}) async {
    final attempt = _attempt;
    if (attempt == null) return;
    _stopping = true;
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
    final pendingAdmission = attempt.picture == null && _busy;
    _phase = failed ? RemotePhase.failed : RemotePhase.idle;
    _error = reason;
    _notify();
    await _cancelEvents(attempt);
    try {
      await attempt.picture?.stop();
      _cleanupFailed = false;
      if (!pendingAdmission && identical(_attempt, attempt)) _attempt = null;
      _phase = failed ? RemotePhase.failed : RemotePhase.idle;
      _error = reason;
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
    if (_disposed) return;
    final live = connections.sessions.where((c) => !c.isClosed).toSet();
    for (final connection in _links.keys.toList()) {
      if (!live.contains(connection)) {
        final link = _links.remove(connection);
        if (link != null) unawaited(link.close().catchError((Object _) {}));
      }
    }
    // Each authenticated transport keeps its receiver, even for the same peer.
    for (final connection in live) {
      _linkFor(connection);
    }
    final attempt = _attempt;
    if (attempt != null && !live.contains(attempt.connection)) {
      unawaited(stop(reason: '连接已断开，远端画面已停止并释放。', failed: true));
    }
  }

  RemotePictureLink _linkFor(TrustedConnection connection) {
    final existing = _links[connection];
    if (existing != null) return existing;
    final link = factory.create(
      transport: connection.operationTransport({
        SessionOperation.watch,
        SessionOperation.cast,
        if (offeredOperations.contains(SessionOperation.control.name))
          SessionOperation.control,
      }),
      budget: budget,
      resolveSource: _resolveLocalSource,
      onSession: (session) => _adopt(connection, session),
      onFailure: (sessionId, code) =>
          _onLinkFailure(connection, sessionId, code),
    );
    _links[connection] = link;
    return link;
  }

  // ------------------------------------------------------------------ routing

  void _adopt(TrustedConnection connection, RemotePicture session) {
    if (_disposed ||
        connection.isClosed ||
        !connections.sessions.contains(connection)) {
      unawaited(_silentStop(session));
      return;
    }
    if (localCaptureActive?.call() ?? false) {
      // The SDK reports admission before resolving or capturing a source.
      // stop gates this unstarted session synchronously before its next await;
      // an incoming request cannot bypass local preview's occupied budget.
      unawaited(_silentStop(session, reason: VideoEndReason.busy));
      return;
    }
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
      _notify();
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
    final owned = attempt;
    owned.picture = session;
    owned.events = session.events.listen((event) => _onEvent(owned, event));
    if (session is RemoteControlPicture) {
      owned.inputListener = () {
        if (_isCurrent(owned)) _notify();
      };
      session.inputChanges.addListener(owned.inputListener!);
    }
    _startPermissionWatch(owned);
    _armFirstFrameDeadline(owned);
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
    _deadline?.cancel();
    _deadline = null;
    _phase = RemotePhase.failed;
    _error = _eventMessage(code);
    _notify();
  }

  void _onEvent(_Attempt attempt, MediaSessionEvent event) {
    if (_disposed ||
        !identical(_attempt, attempt) ||
        attempt.token != _generation) {
      return;
    }
    if (event.mediaRevision < attempt.minimumRevision) return;
    if (event.mediaRevision > attempt.minimumRevision) {
      attempt.firstFrame = false;
      attempt.transportReady = false;
      attempt.minimumRevision = event.mediaRevision;
    }
    switch (event.kind) {
      case MediaEventKind.connecting:
        _phase = RemotePhase.connecting;
        break;
      case MediaEventKind.transportReady:
        attempt.transportReady = true;
        break;
      case MediaEventKind.waitingFirstFrame:
        _phase = RemotePhase.waitingFirstFrame;
        _armFirstFrameDeadline(attempt);
        break;
      case MediaEventKind.firstFrame:
        attempt.firstFrame = true;
        _deadline?.cancel();
        _deadline = null;
        _phase = RemotePhase.active;
        break;
      case MediaEventKind.paused:
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
        break;
      case MediaEventKind.ended:
        _remoteEnded(attempt);
        break;
      case MediaEventKind.failed:
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
    await _cancelEvents(attempt);
  }

  // ------------------------------------------------------------------ deadline

  /// Bounded policy: a channel that never presents a frame fails visibly. A
  /// locally produced frame is not evidence that the peer received anything.
  void _armFirstFrameDeadline(_Attempt attempt) {
    if (_disposed || attempt.firstFrame || attempt.cancelled) return;
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
      _deadline?.cancel();
      _phase = RemotePhase.connecting;
      _notify();
      changingRevision = true;
      await picture.changeSource(matching.single);
      if (_isCurrent(attempt) && !attempt.firstFrame) {
        _armFirstFrameDeadline(attempt);
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
    if (!await _hasScreenPermission()) {
      throw const SessionFailure('permission_unavailable');
    }
    final found = await listSources();
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
    final picture = attempt?.picture;
    if (picture is RemoteControlPicture && attempt?.inputListener != null) {
      picture.inputChanges.removeListener(attempt!.inputListener!);
      attempt.inputListener = null;
    }
    final subscription = attempt?.events;
    attempt?.events = null;
    if (subscription != null) await subscription.cancel();
  }

  /// Stops a session nothing in the field owns. The operation is already
  /// isolated, so a failure here cannot be retried and is not surfaced.
  Future<void> _silentStop(
    RemotePicture session, {
    VideoEndReason reason = VideoEndReason.stopped,
  }) async {
    try {
      await session.stop(reason: reason);
    } catch (_) {
      /* Nobody owns this session any more. */
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
  VoidCallback? inputListener;
  int inputSequence = 0;
  bool transportReady = false;
  bool firstFrame = false;
  int minimumRevision = 0;
  bool loadingSources = false, changingSource = false;
  bool cancelled = false;
}
