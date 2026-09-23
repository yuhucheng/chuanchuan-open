import 'dart:async';

import 'package:flutter/services.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

final class ClipboardNativeSnapshot {
  const ClipboardNativeSnapshot(this.sequence, this.text);
  final int sequence;
  final String? text;
}

enum ClipboardNativeWriteStatus { written, conflict, rejected, unknown }

final class ClipboardNativeWriteResult {
  const ClipboardNativeWriteResult(this.status, this.sequence);
  final ClipboardNativeWriteStatus status;
  final int? sequence;
}

/// One local OS lease for an authenticated control pair. This adapter does not
/// start synchronization or advertise clipboard capability to the product.
final class WindowsControlClipboardAccess {
  WindowsControlClipboardAccess._(
    this._context,
    this._channel,
    this._lease,
    this._epoch,
    this._controllerRevision,
    this._targetRevision,
  ) {
    _invalidations = _context.authorization.invalidated.listen((_) {
      unawaited(close().catchError((Object _) {}));
    });
  }

  static const _maxSequence = 0xffffffff;
  final ControlContext _context;
  final MethodChannel _channel;
  final int _lease, _epoch, _controllerRevision, _targetRevision;
  late final StreamSubscription<void> _invalidations;
  Future<void>? _closing;
  bool _closed = false;
  bool _released = false;

  static Future<WindowsControlClipboardAccess> open({
    required ControlContext context,
    required int epoch,
    required ClipboardSideState controllerState,
    required ClipboardSideState targetState,
    MethodChannel channel = const MethodChannel('dev.sharehub.client/platform'),
  }) async {
    if (!context.start.capabilities.contains(ControlCapability.clipboardText) ||
        !controllerState.permitsSync ||
        !targetState.permitsSync ||
        epoch < 1) {
      throw const SessionFailure('capability_unavailable');
    }
    await context.check();
    final Object? raw;
    try {
      raw = await channel.invokeMethod<Object?>('control.clipboard.open', {
        'deadlineMicros': context.authorization.expiresMicros,
        'epoch': epoch,
        'controllerRevision': controllerState.revision,
        'targetRevision': targetState.revision,
      });
    } on PlatformException catch (error) {
      throw SessionFailure(error.code);
    } on MissingPluginException {
      throw const SessionFailure('platform_unavailable');
    }
    if (raw is! int || raw < 1) {
      throw const SessionFailure('invalid_native_result');
    }
    final access = WindowsControlClipboardAccess._(
      context,
      channel,
      raw,
      epoch,
      controllerState.revision,
      targetState.revision,
    );
    try {
      await context.check();
      return access;
    } catch (_) {
      await access.close();
      rethrow;
    }
  }

  Map<String, Object> get _scope => {
    'lease': _lease,
    'epoch': _epoch,
    'controllerRevision': _controllerRevision,
    'targetRevision': _targetRevision,
  };

  Future<void> _check() async {
    if (_closed) throw const SessionFailure('operation_stopped');
    await _context.check();
    if (_closed) throw const SessionFailure('operation_stopped');
  }

  Future<Object?> _call(String method, Map<String, Object> args) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on PlatformException catch (error) {
      throw SessionFailure(error.code);
    } on MissingPluginException {
      throw const SessionFailure('platform_unavailable');
    }
  }

  Future<ClipboardNativeSnapshot> read() async {
    await _check();
    final raw = await _call('control.clipboard.read', _scope);
    await _check();
    if (raw is! Map ||
        raw.length != 2 ||
        !raw.containsKey('sequence') ||
        !raw.containsKey('text') ||
        raw['sequence'] is! int ||
        (raw['sequence'] as int) < 1 ||
        (raw['sequence'] as int) > _maxSequence ||
        (raw['text'] != null && raw['text'] is! String)) {
      throw const SessionFailure('invalid_native_result');
    }
    return ClipboardNativeSnapshot(
      raw['sequence'] as int,
      raw['text'] as String?,
    );
  }

  Future<ClipboardNativeWriteResult> write({
    required int expectedSequence,
    required String text,
  }) async {
    if (expectedSequence < 1 || expectedSequence > _maxSequence) {
      throw const SessionFailure('invalid_range');
    }
    // The public message validates UTF-8 length and surrogate pairs. Native
    // CF_UNICODETEXT is NUL-terminated, so reject embedded NUL before dispatch.
    if (text.contains('\u0000')) {
      throw const SessionFailure('invalid_message');
    }
    ClipboardCommit(
      epoch: _epoch,
      controllerStateRevision: _controllerRevision,
      targetStateRevision: _targetRevision,
      revision: 1,
      text: text,
    );
    await _check();
    final raw = await _call('control.clipboard.write', {
      ..._scope,
      'expectedSequence': expectedSequence,
      'text': text,
    });
    await _check();
    if (raw is! Map ||
        raw.length != 2 ||
        !raw.containsKey('status') ||
        !raw.containsKey('sequence')) {
      throw const SessionFailure('invalid_native_result');
    }
    final status = switch (raw['status']) {
      'written' => ClipboardNativeWriteStatus.written,
      'conflict' => ClipboardNativeWriteStatus.conflict,
      'rejected' => ClipboardNativeWriteStatus.rejected,
      'unknown' => ClipboardNativeWriteStatus.unknown,
      _ => throw const SessionFailure('invalid_native_result'),
    };
    final sequence = raw['sequence'];
    if (status == ClipboardNativeWriteStatus.written
        ? sequence is! int || sequence < 1 || sequence > _maxSequence
        : sequence != null) {
      throw const SessionFailure('invalid_native_result');
    }
    if (status == ClipboardNativeWriteStatus.unknown) {
      unawaited(close().catchError((Object _) {}));
    }
    return ClipboardNativeWriteResult(status, sequence as int?);
  }

  Future<void> close() {
    _closed = true;
    if (_released) return Future<void>.value();
    return _closing ??= _finishClose().whenComplete(() => _closing = null);
  }

  Future<void> _finishClose() async {
    await _invalidations.cancel();
    try {
      await _call('control.clipboard.close', {'lease': _lease});
    } on SessionFailure catch (error) {
      if (error.code != 'stale_scope') rethrow;
    }
    _released = true;
  }
}
