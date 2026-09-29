// Independent host/joiner processes for selected-origin first-meeting checks.
// No media or Flutter engine. The one-time code is written only to a caller's
// private exchange file; identities and grants are never reused across runs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';

const _session = 'first-meeting-peer-probe';
final _clock = Stopwatch()..start();
Future<int> _now() async => _clock.elapsedMicroseconds;
void _report(String event, [Map<String, Object?> fields = const {}]) =>
    stdout.writeln(jsonEncode({'event': event, ...fields}));
void _require(bool condition, String code) {
  if (!condition) throw ConnectionFailure(code);
}

Future<void> _protectCodeFile(File file) async {
  if (Platform.isWindows) {
    final system = Platform.environment['SystemRoot'];
    _require(system != null, 'file_protection_unavailable');
    final who = await Process.run('$system/System32/whoami.exe', [
      '/user',
      '/fo',
      'csv',
      '/nh',
    ]);
    final sid = RegExp(r'S-1-[0-9-]+')
        .firstMatch(who.stdout.toString())
        ?.group(0);
    _require(who.exitCode == 0 && sid != null, 'file_protection_unavailable');
    final result = await Process.run('$system/System32/icacls.exe', [
      file.absolute.path,
      '/inheritance:r',
      '/grant:r',
      '*$sid:(F)',
    ]);
    _require(result.exitCode == 0, 'file_protection_failed');
  } else if (Platform.isMacOS || Platform.isLinux) {
    final result = await Process.run('/bin/chmod', ['600', file.absolute.path]);
    _require(
      result.exitCode == 0 && (await file.stat()).mode & 0x3f == 0,
      'file_protection_failed',
    );
  } else {
    throw const ConnectionFailure('file_protection_unavailable');
  }
}

String _failure(Object error) => switch (error) {
  ConnectionFailure() => error.code,
  AuxiliaryFailure() => error.code,
  SessionFailure() => error.code,
  TimeoutException() => 'timeout',
  _ => error.runtimeType.toString(),
};

void _connected(DeviceIdentity identity, TrustedConnection connection) {
  final grant = connection.grant!;
  _require(grant.phase == GrantPhase.active, 'grant_not_active');
  _require(
    connection.lease.expiresMicros - connection.lease.startedMicros ==
        const Duration(hours: 8).inMicroseconds,
    'unexpected_grant_lifetime',
  );
  _report('connected', {
    'selfId': identity.id,
    'peerId': connection.peerId,
    'grantId': grant.binding.encodedId,
    'grantRole': grant.role.name,
    'transportGeneration': grant.generation,
    'leaseStartedMicros': connection.lease.startedMicros,
    'leaseExpiresMicros': connection.lease.expiresMicros,
    'leaseDurationMicros':
        connection.lease.expiresMicros - connection.lease.startedMicros,
    'signalingPath': 'selected-origin-first-meeting',
    'mediaPath': 'not-tested',
    'clockEvidence':
        'process stopwatch; no suspend or eight-hour expiry acceptance',
  });
}

Future<void> main(List<String> args) async {
  try {
    final values = <String, String>{};
    const allowed = {
      '--role',
      '--origin',
      '--code-file',
      '--timeout',
      '--test-ca',
    };
    for (var index = 0; index < args.length; index += 2) {
      _require(
        index + 1 < args.length &&
            allowed.contains(args[index]) &&
            !values.containsKey(args[index]),
        'invalid_arguments',
      );
      values[args[index]] = args[index + 1];
    }
    final role = values['--role'];
    final origin = Uri.parse(values['--origin'] ?? '');
    final file = values['--code-file'];
    final seconds = int.tryParse(values['--timeout'] ?? '120');
    _require(
      (role == 'host' || role == 'join') &&
          file != null &&
          origin.scheme == 'https' &&
          origin.host.isNotEmpty &&
          origin.userInfo.isEmpty &&
          !origin.hasQuery &&
          !origin.hasFragment &&
          (origin.path.isEmpty || origin.path == '/') &&
          seconds != null &&
          seconds >= 10 &&
          seconds <= 180,
      'invalid_arguments',
    );
    final ca = values['--test-ca'];
    _require(
      ca == null || origin.host == 'localhost',
      'test_ca_requires_localhost',
    );
    final context = ca == null
        ? null
        : (SecurityContext(withTrustedRoots: false)
            ..setTrustedCertificates(ca));
    final http = HttpClient(context: context);
    // Never accept a bad certificate, including in loopback tests.
    final transport = HttpsAuxiliaryTransport(
      origin,
      client: http,
      timeout: const Duration(seconds: 10),
    );
    try {
      final random = Random.secure();
      final identity = await DeviceIdentity.fromSeed(
        List.generate(32, (_) => random.nextInt(256)),
      );
      if (role == 'host') {
        await _host(
          identity,
          transport,
          File(file!),
          Duration(seconds: seconds!),
        );
      } else {
        await _join(
          identity,
          transport,
          File(file!),
          Duration(seconds: seconds!),
        );
      }
    } finally {
      transport.close();
    }
  } catch (error) {
    _report('failed', {'code': _failure(error)});
    exitCode = 1;
  }
}

