import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/transfers/receive_access.dart';

/// Opt-in device test. NATIVE_RECEIVE_DIR is an out-of-band disk assertion,
/// not an input to the native receive capability issuer.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native receive refuses writes after original deadline', (
    tester,
  ) async {
    expect(Platform.isWindows || Platform.isMacOS, isTrue);
    const destinationPath = String.fromEnvironment('NATIVE_RECEIVE_DIR');
    expect(destinationPath, isNotEmpty);
    final destination = Directory(destinationPath);
    expect(destination.existsSync(), isTrue);
    final existingTemporary = _temporaryPaths(destination);
    final access = MethodChannelReceiveAccess();
    final directory = await access.configuredDirectory();
    expect(
      destination.uri.pathSegments.where((segment) => segment.isNotEmpty).last,
      directory.label,
    );
    final clock = MethodChannelConnectionPlatform();
    final deadline =
        await clock.now() + const Duration(seconds: 2).inMicroseconds;
    final scope = await access.openScope(
      key: 'native-expiry-acceptance',
      deadlineMicros: deadline,
    );
    final name =
        'chuan-native-expiry-${DateTime.now().microsecondsSinceEpoch}.bin';
    final data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    ReceiveFile? file;
    try {
      file = await access.begin(
        directory: directory,
        scope: scope,
        metadata: ReceiveMetadata(
          name: name,
          size: data.length,
          sha256: sha256.convert(data).toString(),
        ),
      );
      expect(
        await access.append(file, scope, 0, Uint8List.sublistView(data, 0, 4)),
        4,
      );
      while (await clock.now() < deadline) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await expectLater(
        access.append(file, scope, 4, Uint8List.sublistView(data, 4)),
        throwsA(
          isA<ReceiveAccessFailure>().having(
            (failure) => failure.code,
            'code',
            'expired',
          ),
        ),
      );
      await expectLater(
        access.commit(file, scope),
        throwsA(isA<ReceiveAccessFailure>()),
      );
      expect(
        File('${destination.path}${Platform.pathSeparator}$name').existsSync(),
        isFalse,
      );
      stdout.writeln(
        'NATIVE_RECEIVE_EXPIRY_REPORT platform=${Platform.operatingSystem} name=$name',
      );
    } finally {
      if (file case final received?) {
        await access.abort(received);
        await access.retryCleanup(received);
        await access.release(received);
      }
      await access.closeScope(scope);
      await access.releaseDirectory(directory);
      expect(
        _temporaryPaths(destination).difference(existingTemporary),
        isEmpty,
      );
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Set<String> _temporaryPaths(Directory directory) => {
  for (final entry in directory.listSync(followLinks: false))
    if (entry is File &&
        entry.uri.pathSegments.last.startsWith('.chuanchuan-receive-') &&
        entry.uri.pathSegments.last.endsWith('.part'))
      entry.path,
};
