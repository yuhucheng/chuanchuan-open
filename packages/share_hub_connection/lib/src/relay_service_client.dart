import 'dart:async';

import 'package:share_hub_session_api/share_hub_session_api.dart';

import 'auxiliary_service.dart';
import 'identity.dart';
import 'relay_room_claim.dart';
import 'relay_signal_envelope.dart';

/// Opens a relay only from a process-owned grant. A claim or service response
/// cannot manufacture end-to-end authorization; callers must open sealed bodies
/// through their own GrantEndpoint before using operation data.
final class RelayServiceClient {
  const RelayServiceClient(this.transport);
  final AuxiliaryTransport transport;

  Future<RelaySignalChannel> open(
    GrantEndpoint grant,
    DeviceIdentity identity, {
    required AuxiliaryCancellation cancellation,
  }) async {
    cancellation.throwIfCancelled();
    await grant.checkValidity();
    final binding = grant.binding;
    final selfKey = grant.role == GrantRole.initiator
        ? binding.initiatorKey
        : binding.receiverKey;
    if (encodeBytes(selfKey) != identity.encodedKey) {
      throw const AuxiliaryFailure('identity_mismatch');
    }
    final claim = RelayRoomClaim.fromBinding(binding, grant.generation);
    await AuxiliaryServiceClient(transport)
        .register(identity, cancellation: cancellation);
    cancellation.throwIfCancelled();
    await grant.checkValidity();
    final challenged = await transport.post('/v1/signal/challenge', {
      'claim': claim.encode(),
      'sender': identity.encodedKey,
    }, cancellation);
    if (challenged.length != 1 || challenged['nonce'] is! String) {
      throw const AuxiliaryFailure('invalid_response');
    }
    late final List<int> nonce;
    try {
      nonce = decodeBytes(challenged['nonce'], 32);
    } on ConnectionFailure {
      throw const AuxiliaryFailure('invalid_response');
    }
    final signature = await claim.signJoin(identity, nonce);
    cancellation.throwIfCancelled();
    await grant.checkValidity();
    final joined = await transport.post('/v1/signal/join', {
      'claim': claim.encode(),
      'sender': identity.encodedKey,
      'nonce': challenged['nonce'] as String,
      'signature': signature,
    }, cancellation);
    final room = joined['room'],
        token = joined['token'],
        ready = joined['ready'];
    if (joined.length != 3 ||
        room is! String ||
        token is! String ||
        ready is! bool ||
        room != encodeBytes(claim.roomId)) {
      throw const AuxiliaryFailure('invalid_response');
    }
    try {
      decodeBytes(token, 32);
    } on ConnectionFailure {
      throw const AuxiliaryFailure('invalid_response');
    }
    final channel = RelaySignalChannel._(
      transport,
      grant,
      claim,
      identity,
      room,
      token,
      cancellation,
    );
    try {
      await grant.checkValidity();
      cancellation.throwIfCancelled();
      return channel;
    } catch (_) {
      await channel.close();
      rethrow;
    }
  }
}

/// One generation's ordered, cancellable signaling path. Only opaque sealed
/// bytes cross this boundary. Reopening needs a newly proved room/generation.
final class RelaySignalChannel {
  RelaySignalChannel._(
    this._transport,
    this._grant,
    this.claim,
    this._identity,
    this.room,
    this._token,
    this._cancellation,
  ) : _inbox = RelaySignalInbox(
        room: claim.roomId,
        sender:
            encodeBytes(_identity.publicKey.bytes) ==
                encodeBytes(claim.initiator)
            ? claim.receiver
            : claim.initiator,
        generation: claim.generation,
      ) {
    _invalidations = _grant.invalidated.listen((_) {
      _cancellation.cancel();
      unawaited(close());
    });
  }

