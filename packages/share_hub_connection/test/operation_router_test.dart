import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';
import 'package:test/test.dart';

void main() {
  late PairingHost host;
  late TrustedConnection a, b;
  late Future<int> Function() hostClock;
  setUp(() async {
    hostClock = () async => 100;
    final accepted = Completer<TrustedConnection>();
    host = PairingHost(
      identity: await DeviceIdentity.fromSeed(List.filled(32, 51)),
      clock: () => hostClock(),
      protocolVersion: 2,
      onConnection: accepted.complete,
    );
    await host.open(address: InternetAddress.loopbackIPv4);
    a = await PairingAttempt(
      identity: await DeviceIdentity.fromSeed(List.filled(32, 52)),
      clock: () async => 100,
      protocolVersion: 2,
    ).connect('127.0.0.1', host.port!, host.offer!.code);
    b = await accepted.future;
  });
  tearDown(() async {
    a.close();
    b.close();
    await host.close();
  });

  test('packet awaiting clock cannot reach a replacement consumer', () async {
    final sender = _Consumer(a.operationTransport({SessionOperation.file}));
    final port = b.operationTransport({SessionOperation.file});
    final old = _Consumer(port);
    final entered = Completer<void>();
    final gate = Completer<int>();
    hostClock = () {
      hostClock = () async => 100;
      entered.complete();
      return gate.future;
    };
    await sender.request(SessionOperation.file, 'old-owner', 'old-data');
    await entered.future.timeout(const Duration(seconds: 5));
    port.detachReceiver();
    final replacement = _Consumer(port);
    gate.complete(100);
    await sender.request(SessionOperation.file, 'new-owner', 'new-data');
    // The fresh request is a wire-order barrier for the discarded old packet.
    expect((await replacement.requests.next()).sessionId, 'new-owner');
    expect(old.requests.values, isEmpty);
    expect(replacement.requests.values, isEmpty);
    expect(b.isClosed, isFalse);
  });

  test('real connection routes concurrent media and full file blocks independently', () async {
    final am = _Consumer(
      a.operationTransport({SessionOperation.watch, SessionOperation.cast}),
    );
    final af = _Consumer(a.operationTransport({SessionOperation.file}));
    final bm = _Consumer(
      b.operationTransport({SessionOperation.watch, SessionOperation.cast}),
    );
    final bf = _Consumer(b.operationTransport({SessionOperation.file}));
    final media = await am.request(SessionOperation.watch, 'media', 'video-v1');
    // The complete file block passes through both real authenticated envelopes.
    final block = jsonEncode({
      'v': 1,
      'type': 'chunk',
      'data': base64Url.encode(List.filled(32768, 42)),
    });
    final file = await af.request(SessionOperation.file, 'file', 'offer-v1');
    final incomingMedia = await bm.requests.next();
    final incomingFile = await bf.requests.next();
    expect(incomingMedia.sessionId, media.sessionId);
    expect(incomingFile.sessionId, file.sessionId);
    await Future.wait([
      bf.transport.sendSignal(incomingFile, 'ack'),
      bm.transport.sendSignal(incomingMedia, 'ready'),
      af.transport.sendSignal(file, block),
    ]);
    expect((await af.signals.next()).body, 'ack');
    expect((await am.signals.next()).body, 'ready');
    expect((await bf.signals.next()).body, block);
    expect(a.isClosed, isFalse);
    expect(b.isClosed, isFalse);
  });

  test(
    'file in either grant direction does not expand watch authority',
    () async {
      final af = _Consumer(a.operationTransport({SessionOperation.file}));
      final bf = _Consumer(b.operationTransport({SessionOperation.file}));
      final reverse = await bf.request(
        SessionOperation.file,
        'reverse-file',
        'offer',
      );
      final incoming = await af.requests.next();
      expect(incoming.sender, GrantRole.receiver);
      await af.transport.sendSignal(incoming, 'accepted');
      expect(
        (await bf.signals.next()).authorization.sessionId,
        reverse.sessionId,
      );
      await expectLater(
        bf.transport.createRequest(
          SessionOperation.watch,
          'wrong-operation',
          '',
        ),
        throwsA(isA<SessionFailure>()),
      );
      expect(b.isClosed, isFalse);
    },
  );

  test(
    'detaching media leaves file replies active and permits media reattachment',
    () async {
      final am = _Consumer(a.operationTransport({SessionOperation.watch}));
      final af = _Consumer(a.operationTransport({SessionOperation.file}));
      final bm = _Consumer(b.operationTransport({SessionOperation.watch}));
      final bf = _Consumer(b.operationTransport({SessionOperation.file}));
      await am.request(SessionOperation.watch, 'old-media', '');
      final old = await bm.requests.next();
      am.transport.detachReceiver();
      await af.request(SessionOperation.file, 'active-file', '');
      final file = await bf.requests.next();
      await bm.transport.sendSignal(old, 'late-media');
      await bf.transport.sendSignal(file, 'file-progress');
      expect((await af.signals.next()).body, 'file-progress');
      expect(am.signals.values, isEmpty);
      final again = _Consumer(a.operationTransport({SessionOperation.watch}));
      await again.request(SessionOperation.watch, 'new-media', '');
      final current = await bm.requests.next();
      await bm.transport.sendSignal(current, 'current-media');
      expect((await again.signals.next()).body, 'current-media');
    },
  );

  test('overlapping routes and cross-route authorities are rejected', () async {
    final media = _Consumer(
      a.operationTransport({SessionOperation.watch, SessionOperation.cast}),
    );
    final files = _Consumer(a.operationTransport({SessionOperation.file}));
    expect(
      () => a.operationTransport({SessionOperation.watch}),
      throwsStateError,
    );
    expect(() => a.operationTransport({}), throwsArgumentError);
    final request = await media.transport.createRequest(
      SessionOperation.watch,
      'media',
      '',
    );
    await expectLater(
      files.transport.sendRequest(request),
      throwsA(isA<SessionFailure>()),
    );
    await expectLater(
      files.transport.sendSignal(request, 'forged'),
      throwsA(isA<SessionFailure>()),
    );
    expect(a.isClosed, isFalse);
  });

  test(
    'cross-operation session ID collision cannot redirect a signal',
    () async {
      final am = _Consumer(a.operationTransport({SessionOperation.watch}));
      final af = _Consumer(a.operationTransport({SessionOperation.file}));
      final bm = _Consumer(b.operationTransport({SessionOperation.watch}));
      _Consumer(b.operationTransport({SessionOperation.file}));
      await am.request(SessionOperation.watch, 'same-id', '');
      await bm.requests.next();
      await expectLater(
        af.transport.createRequest(SessionOperation.file, 'same-id', ''),
        throwsA(isA<SessionFailure>()),
      );
      expect(a.isClosed, isFalse);
    },
  );

  test('closing connection invalidates all routed sends', () async {
    final file = _Consumer(a.operationTransport({SessionOperation.file}));
    final local = await file.transport.createRequest(
      SessionOperation.file,
      'queued',
      '',
    );
    a.close();
    await expectLater(
      file.transport.sendRequest(local),
      throwsA(isA<SessionFailure>()),
    );
    await expectLater(
      file.transport.createRequest(SessionOperation.file, 'later', ''),
      throwsA(isA<SessionFailure>()),
    );
    expect(
      () => a.operationTransport({SessionOperation.file}),
      throwsA(isA<ConnectionFailure>()),
    );
  });
}

final class _Consumer {
  _Consumer(this.transport) {
    transport.attachReceiver(
      onRequest: (value) {
        entries[value.sessionId] = value;
        requests.add(value);
      },
      resolveSession: (id) => entries[id],
      onSignal: signals.add,
    );
  }
  final SessionTransport transport;
  final entries = <String, SessionAuthorization>{};
  final requests = _Inbox<VerifiedSessionMessage>();
  final signals = _Inbox<VerifiedSessionSignal>();
  Future<LocalSessionRequest> request(
    SessionOperation operation,
    String id,
    String body,
  ) async {
    final request = await transport.createRequest(operation, id, body);
    entries[id] = request;
    await transport.sendRequest(request);
    return request;
  }
}

final class _Inbox<T> {
  final values = <T>[];
  final waiters = <Completer<T>>[];
  void add(T value) {
    if (waiters.isEmpty) {
      values.add(value);
    } else {
      waiters.removeAt(0).complete(value);
    }
  }

  Future<T> next() {
    if (values.isNotEmpty) return Future.value(values.removeAt(0));
    final waiter = Completer<T>();
    waiters.add(waiter);
    return waiter.future.timeout(const Duration(seconds: 5));
  }
}
