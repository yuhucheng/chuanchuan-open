import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import 'connection_recovery.dart';
import 'auxiliary_route_controller.dart';

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
  });
  final ConnectionPlatform platform;
  final Duration recoveryWindow, recoveryAttemptTimeout;
  final List<Duration> recoveryBackoff;
  final AuxiliaryRouteController? auxiliaryRoutes;
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
  Timer? _timer;
  bool _disposed = false;
  bool _disconnecting = false;
  bool _shutdownRequested = false;
  final _pendingStarts = <Future<dynamic>>{};
  Future<void>? _shutdownPending;
  int _generation = 0;
  bool busy = false;
  bool _connecting = false;
  bool get connecting => _connecting;
  String? code;
  String? address;
  ConnectionNotice? _notice;
  ConnectionNotice? get notice => _notice;
  String? get message => notice?.message;
  String? get problem =>
      notice?.kind == ConnectionNoticeKind.problem ? notice?.message : null;
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
    busy = true;
    _notice = null;
    code = null;
    address = null;
    _emit();
    PairingHost? opening;
    try {
      final identity = await _loadIdentity();
      if (_disposed || _shutdownRequested || generation != _generation) return;
      await _clearAdvertisement();
      if (_disposed || _shutdownRequested || generation != _generation) return;
      final existing = _host;
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
                _notice = const ConnectionNotice.status(
                  '连接已建立，短接码已消费。授权期限以当前连接为准，可随时断开。',
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
      final hostname = await platform.advertise(host.port, identity.encodedKey);
      if (_disposed || _shutdownRequested || generation != _generation) {
        await host.stopAccepting();
        if (identical(_host, host)) await _clearAdvertisement();
        return;
      }
      code = host.offer!.code;
      address = hostname == null ? null : '$hostname:${host.port}';
      _timer ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_tick()),
      );
    } catch (_) {
      await opening?.stopAccepting();
      if (generation == _generation) await _clearAdvertisement();
      if (!_disposed && generation == _generation) {
        _notice = const ConnectionNotice.problem('接入启动失败，请检查钥匙串及本地网络权限。');
      }
    } finally {
      if (generation == _generation) busy = false;
      _emit();
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
        _notice = const ConnectionNotice.problem('短接码已失效或尝试次数已用完，请重新生成。');
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
    code = null;
    address = null;
    await _host?.stopAccepting();
    if (generation == _generation && _host != null) await _clearAdvertisement();
    _emit();
  }

  /// Admission and in-flight handshakes are invalidated before awaiting I/O.
  Future<void> disconnectAll() async {
    _disconnecting = true;
    grants.revokeAll();
    _cancelRecoveries();
    _timer?.cancel();
    _timer = null;
    for (final session in _sessions.toList()) {
      _close(session, 'revoked');
    }
    try {
      await stopAccepting();
      await Future.wait(_transportClosures.toList());
    } finally {
      _disconnecting = false;
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
      Future.wait<dynamic>([
            disconnect,
            ..._pendingStarts,
            ..._pendingRecoveries,
          ])
          .then<void>((_) async {
            while (_transportClosures.isNotEmpty) {
              await Future.wait(_transportClosures.toList());
            }
          })
          .whenComplete(() {
            _shutdownPending = null;
          }),
    );
    return completion.future;
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
      _notice = const ConnectionNotice.status('身份验证通过，已建立本地直连。授权期限以当前连接为准。');
      return connection;
    } catch (error) {
      if (!_disposed && generation == _generation) {
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
    _attempt?.cancel();
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
    _generation++;
    _attempt?.cancel();
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
