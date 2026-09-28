import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';

import 'features/connections/connection_controller.dart';
import 'features/connections/auxiliary_route_controller.dart';
import 'ui/client_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The official origin is part of the normal client build. A build-time value
  // may select a test deployment; a custom LAN choice never falls back here.
  const origin = String.fromEnvironment(
    'CHUANCHUAN_AUX_ORIGIN',
    defaultValue: 'https://chuanchuan.xyz:8443',
  );
  final routes = AuxiliaryRouteController(
    identity: MethodChannelConnectionPlatform().identity,
    officialOrigin: origin,
    store: const NativeAuxiliaryRouteStore(),
  );
  unawaited(routes.ensureLoaded());
  runApp(
    ShareHubApp(
      appTitle: 'chuanchuan',
      auxiliaryRoutes: routes,
      previewEngine: createPreviewEngine(
        currentRelayLease: () {
          final lease = routes.current;
          if (lease == null) return null;
          return RelayIceLease(
            urls: lease.urls,
            username: lease.username,
            credential: lease.credential,
            expiresAt: lease.expiresAt,
          );
        },
      ),
      stopAuxiliary: routes.stop,
      setAuxiliaryNeeded: routes.setNeeded,
      relayCredentialAvailable: () => routes.current != null,
      relayCredentialChanges: routes,
    ),
  );
}
