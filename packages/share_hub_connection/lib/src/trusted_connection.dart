part of 'session.dart';

enum ConnectionPhase { active, suspended, recovering, closed }

/// Stable owner of an authenticated grant. Physical queues and cipher sequences
/// belong to separate epochs; recovery never creates a new lease or endpoint.
class TrustedConnection implements SessionTransport {
  TrustedConnection(
    CipherChannel channel,
    this.peerKey,
    this.lease,
    this._clock, {
    this.grant,
    ConnectionRecoveryHandle? recovery,
  }) : _physical = _PhysicalTransport(channel),
       _sessionId = channel.sessionId,
       _recovery = recovery {
    if (recovery != null) {
      if (grant == null ||
          grant!.phase != GrantPhase.active ||
          recovery._owner != null) {
        throw ArgumentError('Recovery requires one active original grant.');
      }
      recovery._owner = this;
    }
  }

  final GrantEndpoint? grant;
  final String peerKey;
  final SessionLease lease;
  final ContinuousClock _clock;
  final ConnectionRecoveryHandle? _recovery;
  _PhysicalTransport? _physical;
  String _sessionId;
  String get sessionId => _sessionId;
  String get peerId =>
      hashes.sha256.convert(decodeBytes(peerKey, 32)).toString();
  final _closed = Completer<String>();
  final _phases = StreamController<ConnectionPhase>.broadcast();
  final _suspending = <void Function()>{};
  Stream<ConnectionPhase> get phaseChanges => _phases.stream;
  ConnectionPhase _phase = ConnectionPhase.active;
  ConnectionPhase get phase => _phase;
  bool get isConnected => _phase == ConnectionPhase.active && _physical != null;
  bool get isClosed => _phase == ConnectionPhase.closed;
  Future<String> get whenClosed => _closed.future;
  Set<String> get capabilities => const {};
  Timer? _timer, _deadline;
  bool _monitoring = false;
  Future<int?>? _auditing;
  int _minimumGeneration = 0;
  ConnectionRecoveryAttempt? _attempt;

  /// Called synchronously after admission closes and before grant invalidation.
  /// File owners establish native pause intent here, without awaiting a result.
  void addSuspendingListener(void Function() listener) {
    if (isClosed) throw const ConnectionFailure('disconnected');
    _suspending.add(listener);
  }

  void removeSuspendingListener(void Function() listener) =>
      _suspending.remove(listener);

  void Function(VerifiedSessionMessage)? _onRequest;
  SessionAuthorization? Function(String)? _resolveSession;
  void Function(VerifiedSessionSignal)? _onSignal;
  int _receiverGeneration = 0;
  OperationRouter? _operationRouter;

  SessionTransport operationTransport(Set<SessionOperation> operations) {
    _endpoint;
    return (_operationRouter ??= OperationRouter(
      this,
    )).transportFor(operations);
  }

  GrantEndpoint get _endpoint {
    if (isClosed || grant == null) {
      throw const ConnectionFailure('session_unavailable');
    }
    return grant!;
  }

  _PhysicalTransport _active() {
    if (!isConnected) throw const ConnectionFailure('session_unavailable');
    return _physical!;
  }

  bool _owns(_PhysicalTransport epoch) =>
      isConnected && identical(_physical, epoch);
  void _require(_PhysicalTransport epoch) {
    if (!_owns(epoch)) throw const ConnectionFailure('disconnected');
  }

  @override
  Future<LocalSessionRequest> createRequest(
    SessionOperation operation,
    String sessionId,
    String body,
  ) async {
    final epoch = _active();
    final result = await _endpoint.authorizeLocal(operation, sessionId, body);
    _require(epoch);
    return result;
  }

  @override
  void attachReceiver({
    required void Function(VerifiedSessionMessage) onRequest,
    required SessionAuthorization? Function(String) resolveSession,
    required void Function(VerifiedSessionSignal) onSignal,
  }) {
    _endpoint;
    if (_onRequest != null) throw StateError('Receiver already attached');
    _receiverGeneration++;
    _onRequest = onRequest;
    _resolveSession = resolveSession;
    _onSignal = onSignal;
  }

