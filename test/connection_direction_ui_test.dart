import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/connections/connection_panel.dart';
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
import 'field_test_helpers.dart';
import 'file_fakes.dart';

// Authentication is exercised by controller tests. These presentation fixtures
// use real authenticated directional grants, while making the next dialog
// result controllable without socket I/O inside the widget clock.
class _DialogConnections extends ConnectionController {
  _DialogConnections(TrustedConnection incoming)
    : visible = [incoming],
      super(FakeConnectionPlatform());
  final List<TrustedConnection> visible;
  TrustedConnection? nextResult;
  Completer<TrustedConnection?>? pending;
  String? expectedKey;
  int connects = 0, cancels = 0, revision = 0;
  @override
  List<TrustedConnection> get sessions => List.unmodifiable(visible);
  @override
  TrustedConnection? outgoingFor(String peerKey) => visible
      .where(
        (c) =>
            !c.isClosed &&
            c.peerKey == peerKey &&
            c.grant?.role == GrantRole.initiator &&
            c.grant?.phase == GrantPhase.active,
      )
      .firstOrNull;
  @override
  Future<TrustedConnection?> connect(
    String host,
    int port,
    String shortCode, {
    String? expectedPeerKey,
  }) async {
    connects++;
    final current = ++revision;
    expectedKey = expectedPeerKey;
    busy = true;
    final result = await (pending?.future ?? Future.value(nextResult));
    if (current != revision) return null;
    busy = false;
    if (result != null) visible.add(result);
    notifyListeners();
    return result;
  }

  @override
  void cancel() {
    cancels++;
    revision++;
    busy = false;
  }
}

class _NoopLink implements RemotePictureLink {
  @override
  Future<void> close() async {}
  @override
  Future<RemotePicture> start(SessionOperation operation, String sessionId) =>
      throw StateError('UI fixture must not create media');
}

class _NoopMedia implements RemotePictureFactory {
  @override
  MediaCapabilities get capabilities => MediaCapabilities(
    protocolVersion: sessionProtocolVersion,
    operations: {SessionOperation.watch, SessionOperation.cast},
    maxVideoSessions: 1,
  );
  @override
  RemotePictureLink create({
    required SessionTransport transport,
    required MediaSessionBudget budget,
    required Future<CaptureSource> Function() resolveSource,
    required void Function(RemotePicture session) onSession,
    required void Function(String sessionId, String code) onFailure,
  }) => _NoopLink();
}

class _RecordingRemote extends RemoteSessionController {
  _RecordingRemote(ConnectionController connections, FakePlatform platform)
    : super(
        connections: connections,
        platform: platform,
        factory: _NoopMedia(),
        listSources: () async => [],
      );
  final starts = <(SessionOperation, String)>[];
  @override
  Future<void> start(
    SessionOperation operation, {
    required String peerKey,
    String? label,
  }) async {
    starts.add((operation, peerKey));
  }
}

