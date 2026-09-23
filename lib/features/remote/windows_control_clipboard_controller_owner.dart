import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import 'windows_control_clipboard_access.dart';
import 'windows_control_clipboard_watcher.dart';

/// One controller's local OS clipboard for an authenticated control pair.
/// All local observations and target authority messages run serially.
final class WindowsControlClipboardControllerOwner {
  WindowsControlClipboardControllerOwner._(
    this._context,
    this._access,
    this._state,
    this._send,
    this._newUpdateId,
    this._sequence,
    this._localText,
    this._controllerRevision,
    this._targetRevision,
  );

  static final _random = Random.secure();
  final ControlContext _context;
  final WindowsControlClipboardAccess _access;
  final ClipboardControllerState _state;
  final Future<void> Function(ClipboardWireMessage) _send;
  final String Function() _newUpdateId;
  final ClipboardEchoGuard _echo = ClipboardEchoGuard();
  final int _controllerRevision, _targetRevision;
  Future<void> _tail = Future<void>.value();
  Future<void>? _closing;
  WindowsControlClipboardWatcher? _watcher;
  int _sequence;
  String? _localText;
  bool _closed = false;

  static String _secureId() => List<int>.generate(
    16,
    (_) => _random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static Future<WindowsControlClipboardControllerOwner> open({
    required ControlContext context,
    required ClipboardReady ready,
    required ClipboardSideState controllerState,
    required ClipboardSideState targetState,
    required bool pictureReady,
    required Future<void> Function(ClipboardWireMessage) send,
    MethodChannel channel = const MethodChannel('dev.sharehub.client/platform'),
    String Function()? newUpdateId,
    int Function()? monotonicMicros,
  }) async {
    if (!context.localIsController || !pictureReady) {
      throw const SessionFailure('not_ready');
    }
    final access = await WindowsControlClipboardAccess.open(
      context: context,
      epoch: ready.epoch,
      controllerState: controllerState,
      targetState: targetState,
      channel: channel,
    );
    try {
      final baseline = await access.read();
      final state = ClipboardControllerState(monotonicMicros: monotonicMicros);
      state.acceptReady(
        ready,
        controllerState: controllerState,
        targetState: targetState,
        pictureReady: pictureReady,
      );
      final owner = WindowsControlClipboardControllerOwner._(
        context,
        access,
        state,
        send,
        newUpdateId ?? _secureId,
        baseline.sequence,
        baseline.text,
        controllerState.revision,
        targetState.revision,
      );
      await owner._applyAuthoritative(ready.text);
      owner._requireCurrent();
      return owner;
    } catch (_) {
      await access.close();
      rethrow;
    }
  }

  void _requireCurrent() {
    if (_closed) throw const SessionFailure('operation_stopped');
    _context.requireCurrent();
  }

  Future<T> _serialize<T>(Future<T> Function() work) {
    try {
      _requireCurrent();
    } catch (error, stack) {
      return Future<T>.error(error, stack);
    }
    final result = _tail.then((_) {
      _requireCurrent();
      return work();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> observe() => _serialize(() async {
    await _observeCurrent();
    await _sendProposal();
  });

  Future<void> _observeCurrent() async {
    final snapshot = await _access.read();
    _requireCurrent();
    if (snapshot.sequence == _sequence) return;
    if (snapshot.sequence < _sequence || snapshot.text == null) {
      unawaited(close().catchError((Object _) {}));
      throw const SessionFailure('clipboard_unavailable');
    }
    _sequence = snapshot.sequence;
    _localText = snapshot.text;
    final observation = _echo.observe(
      changeToken: '${snapshot.sequence}',
      text: snapshot.text,
    );
    if (observation == ClipboardObservation.localText) {
      _state.localCopy(snapshot.text!, updateId: _newUpdateId());
    }
  }

  Future<void> receive(ClipboardWireMessage message) => _serialize(() async {
    if (message is! ClipboardCommit &&
        message is! ClipboardConflict &&
        message is! ClipboardWriteFailed) {
      throw const SessionFailure('direction_denied');
    }
    await _observeCurrent();
    _requireCurrent();
    if (message is ClipboardWriteFailed) {
      await close();
      throw const SessionFailure('execution_failed');
    }
    final apply = message is ClipboardCommit
        ? _state.receiveCommit(message)
        : _state.receiveConflict(message as ClipboardConflict);
    if (apply == ClipboardApply.applyRemote) {
      await _applyAuthoritative(_state.authoritativeText);
    }
    await _sendProposal();
  });

  Future<void> _applyAuthoritative(String? text) async {
    _requireCurrent();
    if (text == null || text == _localText) return;
    final result = await _access.write(expectedSequence: _sequence, text: text);
    _requireCurrent();
    switch (result.status) {
      case ClipboardNativeWriteStatus.written:
        final sequence = result.sequence!;
        if (sequence <= _sequence) {
          await close();
          throw const SessionFailure('clipboard_unavailable');
        }
        _sequence = sequence;
        _localText = text;
        _echo.recordOwnWrite(changeToken: '$sequence', text: text);
      case ClipboardNativeWriteStatus.conflict:
        await _observeCurrent();
        await _sendProposal();
      case ClipboardNativeWriteStatus.rejected:
      case ClipboardNativeWriteStatus.unknown:
        await close();
        throw const SessionFailure('execution_failed');
    }
  }

  Future<void> _sendProposal() async {
    _requireCurrent();
    final proposal = _state.takeProposal();
    if (proposal == null) return;
    await _send(proposal);
    _requireCurrent();
  }

  Future<void> flush() => _serialize(_sendProposal);

  void startWatching({
    required void Function(Object) onFailure,
    MethodChannel notificationChannel = const MethodChannel(
      'dev.sharehub.client/control-clipboard',
    ),
  }) {
    _requireCurrent();
    if (_watcher != null) throw const SessionFailure('busy');
    _watcher = WindowsControlClipboardWatcher(
      channel: notificationChannel,
      onChanged: observe,
      onFailure: (error) {
        unawaited(close().catchError((Object _) {}));
        onFailure(error);
      },
    );
  }

  Future<void> settingsChanged({
    required ClipboardSideState controllerState,
    required ClipboardSideState targetState,
  }) {
    _state.settingsChanged(
      controllerState: controllerState,
      targetState: targetState,
    );
    if (!controllerState.permitsSync ||
        !targetState.permitsSync ||
        controllerState.revision != _controllerRevision ||
        targetState.revision != _targetRevision) {
      return close();
    }
    return Future<void>.value();
  }

  /// Synchronously closes admission and clears in-memory text before cleanup.
  Future<void> close() {
    if (!_closed) {
      _closed = true;
      _state.invalidate();
      _echo.clear();
      _localText = null;
    }
    return _closing ??= Future.wait<void>([
      if (_watcher != null) _watcher!.close(),
      _access.close(),
    ]).then((_) {}).whenComplete(() => _closing = null);
  }
}
