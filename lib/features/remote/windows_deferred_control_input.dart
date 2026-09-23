import 'package:flutter/services.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';

import 'windows_control_pointer_input.dart';

/// Pins one control picture's screen source and opens its native input lease
/// only when the matching authenticated geometry reaches input readiness.
final class WindowsDeferredControlInput implements ControlNativeInput {
  WindowsDeferredControlInput({
    required this.currentSource,
    this.channel = const MethodChannel('dev.sharehub.client/platform'),
    this.keyboardText = false,
  });

  final CaptureSource? Function() currentSource;
  final MethodChannel channel;
  final bool keyboardText;
  ControlGeometry? _geometry;
  ControlGeometry? _boundGeometry;
  CaptureSource? _boundSource;
  WindowsControlPointerInput? _input;
  Future<WindowsControlPointerInput>? _opening;
  Future<void>? _closing;
  bool _closed = false;
  int? _failedOpenLease;

  @override
  Set<ControlCapability> get supportedInputCapabilities => {
    ControlCapability.pointer,
    ControlCapability.wheel,
    if (keyboardText) ControlCapability.physicalKey,
    if (keyboardText) ControlCapability.textInput,
  };

  @override
  void requireCurrentGeometry(ControlGeometry geometry) {
    if (_closed) throw const SessionFailure('operation_stopped');
    final pinned = _geometry;
    if (pinned == null) {
      _geometry = geometry;
    } else if (!identical(pinned, geometry)) {
      if (geometry.revision <= pinned.revision || _opening != null) {
        throw const SessionFailure('stale_geometry');
      }
      _geometry = geometry;
    }
    if (identical(_boundGeometry, geometry)) {
      final source = _boundSource;
      if (source != null && !identical(source, currentSource())) {
        throw const SessionFailure('stale_geometry');
      }
      _input?.requireCurrentGeometry(geometry);
    }
  }

  @override
  Future<void> verifyCurrentGeometry(ControlGeometry geometry) async {
    requireCurrentGeometry(geometry);
    if (_failedOpenLease != null) {
      throw const SessionFailure('native_cleanup_failed');
    }
    final input = identical(_boundGeometry, geometry) && _input != null
        ? _input!
        : await (_opening ??= _open(geometry)
              .whenComplete(() => _opening = null));
    if (_closed) throw const SessionFailure('operation_stopped');
    await input.verifyCurrentGeometry(geometry);
    requireCurrentGeometry(geometry);
  }

  Future<WindowsControlPointerInput> _open(ControlGeometry geometry) async {
    final old = _input;
    if (old != null) {
      await old.close();
      _input = null;
      _boundSource = null;
      _boundGeometry = null;
      if (_closed || !identical(_geometry, geometry)) {
        throw const SessionFailure('operation_stopped');
      }
    }
    final source = currentSource();
    if (source == null) throw const SessionFailure('source_unavailable');
    final opened = await WindowsControlPointerInput.open(
      source: source,
      geometry: geometry,
      channel: channel,
      keyboardText: keyboardText,
      onCleanupFailure: (lease) => _failedOpenLease = lease,
    );
    _input = opened;
    _boundSource = source;
    _boundGeometry = geometry;
    if (_closed ||
        !identical(_geometry, geometry) ||
        !identical(currentSource(), source)) {
      await opened.close();
      throw const SessionFailure('operation_stopped');
    }
    return opened;
  }

  @override
  Future<bool> execute(ControlInput input, ControlGeometry geometry) async {
    requireCurrentGeometry(geometry);
    if (input is! ControlPointerMove &&
        input is! ControlPointerButton &&
        input is! ControlWheel &&
        !(keyboardText && (input is ControlKey || input is ControlTextInput))) {
      return false;
    }
    final bound = _input;
    if (bound == null) throw const SessionFailure('stale_geometry');
    return bound.execute(input, geometry);
  }

  @override
  Future<bool> releaseKey(int usage) async =>
      _input?.releaseKey(usage) ?? false;

  @override
  Future<bool> releaseButton(ControlButton button) async =>
      _input?.releaseButton(button) ?? false;

  @override
  Future<bool> releasePendingText() async =>
      _input?.releasePendingText() ?? true;

  @override
  Future<void> close() {
    _closed = true;
    return _closing ??= _finishClose().whenComplete(() => _closing = null);
  }

  Future<void> _finishClose() async {
    Object? openFailure;
    try {
      await _opening;
    } catch (error) {
      openFailure = error;
    }
    await _input?.close();
    final failedLease = _failedOpenLease;
    if (failedLease != null) {
      try {
        await channel.invokeMethod<void>('control.pointer.close', {
          'lease': failedLease,
        });
      } on PlatformException catch (error) {
        if (error.code != 'stale_operation') {
          throw const SessionFailure('native_cleanup_failed');
        }
      } catch (_) {
        throw const SessionFailure('native_cleanup_failed');
      }
      _failedOpenLease = null;
    } else if (openFailure is SessionFailure &&
        openFailure.code == 'native_cleanup_failed') {
      throw openFailure;
    }
  }
}
