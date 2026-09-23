import 'package:share_hub_session_api/share_hub_session_api.dart';

/// Owns the connection's single receiver and exposes disjoint operation views.
/// It holds no message backlog or session registry: consumers own bounded work
/// queues and resolve their current sealed authorities at delivery time.
final class OperationRouter {
  OperationRouter(this._source) {
    _source.attachReceiver(
      onRequest: _onRequest,
      resolveSession: _resolve,
      onSignal: _onSignal,
    );
  }

  final SessionTransport _source;
  final _ports = <_OperationPort>[];
  bool _closed = false;

  SessionTransport transportFor(Set<SessionOperation> operations) {
    if (_closed) throw StateError('Operation router closed');
    if (operations.isEmpty) throw ArgumentError.value(operations, 'operations');
    for (final port in _ports) {
      if (port.operations.length == operations.length &&
          port.operations.containsAll(operations)) {
        return port;
      }
      if (operations.any(port.operations.contains)) {
        throw StateError('Operation already routed');
      }
    }
    final port = _OperationPort(this, Set.unmodifiable(operations));
    _ports.add(port);
    return port;
  }

  /// Capture attachment epochs before the connection awaits authentication.
  /// A detach/reattach cannot deliver an earlier packet to a new consumer.
  Map<SessionOperation, int> snapshot() => {
    for (final port in _ports)
      for (final operation in port.operations) operation: port._epoch,
  };

  bool canDeliver(
    SessionOperation operation,
    Map<SessionOperation, int> before,
  ) {
    final port = _portFor(operation);
    return port != null && port._attached && before[operation] == port._epoch;
  }

  _OperationPort? _portFor(SessionOperation operation) {
    for (final port in _ports) {
      if (port.operations.contains(operation)) return port;
    }
    return null;
  }

  SessionAuthorization? _resolve(String id) {
    SessionAuthorization? found;
    for (final port in _ports) {
      final candidate = port._resolve(id);
      if (candidate == null) continue;
      if (found != null) return null;
      found = candidate;
    }
    return found;
  }

  void _checkCollision(_OperationPort owner, String id) {
    for (final port in _ports) {
      if (!identical(owner, port) && port._resolve(id) != null) {
        throw const SessionFailure('session_id_conflict');
      }
    }
  }

  void _onRequest(VerifiedSessionMessage request) {
    final port = _portFor(request.operation);
    if (port == null || !port._attached) return;
    try {
      _checkCollision(port, request.sessionId);
      request.requireCurrent();
    } on SessionFailure {
      return;
    }
    port._onRequest?.call(request);
  }

  void _onSignal(VerifiedSessionSignal signal) {
    final authority = signal.authorization;
    final port = _portFor(authority.operation);
    if (port == null ||
        !identical(port._resolve(authority.sessionId), authority)) {
      return;
    }
    signal.requireCurrent();
    port._onSignal?.call(signal);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final port in _ports) {
      port.detachReceiver();
    }
    _source.detachReceiver();
  }
}

final class _OperationPort implements SessionTransport {
  _OperationPort(this._router, this.operations);
  final OperationRouter _router;
  final Set<SessionOperation> operations;
  int _epoch = 0;
  void Function(VerifiedSessionMessage)? _onRequest;
  SessionAuthorization? Function(String)? _resolver;
  void Function(VerifiedSessionSignal)? _onSignal;
  bool get _attached => !_router._closed && _onRequest != null;

  void _check(SessionOperation operation, [int? epoch]) {
    if (!_attached ||
        !operations.contains(operation) ||
        (epoch != null && epoch != _epoch)) {
      throw const SessionFailure('operation_route_unavailable');
    }
  }

  SessionAuthorization? _resolve(String id) {
    if (!_attached) return null;
    final authority = _resolver?.call(id);
    if (authority == null ||
        authority.sessionId != id ||
        !operations.contains(authority.operation)) {
      return null;
    }
    try {
      authority.requireCurrent();
      return authority;
    } on SessionFailure {
      return null;
    }
  }

  @override
  Future<LocalSessionRequest> createRequest(
    SessionOperation operation,
    String sessionId,
    String body,
  ) async {
    final epoch = _epoch;
    _check(operation, epoch);
    _router._checkCollision(this, sessionId);
    final request = await _router._source.createRequest(
      operation,
      sessionId,
      body,
    );
    _check(operation, epoch);
    _router._checkCollision(this, sessionId);
    return request;
  }

  @override
  Future<void> sendRequest(LocalSessionRequest request) async {
    _check(request.operation);
    _router._checkCollision(this, request.sessionId);
    await _router._source.sendRequest(request);
  }

  @override
  Future<void> sendSignal(
    SessionAuthorization authorization,
    String body,
  ) async {
    _check(authorization.operation);
    _router._checkCollision(this, authorization.sessionId);
    await _router._source.sendSignal(authorization, body);
  }

  @override
  void attachReceiver({
    required void Function(VerifiedSessionMessage) onRequest,
    required SessionAuthorization? Function(String) resolveSession,
    required void Function(VerifiedSessionSignal) onSignal,
  }) {
    if (_router._closed) throw StateError('Operation router closed');
    if (_attached) throw StateError('Receiver already attached');
    _epoch++;
    _onRequest = onRequest;
    _resolver = resolveSession;
    _onSignal = onSignal;
  }

  @override
  void detachReceiver() {
    _epoch++;
    _onRequest = null;
    _resolver = null;
    _onSignal = null;
  }
}
