import 'dart:io';

import 'package:share_hub_connection/src/channel.dart';
import 'package:share_hub_connection/src/identity.dart';
import 'package:share_hub_connection/src/session.dart';
import 'package:test/test.dart';

void main() {
  late ServerSocket listener;
  late WireChannel left;
  late WireChannel right;
  setUp(() async {
    listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = listener.first;
    final socket = await Socket.connect('127.0.0.1', listener.port);
    left = WireChannel(socket);
    right = WireChannel(await accepted);
  });
  tearDown(() async {
    left.close();
    right.close();
    await listener.close();
  });
  test('authenticated envelope replay is rejected', () async {
    final sender = await CipherChannel.create(left, List.filled(32, 1), [
      1,
      2,
      3,
    ], host: true);
    // Intercept at the other end, then replay through the sender's socket.
    await sender.send({'type': 'heartbeat'});
    final frame = await right.next();
    final receiver = await CipherChannel.create(right, List.filled(32, 1), [
      1,
      2,
      3,
    ], host: false);
    left.send(frame);
    expect((await receiver.next())['type'], 'heartbeat');
    left.send(frame);
    await expectLater(receiver.next(), throwsA(isA<ConnectionFailure>()));
  });
  test('tampered ciphertext cannot become a session operation', () async {
    final sender = await CipherChannel.create(left, List.filled(32, 1), [
      4,
    ], host: true);
    await sender.send({'type': 'heartbeat'});
    final frame = await right.next();
    frame['mac'] = encodeBytes(List.filled(16, 0));
    final receiver = await CipherChannel.create(right, List.filled(32, 1), [
      4,
    ], host: false);
    left.send(frame);
    await expectLater(receiver.next(), throwsA(isA<ConnectionFailure>()));
  });
  test('oversized frame closes before allocating requested payload', () async {
    left.socket.add([0x7f, 0xff, 0xff, 0xff]);
    await expectLater(right.next(), throwsA(isA<ConnectionFailure>()));
  });
  test(
    'concurrent sends remain ordered and snapshot mutable caller data',
    () async {
      final sender = await CipherChannel.create(left, List.filled(32, 1), [
        9,
      ], host: true);
      final receiver = await CipherChannel.create(right, List.filled(32, 1), [
        9,
      ], host: false);
      final data = <String, dynamic>{'index': 0};
      final writes = <Future<void>>[];
      for (var i = 0; i < 8; i++) {
        data['index'] = i;
        writes.add(sender.send(data));
      }
      data['index'] = 99;
      final read = Future(() async {
        for (var i = 0; i < 8; i++) {
          expect((await receiver.next())['index'], i);
        }
      });
      await Future.wait([...writes, read]);
    },
  );
  test(
    'send queue and payload bounds reject without consuming sequence',
    () async {
      final sender = await CipherChannel.create(left, List.filled(32, 1), [
        10,
      ], host: true);
      final receiver = await CipherChannel.create(right, List.filled(32, 1), [
        10,
      ], host: false);
      await expectLater(
        sender.send({'data': 'x' * 4096}),
        throwsA(isA<ConnectionFailure>()),
      );
      final writes = List.generate(8, (i) => sender.send({'index': i}));
      final excess = sender.send({'index': 8});
      final read = Future(() async {
        for (var i = 0; i < 8; i++) {
          expect((await receiver.next())['index'], i);
        }
      });
      await expectLater(excess, throwsA(isA<ConnectionFailure>()));
      await Future.wait([...writes, read]);
      await sender.send({'index': 9});
      expect((await receiver.next())['index'], 9);
    },
  );
}
