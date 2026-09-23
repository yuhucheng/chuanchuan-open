import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/remote/windows_control_clipboard_watcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sharehub.client/control-clipboard');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('coalesces bursts and stops delivering after close', () async {
    final first = Completer<void>();
    final entered = Completer<void>();
    var observed = 0;
    final watcher = WindowsControlClipboardWatcher(
      onChanged: () async {
        observed++;
        if (observed == 1) {
          entered.complete();
          await first.future;
        }
      },
      onFailure: (_) => fail('unexpected clipboard watcher error'),
    );
    Future<void> notify() => messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('changed')),
      (_) {},
    );
    final a = notify();
    await entered.future;
    final b = notify();
    final c = notify();
    first.complete();
    await Future.wait([a, b, c]);
    expect(observed, 2);
    await watcher.close();
    await notify();
    expect(observed, 2);
  });

  test(
    'read failure retires watcher instead of retrying notifications',
    () async {
      var reads = 0, failures = 0;
      final watcher = WindowsControlClipboardWatcher(
        onChanged: () async {
          reads++;
          throw StateError('clipboard lease lost');
        },
        onFailure: (_) => failures++,
      );
      Future<void> notify() => messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('changed'),
        ),
        (_) {},
      );
      await notify();
      await notify();
      expect(reads, 1);
      expect(failures, 1);
      await watcher.close();
    },
  );
}
