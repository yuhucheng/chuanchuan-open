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

  /// One budget for watch, cast and (later) control-with-video in this process.
  final MediaSessionBudget budget;

  final MediaCapabilities _capabilities;
  final _links = <String, RemotePictureLink>{};
  final _linkGenerations = <String, String>{};
  _Attempt? _attempt;
  Timer? _deadline;
  Timer? _permissionTimer;
  int _generation = 0;
  int _sessionCounter = 0;
  bool _disposed = false;
  bool _busy = false;
  bool _stopping = false;
  bool _checkingPermission = false;
  RemotePhase _phase = RemotePhase.idle;
  String? _error;
  bool _cleanupFailed = false;

  /// Operations this build can offer. The peer's own support is confirmed by
  /// the session; a refusal is shown as a refusal, never as success.
  Set<String> get offeredOperations {
    if (_capabilities.protocolVersion != sessionProtocolVersion) {
      return const {};
    }
    return {
      for (final operation in _capabilities.operations)
        if (operation == SessionOperation.watch ||
            operation == SessionOperation.cast)
          operation.name,
    };
  }

  RemotePicture? get session => _attempt?.picture;
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
    _linkGenerations.clear();
    connections.removeListener(_reconcile);
    super.dispose();
  }

  // ------------------------------------------------------------------ starting

  /// Starts a watch or cast towards an already verified peer. A peer that is not
  /// connected yet is refused here: the caller runs the short-code flow first
  /// and only then asks for the operation.
  Future<void> start(
    SessionOperation operation, {
    required String peerKey,
    String? label,
  }) async {
    if (_disposed || _busy) return;
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
    final connection = _liveConnection(peerKey);
    if (connection == null) {
      _fail('该设备尚未完成身份验证；请先输入 6 位短接码连接。');
      return;
    }
    final token = ++_generation;
    final attempt = _Attempt(token, peerKey, operation, label: label)
      ..sessionId = 'remote-${++_sessionCounter}';
    _attempt = attempt;
    _busy = true;
    _cleanupFailed = false;
    _error = null;
    _phase = RemotePhase.connecting;
    _notify();
    try {
      final started = await _linkFor(
        connection,
      ).start(operation, attempt.sessionId);
      if (_disposed || attempt.cancelled || token != _generation) {
        // A cancelled or superseded start must not leave a live session behind.
        await _silentStop(started);
        return;
      }
      attempt.picture ??= started;
      if (attempt.picture!.stopped) {
        await _finishAttempt(attempt);
        return;
      }
      if (!attempt.firstFrame) _armFirstFrameDeadline(attempt);
    } catch (failure) {
      if (!_disposed && token == _generation) {
        _phase = RemotePhase.failed;
        _error = _failureMessage(failure);
      }
      // A refused start owns nothing, so it must not keep the picture budget.
      attempt.cancelled = true;
    } finally {
      _busy = false;
      if (attempt.cancelled && identical(_attempt, attempt)) {
        await _cancelEvents(attempt);
        final picture = attempt.picture;
        if (picture != null) await _silentStop(picture);
        _attempt = null;
        if (_phase != RemotePhase.failed) _phase = RemotePhase.idle;
      }
      _notify();
    }
  }

  /// Cancels an in-flight start. On an established session use [stop]: it ends
  /// the operation, notifies the peer and releases the resources.
  Future<void> cancel() => stop(reason: '已取消远端画面，未建立远端画面。');

  Future<void> pause() async {
    final picture = _attempt?.picture;
    if (_disposed || picture == null) return;
    try {
      await picture.pause();
    } catch (failure) {
      _phase = RemotePhase.failed;
      _error = _failureMessage(failure);
      _notify();
    }
  }

  Future<void> resume() async {
    final attempt = _attempt;
    final picture = attempt?.picture;
    if (_disposed || attempt == null || picture == null) return;
    try {
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
  Future<void> stop({String? reason, bool failed = false}) async {
    final attempt = _attempt;
    if (_disposed || attempt == null || _stopping) return;
    _stopping = true;
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
    final live = <String, TrustedConnection>{};
    for (final connection in connections.sessions) {
      if (!connection.isClosed) live[connection.peerKey] = connection;
    }
    for (final key in _links.keys.toList()) {
      final connection = live[key];
      if (connection == null ||
          _linkGenerations[key] != connection.sessionId) {
        final link = _links.remove(key);
        _linkGenerations.remove(key);
        if (link != null) unawaited(link.close().catchError((Object _) {}));
      }
    }
    // Every live connection owns a receiver, so a peer-initiated operation is
    // routed and visible instead of being dropped by the transport.
    for (final connection in live.values) {
      _linkFor(connection);
    }
    final attempt = _attempt;
    if (attempt != null && !live.containsKey(attempt.peerKey)) {
      unawaited(stop(reason: '连接已断开，远端画面已停止并释放。', failed: true));
    }
  }

  TrustedConnection? _liveConnection(String peerKey) {
    for (final connection in connections.sessions) {
      if (!connection.isClosed && connection.peerKey == peerKey) {
        return connection;
      }
    }
    return null;
  }

  RemotePictureLink _linkFor(TrustedConnection connection) {
    final key = connection.peerKey;
    final existing = _links[key];
    if (existing != null && _linkGenerations[key] == connection.sessionId) {
      return existing;
    }
    final link = factory.create(
      transport: connection,
      budget: budget,
      resolveSource: _resolveLocalSource,
      onSession: (session) => _adopt(key, session),
      onFailure: (sessionId, code) => _onLinkFailure(key, sessionId, code),
    );
    _links[key] = link;
    _linkGenerations[key] = connection.sessionId;
    return link;
  }

  // ------------------------------------------------------------------ routing

  void _adopt(String peerKey, RemotePicture session) {
    if (_disposed) {
      unawaited(_silentStop(session));
      return;
    }
    var attempt = _attempt;
    if (attempt != null && attempt.peerKey != peerKey) {
      // The single picture budget is already spent on another peer.
      unawaited(_silentStop(session));
      return;
    }
    if (attempt == null) {
      // Peer-initiated: own it here so it stays visible and stoppable.
      attempt = _Attempt(++_generation, peerKey, session.operation)
        ..sessionId = session.id;
      _attempt = attempt;
      _phase = RemotePhase.connecting;
      _error = null;
      _cleanupFailed = false;
      _notify();
    } else if (attempt.cancelled || attempt.picture != null) {
      // One session per operation, and never for a cancelled one.
      unawaited(_silentStop(session));
      return;
    }
    final owned = attempt;
    owned.picture = session;
    owned.events = session.events.listen((event) => _onEvent(owned, event));
    _startPermissionWatch(owned);
    _armFirstFrameDeadline(owned);
    _notify();
  }

  void _onLinkFailure(String peerKey, String sessionId, String code) {
    if (_disposed || _stopping) return;
    final attempt = _attempt;
    if (attempt == null || attempt.peerKey != peerKey) return;
    final picture = attempt.picture;
    if (picture != null && picture.id != sessionId) return;
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
        _deadline?.cancel();
        _deadline = null;
        _phase = RemotePhase.paused;
        break;
      case MediaEventKind.sourceChanged:
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
    'source_unavailable' => '无法确认当前主屏，未开始采集。',
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
    attempt?.events = null;
    if (subscription != null) await subscription.cancel();
  }

  /// Stops a session nothing in the field owns. The operation is already
  /// isolated, so a failure here cannot be retried and is not surfaced.
  Future<void> _silentStop(RemotePicture session) async {
    try {
      await session.stop();
    } catch (_) {
      /* Nobody owns this session any more. */
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

class _Attempt {
  _Attempt(this.token, this.peerKey, this.operation, {this.label});
  final int token;
  final String peerKey;
  final SessionOperation operation;
  final String? label;
  String sessionId = '';
  RemotePicture? picture;
  StreamSubscription<MediaSessionEvent>? events;
  bool transportReady = false;
  bool firstFrame = false;
  bool cancelled = false;
}
