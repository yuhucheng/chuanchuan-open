import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import 'connection_recovery.dart';
import 'auxiliary_route_controller.dart';
import 'grant_duration.dart';

/// Identity, a continuous clock and the discovery advertisement come from the
/// platform channel. macOS and Windows implement the same channel, so this is
/// not a per-platform implementation in the product sense.
abstract interface class ConnectionPlatform {
  Future<DeviceIdentity> identity();
  Future<int> now();
  Future<String?> advertise(int? port, String? key);
}

class MethodChannelConnectionPlatform implements ConnectionPlatform {
  static const _channel = MethodChannel('dev.sharehub.client/platform');
  @override
  Future<DeviceIdentity> identity() async {
    final seed = await _channel.invokeMethod<Uint8List>('connection.identity');
    if (seed == null) throw const ConnectionFailure('identity_unavailable');
    return DeviceIdentity.fromSeed(seed);
  }

  @override
  Future<int> now() async {
    final value = await _channel.invokeMethod<int>('connection.clock');
    if (value == null) throw const ConnectionFailure('clock_unavailable');
    return value;
  }

  @override
  Future<String?> advertise(int? port, String? key) => _channel
      .invokeMethod<String>('connection.advertise', {'port': port, 'key': key});
}

/// Status text belongs in the connection context; only problems enter the
/// global issue queue. Keeping the kind beside the message avoids interpreting
/// translated user-facing text as application state.
enum ConnectionNoticeKind { status, problem }

/// The displayed code is immediately usable on the local TCP listener. WAN
/// use starts only after the selected service confirms its short-lived entry.
enum MeetingPublication { none, localOnly, publishing, ready, retrying, failed }

class ConnectionNotice {
  const ConnectionNotice.status(this.message)
    : kind = ConnectionNoticeKind.status;
  const ConnectionNotice.problem(this.message)
    : kind = ConnectionNoticeKind.problem;
  final String message;
  final ConnectionNoticeKind kind;
}

