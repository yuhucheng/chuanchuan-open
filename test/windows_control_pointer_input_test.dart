import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/remote/windows_control_pointer_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sharehub.client/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const source = CaptureSource('0', 'screen', type: CaptureSourceType.screen);
  final geometry = ControlGeometry(
    sourceToken: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    revision: 1,
    mediaRevision: 2,
    width: 1920,
    height: 1080,
    originX: -1920,
    originY: 0,
    scaleX: 1,
    scaleY: 1,
    rotation: 90,
  );
  final native = {
    'lease': 7,
    'sourceId': '0',
    'left': -1920,
    'top': 0,
    'width': 1920,
    'height': 1080,
    'rotation': 90,
  };

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'binds matching local source and forwards pointer, wheel and release',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'control.pointer.open') return native;
        if (call.method == 'control.pointer.current') return true;
        if (call.method == 'control.pointer.execute' ||
            call.method == 'control.pointer.releaseButton' ||
            call.method == 'control.input.releaseText') {
          return true;
        }
        return null;
      });
      final input = await WindowsControlPointerInput.open(
        source: source,
        geometry: geometry,
      );
      expect(calls.first.method, 'control.pointer.open');
      expect(calls.first.arguments, {'sourceId': '0'});
      await input.verifyCurrentGeometry(geometry);
      expect(calls.last.method, 'control.pointer.current');
      expect(calls.last.arguments, {'lease': 7});
      expect(
        await input.execute(
          ControlPointerMove(
            sequence: 1,
            inputEpoch: 1,
            geometryRevision: 1,
            x: 1,
            y: 0,
          ),
          geometry,
        ),
        isTrue,
      );
      expect(calls.last.arguments, {
        'lease': 7,
        'kind': 'move',
        'x': 1.0,
        'y': 0.0,
      });
      expect(
        await input.execute(
          ControlPointerButton(
            sequence: 2,
            inputEpoch: 1,
            geometryRevision: 1,
            x: 0.5,
            y: 0.5,
            button: ControlButton.forward,
            down: true,
          ),
          geometry,
        ),
        isTrue,
      );
      expect(calls.last.arguments, {
        'lease': 7,
        'kind': 'button',
        'x': 0.5,
        'y': 0.5,
        'button': 'forward',
        'down': true,
      });
      expect(
        await input.execute(
          ControlWheel(
            sequence: 3,
            inputEpoch: 1,
            geometryRevision: 1,
            x: 0.5,
            y: 0.5,
            deltaX: 120,
            deltaY: -120,
          ),
          geometry,
        ),
        isTrue,
      );
      expect(calls.last.arguments, {
        'lease': 7,
        'kind': 'wheel',
        'x': 0.5,
        'y': 0.5,
        'deltaX': 120.0,
        'deltaY': -120.0,
      });
      expect(await input.releaseButton(ControlButton.forward), isTrue);
      expect(calls.last.arguments, {'lease': 7, 'button': 'forward'});
      expect(await input.releasePendingText(), isTrue);
      expect(calls.last.method, 'control.input.releaseText');
      expect(calls.last.arguments, {'lease': 7});
      await input.close();
      expect(calls.last.method, 'control.pointer.close');
      expect(calls.last.arguments, {'lease': 7});
    },
  );

  test(
    'mismatched native geometry retires binding without executing',
    () async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'control.pointer.open') {
          return {...native, 'left': -1919};
        }
        return null;
      });
      await expectLater(
        WindowsControlPointerInput.open(source: source, geometry: geometry),
        throwsA(
          isA<SessionFailure>().having(
            (e) => e.code,
            'code',
            'invalid_native_geometry',
          ),
        ),
      );
      expect(methods, ['control.pointer.open', 'control.pointer.close']);
    },
  );

  test('malformed native reply with a lease is retired', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'control.pointer.open') {
        return {...native, 'unexpected': true};
      }
      return null;
    });
    await expectLater(
      WindowsControlPointerInput.open(source: source, geometry: geometry),
      throwsA(isA<SessionFailure>()),
    );
    expect(methods, ['control.pointer.open', 'control.pointer.close']);
  });

  test('new source or media revision is rejected before native call', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return call.method == 'control.pointer.open' ? native : true;
    });
    final input = await WindowsControlPointerInput.open(
      source: source,
      geometry: geometry,
    );
    final updated = ControlGeometry(
      sourceToken: geometry.sourceToken,
      revision: geometry.revision,
      mediaRevision: geometry.mediaRevision + 1,
      width: geometry.width,
      height: geometry.height,
      originX: geometry.originX,
      originY: geometry.originY,
      scaleX: geometry.scaleX,
      scaleY: geometry.scaleY,
      rotation: geometry.rotation,
    );
    await expectLater(
      input.execute(
        ControlPointerMove(
          sequence: 1,
          inputEpoch: 1,
          geometryRevision: 1,
          x: 0,
          y: 0,
        ),
        updated,
      ),
      throwsA(isA<SessionFailure>()),
    );
    expect(methods, ['control.pointer.open']);
    await input.close();
  });

  test('native current-source failure blocks geometry readiness', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'control.pointer.open') return native;
      if (call.method == 'control.pointer.current') return false;
      return null;
    });
    final input = await WindowsControlPointerInput.open(
      source: source,
      geometry: geometry,
    );
    await expectLater(
      input.verifyCurrentGeometry(geometry),
      throwsA(
        isA<SessionFailure>().having((e) => e.code, 'code', 'stale_geometry'),
      ),
    );
  });

  test('committed Chinese multiline text uses native text channel', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'control.pointer.open') return native;
      if (call.method == 'control.input.text') return true;
      return null;
    });
    final input = await WindowsControlPointerInput.open(
      source: source,
      geometry: geometry,
      keyboardText: true,
    );
    expect(
      input.supportedInputCapabilities,
      contains(ControlCapability.textInput),
    );
    expect(
      await input.execute(
        ControlTextInput(
          sequence: 1,
          inputEpoch: 1,
          geometryRevision: 1,
          text: '中文\nA😀',
        ),
        geometry,
      ),
      isTrue,
    );
    expect(calls.last.method, 'control.input.text');
    expect(calls.last.arguments, {'lease': 7, 'text': '中文\nA😀'});
  });

  test('physical key and cleanup use the exact native lease', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'control.pointer.open') return native;
      if (call.method == 'control.input.key' ||
          call.method == 'control.input.releaseKey') {
        return true;
      }
      return null;
    });
    final input = await WindowsControlPointerInput.open(
      source: source,
      geometry: geometry,
      keyboardText: true,
    );
    expect(
      input.supportedInputCapabilities,
      contains(ControlCapability.physicalKey),
    );
    expect(
      await input.execute(
        ControlKey(
          sequence: 1,
          inputEpoch: 1,
          geometryRevision: 1,
          usage: 0xe4,
          action: ControlKeyAction.down,
        ),
        geometry,
      ),
      isTrue,
    );
    expect(calls.last.method, 'control.input.key');
    expect(calls.last.arguments, {'lease': 7, 'usage': 0xe4, 'action': 'down'});
    expect(await input.releaseKey(0xe4), isTrue);
    expect(calls.last.method, 'control.input.releaseKey');
    expect(calls.last.arguments, {'lease': 7, 'usage': 0xe4});
  });

  test('unknown native result propagates while undeclared key support stays closed', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'control.pointer.open') return native;
      if (call.method == 'control.pointer.execute') {
        throw PlatformException(code: 'input_result_unknown');
      }
      return null;
    });
    final input = await WindowsControlPointerInput.open(
      source: source,
      geometry: geometry,
    );
    expect(
      await input.execute(
        ControlKey(
          sequence: 1,
          inputEpoch: 1,
          geometryRevision: 1,
          usage: 4,
          action: ControlKeyAction.down,
        ),
        geometry,
      ),
      isFalse,
    );
    expect(methods, ['control.pointer.open']);
    await expectLater(
      input.execute(
        ControlPointerMove(
          sequence: 2,
          inputEpoch: 1,
          geometryRevision: 1,
          x: 0,
          y: 0,
        ),
        geometry,
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(methods.last, 'control.pointer.execute');
  });

  test(
    'invalid local source is rejected before opening a native lease',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return native;
      });
      await expectLater(
        WindowsControlPointerInput.open(
          source: const CaptureSource('00', 'screen'),
          geometry: geometry,
        ),
        throwsA(isA<SessionFailure>()),
      );
      expect(calls, 0);
    },
  );

  test('failed close can retry after held-button cleanup', () async {
    var closes = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'control.pointer.open') return native;
      if (call.method == 'control.pointer.close' && closes++ == 0) {
        throw PlatformException(code: 'input_releasing');
      }
      if (call.method == 'control.pointer.releaseButton') return true;
      return null;
    });
    final input = await WindowsControlPointerInput.open(
      source: source,
      geometry: geometry,
    );
    await expectLater(input.close(), throwsA(isA<PlatformException>()));
    expect(await input.releaseButton(ControlButton.primary), isTrue);
    await input.close();
    expect(closes, 2);
  });
}
