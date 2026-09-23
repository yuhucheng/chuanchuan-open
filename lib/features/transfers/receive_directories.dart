import 'dart:async';

import 'package:flutter/foundation.dart';

import 'receive_access.dart';

/// One receiver's use of a directory capability. Failed release remains
/// retryable; a completed release never touches another receiver's reference.
final class ReceiveDirectoryLease {
  ReceiveDirectoryLease(this.directory, this._release);
  ReceiveDirectoryLease.borrowed(this.directory) : _release = _nothing;
  final ReceiveDirectory directory;
  final Future<void> Function() _release;
  Future<void>? _pending;
  bool _released = false;
  static Future<void> _nothing() async {}
  Future<void> release() {
    if (_released) return Future.value();
    return _pending ??=
        () async {
          await _release();
          _released = true;
        }().whenComplete(() {
          _pending = null;
        });
  }
}

/// Owns the selected destination and outstanding directory leases. Changing the
/// setting affects new files only; native capabilities are never stored as paths
/// or silently replaced with a fallback when access fails.
final class ReceiveDirectories extends ChangeNotifier {
  ReceiveDirectories(this.access);
  final ReceiveAccess access;
  static const maxDirectories = 64;
  final _owners = <_DirectoryOwner>{};
  _DirectoryOwner? _current;
  ReceiveDirectory? get current => _current?.directory;
  Future<void>? _opening, _picking, _closing;
  bool get picking => _picking != null;
  bool _closed = false, _disposed = false;
  String? error;

  Future<ReceiveDirectoryLease> acquire() async {
    await load();
    _checkOpen();
    final owner = _current!;
    owner.uses++;
    var dropped = false;
    return ReceiveDirectoryLease(owner.directory, () async {
      if (!dropped) {
        owner.uses--;
        dropped = true;
      }
      if (!identical(owner, _current) && owner.uses == 0) {
        await _release(owner);
      }
    });
  }

  /// Loads the saved native destination (or default on first use), without
  /// starting a receive or retaining a file lease. Errors never select a fallback.
  Future<void> load() async {
    _checkOpen();
    final picking = _picking;
    if (picking != null) await picking;
    _checkOpen();
    if (_current == null) {
      await (_opening ??= _openConfigured().whenComplete(() {
        _opening = null;
      }));
    }
    _checkOpen();
  }

  Future<void> _openConfigured() async {
    try {
      await _adopt(await access.configuredDirectory());
    } catch (_) {
      error = '无法使用接收目录，请选择可写的保存位置。';
      _notify();
      rethrow;
    }
  }

  Future<void> pick() {
    if (_closed) return Future.error(StateError('Directory owner closed.'));
    return _picking ??= _pick().whenComplete(() {
      _picking = null;
      _notify();
    });
  }

  Future<void> _pick() async {
    try {
      final opening = _opening;
      if (opening != null) {
        await opening.then<void>((_) {}, onError: (Object e, StackTrace s) {});
      }
      _checkOpen();
      if (_owners.length >= maxDirectories) {
        throw const ReceiveAccessFailure('resource_limit');
      }
      final chosen = await access.pickDirectory();
      if (chosen != null) await _adopt(chosen);
      _checkOpen();
    } catch (_) {
      error = '无法更改接收目录，请重试。';
      _notify();
      rethrow;
    }
  }

  Future<void> _adopt(ReceiveDirectory directory) async {
    final owner = _DirectoryOwner(directory);
    _owners.add(owner); // Own late results before checking close intent.
    if (_closed) {
      await _release(owner);
      throw StateError('Directory owner closed.');
    }
    _current = owner;
    error = null;
    try {
      await _collect();
    } catch (_) {
      error = '旧接收目录释放失败，退出时将重试。';
    }
    _notify();
  }

  Future<void> _release(_DirectoryOwner owner) {
    if (!_owners.contains(owner)) return Future.value();
    return owner.releasing ??=
        () async {
          await access.releaseDirectory(owner.directory);
          _owners.remove(owner);
        }().whenComplete(() {
          owner.releasing = null;
        });
  }

  Future<void> _collect() => Future.wait([
    for (final owner in _owners.toList())
      if (!identical(owner, _current) && owner.uses == 0) _release(owner),
  ]).then((_) {});

  void _checkOpen() {
    if (_closed) throw StateError('Directory owner closed.');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> close() {
    _closed = true;
    _current = null;
    return _closing ??= _close().whenComplete(() {
      _closing = null;
    });
  }

  Future<void> _close() async {
    await Future.wait([
      for (final pending in [?_opening, ?_picking])
        pending.then<void>((_) {}, onError: (Object e, StackTrace s) {}),
    ]);
    await _collect();
    if (_owners.isNotEmpty) {
      throw StateError('Directory leases are still active.');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close().then<void>((_) {}, onError: (Object e, StackTrace s) {}));
    super.dispose();
  }
}

final class _DirectoryOwner {
  _DirectoryOwner(this.directory);
  final ReceiveDirectory directory;
  int uses = 0;
  Future<void>? releasing;
}
