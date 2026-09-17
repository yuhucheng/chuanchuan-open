import 'dart:async';
import 'dart:io';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'v2 PAKE derives matching direction-bound exporters and revokes with owner',
    () async {
      final receiver = await DeviceIdentity.fromSeed(List.filled(32, 1));
      final initiator = await DeviceIdentity.fromSeed(List.filled(32, 2));
      final accepted = Completer<TrustedConnection>();
      final host = PairingHost(
        identity: receiver,
        clock: () async => 100,
        protocolVersion: 2,
        onConnection: accepted.complete,
      );
      await host.open(address: InternetAddress.loopbackIPv4);
      addTearDown(host.close);
      final client = await PairingAttempt(
        identity: initiator,
        clock: () async => 90,
        protocolVersion: 2,
      ).connect('127.0.0.1', host.port!, host.offer!.code);
      addTearDown(client.close);
      final server = await accepted.future;
      final a = client.grant!, b = server.grant!;
      expect(a.binding.initiatorKey, initiator.publicKey.bytes);
      expect(a.binding.receiverKey, receiver.publicKey.bytes);
      expect(b.binding.id, a.binding.id);
      expect(a.phase, GrantPhase.active);
      expect(b.phase, GrantPhase.active);
      expect(a.generation, 1);
      final initial = await b.open(
        await a.seal(SessionOperation.watch, 'initial', ''),
      );
      await initial.check();
      a.suspend();
      b.suspend();
      await expectLater(initial.check(), throwsA(isA<SessionFailure>()));
      final response = await b.answerResume(await a.beginResume());
      await b.acceptResume(await a.finishResume(response));
      expect(a.generation, 2);
      final message = await b.open(
        await a.seal(SessionOperation.watch, 'm', ''),
      );
      await message.check();
      expect(a.expiresMicros, 90 + grantLifetime.inMicroseconds);
      expect(b.expiresMicros, 100 + grantLifetime.inMicroseconds);
      expect(client.capabilities, isEmpty);
      server.close();
      await expectLater(message.check(), throwsA(isA<SessionFailure>()));
    },
  );
  test('v2 never silently downgrades to a v1 peer', () async {
    final host = PairingHost(
      identity: await DeviceIdentity.fromSeed(List.filled(32, 3)),
      clock: () async => 0,
      onConnection: (_) => fail('must reject'),
    );
    await host.open(address: InternetAddress.loopbackIPv4);
    addTearDown(host.close);
    final client = PairingAttempt(
      identity: await DeviceIdentity.fromSeed(List.filled(32, 4)),
      clock: () async => 0,
      protocolVersion: 2,
    );
    await expectLater(
      client.connect('127.0.0.1', host.port!, host.offer!.code),
      throwsA(isA<ConnectionFailure>()),
    );
  });
}
