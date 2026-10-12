import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/platform/client_platform.dart';
import 'package:share_hub_open/ui/client_app.dart';
import 'package:share_hub_open/ui/field/device_field.dart';

import 'fakes.dart';
import 'field_test_helpers.dart';

void main() {
  for (final reduced in [false, true]) {
    testWidgets(
      'field and short-code dialogs respect reduced motion $reduced',
      (tester) async {
        tester.view.physicalSize = const Size(1180, 900);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(disableAnimations: reduced);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        final platform = FakePlatform();
        final engine = FakePreviewEngine();
        await tester.pumpWidget(
          ShareHubApp(
            platform: platform,
            previewEngine: engine,
            targetPlatform: TargetPlatform.macOS,
          ),
        );
        await tester.pumpAndSettle();

        void checkRoute() {
          final route =
              ModalRoute.of(tester.element(find.byType(AlertDialog).last))!
                  as TransitionRoute<dynamic>;
          expect(
            route.transitionDuration,
            reduced ? Duration.zero : const Duration(milliseconds: 150),
          );
          expect(route.reverseTransitionDuration, route.transitionDuration);
        }

        await tester.tap(find.text('设置'));
        await tester.pumpAndSettle();
        checkRoute();
        await closeFieldPanel(tester);
        await tester.tap(find.byKey(const ValueKey('local-device')));
        await tester.pumpAndSettle();
        checkRoute();
        await tester.tap(find.text('输入短接码连接设备'));
        await tester.pumpAndSettle();
        checkRoute();
        await tester.enterText(find.byType(TextField).last, '123');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('本机与连接'), findsOneWidget);
        await closeFieldPanel(tester);
        platform.events.add(
          const DiscoverySnapshot(
            state: 'running',
            devices: [NearbyDevice('peer', '另一台电脑', 'macos')],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('device-peer')));
        await tester.pumpAndSettle();
        checkRoute();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(engine.sourceCalls, 0);
        expect(engine.starts, 0);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await platform.events.close();
      },
    );
  }

  testWidgets('live motion and system theme changes preserve focus and input', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1180, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final platform = FakePlatform();
    final engine = FakePreviewEngine();
    await tester.pumpWidget(
      ShareHubApp(platform: platform, previewEngine: engine),
    );
    await tester.pumpAndSettle();
    final field = tester.state(find.byType(DeviceField));
    final search = find.byType(TextField).first;
    await tester.enterText(search, '未提交的搜索文本');
    final editing = tester.widget<EditableText>(
      find.byType(EditableText).first,
    );
    final focus = editing.focusNode;
    final text = editing.controller;
    expect(focus.hasFocus, isTrue);

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    await tester.pump();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    expect(
      Theme.of(tester.element(find.byType(DeviceField))).brightness,
      Brightness.dark,
    );
    expect(
      tester.widget<AnimatedTheme>(find.byType(AnimatedTheme).first).duration,
      Duration.zero,
    );
    expect(tester.state(find.byType(DeviceField)), same(field));
    expect(focus.hasFocus, isTrue);
    expect(text.text, '未提交的搜索文本');

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures();
    await tester.pump();
    expect(
      tester.widget<AnimatedTheme>(find.byType(AnimatedTheme).first).duration,
      kThemeAnimationDuration,
    );
    expect(tester.state(find.byType(DeviceField)), same(field));
    expect(focus.hasFocus, isTrue);
    expect(text.text, '未提交的搜索文本');
    expect(engine.sourceCalls, 0);
    expect(engine.starts, 0);
    expect(engine.closed, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await platform.events.close();
  });
}
