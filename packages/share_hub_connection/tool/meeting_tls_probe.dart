import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_connection/src/auxiliary_service.dart'
    show meetingSessionFrameMaxBytes;
import 'package:share_hub_session_api/share_hub_session_api.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError('Expected HTTPS origin, test CA and pinned leaf');
  }
  final pem = await File(args[2]).readAsString();
  final leaf = base64.decode(pem.replaceAll(RegExp(r'-----[^-]+-----|\s'), ''));
  final expected = hashes.sha256.convert(leaf);
  final context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificates(args[1]);
  final http = HttpClient(context: context)
    ..badCertificateCallback = (certificate, host, port) =>
        host == 'localhost' &&
        port == Uri.parse(args[0]).port &&
        hashes.sha256.convert(certificate.der) == expected;
  final transport = HttpsAuxiliaryTransport(
    Uri.parse(args[0]),
    client: http,
    timeout: const Duration(seconds: 10),
  );
  final alice = await DeviceIdentity.fromSeed(List<int>.filled(32, 71));
  final bob = await DeviceIdentity.fromSeed(List<int>.filled(32, 72));
  final accepted = <TrustedConnection>[];
  final host = PairingHost(
    identity: bob,
    clock: () async => 1000000,
    protocolVersion: 2,
    enableRecovery: true,
    onConnection: accepted.add,
  );
  MeetingListing? listing;
  TrustedConnection? client;
  try {
    await host.open(address: InternetAddress.loopbackIPv4);
    final code = host.offer!.code;
    final meeting = MeetingServiceClient(transport);
    listing = await meeting.publish(
      host,
      cancellation: AuxiliaryCancellation(),
    );
    final serving = listing.serve();
    client =
        await PairingAttempt(
              identity: alice,
              clock: () async => 1000000,
              protocolVersion: 2,
              enableRecovery: true,
            )
            .connectWithWire(
              () => meeting.join(code, cancellation: AuxiliaryCancellation()),
              code,
            )
            .timeout(const Duration(seconds: 20));
    await serving.timeout(const Duration(seconds: 10));
    if (accepted.length != 1 ||
        client.grant!.binding.encodedId !=
            accepted.single.grant!.binding.encodedId ||
        client.peerKey != bob.encodedKey ||
        accepted.single.peerKey != alice.encodedKey) {
      throw StateError('Cross-language meeting did not bind both identities');
    }
    final delivered = Completer<VerifiedSessionMessage>();
    accepted.single.attachReceiver(
      onRequest: delivered.complete,
      resolveSession: (_) => null,
      onSignal: (_) {},
    );
    await client.sendRequest(
      await client.createRequest(
        SessionOperation.watch,
        'meeting-tls-watch',
        '',
      ),
    );
    if ((await delivered.future.timeout(const Duration(seconds: 10)))
            .operation !=
        SessionOperation.watch) {
      throw StateError('Encrypted operation was not delivered');
    }
    // Exercise the HTTPS envelope independently of PAKE's encrypted frames:
    // JSON can expand a valid 128 KiB decoded frame well beyond the old poll
    // response cap. The transport must not reject it before the wire can parse.
    final boundaryHost = PairingHost(
      identity: bob,
      clock: () async => 1000000,
      protocolVersion: 2,
      enableRecovery: true,
      onConnection: (_) {},
    );
    await boundaryHost.open(address: InternetAddress.loopbackIPv4);
    String? hostToken, joinerToken, attemptId;
    var activated = false;
    try {
      final offer = boundaryHost.offer!;
      final published = await AuxiliaryServiceClient(transport).publishMeeting(
        bob,
        offer.code,
        offerId: offer.id,
        ttlSeconds: 300,
        cancellation: AuxiliaryCancellation(),
      );
      hostToken = published['token'] as String;
      final joined = await transport.post('/v1/meet/join', {
        'code': offer.code,
      }, AuxiliaryCancellation());
      joinerToken = joined['token'] as String;
      attemptId = joined['attempt'] as String;
      // This isolated transport boundary check has no endpoint grant. The
      // preceding flow exercises real PAKE; activate here only to lift the
      // service's pre-handshake 8 KiB frame cap for an HTTP size probe.
      await transport.post('/v1/meet/activate', {
        'token': hostToken,
        'attempt': attemptId,
        'lifetimeSeconds': '60',
      }, AuxiliaryCancellation());
      activated = true;
      final frame = '\x00' * meetingSessionFrameMaxBytes;
      await transport.post('/v1/meet/send', {
        'token': joinerToken,
        'attempt': attemptId,
        'sequence': '0',
        'frame': frame,
      }, AuxiliaryCancellation());
      final received = await transport.post('/v1/meet/poll', {
        'token': hostToken,
        'attempt': attemptId,
      }, AuxiliaryCancellation());
      if (received['sequence'] != 0 || received['frame'] != frame) {
        throw StateError('Full escaped meeting frame changed in HTTPS transit');
      }
    } finally {
      if (joinerToken != null && attemptId != null) {
        await transport.post('/v1/meet/leave', {
          'token': joinerToken,
          'attempt': attemptId,
        }, AuxiliaryCancellation());
      }
      if (hostToken != null && !activated) {
        await transport.post('/v1/meet/unpublish', {
          'token': hostToken,
        }, AuxiliaryCancellation());
      }
      await boundaryHost.close();
    }
    stdout.writeln(
      'TLS meeting: six-digit v2 PAKE, matching grants and encrypted operation passed',
    );
    stdout.writeln(
      'TLS meeting: full escaped 128 KiB frame passed through Dart HTTPS transport',
    );
  } finally {
    client?.close();
    for (final connection in accepted) {
      connection.close();
    }
    await listing?.close();
    await host.close();
    transport.close();
  }
}
