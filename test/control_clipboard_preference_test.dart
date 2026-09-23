import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/remote/control_clipboard_preference.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sharehub.client/desktop');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'starts sealed, loads the desktop default, then disables immediately',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'controlClipboard.read') return true;
        if (call.method == 'controlClipboard.write') return null;
        throw MissingPluginException(call.method);
      });
      final setting = ControlClipboardPreference(channel: channel);
      expect(setting.value, isFalse);
      await setting.load();
      expect(setting.value, isTrue);
      final saving = setting.setEnabled(false);
      expect(setting.value, isFalse);
      await saving;
      expect(calls.last.method, 'controlClipboard.write');
      expect(calls.last.arguments, false);
      setting.dispose();
    },
  );

  test('a late load cannot reopen a user-disabled setting', () async {
    final reading = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'controlClipboard.read') return reading.future;
      return null;
    });
    final setting = ControlClipboardPreference(channel: channel);
    final load = setting.load();
    await setting.setEnabled(false);
    reading.complete(true);
    await load;
    expect(setting.value, isFalse);
    setting.dispose();
  });

  test('read failure stays sealed and can retry', () async {
    var reads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'controlClipboard.read') {
        if (reads++ == 0) throw PlatformException(code: 'preferences_failed');
        return true;
      }
      return null;
    });
    final setting = ControlClipboardPreference(channel: channel);
    await setting.load();
    expect(setting.value, isFalse);
    expect(setting.error, isNotNull);
    await setting.retry();
    expect(setting.value, isTrue);
    expect(setting.error, isNull);
    setting.dispose();
  });

  test('failed disable stays live and retries persistence', () async {
    var writes = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'controlClipboard.read') return true;
      if (call.method == 'controlClipboard.write') {
        expect(call.arguments, false);
        if (writes++ == 0) {
          throw PlatformException(code: 'preferences_failed');
        }
      }
      return null;
    });
    final setting = ControlClipboardPreference(channel: channel);
    await setting.load();
    await setting.setEnabled(false);
    expect(setting.value, isFalse);
    expect(setting.error, isNotNull);
    await setting.retry();
    expect(setting.value, isFalse);
    expect(setting.error, isNull);
    expect(writes, 2);
    setting.dispose();
  });
}
