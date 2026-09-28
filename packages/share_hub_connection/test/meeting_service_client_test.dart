import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:test/test.dart';

final class _MeetingTransport implements AuxiliaryTransport {
  _MeetingTransport(this.code);
  final String code;
  static final hostToken = base64Token(32, 1);
  static final joinToken = base64Token(32, 2);
  static final attempt = base64Token(16, 3);
  final toHost = <Map<String, Object?>>[];
  final toJoiner = <Map<String, Object?>>[];
  bool active = false;

  static String base64Token(int count, int value) =>
      base64Url.encode(List<int>.filled(count, value));

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  ) async {
    cancellation.throwIfCancelled();
    switch (path) {
      case '/v1/meet/join':
        if (body['code'] != code) {
          throw const AuxiliaryFailure('entry_unavailable');
        }
        return {'attempt': attempt, 'token': joinToken};
      case '/v1/meet/pending':
        return {
          'attempts': [attempt],
        };
      case '/v1/meet/send':
        final target = body['token'] == hostToken ? toJoiner : toHost;
        target.add({
          'sequence': int.parse(body['sequence']!),
          'frame': body['frame']!,
        });
        return {'accepted': true};
      case '/v1/meet/poll':
        final source = body['token'] == hostToken ? toHost : toJoiner;
        if (source.isNotEmpty) return source.removeAt(0);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        cancellation.throwIfCancelled();
        return {'pending': true};
      case '/v1/meet/activate':
        active = true;
        return {'active': true};
      case '/v1/meet/leave':
      case '/v1/meet/unpublish':
        return {'closed': true};
      default:
        throw const AuxiliaryFailure('invalid_request');
    }
  }
}

final class _LostPublishTransport implements AuxiliaryTransport {
  _LostPublishTransport(this.identity);
  final DeviceIdentity identity;
  String? publishedOffer;
  bool withdrawn = false;

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  ) async {
    cancellation.throwIfCancelled();
    switch (path) {
      case '/v1/aux/challenge':
        return {
          'nonce': _MeetingTransport.base64Token(32, 4),
          'expiresAt': 1800000030,
        };
      case '/v1/devices/register':
        return {'deviceId': identity.id};
      case '/v1/meet/publish':
        publishedOffer = body['offerId'];
        throw const AuxiliaryFailure('cancelled');
      case '/v1/meet/unpublish-owned':
        if (body['offerId'] != publishedOffer) {
          throw const AuxiliaryFailure('entry_unavailable');
        }
        withdrawn = true;
        return {'closed': true};
      default:
        throw const AuxiliaryFailure('invalid_request');
    }
  }
}

void main() {
  test(
    'lost publish response withdraws the exact offer by holder proof',
    () async {
      final identity = await DeviceIdentity.fromSeed(List.filled(32, 53));
      final host = PairingHost(
        identity: identity,
        clock: () async => 1000000,
        onConnection: (_) {},
        protocolVersion: 2,
      );
      addTearDown(host.close);
      await host.open(address: InternetAddress.loopbackIPv4);
      final transport = _LostPublishTransport(identity);
      await expectLater(
        MeetingServiceClient(transport)
            .publish(host, cancellation: AuxiliaryCancellation()),
        throwsA(isA<AuxiliaryFailure>()),
      );
      expect(transport.publishedOffer, host.offer!.id);
      expect(transport.withdrawn, isTrue);
    },
  );

  test('meeting wire carries the real v2 PAKE and grant activation', () async {
    final hostIdentity = await DeviceIdentity.fromSeed(List.filled(32, 51));
    final clientIdentity = await DeviceIdentity.fromSeed(List.filled(32, 52));
    final accepted = <TrustedConnection>[];
    final host = PairingHost(
      identity: hostIdentity,
      clock: () async => 1000000,
      onConnection: accepted.add,
      protocolVersion: 2,
    );
    addTearDown(host.close);
    await host.open(address: InternetAddress.loopbackIPv4);
    final transport = _MeetingTransport(host.offer!.code);
    final listing = MeetingListing(
      transport,
      host,
      _MeetingTransport.hostToken,
      AuxiliaryCancellation(),
    );
    addTearDown(listing.close);
    final serving = listing.serve();
    final client =
        await PairingAttempt(
          identity: clientIdentity,
          clock: () async => 1000000,
          protocolVersion: 2,
        ).connectWithWire(
          () => MeetingServiceClient(transport)
              .join(host.offer!.code, cancellation: AuxiliaryCancellation()),
          host.offer!.code,
        );
    addTearDown(client.close);
    await serving;
    expect(transport.active, isTrue);
    expect(accepted, hasLength(1));
    expect(client.grant!.binding.policy.type, 'short-code');
    expect(client.peerKey, hostIdentity.encodedKey);
  });
}
