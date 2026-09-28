import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
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
  int? activatedLifetimeSeconds;
  bool closed = false;
  bool cancelOnJoin = false;

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
        if (cancelOnJoin) cancellation.cancel();
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
        if (closed) throw const AuxiliaryFailure('entry_unavailable');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        cancellation.throwIfCancelled();
        return {'pending': true};
      case '/v1/meet/activate':
        activatedLifetimeSeconds = int.parse(body['lifetimeSeconds']!);
        active = true;
        return {'active': true};
      case '/v1/meet/leave':
        closed = true;
        return {'closed': true};
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
  final publishedTtls = <String?>[];
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
        publishedTtls.add(body['ttlSeconds']);
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

final class _DelayedLeaveTransport implements AuxiliaryTransport {
  final leaving = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  ) async {
    if (path != '/v1/meet/leave') {
      throw const AuxiliaryFailure('invalid_request');
    }
    leaving.complete();
    await release.future;
    return {'closed': true};
  }
}

void main() {
  test('cancel after accepted meeting join releases the attempt', () async {
    final transport = _MeetingTransport('123456')..cancelOnJoin = true;
    await expectLater(
      MeetingServiceClient(transport)
          .join('123456', cancellation: AuxiliaryCancellation()),
      throwsA(
        isA<AuxiliaryFailure>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
    expect(transport.closed, isTrue);
  });

  test(
    'meeting wire waits briefly for service leave after local close',
    () async {
      final transport = _DelayedLeaveTransport();
      final wire = MeetingConnectionWire(
        transport,
        _MeetingTransport.joinToken,
        _MeetingTransport.attempt,
      );
      final completion = wire.closeAndLeave();
      await transport.leaving.future;
      expect(wire.isClosed, isTrue);
      var completed = false;
      completion.then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      transport.release.complete();
      await completion;
      expect(completed, isTrue);
    },
  );

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

  test(
    're-publishing one offer carries only its original remaining life',
    () async {
      final identity = await DeviceIdentity.fromSeed(List.filled(32, 54));
      var now = 1000000;
      final host = PairingHost(
        identity: identity,
        clock: () async => now,
        onConnection: (_) {},
        protocolVersion: 2,
      );
      addTearDown(host.close);
      await host.open(address: InternetAddress.loopbackIPv4);
      final transport = _LostPublishTransport(identity);
      for (final elapsedSeconds in [0, 200]) {
        now = 1000000 + elapsedSeconds * 1000000;
        await expectLater(
          MeetingServiceClient(transport)
              .publish(host, cancellation: AuxiliaryCancellation()),
          throwsA(isA<AuxiliaryFailure>()),
        );
      }
      expect(transport.publishedTtls, ['300', '100']);
    },
  );

  test('meeting close drains an in-flight host admission', () async {
    final identity = await DeviceIdentity.fromSeed(List.filled(32, 57));
    final clockEntered = Completer<void>();
    final releaseClock = Completer<int>();
    var holdClock = false;
    final host = PairingHost(
      identity: identity,
      clock: () {
        if (!holdClock) return Future.value(1000000);
        if (!clockEntered.isCompleted) clockEntered.complete();
        return releaseClock.future;
      },
      onConnection: (_) {},
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
    final serving = listing.serve();
    for (var tries = 0; !listing.admissionPending; tries++) {
      if (tries == 100) fail('meeting attempt was not admitted');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    holdClock = true;
    var closed = false;
    final closing = listing.close().then((_) => closed = true);
    await clockEntered.future.timeout(const Duration(seconds: 2));
    expect(closed, isFalse);
    releaseClock.complete(1000000);
    await closing;
    await serving;
    expect(closed, isTrue);
    expect(transport.closed, isTrue);
  });

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
    expect(transport.activatedLifetimeSeconds, grantLifetime.inSeconds);
    expect(accepted, hasLength(1));
    expect(client.grant!.binding.policy.type, 'short-code');
    expect(client.peerKey, hostIdentity.encodedKey);
    accepted.single.close();
    await client.whenClosed.timeout(const Duration(seconds: 2));
    expect(client.isClosed, isTrue);
  });

  test(
    'meeting session is bounded by an extensible grant remaining lifetime',
    () async {
      const policy = GrantPolicy(
        type: 'short-code.next',
        lifetime: Duration(hours: 1),
      );
      final hostIdentity = await DeviceIdentity.fromSeed(List.filled(32, 61));
      final clientIdentity = await DeviceIdentity.fromSeed(List.filled(32, 62));
      var hostNow = 1000000;
      final host = PairingHost(
        identity: hostIdentity,
        clock: () async => hostNow += 1000000,
        onConnection: (_) {},
        protocolVersion: 2,
        grantPolicy: policy,
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
            grantPolicy: policy,
          ).connectWithWire(
            () => MeetingServiceClient(transport)
                .join(host.offer!.code, cancellation: AuxiliaryCancellation()),
            host.offer!.code,
          );
      addTearDown(client.close);
      await serving;
      expect(transport.active, isTrue);
      expect(transport.activatedLifetimeSeconds, greaterThan(0));
      expect(
        transport.activatedLifetimeSeconds,
        lessThan(policy.lifetime.inSeconds),
      );
      expect(client.grant!.binding.policy.type, policy.type);
    },
  );

  test(
    'misrouted code cannot authenticate a different receiving host',
    () async {
      final intended = await DeviceIdentity.fromSeed(List.filled(32, 54));
      final other = await DeviceIdentity.fromSeed(List.filled(32, 55));
      final initiator = await DeviceIdentity.fromSeed(List.filled(32, 56));
      final intendedHost = PairingHost(
        identity: intended,
        clock: () async => 1000000,
        onConnection: (_) {},
        protocolVersion: 2,
      );
      final otherConnections = <TrustedConnection>[];
      final wrongHost = PairingHost(
        identity: other,
        clock: () async => 1000000,
        onConnection: otherConnections.add,
        protocolVersion: 2,
      );
      addTearDown(intendedHost.close);
      addTearDown(wrongHost.close);
      await intendedHost.open(address: InternetAddress.loopbackIPv4);
      await wrongHost.open(address: InternetAddress.loopbackIPv4);
      while (wrongHost.offer!.code == intendedHost.offer!.code) {
        await wrongHost.refreshOffer();
      }
      final transport = _MeetingTransport(intendedHost.offer!.code);
      final listing = MeetingListing(
        transport,
        wrongHost,
        _MeetingTransport.hostToken,
        AuxiliaryCancellation(),
      );
      addTearDown(listing.close);
      final serving = listing.serve();
      await expectLater(
        PairingAttempt(
          identity: initiator,
          clock: () async => 1000000,
          protocolVersion: 2,
        ).connectWithWire(
          () => MeetingServiceClient(transport).join(
            intendedHost.offer!.code,
            cancellation: AuxiliaryCancellation(),
          ),
          intendedHost.offer!.code,
        ),
        throwsA(isA<ConnectionFailure>()),
      );
      await listing.close();
      await serving;
      expect(transport.active, isFalse);
      expect(otherConnections, isEmpty);
    },
  );

  test('meeting wire rejects replayed receive sequence and closes', () async {
    final transport = _MeetingTransport('123456');
    final wire = MeetingConnectionWire(
      transport,
      _MeetingTransport.joinToken,
      _MeetingTransport.attempt,
    );
    transport.toJoiner.addAll([
      {'sequence': 0, 'frame': '{"v":2,"type":"hello"}'},
      {'sequence': 0, 'frame': '{"v":2,"type":"replay"}'},
    ]);
    expect((await wire.next())['type'], 'hello');
    await expectLater(
      wire.next(),
      throwsA(
        isA<ConnectionFailure>().having(
          (error) => error.code,
          'code',
          'invalid_message',
        ),
      ),
    );
    expect(wire.isClosed, isTrue);
  });
}
