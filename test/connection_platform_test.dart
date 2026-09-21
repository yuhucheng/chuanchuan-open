import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/platform/client_platform.dart';

void main() {
  test('trusted connections ship for the desktop hosts only', () {
    expect(connectionHostSupported(TargetPlatform.macOS), isTrue);
    expect(connectionHostSupported(TargetPlatform.windows), isTrue);
    // Every other host keeps discovery read-only, so the UI never offers a
    // connection the platform cannot finish.
    for (final platform in const [
      TargetPlatform.linux,
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.fuchsia,
    ]) {
      expect(connectionHostSupported(platform), isFalse, reason: '$platform');
    }
  });
}