class ConnectionController extends ChangeNotifier {
  ConnectionController(
    this.platform, {
    this.recoveryWindow = const Duration(seconds: 30),
    this.recoveryBackoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    this.recoveryAttemptTimeout = const Duration(seconds: 5),
    this.auxiliaryRoutes,
    this.meetingRetryBackoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
    ],
  });
  final ConnectionPlatform platform;
  final Duration recoveryWindow, recoveryAttemptTimeout;
  final List<Duration> recoveryBackoff;
  final AuxiliaryRouteController? auxiliaryRoutes;
  final List<Duration> meetingRetryBackoff;
  final _recoveries = <GrantEndpoint, ConnectionRecovery>{};
  final _routes = <GrantEndpoint, RecoveryRoute>{};
  final _alternateRoutes = <GrantEndpoint, RecoveryRoute>{};
  final _pendingRecoveries = <Future<void>>{};
  final _transportClosures = <Future<void>>{};
  int get recoveringCount => _recoveries.length;
  List<TrustedConnection> get recoveringConnections =>
      _recoveries.values.map((r) => r.previous).toList(growable: false);

  /// Process-local authority shared with SDK resource owners. Only completed
  /// authenticated connections may register grants; never restore from storage.
  final GrantRegistry grants = GrantRegistry();
  DeviceIdentity? _identity;
  PairingHost? _host;
  PairingAttempt? _attempt;
  MeetingRoute? _meetingRoute;
  AuxiliaryCancellation? _meetingCancellation;
  AuxiliaryCancellation? _meetingJoinCancellation;
  int? _observedRouteRevision;
  Timer? _timer;
  bool _disposed = false;
  bool _disconnecting = false;
  bool _shutdownRequested = false;
  final _pendingStarts = <Future<dynamic>>{};
  Future<void>? _disconnectPending;
  Future<void>? _shutdownPending;
  int _generation = 0;
  bool busy = false;
  bool _connecting = false;
  bool get connecting => _connecting;
  String? code;
  String? address;
  MeetingPublication meetingPublication = MeetingPublication.none;
  ConnectionNotice? _notice;
  ConnectionNotice? get notice => _notice;
  String? get message => notice?.message;
  String? get problem =>
      notice?.kind == ConnectionNoticeKind.problem ? notice?.message : null;
  String? _lastConnectionFailureCode;

  /// A typed result for choosing a transport fallback, never UI text parsing.
  String? get lastConnectionFailureCode => _lastConnectionFailureCode;
  final List<TrustedConnection> _sessions = [];
  List<TrustedConnection> get sessions => List.unmodifiable(_sessions);
  bool get accepting => _host?.port != null;

  /// Presentation/routing hint only. SDK still verifies the exact grant and
  /// its authoritative clock before starting an operation.
  TrustedConnection? outgoingFor(String peerKey) {
    for (final connection in _sessions.reversed) {
      if (!connection.isClosed &&
          connection.peerKey == peerKey &&
          connection.grant?.role == GrantRole.initiator &&
          connection.grant?.phase == GrantPhase.active) {
        return connection;
      }
    }
    return null;
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<DeviceIdentity> _loadIdentity() async =>
      _identity ??= await platform.identity();

  Future<void> open() =>
      _shutdownRequested ? Future<void>.value() : _startTracked<void>(_open);

  Future<T> _startTracked<T>(Future<T> Function() action) {
    final completion = Completer<T>();
    // Register before the action can notify listeners: a listener may request
    // process shutdown synchronously from its first busy notification.
    _pendingStarts.add(completion.future);
    completion.complete(
      Future<T>.sync(action).whenComplete(() {
        _pendingStarts.remove(completion.future);
      }),
    );
    return completion.future;
  }

  Future<void> _open() async {
    if (busy || _disposed || _disconnecting || _shutdownRequested) return;
    if (_sessions.length + _recoveries.length >= 8) {
      _notice = const ConnectionNotice.problem('连接数量已达上限，请先断开一个连接。');
      _emit();
      return;
    }
    final generation = ++_generation;
    PairingHost? opening = _host;
    // Refresh must invalidate the old displayed code before identity,
    // advertisement or meeting cleanup can await a slow platform/service call.
    _host?.revokeOffer();
    _meetingCancellation?.cancel();
    busy = true;
    _notice = null;
    code = null;
    address = null;
    meetingPublication = MeetingPublication.none;
    _emit();
    try {
      final identity = await _loadIdentity();
      if (_disposed || _shutdownRequested || generation != _generation) return;
      await _clearAdvertisement();
      if (_disposed || _shutdownRequested || generation != _generation) return;
      final existing = _host;
      _meetingCancellation?.cancel();
      _meetingCancellation = null;
      final oldMeeting = _meetingRoute;
      _meetingRoute = null;
      await oldMeeting?.closeAdmission();
      final host = opening = existing?.port != null
          ? existing!
          : PairingHost(
              identity: identity,
              clock: platform.now,
              protocolVersion: 2,
              enableRecovery: true,
              onConnection: (connection) {
                if (_disposed ||
                    _disconnecting ||
                    _shutdownRequested ||
                    !accepting) {
                  _close(connection, 'admission_rejected');
                  return;
                }
                if (connection.grant!.generation > 1) {
                  unawaited(
                    _startTracked<void>(() => _acceptRecovered(connection)),
                  );
                  return;
                }
                if (!_track(connection)) return;
                code = null;
                meetingPublication = MeetingPublication.none;
                final meeting = _meetingRoute;
                if (meeting != null) unawaited(meeting.closeAdmission());
                _notice = ConnectionNotice.status(
                  '连接已建立，短接码已消费。${formatGrantPolicy(connection.grant!)}，可随时断开。',
                );
                unawaited(_clearAdvertisement());
                _emit();
              },
            );
      _host = host;
      if (host.port != null) {
        await host.refreshOffer();
      } else {
        await host.open();
      }
      if (_disposed || _shutdownRequested || generation != _generation) {
        await host.stopAccepting();
        if (identical(_host, host)) await _clearAdvertisement();
        return;
      }
      // Local discovery is independent of the selected first-pairing meeting.
      // A missing mDNS permission must not prevent a code-only WAN connection.
      String? hostname;
      var discoveryFailed = false;
      try {
        hostname = await platform.advertise(host.port, identity.encodedKey);
      } catch (_) {
        discoveryFailed = true;
      }
      if (_disposed || _shutdownRequested || generation != _generation) {
        await host.stopAccepting();
        if (identical(_host, host)) await _clearAdvertisement();
        return;
      }
      code = host.offer!.code;
      address = hostname == null ? null : '$hostname:${host.port}';
      meetingPublication = auxiliaryRoutes == null
          ? MeetingPublication.localOnly
          : MeetingPublication.publishing;
      if (discoveryFailed) {
        _notice = ConnectionNotice.problem(
          auxiliaryRoutes == null
              ? '局域网自动发现不可用，请检查本地网络权限。'
              : '局域网自动发现不可用；短接码仍可尝试通过所选辅助服务会合。',
        );
      }
      if (auxiliaryRoutes != null) {
        unawaited(
          _startTracked<void>(() => _publishMeeting(host, host.offer!)),
        );
      }
      _timer ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_tick()),
      );
    } catch (_) {
      await opening?.stopAccepting();
      if (generation == _generation) await _clearAdvertisement();
      if (!_disposed && generation == _generation) {
        meetingPublication = MeetingPublication.none;
        _notice = const ConnectionNotice.problem('接入启动失败，请检查钥匙串及本地网络权限。');
      }
    } finally {
      if (generation == _generation) busy = false;
      _emit();
    }
  }

  Future<void> _publishMeeting(PairingHost host, PairingOffer offer) async {
    final routes = auxiliaryRoutes!;
    final cancellation = _meetingCancellation = AuxiliaryCancellation();
    var selectionRevision = -1;
    void cancelOnOriginChange() {
      if (routes.selectionRevision != selectionRevision) cancellation.cancel();
    }

    try {
      await routes.ensureLoaded();
      if (_observedRouteRevision == null) {
        _observedRouteRevision = routes.selectionRevision;
        routes.addListener(_onAuxiliaryRouteChanged);
      }
      selectionRevision = routes.selectionRevision;
      routes.addListener(cancelOnOriginChange);
      var retry = 0;
      var hadFailure = false;
      while (routes.selectionRevision == selectionRevision &&
          await _meetingOfferValid(host, offer, cancellation)) {
        MeetingRoute? route;
        final attemptCancellation = AuxiliaryCancellation();
        void cancelAttempt() => attemptCancellation.cancel();
        cancellation.onCancel(cancelAttempt);
        try {
          route = await routes.openMeetingHost(host, attemptCancellation);
          if (routes.selectionRevision != selectionRevision ||
              !await _meetingOfferValid(host, offer, cancellation)) {
            await route.closeAdmission();
            return;
          }
          _meetingRoute = route;
          meetingPublication = MeetingPublication.ready;
          if (hadFailure) {
            _notice = const ConnectionNotice.status(
              '所选辅助服务会合入口已恢复，当前短接码可用于跨网连接。',
            );
          }
          _emit();
          await route.serve();
          if (!route.activated && identical(_meetingRoute, route)) {
            _meetingRoute = null;
          }
          return;
        } catch (error) {
          // A listing that was already published can disappear when the
          // selected service restarts. Re-publish the same still-valid offer;
          // an initial code collision must remain a visible failure.
          final lostPublishedListing =
              route != null &&
              error is AuxiliaryFailure &&
              error.code == 'entry_unavailable';
          if (route != null && !route.activated) {
            if (identical(_meetingRoute, route)) _meetingRoute = null;
            try {
              await route.closeAdmission();
            } catch (_) {
              // A lost unpublish is bounded by service expiry. Re-publishing
              // this exact offer is idempotent at the selected service.
            }
          }
          if (!await _meetingOfferValid(host, offer, cancellation) ||
              routes.selectionRevision != selectionRevision) {
            return;
          }
          final retryable =
              (lostPublishedListing ||
                  (error is AuxiliaryFailure &&
                      const {
                        'unreachable',
                        'timeout',
                        'server_error',
                      }.contains(error.code))) &&
              meetingRetryBackoff.isNotEmpty;
          meetingPublication = retryable
              ? MeetingPublication.retrying
              : MeetingPublication.failed;
          _notice = ConnectionNotice.problem(
            retryable
                ? '本地接入已开启，但所选辅助服务暂不可用；当前短接码仍有效，正在重试跨网会合。'
                : '本地接入已开启，但所选辅助服务会合失败；请检查服务或重新生成短接码。',
          );
          _emit();
          if (!retryable) return;
          hadFailure = true;
          final delay =
              meetingRetryBackoff[retry < meetingRetryBackoff.length
                  ? retry
                  : meetingRetryBackoff.length - 1];
          retry++;
          await _waitMeetingRetry(cancellation, delay);
        } finally {
          cancellation.removeOnCancel(cancelAttempt);
        }
      }
    } finally {
      routes.removeListener(cancelOnOriginChange);
      if (identical(_meetingCancellation, cancellation)) {
        _meetingCancellation = null;
      }
    }
  }

  void _onAuxiliaryRouteChanged() {
    final routes = auxiliaryRoutes;
    if (routes == null || _observedRouteRevision == routes.selectionRevision) {
      return;
    }
    _observedRouteRevision = routes.selectionRevision;
    _meetingCancellation?.cancel();
    if (_disposed ||
        _shutdownRequested ||
        _disconnecting ||
        routes.stopped ||
        busy ||
        !accepting ||
        code == null) {
      return;
    }
    // _open synchronously revokes the displayed offer before its first await.
    // A new code is published only after old admission cleanup finishes.
    unawaited(open());
  }

  Future<bool> _meetingOfferValid(
    PairingHost host,
    PairingOffer offer,
    AuxiliaryCancellation cancellation,
  ) async {
    if (_disposed ||
        _shutdownRequested ||
        cancellation.isCancelled ||
        !identical(_host, host) ||
        !identical(host.offer, offer) ||
        code != offer.code) {
      return false;
    }
    try {
      return offer.reservable(await platform.now());
    } catch (_) {
      return false;
    }
  }

  Future<void> _waitMeetingRetry(
    AuxiliaryCancellation cancellation,
    Duration delay,
  ) async {
    final ready = Completer<void>();
    void complete() {
      if (!ready.isCompleted) ready.complete();
    }

    cancellation.onCancel(complete);
    final timer = Timer(delay, complete);
    try {
      await ready.future;
    } finally {
      timer.cancel();
      cancellation.removeOnCancel(complete);
    }
  }

  bool _ticking = false;
  Future<void> _tick() async {
    if (_disposed || _shutdownRequested || _ticking) return;
    _ticking = true;
    try {
      final offer = _host?.offer;
      final now = await platform.now();
      if (_disposed || _shutdownRequested || !identical(offer, _host?.offer)) {
        return;
      }
      if (code != null && (offer == null || !offer.reservable(now))) {
        code = null;
        meetingPublication = MeetingPublication.none;
        _notice = const ConnectionNotice.problem('短接码已失效或尝试次数已用完，请重新生成。');
        _meetingCancellation?.cancel();
        final meeting = _meetingRoute;
        _meetingRoute = null;
        await meeting?.closeAdmission();
        await _clearAdvertisement();
      }
      _emit();
    } catch (_) {
      _cancelRecoveries();
      for (final session in _sessions.toList()) {
        _close(session, 'clock_unavailable');
      }
      await stopAccepting();
    } finally {
      _ticking = false;
    }
  }

  Future<void> _clearAdvertisement() async {
    try {
      await platform.advertise(null, null);
    } catch (_) {
      /* Listener still enforces closed offers. */
    }
  }

  Future<void> stopAccepting() async {
    final generation = ++_generation;
    busy = false;
    _connecting = false;
    _attempt?.cancel();
    _attempt = null;
    _meetingCancellation?.cancel();
    _meetingCancellation = null;
    _meetingJoinCancellation?.cancel();
    _meetingJoinCancellation = null;
    final meeting = _meetingRoute;
    _meetingRoute = null;
    code = null;
    address = null;
    meetingPublication = MeetingPublication.none;
    // stopAccepting revokes the local offer and closes pending sockets before
    // its Future yields. Do not wait for HTTPS unpublish while old TCP remains
    // eligible to finish a pairing.
    final hostClosing = _host?.stopAccepting() ?? Future<void>.value();
    final meetingClosing = meeting?.closeAdmission() ?? Future<void>.value();
    try {
      await Future.wait([hostClosing, meetingClosing]);
    } finally {
      // A failed remote leave must not retain a stale discovery advertisement.
      // Both local admission paths were already invalidated synchronously.
      if (generation == _generation && _host != null) {
        await _clearAdvertisement();
      }
      _emit();
    }
  }

  /// Admission and in-flight handshakes are invalidated before awaiting I/O.
  Future<void> disconnectAll() {
    if (_disconnectPending case final pending?) return pending;
    final completion = Completer<void>();
    _disconnectPending = completion.future;
    _disconnecting = true;
    grants.revokeAll();
    _cancelRecoveries();
    _timer?.cancel();
    _timer = null;
    for (final session in _sessions.toList()) {
      _close(session, 'revoked');
    }
    completion.complete(_finishDisconnectAll());
    return completion.future;
  }

  Future<void> _finishDisconnectAll() async {
    try {
      // An admission cleanup error still has to wait for every socket already
      // closed by disconnectAll before the shared barrier is released.
      await Future.wait<void>([stopAccepting(), ..._transportClosures]);
    } finally {
      _disconnecting = false;
      _disconnectPending = null;
    }
  }

  /// Revokes every live and recovering grant for one verified identity.
  /// A suspended connection is no longer in [sessions], so closing only the
  /// visible sockets would leave its authenticated recovery able to resume.
  void disconnectPeer(String peerKey) {
    for (final previous
        in recoveringConnections
            .where((connection) => connection.peerKey == peerKey)
            .toList()) {
      cancelRecovery(previous);
    }
    for (final connection
        in sessions.where((session) => session.peerKey == peerKey).toList()) {
      final grant = connection.grant;
      if (grant != null) grants.revoke(grant);
      _close(connection, 'revoked');
    }
  }

  /// Permanently closes admission for this process before awaiting cleanup.
  /// Unlike the reversible allow-connections switch, an exit retry must never
  /// create new grants while its original media release is still pending.
  Future<void> shutdown() {
    _shutdownRequested = true;
    final pending = _shutdownPending;
    if (pending != null) return pending;
    final completion = Completer<void>();
    _shutdownPending = completion.future;
    final disconnect = Future<void>.sync(disconnectAll);
    // Cancellation can finish before a pending bind/connect returns its socket.
    // Await those owners too, so their late resources are closed before exit.
    completion.complete(
      _finishShutdown(disconnect).whenComplete(() {
        _shutdownPending = null;
      }),
    );
    return completion.future;
  }

  Future<void> _finishShutdown(Future<void> disconnect) async {
    Object? failure;
    StackTrace? failureStack;
    try {
      await Future.wait<dynamic>([
        disconnect,
        ..._pendingStarts,
        ..._pendingRecoveries,
      ]);
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    }
    // A failed owner can still have created a socket before it finished. Its
    // transport close must settle before process cleanup reports the failure.
    while (_transportClosures.isNotEmpty) {
      try {
        await Future.wait(_transportClosures.toList());
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }

  Future<TrustedConnection?> connect(
    String host,
    int port,
    String shortCode, {
    String? expectedPeerKey,
  }) => _shutdownRequested
      ? Future<TrustedConnection?>.value()
      : _startTracked<TrustedConnection?>(
          () =>
              _connect(host, port, shortCode, expectedPeerKey: expectedPeerKey),
        );

  Future<TrustedConnection?> connectByCode(
    String shortCode, {
    String? expectedPeerKey,
  }) => _shutdownRequested
      ? Future<TrustedConnection?>.value()
      : _startTracked<TrustedConnection?>(
          () => _connectByCode(shortCode, expectedPeerKey: expectedPeerKey),
        );

  Future<TrustedConnection?> _connectByCode(
    String shortCode, {
    String? expectedPeerKey,
  }) async {
    if (busy || _disposed || _disconnecting || _shutdownRequested) return null;
    if (_sessions.length + _recoveries.length >= 8) {
      _notice = const ConnectionNotice.problem('连接数量已达上限，请先断开一个连接。');
      _emit();
      return null;
    }
    final generation = ++_generation;
    _lastConnectionFailureCode = null;
    busy = true;
    _connecting = true;
    _notice = const ConnectionNotice.status('正在通过所选辅助服务验证短接码和对端身份…');
    _emit();
    final cancellation = _meetingJoinCancellation = AuxiliaryCancellation();
    try {
      final identity = await _loadIdentity();
      if (_disposed || _shutdownRequested || generation != _generation) {
        return null;
      }
      final routes = auxiliaryRoutes;
      if (routes == null) throw const AuxiliaryFailure('route_unavailable');
      final attempt = _attempt = PairingAttempt(
        identity: identity,
        clock: platform.now,
        protocolVersion: 2,
        enableRecovery: true,
      );
      final connection = await attempt.connectWithWire(
        () => routes.openMeetingWire(shortCode, cancellation),
        shortCode,
        expectedPeerKey: expectedPeerKey,
      );
      if (_disposed || _shutdownRequested || generation != _generation) {
        _close(connection, 'cancelled');
        return null;
      }
      _attempt = null;
      if (!_track(connection)) return null;
      _notice = ConnectionNotice.status(
        '身份验证通过，已通过辅助服务建立连接。${formatGrantPolicy(connection.grant!)}。',
      );
      return connection;
    } catch (error) {
      if (!_disposed && generation == _generation) {
        _lastConnectionFailureCode = switch (error) {
          ConnectionFailure(:final code) => code,
          AuxiliaryFailure(:final code) => code,
          _ => null,
        };
        _notice = ConnectionNotice.problem(switch (error) {
          ConnectionFailure(code: 'invalid_input') => '请输入完整的 6 位纯数字短接码。',
          ConnectionFailure(code: 'identity_mismatch') =>
            '辅助服务返回的设备身份与所选设备不一致，请重新发现设备或检查服务。',
          ConnectionFailure(code: 'cancelled') => '连接已取消或握手超时。',
          ConnectionFailure(code: 'entry_unavailable') =>
            '短接码不可用、已过期或已被使用，请让对方重新生成。',
          ConnectionFailure(code: 'capacity_limited') =>
            '会合请求过多，请稍后重试或让对方重新生成短接码。',
          ConnectionFailure(code: 'timeout' || 'unreachable' || 'tls_error') =>
            '所选辅助服务不可达或 TLS 校验失败，请检查服务地址与网络。',
          AuxiliaryFailure(code: 'route_unavailable') =>
            '所选辅助服务未配置或不可用，请在设置中选择可达的 HTTPS 服务。',
          ConnectionFailure(code: 'route_unavailable') =>
            '所选辅助服务未配置或不可用，请在设置中选择可达的 HTTPS 服务。',
          _ => '跨网连接未建立，请检查短接码、对端接入状态及所选辅助服务。',
        });
      }
    } finally {
      cancellation.cancel();
      if (identical(_meetingJoinCancellation, cancellation)) {
        _meetingJoinCancellation = null;
      }
      if (generation == _generation) {
        busy = false;
        _connecting = false;
        _attempt = null;
      }
      _emit();
    }
    return null;
  }

  Future<TrustedConnection?> _connect(
    String host,
    int port,
    String shortCode, {
    String? expectedPeerKey,
  }) async {
    if (busy || _disposed || _disconnecting || _shutdownRequested) return null;
    if (_sessions.length + _recoveries.length >= 8) {
      _notice = const ConnectionNotice.problem('连接数量已达上限，请先断开一个连接。');
      _emit();
      return null;
    }
    final generation = ++_generation;
    _lastConnectionFailureCode = null;
    busy = true;
    _connecting = true;
    _notice = const ConnectionNotice.status('正在验证短接码和对端身份…');
    _emit();
    try {
      final identity = await _loadIdentity();
      if (_disposed || _shutdownRequested || generation != _generation) {
        return null;
      }
      final attempt = _attempt = PairingAttempt(
        identity: identity,
        clock: platform.now,
        protocolVersion: 2,
        enableRecovery: true,
      );
      final connection = await attempt.connect(
        host,
        port,
        shortCode,
        expectedPeerKey: expectedPeerKey,
      );
      if (_disposed || _shutdownRequested || generation != _generation) {
        _close(connection, 'cancelled');
        return null;
      }
      _attempt = null;
      _routes[connection.grant!] = (host: host, port: port);
      if (!_track(connection)) {
        _routes.remove(connection.grant);
        return null;
      }
      _notice = ConnectionNotice.status(
        '身份验证通过，已建立本地直连。${formatGrantPolicy(connection.grant!)}。',
      );
      return connection;
    } catch (error) {
      if (!_disposed && generation == _generation) {
        _lastConnectionFailureCode = error is ConnectionFailure
            ? error.code
            : null;
        _notice = ConnectionNotice.problem(switch (error) {
          ConnectionFailure(code: 'identity_mismatch') =>
            '对端身份与所选设备不一致，请重新发现设备。',
          ConnectionFailure(code: 'invalid_input') => '请输入完整的 6 位纯数字短接码及有效端口。',
          ConnectionFailure(code: 'cancelled') => '连接已取消或握手超时。',
          ConnectionFailure(code: 'signal_unreachable') =>
            '本地信令地址不可达，请检查对端接入状态、地址及局域网连接；TURN 不能代替首次短码连接。',
          _ => '连接未建立，请检查短接码、对端接入状态及局域网连通性。',
        });
      }
    } finally {
      if (generation == _generation) {
        busy = false;
        _connecting = false;
        _attempt = null;
      }
      _emit();
    }
    return null;
  }

  void cancel() {
    _generation++;
    _lastConnectionFailureCode = null;
    _attempt?.cancel();
    _meetingJoinCancellation?.cancel();
    _attempt = null;
    busy = false;
    _connecting = false;
    _notice = const ConnectionNotice.status('已取消连接。');
    _emit();
  }

  void _observeClosure(TrustedConnection connection) {
    final closure = connection.whenTransportClosed;
    if (_transportClosures.add(closure)) {
      unawaited(closure.whenComplete(() => _transportClosures.remove(closure)));
    }
  }

  void _close(TrustedConnection connection, String reason) {
    connection.close(reason);
    _observeClosure(connection);
  }

  bool _track(TrustedConnection connection) {
    if (_disposed || _disconnecting || _shutdownRequested) {
      _close(connection, 'admission_rejected');
      return false;
    }
    final grant = connection.grant;
    final replacing = _recoveries.containsKey(grant);
    if (connection.isClosed ||
        grant == null ||
        grant.phase != GrantPhase.active ||
        _sessions.length + _recoveries.length - (replacing ? 1 : 0) >= 8) {
      _close(connection, 'admission_rejected');
      _notice = const ConnectionNotice.problem('连接未接入：授权不可用或连接数量已达上限。');
      _emit();
      return false;
    }
    grants.register(grant);
    _recoveries.remove(grant)?.cancel(revoke: false);
    _sessions.add(connection);
    unawaited(
      connection.whenClosed.then((reason) {
        _observeClosure(connection);
        _sessions.remove(connection);
        if (reason == 'transport_suspended' &&
            connection.canRecover &&
            (grant.role == GrantRole.initiator || accepting) &&
            !_disposed &&
            !_disconnecting &&
            !_shutdownRequested) {
          _beginRecovery(connection);
          return;
        }
        grants.revoke(grant);
        _routes.remove(grant);
        _alternateRoutes.remove(grant);
        if (!_disposed) {
          _notice = reason == 'revoked' || reason == 'cancelled'
              ? const ConnectionNotice.status('连接已断开；再次连接需输入有效短接码。')
              : ConnectionNotice.problem(
                  reason == 'expired'
                      ? '授权已到期，请使用新短接码连接。'
                      : '连接已断开；再次连接需输入有效短接码。',
                );
          _emit();
        }
      }),
    );
    _emit();
    return true;
  }

  Future<void> _verifyRecoveryIdentity() async {
    final identity = await platform.identity();
    if (_disposed ||
        _disconnecting ||
        _shutdownRequested ||
        identity.encodedKey != _identity?.encodedKey) {
      throw const ConnectionFailure('identity_mismatch');
    }
  }

  Future<void> _acceptRecovered(TrustedConnection connection) async {
    // Host authentication has already produced a socket, but platform identity
    // validation can still be pending. Revocation must close this candidate now,
    // not only after that platform Future eventually returns.
    final invalidation = connection.grant!.invalidated.listen((_) {
      if (connection.grant!.phase == GrantPhase.revoked) {
        _close(connection, 'revoked');
      }
    });
    try {
      final owner = _recoveries[connection.grant];
      if (owner == null || owner.cancelled) {
        throw const ConnectionFailure('recovery_unavailable');
      }
      await _verifyRecoveryIdentity();
      await owner.checkCurrent();
      if (!identical(_recoveries[connection.grant], owner) ||
          owner.cancelled ||
          !accepting) {
        throw const ConnectionFailure('cancelled');
      }
      if (_track(connection)) {
        _notice = const ConnectionNotice.status('连接已认证恢复，原授权截止时间不变。');
        _emit();
      }
    } catch (_) {
      _close(connection, 'recovery_rejected');
    } finally {
      await invalidation.cancel();
      if (connection.isClosed) await connection.whenTransportClosed;
    }
  }

  void _beginRecovery(TrustedConnection previous) {
    final grant = previous.grant!;
    String? relayPeerAddress;
    late ConnectionRecovery recovery;
    recovery = ConnectionRecovery(
      previous: previous,
      route: grant.role == GrantRole.initiator ? _routes[grant] : null,
      alternateRoute: grant.role == GrantRole.initiator
          ? _alternateRoutes[grant]
          : null,
      clock: platform.now,
      verifyIdentity: _verifyRecoveryIdentity,
      window: recoveryWindow,
      backoff: recoveryBackoff,
      attemptTimeout: recoveryAttemptTimeout,
      openRelay: auxiliaryRoutes == null
          ? null
          : (previous, cancellation) async {
              final device = await _loadIdentity();
              cancellation.throwIfCancelled();
              await _verifyRecoveryIdentity();
              cancellation.throwIfCancelled();
              return auxiliaryRoutes!.openSignalWire(
                previous,
                device,
                cancellation,
                onPeerAddress: (address) => relayPeerAddress = address,
              );
            },
      requireAdmission: () {
        if (!accepting || _disposed || _disconnecting || _shutdownRequested) {
          throw const ConnectionFailure('cancelled');
        }
      },
      onRecovered: (connection) {
        if (!identical(_recoveries[grant], recovery) || recovery.cancelled) {
          return false;
        }
        if (grant.role == GrantRole.receiver && !accepting) return false;
        final accepted = _track(connection);
        if (accepted) {
          final route = _routes[grant];
          if (relayPeerAddress case final address? when route != null) {
            // Preserve the local route first; the observed address may be a
            // NAT address that does not accept a direct connection.
            _alternateRoutes[grant] = (host: address, port: route.port);
          }
          _notice = const ConnectionNotice.status('连接已认证恢复，原授权截止时间不变。');
          _emit();
        }
        return accepted;
      },
      onFailed: () {
        if (!identical(_recoveries[grant], recovery)) return;
        _recoveries.remove(grant);
        _routes.remove(grant);
        _alternateRoutes.remove(grant);
        grants.revoke(grant);
        if (!_disposed && !_disconnecting && !_shutdownRequested) {
          _notice = const ConnectionNotice.problem('连接恢复未完成，请重新输入短接码连接。');
          _emit();
        }
      },
    );
    _recoveries[grant] = recovery;
    final completion = Completer<void>();
    _pendingRecoveries.add(completion.future);
    completion.complete(
      recovery.run().whenComplete(
        () => _pendingRecoveries.remove(completion.future),
      ),
    );
    _notice = const ConnectionNotice.status('连接暂时中断，正在核验原授权并恢复…');
    _emit();
  }

  void cancelRecovery(TrustedConnection previous) {
    final grant = previous.grant;
    if (grant == null) return;
    final recovery = _recoveries.remove(grant);
    recovery?.cancel();
    _routes.remove(grant);
    _alternateRoutes.remove(grant);
    grants.revoke(grant);
    for (final connection
        in _sessions.where((s) => identical(s.grant, grant)).toList()) {
      _close(connection, 'cancelled');
    }
    _notice = const ConnectionNotice.status('已取消恢复；再次连接需输入有效短接码。');
    _emit();
  }

  void _cancelRecoveries() {
    final pending = _recoveries.values.toList();
    _recoveries.clear();
    for (final recovery in pending) {
      _routes.remove(recovery.previous.grant);
      _alternateRoutes.remove(recovery.previous.grant);
      recovery.cancel();
      grants.revoke(recovery.previous.grant!);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    auxiliaryRoutes?.removeListener(_onAuxiliaryRouteChanged);
    _generation++;
    _attempt?.cancel();
    _meetingJoinCancellation?.cancel();
    _meetingCancellation?.cancel();
    unawaited(_meetingRoute?.close() ?? Future.value());
    _timer?.cancel();
    _cancelRecoveries();
    grants.revokeAll();
    for (final session in _sessions.toList()) {
      _close(session, 'revoked');
    }
    unawaited(_host?.close() ?? Future.value());
    unawaited(_clearAdvertisement());
    super.dispose();
  }
}
