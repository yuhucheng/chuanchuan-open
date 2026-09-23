import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart' as sdk;

import 'remote_media.dart';
import 'windows_control_geometry_resolver.dart';
import 'windows_control_display_watcher.dart';
import 'windows_control_screen_geometry.dart';
import 'windows_control_clipboard_pair.dart';
import 'windows_deferred_control_input.dart';

/// Opt-in composition for Windows pointer/wheel control integration tests.
/// The default product factory stays watch/cast until all v0.2 capabilities
/// and real platform acceptance are present.
RtcRemotePictureFactory createWindowsPointerControlFactory({
  MethodChannel channel = const MethodChannel('dev.sharehub.client/platform'),
  bool clipboardText = false,
  bool keyboardText = false,
  ValueListenable<bool>? clipboardSetting,
}) {
  if (defaultTargetPlatform != TargetPlatform.windows) {
    throw UnsupportedError('Windows control factory requires Windows');
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
      createControlSession: (picture, context) async {
        late final sdk.RtcControlOperation operation;
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
            operation.done.whenComplete(() {
              setting.removeListener(changed);
            }),
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
        final native = WindowsDeferredControlInput(
          currentSource: () => picture.localSource,
          channel: channel,
          keyboardText: keyboardText,
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
        final geometry = WindowsControlGeometryResolver(
          probe: WindowsControlScreenGeometryProbe(channel: channel),
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
        final watcher = WindowsControlDisplayWatcher(
          onChanged: () async {
            if (operation.stopped) return;
            final previous = operation.targetPublishedGeometry;
            if (previous == null) return;
            try {
              final source = picture.localSource;
              final presented = picture.resources.peerPresentation;
              if (source == null || presented == null) {
                throw const SessionFailure('stale_geometry');
              }
              final candidate = await geometry.resolve(
                source: source,
                presented: presented,
                mediaRevision: picture.mediaRevision,
                geometryRevision: geometryRevision + 1,
              );
              if (_sameDisplayMapping(previous, candidate)) return;
              await operation.refreshTargetGeometry();
            } catch (_) {
              await operation.stop();
            }
          },
        );
        unawaited(operation.done.then((_) => watcher.close()));
        bindClipboardSetting();
        return operation;
      },
    ),
  );
}

bool _sameDisplayMapping(ControlGeometry a, ControlGeometry b) =>
    a.mediaRevision == b.mediaRevision &&
    a.width == b.width &&
    a.height == b.height &&
    a.originX == b.originX &&
    a.originY == b.originY &&
    a.scaleX == b.scaleX &&
    a.scaleY == b.scaleY &&
    a.rotation == b.rotation;
