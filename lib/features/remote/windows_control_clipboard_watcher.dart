import 'package:flutter/services.dart';

/// A native notification carries no text. The active owner rechecks its own
/// lease and OS change sequence before reading or publishing anything.
final class WindowsControlClipboardWatcher {
  WindowsControlClipboardWatcher({
    required this.onChanged,
    required this.onFailure,
    this.channel = const MethodChannel('dev.sharehub.client/control-clipboard'),
  }) {
    channel.setMethodCallHandler(_handle);
  }

  final Future<void> Function() onChanged;
  final void Function(Object) onFailure;
  final MethodChannel channel;
  Future<void> _tail = Future<void>.value();
  bool _closed = false, _pending = false, _scheduled = false;

  Future<Object?> _handle(MethodCall call) {
    if (call.method != 'changed') throw MissingPluginException();
    if (_closed) return Future<Object?>.value();
    _pending = true;
    if (!_scheduled) {
      _scheduled = true;
      _tail = _tail.then((_) async {
        try {
          while (_pending && !_closed) {
            _pending = false;
            await onChanged();
          }
        } catch (error) {
          final wasClosed = _closed;
          _closed = true;
          channel.setMethodCallHandler(null);
          if (!wasClosed) onFailure(error);
        } finally {
          _scheduled = false;
        }
      });
    }
    return _tail.then<Object?>((_) => null);
  }

  Future<void> close() {
    _closed = true;
    _pending = false;
    channel.setMethodCallHandler(null);
    return _tail;
  }
}
