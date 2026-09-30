import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/connections/connection_panel.dart';

import 'connection_controller_test.dart' show FakeConnectionPlatform;

class _PendingConnections extends ConnectionController {
  _PendingConnections() : super(FakeConnectionPlatform());

  final pending = Completer<TrustedConnection?>();
  final codes = <String>[];
  int cancels = 0;

  @override
  Future<TrustedConnection?> connectByCode(
    String shortCode, {
    String? expectedPeerKey,
  }) async {
    codes.add(shortCode);
    busy = true;
    await pending.future;
    busy = false;
    return null;
  }

  @override
  void cancel() {
    cancels++;
    busy = false;
  }
}

void main() {
  Future<void> open(
    WidgetTester tester,
    _PendingConnections connections, {
    FocusNode? launcherFocus,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              autofocus: true,
              focusNode: launcherFocus,
              onPressed: () => showConnectionDialog(context, connections),
              child: const Text('输入短接码'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
  }

  testWidgets('failed pairing returns focus for keyboard-only retry', (
    tester,
  ) async {
    final connections = _PendingConnections();
    addTearDown(connections.dispose);
    await open(tester, connections);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(connections.codes, ['123456']);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    connections.pending.complete(null);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    await tester.enterText(find.byType(TextField), '654321');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(connections.codes, ['123456', '654321']);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('incomplete code keeps focus and never starts pairing', (
    tester,
  ) async {
    final connections = _PendingConnections();
    addTearDown(connections.dispose);
    await open(tester, connections);
    await tester.enterText(find.byType(TextField), '123');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('请输入完整的 6 位纯数字短接码。'), findsOneWidget);
    expect(connections.codes, isEmpty);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Escape cancels pending pairing immediately and restores the launcher',
    (tester) async {
      tester.view.physicalSize = const Size(640, 550);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final launcherFocus = FocusNode();
      addTearDown(launcherFocus.dispose);
      final connections = _PendingConnections();
      addTearDown(connections.dispose);
      await open(
        tester,
        connections,
        launcherFocus: launcherFocus,
        textScale: 2,
      );
      await tester.enterText(find.byType(TextField), '123456');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(connections.cancels, 1);
      connections.pending.complete(null);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(launcherFocus.hasFocus, isTrue);
      expect(connections.cancels, 1);
      expect(tester.takeException(), isNull);
      // A late failure must not steal focus or interfere with a new dialog.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
