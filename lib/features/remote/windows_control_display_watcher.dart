import 'package:flutter/services.dart';

/// Delivers native display-layout notifications to the one active Windows
/// target control owner. Calls are serialized so geometry cannot be republished
/// out of order when Windows emits several notifications in quick succession.
final class WindowsControlDisplayWatcher {
  WindowsControlDisplayWatcher({
    required this.onChanged,
    this.channel = const MethodChannel('dev.sharehub.client/control-display'),
  }) {
    channel.setMethodCallHandler(_handle);
  }

  final Future<void> Function() onChanged;
  final MethodChannel channel;
  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  Future<Object?> _handle(MethodCall call) {
    if (call.method != 'changed') throw MissingPluginException();
    if (_closed) return Future<Object?>.value();
    final pending = _tail.then((_) async {
      if (!_closed) await onChanged();
    });
    _tail = pending.catchError((Object _) {});
    return pending;
  }

  Future<void> close() {
    _closed = true;
    channel.setMethodCallHandler(null);
    return _tail;
  }
}
