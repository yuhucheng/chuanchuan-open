import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/remote/windows_control_display_watcher.dart';

void main() {
  const channel = MethodChannel('test/control-display');
  const codec = StandardMethodCodec();

  Future<void> changed(WidgetTester tester) async {
    final reply = Completer<void>();
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(const MethodCall('changed')),
      (bytes) {
        codec.decodeEnvelope(bytes!);
        reply.complete();
      },
    );
    await reply.future;
  }

  testWidgets('display changes serialize and stop after owner closes', (
    tester,
  ) async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var calls = 0;
    final watcher = WindowsControlDisplayWatcher(
      channel: channel,
      onChanged: () async {
        calls++;
        if (calls == 1) {
          entered.complete();
          await release.future;
        }
      },
    );
    final first = changed(tester);
    await entered.future;
    final second = changed(tester);
    expect(calls, 1);
    release.complete();
    await Future.wait([first, second]);
    expect(calls, 2);
    await watcher.close();
    expect(calls, 2);
  });
}
