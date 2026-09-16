import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';
import 'package:share_hub_open/features/preview/preview_controller.dart';
import 'package:share_hub_open/platform/client_platform.dart';

import 'fakes.dart';

// Exercises the public SDK factory and real Dart adapter with a controlled
// native channel. These tests do not prove ScreenCaptureKit capture/release.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sharehub.client/preview');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late FakePlatform platform;
  late PreviewController controller;
  late Completer<void> startEntered;
  Completer<void>? startReply;
  Completer<void>? stopReply;
  final calls = <MethodCall>[];
  var failStop = false;
  var session = '';

  Future<void> event(String id, String type) async {
    final reply = Completer<void>();
    ServicesBinding.instance.channelBuffers.push(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('event', {'sessionId': id, 'type': type}),
      ),
      (_) => reply.complete(),
    );
    await reply.future;
  }

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    calls.clear();
    startEntered = Completer<void>();
    startReply = stopReply = null;
    failStop = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'sources':
          return [
            {'id': 'fixture-a', 'name': 'Fixture A', 'type': 'window'},
          ];
        case 'start':
          session = call.arguments['sessionId'] as String;
          if (!startEntered.isCompleted) startEntered.complete();
          await startReply?.future;
          return {'textureId': 42, 'width': 640, 'height': 360};
        case 'stop':
          await stopReply?.future;
          if (failStop) throw PlatformException(code: 'cleanup_failed');
          return null;
        default:
          throw StateError('Unexpected method ${call.method}');
      }
    });
    platform = FakePlatform()
      ..status = const PermissionStatus(screenRecording: true);
    controller = PreviewController(platform, createPreviewEngine());
    await controller.loadSources();
    controller.select(controller.sources.single);
  });

  tearDown(() async {
    failStop = false;
    await controller.stop();
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    await platform.events.close();
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('cancel waits for SDK start and coalesces release; late frames stay ignored', () async {
    startReply = Completer<void>();
    final starting = controller.start();
    await startEntered.future;
    final oldSession = session;
    final stopping = controller.stop();
    final stoppingAgain = controller.stop();
    expect(calls.where((call) => call.method == 'stop'), isEmpty);
    await event(oldSession, 'firstFrame');
    expect(controller.firstFrame, false);
    startReply!.complete();
    await Future.wait([starting, stopping, stoppingAgain]);
    expect(calls.where((call) => call.method == 'stop'), hasLength(1));
    expect(controller.active, false);
    expect(controller.cleanupFailed, false);
    await controller.start();
    expect(session, isNot(oldSession));
    await event(oldSession, 'firstFrame');
    await event(oldSession, 'ended');
    expect(controller.active, true);
    expect(controller.firstFrame, false);
    await event(session, 'firstFrame');
    expect(controller.firstFrame, true);
  });

  test('native end before start reply cannot revive capture', () async {
    startReply = Completer<void>();
    final starting = controller.start();
    await startEntered.future;
    await event(session, 'ended');
    expect(controller.stopping, true);
    final stopping = controller.stop();
    startReply!.complete();
    await Future.wait([starting, stopping]);
    expect(controller.active, false);
    expect(controller.firstFrame, false);
    expect(controller.error, contains('系统结束'));
    expect(calls.where((call) => call.method == 'stop'), hasLength(1));
  });

  test(
    'failed SDK cleanup blocks capture until the same session is released',
    () async {
      await controller.start();
      await event(session, 'firstFrame');
      final oldSession = session;
      failStop = true;
      await controller.stop();
      expect(controller.cleanupFailed, true);
      await controller.start();
      expect(calls.where((call) => call.method == 'start'), hasLength(1));
      await event(oldSession, 'ended');
      expect(controller.error, contains('释放失败'));
      failStop = false;
      stopReply = Completer<void>();
      final retry = controller.stop();
      await controller.start();
      expect(calls.where((call) => call.method == 'start'), hasLength(1));
      stopReply!.complete();
      await retry;
      expect(controller.cleanupFailed, false);
      expect(controller.active, false);
      final stops = calls.where((call) => call.method == 'stop');
      expect(stops, hasLength(2));
      expect(
        stops.every((call) => call.arguments['sessionId'] == oldSession),
        true,
      );
      await controller.start();
      expect(session, isNot(oldSession));
    },
  );
}