  @override
  void detachReceiver() {
    _receiverGeneration++;
    _onRequest = null;
    _resolveSession = null;
    _onSignal = null;
  }

  Future<void> _enqueueOperation(
    Future<void> Function(_PhysicalTransport) write,
  ) {
    if (!isConnected || _physical!.queued >= 8) {
      return Future.error(
        const ConnectionFailure('session_unavailable_or_busy'),
      );
    }
    final epoch = _physical!;
    epoch.queued++;
    final pending = epoch.tail.then((_) async {
      _require(epoch);
      await write(epoch);
    });
    epoch.tail = pending.then<void>(
      (_) {
        epoch.queued--;
      },
      onError: (Object _, StackTrace _) {
        epoch.queued--;
      },
    );
    return pending;
  }

  @override
  Future<void> sendRequest(LocalSessionRequest request) =>
      _enqueueOperation((epoch) async {
        final packet = await _endpoint.sealRequest(request);
        _require(epoch);
        await _sendOperationPacket(epoch, {
          'type': 'operation-request',
          'packet': _packetMap(packet),
        });
      });
  @override
  Future<void> sendSignal(SessionAuthorization authorization, String body) {
    if (utf8.encode(body).length > 65536) {
      return Future.error(const ConnectionFailure('message_limit'));
    }
    return _enqueueOperation((epoch) async {
      final packet = await _endpoint.sealSignal(authorization, body);
      _require(epoch);
      await _sendOperationPacket(epoch, {
        'type': 'operation-signal',
        'sessionId': authorization.sessionId,
        'packet': _packetMap(packet),
      });
    });
  }

  Future<void> _sendOperationPacket(
    _PhysicalTransport epoch,
    Map<String, dynamic> packet,
  ) async {
    try {
      await epoch.channel.send(packet);
      _require(epoch);
    } catch (_) {
      _lost(epoch, 'operation_transport_failed');
      rethrow;
    }
  }

  static Map<String, dynamic> _packetMap(SessionEnvelope packet) => {
    'generation': packet.generation,
    'sequence': packet.sequence,
    'ciphertext': encodeBytes(packet.ciphertext),
    'mac': encodeBytes(packet.mac),
  };
  static SessionEnvelope _parsePacket(Object? value) {
    if (value is! Map ||
        value['generation'] is! int ||
        value['sequence'] is! int ||
        value['ciphertext'] is! String) {
      throw const ConnectionFailure('invalid_message');
    }
    final encoded = value['ciphertext'] as String;
    if (encoded.length > 87384) throw const ConnectionFailure('message_limit');
    final bytes = base64Url.decode(encoded);
    if (encodeBytes(bytes) != encoded) {
      throw const ConnectionFailure('invalid_message');
    }
    return SessionEnvelope(
      generation: value['generation'],
      sequence: value['sequence'],
      ciphertext: bytes,
      mac: decodeBytes(value['mac'], 16),
    );
  }

  Future<void> _receiveOperation(
    _PhysicalTransport epoch,
    Map<String, dynamic> message,
    int generation,
    Map<SessionOperation, int>? routes,
  ) async {
    final endpoint = _endpoint;
    final packet = _parsePacket(message['packet']);
    if (message['type'] == 'operation-request') {
      final request = await endpoint.open(packet);
      if (_owns(epoch) &&
          generation == _receiverGeneration &&
          (routes == null ||
              _operationRouter!.canDeliver(request.operation, routes))) {
        request.requireCurrent();
        _onRequest?.call(request);
      }
    } else {
      final id = message['sessionId'];
      if (id is! String || id.isEmpty || id.length > 128) {
        throw const ConnectionFailure('invalid_message');
      }
      final authorization = _resolveSession?.call(id);
      if (authorization == null) {
        await endpoint.discardSignal(packet);
        return;
      }
      final signal = await endpoint.openSignal(authorization, packet);
      if (_owns(epoch) &&
          generation == _receiverGeneration &&
          (routes == null ||
              _operationRouter!.canDeliver(authorization.operation, routes))) {
        signal.requireCurrent();
        _onSignal?.call(signal);
      }
    }
  }

