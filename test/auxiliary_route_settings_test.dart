import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_open/features/connections/auxiliary_route_controller.dart';
import 'package:share_hub_open/ui/field/auxiliary_route_settings.dart';

final class _Store implements AuxiliaryRouteStore {
  AuxiliaryRouteChoice? saved;

  @override
  Future<AuxiliaryRouteChoice?> read() async => saved;

  @override
  Future<void> write(AuxiliaryRouteChoice choice) async => saved = choice;
}

final class _Transport implements AuxiliaryTransport {
  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, String> body,
    AuxiliaryCancellation cancellation,
  ) async => throw const AuxiliaryFailure('unreachable');
}

void main() {
  testWidgets('custom route is saved from settings at 200 percent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 600);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final store = _Store();
    final requested = <Uri>[];
    final routes = AuxiliaryRouteController(
      identity: () => DeviceIdentity.fromSeed(List<int>.filled(32, 1)),
      officialOrigin: 'https://official.example',
      store: store,
      transportFactory: (uri) {
        requested.add(uri);
        return (transport: _Transport(), close: () {});
      },
    );
    addTearDown(routes.stop);
    await routes.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AuxiliaryRouteSettings(routes: routes),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('官方默认'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义内网').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://lan.example:8443');
    await tester.ensureVisible(find.text('保存辅助服务'));
    await tester.tap(find.text('保存辅助服务'));
    await tester.pumpAndSettle();
    expect(store.saved?.mode, AuxiliaryRouteMode.custom);
    expect(requested.map((uri) => uri.host), [
      'official.example',
      'lan.example',
    ]);
    expect(tester.takeException(), isNull);
  });
}
