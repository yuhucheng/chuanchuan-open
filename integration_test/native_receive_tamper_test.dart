import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/transfers/receive_access.dart';

/// Opt-in device test. NATIVE_RECEIVE_DIR locates only the out-of-band tamper
/// target; the native receive capability still comes from configuredDirectory.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('paused native temporary cannot publish changed bytes', (
    tester,
  ) async {
    expect(Platform.isWindows || Platform.isMacOS, isTrue);
    final access = MethodChannelReceiveAccess();
    final directory = await access.configuredDirectory();
    const destinationPath = String.fromEnvironment('NATIVE_RECEIVE_DIR');
    expect(destinationPath, isNotEmpty);
    final destination = Directory(destinationPath);
    expect(destination.existsSync(), isTrue);
    expect(
      destination.uri.pathSegments.where((segment) => segment.isNotEmpty).last,
      directory.label,
    );
    final existing = _temporaryPaths(destination);
    final now = await MethodChannelConnectionPlatform().now();
    final deadline = now + const Duration(minutes: 5).inMicroseconds;
    final key = 'native-temporary-tamper-acceptance';
    final name =
        'chuan-native-tamper-${DateTime.now().microsecondsSinceEpoch}.bin';
    final expected = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    final scope = await access.openScope(key: key, deadlineMicros: deadline);
    ReceiveScope? resumedScope;
    ReceiveFile? file;
    String? temporaryPath;
    String? completedPath;
    try {
      file = await access.begin(
        directory: directory,
        scope: scope,
        metadata: ReceiveMetadata(
          name: name,
          size: expected.length,
          sha256: sha256.convert(expected).toString(),
        ),
      );
      expect(
        await access.append(
          file,
          scope,
          0,
          Uint8List.sublistView(expected, 0, 4),
        ),
        4,
      );
      expect(
        await access.stopScope(scope, ReceiveStopMode.pause),
        ReceiveStopState.paused,
      );
      final checkpoint = await access.checkpoint(file);
      expect(checkpoint.offset, 4);
      final created = _temporaryPaths(destination).difference(existing);
      expect(created, hasLength(1));
      temporaryPath = created.single;
      var changed = false;
      try {
        File(temporaryPath).writeAsBytesSync([9, 8, 7, 6]);
        changed = true;
      } on FileSystemException catch (error) {
        if (!Platform.isWindows || error.osError?.errorCode != 5) rethrow;
      }

      resumedScope = await access.openScope(key: key, deadlineMicros: deadline);
      if (changed) {
        await expectLater(
          access.resume(file, resumedScope, checkpoint),
          throwsA(
            isA<ReceiveAccessFailure>().having(
              (failure) => failure.code,
              'code',
              anyOf('integrity_mismatch', 'source_changed'),
            ),
          ),
        );
        await expectLater(
          access.commit(file, resumedScope),
          throwsA(isA<ReceiveAccessFailure>()),
        );
        expect(
          File('${destination.path}${Platform.pathSeparator}$name')
              .existsSync(),
          isFalse,
        );
      } else {
        await access.resume(file, resumedScope, checkpoint);
        expect(
          await access.append(
            file,
            resumedScope,
            checkpoint.offset,
            Uint8List.sublistView(expected, 4),
          ),
          expected.length,
        );
        final receipt = await access.commit(file, resumedScope);
        expect(receipt.sha256, sha256.convert(expected).toString());
        completedPath =
            '${destination.path}${Platform.pathSeparator}${receipt.name}';
        expect(File(completedPath).readAsBytesSync(), expected);
      }
      stdout.writeln(
        'NATIVE_TEMP_TAMPER_REPORT platform=${Platform.operatingSystem} '
        'name=$name result=${changed ? 'resume_rejected' : 'external_write_denied'}',
      );
    } finally {
      if (file case final received?) {
        await access.abort(received);
        await access.retryCleanup(received);
        await access.release(received);
      }
      await access.closeScope(scope);
      if (resumedScope case final resumed?) {
        await access.closeScope(resumed);
      }
      await access.releaseDirectory(directory);
      if (temporaryPath case final path?) {
        expect(File(path).existsSync(), isFalse);
      }
      if (completedPath case final path?) {
        File(path).deleteSync();
      }
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
