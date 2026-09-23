import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/transfers/native_file_drop.dart';

void main() {
  const channel = MethodChannel('test/drop');
  const codec = StandardMethodCodec();
  Future<Object?> invoke(
    WidgetTester tester,
    String method,
    Object? arguments,
  ) async {
    final result = Completer<Object?>();
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (reply) => result.complete(codec.decodeEnvelope(reply!)),
    );
    return result.future;
  }

  Future<Object?> send(WidgetTester tester, Map<String, Object> args) async {
    final located = await invoke(tester, 'locate', {
      'x': args['x'],
      'y': args['y'],
    });
    if (located != true) return false;
    return invoke(tester, 'drop', args);
  }

  Map<String, Object> offer(Offset point) => {
    'x': point.dx,
    'y': point.dy,
    'files': [
      {'token': 'native-token', 'name': '文件.txt', 'size': 10},
    ],
  };

  testWidgets(
    'slow native preparation retains the located target across rebuilds',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final received = <String>[];
      Widget page(String identity) => NativeFileDropHost(
        channel: channel,
        enabled: true,
        canAccept: () => true,
        onError: (_) {},
        child: MaterialApp(
          home: Scaffold(
            body: NativeFileDropRegion(
              onDrop: (_) {
                received.add(identity);
                return true;
              },
              child: const SizedBox.expand(child: Text('target')),
            ),
          ),
        ),
      );
      await tester.pumpWidget(page('original'));
      await tester.pump();
      expect(await invoke(tester, 'drop', offer(const Offset(20, 20))), false);
      expect(await invoke(tester, 'locate', {'x': 20.0, 'y': 20.0}), true);
      await tester.pumpWidget(page('replacement'));
      expect(await invoke(tester, 'drop', offer(const Offset(20, 20))), true);
      expect(received, ['original']);
      expect(await invoke(tester, 'drop', offer(const Offset(20, 20))), false);
      expect(received, ['original']);
    },
  );

  testWidgets('OS offer reaches only the hit region and returns ownership', (
    tester,
  ) async {
    final methods = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      methods.add(call.method);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    var accepted = 0;
    var enabled = true;
    final failures = <String>[];
    await tester.pumpWidget(
      NativeFileDropHost(
        channel: channel,
        enabled: true,
        canAccept: () => enabled,
        onError: failures.add,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: NativeFileDropRegion(
                onDrop: (files) {
                  accepted++;
                  expect(files.single.token, 'native-token');
                  return true;
                },
                child: const SizedBox(
                  width: 100,
                  height: 100,
                  child: Text('drop here'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(methods, ['listen']);
    expect(
      await send(tester, offer(tester.getCenter(find.text('drop here')))),
      true,
    );
    expect(accepted, 1);
    expect(await send(tester, offer(const Offset(0, 0))), false);
    expect(failures, isNotEmpty);
    enabled = false;
    expect(
      await send(tester, offer(tester.getCenter(find.text('drop here')))),
      false,
    );
    expect(accepted, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(methods, ['listen', 'cancel']);
  });

  testWidgets(
    'modal barrier, bad metadata and full queue reject entire offer',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      var attempts = 0;
      late BuildContext pageContext;
      await tester.pumpWidget(
        NativeFileDropHost(
          channel: channel,
          enabled: true,
          canAccept: () => true,
          onError: (_) {},
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                pageContext = context;
                return Scaffold(
                  body: NativeFileDropRegion(
                    onDrop: (_) {
                      attempts++;
                      return false;
                    },
                    child: const SizedBox.expand(child: Text('queue')),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(await send(tester, offer(const Offset(20, 20))), false);
      expect(attempts, 1);
      final invalid = offer(const Offset(20, 20))
        ..['files'] = [
          {'path': 'C:/arbitrary'},
        ];
      expect(await send(tester, invalid), false);
      expect(await send(tester, offer(const Offset(double.nan, 20))), false);
      expect(attempts, 1);
      unawaited(
        showDialog<void>(
          context: pageContext,
          builder: (_) => const AlertDialog(content: Text('modal')),
        ),
      );
      await tester.pumpAndSettle();
      expect(await send(tester, offer(const Offset(20, 20))), false);
      expect(attempts, 1);
    },
  );
}
