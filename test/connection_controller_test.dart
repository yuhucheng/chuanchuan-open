import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';

class FakeConnectionPlatform implements ConnectionPlatform {
  final seed = Completer<DeviceIdentity>();
  final advertisements = <int?>[];
  @override
  Future<DeviceIdentity> identity() => seed.future;
  @override
  Future<int> now() async => 1000;
  @override
  Future<String?> advertise(int? port, String? key) async {
    advertisements.add(port);
    return 'test.local';
  }
}

void main() {
  test(
    'cancel while loading identity cannot start listener from late result',
    () async {
      final platform = FakeConnectionPlatform();
      final controller = ConnectionController(platform);
      final opening = controller.open();
      controller.cancel();
      platform.seed.complete(await DeviceIdentity.fromSeed(List.filled(32, 4)));
      await opening;
      expect(controller.accepting, isFalse);
      expect(controller.code, isNull);
      expect(platform.advertisements.whereType<int>(), isEmpty);
      controller.dispose();
    },
  );
  test(
    'dispose while loading identity cannot publish or notify late result',
    () async {
      final platform = FakeConnectionPlatform();
      final controller = ConnectionController(platform);
      final opening = controller.open();
      controller.dispose();
      platform.seed.complete(await DeviceIdentity.fromSeed(List.filled(32, 5)));
      await opening;
      expect(platform.advertisements.whereType<int>(), isEmpty);
    },
  );
  test(
    'cancelled outgoing attempt does not revive UI after identity returns',
    () async {
      final platform = FakeConnectionPlatform();
      final controller = ConnectionController(platform);
      final connecting = controller.connect('127.0.0.1', 12345, '123456');
      controller.cancel();
      platform.seed.complete(await DeviceIdentity.fromSeed(List.filled(32, 6)));
      await connecting;
      expect(controller.sessions, isEmpty);
      expect(controller.busy, isFalse);
      expect(controller.message, '已取消连接。');
      controller.dispose();
    },
  );
}
