import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../platform/client_platform.dart';
import 'preview_engine.dart';

class PreviewController extends ChangeNotifier {
  PreviewController(this.platform, this.engine);
  final ClientPlatform platform;
  final PreviewEngine engine;
  List<CaptureSource> sources = [];
  CaptureSource? selected;
  bool _explicitSource = false;
  bool busy = false;
  bool stopping = false;
  bool active = false;
  bool firstFrame = false;
  bool cleanupFailed = false;
  String? error;
  bool _disposed = false;
  int _generation = 0;
  Future<void>? _pending;
  Future<void>? _stopPending;
  Timer? _permissionTimer;
  Timer? _firstFrameTimer;
  bool _polling = false;

  void select(CaptureSource? source) {
    if (busy || active || stopping || cleanupFailed) return;
    _explicitSource = true;
    selected = source;
    _notify();
  }

  Future<void> loadSources() => _run((token) async {
    if (_unavailable()) return;
    if (!await _hasPermission()) {
      error = '尚未获得屏幕录制权限。请在系统设置中允许 Share Hub，必要时退出并重新打开应用。';
      return;
    }
    if (!_current(token)) return;
    final found = await engine.sources();
    if (!_current(token)) return;
    sources = found;
    if (!_explicitSource) selected = null;
    if (_explicitSource && selected != null) {
      final previous = selected!;
      selected = found
          .where((item) => item.id == previous.id && item.type == previous.type)
          .firstOrNull;
      if (selected == null) error = '所选来源已失效，请重新选择；不会自动切换到整屏。';
    }
    if (found.isEmpty) error = '没有可预览的屏幕或窗口，请检查权限后刷新。';
  });

  Future<void> start() {
    if (_unavailable()) return Future.value();

    return _run((token) async {
      if (!await _hasPermission()) {
        error = '屏幕录制权限不可用，请检查系统设置。';
        return;
      }
      if (!_current(token)) return;
      CaptureSource? source = selected;
      if (!_explicitSource) {
        final found = await engine.sources();
        if (!_current(token)) return;
        sources = found;
        selected = null;
        final primary = found
            .where(
              (item) => item.type == CaptureSourceType.screen && item.isPrimary,
            )
            .toList();
        if (primary.length != 1) {
          error = '当前引擎无法确认主屏幕，请明确选择画面来源。';
          return;
        }
        source = selected = primary.single;
      }
      if (source == null) {
        error = '请重新选择画面来源；不会自动切换到整屏。';
        return;
      }
      await engine.start(
        source,
        onEnded: () {
          if (_current(token)) unawaited(stop(reason: '屏幕预览已被系统结束。'));
        },
        onFirstFrame: () {
          if (!_current(token)) return;
          firstFrame = true;
          _firstFrameTimer?.cancel();
          _notify();
        },
      );
      if (!_current(token)) return;
      active = true;
      if (!firstFrame) {
        _firstFrameTimer = Timer(const Duration(seconds: 12), () {
          if (_current(token)) unawaited(stop(reason: '未收到画面，请检查权限或重新选择窗口。'));
        });
      }
      _permissionTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _checkPermission(token),
      );
    });
  }

  Future<bool> _hasPermission() async =>
      (await platform.permissions()).screenRecording ||
      await platform.requestScreenRecording();

  bool _unavailable() {
    final reason = engine.unavailableReason;
    if (reason == null) return false;
    error = reason;
    _notify();
    return true;
  }

  Future<void> _checkPermission(int token) async {
    if (_polling || !_current(token)) return;
    _polling = true;
    try {
      final allowed = (await platform.permissions()).screenRecording;
      if (_current(token) && !allowed) await stop(reason: '屏幕录制权限已关闭，预览已停止。');
    } catch (_) {
      if (_current(token)) await stop(reason: '无法检查屏幕录制权限，预览已停止。');
    } finally {
      _polling = false;
    }
  }

  Future<void> _run(Future<void> Function(int) action) {
    if (busy || stopping || active || cleanupFailed || _disposed) {
      return Future.value();
    }
    busy = true;
    error = null;
    firstFrame = false;
    final token = ++_generation;
    _notify();
    return _pending = () async {
      try {
        await action(token);
      } catch (failure) {
        if (_current(token)) {
          // A failed start can still have queued callbacks. Invalidate them
          // before awaiting cleanup, including when cleanup itself fails.
          ++_generation;
          firstFrame = false;
          error =
              failure is PlatformException &&
                  failure.code == 'source_unavailable'
              ? '所选窗口或显示器已不可用，请重新读取画面来源。'
              : '预览未能启动，请刷新来源后重新选择画面。';
          try {
            await engine.stop();
          } catch (_) {
            cleanupFailed = true;
            error = '屏幕采集释放失败，请再次停止，或退出 Share Hub。';
          }
        }
      } finally {
        busy = false;
        _notify();
      }
    }();
  }

  Future<void> stop({String? reason}) =>
      _stopPending ??= _stop(reason).whenComplete(() {
        _stopPending = null;
      });

  Future<void> _stop(String? reason) async {
    ++_generation;
    stopping = true;
    _permissionTimer?.cancel();
    _firstFrameTimer?.cancel();
    _notify();
    await _pending;
    try {
      await engine.stop();
      active = false;
      firstFrame = false;
      cleanupFailed = false;
      error = reason;
    } catch (_) {
      cleanupFailed = true;
      error = '屏幕采集释放失败，请再次停止，或退出 Share Hub。';
    } finally {
      stopping = false;
      _notify();
    }
  }

  bool _current(int token) => !_disposed && token == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop().then((_) => engine.dispose()).catchError((Object _) {}));
    super.dispose();
  }
}
