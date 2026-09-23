import 'dart:async';

import 'package:flutter/services.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

import 'windows_control_clipboard_access.dart';
import 'windows_control_clipboard_watcher.dart';

/// The target arbitrates text for exactly one control pair. Clipboard change
/// notifications and authenticated proposals enter the same serial queue.
final class WindowsControlClipboardTargetOwner {
  WindowsControlClipboardTargetOwner._(
    this._context,
    this._access,
    this._state,
    this._send,
    this._sequence,
    this._controllerRevision,
    this._targetRevision,
  );

  final ControlContext _context;
  final WindowsControlClipboardAccess _access;
  final ClipboardTargetState _state;
  final Future<void> Function(ClipboardWireMessage) _send;
  final ClipboardEchoGuard _echo = ClipboardEchoGuard();
  Future<void> _tail = Future<void>.value();
  Future<void>? _closing;
  WindowsControlClipboardWatcher? _watcher;
  int _sequence;
  final int _controllerRevision, _targetRevision;
  bool _closed = false;

  static Future<WindowsControlClipboardTargetOwner> open({
    required ControlContext context,
    required int epoch,
    required ClipboardSideState controllerState,
    required ClipboardSideState targetState,
    required bool pictureReady,
    required Future<void> Function(ClipboardWireMessage) send,
    MethodChannel channel = const MethodChannel('dev.sharehub.client/platform'),
    int Function()? monotonicMicros,
  }) async {
    if (context.localIsController || !pictureReady) {
      throw const SessionFailure('not_ready');
    }
    final access = await WindowsControlClipboardAccess.open(
      context: context,
      epoch: epoch,
      controllerState: controllerState,
      targetState: targetState,
      channel: channel,
    );
    try {
      final baseline = await access.read();
      final state = ClipboardTargetState(monotonicMicros: monotonicMicros);
      final ready = state.open(
        epoch: epoch,
        controllerState: controllerState,
        targetState: targetState,
        pictureReady: pictureReady,
        initialText: baseline.text,
      );
      final owner = WindowsControlClipboardTargetOwner._(
        context,
        access,
        state,
        send,
        baseline.sequence,
        controllerState.revision,
        targetState.revision,
      );
      await send(ready);
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
    await _sendCommits();
  });

  Future<void> _observeCurrent() async {
    final snapshot = await _access.read();
    _requireCurrent();
    if (snapshot.sequence == _sequence) return;
    if (snapshot.sequence < _sequence || snapshot.text == null) {
      // A wrapped token or non-text local change needs a new baseline. Keep
      // the user's OS clipboard untouched and retire this epoch.
      unawaited(close().catchError((Object _) {}));
      throw const SessionFailure('clipboard_unavailable');
    }
    _sequence = snapshot.sequence;
    final observation = _echo.observe(
      changeToken: '${snapshot.sequence}',
      text: snapshot.text,
    );
    if (observation == ClipboardObservation.localText) {
      _state.localCopy(snapshot.text!);
    }
  }

  Future<void> receive(ClipboardWireMessage message) => _serialize(() async {
    if (message is! ClipboardProposal) {
      throw const SessionFailure('direction_denied');
    }
    await _observeCurrent();
    await _sendCommits();
    _requireCurrent();
    final decision = _state.receiveProposal(message);
    if (decision is ClipboardConflict) {
      await _send(decision);
      return;
    }
    final ticket = decision as ClipboardWriteTicket;
    if (!_state.canWrite(ticket)) {
      throw const SessionFailure('stale_operation');
    }
    final result = await _access.write(
      expectedSequence: _sequence,
      text: message.text,
    );
    _requireCurrent();
    switch (result.status) {
      case ClipboardNativeWriteStatus.written:
        final sequence = result.sequence!;
        if (sequence <= _sequence) {
          await close();
          throw const SessionFailure('clipboard_unavailable');
        }
        _state.completeWrite(ticket, succeeded: true);
        _sequence = sequence;
        _echo.recordOwnWrite(changeToken: '$sequence', text: message.text);
        await _sendCommits();
      case ClipboardNativeWriteStatus.conflict:
        final snapshot = await _access.read();
        _requireCurrent();
        if (snapshot.sequence <= _sequence || snapshot.text == null) {
          await close();
          throw const SessionFailure('clipboard_unavailable');
        }
        _sequence = snapshot.sequence;
        final conflict = _state.nativeConflict(
          ticket,
          observedText: snapshot.text!,
        );
        await _send(conflict);
      case ClipboardNativeWriteStatus.rejected:
      case ClipboardNativeWriteStatus.unknown:
        await close();
        throw const SessionFailure('execution_failed');
    }
  });

  Future<void> flush() => _serialize(_sendCommits);

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

  /// Any settings revision change retires this epoch before queued writes can
  /// enter the platform channel. A later enabled pair needs a new baseline.
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

  Future<void> _sendCommits() async {
    while (!_closed) {
      final commit = _state.takeCommit();
      if (commit == null) return;
      _requireCurrent();
      await _send(commit);
      _requireCurrent();
    }
  }

  /// Synchronously closes admission before returning the native cleanup.
  Future<void> close() {
    if (!_closed) {
      _closed = true;
      _state.invalidate();
      _echo.clear();
    }
    return _closing ??= Future.wait<void>([
      if (_watcher != null) _watcher!.close(),
      _access.close(),
    ]).then((_) {}).whenComplete(() => _closing = null);
  }
}
