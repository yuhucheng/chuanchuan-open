import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/ui/field/appearance.dart';
import 'package:share_hub_open/ui/field/tokens.dart';

void main() {
  final data = jsonDecode(
    File('assets/design/design-tokens.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  Color color(String name) => Color(
    0xff000000 |
        int.parse(data['color'][name]['value'].substring(1), radix: 16),
  );
  Color role(String mode, String name) => color(data['theme'][mode][name]);
  double contrast(Color foreground, Color background) {
    final a = foreground.computeLuminance(), b = background.computeLuminance();
    return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    for (final brightness in Brightness.values) {
      final mode = brightness.name;
      test('$platform $mode resolves the supplied semantic palette', () {
        final theme = fieldTheme(brightness, platform);
        final scheme = theme.colorScheme;
        expect(theme.scaffoldBackgroundColor, role(mode, 'background'));
        expect(scheme.surface, role(mode, 'surface'));
        expect(scheme.surfaceContainerHighest, role(mode, 'raised'));
        expect(scheme.onSurface, role(mode, 'text'));
        expect(scheme.onSurfaceVariant, role(mode, 'secondaryText'));
        expect(scheme.primary, role(mode, 'link'));
        expect(scheme.secondary, role(mode, 'self'));
        expect(theme.dividerTheme.color, role(mode, 'decoration'));
        expect(scheme.outlineVariant, role(mode, 'decoration'));
        expect(scheme.outline, isNot(scheme.outlineVariant));
        expect(theme.cardTheme.color, role(mode, 'surface'));
        expect(theme.dialogTheme.backgroundColor, role(mode, 'surface'));
        final weak = data['theme'][mode]['weakText'];
        expect(
          theme.hintColor,
          weak == null ? role(mode, 'secondaryText') : color(weak),
        );

        final input = theme.inputDecorationTheme;
        expect(input.filled, isTrue);
        expect(input.fillColor, role(mode, 'raised'));
        expect(input.hintStyle!.color, role(mode, 'secondaryText'));
        expect(input.focusedBorder!.borderSide.color, role(mode, 'focus'));
        expect(
          input.focusedBorder!.borderSide.width,
          data['component']['focusWidth'],
        );
        expect(
          (input.border! as OutlineInputBorder).borderRadius,
          BorderRadius.circular((data['radius']['node'] as num).toDouble()),
        );
        expect(
          (theme.cardTheme.shape! as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular((data['radius']['card'] as num).toDouble()),
        );
        expect(
          (theme.dialogTheme.shape! as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular((data['radius']['panel'] as num).toDouble()),
        );
        expect(
          (theme.chipTheme.shape! as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular((data['radius']['chip'] as num).toDouble()),
        );

        final styles = {
          'display': theme.textTheme.displayLarge!,
          'h1': theme.textTheme.headlineLarge!,
          'h2': theme.textTheme.headlineMedium!,
          'h3': theme.textTheme.headlineSmall!,
          'bodyLarge': theme.textTheme.bodyLarge!,
          'body': theme.textTheme.bodyMedium!,
          'caption': theme.textTheme.bodySmall!,
        };
        for (final entry in styles.entries) {
          final expected = data['typography'][entry.key];
          expect(entry.value.fontSize, expected['size']);
          expect(entry.value.height, expected['lineHeight'] / expected['size']);
          expect(entry.value.fontWeight!.value, expected['weight']);
          expect(entry.value.fontFamily, data['font']['body']['family']);
          expect(
            entry.value.fontFamilyFallback,
            data['font']['body']['fallback'],
          );
        }
        expect(theme.platform, platform);
        expect(theme.useMaterial3, isTrue);
      });
    }
  }

  test(
    'code typography uses the supplied mono family without changing its size',
    () {
      expect(FieldTokens.codeStyle.fontFamily, data['font']['mono']['family']);
      expect(
        FieldTokens.codeStyle.fontFamilyFallback,
        data['font']['mono']['fallback'],
      );
      expect(
        FieldTokens.codeStyle.fontSize,
        data['typography']['code']['size'],
      );
      expect(FieldTokens.spaceUnit, data['space']['unit']);
      expect(
        FieldTokens.nodePadding,
        data['component']['desktopNode']['padding'],
      );
      expect(FieldTokens.touchTargetMin, data['component']['touchTargetMin']);
    },
  );

  for (final brightness in Brightness.values) {
    test(
      '${brightness.name} informational colors remain legible on their actual fills',
      () {
        final theme = fieldTheme(brightness, TargetPlatform.macOS);
        final scheme = theme.colorScheme;
        for (final background in [
          scheme.surface,
          scheme.surfaceContainerHighest,
          theme.scaffoldBackgroundColor,
        ]) {
          expect(
            contrast(scheme.onSurface, background),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            contrast(scheme.onSurfaceVariant, background),
            greaterThanOrEqualTo(4.5),
          );
          expect(contrast(scheme.error, background), greaterThanOrEqualTo(4.5));
          expect(contrast(scheme.outline, background), greaterThanOrEqualTo(3));
          expect(
            contrast(
              theme.inputDecorationTheme.focusedBorder!.borderSide.color,
              background,
            ),
            greaterThanOrEqualTo(3),
          );
        }
        expect(
          contrast(scheme.onPrimary, scheme.primary),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(scheme.onSecondary, scheme.secondary),
          greaterThanOrEqualTo(4.5),
        );
        if (brightness == Brightness.light) {
          expect(scheme.error, color('dangerText'));
        } else {
          expect(
            scheme.error,
            ColorScheme.fromSeed(
              seedColor: role('dark', 'link'),
              brightness: brightness,
            ).error,
          );
        }
      },
    );
  }

  testWidgets(
    'real input and card consume grouped fills and focus roles in both themes',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: fieldTheme(brightness, TargetPlatform.macOS),
            home: Scaffold(
              body: Column(
                children: [
                  Card(child: const Text('设备资料')),
                  TextField(
                    focusNode: focus,
                    decoration: const InputDecoration(
                      labelText: '设备名称',
                      hintText: '本机',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        focus.requestFocus();
        await tester.pumpAndSettle();
        final input = tester.widget<InputDecorator>(
          find.byType(InputDecorator),
        );
        expect(input.isFocused, isTrue);
        expect(input.decoration.filled, isTrue);
        expect(input.decoration.fillColor, role(brightness.name, 'raised'));
        expect(
          input.decoration.focusedBorder!.borderSide.color,
          role(brightness.name, 'focus'),
        );
        final cardMaterial = tester.widget<Material>(
          find
              .descendant(
                of: find.byType(Card),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(cardMaterial.color, role(brightness.name, 'surface'));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
