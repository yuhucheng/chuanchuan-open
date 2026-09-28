import 'dart:async';
import 'dart:convert';

import 'auxiliary_service.dart';
import 'channel.dart';
import 'identity.dart';
import 'pairing.dart';

/// The selected auxiliary origin routes first-pairing bytes. It is not a grant.
final class MeetingServiceClient {
  const MeetingServiceClient(this.transport);
  final AuxiliaryTransport transport;

  Future<MeetingListing> publish(
    PairingHost host, {
    required AuxiliaryCancellation cancellation,
    void Function(MeetingConnectionWire)? onActivated,
  }) async {
    final offer = host.offer;
    if (offer == null) throw const AuxiliaryFailure('admission_closed');
    await AuxiliaryServiceClient(transport)
        .register(host.identity, cancellation: cancellation);
    cancellation.throwIfCancelled();
    if (!identical(offer, host.offer)) {
      throw const AuxiliaryFailure('cancelled');
    }
    final response = await AuxiliaryServiceClient(transport)
        .publishMeeting(host.identity, offer.code, cancellation: cancellation);
    final token = response['token'];
    final lifetime = response['expiresInSeconds'];
    if (response.length != 2 ||
        token is! String ||
        lifetime is! int ||
        lifetime < 1 ||
        lifetime > 300) {
      throw const AuxiliaryFailure('invalid_response');
    }
    try {
      decodeBytes(token, 32);
      if (!identical(offer, host.offer)) {
        throw const AuxiliaryFailure('cancelled');
      }
      return MeetingListing(
        transport,
        host,
        token,
        cancellation,
        onActivated: onActivated,
      );
    } catch (_) {
      unawaited(
        transport
            .post('/v1/meet/unpublish', {
              'token': token,
            }, AuxiliaryCancellation())
            .then<void>((_) {}, onError: (Object _) {}),
      );
      rethrow;
    }
  }

  Future<MeetingConnectionWire> join(
    String code, {
    required AuxiliaryCancellation cancellation,
  }) async {
    if (!RegExp(r'^[0-9]{6}$').hasMatch(code)) {
      throw const AuxiliaryFailure('invalid_input');
    }
    final response = await transport.post('/v1/meet/join', {
      'code': code,
    }, cancellation);
    final attempt = response['attempt'], token = response['token'];
    if (response.length != 2 || attempt is! String || token is! String) {
      throw const AuxiliaryFailure('invalid_response');
    }
    try {
      decodeBytes(attempt, 16);
      decodeBytes(token, 32);
    } on ConnectionFailure {
      throw const AuxiliaryFailure('invalid_response');
    }
    cancellation.throwIfCancelled();
    return MeetingConnectionWire(transport, token, attempt);
  }
}

/// The host owns the displayed code and all wire attempts opened for it.
final class MeetingListing {
  MeetingListing(
    this._transport,
    this._host,
    this._token,
    this._owner, {
    this.onActivated,
  });
  final AuxiliaryTransport _transport;
  final PairingHost _host;
  final String _token;
  final AuxiliaryCancellation _owner;
  final void Function(MeetingConnectionWire)? onActivated;
  final _pollCancellation = AuxiliaryCancellation();
  final _wires = <String, MeetingConnectionWire>{};
  bool _closed = false;
  bool _activated = false;
  String? _activeAttempt;
  bool get activated => _activated;
  bool get admissionPending => _wires.isNotEmpty && !_activated;

