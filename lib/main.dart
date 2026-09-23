import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';

import 'features/connections/auxiliary_route_controller.dart';
import 'features/connections/connection_controller.dart';
import 'ui/client_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const origin = String.fromEnvironment('CHUANCHUAN_AUX_ORIGIN');
  final routes = AuxiliaryRouteController(
    identity: MethodChannelConnectionPlatform().identity,
    officialOrigin: origin,
    store: const NativeAuxiliaryRouteStore(),
  );
  unawaited(routes.load());
  runApp(
    ShareHubApp(
      appTitle: 'chuanchuan',
      previewEngine: createPreviewEngine(),
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
      auxiliaryRoutes: routes,
      setAuxiliaryNeeded: routes.setNeeded,
      stopAuxiliary: routes.stop,
    ),
  );
}
