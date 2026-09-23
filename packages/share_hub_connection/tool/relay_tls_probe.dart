import 'dart:async';
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

final class _CuttableProxy {
  late ServerSocket server;
  final sockets = <Socket>[];

  Future<void> start(int target) async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((client) async {
      sockets.add(client);
      final remote = await Socket.connect('127.0.0.1', target);
      sockets.add(remote);
      client.listen(remote.add, onDone: remote.destroy);
      remote.listen(client.add, onDone: client.destroy);
    });
  }

  void cut() {
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
  }

  Future<void> close() async {
    cut();
    await server.close();
  }
}

Future<void> probeRecovery(
  RelayServiceClient client,
  DeviceIdentity alice,
  DeviceIdentity bob,
) async {
  var now = 1000000;
  final accepted = <TrustedConnection>[];
  final host = PairingHost(
    identity: bob,
    clock: () async => now,
    protocolVersion: 2,
    enableRecovery: true,
    onConnection: accepted.add,
  );
  await host.open(address: InternetAddress.loopbackIPv4);
  final proxy = _CuttableProxy();
  await proxy.start(host.port!);
  TrustedConnection? original, resumed, resumedRemote;
  try {
    original = await PairingAttempt(
      identity: alice,
      clock: () async => now,
      protocolVersion: 2,
      enableRecovery: true,
    ).connect('127.0.0.1', proxy.server.port, host.offer!.code);
    final previousRemote = accepted.single;
    final expiry = original.grant!.expiresMicros;
    proxy.cut();
    if (await original.whenClosed != 'transport_suspended' ||
        await previousRemote.whenClosed != 'transport_suspended') {
      throw StateError('The original TCP grant was not suspended');
    }
    now += const Duration(minutes: 3).inMicroseconds;
    final generation = original.grant!.generation + 1;
    final ca = await client.open(
      original.grant!,
      alice,
      generation: generation,
      cancellation: AuxiliaryCancellation(),
    );
    final cb = await client.open(
      previousRemote.grant!,
      bob,
      generation: generation,
      cancellation: AuxiliaryCancellation(),
    );
    final aWire = await original.openRelayWire(ca);
    final bWire = await previousRemote.openRelayWire(cb);
    final connecting = ConnectionRecoveryAttempt(original)
        .connectWire(() async => aWire);
    final accepting = previousRemote.acceptRecoveryWire(bWire, () {});
    resumed = await connecting.timeout(const Duration(seconds: 10));
    resumedRemote = await accepting.timeout(const Duration(seconds: 10));
    resumedRemote.startMonitoring();
    if (resumed.grant != original.grant ||
        resumedRemote.grant != previousRemote.grant ||
        resumed.grant!.generation != generation ||
        resumed.grant!.expiresMicros != expiry) {
      throw StateError('Relay recovery replaced or renewed the grant');
    }
    final delivered = Completer<VerifiedSessionMessage>();
    resumedRemote.attachReceiver(
      onRequest: delivered.complete,
      resolveSession: (_) => null,
      onSignal: (_) {},
    );
    await resumed.sendRequest(
      await resumed.createRequest(
        SessionOperation.watch,
        'tls-recovered-watch',
        '',
      ),
    );
    if ((await delivered.future.timeout(const Duration(seconds: 10)))
            .transportGeneration !=
        generation) {
      throw StateError('Recovered operation used the wrong generation');
    }
  } finally {
    resumed?.close();
    resumedRemote?.close();
    original?.close();
    for (final connection in accepted) {
      connection.close();
    }
    await proxy.close();
    await host.close();
  }
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
    await probeRecovery(client, alice, bob);
    stdout.writeln(
      'TLS relay: device proofs, sealed request/cancel and original-grant recovery passed',
    );
  } finally {
    transport.close();
  }
}
