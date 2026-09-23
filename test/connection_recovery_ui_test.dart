import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/connections/connection_panel.dart';

import 'connection_recovery_test.dart'
    show RecoveryPlatform, RecoveryProxy, until;

void main() {
  late ConnectionController a, b;
  late RecoveryProxy proxy;
  setUp(() async {
    final pa = RecoveryPlatform(
      await DeviceIdentity.fromSeed(List.filled(32, 111)),
    );
    final pb = RecoveryPlatform(
      await DeviceIdentity.fromSeed(List.filled(32, 112)),
    );
    a = ConnectionController(
      pa,
      recoveryBackoff: const [Duration(seconds: 20)],
    );
    b = ConnectionController(pb);
    await b.open();
    proxy = RecoveryProxy();
    await proxy.start(pb.port!);
    await a.connect('127.0.0.1', proxy.server.port, b.code!);
    proxy.cut();
    await until(() => a.recoveringCount == 1 && b.recoveringCount == 1);
  });
  tearDown(() async {
    await a.shutdown();
    await b.shutdown();
    await proxy.close();
    a.dispose();
    b.dispose();
  });

  for (final receiver in [false, true]) {
    testWidgets(
      '${receiver ? 'receiver' : 'initiator'} recovery remains cancellable at 200 percent',
      (tester) async {
        tester.view.physicalSize = const Size(640, 600);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final controller = receiver ? b : a;
        final pending = controller.recoveringConnections.single;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: AnimatedBuilder(
                  animation: controller,
                  builder: (_, _) => ConnectionPanel(
                    controller: controller,
                    peerName: (_) => '对端电脑',
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text('对端电脑'), findsOneWidget);
        expect(
          find.textContaining(receiver ? '正在等待对方重新认证' : '正在重新认证本机发起'),
          findsOneWidget,
        );
        expect(find.text('断开并撤销'), findsNothing); // No active connection entry.
        final cancel = find.text('取消恢复并断开');
        await tester.ensureVisible(cancel);
        await tester.tap(cancel);
        await tester.pump();
        expect(controller.recoveringCount, 0);
        expect(pending.grant!.phase, GrantPhase.revoked);
        expect(find.text('取消恢复并断开'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
