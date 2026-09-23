import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
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
  late List<String> cleanupOrder;
  late Future<void> Function() stopRemote;
  late void Function()? stopAuxiliary;
  late int remoteStops;
  setUp(() async {
    calls = [];
    cleanupOrder = [];
    stopRemote = () async {};
    stopAuxiliary = null;
    remoteStops = 0;
    platform = FakePlatform();
    devices = DeviceController(platform);
    connections = _OrderedConnectionController(cleanupOrder);
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
      stopRemote: () {
        remoteStops++;
        cleanupOrder.add('remote');
        return stopRemote();
      },
      stopAuxiliary: () => stopAuxiliary?.call(),
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
    'synchronous listener reentry joins the original exit transaction',
    () async {
      final remoteReleased = Completer<void>();
      stopRemote = () => remoteReleased.future;
      Future<bool>? reentrant;
      var reentered = false;
      void requestAgain() {
        if (lifecycle.exiting && !reentered) {
          reentered = true;
          reentrant = lifecycle.requestExit();
        }
      }

      lifecycle.addListener(requestAgain);
      addTearDown(() => lifecycle.removeListener(requestAgain));
      final first = lifecycle.requestExit();
      expect(reentered, isTrue);
      expect(reentrant, same(first));
      expect(lifecycle.requestExit(), same(first));
      expect(remoteStops, 1);
      expect(cleanupOrder, ['remote', 'disconnect']);
      remoteReleased.complete();
      expect(await first, isTrue);
      expect(await reentrant, isTrue);
      expect(remoteStops, 1);
      expect(calls.where((call) => call == 'prepareExit'), hasLength(1));
    },
  );
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
  test('exit waits for remote media before native teardown', () async {
    final remoteReleased = Completer<void>();
    stopRemote = () => remoteReleased.future;
    final exiting = lifecycle.requestExit();
    // Both calls must happen before the first asynchronous cleanup result.
    expect(cleanupOrder, ['remote', 'disconnect']);
    expect(remoteStops, 1);
    expect(lifecycle.exiting, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect((preview.engine as FakePreviewEngine).stops, 1);
    expect(lifecycle.exited, isFalse);
    expect(calls, isNot(contains('prepareExit')));
    await lifecycle.finishExit();
    expect(calls, isNot(contains('exit')));

    remoteReleased.complete();
    expect(await exiting, isTrue);
    await lifecycle.finishExit();
    expect(calls.last, 'exit');
  });
  test(
    'remote failure denies exit and retries without logging its data',
    () async {
      final logged = <String>[];
      final previousPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logged.add(message);
      };
      addTearDown(() => debugPrint = previousPrint);
      stopRemote = () => Future<void>.error(StateError('private-session-data'));

      expect(await lifecycle.requestExit(), isFalse);
      expect(lifecycle.exited, isFalse);
      expect(lifecycle.error, contains('退出清理未完成'));
      expect(calls, isNot(contains('prepareExit')));
      await lifecycle.finishExit();
      expect(calls, isNot(contains('exit')));
      expect(logged.join('\n'), contains('stop-media+disconnect (StateError)'));
      expect(logged.join('\n'), isNot(contains('private-session-data')));

      stopRemote = () async {};
      expect(await lifecycle.requestExit(), isTrue);
      expect(remoteStops, 2);
    },
  );
  test('synchronous remote failure still revokes connections', () async {
    stopRemote = () => throw StateError('remote cleanup');
    final exiting = lifecycle.requestExit();
    expect(cleanupOrder, ['remote', 'disconnect']);
    expect(await exiting, isFalse);
    expect(calls, isNot(contains('prepareExit')));
  });
  test(
    'exit cancels auxiliary work alongside media and connection cleanup',
    () async {
      var stops = 0;
      stopAuxiliary = () {
        stops++;
        cleanupOrder.add('auxiliary');
      };
      expect(await lifecycle.requestExit(), isTrue);
      expect(cleanupOrder, ['remote', 'disconnect', 'auxiliary']);
      expect(stops, 1);
    },
  );
  test('auxiliary cleanup error cannot skip connection revocation', () async {
    stopAuxiliary = () => throw StateError('auxiliary cleanup');
    expect(await lifecycle.requestExit(), isFalse);
    expect(cleanupOrder, contains('disconnect'));
    expect(calls, isNot(contains('prepareExit')));
  });
  testWidgets('remote timeout retry awaits the same pending release', (
    tester,
  ) async {
    final remoteReleased = Completer<void>();
    stopRemote = () => remoteReleased.future;
    final first = lifecycle.requestExit();
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(await first, isFalse);
    expect(lifecycle.exiting, isFalse);
    expect(lifecycle.exited, isFalse);
    expect(calls, isNot(contains('prepareExit')));
    await lifecycle.finishExit();
    expect(calls, isNot(contains('exit')));

    // A timed-out exit is still terminal for connection admission, even after
    // disconnectAll has finished while the remote release remains pending.
    await connections.open();
    expect(connections.accepting, isFalse);
    expect(connections.busy, isFalse);

    final retry = lifecycle.requestExit();
    await tester.pump();
    expect(remoteStops, 1);
    expect(cleanupOrder, ['remote', 'disconnect']);
    expect((preview.engine as FakePreviewEngine).stops, 1);
    expect(lifecycle.exiting, isTrue);
    remoteReleased.complete();
    await tester.pump();
    expect(await retry, isTrue);
    expect(remoteStops, 1);
  });
  testWidgets('late remote failure after timeout requires a fresh retry', (
    tester,
  ) async {
    final remoteReleased = Completer<void>();
    stopRemote = () => remoteReleased.future;
    final first = lifecycle.requestExit();
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(await first, isFalse);

    remoteReleased.completeError(StateError('late cleanup failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(lifecycle.exited, isFalse);
    expect(calls, isNot(contains('prepareExit')));

    stopRemote = () async {};
    final retry = lifecycle.requestExit();
    await tester.pump();
    expect(await retry, isTrue);
    expect(remoteStops, 2);
    expect(cleanupOrder, ['remote', 'disconnect', 'remote', 'disconnect']);
  });
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
            if (call.method == 'initialize') return {'allowConnections': true};
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
        stopRemote: () async {},
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
      expect(restored.code, matches(RegExp(r'^\d{6}$')));
      // Only the preference survives a restart: no session, no grant, and the
      // previous run's code cannot be replayed into this process.
      expect(restored.sessions, isEmpty);
      expect(published.last, isTrue);
    },
  );
}

class _OrderedConnectionController extends ConnectionController {
  _OrderedConnectionController(this.cleanupOrder)
    : super(FakeConnectionPlatform());

  final List<String> cleanupOrder;

  @override
  Future<void> disconnectAll() {
    cleanupOrder.add('disconnect');
    return super.disconnectAll();
  }
}