  void startMonitoring() {
    if (_monitoring || isClosed) return;
    _monitoring = true;
    unawaited(_armDeadline());
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(check()),
    );
    if (_physical case final epoch?) unawaited(_read(epoch));
  }

  int get _expiresMicros =>
      grant != null && grant!.expiresMicros < lease.expiresMicros
      ? grant!.expiresMicros
      : lease.expiresMicros;
  Future<int?> _audit() => _auditing ??= _readClock().whenComplete(() {
    _auditing = null;
  });
  Future<int?> _readClock() async {
    if (isClosed) return null;
    int now;
    try {
      now = await _clock();
    } catch (_) {
      close('clock_unavailable');
      return null;
    }
    if (isClosed) return null;
    if (!lease.check(now) ||
        now >= _expiresMicros ||
        grant?.phase == GrantPhase.revoked) {
      close('expired');
      return null;
    }
    return now;
  }

  Future<void> _armDeadline() async {
    final now = await _audit();
    if (now == null || isClosed) return;
    _deadline?.cancel();
    _deadline = Timer(
      Duration(microseconds: _expiresMicros - now),
      () => unawaited(_armDeadline()),
    );
  }

  Future<bool> check() async {
    if (isClosed) return false;
    final epoch = _physical;
    if (await _audit() == null) return false;
    if (epoch == null || !_owns(epoch)) return false;
    if (!epoch.sendingHeartbeat) {
      epoch.sendingHeartbeat = true;
      try {
        await epoch.channel.send({'type': 'heartbeat'});
      } catch (_) {
        _lost(epoch, 'transport_failed');
        return false;
      } finally {
        epoch.sendingHeartbeat = false;
      }
    }
    return _owns(epoch);
  }

  Future<void> _read(_PhysicalTransport epoch) async {
    while (_owns(epoch)) {
      var generation = _receiverGeneration;
      Map<SessionOperation, int>? routes;
      Map<String, dynamic> message;
      try {
        message = await epoch.channel
            .next(
              onFrame: () {
                generation = _receiverGeneration;
                routes = _operationRouter?.snapshot();
              },
            )
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        _lost(epoch, 'disconnected');
        return;
      }
      if (!_owns(epoch) || await _audit() == null || !_owns(epoch)) return;
      try {
        if (message['type'] == 'connection-revoked' &&
            message['reason'] == 'revoked') {
          _close('peer_revoked', notifyPeer: false);
          return;
        }
        if (grant != null &&
            (message['type'] == 'operation-request' ||
                message['type'] == 'operation-signal')) {
          await _receiveOperation(epoch, message, generation, routes);
        } else if (message['type'] != 'heartbeat') {
          close('unsupported_operation');
          return;
        }
      } catch (_) {
        if (_owns(epoch)) close('invalid_operation');
        return;
      }
    }
  }

  void _lost(_PhysicalTransport epoch, String reason) {
    if (!_owns(epoch)) {
      epoch.channel.wire.close();
      return;
    }
    if (_recovery == null || grant?.phase == GrantPhase.revoked) {
      close(reason);
      return;
    }
    _physical = null;
    _phase = ConnectionPhase.suspended;
    _minimumGeneration = grant!.generation;
    for (final listener in List.of(_suspending)) {
      try {
        listener();
      } catch (_) {
        close('suspension_failed');
        epoch.channel.wire.close();
        return;
      }
      if (isClosed) {
        epoch.channel.wire.close();
        return;
      }
    }
    grant!.suspend();
    epoch.channel.wire.close();
    if (!isClosed) _phases.add(ConnectionPhase.suspended);
  }

  void close([String reason = 'revoked']) => _close(reason, notifyPeer: true);
  void _close(String reason, {required bool notifyPeer}) {
    if (isClosed) return;
    final epoch = _physical;
    _physical = null;
    _phase = ConnectionPhase.closed;
    _attempt = null;
    _operationRouter?.close();
    detachReceiver();
    grant?.revoke();
    lease.revoke();
    _timer?.cancel();
    _deadline?.cancel();
    _suspending.clear();
    if (epoch != null) {
      if (notifyPeer && _recovery != null) {
        unawaited(_sendRevoked(epoch));
      } else {
        epoch.channel.wire.close();
      }
    }
    _phases.add(ConnectionPhase.closed);
    unawaited(_phases.close());
    _closed.complete(reason);
  }

  Future<void> _sendRevoked(_PhysicalTransport epoch) async {
    try {
      await (() async {
        await epoch.channel.send({
          'type': 'connection-revoked',
          'reason': 'revoked',
        });
        await epoch.channel.wire.socket.flush();
      })().timeout(const Duration(milliseconds: 200));
    } catch (_) {
      /* Local revocation does not wait for delivery. */
    } finally {
      epoch.channel.wire.close();
    }
  }
}

