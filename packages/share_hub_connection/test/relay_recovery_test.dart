import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

final class _Proxy {
  late ServerSocket server;
  final sockets = <Socket>[];

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

  void cut() {
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
  }

  Future<void> close() async {
    cut();
    await server.close();
  }
}

final class _Relay implements AuxiliaryTransport {
  final nonce = base64Url.encode(List<int>.generate(32, (i) => i));
  final members = <String, String>{};
  final queues = <String, List<String>>{};
  final payloads = <List<int>>[];
  int messages = 0;

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
      final key = body['publicKey']!;
      return {
        'deviceId': (await DeviceIdentity.fromSeed(
          List<int>.filled(32, key == _firstKey ? 31 : 32),
        )).id,
      };
    }
    if (path == '/v1/signal/challenge') return {'nonce': nonce};
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
      payloads.add(RelaySignalEnvelope.decode(body['wire']!).payload);
      queues[peer]!.add(body['wire']!);
      messages++;
      return {'accepted': true};
    }
    if (path == '/v1/signal/poll') {
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

  String? _firstKey;
  void setFirst(DeviceIdentity identity) => _firstKey = identity.encodedKey;
}

void main() {
  test(
    'suspended grant resumes over a proved relay room without renewal',
    () async {
      var now = 1000000;
      final alice = await DeviceIdentity.fromSeed(List<int>.filled(32, 31));
      final bob = await DeviceIdentity.fromSeed(List<int>.filled(32, 32));
      final accepted = <TrustedConnection>[];
      final host = PairingHost(
        identity: bob,
        clock: () async => now,
        protocolVersion: 2,
        enableRecovery: true,
        onConnection: accepted.add,
      );
      await host.open(address: InternetAddress.loopbackIPv4);
      final proxy = _Proxy();
      await proxy.start(host.port!);
      final connections = <TrustedConnection>[];
      try {
        final original = await PairingAttempt(
          identity: alice,
          clock: () async => now,
          protocolVersion: 2,
          enableRecovery: true,
        ).connect('127.0.0.1', proxy.server.port, host.offer!.code);
        connections.add(original);
        final remote = accepted.single;
        final expires = original.grant!.expiresMicros;
        proxy.cut();
        expect(await original.whenClosed, 'transport_suspended');
        expect(await remote.whenClosed, 'transport_suspended');
        now += const Duration(minutes: 3).inMicroseconds;

        final relay = _Relay()..setFirst(alice);
        final client = RelayServiceClient(relay);
        final generation = original.grant!.generation + 1;
        final aChannel = await client.open(
          original.grant!,
          alice,
          generation: generation,
          cancellation: AuxiliaryCancellation(),
        );
        final bChannel = await client.open(
          remote.grant!,
          bob,
          generation: generation,
          cancellation: AuxiliaryCancellation(),
        );
        await Future.wait([aChannel.awaitReady(), bChannel.awaitReady()]);
        final aWire = await original.openRelayWire(aChannel);
        final bWire = await remote.openRelayWire(bChannel);
        final attempt = ConnectionRecoveryAttempt(original);
        final future = attempt.connectWire(() async => aWire);
        final remoteFuture = remote.acceptRecoveryWire(bWire, () {});
        final recovered = await future.timeout(const Duration(seconds: 3));
        final recoveredRemote = await remoteFuture.timeout(
          const Duration(seconds: 3),
        );
        connections.addAll([recovered, recoveredRemote]);
        recoveredRemote.startMonitoring();
        expect(recovered.grant, same(original.grant));
        expect(recoveredRemote.grant, same(remote.grant));
        expect(recovered.grant!.expiresMicros, expires);
        expect(recovered.grant!.generation, generation);
        final delivered = Completer<VerifiedSessionMessage>();
        recoveredRemote.attachReceiver(
          onRequest: delivered.complete,
          resolveSession: (_) => null,
          onSignal: (_) {},
        );
        await recovered.sendRequest(
          await recovered.createRequest(
            SessionOperation.watch,
            'relay-watch',
            '',
          ),
        );
        expect(
          (await delivered.future.timeout(const Duration(seconds: 3)))
              .transportGeneration,
          generation,
        );
        expect(relay.messages, greaterThan(3));
        expect(
          relay.payloads.any(
            (payload) => utf8
                .decode(payload, allowMalformed: true)
                .contains('resume-hello'),
          ),
          isFalse,
        );
      } finally {
        for (final connection in connections) {
          connection.close();
        }
        await proxy.close();
        await host.close();
      }
    },
  );
}