void main() {
  late ConnectionController peerA, peerB;
  late TrustedConnection incoming, outgoing;

  setUp(() async {
    final a = FakeConnectionPlatform();
    final b = FakeConnectionPlatform();
    peerA = ConnectionController(a);
    peerB = ConnectionController(b);
    a.seed.complete(await DeviceIdentity.fromSeed(List.filled(32, 81)));
    b.seed.complete(await DeviceIdentity.fromSeed(List.filled(32, 82)));
    await peerB.open();
    await peerA.connect(
      '127.0.0.1',
      b.advertisements.whereType<int>().last,
      peerB.code!,
    );
    incoming = peerB.sessions.single;
    await peerA.open();
    await peerB.connect(
      '127.0.0.1',
      a.advertisements.whereType<int>().last,
      peerA.code!,
    );
    outgoing = peerB.sessions.last;
    expect(incoming.grant!.role, GrantRole.receiver);
    expect(outgoing.grant!.role, GrantRole.initiator);
  });
  tearDown(() async {
    await peerA.disconnectAll();
    await peerB.disconnectAll();
    peerA.dispose();
    peerB.dispose();
  });

  Future<(_DialogConnections, _RecordingRemote, FakePlatform)> mount(
    WidgetTester tester, {
    bool endpoint = true,
  }) async {
    tester.view.physicalSize = const Size(1100, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final platform = FakePlatform()
      ..status = const PermissionStatus(screenRecording: true);
    final connections = _DialogConnections(incoming);
    final devices = DeviceController(platform);
    await devices.initialize();
    devices.discovery = DiscoverySnapshot(
      state: 'running',
      devices: [
        NearbyDevice(
          'peer',
          '对端电脑',
          'macos',
          host: endpoint ? 'peer.local' : null,
          port: endpoint ? 31000 : null,
          publicKey: incoming.peerKey,
        ),
      ],
    );
    final engine = FakePreviewEngine();
    final preview = PreviewController(platform, engine);
    final transfers = TransferQueue(TestFileAccess());
    final remote = _RecordingRemote(connections, platform);
    final appearance = Appearance();
    final desktop = DesktopLifecycle(
      devices: devices,
      connections: connections,
      preview: preview,
      transfers: transfers,
      connectionSupported: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: FieldShell(
          devices: devices,
          connections: connections,
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
    addTearDown(() async {
      desktop.dispose();
      remote.dispose();
      connections.dispose();
      preview.dispose();
      transfers.dispose();
      devices.dispose();
      appearance.dispose();
      await platform.events.close();
    });
    return (connections, remote, platform);
  }

  Future<void> openDevice(WidgetTester tester) async {
    await tester.ensureVisible(
      find.byKey(ValueKey('device-${incoming.peerKey}')),
    );
    await tester.tap(find.byKey(ValueKey('device-${incoming.peerKey}')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'receiver direction requests a new code and cancel keeps the old connection',
    (tester) async {
      final (connections, remote, _) = await mount(tester);
      await openDevice(tester);
      expect(find.text('观看该设备屏幕'), findsNothing);
      expect(find.textContaining('当前连接由对方发起'), findsOneWidget);
      await tester.tap(find.text('连接并观看'));
      await tester.pumpAndSettle();
      expect(
        find.byType(TextField),
        findsNWidgets(2),
      ); // Root search plus code.
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(connections.sessions, [incoming]);
      expect(incoming.isClosed, isFalse);
      expect(remote.starts, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('failed reverse pairing never reuses the receiver connection', (
    tester,
  ) async {
    final (connections, remote, _) = await mount(tester);
    await openDevice(tester);
    await tester.tap(find.text('连接并观看'));
    await tester.pumpAndSettle();
    expect(find.text('验证后建立 8 小时连接，并继续观看该设备屏幕。'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '123456',
    );
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(connections.expectedKey, incoming.peerKey);
    expect(remote.starts, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(connections.sessions, [incoming]);
    expect(remote.starts, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'successful reverse pairing returns the new connection and starts once',
    (tester) async {
      final (connections, remote, _) = await mount(tester);
      connections.nextResult = outgoing;
      await openDevice(tester);
      await tester.tap(find.text('连接并观看'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '123456',
      );
      await tester.tap(find.text('连接'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(connections.sessions, [incoming, outgoing]);
      expect(remote.starts, [(SessionOperation.watch, incoming.peerKey)]);
      await openDevice(tester);
      expect(find.text('观看该设备屏幕'), findsOneWidget);
      expect(find.text('连接并观看'), findsNothing);
      expect(find.text('断开该设备并撤销全部授权'), findsOneWidget);
      await tester.ensureVisible(find.text('断开该设备并撤销全部授权'));
      await tester.tap(find.text('断开该设备并撤销全部授权'));
      expect(incoming.isClosed, isTrue);
      expect(outgoing.isClosed, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'missing reverse endpoint offers refresh instead of unusable operations',
    (tester) async {
      final (_, remote, platform) = await mount(tester, endpoint: false);
      await openDevice(tester);
      expect(find.text('连接并观看'), findsNothing);
      expect(find.text('观看该设备屏幕'), findsNothing);
      expect(find.text('刷新设备'), findsOneWidget);
      final before = platform.starts;
      await tester.ensureVisible(find.text('刷新设备'));
      await tester.tap(find.text('刷新设备'));
      await tester.pumpAndSettle();
      expect(platform.starts, before + 1);
      expect(remote.starts, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final invalidResult in ['receiver', 'different-peer']) {
    testWidgets(
      'dialog result $invalidResult cannot authorize the requested action',
      (tester) async {
        final (connections, remote, _) = await mount(tester);
        connections.nextResult = invalidResult == 'receiver'
            ? incoming
            : peerA.sessions.first;
        await openDevice(tester);
        await tester.tap(find.text('连接并观看'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          '123456',
        );
        await tester.tap(find.text('连接'));
        await tester.pumpAndSettle();
        expect(remote.starts, isEmpty);
        expect(incoming.isClosed, isFalse);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'dismissal cancels immediately and late completion cannot close another dialog',
    (tester) async {
      final (connections, remote, _) = await mount(tester);
      connections.pending = Completer<TrustedConnection?>();
      await openDevice(tester);
      await tester.tap(find.text('连接并观看'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '123456',
      );
      await tester.tap(find.text('连接'));
      await tester.pump();
      await tester.tap(find.text('取消'));
      expect(connections.cancels, 1);
      connections.pending!.complete(outgoing);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(connections.sessions, [incoming]);
      expect(remote.starts, isEmpty);
      await openFieldTool(tester, '设置');
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'local session rows identify both directions without exposing raw IDs',
    (tester) async {
      final connections = _DialogConnections(incoming)..visible.add(outgoing);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ConnectionPanel(
                controller: connections,
                peerName: (_) => '对端电脑',
              ),
            ),
          ),
        ),
      );
      expect(find.text('本机发起的连接'), findsOneWidget);
      expect(find.text('对方发起的连接'), findsOneWidget);
      expect(find.textContaining(incoming.sessionId), findsNothing);
      expect(find.textContaining(outgoing.sessionId), findsNothing);
      await tester.pumpWidget(const SizedBox());
      connections.dispose();
    },
  );
}
