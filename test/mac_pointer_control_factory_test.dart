import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/remote/mac_pointer_control_factory.dart';
import 'package:share_hub_open/features/remote/remote_media.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('macOS pointer composition is explicit and capability-limited', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(RtcRemotePictureFactory().capabilities.operations, {
      SessionOperation.watch,
      SessionOperation.cast,
    });
    final factory = createMacPointerControlFactory();
    expect(factory.capabilities.operations, {
      SessionOperation.watch,
      SessionOperation.cast,
      SessionOperation.control,
    });
    expect(factory.controlCapabilities, {
      ControlCapability.pointer,
      ControlCapability.wheel,
    });
  });

  test('macOS control composition is unavailable on Windows', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(createMacPointerControlFactory, throwsUnsupportedError);
  });
}
