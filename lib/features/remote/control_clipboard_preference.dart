import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The local user's clipboard decision. It stays sealed until the desktop
/// preference is read; a write changes the live value before persistence.
final class ControlClipboardPreference extends ChangeNotifier
    implements ValueListenable<bool> {
  ControlClipboardPreference({
    this.channel = const MethodChannel('dev.sharehub.client/desktop'),
  });

  final MethodChannel channel;
  bool _value = false;
  bool _disposed = false;
  bool _retryRead = true;
  int _revision = 0;
  Future<void> _writeTail = Future<void>.value();
  String? error;

  @override
  bool get value => _value;

  Future<void> load() async {
    final revision = _revision;
    try {
      final stored = await channel.invokeMethod<bool>('controlClipboard.read');
      if (_disposed || revision != _revision) return;
      if (stored == null) throw const FormatException('missing preference');
      _value = stored;
      _retryRead = false;
      error = null;
      notifyListeners();
    } catch (_) {
      if (_disposed || revision != _revision) return;
      _retryRead = true;
      error = '无法读取剪贴板同步设置；同步已暂停，请重试。';
      notifyListeners();
    }
  }

  Future<void> setEnabled(bool enabled) {
    if (_disposed) return Future<void>.value();
    final revision = ++_revision;
    _value = enabled;
    _retryRead = false;
    error = null;
    notifyListeners();
    return _enqueueWrite(revision);
  }

  Future<void> retry() => _retryRead ? load() : _enqueueWrite(_revision);

  Future<void> _enqueueWrite(int revision) {
    final work = _writeTail.then((_) async {
      if (_disposed || revision != _revision) return;
      try {
        await channel.invokeMethod<void>('controlClipboard.write', _value);
        if (_disposed || revision != _revision) return;
        error = null;
        notifyListeners();
      } catch (_) {
        if (_disposed || revision != _revision) return;
        error = '剪贴板同步设置未能保存，请重试。';
        notifyListeners();
      }
    });
    _writeTail = work;
    return work;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
