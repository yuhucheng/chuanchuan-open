import 'dart:async';
import 'dart:io';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

void main() {
  late PairingHost host;
  late TrustedConnection a, b;
  Future<int> Function()? clockRead;
  setUp(() async {
    clockRead = null;
    final accepted = Completer<TrustedConnection>();
    host = PairingHost(
      identity: await DeviceIdentity.fromSeed(List.filled(32, 31)),
      clock: () => clockRead?.call() ?? Future.value(100),
      protocolVersion: 2,
      onConnection: accepted.complete,
    );
    await host.open(address: InternetAddress.loopbackIPv4);
    a = await PairingAttempt(
      identity: await DeviceIdentity.fromSeed(List.filled(32, 32)),
      clock: () => clockRead?.call() ?? Future.value(100),
      protocolVersion: 2,
    ).connect('127.0.0.1', host.port!, host.offer!.code);
    b = await accepted.future;
  });
  tearDown(() async {
    a.close();
    b.close();
    await host.close();
  });

  test(
    'foreign local request cannot be sent through another endpoint',
    () async {
      final foreign = await b.createRequest(
        SessionOperation.file,
        'foreign',
        '',
      );
      await expectLater(a.sendRequest(foreign), throwsA(isA<SessionFailure>()));
      final received = Completer<VerifiedSessionMessage>();
      b.attachReceiver(
        onRequest: received.complete,
        resolveSession: (_) => null,
        onSignal: (_) {},
      );
      final valid = await a.createRequest(SessionOperation.watch, 'valid', '');
      await a.sendRequest(valid);
      expect(
        (await received.future.timeout(const Duration(seconds: 5))).sessionId,
        'valid',
      );
      expect(a.isClosed, isFalse);
    },
  );

  test('real v2 transport carries large authorized requests and bidirectional replies', () async {
    final local = await a.createRequest(
      SessionOperation.watch,
      'screen',
      's' * 60000,
    );
    final incoming = Completer<VerifiedSessionMessage>();
    final atA = Completer<VerifiedSessionSignal>();
    final atB = Completer<VerifiedSessionSignal>();
    VerifiedSessionMessage? remote;
    a.attachReceiver(
      onRequest: (_) => fail('reverse start'),
      resolveSession: (id) => id == local.sessionId ? local : null,
      onSignal: atA.complete,
    );
    b.attachReceiver(
      onRequest: (value) {
        remote = value;
        incoming.complete(value);
      },
      resolveSession: (id) => id == remote?.sessionId ? remote : null,
      onSignal: atB.complete,
    );
    await a.sendRequest(local);
    final request = await incoming.future.timeout(const Duration(seconds: 5));
    expect(request.body.length, 60000);
    await (GrantRegistry()..register(b.grant!)).verify(request);
    await b.sendSignal(request, 'a' * 60000);
    expect(
      (await atA.future.timeout(const Duration(seconds: 5))).body.length,
      60000,
    );
    await a.sendSignal(local, 'candidate');
    expect(
      (await atB.future.timeout(const Duration(seconds: 5))).body,
      'candidate',
    );
    expect(a.capabilities, isEmpty); // Transport is not a media implementation.
    expect(b.isClosed, isFalse);
  });

  test(
    'late signal for removed operation is consumed without affecting a new one',
    () async {
      final first = await a.createRequest(SessionOperation.watch, 'old', '');
      final second = await a.createRequest(SessionOperation.cast, 'new', '');
      final received = <String, VerifiedSessionMessage>{};
      final both = Completer<void>();
      final current = Completer<VerifiedSessionSignal>();
      a.attachReceiver(
        onRequest: (_) => fail('unexpected'),
        resolveSession: (id) => id == 'new' ? second : null,
        onSignal: current.complete,
      );
      b.attachReceiver(
        onRequest: (request) {
          received[request.sessionId] = request;
          if (received.length == 2) both.complete();
        },
        resolveSession: (id) => received[id],
        onSignal: (_) {},
      );
      await a.sendRequest(first);
      await a.sendRequest(second);
      await both.future.timeout(const Duration(seconds: 5));
      await Future.wait([
        b.sendSignal(received['old']!, 'late'),
        b.sendSignal(received['new']!, 'current'),
      ]);
      expect(
        (await current.future.timeout(const Duration(seconds: 5))).body,
        'current',
      );
      expect(a.isClosed, isFalse);
    },
  );

  test(
    'revocation while queued seal awaits the clock sends no request',
    () async {
      final request = await a.createRequest(
        SessionOperation.watch,
        'cancelled',
        '',
      );
      var deliveries = 0;
      b.attachReceiver(
        onRequest: (_) => deliveries++,
        resolveSession: (_) => null,
        onSignal: (_) {},
      );
      final clock = Completer<int>();
      final entered = Completer<void>();
      clockRead = () {
        if (!entered.isCompleted) entered.complete();
        return clock.future;
      };
      final pending = a.sendRequest(request);
      final failure = expectLater(pending, throwsA(isA<SessionFailure>()));
      await entered.future;
      a.close();
      clock.complete(100);
      await failure;
      await b.whenClosed.timeout(const Duration(seconds: 5));
      expect(deliveries, 0);
      await expectLater(request.check(), throwsA(isA<SessionFailure>()));
    },
  );
}
