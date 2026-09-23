import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_session_api/share_hub_session_api.dart';

List<int> encodeSealed(SessionEnvelope envelope) => utf8.encode(
  jsonEncode([
    envelope.generation,
    envelope.sequence,
    base64Url.encode(envelope.ciphertext),
    base64Url.encode(envelope.mac),
  ]),
);

SessionEnvelope decodeSealed(List<int> bytes) {
  final value = jsonDecode(utf8.decode(bytes)) as List<dynamic>;
  return SessionEnvelope(
    generation: value[0] as int,
    sequence: value[1] as int,
    ciphertext: base64Url.decode(value[2] as String),
    mac: base64Url.decode(value[3] as String),
  );
}

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
    ..badCertificateCallback = (certificate, host, port) {
      // The Mac test VM may reject a temporary root; accept only this exact
      // ephemeral localhost leaf, never an arbitrary invalid certificate.
      return host == 'localhost' &&
          port == Uri.parse(args[0]).port &&
          hashes.sha256.convert(certificate.der) == expected;
    };
  await (await http.getUrl(Uri.parse('${args[0]}/health'))).close();
  final transport = HttpsAuxiliaryTransport(
    Uri.parse(args[0]),
    client: http,
    timeout: const Duration(seconds: 35),
  );
  try {
    final alice = await DeviceIdentity.fromSeed(List<int>.filled(32, 1));
    final bob = await DeviceIdentity.fromSeed(List<int>.filled(32, 2));
    final binding = GrantBinding(
      id: List<int>.filled(32, 3),
      initiatorKey: alice.publicKey.bytes,
      receiverKey: bob.publicKey.bytes,
    );
    GrantEndpoint endpoint(GrantRole role) =>
        GrantEndpoint.fromAuthenticatedPairing(
          binding: binding,
          role: role,
          establishedMicros: 0,
          recoverySecret: List<int>.filled(32, 4),
          clock: () async => 0,
          onInvalidated: () {},
        );
    final a = endpoint(GrantRole.initiator), b = endpoint(GrantRole.receiver);
    await b.acceptResume(
      await a.finishResume(await b.answerResume(await a.beginResume())),
    );
    final client = RelayServiceClient(transport);
    final ca = await client.open(
      a,
      alice,
      cancellation: AuxiliaryCancellation(),
    );
    final cb = await client.open(b, bob, cancellation: AuxiliaryCancellation());
    final request = await a.authorizeLocal(
      SessionOperation.watch,
      'tls-probe',
      '',
    );
    await ca.sendSealed(encodeSealed(await a.sealRequest(request)));
    final received = await cb.receive();
    if (received == null ||
        received.kind != RelaySignalKind.data ||
        (await b.open(decodeSealed(received.payload))).operation !=
            SessionOperation.watch) {
      throw StateError('Sealed operation was not delivered and verified');
    }
    await ca.cancel();
    if ((await cb.receive())?.kind != RelaySignalKind.cancel) {
      throw StateError('Terminal cancellation was not forwarded');
    }
    await cb.close();
    a.revoke();
    b.revoke();
    stdout.writeln(
      'TLS relay: both device proofs, sealed request and cancel passed',
    );
  } finally {
    transport.close();
  }
}
