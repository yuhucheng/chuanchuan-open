import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> closeFieldPanel(WidgetTester tester) async {
  if (find.byType(AlertDialog).evaluate().isNotEmpty) {
    await tester.tap(find.widgetWithText(TextButton, '关闭').last);
    await tester.pumpAndSettle();
  }
}

Future<void> openFieldTool(WidgetTester tester, String label) async {
  await closeFieldPanel(tester);
  if (label != '设置') {
    final local = find.byKey(const ValueKey('local-device'));
    await tester.ensureVisible(local);
    await tester.tap(local);
    await tester.pumpAndSettle();
  }
  final button = find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}
