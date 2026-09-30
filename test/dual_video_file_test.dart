import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/atomic_probe_record.dart';

void main() {
  test('atomic report survives a temporary Windows reader denying deletion', () async {
    final directory = await Directory.systemTemp.createTemp('dual-report-');
    final target = File('${directory.path}/report.json');
    final release = File('${directory.path}/release');
    await target.writeAsString('{"old":true}');
    final escaped = target.path.replaceAll("'", "''");
    final unlock = release.path.replaceAll("'", "''");
    final process = await Process.start('powershell.exe', [
      '-NoProfile',
      '-Command',
      "\$handle = [System.IO.File]::Open('$escaped', 'Open', 'Read', 'ReadWrite'); "
          "[Console]::WriteLine('locked'); while (-not (Test-Path -LiteralPath '$unlock')) { Start-Sleep -Milliseconds 10 }; \$handle.Dispose()",
    ]);
    try {
      expect(
        await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 10)),
        'locked',
      );
      final pending = writeAtomicProbeRecord(target, {'sequence': 2});
      // Register the error handler before releasing the external lock.
      final observed = pending.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(jsonDecode(await target.readAsString()), {'old': true});
      await release.writeAsString('release');
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect(await observed, isNull);
      expect(jsonDecode(await target.readAsString()), {'sequence': 2});
    } finally {
      await release.writeAsString('release');
      await process.exitCode.timeout(const Duration(seconds: 10));
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
}
