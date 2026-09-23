import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/remote/windows_deferred_control_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sharehub.client/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const source = CaptureSource('0', 'screen', type: CaptureSourceType.screen);
  final geometry = ControlGeometry(
    sourceToken: 'a' * 32,
    revision: 1,
    mediaRevision: 0,
    width: 640,
    height: 360,
    originX: 0,
    originY: 0,
    scaleX: (1920 - 1) / (640 - 1),
    scaleY: (1080 - 1) / (360 - 1),
    rotation: 0,
  );
  final reply = {
    'lease': 7,
    'sourceId': '0',
    'left': 0,
    'top': 0,
    'width': 1920,
    'height': 1080,
    'rotation': 0,
  };
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'keyboard and text require explicit opt-in and use the bound lease',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'control.pointer.open') return reply;
        if (call.method == 'control.pointer.current' ||
            call.method == 'control.input.key' ||
            call.method == 'control.input.text') {
          return true;
        }
        return null;
      });
      final key = ControlKey(
        sequence: 1,
        inputEpoch: 1,
        geometryRevision: 1,
        usage: 0xe4,
        action: ControlKeyAction.down,
      );
      final text = ControlTextInput(
        sequence: 2,
        inputEpoch: 1,
        geometryRevision: 1,
        text: '中文\nA😀',
      );
      final defaultInput = WindowsDeferredControlInput(
        currentSource: () => source,
        channel: channel,
      );
      expect(defaultInput.supportedInputCapabilities, {
        ControlCapability.pointer,
        ControlCapability.wheel,
      });
      defaultInput.requireCurrentGeometry(geometry);
      await defaultInput.verifyCurrentGeometry(geometry);
      expect(await defaultInput.execute(key, geometry), isFalse);
      expect(await defaultInput.execute(text, geometry), isFalse);
      await defaultInput.close();
      expect(
        calls.where((call) => call.method == 'control.input.key'),
        isEmpty,
      );
      expect(
        calls.where((call) => call.method == 'control.input.text'),
        isEmpty,
      );

      final enabled = WindowsDeferredControlInput(
        currentSource: () => source,
        channel: channel,
        keyboardText: true,
      );
      expect(enabled.supportedInputCapabilities, {
        ControlCapability.pointer,
        ControlCapability.wheel,
        ControlCapability.physicalKey,
        ControlCapability.textInput,
      });
      enabled.requireCurrentGeometry(geometry);
      await enabled.verifyCurrentGeometry(geometry);
      expect(await enabled.execute(key, geometry), isTrue);
      expect(await enabled.execute(text, geometry), isTrue);
      expect(
        calls
            .where((call) => call.method == 'control.input.key')
            .single
            .arguments,
        {'lease': 7, 'usage': 0xe4, 'action': 'down'},
      );
      expect(
        calls
            .where((call) => call.method == 'control.input.text')
            .single
            .arguments,
        {'lease': 7, 'text': '中文\nA😀'},
      );
      await enabled.close();
    },
  );

  test('opens only at geometry readiness and reuses one lease', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'control.pointer.open') return reply;
      if (call.method == 'control.pointer.current' ||
          call.method == 'control.pointer.execute' ||
          call.method == 'control.input.releaseText') {
        return true;
      }
      return null;
    });
    final input = WindowsDeferredControlInput(
      currentSource: () => source,
      channel: channel,
    );
    input.requireCurrentGeometry(geometry);
    expect(methods, isEmpty);
    await input.verifyCurrentGeometry(geometry);
    await input.verifyCurrentGeometry(geometry);
    expect(methods.where((m) => m == 'control.pointer.open'), hasLength(1));
    expect(
      await input.execute(
        ControlPointerMove(
          sequence: 1,
          inputEpoch: 1,
          geometryRevision: 1,
          x: .5,
          y: .5,
        ),
        geometry,
      ),
      isTrue,
    );
    await input.close();
    expect(methods.where((m) => m == 'control.pointer.close'), hasLength(1));
  });

  test('new geometry retires old lease before opening replacement', () async {
    final methods = <String>[];
    var opens = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'control.pointer.open') {
        opens++;
        return {...reply, 'lease': opens};
      }
      if (call.method == 'control.pointer.current') return true;
      return null;
    });
    final input = WindowsDeferredControlInput(
      currentSource: () => source,
      channel: channel,
    );
    input.requireCurrentGeometry(geometry);
    await input.verifyCurrentGeometry(geometry);
    final next = ControlGeometry(
      sourceToken: 'b' * 32,
      revision: 2,
      mediaRevision: 0,
      width: 640,
      height: 360,
      originX: 0,
      originY: 0,
      scaleX: (1920 - 1) / (640 - 1),
      scaleY: (1080 - 1) / (360 - 1),
      rotation: 0,
    );
    input.requireCurrentGeometry(next);
    await input.verifyCurrentGeometry(next);
    expect(methods, [
      'control.pointer.open',
      'control.pointer.current',
      'control.pointer.close',
      'control.pointer.open',
      'control.pointer.current',
    ]);
    await input.close();
    expect(methods.last, 'control.pointer.close');
    expect(opens, 2);
  });

  test(
    'failed old-lease close blocks replacement and remains retryable',
    () async {
      var opens = 0;
      var closes = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'control.pointer.open') {
          opens++;
          return {...reply, 'lease': opens};
        }
        if (call.method == 'control.pointer.current') return true;
        if (call.method == 'control.pointer.close' && closes++ == 0) {
          throw PlatformException(code: 'input_releasing');
        }
        return null;
      });
      final input = WindowsDeferredControlInput(
        currentSource: () => source,
        channel: channel,
      );
      input.requireCurrentGeometry(geometry);
      await input.verifyCurrentGeometry(geometry);
      final next = ControlGeometry(
        sourceToken: 'b' * 32,
        revision: 2,
        mediaRevision: 0,
        width: 640,
        height: 360,
        originX: 0,
        originY: 0,
        scaleX: (1920 - 1) / (640 - 1),
        scaleY: (1080 - 1) / (360 - 1),
        rotation: 0,
      );
      input.requireCurrentGeometry(next);
      await expectLater(
        input.verifyCurrentGeometry(next),
        throwsA(isA<PlatformException>()),
      );
      expect(opens, 1);
      await input.close();
      expect(closes, 2);
    },
  );

  test('stop during native open retires the late lease', () async {
    final open = Completer<void>();
    final entered = Completer<void>();
    var closes = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'control.pointer.open') {
        entered.complete();
        await open.future;
        return reply;
      }
      if (call.method == 'control.pointer.close') closes++;
      return null;
    });
    final input = WindowsDeferredControlInput(
      currentSource: () => source,
      channel: channel,
    );
    input.requireCurrentGeometry(geometry);
    final ready = expectLater(
      input.verifyCurrentGeometry(geometry),
      throwsA(isA<SessionFailure>()),
    );
    await entered.future;
    final stopping = input.close();
    open.complete();
    await ready;
    await stopping;
    expect(closes, 1);
    await expectLater(
      input.verifyCurrentGeometry(geometry),
      throwsA(isA<SessionFailure>()),
    );
  });

  test('source replacement during native open retires the old lease', () async {
    final open = Completer<void>();
    final entered = Completer<void>();
    var closes = 0;
    var selected = source;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'control.pointer.open') {
        entered.complete();
        await open.future;
        return reply;
      }
      if (call.method == 'control.pointer.close') closes++;
      return null;
    });
    final input = WindowsDeferredControlInput(
      currentSource: () => selected,
      channel: channel,
    );
    input.requireCurrentGeometry(geometry);
    final ready = expectLater(
      input.verifyCurrentGeometry(geometry),
      throwsA(isA<SessionFailure>()),
    );
    await entered.future;
    selected = const CaptureSource(
      '1',
      'other',
      type: CaptureSourceType.screen,
    );
    open.complete();
    await ready;
    await input.close();
    expect(closes, 1);
  });

  test('missing captured source never opens a lease', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return reply;
    });
    final input = WindowsDeferredControlInput(
      currentSource: () => null,
      channel: channel,
    );
    input.requireCurrentGeometry(geometry);
    await expectLater(
      input.verifyCurrentGeometry(geometry),
      throwsA(isA<SessionFailure>()),
    );
    await input.close();
    expect(calls, 0);
  });

  test('failed close retains the lease for retry', () async {
    var closes = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'control.pointer.open') return reply;
      if (call.method == 'control.pointer.current') return true;
      if (call.method == 'control.pointer.close' && closes++ == 0) {
        throw PlatformException(code: 'input_releasing');
      }
      return null;
    });
    final input = WindowsDeferredControlInput(
      currentSource: () => source,
      channel: channel,
    );
    input.requireCurrentGeometry(geometry);
    await input.verifyCurrentGeometry(geometry);
    await expectLater(input.close(), throwsA(isA<PlatformException>()));
    await input.close();
    expect(closes, 2);
  });

  test(
    'unresolved malformed-open cleanup cannot report a clean stop',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'control.pointer.open') {
          return {...reply, 'sourceId': 'other'};
        }
        if (call.method == 'control.pointer.close') {
          throw PlatformException(code: 'native_cleanup_failed');
        }
        return null;
      });
      final input = WindowsDeferredControlInput(
        currentSource: () => source,
        channel: channel,
      );
      input.requireCurrentGeometry(geometry);
      await expectLater(
        input.verifyCurrentGeometry(geometry),
        throwsA(isA<SessionFailure>()),
      );
      await expectLater(input.close(), throwsA(isA<SessionFailure>()));
    },
  );

  test('malformed-open lease cleanup retries on stop', () async {
    var closes = 0;
    var opens = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'control.pointer.open') {
        opens++;
        return {...reply, 'sourceId': 'other'};
      }
      if (call.method == 'control.pointer.close') {
        expect(call.arguments, {'lease': 7});
        if (closes++ == 0) {
          throw PlatformException(code: 'native_cleanup_failed');
        }
      }
      return null;
    });
    final input = WindowsDeferredControlInput(
      currentSource: () => source,
      channel: channel,
    );
    input.requireCurrentGeometry(geometry);
    await expectLater(
      input.verifyCurrentGeometry(geometry),
      throwsA(isA<SessionFailure>()),
    );
    await expectLater(
      input.verifyCurrentGeometry(geometry),
      throwsA(isA<SessionFailure>()),
    );
    await input.close();
    expect(opens, 1);
    expect(closes, 2);
  });
}
