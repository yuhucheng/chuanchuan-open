import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/devices/device_controller.dart';
import 'package:share_hub_open/platform/mac_platform.dart';

import 'fakes.dart';

void main() {
  late FakePlatform platform;
  late DeviceController controller;
  setUp(() {
    platform = FakePlatform();
    controller = DeviceController(platform);
  });
  tearDown(() async {
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    await platform.events.close();
  });

  test(
    'initialization loads local data without discovery or permission prompts',
    () async {
      await controller.initialize();
      expect(controller.device?.name, '书房 Mac');
      expect(platform.starts, 0);
      expect(platform.permissionRequests, 0);
      expect(controller.discovery.enabled, false);
    },
  );

  test('opt in, rename live advertisement, device removal, and stop', () async {
    await controller.initialize();
    await controller.setDiscovery(true);
    await Future<void>.delayed(Duration.zero);
    expect(controller.discovery.enabled, true);
    await controller.rename('客厅 Mac');
    expect(platform.starts, 2);
    expect(controller.device?.name, '客厅 Mac');
    platform.events.add(
      const DiscoverySnapshot(
        state: 'searching',
        devices: [NearbyDevice('remote', '平板', 'android')],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.discovery.devices.single.name, '平板');
    await controller.setDiscovery(false);
    await Future<void>.delayed(Duration.zero);
    expect(controller.discovery.devices, isEmpty);
    expect(controller.discovery.enabled, false);
  });

  test(
    'platform validation error preserves saved name and permits retry',
    () async {
      await controller.initialize();
      platform.renameError = PlatformException(
        code: 'invalid_name',
        message: '名称无效',
      );
      await controller.rename('');
      expect(controller.error, '名称无效');
      expect(controller.device?.name, '书房 Mac');
      expect(controller.busy, false);
      platform.renameError = null;
      await controller.rename('工作室');
      expect(controller.error, isNull);
      expect(controller.device?.name, '工作室');
    },
  );

  test('missing native plugin is shown and can retry initialization', () async {
    platform.loadError = MissingPluginException();
    await controller.initialize();
    expect(controller.device, isNull);
    expect(controller.error, contains('系统组件尚未加载'));
    platform.loadError = null;
    await controller.initialize();
    expect(controller.device, isNotNull);
  });
}
