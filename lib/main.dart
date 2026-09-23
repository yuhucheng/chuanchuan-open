import 'package:flutter/material.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';

import 'features/connections/connection_controller.dart';
import 'features/connections/relay_credential_owner.dart';
import 'ui/client_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Supply an audited official HTTPS origin at build time. Empty or invalid
  // configuration leaves local/direct connections available without a cloud
  // request; no production endpoint is silently assumed.
  const origin = String.fromEnvironment('CHUANCHUAN_AUX_ORIGIN');
  RelayCredentialOwner? relay;
  if (origin.isNotEmpty) {
    try {
      final transport = HttpsAuxiliaryTransport(Uri.parse(origin));
      relay = RelayCredentialOwner(
        MethodChannelConnectionPlatform().identity,
        AuxiliaryServiceClient(transport),
        transport.close,
      );
    } on FormatException {
      debugPrint(
        'Invalid auxiliary service origin; direct connection remains available.',
      );
    } on ArgumentError {
      debugPrint(
        'Invalid auxiliary service origin; direct connection remains available.',
      );
    }
  }
  runApp(
    ShareHubApp(
      appTitle: 'chuanchuan',
      previewEngine: createPreviewEngine(
        currentRelayLease: () {
          final lease = relay?.current;
          if (lease == null) return null;
          return RelayIceLease(
            urls: lease.urls,
            username: lease.username,
            credential: lease.credential,
            expiresAt: lease.expiresAt,
          );
        },
      ),
      stopAuxiliary: relay?.stop,
      setAuxiliaryNeeded: relay?.setNeeded,
      relayCredentialAvailable: () => relay?.current != null,
    ),
  );
}