  final AuxiliaryTransport _transport;
  final GrantEndpoint _grant;
  final DeviceIdentity _identity;
  final AuxiliaryCancellation _cancellation;
  final RelaySignalInbox _inbox;
  final RelayRoomClaim claim;
  final String room, _token;
  late final StreamSubscription<void> _invalidations;
  int _sequence = 0;
  bool _closed = false, _left = false, _sending = false, _receiving = false;

  bool get closed => _closed || _cancellation.isCancelled;

  Future<void> sendSealed(List<int> sealed) async {
    if (closed || _sending) throw const AuxiliaryFailure('cancelled');
    await _grant.checkValidity();
    _cancellation.throwIfCancelled();
    _sending = true;
    try {
      final wire = RelaySignalEnvelope(
        room: claim.roomId,
        sender: _identity.publicKey.bytes,
        generation: claim.generation,
        sequence: _sequence,
        kind: RelaySignalKind.data,
        payload: sealed,
      ).encode();
      final response = await _transport.post('/v1/signal/send', {
        'room': room,
        'token': _token,
        'wire': wire,
      }, _cancellation);
      _cancellation.throwIfCancelled();
      await _grant.checkValidity();
      if (response.length != 1 || response['accepted'] != true) {
        throw const AuxiliaryFailure('invalid_response');
      }
      _sequence++;
    } catch (_) {
      // A lost acknowledgement makes the next sequence ambiguous. Never reuse
      // this channel or guess whether the server accepted the ciphertext.
      // Leave with a fresh cancellation token so a cancelled request cannot
      // strand a live server room until its TTL expires.
      await close();
      rethrow;
    } finally {
      _sending = false;
    }
  }

  Future<RelaySignalEnvelope?> receive() async {
    if (closed || _receiving) throw const AuxiliaryFailure('cancelled');
    await _grant.checkValidity();
    _cancellation.throwIfCancelled();
    _receiving = true;
    try {
      final response = await _transport.post('/v1/signal/poll', {
        'room': room,
        'token': _token,
      }, _cancellation);
      _cancellation.throwIfCancelled();
      await _grant.checkValidity();
      if (response.length != 2 ||
          response['ready'] is! bool ||
          response['wire'] is! String) {
        throw const AuxiliaryFailure('invalid_response');
      }
      final wire = response['wire'] as String;
      if (wire.isEmpty) return null;
      final envelope = RelaySignalEnvelope.decode(wire);
      _inbox.accept(envelope);
      if (envelope.kind == RelaySignalKind.cancel) {
        await close();
      }
      return envelope;
    } catch (_) {
      await close();
      rethrow;
    } finally {
      _receiving = false;
    }
  }

  /// Local cancellation is immediate. A best-effort terminal envelope informs
  /// the peer if no other send is in flight; expiry still bounds lost notices.
  Future<void> cancel() async {
    if (closed) return;
    _closed = true;
    if (_sending) {
      _cancellation.cancel();
      await _invalidations.cancel();
      return;
    }
    try {
      final wire = RelaySignalEnvelope(
        room: claim.roomId,
        sender: _identity.publicKey.bytes,
        generation: claim.generation,
        sequence: _sequence,
        kind: RelaySignalKind.cancel,
        payload: const [],
      ).encode();
      await _transport.post('/v1/signal/send', {
        'room': room,
        'token': _token,
        'wire': wire,
      }, _cancellation);
    } catch (_) {
      // The local stop is already final; relay expiry closes an undelivered
      // notice, and endpoint authorization never depends on this response.
    } finally {
      _cancellation.cancel();
      await _invalidations.cancel();
    }
  }

  Future<void> close() async {
    if (_left) return;
    _left = true;
    _closed = true;
    _cancellation.cancel();
    try {
      await _transport.post('/v1/signal/leave', {
        'room': room,
        'token': _token,
      }, AuxiliaryCancellation());
    } catch (_) {
      // Server-side room TTL is a second cleanup boundary.
    } finally {
      _cancellation.cancel();
      await _invalidations.cancel();
    }
  }
}
