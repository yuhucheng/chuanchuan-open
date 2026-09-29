// Opt-in desktop exit probe. Build only in an isolated checkout, then launch
// the executable directly with NATIVE_RECEIVE_DIR set to the configured native
// receive directory. The normal client never imports this entry point.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/desktop/desktop_lifecycle.dart';
import 'package:share_hub_open/features/devices/device_controller.dart';
import 'package:share_hub_open/features/preview/preview_controller.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';
import 'package:share_hub_open/features/transfers/network_transfers.dart';
import 'package:share_hub_open/features/transfers/receive_access.dart';
import 'package:share_hub_open/features/transfers/source_access.dart';
import 'package:share_hub_open/features/transfers/transfer_queue.dart';

import '../test/connection_controller_test.dart' show FakeConnectionPlatform;
import '../test/connection_relay.dart';
import '../test/fakes.dart';
import '../test/file_fakes.dart';
import '../test/network_file_fakes.dart';
import '../test/transfer_queue_test.dart' show drainQueue;

final class _ClockPlatform extends FakeConnectionPlatform {
  @override
  Future<int> now() => MethodChannelConnectionPlatform().now();
}

final class _GatedSource extends MemorySourceAccess {
  _GatedSource(super.bytes);
  int? gatePass;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Uint8List> readPass(
    SourceReadPass pass,
    int offset,
    int length,
  ) async {
    if (passes == gatePass && offset >= 256 * 1024) {
      gatePass = null;
      entered.complete();
      await release.future;
    }
    return super.readPass(pass, offset, length);
  }
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Set<String> _parts(Directory directory) => {
  for (final entry in directory.listSync(followLinks: false))
    if (entry is File &&
        entry.uri.pathSegments.last.startsWith('.chuanchuan-receive-') &&
        entry.uri.pathSegments.last.endsWith('.part'))
      entry.path,
};

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('退出验收中'))),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
}

Future<void> _run() async {
  final destinationPath = Platform.environment['NATIVE_RECEIVE_DIR'];
  if (destinationPath == null || destinationPath.isEmpty) {
    stderr.writeln('EXIT_PROBE_FAILED missing receive directory');
    exit(2);
  }
  final destination = Directory(destinationPath);
  final previousParts = _parts(destination);
  final senderPlatform = _ClockPlatform();
  final receiverPlatform = _ClockPlatform();
  final receiverIdentity = await DeviceIdentity.fromSeed(
    List<int>.filled(32, 112),
  );
  senderPlatform.seed.complete(
    await DeviceIdentity.fromSeed(List<int>.filled(32, 111)),
  );
  receiverPlatform.seed.complete(receiverIdentity);
  final sender = ConnectionController(senderPlatform);
  final receiver = ConnectionController(receiverPlatform);
  final files = TestFileAccess();
  final senderQueue = TransferQueue(files);
  final receiverQueue = TransferQueue(TestFileAccess());
  final source = _GatedSource(files.data);
  final sent = NetworkTransfers(
    connections: sender,
    queue: senderQueue,
    source: source,
    receive: MemoryReceiveAccess(),
  );
  final received = NetworkTransfers(
    connections: receiver,
    queue: receiverQueue,
    source: MemorySourceAccess({}),
    receive: MethodChannelReceiveAccess(),
  );
  final desktopPlatform = FakePlatform();
  final devices = DeviceController(desktopPlatform);
  final preview = PreviewController(desktopPlatform, FakePreviewEngine());
  final desktop = DesktopLifecycle(
    devices: devices,
    connections: sender,
    preview: preview,
    transfers: senderQueue,
    closeNetworkTransfers: sent.close,
    connectionSupported: false,
    channel: const MethodChannel('dev.sharehub.client/desktop'),
  );
  ConnectionRelay? relay;
  try {
    await desktop.initialize();
    await receiver.open();
    relay = await ConnectionRelay.open(
      receiverPlatform.advertisements.whereType<int>().last,
    );
    final connection = await sender.connect(
      '127.0.0.1',
      relay.port,
      receiver.code!,
      expectedPeerKey: receiverIdentity.encodedKey,
    );
    _require(connection != null, 'pairing failed');
    final bytes = Uint8List.fromList(
      List<int>.generate(3 * 256 * 1024 + 13, (index) => index % 251),
    );
    final name =
        'chuan-network-process-exit-${DateTime.now().microsecondsSinceEpoch}.bin';
    files.selection = [
      SelectedFile(token: 'exit-source', name: name, size: bytes.length),
    ];
    files.data['exit-source'] = bytes;
    await senderQueue.selectFiles();
    await drainQueue(senderQueue);
    source.gatePass = source.passes + 2;
    final job = sent.send(senderQueue.items.single, sender.sessions.single);
    await source.entered.future.timeout(const Duration(seconds: 10));
    _require(job.acknowledgedBytes == 256 * 1024, 'first ACK missing');
    _require(
      _parts(destination).difference(previousParts).length == 1,
      'native partial missing',
    );
    final exiting = desktop.requestExit();
    source.release.complete();
    _require(
      await exiting.timeout(const Duration(seconds: 20)),
      'exit cleanup failed',
    );
    await job.done.timeout(const Duration(seconds: 20));
    _require(job.phase == NetworkSendPhase.cancelled, 'send not cancelled');
    _require(
      !job.canResume && job.receipt == null,
      'send still resumable or delivered',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (_parts(destination).difference(previousParts).isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    _require(
      _parts(destination).difference(previousParts).isEmpty,
      'partial remains',
    );
    _require(
      !File('${destination.path}${Platform.pathSeparator}$name').existsSync(),
      'published unexpectedly',
    );
    _require(
      received.receiveHistory.every(
        (item) => item.file.outcome != FileRetirementOutcome.completed,
      ),
      'unexpected receipt',
    );
    stdout.writeln('EXIT_PROBE_READY pid=$pid name=$name');
    await stdout.flush();
    await desktop.finishExit();
    await Future<void>.delayed(const Duration(seconds: 5));
    throw StateError('native exit did not terminate process');
  } catch (error) {
    stderr.writeln('EXIT_PROBE_FAILED $error');
    if (!source.release.isCompleted) source.release.complete();
    await Future.wait([sent.close(), received.close()]);
    await Future.wait([
      senderQueue.close(),
      receiverQueue.close(),
      sender.disconnectAll(),
      receiver.disconnectAll(),
    ]);
    await relay?.close();
    desktop.dispose();
    devices.dispose();
    preview.dispose();
    sent.dispose();
    received.dispose();
    senderQueue.dispose();
    receiverQueue.dispose();
    sender.dispose();
    receiver.dispose();
    await desktopPlatform.events.close();
    exit(1);
  }
}
