import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';
import 'package:share_hub_open/platform/client_platform.dart';

/// macOS real-client acceptance: the real host process, real platform
/// channels and the real ScreenCaptureKit adapter. No mock frames and no
/// simulated callbacks; a missing permission or source is a recorded failure.
Future<void> _until(bool Function() done, Duration timeout) async {
  final limit = DateTime.now().add(timeout);
  while (!done() && DateTime.now().isBefore(limit)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS host preserves stable local device identity', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue);
    final platform = MethodChannelClientPlatform();
    final original = await platform.loadDevice();
    expect(original.id, matches(RegExp(r'^[0-9a-fA-F-]{36}$')));
    expect((await platform.loadDevice()).id, original.id);
    await expectLater(platform.setDeviceName('\n'), throwsA(anything));
    expect((await platform.loadDevice()).name, original.name);
  });

  testWidgets('macOS reports live permission state', (tester) async {
    final platform = MethodChannelClientPlatform();
    final permissions = await platform.permissions();
    // Recorded evidence, not an assertion: the host must report the real TCC
    // state without inventing a value.
    stdout.writeln(
      'MACOS_PERMISSIONS screenRecording=${permissions.screenRecording} '
      'accessibility=${permissions.accessibility}',
    );
  });

  testWidgets('macOS real sources expose exactly one primary screen', (
    tester,
  ) async {
    final engine = createPreviewEngine();
    expect(engine.unavailableReason, isNull);
    final sources = await engine.sources();
    final screens = sources
        .where((item) => item.type == CaptureSourceType.screen)
        .toList(growable: false);
    final primary = screens.where((item) => item.isPrimary).toList();
    stdout.writeln('MACOS_SOURCES total=${sources.length} screens=${screens.length}');
    for (final item in sources.take(5)) {
      stdout.writeln(
        'MACOS_SOURCE type=${item.type.name} primary=${item.isPrimary} '
        'name=${item.name}',
      );
    }
    expect(sources, isNotEmpty);
    expect(primary.length, 1);
    await engine.dispose();
  });

  testWidgets('macOS real capture stops and resumes on the same source', (
    tester,
  ) async {
    final engine = createPreviewEngine();
    final sources = await engine.sources();
    final primary = sources.firstWhere((item) => item.isPrimary);

    Future<bool> run() async {
      var firstFrame = false;
      await engine.start(
        primary,
        onEnded: () => stdout.writeln('MACOS_CAPTURE ended'),
        onFirstFrame: () => firstFrame = true,
      );
      await _until(() => firstFrame, const Duration(seconds: 12));
      await engine.stop();
      return firstFrame;
    }

    expect(await run(), isTrue, reason: 'first run must reach a real frame');
    expect(
      await run(),
      isTrue,
      reason: 'resume after stop must reach a real frame again',
    );
    await engine.dispose();
  });
}
