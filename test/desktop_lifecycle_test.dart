import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/desktop/desktop_lifecycle.dart';
import 'package:share_hub_open/features/devices/device_controller.dart';
import 'package:share_hub_open/features/preview/preview_controller.dart';
import 'package:share_hub_open/features/transfers/transfer_queue.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';

import 'connection_controller_test.dart' show FakeConnectionPlatform;
import 'fakes.dart';
import 'file_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/desktop');
  late FakePlatform platform;
  late DeviceController devices;
  late ConnectionController connections;
  late PreviewController preview;
  late TransferQueue transfers;
  late TestFileAccess files;
  late DesktopLifecycle lifecycle;
  late List<String> calls;
  setUp(() async {
    calls = [];
    platform = FakePlatform();
    devices = DeviceController(platform);
    connections = ConnectionController(FakeConnectionPlatform());
    preview = PreviewController(platform, FakePreviewEngine());
    files = TestFileAccess();
    transfers = TransferQueue(files);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'initialize') return {'allowConnections': false};
          if (call.method == 'prepareExit' &&
              files.picker != null &&
              !files.picker!.isCompleted) {
            files.picker!.complete([
              const SelectedFile(token: 'late', name: 'late.txt', size: 0),
            ]);
          }
          return null;
        });
    lifecycle = DesktopLifecycle(
      devices: devices,
      connections: connections,
      preview: preview,
      transfers: transfers,
      connectionSupported: false,
      channel: channel,
    );
    await lifecycle.initialize();
  });
  tearDown(() async {
    lifecycle.dispose();
    devices.dispose();
    connections.dispose();
    preview.dispose();
    transfers.dispose();
    await Future<void>.delayed(Duration.zero);
    await platform.events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test(
    'discovery is independent from initially closed admission and disconnect',
    () async {
      await devices.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(devices.discovery.enabled, true);
      expect(connections.accepting, false);
      await connections.disconnectAll();
      expect(devices.discovery.enabled, true);
      expect(platform.starts, 1);
      expect(platform.stops, 0);
      expect((preview.engine as FakePreviewEngine).starts, 0);
    },
  );
  test(
    'quit cancels pending native picker before awaiting late token cleanup',
    () async {
      files.picker = Completer<List<SelectedFile>>();
      final pending = transfers.selectFiles();
      final first = lifecycle.requestExit();
      final repeated = lifecycle.requestExit();
      expect(identical(first, repeated), true);
      expect(await first, true);
      await pending;
      expect(calls.where((v) => v == 'prepareExit').length, 1);
      expect(files.releases, ['late']);
      expect(transfers.items, isEmpty);
      expect(lifecycle.exited, true);
    },
  );
  test('file release failure cancels exit and is retryable', () async {
    files.selection = [
      const SelectedFile(token: 'file', name: 'file.txt', size: 0),
    ];
    await transfers.selectFiles();
    await Future<void>.delayed(Duration.zero);
    files.failRelease = true;
    expect(await lifecycle.requestExit(), false);
    expect(lifecycle.exited, false);
    expect(transfers.items, isNotEmpty);
    expect(lifecycle.error, contains('退出清理未完成'));
    files.failRelease = false;
    expect(await lifecycle.requestExit(), true);
    expect(transfers.items, isEmpty);
  });
  test(
    'native final exit is available only after successful cleanup',
    () async {
      (preview.engine as FakePreviewEngine).failStop = true;
      expect(await lifecycle.requestExit(), false);
      await lifecycle.finishExit();
      expect(calls, isNot(contains('exit')));
      (preview.engine as FakePreviewEngine).failStop = false;
      expect(await lifecycle.requestExit(), true);
      await lifecycle.finishExit();
      expect(calls.last, 'exit');
    },
  );
  test(
    'capture release failure prevents native picker teardown until retried',
    () async {
      final engine = preview.engine as FakePreviewEngine;
      engine.failStop = true;
      expect(await lifecycle.requestExit(), false);
      expect(calls, isNot(contains('prepareExit')));
      engine.failStop = false;
      expect(await lifecycle.requestExit(), true);
      expect(calls, contains('prepareExit'));
    },
  );
  test(
    'exit preserves admission preference instead of saving a shutdown false',
    () async {
      final stateWrites = calls.where((v) => v == 'state').length;
      expect(await lifecycle.requestExit(), true);
      expect(calls.where((v) => v == 'state').length, stateWrites);
    },
  );
}
