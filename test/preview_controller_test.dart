import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/preview/preview_controller.dart';
import 'package:share_hub_open/platform/mac_platform.dart';

import 'fakes.dart';

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

  test('source refresh requires an explicit choice and never starts a default screen', () async {
    platform.status = const PermissionStatus(screenRecording: true);
    await controller.loadSources();
    expect(controller.selected, isNull);
    await controller.start();
    expect(engine.starts, 0);
    controller.select(controller.sources.first);
    await controller.loadSources();
    expect(controller.selected, isNull);
    expect(engine.starts, 0);
  });

  test('permission denial never enumerates or starts capture', () async {
    await controller.loadSources();
    expect(platform.permissionRequests, 1);
    expect(engine.sourceCalls, 0);
    expect(controller.error, contains('尚未获得'));
    await controller.start();
    expect(engine.starts, 0);
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
