import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart' as sdk;

import 'mac_control_geometry_resolver.dart';
import 'remote_media.dart';

/// Explicit macOS pointer/wheel composition for platform acceptance work.
/// Product defaults remain watch/cast until native effects pass real testing.
RtcRemotePictureFactory createMacPointerControlFactory() {
  if (defaultTargetPlatform != TargetPlatform.macOS) {
    throw UnsupportedError('macOS control factory requires macOS');
  }
  const capabilities = {ControlCapability.pointer, ControlCapability.wheel};
  return RtcRemotePictureFactory(
    sdk.RtcRemoteMediaFactory(
      operations: const {
        SessionOperation.watch,
        SessionOperation.cast,
        SessionOperation.control,
      },
      controlCapabilities: capabilities,
      createControlSession: (picture, context) async {
        if (context.localIsController) {
          return sdk.RtcControlOperation(
            context: context,
            picture: picture,
            onControllerStage: (_) async {},
          );
        }
        final native = sdk.MacDeferredControlInput(
          currentSource: () => picture.localSource,
          openLease: picture.resources.openControlInputLease,
        );
        final clock = Stopwatch()..start();
        final input = await sdk.ControlInputExecutor.create(
          context: context,
          slot: picture.slot,
          native: native,
          capabilities: capabilities,
          inputPermission: () async => true,
          monotonicMicros: () => clock.elapsedMicroseconds,
        );
        final geometry = MacControlGeometryResolver(
          readCurrentScreen: picture.resources.readControlScreenGeometry,
        );
        var geometryRevision = 0;
        final operation = sdk.RtcControlOperation(
          context: context,
          picture: picture,
          input: input,
          resolveTargetGeometry: (currentPicture) async {
            final source = currentPicture.localSource;
            final presented = currentPicture.resources.peerPresentation;
            if (source == null || presented == null) {
              throw const SessionFailure('stale_geometry');
            }
            return geometry.resolve(
              source: source,
              presented: presented,
              mediaRevision: currentPicture.mediaRevision,
              geometryRevision: ++geometryRevision,
            );
          },
        );
        final changes = picture.resources.screenChanges.listen((_) {
          if (operation.stopped || operation.targetPublishedGeometry == null) {
            return;
          }
          unawaited(
            operation.refreshTargetGeometry().catchError((Object _) async {
              if (!operation.stopped) {
                try {
                  await operation.stop();
                } catch (_) {
                  // Keep the owner and media slot for cleanup retry.
                }
              }
            }),
          );
        });
        unawaited(operation.done.whenComplete(() => changes.cancel()));
        return operation;
      },
    ),
  );
}
