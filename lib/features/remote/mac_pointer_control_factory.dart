import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart' as sdk;

import 'mac_control_geometry_resolver.dart';
import 'remote_media.dart';
import 'windows_control_clipboard_pair.dart';

/// Capability-limited macOS input composition, also used by the product.
RtcRemotePictureFactory createMacPointerControlFactory({
  MethodChannel channel = const MethodChannel('dev.sharehub.client/platform'),
  bool keyboardText = false,
  bool clipboardText = false,
  ValueListenable<bool>? clipboardSetting,
  sdk.RelayIceLease? Function()? currentRelayLease,
}) {
  if (defaultTargetPlatform != TargetPlatform.macOS) {
    throw UnsupportedError('macOS control factory requires macOS');
  }
  final capabilities = {
    ControlCapability.pointer,
    ControlCapability.wheel,
    if (keyboardText) ControlCapability.physicalKey,
    if (keyboardText) ControlCapability.textInput,
    if (clipboardText) ControlCapability.clipboardText,
  };
  return RtcRemotePictureFactory(
    sdk.RtcRemoteMediaFactory(
      operations: const {
        SessionOperation.watch,
        SessionOperation.cast,
        SessionOperation.control,
      },
      controlCapabilities: capabilities,
      currentRelayLease: currentRelayLease,
      createControlSession: (picture, context) async {
        late final sdk.RtcControlOperation operation;
        // The Dart pair owns the shared protocol; this channel selects the
        // macOS lease-backed AppKit clipboard implementation.
        final clipboard =
            context.start.capabilities.contains(ControlCapability.clipboardText)
            ? WindowsControlClipboardPair(
                context: context,
                enabled: clipboardSetting?.value ?? true,
                channel: channel,
                send: (message) => operation.sendClipboard(message),
                onFailure: (_) {
                  unawaited(operation.stop().catchError((Object _) {}));
                },
              )
            : null;
        void bindClipboardSetting() {
          final setting = clipboardSetting;
          final pair = clipboard;
          if (setting == null || pair == null) return;
          void changed() {
            unawaited(
              pair.setEnabled(setting.value).catchError((Object _) {
                if (!operation.stopped) {
                  unawaited(operation.stop().catchError((Object _) {}));
                }
              }),
            );
          }

          setting.addListener(changed);
          unawaited(
            operation.done.whenComplete(() => setting.removeListener(changed)),
          );
          changed();
        }

        if (context.localIsController) {
          operation = sdk.RtcControlOperation(
            context: context,
            picture: picture,
            onControllerStage: (stage) async {
              if (stage is ControlGeometryPublished &&
                  clipboard?.pictureReady == true) {
                await clipboard!.invalidatePicture();
              }
              if (stage is ControlInputReady) {
                await clipboard?.markPictureReady();
              }
            },
            onClipboardMessage: clipboard?.receive,
            stopClipboard: clipboard?.stop,
          );
          bindClipboardSetting();
          return operation;
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
        operation = sdk.RtcControlOperation(
          context: context,
          picture: picture,
          input: input,
          onClipboardMessage: clipboard?.receive,
          stopClipboard: clipboard?.stop,
          onTargetInputReady: clipboard == null
              ? null
              : (_) => clipboard.markPictureReady(),
          onTargetPictureInvalidated: clipboard?.invalidatePicture,
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
        bindClipboardSetting();
        return operation;
      },
    ),
  );
}

/// Normal macOS client composition with native pointer, keyboard, text and
/// the user's current pure-text clipboard preference.
RtcRemotePictureFactory createMacControlFactory({
  MethodChannel channel = const MethodChannel('dev.sharehub.client/platform'),
  ValueListenable<bool>? clipboardSetting,
  sdk.RelayIceLease? Function()? currentRelayLease,
}) => createMacPointerControlFactory(
  channel: channel,
  keyboardText: true,
  clipboardText: true,
  clipboardSetting: clipboardSetting,
  currentRelayLease: currentRelayLease,
);
