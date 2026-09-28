import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_open/features/connections/auxiliary_route_controller.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';

final class _Platform implements ConnectionPlatform {
  _Platform(this.device, {this.failAdvertisement = false});
  final DeviceIdentity device;
  final bool failAdvertisement;
  @override
  Future<DeviceIdentity> identity() async => device;
  @override
  Future<int> now() async => 1000000;
  @override
  Future<String?> advertise(int? port, String? key) async {
    if (port != null && failAdvertisement) {
      throw StateError('local discovery unavailable');
    }
    return null;
  }
}

final class _Store implements AuxiliaryRouteStore {
  @override
  Future<AuxiliaryRouteChoice?> read() async => null;
  @override
  Future<void> write(AuxiliaryRouteChoice choice) async {}
}

final class _MeetingService implements AuxiliaryTransport {
  _MeetingService(this.host);
  final DeviceIdentity host;
  static String token(int length, int value) =>
      base64Url.encode(List<int>.filled(length, value));
  final hostToken = token(32, 1);
  final joinToken = token(32, 2);
  final attempt = token(16, 3);
  final toHost = <Map<String, Object?>>[];
  final toJoiner = <Map<String, Object?>>[];
  String? code;
  bool activated = false;
  Completer<void>? joinGate;
  final joinStarted = Completer<void>();
  Completer<void>? hostLeaveGate;
  final hostLeaveStarted = Completer<void>();

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  ) async {
    cancellation.throwIfCancelled();
    switch (path) {
      case '/v1/aux/challenge':
        return {'nonce': token(32, 4), 'expiresAt': 1800000030};
      case '/v1/devices/register':
        return {'deviceId': host.id};
      case '/v1/meet/publish':
        code = body['code'];
        return {'token': hostToken, 'expiresInSeconds': 300};
      case '/v1/meet/join':
        if (!joinStarted.isCompleted) joinStarted.complete();
        await joinGate?.future;
        cancellation.throwIfCancelled();
        if (body['code'] != code) {
          throw const AuxiliaryFailure('entry_unavailable');
        }
        return {'attempt': attempt, 'token': joinToken};
      case '/v1/meet/pending':
        if (activated) throw const AuxiliaryFailure('entry_unavailable');
        return {
          'attempts': code == null ? <String>[] : [attempt],
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
        activated = true;
        code = null;
        return {'active': true};
      case '/v1/meet/leave':
        if (body['token'] == hostToken && hostLeaveGate != null) {
          if (!hostLeaveStarted.isCompleted) hostLeaveStarted.complete();
          await hostLeaveGate!.future;
        }
        return {'closed': true};
      case '/v1/meet/unpublish':
        return {'closed': true};
      default:
        throw const AuxiliaryFailure('invalid_request');
    }
  }
}

final class _DelayedLeaveService implements AuxiliaryTransport {
  final leaveStarted = Completer<void>();
  final releaseLeave = Completer<void>();
  bool transportClosed = false;

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  ) async {
    if (path == '/v1/meet/join') {
      return {
        'attempt': _MeetingService.token(16, 3),
        'token': _MeetingService.token(32, 2),
      };
    }
    if (path == '/v1/meet/leave') {
      leaveStarted.complete();
      await releaseLeave.future;
      if (transportClosed) throw const AuxiliaryFailure('unreachable');
      return {'closed': true};
    }
    throw const AuxiliaryFailure('invalid_request');
  }
}

