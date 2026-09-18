import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/preview/preview_controller.dart';
import 'package:share_hub_open/platform/mac_platform.dart';

import 'fakes.dart';

import 'package:share_hub_media_api/share_hub_media_api.dart';

void main() {
  late FakePlatform platform;
  late FakePreviewEngine engine;
  late PreviewController controller;
  setUp(() {
    platform = FakePlatform();
    engine = FakePreviewEngine();
    controller = PreviewController(platform, engine);
  });
  tearDown(() async {
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    await platform.events.close();
  });
  Future<void> prepare() async {
    platform.status = const PermissionStatus(screenRecording: true);
    await controller.loadSources();
    controller.select(controller.sources.first);
  }

  test('start resolves primary only after explicit action and preserves a chosen source', () async {
    platform.status = const PermissionStatus(screenRecording: true);
    await controller.loadSources();
    expect(controller.selected, isNull);
    expect(engine.starts, 0);
    await controller.start();
    expect(engine.startedSource?.id, 'screen:1');
    await controller.stop();
    controller.select(controller.sources.first);
    await controller.loadSources();
    expect(controller.selected?.id, 'screen:1');
  });

  test('lost explicit source never falls back to a primary display', () async {
    await prepare();
    engine.availableSources = [
      const CaptureSource('screen:2', '另一主屏', isPrimary: true),
    ];
    await controller.loadSources();
    expect(controller.selected, isNull);
    await controller.start();
    expect(engine.starts, 0);
    expect(controller.error, contains('不会自动切换'));
  });

  test(
    'primary is resolved anew at start; legacy metadata is not guessed',
    () async {
      platform.status = const PermissionStatus(screenRecording: true);
      await controller.loadSources();
      engine.availableSources = [
        const CaptureSource('screen:2', '新主屏', isPrimary: true),
      ];
      await controller.start();
      expect(engine.startedSource?.id, 'screen:2');
      await controller.stop();
      engine.availableSources = [const CaptureSource('legacy', '旧引擎首项')];
      await controller.start();
      expect(engine.starts, 1);
      expect(controller.error, contains('无法确认主屏幕'));
    },
  );

  test('permission denial never enumerates or starts capture', () async {
    await controller.loadSources();
    expect(platform.permissionRequests, 1);
    expect(engine.sourceCalls, 0);
    expect(controller.error, contains('尚未获得'));
    await controller.start();
    expect(engine.starts, 0);
  });

  // macOS ScreenCaptureKit reports `permission` from the native start even when
  // preflight was satisfied, so the denial must not be described as a source
  // problem or the user is told to retry something that cannot succeed.
  test('native permission failure points at the system setting', () async {
    await prepare();
    engine.startError = PlatformException(code: 'permission');
    await controller.start();
    expect(controller.error, contains('屏幕录制权限不可用'));
    expect(controller.error, isNot(contains('刷新来源')));
    expect(controller.active, false);
    expect(engine.released, true);
  });

  test('unknown native start failures keep the retry guidance', () async {
    await prepare();
    engine.startError = PlatformException(code: 'internal');
    await controller.start();
    expect(controller.error, contains('预览未能启动'));
    expect(controller.active, false);
  });

  test('capture and first frame are separate; stop is repeatable', () async {
    await prepare();
    await controller.start();
    expect(controller.active, true);
    expect(controller.firstFrame, false);
    engine.firstFrame!();
    expect(controller.firstFrame, true);
    await controller.stop();
    await controller.stop();
    expect(controller.active, false);
    expect(engine.released, true);
    expect(controller.firstFrame, false);
  });

  test('stop while permission is pending prevents late capture', () async {
    await prepare();
    platform.status = const PermissionStatus();
    platform.permissionCompleter = Completer<bool>();
    final starting = controller.start();
    await Future<void>.delayed(Duration.zero);
    final stopping = controller.stop();
    platform.permissionCompleter!.complete(true);
    await Future.wait([starting, stopping]);
    expect(engine.starts, 0);
    expect(controller.active, false);
  });

  test(
    'failed start invalidates frame and ended callbacks after cleanup',
    () async {
      await prepare();
      engine.failStart = true;
      await controller.start();
      final failure = controller.error;
      final stops = engine.stops;
      engine.firstFrame!();
      expect(controller.firstFrame, false);
      engine.ended!();
      await Future<void>.delayed(Duration.zero);
      expect(controller.firstFrame, false);
      expect(controller.active, false);
      expect(controller.error, failure);
      expect(engine.stops, stops);
    },
  );

  test(
    'late native capture is released and repeated starts are ignored',
    () async {
      await prepare();
      engine.startCompleter = Completer<void>();
      final starting = controller.start();
      await Future<void>.delayed(Duration.zero);
      await controller.start();
      final stopping = controller.stop();
      engine.startCompleter!.complete();
      await Future.wait([starting, stopping]);
      expect(engine.starts, 1);
      expect(engine.released, true);
      expect(controller.active, false);
      engine.firstFrame!();
      expect(controller.firstFrame, false);
    },
  );

  test(
    'native error cleans resources; cleanup failure requires retry',
    () async {
      await prepare();
      engine.failStart = true;
      engine.failStop = true;
      await controller.start();
      expect(controller.cleanupFailed, true);
      await controller.start();
      expect(engine.starts, 1);
      engine.failStop = false;
      await controller.stop();
      expect(controller.cleanupFailed, false);
      expect(controller.error, isNull);
    },
  );

  test(
    'ended callback stops capture and old callbacks cannot stop a new capture',
    () async {
      await prepare();
      await controller.start();
      final oldEnded = engine.ended!;
      oldEnded();
      await Future<void>.delayed(Duration.zero);
      expect(controller.active, false);
      await controller.start();
      oldEnded();
      await Future<void>.delayed(Duration.zero);
      expect(controller.active, true);
    },
  );

  testWidgets('missing first frame times out and releases capture', (
    tester,
  ) async {
    await prepare();
    await controller.start();
    await tester.pump(const Duration(seconds: 13));
    await tester.pump();
    expect(controller.active, false);
    expect(engine.released, true);
    expect(controller.error, contains('未收到画面'));
  });

  testWidgets('revoked recording permission stops an active preview', (
    tester,
  ) async {
    await prepare();
    await controller.start();
    engine.firstFrame!();
    platform.status = const PermissionStatus();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(controller.active, false);
    expect(controller.error, contains('权限已关闭'));
  });
}
