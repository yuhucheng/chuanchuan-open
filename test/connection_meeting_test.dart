import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_open/features/connections/auxiliary_route_controller.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/connections/connection_panel.dart';

final class _Platform implements ConnectionPlatform {
  _Platform(this.device, {this.failAdvertisement = false});
  final DeviceIdentity device;
  final bool failAdvertisement;
  int time = 1000000;
  @override
  Future<DeviceIdentity> identity() async => device;
  @override
  Future<int> now() async => time;
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
  final extraAttempt = token(16, 5);
  final toHost = <Map<String, Object?>>[];
  final toJoiner = <Map<String, Object?>>[];
  String? code;
  bool activated = false;
  int publishFailures = 0;
  int publishAttempts = 0;
  Completer<void>? publishGate;
  final publishStarted = Completer<void>();
  final publishedTtls = <String?>[];
  int pendingFailures = 0;
  int forgottenListings = 0;
  void Function()? onForget;
  bool publishCollision = false;
  Completer<void>? joinGate;
  final joinStarted = Completer<void>();
  Completer<void>? hostLeaveGate;
  final hostLeaveStarted = Completer<void>();
  Completer<void>? extraPollGate;
  final extraPollStarted = Completer<void>();

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
        publishAttempts++;
        if (!publishStarted.isCompleted) publishStarted.complete();
        await publishGate?.future;
        cancellation.throwIfCancelled();
        publishedTtls.add(body['ttlSeconds']);
        if (publishCollision) {
          throw const AuxiliaryFailure('entry_unavailable');
        }
        if (publishFailures > 0) {
          publishFailures--;
          throw const AuxiliaryFailure('unreachable');
        }
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
        if (forgottenListings > 0) {
          forgottenListings--;
          code = null;
          onForget?.call();
          throw const AuxiliaryFailure('entry_unavailable');
        }
        if (pendingFailures > 0) {
          pendingFailures--;
          throw const AuxiliaryFailure('unreachable');
        }
        if (activated) throw const AuxiliaryFailure('entry_unavailable');
        return {
          'attempts': code == null
              ? <String>[]
              : [attempt, if (extraPollGate != null) extraAttempt],
        };
      case '/v1/meet/send':
        final target = body['token'] == hostToken ? toJoiner : toHost;
        target.add({
          'sequence': int.parse(body['sequence']!),
          'frame': body['frame']!,
        });
        return {'accepted': true};
      case '/v1/meet/poll':
        if (body['attempt'] == extraAttempt &&
            body['token'] == hostToken &&
            extraPollGate != null) {
          if (!extraPollStarted.isCompleted) extraPollStarted.complete();
          await extraPollGate!.future;
          cancellation.throwIfCancelled();
        }
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
        code = null;
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
  testWidgets('connection panel distinguishes local code from WAN readiness', (
    tester,
  ) async {
    final identity = await DeviceIdentity.fromSeed(List.filled(32, 69));
    final controller = ConnectionController(_Platform(identity))
      ..code = '123456'
      ..meetingPublication = MeetingPublication.publishing;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ConnectionPanel(controller: controller)),
      ),
    );
    expect(find.textContaining('跨网会合正在准备'), findsOneWidget);
    controller.meetingPublication = MeetingPublication.ready;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ConnectionPanel(controller: controller)),
      ),
    );
    expect(find.textContaining('跨网会合已就绪'), findsOneWidget);
  });

  test('displayed local code reports WAN publication truthfully', () async {
    final identity = await DeviceIdentity.fromSeed(List.filled(32, 68));
    final service = _MeetingService(identity)..publishGate = Completer<void>();
    final route = AuxiliaryRouteController(
      identity: () async => identity,
      officialOrigin: 'https://selected.example',
      store: _Store(),
      transportFactory: (_) => (transport: service, close: () {}),
    );
    final host = ConnectionController(
      _Platform(identity),
      auxiliaryRoutes: route,
    );
    addTearDown(() async {
      await host.disconnectAll();
      await route.stop();
      host.dispose();
    });
    await host.open();
    await service.publishStarted.future;
    expect(host.code, isNotNull);
    expect(host.meetingPublication, MeetingPublication.publishing);
    final ready = Completer<void>();
    void onPublicationChanged() {
      if (host.meetingPublication == MeetingPublication.ready &&
          !ready.isCompleted) {
        ready.complete();
      }
    }
    host.addListener(onPublicationChanged);
    addTearDown(() => host.removeListener(onPublicationChanged));
    service.publishGate!.complete();
    await ready.future.timeout(const Duration(seconds: 2));
    expect(host.meetingPublication, MeetingPublication.ready);
    await host.stopAccepting();
    expect(host.meetingPublication, MeetingPublication.none);
    expect(host.code, isNull);
  });

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
      var finished = false;
      final stopping = routes.stop().then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      service.releaseLeave.complete();
      await stopping;
      expect(service.transportClosed, isTrue);
      expect(finished, isTrue);
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
      final service = _MeetingService(hostIdentity)
        ..extraPollGate = Completer<void>();
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
      await service.extraPollStarted.future.timeout(const Duration(seconds: 2));

      // A second admission may still be unwinding when the established wire
      // closes. The HTTPS owner must drain both before disposing transport.
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
      await Future<void>.delayed(Duration.zero);
      expect(hostTransportClosed, isFalse);
      service.extraPollGate!.complete();
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
    'transient meeting publish failure retries the same live offer',
    () async {
      final hostIdentity = await DeviceIdentity.fromSeed(List.filled(32, 74));
      final clientIdentity = await DeviceIdentity.fromSeed(List.filled(32, 75));
      final service = _MeetingService(hostIdentity)..publishFailures = 1;
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
        meetingRetryBackoff: const [Duration(milliseconds: 20)],
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
      final originalCode = host.code;
      for (var i = 0; i < 100 && service.code == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(service.publishAttempts, 2);
      expect(service.code, originalCode);
      expect(host.message, contains('会合入口已恢复'));
      expect(await client.connectByCode(originalCode!), isNotNull);
      expect(
        host.sessions.single.grant!.binding.encodedId,
        client.sessions.single.grant!.binding.encodedId,
      );
    },
  );

  test('closing admission cancels a pending meeting retry', () async {
    final identity = await DeviceIdentity.fromSeed(List.filled(32, 76));
    final service = _MeetingService(identity)..publishFailures = 100;
    final route = AuxiliaryRouteController(
      identity: () async => identity,
      officialOrigin: 'https://selected.example',
      store: _Store(),
      transportFactory: (_) => (transport: service, close: () {}),
    );
    final host = ConnectionController(
      _Platform(identity),
      auxiliaryRoutes: route,
      meetingRetryBackoff: const [Duration(milliseconds: 100)],
    );
    addTearDown(() async {
      await host.disconnectAll();
      await route.stop();
      host.dispose();
    });
    await host.open();
    for (var i = 0; i < 100 && service.publishAttempts == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(service.publishAttempts, 1);
    expect(host.meetingPublication, MeetingPublication.retrying);
    await host.stopAccepting();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(service.publishAttempts, 1);
    expect(host.code, isNull);
    expect(host.meetingPublication, MeetingPublication.none);
  });

  test('meeting poll failure retries while the same offer is valid', () async {
    final identity = await DeviceIdentity.fromSeed(List.filled(32, 78));
    final service = _MeetingService(identity)..pendingFailures = 1;
    final routes = AuxiliaryRouteController(
      identity: () async => identity,
      officialOrigin: 'https://official.example',
      store: _Store(),
      transportFactory: (_) => (transport: service, close: () {}),
    );
    final host = ConnectionController(
      _Platform(identity),
      auxiliaryRoutes: routes,
      meetingRetryBackoff: const [Duration(milliseconds: 20)],
    );
    addTearDown(() async {
      await host.disconnectAll();
      await routes.stop();
      host.dispose();
    });
    await host.open();
    final originalCode = host.code;
    for (var i = 0; i < 100 && service.publishAttempts < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(service.publishAttempts, 2);
    expect(host.code, originalCode);
    expect(host.message, contains('会合入口已恢复'));
  });

  test(
    'lost listing after service restart republishes the same code',
    () async {
      final identity = await DeviceIdentity.fromSeed(List.filled(32, 76));
      final service = _MeetingService(identity)..forgottenListings = 1;
      final platform = _Platform(identity);
      service.onForget = () => platform.time += 200000000;
      final routes = AuxiliaryRouteController(
        identity: () async => identity,
        officialOrigin: 'https://official.example',
        store: _Store(),
        transportFactory: (_) => (transport: service, close: () {}),
      );
      final host = ConnectionController(
        platform,
        auxiliaryRoutes: routes,
        meetingRetryBackoff: const [Duration(milliseconds: 20)],
      );
      addTearDown(() async {
        await host.disconnectAll();
        await routes.stop();
        host.dispose();
      });
      await host.open();
      final originalCode = host.code;
      for (var i = 0; i < 100 && service.publishAttempts < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(service.publishAttempts, 2);
      expect(service.publishedTtls, ['300', '100']);
      expect(service.code, originalCode);
      expect(host.code, originalCode);
      expect(host.message, contains('会合入口已恢复'));
    },
  );

  test(
    'initial code collision does not retry the same unavailable code',
    () async {
      final identity = await DeviceIdentity.fromSeed(List.filled(32, 75));
      final service = _MeetingService(identity)..publishCollision = true;
      final routes = AuxiliaryRouteController(
        identity: () async => identity,
        officialOrigin: 'https://official.example',
        store: _Store(),
        transportFactory: (_) => (transport: service, close: () {}),
      );
      final host = ConnectionController(
        _Platform(identity),
        auxiliaryRoutes: routes,
        meetingRetryBackoff: const [Duration(milliseconds: 20)],
      );
      addTearDown(() async {
        await host.disconnectAll();
        await routes.stop();
        host.dispose();
      });
      await host.open();
      for (var i = 0; i < 100 && service.publishAttempts == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(service.publishAttempts, 1);
      expect(host.message, contains('会合失败'));
      expect(host.meetingPublication, MeetingPublication.failed);
    },
  );

  test('switching the selected origin cancels the old meeting retry', () async {
    final identity = await DeviceIdentity.fromSeed(List.filled(32, 77));
    final oldService = _MeetingService(identity)..publishFailures = 100;
    final newService = _MeetingService(identity);
    final routes = AuxiliaryRouteController(
      identity: () async => identity,
      officialOrigin: 'https://official.example',
      store: _Store(),
      transportFactory: (origin) => (
        transport: origin.host == 'official.example' ? oldService : newService,
        close: () {},
      ),
    );
    final host = ConnectionController(
      _Platform(identity),
      auxiliaryRoutes: routes,
      meetingRetryBackoff: const [Duration(milliseconds: 100)],
    );
    addTearDown(() async {
      await host.disconnectAll();
      await routes.stop();
      host.dispose();
    });
    await host.open();
    for (var i = 0; i < 100 && oldService.publishAttempts == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(oldService.publishAttempts, 1);
    final oldCode = host.code;
    await routes.select(
      const AuxiliaryRouteChoice(
        AuxiliaryRouteMode.custom,
        'https://lan.example',
      ),
    );
    for (var i = 0; i < 100 && newService.code == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(oldService.publishAttempts, 1);
    expect(newService.code, isNotNull);
    expect(host.code, newService.code);
    expect(host.code, isNot(oldCode));
  });

  test(
    'switching origin withdraws a published code before republishing',
    () async {
      final identity = await DeviceIdentity.fromSeed(List.filled(32, 79));
      final oldService = _MeetingService(identity);
      final newService = _MeetingService(identity);
      final routes = AuxiliaryRouteController(
        identity: () async => identity,
        officialOrigin: 'https://official.example',
        store: _Store(),
        transportFactory: (origin) => (
          transport: origin.host == 'official.example'
              ? oldService
              : newService,
          close: () {},
        ),
      );
      final host = ConnectionController(
        _Platform(identity),
        auxiliaryRoutes: routes,
      );
      addTearDown(() async {
        await host.disconnectAll();
        await routes.stop();
        host.dispose();
      });
      await host.open();
      for (var i = 0; i < 100 && oldService.code == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final oldCode = host.code;
      expect(oldService.code, oldCode);
      await routes.select(
        const AuxiliaryRouteChoice(
          AuxiliaryRouteMode.custom,
          'http://invalid.example',
        ),
      );
      expect(host.code, oldCode);
      expect(oldService.code, oldCode);
      expect(newService.code, isNull);
      await routes.select(
        const AuxiliaryRouteChoice(
          AuxiliaryRouteMode.custom,
          'https://lan.example',
        ),
      );
      for (var i = 0; i < 100 && newService.code == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(oldService.code, isNull);
      expect(newService.code, isNotNull);
      expect(host.code, newService.code);
      expect(host.code, isNot(oldCode));
    },
  );

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
