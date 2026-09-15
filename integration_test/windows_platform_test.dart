import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:share_hub_open/platform/client_platform.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows host preserves valid local device identity', (tester) async {
    expect(Platform.isWindows, isTrue);
    final platform = MethodChannelClientPlatform();
    final original = await platform.loadDevice();
    expect((await platform.loadDevice()).id, original.id);
    expect(original.id, matches(RegExp(r'^[0-9a-fA-F-]{36}$')));
    final permissions = await platform.permissions();
    expect(permissions.screenRecording, isTrue);
    expect(permissions.accessibility, isFalse);
    await expectLater(platform.setDeviceName('\n'), throwsA(anything));
    expect((await platform.loadDevice()).name, original.name);
  });
}
