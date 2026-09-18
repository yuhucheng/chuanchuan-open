import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:share_hub_connection/src/channel.dart';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:test/test.dart';

void main() {
  for (final version in [1, 2]) {
    group("protocol v$version", () {
      late DeviceIdentity hostIdentity;
      late DeviceIdentity clientIdentity;
      late PairingHost host;
      late int now;
      late List<TrustedConnection> accepted;
      setUp(() async {
        now = 1000000;
        hostIdentity = await DeviceIdentity.fromSeed(List.filled(32, 1));
        clientIdentity = await DeviceIdentity.fromSeed(List.filled(32, 2));
        accepted = [];
        host = PairingHost(
          protocolVersion: version,
          identity: hostIdentity,
          clock: () async => now,
          onConnection: accepted.add,
        );
        await host.open(address: InternetAddress.loopbackIPv4);
      });
      tearDown(() async {
        await host.close();
      });
      PairingAttempt attempt() => PairingAttempt(
        identity: clientIdentity,
        clock: () async => now,
        protocolVersion: version,
      );

      test('code requires exactly six ASCII digits', () async {
        expect(host.offer!.code, matches(RegExp(r'^[0-9]{6}$')));
        for (final invalid in [
          '12345',
          '1234567',
          '12345678',
          '12345a',
          '１２３４５６',
          '123456\n',
        ]) {
          await expectLater(
            attempt().connect('127.0.0.1', host.port!, invalid),
            throwsA(
              isA<ConnectionFailure>().having(
                (error) => error.code,
                'code',
                'invalid_input',
              ),
            ),
          );
        }
        expect(accepted, isEmpty);
      });

      test(
        'authorization remains valid after two hours and expires at eight',
        () {
          expect(connectionLifetime, const Duration(hours: 8));
          final lease = SessionLease(startedMicros: now);
          expect(
            lease.check(now + const Duration(hours: 2).inMicroseconds),
            isTrue,
          );
          expect(
            lease.check(now + const Duration(hours: 8).inMicroseconds - 1),
            isTrue,
          );
          expect(
            lease.check(now + const Duration(hours: 8).inMicroseconds),
            isFalse,
          );
        },
      );

      test(
        'short code binds identities, consumes once and grants no operations',
        () async {
          final code = host.offer!.code;
          now += const Duration(minutes: 4).inMicroseconds;
          final client = await attempt().connect('127.0.0.1', host.port!, code);
          expect(client.peerId, hostIdentity.id);
          expect(accepted.single.peerId, clientIdentity.id);
          expect(client.capabilities, isEmpty);
          expect(accepted.single.lease.startedMicros, now);
          await expectLater(
            attempt().connect('127.0.0.1', host.port!, code),
            throwsA(isA<ConnectionFailure>()),
          );
          client.close();
        },
      );
      test(
        'wrong code cannot authorize and does not consume correct code',
        () async {
          final code = host.offer!.code;
          final wrong = code == '000000' ? '111111' : '000000';
          await expectLater(
            attempt().connect('127.0.0.1', host.port!, wrong),
            throwsA(isA<ConnectionFailure>()),
          );
          expect(accepted, isEmpty);
          final client = await attempt().connect('127.0.0.1', host.port!, code);
          client.close();
        },
      );
      test(
        'fifth failed attempt exhausts code, refresh must be explicit',
        () async {
          final code = host.offer!.code;
          for (var i = 0; i < 5; i++) {
            await expectLater(
              attempt().connect(
                '127.0.0.1',
                host.port!,
                code == '000000' ? '111111' : '000000',
              ),
              throwsA(isA<ConnectionFailure>()),
            );
          }
          await expectLater(
            attempt().connect('127.0.0.1', host.port!, code),
            throwsA(isA<ConnectionFailure>()),
          );
          expect(accepted, isEmpty);
        },
      );
      test('offer expires before connection; no lease issued', () async {
        now += offerLifetime.inMicroseconds;
        await expectLater(
          attempt().connect('127.0.0.1', host.port!, host.offer!.code),
          throwsA(isA<ConnectionFailure>()),
        );
        expect(accepted, isEmpty);
      });
      test('concurrent successful proofs can consume only once', () async {
        final port = host.port!;
        final code = host.offer!.code;
        Future<bool> connect() async {
          try {
            await attempt().connect('127.0.0.1', port, code);
            return true;
          } on ConnectionFailure {
            return false;
          }
        }

        final outcomes = await Future.wait([connect(), connect()]);
        expect(outcomes.where((value) => value).length, 1);
        expect(accepted.length, 1);
      });
      test('expected identity mismatch rejects even valid code', () async {
        await expectLater(
          attempt().connect(
            '127.0.0.1',
            host.port!,
            host.offer!.code,
            expectedPeerKey: clientIdentity.encodedKey,
          ),
          throwsA(isA<ConnectionFailure>()),
        );
        expect(accepted, isEmpty);
      });
      test('cancelled connection cannot be restored by late socket', () async {
        final request = attempt();
        final result = request.connect(
          '127.0.0.1',
          host.port!,
          host.offer!.code,
        );
        request.cancel();
        await expectLater(result, throwsA(isA<ConnectionFailure>()));
        expect(accepted, isEmpty);
      });
      test('eight hours expires without renewal and closes peer', () async {
        final client = await attempt().connect(
          '127.0.0.1',
          host.port!,
          host.offer!.code,
        );
        final session = accepted.single;
        final original = session.lease.expiresMicros;
        now += connectionLifetime.inMicroseconds - 1;
        expect(await session.check(), isTrue);
        expect(session.lease.expiresMicros, original);
        now++;
        expect(await session.check(), isFalse);
        expect(await session.whenClosed, 'expired');
        await client.whenClosed.timeout(const Duration(seconds: 2));
        expect(client.isClosed, isTrue);
      });
      test('revocation terminates both endpoints without internet', () async {
        final client = await attempt().connect(
          '127.0.0.1',
          host.port!,
          host.offer!.code,
        );
        accepted.single.close();
        await client.whenClosed.timeout(const Duration(seconds: 2));
        expect(client.isClosed, isTrue);
      });
      test(
        'forged identity signature cannot authorize despite correct SRP proof',
        () async {
          final proxy = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final channels = <WireChannel>[];
          proxy.listen((socket) async {
            final downstream = WireChannel(socket);
            final upstream = WireChannel(
              await Socket.connect('127.0.0.1', host.port!),
            );
            channels.addAll([downstream, upstream]);
            Future<void> forward(
              WireChannel from,
              WireChannel to,
              bool tamper,
            ) async {
              try {
                while (true) {
                  final frame = await from.next();
                  if (tamper && frame['type'] == 'proof') {
                    frame['signature'] = base64Url.encode(List.filled(64, 0));
                  }
                  to.send(frame);
                }
              } catch (_) {
                from.close();
                to.close();
              }
            }

            unawaited(forward(downstream, upstream, true));
            unawaited(forward(upstream, downstream, false));
          });
          try {
            await expectLater(
              attempt().connect('127.0.0.1', proxy.port, host.offer!.code),
              throwsA(isA<ConnectionFailure>()),
            );
            expect(accepted, isEmpty);
          } finally {
            for (final channel in channels) {
              channel.close();
            }
            await proxy.close();
          }
        },
      );
      test(
        'stopping accept invalidates in-flight handshake and late proof',
        () async {
          final socket = await Socket.connect('127.0.0.1', host.port!);
          final wire = WireChannel(socket);
          wire.send({
            'v': version,
            'type': 'hello',
            'key': clientIdentity.encodedKey,
            'nonce': base64Url.encode(List.filled(32, 7)),
          });
          expect((await wire.next())['type'], 'challenge');
          await host.stopAccepting();
          await expectLater(wire.next(), throwsA(isA<ConnectionFailure>()));
          expect(accepted, isEmpty);
          wire.close();
        },
      );
      test('clock rollback and restart cannot recover authorization', () {
        final lease = SessionLease(startedMicros: now);
        expect(lease.check(now + 20), isTrue);
        expect(lease.check(now + 10), isFalse);
        expect(lease.check(now + 30), isFalse);
        expect(lease.expiresMicros, now + connectionLifetime.inMicroseconds);
      });
    });
  }

  group('handshake timeout', () {
    const budget = Duration(milliseconds: 150);

    test('a stalled attempt is cancelled, never completed late', () async {
      final stalled = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      stalled.listen(sockets.add);
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await stalled.close();
      });
      final identity = await DeviceIdentity.fromSeed(List.filled(32, 9));
      await expectLater(
        PairingAttempt(
          identity: identity,
          clock: () async => 1000,
          handshakeTimeout: budget,
        ).connect('127.0.0.1', stalled.port, '123456'),
        throwsA(
          isA<ConnectionFailure>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      expect(sockets, isNotEmpty);
    });

    test('host budget drops a stalled handshake without authorizing it', () async {
      final hostIdentity = await DeviceIdentity.fromSeed(List.filled(32, 11));
      final clientIdentity = await DeviceIdentity.fromSeed(List.filled(32, 12));
      final accepted = <TrustedConnection>[];
      final host = PairingHost(
        identity: hostIdentity,
        clock: () async => 1000,
        onConnection: accepted.add,
        handshakeTimeout: budget,
      );
      addTearDown(host.close);
      await host.open(address: InternetAddress.loopbackIPv4);
      final wire = WireChannel(
        await Socket.connect('127.0.0.1', host.port!),
      );
      wire.send({
        'v': 1,
        'type': 'hello',
        'key': clientIdentity.encodedKey,
        'nonce': base64Url.encode(List.filled(32, 3)),
      });
      expect((await wire.next())['type'], 'challenge');
      await expectLater(wire.next(), throwsA(isA<ConnectionFailure>()));
      expect(accepted, isEmpty);
      // The abandoned attempt consumed no authorization: the code stays usable
      // for the caller's remaining reservations.
      expect(host.offer!.code, matches(RegExp(r'^[0-9]{6}$')));
      expect(host.offer!.reservable(1000), isTrue);
      wire.close();
    });
  });
}
