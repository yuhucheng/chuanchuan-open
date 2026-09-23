import 'dart:async';

import 'package:flutter/services.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import 'windows_control_clipboard_controller_owner.dart';
import 'windows_control_clipboard_target_owner.dart';

/// One Windows control operation's clipboard handshake and local OS owner.
/// The SDK validates the sender and exact authority before calling [receive].
final class WindowsControlClipboardPair {
  WindowsControlClipboardPair({
    required this.context,
    required this.send,
    required this.onFailure,
    bool enabled = true,
    this.channel = const MethodChannel('dev.sharehub.client/platform'),
    this.notificationChannel = const MethodChannel(
      'dev.sharehub.client/control-clipboard',
    ),
    this.newUpdateId,
    this.monotonicMicros,
    this.flushInterval = const Duration(milliseconds: 250),
  }) : _local = ClipboardSideState(
         revision: 1,
         enabled: enabled,
         available: true,
       ) {
    if (!context.start.capabilities.contains(ControlCapability.clipboardText)) {
      throw const SessionFailure('capability_unavailable');
    }
    if (flushInterval <= Duration.zero) {
      throw const SessionFailure('invalid_range');
    }
  }

  final ControlContext context;
  final MethodChannel channel, notificationChannel;
  final String Function()? newUpdateId;
  final int Function()? monotonicMicros;
  final Duration flushInterval;
  final void Function(Object error) onFailure;
  final Future<void> Function(ClipboardWireMessage) send;
  ClipboardSideState _local;
  ClipboardSideState? _peer;
  WindowsControlClipboardControllerOwner? _controller;
  WindowsControlClipboardTargetOwner? _target;
  Future<void> _tail = Future<void>.value();
  Future<void>? _stopping;
  Timer? _flushTimer;
  int _nextEpoch = 0, _lastReadyEpoch = 0;
  bool _pictureReady = false, _closed = false;

  bool get pictureReady => _pictureReady && !_closed;

