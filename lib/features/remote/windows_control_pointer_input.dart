import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';

/// The Windows half of one target-side SDK input owner. The caller must bind
/// this to the source actually captured by its control video session. The SDK
/// closes this lease after draining and releasing held input.
final class WindowsControlPointerInput implements ControlNativeInput {
  WindowsControlPointerInput._(
    this._channel,
    this._lease,
    this._geometry,
    this._keyboardText,
  );

  static Future<WindowsControlPointerInput> open({
    required CaptureSource source,
    required ControlGeometry geometry,
    MethodChannel channel = const MethodChannel('dev.sharehub.client/platform'),
    bool keyboardText = false,
    void Function(int lease)? onCleanupFailure,
  }) async {
    if (source.type != CaptureSourceType.screen ||
        !RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(source.id) ||
        int.parse(source.id) >= 256) {
      throw const SessionFailure('invalid_media_source');
    }
    final Object? response;
    try {
      response = await channel.invokeMethod<Object?>('control.pointer.open', {
        'sourceId': source.id,
      });
    } on PlatformException catch (error) {
      throw SessionFailure(
        error.code == 'source_unavailable' || error.code == 'busy'
            ? error.code
            : 'platform_unavailable',
      );
    } on MissingPluginException {
      throw const SessionFailure('platform_unavailable');
    }
    final returnedLease = response is Map ? response['lease'] : null;
    if (response is! Map ||
        response.length != 7 ||
        response.keys.toSet().difference(const {
          'lease',
          'sourceId',
          'left',
          'top',
          'width',
          'height',
          'rotation',
        }).isNotEmpty ||
        response['sourceId'] != source.id ||
        response['lease'] is! int ||
        (response['lease'] as int) < 1) {
      if (returnedLease is int && returnedLease > 0) {
        try {
          await channel.invokeMethod<void>('control.pointer.close', {
            'lease': returnedLease,
          });
        } catch (_) {
          onCleanupFailure?.call(returnedLease);
          throw const SessionFailure('native_cleanup_failed');
        }
      }
      throw const SessionFailure('invalid_native_geometry');
    }
    final lease = response['lease'] as int;
    final left = response['left'];
    final top = response['top'];
    final width = response['width'];
    final height = response['height'];
    final rotation = response['rotation'];
    final valid =
        left is int &&
        top is int &&
        width is int &&
        height is int &&
        rotation is int &&
        left >= -0x80000000 &&
        left <= 0x7fffffff &&
        top >= -0x80000000 &&
        top <= 0x7fffffff &&
        width >= 1 &&
        width <= 65535 &&
        height >= 1 &&
        height <= 65535 &&
        left + width - 1 <= 0x7fffffff &&
        top + height - 1 <= 0x7fffffff &&
        const [0, 90, 180, 270].contains(rotation) &&
        geometry.rotation == rotation &&
        geometry.originX == left &&
        geometry.originY == top &&
        _sameExtent(geometry.width, geometry.scaleX, width) &&
        _sameExtent(geometry.height, geometry.scaleY, height);
    if (!valid) {
      // No input has been sent: retire this binding before reporting mismatch.
      try {
        await channel.invokeMethod<void>('control.pointer.close', {
          'lease': lease,
        });
      } catch (_) {
        onCleanupFailure?.call(lease);
        throw const SessionFailure('native_cleanup_failed');
      }
      throw const SessionFailure('invalid_native_geometry');
    }
    return WindowsControlPointerInput._(channel, lease, geometry, keyboardText);
  }

  static bool _sameExtent(int imageSize, double scale, int nativeSize) {
    if (imageSize == 1 || nativeSize == 1) {
      return imageSize == 1 && nativeSize == 1;
    }
    return ((imageSize - 1) * scale - (nativeSize - 1)).abs() <=
        math.max(1e-6, nativeSize * 1e-9);
  }

  final MethodChannel _channel;
  final int _lease;
  final ControlGeometry _geometry;
  final bool _keyboardText;
  bool _closed = false;

  @override
  Set<ControlCapability> get supportedInputCapabilities => {
    ControlCapability.pointer,
    ControlCapability.wheel,
    if (_keyboardText) ControlCapability.physicalKey,
    if (_keyboardText) ControlCapability.textInput,
  };

  @override
  void requireCurrentGeometry(ControlGeometry geometry) {
    if (_closed ||
        geometry.sourceToken != _geometry.sourceToken ||
        geometry.revision != _geometry.revision ||
        geometry.mediaRevision != _geometry.mediaRevision ||
        geometry.width != _geometry.width ||
        geometry.height != _geometry.height ||
        geometry.originX != _geometry.originX ||
        geometry.originY != _geometry.originY ||
        geometry.scaleX != _geometry.scaleX ||
        geometry.scaleY != _geometry.scaleY ||
        geometry.rotation != _geometry.rotation) {
      throw const SessionFailure('stale_geometry');
    }
  }

  @override
  Future<void> verifyCurrentGeometry(ControlGeometry geometry) async {
    requireCurrentGeometry(geometry);
    final current = await _channel.invokeMethod<bool>(
      'control.pointer.current',
      {'lease': _lease},
    );
    if (current != true) throw const SessionFailure('stale_geometry');
    requireCurrentGeometry(geometry);
  }

  @override
  Future<bool> execute(ControlInput input, ControlGeometry geometry) async {
    requireCurrentGeometry(geometry);
    final Map<String, Object> args = {'lease': _lease};
    switch (input) {
      case ControlPointerMove(:final x, :final y):
        args.addAll({'kind': 'move', 'x': x, 'y': y});
      case ControlPointerButton(:final x, :final y, :final button, :final down):
        args.addAll({
          'kind': 'button',
          'x': x,
          'y': y,
          'button': button.name,
          'down': down,
        });
      case ControlWheel(:final x, :final y, :final deltaX, :final deltaY):
        args.addAll({
          'kind': 'wheel',
          'x': x,
          'y': y,
          'deltaX': deltaX,
          'deltaY': deltaY,
        });
      case ControlTextInput(:final text):
        if (!_keyboardText) return false;
        return await _channel.invokeMethod<bool>('control.input.text', {
              'lease': _lease,
              'text': text,
            }) ??
            false;
      case ControlKey(:final usage, :final action):
        if (!_keyboardText) return false;
        return await _channel.invokeMethod<bool>('control.input.key', {
              'lease': _lease,
              'usage': usage,
              'action': action.name,
            }) ??
            false;
    }
    return await _channel.invokeMethod<bool>('control.pointer.execute', args) ??
        false;
  }

  @override
  Future<bool> releaseButton(ControlButton button) async =>
      await _channel.invokeMethod<bool>('control.pointer.releaseButton', {
        'lease': _lease,
        'button': button.name,
      }) ??
      false;

  @override
  Future<bool> releaseKey(int usage) async =>
      await _channel.invokeMethod<bool>('control.input.releaseKey', {
        'lease': _lease,
        'usage': usage,
      }) ??
      false;

  @override
  Future<bool> releasePendingText() async =>
      await _channel.invokeMethod<bool>('control.input.releaseText', {
        'lease': _lease,
      }) ??
      false;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _channel.invokeMethod<void>('control.pointer.close', {
        'lease': _lease,
      });
    } catch (_) {
      _closed = false;
      rethrow;
    }
  }
}
