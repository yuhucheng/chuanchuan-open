import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/auxiliary_route_controller.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';

final class _Platform implements ConnectionPlatform {
  _Platform(this.device);
  final DeviceIdentity device;
  int time = 1000000;
  int? port;
  @override
  Future<DeviceIdentity> identity() async => device;
  @override
  Future<int> now() async => time;
  @override
  Future<String?> advertise(int? value, String? key) async {
    if (value != null) port = value;
    return 'test.local';
  }
}

final class _Store implements AuxiliaryRouteStore {
  _Store(this.initial);
  final AuxiliaryRouteChoice initial;
  @override
  Future<AuxiliaryRouteChoice?> read() async => initial;
  @override
  Future<void> write(AuxiliaryRouteChoice choice) async {}
}

final class _Relay implements AuxiliaryTransport {
  _Relay(this.identities);
  final List<DeviceIdentity> identities;
  final nonce = base64Url.encode(List<int>.generate(32, (i) => i));
  final members = <String, String>{};
  final queues = <String, List<String>>{};
  int forwarded = 0;
  bool failPoll = false;
  bool failChallenge = false;

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  ) async {
    cancellation.throwIfCancelled();
    if (path == '/v1/aux/challenge') {
      return {'nonce': nonce, 'expiresAt': 1};
    }
    if (path == '/v1/devices/register') {
      final member = identities.singleWhere(
        (candidate) => candidate.encodedKey == body['publicKey'],
      );
      return {'deviceId': member.id};
    }
    if (path == '/v1/signal/challenge') {
      if (failChallenge) throw const AuxiliaryFailure('unreachable');
      return {'nonce': nonce};
    }
    if (path == '/v1/signal/join') {
      final claim = RelayRoomClaim.decode(body['claim']!);
      final token = base64Url.encode(List<int>.filled(32, members.length + 1));
      members[token] = body['sender']!;
      queues[token] = [];
      return {
        'room': base64Url.encode(claim.roomId),
        'token': token,
        'ready': members.length == 2,
      };
    }
    if (path == '/v1/signal/send') {
      final peer = members.keys.singleWhere((key) => key != body['token']);
      queues[peer]!.add(body['wire']!);
      forwarded++;
      return {'accepted': true};
    }
    if (path == '/v1/signal/poll') {
      if (failPoll) throw const AuxiliaryFailure('unreachable');
      final queue = queues[body['token']]!;
      if (queue.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      return {
        'ready': members.length == 2,
        'wire': queue.isEmpty ? '' : queue.removeAt(0),
      };
    }
    if (path == '/v1/signal/leave') {
      members.clear();
      queues.clear();
      return {'closed': true};
    }
    throw StateError(path);
  }
}

final class _Proxy {
  late ServerSocket server;
  final sockets = <Socket>[];
  bool closed = false;

  Future<void> start(int target) async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((client) async {
      sockets.add(client);
      final remote = await Socket.connect('127.0.0.1', target);
      sockets.add(remote);
      client.listen(remote.add, onDone: remote.destroy);
      remote.listen(client.add, onDone: client.destroy);
    });
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    cut();
    await server.close();
  }

  void cut() {
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
  }
}

Future<void> _until(bool Function() ready) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    if (watch.elapsed > const Duration(seconds: 5)) {
      fail('Recovery did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('official failure keeps local recovery; selected custom relay restores next loss', () async {
    final alice = await DeviceIdentity.fromSeed(List<int>.filled(32, 81));
    final bob = await DeviceIdentity.fromSeed(List<int>.filled(32, 82));
    final relay = _Relay([alice, bob]);
    final requested = <Uri>[];
    AuxiliaryRouteController routes(DeviceIdentity device) =>
        AuxiliaryRouteController(
          identity: () async => device,
          officialOrigin: 'https://official.example',
          store: _Store(
            const AuxiliaryRouteChoice(AuxiliaryRouteMode.official, ''),
          ),
          transportFactory: (uri) {
            requested.add(uri);
            return (transport: relay, close: () {});
          },
        );
    final aRoutes = routes(alice), bRoutes = routes(bob);
    await Future.wait([aRoutes.load(), bRoutes.load()]);
    final aPlatform = _Platform(alice), bPlatform = _Platform(bob);
    ConnectionController controller(
      _Platform platform,
      AuxiliaryRouteController route,
    ) => ConnectionController(
      platform,
      auxiliaryRoutes: route,
      recoveryWindow: const Duration(seconds: 2),
      recoveryBackoff: const [Duration(milliseconds: 40)],
      recoveryAttemptTimeout: const Duration(milliseconds: 600),
    );
    final a = controller(aPlatform, aRoutes);
    final b = controller(bPlatform, bRoutes);
    _Proxy? proxy;
    try {
      await b.open();
      proxy = _Proxy();
      await proxy.start(bPlatform.port!);
      final original = (await a.connect(
        '127.0.0.1',
        proxy.server.port,
        b.code!,
        expectedPeerKey: bob.encodedKey,
      ))!;
      final oldRemote = b.sessions.single;
      final grantA = original.grant!, grantB = oldRemote.grant!;
      final expiry = grantA.expiresMicros;
      relay.failChallenge = true;
      proxy.cut();
      await _until(
        () =>
            a.sessions.length == 1 &&
            b.sessions.length == 1 &&
            !identical(a.sessions.single, original),
      );
      expect(grantA.generation, 2);
      expect(relay.forwarded, 0);
      expect(requested.every((uri) => uri.host == 'official.example'), isTrue);
      const custom = AuxiliaryRouteChoice(
        AuxiliaryRouteMode.custom,
        'https://lan.example:8443',
      );
      await Future.wait([aRoutes.select(custom), bRoutes.select(custom)]);
      relay.failChallenge = false;
      await proxy.close();
      await _until(
        () =>
            a.sessions.length == 1 &&
            b.sessions.length == 1 &&
            grantA.generation == 3,
      );
      expect(a.sessions.single.grant, same(grantA));
      expect(b.sessions.single.grant, same(grantB));
      expect(grantA.expiresMicros, expiry);
      expect(grantA.generation, 3);
      expect(relay.forwarded, greaterThan(3));
      final customStart = requested.indexWhere(
        (uri) => uri.host == 'lan.example',
      );
      expect(customStart, greaterThanOrEqualTo(0));
      expect(
        requested.skip(customStart).every((uri) => uri.host == 'lan.example'),
        isTrue,
      );
      relay.failPoll = true;
      await _until(() => a.recoveringCount == 1 && b.recoveringCount == 1);
      expect(grantA.phase, GrantPhase.suspended);
      expect(grantB.phase, GrantPhase.suspended);
    } finally {
      await a.shutdown();
      await b.shutdown();
      aRoutes.stop();
      bRoutes.stop();
      if (proxy case final pending?) {
        await pending.close();
      }
      a.dispose();
      b.dispose();
    }
  });
}
