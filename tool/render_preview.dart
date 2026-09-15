// UI rendering only, using controlled local state. This is not a native app
// screenshot or evidence of Bonjour / screen-capture functionality.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/ui/client_app.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';
import 'package:share_hub_open/platform/client_platform.dart';

import '../test/fakes.dart';
import '../test/file_fakes.dart';

void main() {
  testWidgets('render desktop client pages for visual review', (tester) async {
    final windows =
        Platform.environment['SHARE_HUB_PREVIEW_TARGET'] == 'windows';
    final fontPath = Platform.environment['SHARE_HUB_PREVIEW_FONT'];
    if (fontPath == null || !File(fontPath).existsSync()) {
      throw StateError(
        'Set SHARE_HUB_PREVIEW_FONT to an existing local CJK font file.',
      );
    }
    await tester.runAsync(() async {
      final bytes = ByteData.sublistView(await File(fontPath).readAsBytes());
      for (final family in [
        'Roboto',
        '.AppleSystemUIFont',
        'Microsoft YaHei UI',
      ]) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    tester.view.physicalSize = const Size(1180, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    final platform = FakePlatform();
    if (windows) platform.device = const LocalDevice('local', '书房 Windows');
    final files = TestFileAccess()
      ..selection = [
        const SelectedFile(token: 'fixture', name: '项目说明.txt', size: 3),
      ]
      ..data['fixture'] = Uint8List.fromList([97, 98, 99]);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: ShareHubApp(
          targetPlatform: windows
              ? TargetPlatform.windows
              : TargetPlatform.macOS,
          platform: platform,
          previewEngine: FakePreviewEngine(),
          fileAccess: files,
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final page in [
      ('设备', 'devices'),
      ('屏幕预览', 'preview'),
      ('文件传送', 'transfers'),
      ('设置', 'settings'),
    ]) {
      await tester.tap(find.byTooltip(page.$1));
      await tester.pumpAndSettle();
      if (page.$2 == 'transfers' && !windows) {
        await tester.tap(find.text('选择文件'));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File(
          'build/ui-preview/${windows ? 'windows' : 'macos'}-${page.$2}.png',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await platform.events.close();
  });
}
