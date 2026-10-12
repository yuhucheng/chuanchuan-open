import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/ui/client_app.dart';

import 'fakes.dart';

void main() {
  for (final target in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets(
      'local tool transition keeps keyboard focus at 200 percent on $target',
      (tester) async {
        tester.view.physicalSize = const Size(860, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final platform = FakePlatform();
        final engine = FakePreviewEngine();
        await tester.pumpWidget(
          ShareHubApp(
            platform: platform,
            targetPlatform: target,
            previewEngine: engine,
          ),
        );
        await tester.pumpAndSettle();
        final local = find.byKey(const ValueKey('local-device'));
        final localFocus = tester.widget<OutlinedButton>(local).focusNode!;
        await tester.ensureVisible(local);
        localFocus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('屏幕预览'));
        Focus.of(tester.element(find.text('屏幕预览'))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('本机屏幕预览'), findsWidgets);
        final focus = FocusManager.instance.primaryFocus!;
        expect(ModalRoute.of(focus.context!)?.isCurrent, isTrue);
        expect(localFocus.hasFocus, isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(localFocus.hasFocus, isTrue);
        expect(engine.starts, 0);
        expect(engine.sourceCalls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await platform.events.close();
      },
    );
  }
}