  Future<T> _serialize<T>(Future<T> Function() work) {
    if (_closed) {
      return Future<T>.error(const SessionFailure('operation_stopped'));
    }
    final result = _tail.then((_) async {
      if (_closed) throw const SessionFailure('operation_stopped');
      await context.check();
      if (_closed) throw const SessionFailure('operation_stopped');
      return work();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> markPictureReady() => _serialize(() async {
    if (_pictureReady) return;
    _pictureReady = true;
    if (!_local.available) {
      _local = ClipboardSideState(
        revision: _local.revision + 1,
        enabled: _local.enabled,
        available: true,
      );
    }
    await send(_local);
    if (_closed) return;
    await _maybeOpenTarget();
  });

  Future<void> receive(ClipboardWireMessage message) => _serialize(() async {
    if (message is ClipboardSideState) {
      final old = _peer;
      if (old != null &&
          (message.revision < old.revision ||
              (message.revision == old.revision &&
                  (message.enabled != old.enabled ||
                      message.available != old.available)))) {
        throw const SessionFailure('stale_operation');
      }
      if (old != null && message.revision == old.revision) return;
      _peer = message;
      await _retireOwner();
      if (_closed) return;
      await _maybeOpenTarget();
      return;
    }
    if (!_pictureReady) throw const SessionFailure('not_ready');
    if (context.localIsController) {
      if (message is ClipboardReady) {
        final peer = _peer;
        if (peer == null ||
            !_local.permitsSync ||
            !peer.permitsSync ||
            message.epoch <= _lastReadyEpoch ||
            message.controllerStateRevision != _local.revision ||
            message.targetStateRevision != peer.revision) {
          throw const SessionFailure('stale_operation');
        }
        await _retireOwner();
        final owner = await WindowsControlClipboardControllerOwner.open(
          context: context,
          ready: message,
          controllerState: _local,
          targetState: peer,
          pictureReady: _pictureReady,
          send: send,
          channel: channel,
          newUpdateId: newUpdateId,
          monotonicMicros: monotonicMicros,
        );
        if (_closed || !_pictureReady) {
          await owner.close();
          throw const SessionFailure('operation_stopped');
        }
        _lastReadyEpoch = message.epoch;
        _controller = owner;
        owner.startWatching(
          notificationChannel: notificationChannel,
          onFailure: _fail,
        );
        _startFlushTimer();
        return;
      }
      final owner = _controller;
      if (owner == null) throw const SessionFailure('stale_operation');
      await owner.receive(message);
      return;
    }
    final owner = _target;
    if (owner == null) throw const SessionFailure('stale_operation');
    await owner.receive(message);
  });

  Future<void> _maybeOpenTarget() async {
    final peer = _peer;
    if (_closed ||
        !_pictureReady ||
        context.localIsController ||
        _target != null ||
        !_local.permitsSync ||
        peer == null ||
        !peer.permitsSync) {
      return;
    }
    if (_nextEpoch == 0x7fffffffffffffff) {
      throw const SessionFailure('operation_limit');
    }
    final owner = await WindowsControlClipboardTargetOwner.open(
      context: context,
      epoch: ++_nextEpoch,
      controllerState: peer,
      targetState: _local,
      pictureReady: true,
      send: send,
      channel: channel,
      monotonicMicros: monotonicMicros,
    );
    if (_closed || !_pictureReady) {
      await owner.close();
      throw const SessionFailure('operation_stopped');
    }
    _target = owner;
    owner.startWatching(
      notificationChannel: notificationChannel,
      onFailure: _fail,
    );
    _startFlushTimer();
  }

  void _startFlushTimer() {
    _flushTimer ??= Timer.periodic(flushInterval, (_) {
      unawaited(
        _serialize(() async {
          if (!_pictureReady) return;
          await _controller?.flush();
          await _target?.flush();
        }).catchError((Object error) {
          if (!_closed && _pictureReady) _fail(error);
        }),
      );
    });
  }

  void _fail(Object error) {
    unawaited(stop().catchError((Object _) {}));
    onFailure(error);
  }

  Future<void> _retireOwner() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final controller = _controller;
    final target = _target;
    _controller = null;
    _target = null;
    return Future.wait<void>([
      if (controller != null) controller.close(),
      if (target != null) target.close(),
    ]).then((_) {});
  }

  /// Called by the SDK before awaiting input release on source/mapping loss.
  Future<void> invalidatePicture() {
    if (_closed || !_pictureReady) return Future<void>.value();
    _pictureReady = false;
    _local = ClipboardSideState(
      revision: _local.revision + 1,
      enabled: _local.enabled,
      available: false,
    );
    final cleanup = _retireOwner();
    final notice = send(_local);
    return Future.wait<void>([cleanup, notice]).then((_) {});
  }

  /// Local setting changes seal the current OS lease before the new state is
  /// signalled. Enabling again always needs a fresh target-authoritative epoch.
  Future<void> setEnabled(bool enabled) {
    if (_closed) {
      return Future<void>.error(const SessionFailure('operation_stopped'));
    }
    if (_local.enabled == enabled) return Future<void>.value();
    if (_local.revision == 0x7fffffffffffffff) {
      return Future<void>.error(const SessionFailure('operation_limit'));
    }
    _local = ClipboardSideState(
      revision: _local.revision + 1,
      enabled: enabled,
      available: _local.available,
    );
    final cleanup = _retireOwner();
    final notice = _pictureReady ? send(_local) : Future<void>.value();
    return Future.wait<void>([cleanup, notice]).then((_) {
      if (_closed) return Future<void>.value();
      return _serialize(_maybeOpenTarget);
    });
  }

  Future<void> stop() {
    if (_stopping != null) return _stopping!;
    _closed = true;
    _pictureReady = false;
    final cleanup = _retireOwner();
    return _stopping = Future.wait<void>([cleanup, _tail]).then((_) {});
  }
}
