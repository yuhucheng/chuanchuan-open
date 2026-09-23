import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/remote/remote_media.dart';
import 'package:share_hub_open/features/remote/windows_pointer_control_factory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows pointer composition is explicit and capability-limited', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final defaultFactory = RtcRemotePictureFactory();
    expect(defaultFactory.capabilities.operations, {
      SessionOperation.watch,
      SessionOperation.cast,
    });
    final pointer = createWindowsPointerControlFactory();
    expect(pointer.capabilities.operations, {
      SessionOperation.watch,
      SessionOperation.cast,
      SessionOperation.control,
    });
    expect(pointer.controlCapabilities, {
      ControlCapability.pointer,
      ControlCapability.wheel,
    });
    expect(
      pointer.controlCapabilities,
      isNot(contains(ControlCapability.textInput)),
    );
  });

  test('Windows pointer composition is unavailable on macOS', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(createWindowsPointerControlFactory, throwsUnsupportedError);
  });

  test('clipboard is an explicit Windows control test capability', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final factory = createWindowsPointerControlFactory(clipboardText: true);
    expect(factory.controlCapabilities, {
      ControlCapability.pointer,
      ControlCapability.wheel,
      ControlCapability.clipboardText,
    });
    expect(
      factory.controlCapabilities,
      isNot(contains(ControlCapability.textInput)),
    );
  });

  test('keyboard and text are explicit Windows control test capabilities', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final factory = createWindowsPointerControlFactory(keyboardText: true);
    expect(factory.controlCapabilities, {
      ControlCapability.pointer,
      ControlCapability.wheel,
      ControlCapability.physicalKey,
      ControlCapability.textInput,
    });
  });
}