final class _PhysicalTransport {
  _PhysicalTransport(this.channel);
  final CipherChannel channel;
  int queued = 0;
  Future<void> tail = Future.value();
  bool sendingHeartbeat = false;
}

/// Internal capability held only by the authenticated recovery protocol. It is
/// not exported by the package entry point and performs no remote authentication.
/// The protocol must prove the peer's original recovery secret before begin.
final class ConnectionRecoveryHandle {
  TrustedConnection? _owner;
  bool owns(TrustedConnection connection) => identical(_owner, connection);

  /// Audits the original lease without sending a heartbeat or changing phase.
  Future<void> check() async {
    final owner = _owner;
    if (owner == null || await owner._audit() == null || owner.isClosed) {
      throw const ConnectionFailure('recovery_unavailable');
    }
  }

  ConnectionRecoveryAttempt beginRecovery() {
    final owner = _owner;
    if (owner == null ||
        owner.isClosed ||
        owner._attempt != null ||
        owner.grant?.phase == GrantPhase.revoked) {
      throw const ConnectionFailure('recovery_unavailable');
    }
    if (owner._physical case final epoch?) {
      owner._lost(epoch, 'authenticated_recovery');
    }
    if (owner.isClosed || owner.phase != ConnectionPhase.suspended) {
      throw const ConnectionFailure('recovery_unavailable');
    }
    owner._phase = ConnectionPhase.recovering;
    final attempt = owner._attempt = ConnectionRecoveryAttempt._(owner);
    owner._phases.add(ConnectionPhase.recovering);
    return attempt;
  }
}

final class ConnectionRecoveryAttempt {
  ConnectionRecoveryAttempt._(this._owner);
  final TrustedConnection _owner;
  bool get _current =>
      !_owner.isClosed &&
      identical(_owner._attempt, this) &&
      _owner.phase == ConnectionPhase.recovering;
  Future<void> install(CipherChannel channel) async {
    try {
      if (!_current || await _owner._audit() == null || !_current) {
        throw const ConnectionFailure('recovery_unavailable');
      }
      final endpoint = _owner.grant!;
      if (endpoint.phase != GrantPhase.active ||
          endpoint.generation <= _owner._minimumGeneration ||
          channel.sessionId == _owner.sessionId) {
        throw const ConnectionFailure('invalid_recovery');
      }
      channel.enableSessionFrames();
      final epoch = _PhysicalTransport(channel);
      _owner._physical = epoch;
      _owner._sessionId = channel.sessionId;
      _owner._attempt = null;
      _owner._phase = ConnectionPhase.active;
      _owner._phases.add(ConnectionPhase.active);
      if (_owner._monitoring) unawaited(_owner._read(epoch));
    } catch (_) {
      if (!identical(_owner._physical?.channel, channel)) channel.wire.close();
      cancel();
      rethrow;
    }
  }

  void cancel() {
    if (!_current) return;
    _owner._attempt = null;
    if (_owner.grant?.phase == GrantPhase.revoked) {
      _owner.close('revoked');
      return;
    }
    _owner._phase = ConnectionPhase.suspended;
    _owner.grant!.suspend();
    _owner._phases.add(ConnectionPhase.suspended);
  }
}
