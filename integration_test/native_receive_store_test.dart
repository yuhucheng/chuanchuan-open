import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/transfers/receive_access.dart';

/// Opt-in device test: writes three files to the configured receive directory.
/// The printed names can be checked on disk and removed after the run.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native receive store publishes complete files and keeps names', (
    tester,
  ) async {
    expect(Platform.isWindows || Platform.isMacOS, isTrue);
    final access = MethodChannelReceiveAccess();
    final clock = MethodChannelConnectionPlatform();
    final now = await clock.now();
    final deadline = now + const Duration(minutes: 5).inMicroseconds;
    final directory = await access.configuredDirectory();
    final key = 'native-receive-acceptance';
    final prefix =
        'chuan-native-receive-${DateTime.now().microsecondsSinceEpoch}';
    final files = <ReceiveFile>[];
    final scopes = <ReceiveScope>[];
    final receipts = <ReceiveReceipt>[];

    Future<ReceiveReceipt> publish(String name, Uint8List data) async {
      final scope = await access.openScope(key: key, deadlineMicros: deadline);
      scopes.add(scope);
      final metadata = ReceiveMetadata(
        name: name,
        size: data.length,
        sha256: sha256.convert(data).toString(),
      );
      final file = await access.begin(
        directory: directory,
        scope: scope,
        metadata: metadata,
      );
      files.add(file);
      var offset = 0;
      while (offset < data.length) {
        final length = data.length - offset < FileLimits.chunkBytes
            ? data.length - offset
            : FileLimits.chunkBytes;
        offset = await access.append(
          file,
          scope,
          offset,
          Uint8List.sublistView(data, offset, offset + length),
        );
      }
      final receipt = await access.commit(file, scope);
      expect(receipt.size, data.length);
      expect(receipt.sha256, metadata.sha256);
      receipts.add(receipt);
      stdout.writeln(
        'NATIVE_RECEIVE_COMMITTED ${receipt.name}:${receipt.size}',
      );
      return receipt;
    }

    try {
      final large = Uint8List.fromList(
        List<int>.generate(2 * 256 * 1024 + 13, (index) => index % 251),
      );
      final original = await publish('$prefix.bin', large);
      final collision = await publish('$prefix.bin', large);
      final empty = await publish('$prefix-empty.bin', Uint8List(0));
      expect(original.name, isNot(collision.name));
      expect(empty.size, 0);
      expect(receipts.map((receipt) => receipt.name).toSet().length, 3);
      stdout.writeln(
        'NATIVE_RECEIVE_REPORT platform=${Platform.operatingSystem} '
        'directory=${directory.label} '
        'files=${receipts.map((r) => '${r.name}:${r.size}:${r.sha256}').join(',')}',
      );

      final cancelScope = await access.openScope(
        key: key,
        deadlineMicros: deadline,
      );
      scopes.add(cancelScope);
      final partial = await access.begin(
        directory: directory,
        scope: cancelScope,
        metadata: ReceiveMetadata(
          name: '$prefix-cancel.bin',
          size: 20,
          sha256: sha256.convert(Uint8List(20)).toString(),
        ),
      );
      files.add(partial);
      expect(await access.append(partial, cancelScope, 0, Uint8List(5)), 5);
      expect(
        await access.stopScope(cancelScope, ReceiveStopMode.cancel),
        ReceiveStopState.cancelled,
      );
      await expectLater(
        access.append(partial, cancelScope, 5, Uint8List(1)),
        throwsA(isA<ReceiveAccessFailure>()),
      );
    } finally {
      for (final file in files) {
        await access.abort(file);
        await access.retryCleanup(file);
        await access.release(file);
      }
      for (final scope in scopes) {
        await access.closeScope(scope);
      }
      await access.releaseDirectory(directory);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
