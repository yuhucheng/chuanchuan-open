import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/ui/client_app.dart';

import 'fakes.dart';
import 'field_test_helpers.dart';

void main() {
  for (final target in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets(
      'exit gates modal pointer and keyboard then restores focus on $target',
      (tester) async {
        tester.view.physicalSize = const Size(860, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final platform = FakePlatform();
        final engine = FakePreviewEngine();
        final gate = Completer<void>();
        var blockCleanup = true;
        await tester.pumpWidget(
          ShareHubApp(
            platform: platform,
            previewEngine: engine,
            targetPlatform: target,
            stopAuxiliary: () =>
                blockCleanup ? gate.future : Future<void>.value(),
          ),
        );
        await tester.pumpAndSettle();
        await openFieldTool(tester, '设置');
        await tester.enterText(
          find.byKey(const ValueKey('device-name')),
          '退出期间不能保存的名字',
        );
        final save = find.widgetWithText(FilledButton, '保存名称');
        await tester.ensureVisible(save);
        final focus = Focus.of(tester.element(find.text('保存名称')));
        focus.requestFocus();
        await tester.pump();
        expect(focus.hasFocus, isTrue);
        final exiting = WidgetsBinding.instance.handleRequestAppExit();
        await tester.pump();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(
          platform.device.name,
          '书房 Mac',
          reason: 'Focused modal action must not run during cleanup',
        );
        await tester.tap(save, warnIfMissed: false);
        await tester.pump();
        expect(
          platform.device.name,
          '书房 Mac',
          reason: 'Modal pointer is outside the field body guard',
        );
        gate.completeError(StateError('controlled auxiliary cleanup failure'));
        AppExitResponse? response;
        exiting.then((value) => response = value);
        for (var frame = 0; frame < 20 && response == null; frame++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(response, AppExitResponse.cancel);
        blockCleanup = false;
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(focus.hasFocus, isTrue);
        expect(find.byKey(const ValueKey('settings-exit-error')), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(platform.device.name, '退出期间不能保存的名字');
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
