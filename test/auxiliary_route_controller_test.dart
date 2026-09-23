import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_open/features/connections/auxiliary_route_controller.dart';

final class _Store implements AuxiliaryRouteStore {
  AuxiliaryRouteChoice? saved;
  Completer<AuxiliaryRouteChoice?>? pendingRead;
  bool failRead = false;
  bool failWrite = false;

  @override
  Future<AuxiliaryRouteChoice?> read() async {
    if (failRead) throw StateError('unreadable');
    return pendingRead?.future ?? saved;
  }

  @override
  Future<void> write(AuxiliaryRouteChoice choice) async {
    if (failWrite) throw StateError('unwritable');
    saved = choice;
  }
}

final class _Transport implements AuxiliaryTransport {
  _Transport(this.identity, {this.fail = false});
  final DeviceIdentity identity;
  final bool fail;
  final issued = Completer<void>();
  int requests = 0;
  bool closed = false;

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  ) async {
    requests++;
    if (closed) throw const AuxiliaryFailure('cancelled');
    if (fail) throw const AuxiliaryFailure('unreachable');
    if (path == '/v1/aux/challenge') {
      return {
        'nonce': base64Url.encode(List<int>.filled(32, 3)),
        'expiresAt':
            DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 1))
                .millisecondsSinceEpoch ~/
            1000,
      };
    }
    if (path == '/v1/devices/register') return {'deviceId': identity.id};
    if (!issued.isCompleted) issued.complete();
    return {
      'expiresAt': DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 5))
          .toIso8601String(),
      'iceServers': [
        {
          'urls': ['turn:relay.example:3478'],
          'username': 'temporary',
          'credential': 'secret',
        },
      ],
    };
  }
}

void main() {
  late DeviceIdentity identity;
  late _Store store;
  late List<Uri> requested;
  late List<_Transport> transports;
  late Set<String> failingHosts;
  late AuxiliaryRouteController routes;

  setUp(() async {
    identity = await DeviceIdentity.fromSeed(List<int>.filled(32, 9));
    store = _Store();
    requested = [];
    transports = [];
    failingHosts = {};
    routes = AuxiliaryRouteController(
      identity: () async => identity,
      officialOrigin: 'https://official.example',
      store: store,
      transportFactory: (uri) {
        requested.add(uri);
        final transport = _Transport(
          identity,
          fail: failingHosts.contains(uri.host),
        );
        transports.add(transport);
        return (transport: transport, close: () => transport.closed = true);
      },
    );
  });
  tearDown(() => routes.stop());

  Future<void> waitForLease() async {
    for (var attempt = 0; attempt < 20 && routes.current == null; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(routes.current, isNotNull);
  }

  test(
    'saved custom route is the only origin used when connection is needed',
    () async {
      store.saved = const AuxiliaryRouteChoice(
        AuxiliaryRouteMode.custom,
        'https://lan.example:8443',
      );
      routes.setNeeded(true);
      await routes.load();
      await transports.single.issued.future;
      await waitForLease();
      expect(requested.map((uri) => uri.toString()), [
        'https://lan.example:8443',
      ]);
    },
  );

  test('switch cancels old lease before a custom route is used', () async {
    await routes.load();
    routes.setNeeded(true);
    await transports.single.issued.future;
    await waitForLease();
    final old = transports.single;
    await routes.select(
      const AuxiliaryRouteChoice(
        AuxiliaryRouteMode.custom,
        'https://lan.example:8443',
      ),
    );
    expect(old.closed, isTrue);
    expect(requested.map((uri) => uri.host), [
      'official.example',
      'lan.example',
    ]);
    await transports.last.issued.future;
    await waitForLease();
    expect(store.saved?.mode, AuxiliaryRouteMode.custom);
  });

  test(
    'failed preference read and invalid custom origin never use official',
    () async {
      store.failRead = true;
      routes.setNeeded(true);
      await routes.load();
      expect(requested, isEmpty);
      expect(routes.current, isNull);
      await routes.select(
        const AuxiliaryRouteChoice(
          AuxiliaryRouteMode.custom,
          'http://lan.example',
        ),
      );
      expect(requested, isEmpty);
      expect(store.saved, isNull);
      await routes.select(
        const AuxiliaryRouteChoice(
          AuxiliaryRouteMode.custom,
          'https://lan.example',
        ),
      );
      await transports.single.issued.future;
      expect(requested.single.host, 'lan.example');
    },
  );

  test(
    'late stored route cannot replace an explicit newer selection',
    () async {
      store.pendingRead = Completer<AuxiliaryRouteChoice?>();
      final loading = routes.load();
      await routes.select(
        const AuxiliaryRouteChoice(
          AuxiliaryRouteMode.custom,
          'https://lan.example',
        ),
      );
      store.pendingRead!.complete(
        const AuxiliaryRouteChoice(AuxiliaryRouteMode.official, ''),
      );
      await loading;
      expect(routes.choice.mode, AuxiliaryRouteMode.custom);
      expect(requested.map((uri) => uri.host), ['lan.example']);
    },
  );

  test(
    'unreachable custom route reports failure without official fallback',
    () async {
      failingHosts.add('lan.example');
      store.saved = const AuxiliaryRouteChoice(
        AuxiliaryRouteMode.custom,
        'https://lan.example',
      );
      await routes.load();
      routes.setNeeded(true);
      for (
        var attempt = 0;
        attempt < 20 && routes.connectionFailure == null;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(routes.connectionFailure, 'unreachable');
      expect(routes.current, isNull);
      expect(requested.map((uri) => uri.host), ['lan.example']);
      final failures = <String?>[];
      routes.addListener(() => failures.add(routes.connectionFailure));
      await routes.refresh();
      expect(failures, contains(null));
      expect(failures.last, 'unreachable');
      expect(requested.map((uri) => uri.host), ['lan.example']);
    },
  );

  test(
    'failed save keeps custom routing visible without official fallback',
    () async {
      await routes.load();
      store.failWrite = true;
      await routes.select(
        const AuxiliaryRouteChoice(
          AuxiliaryRouteMode.custom,
          'https://lan.example',
        ),
      );
      expect(routes.choice.mode, AuxiliaryRouteMode.custom);
      expect(routes.error, contains('保存失败'));
      expect(requested.map((uri) => uri.host), [
        'official.example',
        'lan.example',
      ]);
      expect(transports.first.closed, isTrue);
    },
  );
}