void main() {
  test(
    'closing a joined meeting keeps HTTPS alive until leave completes',
    () async {
      final identity = await DeviceIdentity.fromSeed(List.filled(32, 66));
      final service = _DelayedLeaveService();
      final routes = AuxiliaryRouteController(
        identity: () async => identity,
        officialOrigin: 'https://selected.example',
        store: _Store(),
        transportFactory: (_) =>
            (transport: service, close: () => service.transportClosed = true),
      );
      final wire = await routes.openMeetingWire(
        '123456',
        AuxiliaryCancellation(),
      );
      wire.close();
      await service.leaveStarted.future.timeout(const Duration(seconds: 2));
      expect(wire.isClosed, isTrue);
      expect(service.transportClosed, isFalse);
      service.releaseLeave.complete();
      for (var i = 0; i < 100 && !service.transportClosed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(service.transportClosed, isTrue);
      await routes.stop();
    },
  );

  test('process stop waits for the selected meeting leave', () async {
    final identity = await DeviceIdentity.fromSeed(List.filled(32, 67));
    final service = _DelayedLeaveService();
    var transports = 0;
    final routes = AuxiliaryRouteController(
      identity: () async => identity,
      officialOrigin: 'https://selected.example',
      store: _Store(),
      transportFactory: (_) {
        final index = ++transports;
        return (
          transport: service,
          close: () {
            if (index == 2) service.transportClosed = true;
          },
        );
      },
    );
    final wire = await routes.openMeetingWire(
      '123456',
      AuxiliaryCancellation(),
    );
    var finished = false;
    final stopping = routes.stop().then((_) => finished = true);
    await service.leaveStarted.future.timeout(const Duration(seconds: 2));
    expect(wire.isClosed, isTrue);
    expect(service.transportClosed, isFalse);
    expect(finished, isFalse);
    service.releaseLeave.complete();
    await stopping;
    expect(service.transportClosed, isTrue);
    expect(finished, isTrue);
    await routes.stop();
  });

  test(
    'two new clients connect by six digits when local discovery fails',
    () async {
      final hostIdentity = await DeviceIdentity.fromSeed(List.filled(32, 61));
      final clientIdentity = await DeviceIdentity.fromSeed(List.filled(32, 62));
      final service = _MeetingService(hostIdentity);
      var hostTransportClosed = false;

      AuxiliaryRouteController route(DeviceIdentity identity) =>
          AuxiliaryRouteController(
            identity: () async => identity,
            officialOrigin: 'https://selected.example',
            store: _Store(),
            transportFactory: (_) => (
              transport: service,
              close: () {
                if (identical(identity, hostIdentity)) {
                  hostTransportClosed = true;
                }
              },
            ),
          );

      final hostRoute = route(hostIdentity);
      final clientRoute = route(clientIdentity);
      final host = ConnectionController(
        _Platform(hostIdentity, failAdvertisement: true),
        auxiliaryRoutes: hostRoute,
      );
      final client = ConnectionController(
        _Platform(clientIdentity),
        auxiliaryRoutes: clientRoute,
      );
      addTearDown(() async {
        await client.disconnectAll();
        await host.disconnectAll();
        await clientRoute.stop();
        await hostRoute.stop();
        client.dispose();
        host.dispose();
      });
      await host.open();
      for (var i = 0; i < 100 && service.code == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(service.code, host.code);
      expect(host.accepting, isTrue);
      expect(host.problem, contains('局域网自动发现不可用'));
      final connection = await client.connectByCode(host.code!);
      expect(connection, isNotNull);
      expect(service.activated, isTrue);
      expect(client.sessions.single.peerKey, hostIdentity.encodedKey);
      expect(host.sessions.single.peerKey, clientIdentity.encodedKey);
      expect(
        client.sessions.single.grant!.binding.encodedId,
        host.sessions.single.grant!.binding.encodedId,
      );

      // Closing the active host connection must allow its leave to reach the
      // service before disposing the HTTPS owner; local authority ends first.
      service.hostLeaveGate = Completer<void>();
      final hostConnection = host.sessions.single;
      hostConnection.close();
      try {
        await service.hostLeaveStarted.future.timeout(
          const Duration(seconds: 2),
        );
        expect(hostConnection.isClosed, isTrue);
        expect(hostTransportClosed, isFalse);
      } finally {
        service.hostLeaveGate!.complete();
      }
      for (var i = 0; i < 100 && !hostTransportClosed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(hostTransportClosed, isTrue);
    },
  );

  test('meeting fallback binds the discovered peer identity', () async {
    final hostIdentity = await DeviceIdentity.fromSeed(List.filled(32, 71));
    final clientIdentity = await DeviceIdentity.fromSeed(List.filled(32, 72));
    final otherIdentity = await DeviceIdentity.fromSeed(List.filled(32, 73));
    final service = _MeetingService(hostIdentity);
    AuxiliaryRouteController route(DeviceIdentity identity) =>
        AuxiliaryRouteController(
          identity: () async => identity,
          officialOrigin: 'https://selected.example',
          store: _Store(),
          transportFactory: (_) => (transport: service, close: () {}),
        );
    final hostRoute = route(hostIdentity);
    final clientRoute = route(clientIdentity);
    final host = ConnectionController(
      _Platform(hostIdentity),
      auxiliaryRoutes: hostRoute,
    );
    final client = ConnectionController(
      _Platform(clientIdentity),
      auxiliaryRoutes: clientRoute,
    );
    addTearDown(() async {
      await client.disconnectAll();
      await host.disconnectAll();
      await clientRoute.stop();
      await hostRoute.stop();
      client.dispose();
      host.dispose();
    });
    await host.open();
    for (var i = 0; i < 100 && service.code == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(service.code, host.code);
    final result = await client.connectByCode(
      host.code!,
      expectedPeerKey: otherIdentity.encodedKey,
    );
    expect(result, isNull);
    expect(client.lastConnectionFailureCode, 'identity_mismatch');
    expect(client.problem, contains('身份与所选设备不一致'));
    expect(client.sessions, isEmpty);
    expect(host.sessions, isEmpty);
  });

  test(
    'switching the selected origin cancels an in-flight code join',
    () async {
      final clientIdentity = await DeviceIdentity.fromSeed(List.filled(32, 64));
      final service = _MeetingService(clientIdentity)
        ..joinGate = Completer<void>();
      final routes = AuxiliaryRouteController(
        identity: () async => clientIdentity,
        officialOrigin: 'https://official.example',
        store: _Store(),
        transportFactory: (_) => (transport: service, close: () {}),
      );
      final client = ConnectionController(
        _Platform(clientIdentity),
        auxiliaryRoutes: routes,
      );
      addTearDown(() async {
        await client.disconnectAll();
        await routes.stop();
        client.dispose();
      });
      final pending = client.connectByCode('123456');
      await service.joinStarted.future.timeout(const Duration(seconds: 5));
      await routes.select(
        const AuxiliaryRouteChoice(
          AuxiliaryRouteMode.custom,
          'https://lan.example',
        ),
      );
      service.joinGate!.complete();
      expect(await pending, isNull);
      expect(client.sessions, isEmpty);
      expect(routes.choice.mode, AuxiliaryRouteMode.custom);
    },
  );
}