Future<void> _host(
  DeviceIdentity identity,
  HttpsAuxiliaryTransport transport,
  File codeFile,
  Duration timeout,
) async {
  _require(!await codeFile.exists(), 'exchange_file_already_exists');
  final accepted = Completer<TrustedConnection>();
  // Serving can fail during asynchronous file I/O, before the later wait.
  unawaited(
    accepted.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
  );
  final request = Completer<VerifiedSessionMessage>();
  final finished = Completer<VerifiedSessionSignal>();
  VerifiedSessionMessage? permit;
  TrustedConnection? connection;
  final host = PairingHost(
    identity: identity,
    clock: _now,
    protocolVersion: 2,
    onConnection: (peer) {
      if (accepted.isCompleted) {
        peer.close('unexpected_peer');
        return;
      }
      connection = peer;
      peer.attachReceiver(
        onRequest: (message) {
          if (!request.isCompleted) {
            permit = message;
            request.complete(message);
          }
        },
        resolveSession: (id) => id == _session ? permit : null,
        onSignal: (signal) {
          if (!finished.isCompleted) finished.complete(signal);
        },
      );
      accepted.complete(peer);
    },
  );
  final owner = AuxiliaryCancellation();
  MeetingListing? listing;
  var ownsCodeFile = false;
  Future<void>? serving;
  try {
    await host.open(address: InternetAddress.loopbackIPv4);
    listing = await MeetingServiceClient(transport)
        .publish(host, cancellation: owner);
    serving = listing.serve();
    // Observe errors immediately; the acceptance wait below consumes the error.
    unawaited(
      serving.catchError((Object error, StackTrace stack) {
        if (!accepted.isCompleted) accepted.completeError(error, stack);
      }),
    );
    await codeFile.create(exclusive: true);
    ownsCodeFile = true;
    await _protectCodeFile(
      codeFile,
    ); // The file is still empty until protected.
    await codeFile.writeAsString(
      jsonEncode({'code': host.offer!.code}),
      flush: true,
    );
    _report('ready', {
      'selfId': identity.id,
      'signalingPath': 'selected-origin-first-meeting',
    });
    final peer = await accepted.future.timeout(timeout);
    _connected(identity, peer);
    await serving.timeout(const Duration(seconds: 10));
    final message = await request.future.timeout(const Duration(seconds: 10));
    await message.check();
    _require(
      message.operation == SessionOperation.watch &&
          message.sessionId == _session &&
          RegExp(r'^[0-9a-f]{32}$').hasMatch(message.body),
      'invalid_probe_request',
    );
    await peer.sendSignal(message, 'ack:${message.body}');
    final finalSignal = await finished.future.timeout(
      const Duration(seconds: 10),
    );
    await finalSignal.check();
    _require(
      finalSignal.body == 'finished:${message.body}',
      'invalid_probe_receipt',
    );
    _report('encrypted_round_trip');
  } finally {
    Object? cleanupError;
    var registrationRevoked = false;
    Future<void> clean(Future<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        cleanupError ??= error;
      }
    }

    owner.cancel();
    connection?.close('probe_done');
    await clean(() async {
      await listing?.close();
    });
    await clean(host.close);
    await clean(() async {
      await connection?.whenTransportClosed;
    });
    await clean(() async {
      if (ownsCodeFile && await codeFile.exists()) await codeFile.delete();
    });
    await clean(() async {
      await AuxiliaryServiceClient(transport)
          .revokeRegistration(identity, cancellation: AuxiliaryCancellation());
      registrationRevoked = true;
    });
    if (cleanupError != null) {
      _report('cleanup_failed', {'code': _failure(cleanupError!)});
      exitCode = 1;
    }
    if (connection != null) {
      _require(
        connection!.grant!.phase == GrantPhase.revoked,
        'grant_not_revoked',
      );
      _report('closed', {
        'grantRevoked': true,
        'registrationRevoked': registrationRevoked,
      });
    }
  }
}

Future<void> _join(
  DeviceIdentity identity,
  HttpsAuxiliaryTransport transport,
  File codeFile,
  Duration timeout,
) async {
  _require(await codeFile.length() <= 128, 'invalid_exchange_file');
  final input = jsonDecode(await codeFile.readAsString());
  _require(
    input is Map &&
        input.length == 1 &&
        input['code'] is String &&
        RegExp(r'^[0-9]{6}$').hasMatch(input['code'] as String),
    'invalid_exchange_file',
  );
  final code = input['code'] as String;
  final owner = AuxiliaryCancellation();
  final attempt = PairingAttempt(
    identity: identity,
    clock: _now,
    protocolVersion: 2,
  );
  final deadline = Timer(timeout, () {
    owner.cancel();
    attempt.cancel();
  });
  TrustedConnection? connection;
  try {
    connection = await attempt.connectWithWire(
      () => MeetingServiceClient(transport).join(code, cancellation: owner),
      code,
    );
    _connected(identity, connection);
    final nonce = List.generate(
      16,
      (_) => Random.secure().nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final permit = await connection.createRequest(
      SessionOperation.watch,
      _session,
      nonce,
    );
    final reply = Completer<VerifiedSessionSignal>();
    connection.attachReceiver(
      onRequest: (_) {},
      resolveSession: (id) => id == _session ? permit : null,
      onSignal: (message) {
        if (!reply.isCompleted) reply.complete(message);
      },
    );
    await connection.sendRequest(permit);
    final signal = await reply.future.timeout(const Duration(seconds: 10));
    await signal.check();
    _require(signal.body == 'ack:$nonce', 'invalid_probe_reply');
    await connection.sendSignal(permit, 'finished:$nonce');
    _report('encrypted_round_trip');
    await connection.whenClosed.timeout(const Duration(seconds: 10));
  } finally {
    deadline.cancel();
    owner.cancel();
    attempt.cancel();
    connection?.close('probe_done');
    await connection?.whenTransportClosed;
    if (connection != null) {
      _require(
        connection.grant!.phase == GrantPhase.revoked,
        'grant_not_revoked',
      );
      _report('closed', {'grantRevoked': true});
    }
  }
}
