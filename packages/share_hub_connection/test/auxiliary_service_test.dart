import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:test/test.dart';

final _time = DateTime.utc(2027, 1, 15, 8);
final _nonceBytes = List<int>.generate(32, (index) => index);
final _nonce = base64Url.encode(_nonceBytes);

class _Service implements AuxiliaryTransport {
  bool registered = false;
  int challenges = 0;
  int proofs = 0;
  String? lastPurpose;
  Completer<void>? beforeChallenge;
  Completer<void>? beforeCredential;
  String? overrideDeviceId;
  String? overrideExpiry;

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  ) async {
    if (path == '/v1/aux/challenge') {
      challenges++;
      lastPurpose = body['purpose'];
      if (beforeChallenge case final pending?) await pending.future;
      return {
        'nonce': _nonce,
        'expiresAt': _time.millisecondsSinceEpoch ~/ 1000 + 30,
      };
    }
    proofs++;
    final purpose = path == '/v1/devices/register' ? 'register' : 'turn';
    expect(lastPurpose, purpose);
    expect(body['nonce'], _nonce);
    final key = base64Url.decode(body['publicKey']!);
    final transcript = <int>[
      ...utf8.encode('chuanchuan-aux-v1'),
      0,
      ...utf8.encode(purpose),
      0,
      ...key,
      ..._nonceBytes,
    ];
    expect(
      await DeviceIdentity.verify(
        body['publicKey']!,
        body['signature'],
        transcript,
      ),
      isTrue,
    );
    if (purpose == 'register') {
      registered = true;
      final identity = await DeviceIdentity.fromSeed(List<int>.filled(32, 7));
      return {'deviceId': overrideDeviceId ?? identity.id};
    }
    if (beforeCredential case final pending?) await pending.future;
    if (!registered) throw const AuxiliaryFailure('not_eligible');
    return {
      'expiresAt':
          overrideExpiry ??
          _time.add(const Duration(minutes: 5)).toIso8601String(),
      'iceServers': [
        {
          'urls': ['turn:relay.example:3478?transport=udp'],
          'username': '1800000300:d-test',
          'credential': 'secret-credential',
        },
      ],
    };
  }
}

void main() {
  late DeviceIdentity identity;
  late _Service service;
  late AuxiliaryServiceClient client;
  setUp(() async {
    identity = await DeviceIdentity.fromSeed(List<int>.filled(32, 7));
    service = _Service();
    client = AuxiliaryServiceClient(service, now: () => _time);
  });

  test(
    'public identity proves register and turn without creating a grant',
    () async {
      final token = AuxiliaryCancellation();
      await client.register(identity, cancellation: token);
      final lease = await client.issueTurn(identity, cancellation: token);
      expect(service.challenges, 2);
      expect(service.proofs, 2);
      expect(lease.urls, ['turn:relay.example:3478?transport=udp']);
      expect(lease.validAt(_time.add(const Duration(minutes: 5))), isFalse);
      expect(lease.toString(), isNot(contains('secret-credential')));
    },
  );

  test(
    'cancelled challenge cannot produce a late proof or allocation',
    () async {
      service.beforeChallenge = Completer<void>();
      final token = AuxiliaryCancellation();
      final result = client.register(identity, cancellation: token);
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      service.beforeChallenge!.complete();
      await expectLater(
        result,
        throwsA(
          isA<AuxiliaryFailure>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      expect(service.proofs, 0);
    },
  );

  test('cancelled late TURN response is discarded', () async {
    final token = AuxiliaryCancellation();
    await client.register(identity, cancellation: token);
    service.beforeCredential = Completer<void>();
    final result = client.issueTurn(identity, cancellation: token);
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    service.beforeCredential!.complete();
    await expectLater(
      result,
      throwsA(
        isA<AuxiliaryFailure>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
  });

  test(
    'wrong registration identity and expired credential fail closed',
    () async {
      service.overrideDeviceId = 'someone-else';
      await expectLater(
        client.register(identity, cancellation: AuxiliaryCancellation()),
        throwsA(
          isA<AuxiliaryFailure>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
      service.overrideDeviceId = null;
      await client.register(identity, cancellation: AuxiliaryCancellation());
      service.overrideExpiry = _time
          .subtract(const Duration(seconds: 1))
          .toIso8601String();
      await expectLater(
        client.issueTurn(identity, cancellation: AuxiliaryCancellation()),
        throwsA(
          isA<AuxiliaryFailure>().having(
            (error) => error.code,
            'code',
            'expired_credential',
          ),
        ),
      );
    },
  );

  test('desktop transport requires a TLS origin', () {
    expect(
      () => HttpsAuxiliaryTransport(Uri.parse('http://localhost:8443')),
      throwsArgumentError,
    );
  });

  test(
    'cancelling a stalled TLS connection releases the request immediately',
    () async {
      final accepted = Completer<Socket>();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((socket) {
        if (!accepted.isCompleted) accepted.complete(socket);
      });
      final transport = HttpsAuxiliaryTransport(
        Uri.parse('https://127.0.0.1:${server.port}'),
        timeout: const Duration(seconds: 5),
      );
      final cancellation = AuxiliaryCancellation();
      Socket? stalledSocket;
      try {
        final result = transport.post('/v1/aux/challenge', {
          'publicKey': identity.encodedKey,
          'purpose': 'turn',
        }, cancellation);
        stalledSocket = await accepted.future.timeout(
          const Duration(seconds: 2),
        );
        cancellation.cancel();
        await expectLater(
          result.timeout(const Duration(milliseconds: 500)),
          throwsA(
            isA<AuxiliaryFailure>().having(
              (error) => error.code,
              'code',
              'cancelled',
            ),
          ),
        );
      } finally {
        cancellation.cancel();
        transport.close();
        stalledSocket?.destroy();
        await subscription.cancel();
        await server.close();
      }
    },
  );

  test(
    'server owns challenge expiry when client wall clock is ahead',
    () async {
      final skewed = AuxiliaryServiceClient(
        service,
        now: () => _time.add(const Duration(hours: 1)),
      );
      await skewed.register(identity, cancellation: AuxiliaryCancellation());
      expect(service.registered, isTrue);
    },
  );
}
