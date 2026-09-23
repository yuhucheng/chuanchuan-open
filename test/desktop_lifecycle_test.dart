import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
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
  late List<Map<Object?, Object?>> states;
  late ValueNotifier<bool> controlActive;
  var controlStops = 0;
  Completer<void>? remoteStopGate;
  var remoteStopClean = true;
  Completer<void>? networkCloseGate;
  late Completer<void> networkCloseEntered;
  var failNetworkClose = false;
  setUp(() async {
    calls = [];
    states = [];
    controlActive = ValueNotifier<bool>(false);
    controlStops = 0;
    remoteStopGate = null;
    remoteStopClean = true;
    networkCloseGate = null;
    networkCloseEntered = Completer<void>();
    failNetworkClose = false;
    platform = FakePlatform();
    devices = DeviceController(platform);
    connections = ConnectionController(FakeConnectionPlatform());
    preview = PreviewController(platform, FakePreviewEngine());
    files = TestFileAccess();
    transfers = TransferQueue(files);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'state') {
            states.add(Map<Object?, Object?>.from(call.arguments as Map));
          }
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
      closeNetworkTransfers: () async {
        calls.add('network-close');
        if (!networkCloseEntered.isCompleted) networkCloseEntered.complete();
        if (networkCloseGate != null) await networkCloseGate!.future;
        if (failNetworkClose) throw StateError('network cleanup failed');
      },
      connectionSupported: false,
      channel: channel,
      controlActive: () => controlActive.value,
      controlChanges: controlActive,
      stopControl: () async {
        controlStops++;
        controlActive.value = false;
      },
      stopRemotePicture: () async {
        calls.add('remote-stop');
        await remoteStopGate?.future;
        return remoteStopClean;
      },
    );
    await lifecycle.initialize();
  });
  tearDown(() async {
    if (networkCloseGate case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    if (remoteStopGate case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    lifecycle.dispose();
    controlActive.dispose();
    devices.dispose();
    connections.dispose();
    preview.dispose();
    transfers.dispose();
    await Future<void>.delayed(Duration.zero);
    await platform.events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('tray stop targets only the current control operation', () async {
    const codec = StandardMethodCodec();
    Future<Object?> invokeNative(String method) {
      final reply = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            codec.encodeMethodCall(MethodCall(method)),
            (bytes) => reply.complete(codec.decodeEnvelope(bytes!)),
          );
      return reply.future;
    }

    expect(await invokeNative('stopControl'), isFalse);
    expect(controlStops, 0);
    controlActive.value = true;
    await Future<void>.delayed(Duration.zero);
    expect(states.last['controlActive'], isTrue);
    expect(await invokeNative('stopControl'), isTrue);
    expect(controlStops, 1);
    expect(states.last['controlActive'], isFalse);
    expect(lifecycle.exited, isFalse);
  });
  test(
    'control notice defaults on and may be disabled without hiding stop',
    () async {
      expect(lifecycle.controlNoticeEnabled, isTrue);
      controlActive.value = true;
      await lifecycle.setControlNoticeEnabled(false);
      expect(lifecycle.controlNoticeEnabled, isFalse);
      expect(states.last['controlNoticeEnabled'], isFalse);
      expect(states.last['controlActive'], isTrue);
    },
  );
  test(
    'exit waits for remote input release and retries failed cleanup',
    () async {
      remoteStopGate = Completer<void>();
      remoteStopClean = false;
      final first = lifecycle.requestExit();
      await Future<void>.delayed(Duration.zero);
      expect(lifecycle.exited, isFalse);
      expect(calls, contains('remote-stop'));
      remoteStopGate!.complete();
      expect(await first, isFalse);
      expect(calls, isNot(contains('prepareExit')));
      remoteStopClean = true;
      expect(await lifecycle.requestExit(), isTrue);
      expect(calls.where((call) => call == 'remote-stop'), hasLength(2));
    },
  );
  test(
    'quit waits for network cleanup before releasing selected files',
    () async {
      files.selection = [
        const SelectedFile(token: 'held', name: 'held', size: 0),
      ];
      await transfers.selectFiles();
      await Future<void>.delayed(Duration.zero);
      networkCloseGate = Completer<void>();
      final closing = lifecycle.requestExit();
      await networkCloseEntered.future;
      expect(files.releases, isEmpty);
      expect(
        calls.indexOf('prepareExit'),
        lessThan(calls.indexOf('network-close')),
      );
      networkCloseGate!.complete();
      expect(await closing, isTrue);
      expect(files.releases, ['held']);
    },
  );
  test(
    'failed network cleanup keeps exit retryable and preserves selections',
    () async {
      files.selection = [
        const SelectedFile(token: 'held', name: 'held', size: 0),
      ];
      await transfers.selectFiles();
      await Future<void>.delayed(Duration.zero);
      failNetworkClose = true;
      expect(await lifecycle.requestExit(), isFalse);
      expect(files.releases, isEmpty);
      failNetworkClose = false;
      expect(await lifecycle.requestExit(), isTrue);
      expect(files.releases, ['held']);
    },
  );
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
  test(
    'restart restores the admission preference and no authorization',
    () async {
      const restart = MethodChannel('test/desktop-restart');
      final published = <bool>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(restart, (call) async {
            if (call.method == 'initialize') {
              return {
                'allowConnections': true,
                'controlNoticeEnabled': false,
              };
            }
            if (call.method == 'state') {
              published.add(
                (call.arguments as Map)['allowConnections'] as bool,
              );
            }
            return null;
          });
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(restart, null);
      });
      final connectionPlatform = FakeConnectionPlatform();
      final restored = ConnectionController(connectionPlatform);
      final restarted = DesktopLifecycle(
        devices: devices,
        connections: restored,
        preview: preview,
        transfers: transfers,
        connectionSupported: true,
        channel: restart,
      );
      addTearDown(() async {
        await restored.disconnectAll();
        restarted.dispose();
        restored.dispose();
      });
      connectionPlatform.seed.complete(
        await DeviceIdentity.fromSeed(List.filled(32, 31)),
      );
      await restarted.initialize();
      // The remembered switch reopens admission with a brand new context.
      expect(restored.accepting, isTrue);
      expect(restarted.controlNoticeEnabled, isFalse);
      expect(restored.code, matches(RegExp(r'^\d{6}$')));
      // Only the preference survives a restart: no session, no grant, and the
      // previous run's code cannot be replayed into this process.
      expect(restored.sessions, isEmpty);
      expect(published.last, isTrue);
    },
  );
}
