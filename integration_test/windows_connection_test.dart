import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/platform/client_platform.dart';

/// Verifies the Windows host answers the same `dev.sharehub.client/platform`
/// primitives macOS does, so trusted connections are not silently macOS-only.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows host supplies the connection primitives', (tester) async {
    expect(Platform.isWindows, isTrue);
    final connections = MethodChannelConnectionPlatform();

    // Identity: a 32-byte Ed25519 seed from DPAPI-protected storage. Reading it
    // twice must return the same identity, or saved peers could never reconnect.
    final identity = await connections.identity();
    expect(identity.publicKey.bytes.length, 32);
    expect(identity.encodedKey.length, 44);
    final again = await connections.identity();
    expect(again.encodedKey, identity.encodedKey);

    // Clock: monotonic and non-zero, so it can gate eight-hour leases without
    // trusting wall-clock edits or a dead counter.
    final first = await connections.now();
    final second = await connections.now();
    expect(first, greaterThan(0));
    expect(second, greaterThanOrEqualTo(first));
  });

  testWidgets('Windows publishes and clears the connection endpoint', (tester) async {
    expect(Platform.isWindows, isTrue);
    final client = MethodChannelClientPlatform();
    final connections = MethodChannelConnectionPlatform();
    await client.loadDevice();
    await client.startDiscovery();
    try {
      final identity = await connections.identity();
      final host = await connections.advertise(51234, identity.encodedKey);
      expect(host, isNotNull);
      expect(host, endsWith('.local'));
      // Clearing reports the same local host name so the address display resets.
      expect(await connections.advertise(null, null), host);
    } finally {
      await client.stopDiscovery();
    }
  });
}
