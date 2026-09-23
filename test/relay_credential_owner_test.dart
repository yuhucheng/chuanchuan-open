import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_open/features/connections/relay_credential_owner.dart';
import 'package:share_hub_open/ui/client_app.dart';

import 'fakes.dart';

class _Auxiliary implements AuxiliaryTransport {
  _Auxiliary(this.identity);
  final DeviceIdentity identity;
  final nonce = base64Url.encode(List<int>.filled(32, 3));
  Completer<void>? holdChallenge;
  int challenges = 0, issued = 0;
  bool failOnce = false;
  int failChallenges = 0;
  String failureCode = 'unreachable';

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  ) async {
    if (path == '/v1/aux/challenge') {
      challenges++;
      if (failOnce || failChallenges > 0) {
        failOnce = false;
        if (failChallenges > 0) failChallenges--;
        throw AuxiliaryFailure(failureCode);
      }
      if (holdChallenge case final pending?) await pending.future;
      return {'nonce': nonce, 'expiresAt': 1800000030};
    }
    if (path == '/v1/devices/register') return {'deviceId': identity.id};
    issued++;
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
  late _Auxiliary transport;
  late RelayCredentialOwner owner;
  var closes = 0;

  setUp(() async {
    identity = await DeviceIdentity.fromSeed(List<int>.filled(32, 9));
    transport = _Auxiliary(identity);
    closes = 0;
    owner = RelayCredentialOwner(
      () async => identity,
      AuxiliaryServiceClient(transport),
      () => closes++,
      retryDelays: const [Duration(milliseconds: 1)],
    );
  });
  tearDown(() => owner.stop());

  test(
    'connection demand publishes only a valid lease; stop wipes it',
    () async {
      final states = <bool>[];
      owner.addListener(() => states.add(owner.current != null));
      expect(owner.current, isNull);
      expect(transport.challenges, 0);
      await owner.start();
      expect(owner.current, isNotNull);
      expect(transport.issued, 1);
      expect(owner.lastFailure, isNull);
      expect(states, [true]);
      owner.stop();
      expect(owner.current, isNull);
      expect(states, [true, false]);
      expect(closes, 1);
      owner.stop();
      expect(closes, 1);
    },
  );

  test(
    'idle suspension clears the lease and a new demand fetches again',
    () async {
      await owner.start();
      expect(owner.current, isNotNull);
      owner.suspend();
      expect(owner.current, isNull);
      expect(closes, 0);
      await owner.start();
      expect(owner.current, isNotNull);
      expect(transport.issued, 2);
    },
  );

  test(
    'synchronous listener can stop without leaving a renewal timer',
    () async {
      owner.addListener(() {
        if (owner.current != null) owner.stop();
      });
      await owner.start();
      expect(owner.current, isNull);
      expect(closes, 1);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(transport.issued, 1);
    },
  );

  test('stop during a pending request rejects its late result', () async {
    transport.holdChallenge = Completer<void>();
    final pending = owner.start();
    await Future<void>.delayed(Duration.zero);
    owner.stop();
    transport.holdChallenge!.complete();
    await pending;
    expect(owner.current, isNull);
    expect(transport.issued, 0);
  });

  test('suspend then resume cannot adopt the old cancelled response', () async {
    transport.holdChallenge = Completer<void>();
    final old = owner.start();
    await Future<void>.delayed(Duration.zero);
    owner.suspend();
    final fresh = owner.start();
    transport.holdChallenge!.complete();
    await Future.wait([old, fresh]);
    expect(owner.current, isNotNull);
    expect(transport.issued, 1);
    expect(transport.challenges, 3);
  });

  test('refresh cancels an in-flight credential request', () async {
    transport.holdChallenge = Completer<void>();
    final old = owner.start();
    await Future<void>.delayed(Duration.zero);
    final fresh = owner.refresh();
    transport.holdChallenge!.complete();
    await Future.wait([old, fresh]);
    expect(owner.current, isNotNull);
    expect(transport.issued, 1);
    expect(transport.challenges, 3);
  });

  test(
    'transient failure retries with a bound; direct path never waits',
    () async {
      transport.failOnce = true;
      final first = owner.start();
      expect(owner.current, isNull);
      await first;
      expect(owner.lastFailure, 'unreachable');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(owner.current, isNotNull);
      expect(transport.challenges, 3);
      expect(owner.lastFailure, isNull);
    },
  );

  test('long-lived demand recovers after a cooled-down retry burst', () async {
    owner.stop();
    owner = RelayCredentialOwner(
      () async => identity,
      AuxiliaryServiceClient(transport),
      () => closes++,
      retryDelays: const [Duration(milliseconds: 1)],
      recoveryDelay: const Duration(milliseconds: 20),
      maxRecoveryDelay: const Duration(milliseconds: 40),
    );
    transport.failChallenges = 2;
    final first = owner.start();
    expect(owner.current, isNull);
    await first;
    await Future<void>.delayed(const Duration(milliseconds: 8));
    expect(transport.challenges, 2);
    expect(owner.current, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(transport.challenges, 4);
    expect(transport.issued, 1);
    expect(owner.current, isNotNull);
    expect(owner.lastFailure, isNull);
  });

  test('idle suspension cancels the cooled-down retry', () async {
    owner.stop();
    owner = RelayCredentialOwner(
      () async => identity,
      AuxiliaryServiceClient(transport),
      () => closes++,
      retryDelays: const [Duration(milliseconds: 1)],
      recoveryDelay: const Duration(milliseconds: 30),
      maxRecoveryDelay: const Duration(milliseconds: 60),
    );
    transport.failChallenges = 2;
    await owner.start();
    await Future<void>.delayed(const Duration(milliseconds: 8));
    expect(transport.challenges, 2);
    owner.suspend();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(transport.challenges, 2);
    expect(owner.current, isNull);
  });

  test(
    'final authentication rejection does not enter a cooldown loop',
    () async {
      owner.stop();
      owner = RelayCredentialOwner(
        () async => identity,
        AuxiliaryServiceClient(transport),
        () => closes++,
        retryDelays: const [Duration(milliseconds: 1)],
        recoveryDelay: const Duration(milliseconds: 10),
        maxRecoveryDelay: const Duration(milliseconds: 20),
      );
      transport.failChallenges = 1;
      transport.failureCode = 'not_eligible';
      await owner.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(owner.lastFailure, 'not_eligible');
      expect(transport.challenges, 1);
      expect(owner.current, isNull);
    },
  );

  testWidgets('idle product app never requests auxiliary credentials', (
    tester,
  ) async {
    final platform = FakePlatform();
    final needs = <bool>[];
    await tester.pumpWidget(
      ShareHubApp(
        platform: platform,
        previewEngine: FakePreviewEngine(),
        targetPlatform: TargetPlatform.macOS,
        setAuxiliaryNeeded: needs.add,
      ),
    );
    await tester.pumpAndSettle();
    expect(needs, isNotEmpty);
    expect(needs, everyElement(isFalse));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await platform.events.close();
  });
}
