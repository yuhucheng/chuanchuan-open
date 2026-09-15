import 'dart:async';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'file_access.dart';

enum PreparationState { queued, preparing, ready, cancelled, failed }

class TransferItem {
  TransferItem(this.file);
  final SelectedFile file;
  PreparationState state = PreparationState.queued;
  int checkedBytes = 0;
  String? sha256;
  String? error;
  bool _released = false;
  Future<bool>? _releasePending;
  bool get canCancel =>
      state == PreparationState.queued || state == PreparationState.preparing;
}

/// Prepares a local manifest. Ready means checked locally, never delivered.
class TransferQueue extends ChangeNotifier {
  TransferQueue(this.access);
  static const maxFiles = 64;
  static const chunkSize = 256 * 1024;
  final FileAccess access;
  final List<TransferItem> _items = [];
  List<TransferItem> get items => List.unmodifiable(_items);
  bool selecting = false;
  String? error;
  bool _disposed = false;
  int _selectionGeneration = 0;
  Future<void>? _worker;
  Future<void>? _picker;

  Future<void> selectFiles() {
    if (_disposed || selecting) return Future.value();
    selecting = true;
    error = null;
    final generation = ++_selectionGeneration;
    _notify();
    return _picker = () async {
      try {
        final files = await access.pickFiles();
        if (_disposed ||
            generation != _selectionGeneration ||
            files.length > maxFiles - _items.length) {
          for (final file in files) {
            final item = TransferItem(file)..state = PreparationState.cancelled;
            if (!await _release(item)) _items.add(item);
          }
          if (!_disposed && generation == _selectionGeneration) {
            error = '队列最多容纳 64 个文件，请先移除部分文件。';
          }
          return;
        }
        _items.addAll(files.map(TransferItem.new));
        _ensureWorker();
      } catch (failure) {
        if (!_disposed && generation == _selectionGeneration) {
          error = _message(failure);
        }
      } finally {
        selecting = false;
        _notify();
      }
    }();
  }

  void _ensureWorker() {
    _worker ??= _prepare().whenComplete(() {
      _worker = null;
      if (!_disposed &&
          _items.any((item) => item.state == PreparationState.queued)) {
        _ensureWorker();
      }
    });
  }

  Future<void> _prepare() async {
    while (!_disposed) {
      final queued = _items.where(
        (item) => item.state == PreparationState.queued,
      );
      if (queued.isEmpty) return;
      final item = queued.first;
      item.state = PreparationState.preparing;
      _notify();
      final result = _DigestResult();
      final sink = sha256.startChunkedConversion(result);
      final progressClock = Stopwatch()..start();
      try {
        if (item.file.size < 0) throw StateError('Invalid file size.');
        while (item.checkedBytes < item.file.size && _current(item)) {
          final expected = math.min(
            chunkSize,
            item.file.size - item.checkedBytes,
          );
          final bytes = await access.read(
            item.file.token,
            item.checkedBytes,
            expected,
          );
          if (!_current(item)) break;
          if (bytes.length != expected) {
            throw StateError('Unexpected file length.');
          }
          sink.add(bytes);
          item.checkedBytes += bytes.length;
          if (progressClock.elapsedMilliseconds >= 100) {
            progressClock.reset();
            _notify();
          }
        }
        if (_current(item)) {
          await access.finish(item.file.token);
          if (_current(item)) {
            sink.close();
            item.sha256 = result.value!.toString();
            item.state = PreparationState.ready;
          }
        }
      } catch (failure) {
        if (_current(item)) {
          item.state = PreparationState.failed;
          item.error = _message(failure);
        }
      } finally {
        if (item.state != PreparationState.ready) {
          sink.close();
          await _release(item);
        }
        _notify();
      }
    }
  }

  Future<void> cancel(TransferItem item) async {
    if (!item.canCancel) return;
    item.state = PreparationState.cancelled;
    _notify();
    await _release(item);
  }

  Future<void> remove(TransferItem item) async {
    if (item.canCancel) item.state = PreparationState.cancelled;
    if (await _release(item)) _items.remove(item);
    _notify();
  }

  Future<void> clear() async {
    ++_selectionGeneration;
    final snapshot = List<TransferItem>.of(_items);
    for (final item in snapshot) {
      if (item.canCancel) item.state = PreparationState.cancelled;
    }
    _notify();
    for (final item in snapshot) {
      await remove(item);
    }
  }

  Future<bool> _release(TransferItem item) {
    if (item._released) return Future.value(true);
    return item._releasePending ??=
        () async {
          try {
            await access.release(item.file.token);
            item._released = true;
            return true;
          } catch (_) {
            item.state = PreparationState.failed;
            item.error = '文件访问释放失败，请再次移除该项目，或退出应用。';
            _notify();
            return false;
          }
        }().whenComplete(() {
          item._releasePending = null;
        });
  }

  bool _current(TransferItem item) =>
      !_disposed && item.state == PreparationState.preparing;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String _message(Object failure) => failure is PlatformException
      ? failure.message ?? '文件访问失败，请重新选择。'
      : '文件准备失败，文件可能已变化或不可读取，请重新选择。';

  /// Exposed so tests and a future graceful quit can await all native releases.
  Future<void> close() async {
    _disposed = true;
    await clear();
    await _picker;
    await _worker;
    // Retry any handles from a picker that finished after close began.
    await clear();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

class _DigestResult implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