  /// Observe new joiners; each is admitted by the existing PairingHost budget.
  Future<void> serve() async {
    while (!_closed && !_activated && !_owner.isCancelled) {
      late final Map<String, Object?> response;
      try {
        response = await _transport.post('/v1/meet/pending', {
          'token': _token,
        }, _pollCancellation);
      } catch (_) {
        if (_closed || _activated || _owner.isCancelled) return;
        rethrow;
      }
      if (_closed || _activated || _owner.isCancelled) return;
      final attempts = response['attempts'];
      if (response.length != 1 || attempts is! List || attempts.length > 4) {
        throw const AuxiliaryFailure('invalid_response');
      }
      for (final value in attempts) {
        if (value is! String || _wires.containsKey(value)) continue;
        try {
          decodeBytes(value, 16);
        } on ConnectionFailure {
          throw const AuxiliaryFailure('invalid_response');
        }
        final wire = MeetingConnectionWire(_transport, _token, value);
        _wires[value] = wire;
        unawaited(_admit(value, wire));
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _admit(String attempt, MeetingConnectionWire wire) async {
    final connection = await _host.acceptWire(
      wire,
      beforeConnected: (candidate) async {
        final result = await _transport.post('/v1/meet/activate', {
          'token': _token,
          'attempt': attempt,
          'lifetimeSeconds': candidate.lease.policy.lifetime.inSeconds
              .toString(),
        }, _pollCancellation);
        if (result.length != 1 ||
            result['active'] != true ||
            _closed ||
            _owner.isCancelled) {
          throw const AuxiliaryFailure('invalid_response');
        }
        _activated = true;
        _activeAttempt = attempt;
        onActivated?.call(wire);
      },
    );
    if (connection == null || (_closed && !_activated) || _owner.isCancelled) {
      wire.close();
      _wires.remove(attempt);
      final offer = _host.offer;
      if (connection == null &&
          offer != null &&
          !offer.reservable(await _host.clock())) {
        await closeAdmission();
      }
      return;
    }
    for (final other in _wires.entries.toList()) {
      if (other.key != attempt) other.value.close();
    }
  }

  Future<void> closeAdmission() async {
    if (_closed) return;
    _closed = true;
    _pollCancellation.cancel();
    for (final item in _wires.entries.toList()) {
      if (item.key != _activeAttempt) item.value.close();
    }
    if (!_activated) {
      try {
        await _transport.post('/v1/meet/unpublish', {
          'token': _token,
        }, AuxiliaryCancellation());
      } catch (_) {}
    }
  }

  Future<void> close() async {
    await closeAdmission();
    _wires[_activeAttempt]?.close();
    _wires.clear();
  }
}

/// Bounded JSON frames over the selected HTTPS origin. The meeting service
/// can see the unencrypted SRP handshake but not the post-handshake cipher.
final class MeetingConnectionWire implements ConnectionWire {
  MeetingConnectionWire(this._transport, this._token, this._attempt);
  final AuxiliaryTransport _transport;
  final String _token, _attempt;
  final _cancellation = AuxiliaryCancellation();
  Future<void> _sendTail = Future.value();
  Object? _sendFailure;
  int _sendSequence = 0, _receiveSequence = 0, _queued = 0;
  int _limit = 8192;
  bool _closed = false;
  void Function()? onClosed;

  @override
  bool get isClosed => _closed;

  @override
  void enableSessionFrames() => _limit = 131072;

  @override
  void send(Map<String, dynamic> message) {
    if (_closed || _sendFailure != null) {
      throw const ConnectionFailure('disconnected');
    }
    final frame = jsonEncode(message);
    if (utf8.encode(frame).length > _limit || _queued >= 8) {
      throw const ConnectionFailure('message_limit');
    }
    final sequence = _sendSequence++;
    _queued++;
    _sendTail = _sendTail
        .then((_) async {
          final result = await _transport.post('/v1/meet/send', {
            'token': _token,
            'attempt': _attempt,
            'sequence': sequence.toString(),
            'frame': frame,
          }, _cancellation);
          if (result.length != 1 || result['accepted'] != true) {
            throw const AuxiliaryFailure('invalid_response');
          }
        })
        .then<void>(
          (_) {
            _queued--;
          },
          onError: (Object error) {
            _sendFailure = error;
            _queued--;
            close();
          },
        );
  }

  @override
  Future<void> flush() async {
    await _sendTail;
    if (_closed || _sendFailure != null) {
      throw const ConnectionFailure('disconnected');
    }
  }

  @override
  Future<Map<String, dynamic>> next() async {
    while (!_closed) {
      final result = await _transport.post('/v1/meet/poll', {
        'token': _token,
        'attempt': _attempt,
      }, _cancellation);
      if (result.length == 1 && result['pending'] == true) continue;
      final sequence = result['sequence'], frame = result['frame'];
      if (result.length != 2 ||
          sequence != _receiveSequence ||
          frame is! String ||
          utf8.encode(frame).length > _limit) {
        close();
        throw const ConnectionFailure('invalid_message');
      }
      _receiveSequence++;
      final decoded = jsonDecode(frame);
      if (decoded is! Map<String, dynamic>) {
        close();
        throw const ConnectionFailure('invalid_message');
      }
      return decoded;
    }
    throw const ConnectionFailure('disconnected');
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _cancellation.cancel();
    unawaited(
      _transport
          .post('/v1/meet/leave', {
            'token': _token,
            'attempt': _attempt,
          }, AuxiliaryCancellation())
          .then<void>((_) {}, onError: (Object _) {}),
    );
    onClosed?.call();
  }
}
