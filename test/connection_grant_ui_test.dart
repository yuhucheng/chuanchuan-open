import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/connections/grant_status_text.dart';
import 'package:share_hub_open/features/desktop/desktop_lifecycle.dart';
import 'package:share_hub_open/features/devices/device_controller.dart';
import 'package:share_hub_open/features/preview/preview_controller.dart';
import 'package:share_hub_open/features/remote/remote_media.dart';
import 'package:share_hub_open/features/remote/remote_session_controller.dart';
import 'package:share_hub_open/features/transfers/transfer_queue.dart';
import 'package:share_hub_open/platform/client_platform.dart';
import 'package:share_hub_open/ui/field/appearance.dart';
import 'package:share_hub_open/ui/field/field_shell.dart';

import 'connection_controller_test.dart' show FakeConnectionPlatform;
import 'fakes.dart';
import 'file_fakes.dart';

class _NoMedia implements RemotePictureFactory {
  @override
  MediaCapabilities get capabilities => MediaCapabilities(
    protocolVersion: sessionProtocolVersion,
    operations: const {},
    maxVideoSessions: 1,
  );

  @override
  RemotePictureLink create({
    required SessionTransport transport,
    required MediaSessionBudget budget,
    required Future<CaptureSource> Function() resolveSource,
    required void Function(RemotePicture session) onSession,
    required void Function(String sessionId, String code) onFailure,
  }) => _NoMediaLink();
}

class _NoMediaLink implements RemotePictureLink {
  @override
  Future<void> close() async {}

  @override
  Future<RemotePicture> start(SessionOperation operation, String sessionId) =>
      throw StateError('The authorization readout cannot start media.');
}

void main() {
  late ConnectionController local, peer;

  // Real v2 short-code handshakes establish both independent directions before
  // entering the widget clock. No media or native capture is created.
  setUp(() async {
    final localPlatform = FakeConnectionPlatform();
    final peerPlatform = FakeConnectionPlatform();
    local = ConnectionController(localPlatform);
    peer = ConnectionController(peerPlatform);
    localPlatform.seed.complete(
      await DeviceIdentity.fromSeed(List.filled(32, 91)),
    );
    peerPlatform.seed.complete(
      await DeviceIdentity.fromSeed(List.filled(32, 92)),
    );
    await peer.open();
    await local.connect(
      '127.0.0.1',
      peerPlatform.advertisements.whereType<int>().last,
      peer.code!,
    );
    await local.open();
    await peer.connect(
      '127.0.0.1',
      localPlatform.advertisements.whereType<int>().last,
      local.code!,
    );
    expect(local.sessions, hasLength(2));
  });

  tearDown(() async {
    await local.disconnectAll();
    await peer.disconnectAll();
    local.dispose();
    peer.dispose();
  });

  testWidgets(
    'both dialog contexts show each directional grant at 200 percent',
    (tester) async {
      tester.view.physicalSize = const Size(640, 600);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final platform = FakePlatform()
        ..status = const PermissionStatus(screenRecording: true);
      final devices = DeviceController(platform);
      await devices.initialize();
      final peerKey = local.sessions.first.peerKey;
      devices.discovery = DiscoverySnapshot(
        state: 'running',
        devices: [NearbyDevice('peer', '对端电脑', 'macos', publicKey: peerKey)],
      );
      final engine = FakePreviewEngine();
      final preview = PreviewController(platform, engine);
      final transfers = TransferQueue(TestFileAccess());
      final remote = RemoteSessionController(
        connections: local,
        platform: platform,
        factory: _NoMedia(),
        listSources: engine.sources,
      );
      final desktop = DesktopLifecycle(
        devices: devices,
        connections: local,
        preview: preview,
        stopRemote: remote.shutdown,
        transfers: transfers,
        connectionSupported: true,
      );
      final appearance = Appearance();
      addTearDown(() async {
        desktop.dispose();
        remote.dispose();
        preview.dispose();
        transfers.dispose();
        devices.dispose();
        appearance.dispose();
        await platform.events.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: fieldTheme(Brightness.light, TargetPlatform.macOS),
          home: FieldShell(
            devices: devices,
            connections: local,
            preview: preview,
            remote: remote,
            transfers: transfers,
            desktop: desktop,
            appearance: appearance,
            targetPlatform: TargetPlatform.macOS,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final localNode = find.byKey(const ValueKey('local-device'));
      await tester.ensureVisible(localNode);
      await tester.tap(localNode);
      await tester.pumpAndSettle();

      Future<void> verifyReadouts(String prefix) async {
        expect(find.text('本机发起的连接'), findsOneWidget);
        expect(find.text('对方发起的连接'), findsOneWidget);
        expect(find.text('授权剩余 8 小时'), findsNWidgets(2));
        for (final connection in local.sessions) {
          final status = find.byKey(
            ValueKey('$prefix-grant-${connection.sessionId}'),
          );
          final widget = tester.widget<GrantStatusText>(status);
          expect(widget.grant, same(connection.grant));
          final remaining = find.descendant(
            of: status,
            matching: find.text('授权剩余 8 小时'),
          );
          await tester.ensureVisible(remaining);
          await tester.pump();
          final rect = tester.getRect(remaining);
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(600));
        }
        expect(tester.takeException(), isNull);
      }

      await verifyReadouts('local');
      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pumpAndSettle();
      final device = find.byKey(ValueKey('device-$peerKey'));
      await tester.ensureVisible(device);
      await tester.tap(device);
      await tester.pumpAndSettle();
      await verifyReadouts('device');
      expect(engine.sourceCalls, 0);
      expect(engine.starts, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
