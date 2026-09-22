import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/devices/device_directory.dart';
import 'package:share_hub_open/platform/client_platform.dart';
import 'package:share_hub_open/ui/field/appearance.dart';
import 'package:share_hub_open/ui/field/device_field.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'long duplicate devices keep full distinctions at ${scale * 100} percent',
      (tester) async {
        tester.view.physicalSize = const Size(1180, 900);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final semantics = tester.ensureSemantics();
        try {
          const name = '办公室用于同名布局验收的中文电脑设备';
          var entries = [
            const NearbyDevice('tail-a', name, 'macos', host: '10.2.3.4'),
            const NearbyDevice('tail-b', name, 'macos', host: '192.168.3.4'),
            const NearbyDevice('missing-a', name, 'macos'),
            const NearbyDevice('missing-b', name, 'macos'),
          ].map(DirectoryDevice.fromDiscovered).toList();
          late StateSetter refresh;
          await tester.pumpWidget(
            MaterialApp(
              theme: fieldTheme(Brightness.light, TargetPlatform.macOS),
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    refresh = setState;
                    return SingleChildScrollView(
                      child: DeviceField(
                        entries: entries,
                        localName: '本机',
                        allowConnections: false,
                        onLocal: () {},
                        onDevice: (_) async {},
                      ),
                    );
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final rectangles = <Rect>[];
          for (final entry in entries) {
            final node = find.byKey(ValueKey('device-${entry.identityId}'));
            await tester.ensureVisible(node);
            await tester.pump();
            final details = find.descendant(
              of: node,
              matching: find.byWidgetPredicate(
                (widget) => widget is Text && widget.data != name,
              ),
            );
            final paragraph = tester.renderObject<RenderParagraph>(details);
            expect(
              paragraph.didExceedMaxLines,
              isFalse,
              reason: entry.identityId,
            );
            final nodeBounds = tester.getRect(node);
            final textBounds = tester.getRect(details);
            expect(textBounds.top, greaterThanOrEqualTo(nodeBounds.top));
            expect(textBounds.bottom, lessThanOrEqualTo(nodeBounds.bottom));
            final label = tester.getSemantics(node).label;
            expect(label, contains(name));
            expect(label, contains(deviceIdentitySuffix(entry)));
            expect(label, contains(entry.host == null ? '地址未提供' : '…3.4'));
            // Compare document positions so scrolling between nodes does not
            // obscure whether naturally taller rows overlap.
            final scroll = tester.state<ScrollableState>(
              find.byType(Scrollable),
            );
            rectangles.add(nodeBounds.shift(Offset(0, scroll.position.pixels)));
          }
          for (var i = 0; i < rectangles.length; i++) {
            for (var j = i + 1; j < rectangles.length; j++) {
              expect(rectangles[i].overlaps(rectangles[j]), isFalse);
            }
          }
          final first = find.byKey(const ValueKey('device-tail-a'));
          await tester.ensureVisible(first);
          final button = tester.widget<OutlinedButton>(first);
          button.focusNode!.requestFocus();
          await tester.pump();
          final position = tester.getTopLeft(first);
          refresh(() => entries = entries.reversed.toList());
          await tester.pump();
          expect(tester.getTopLeft(first), position);
          expect(button.focusNode!.hasFocus, isTrue);
          expect(find.byType(ListView), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }
}
