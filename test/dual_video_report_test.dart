import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/probe_report.dart';

void main() {
  test(
    'large successive protocol records arrive intact without a logging queue',
    () async {
      final records = <String>[];
      await runZoned(
        () async {
          try {
            final payload = List.filled(14000, 'x').join();
            for (var n = 0; n < 3; n++) {
              writeProbeRecord('DIAG', {'sequence': n, 'payload': payload});
            }
            expect(records.length, 3);
            for (var n = 0; n < 3; n++) {
              final decoded = jsonDecode(records[n].substring('DIAG='.length));
              expect(decoded['sequence'], n);
              expect(decoded['payload'], payload);
            }
          } finally {
            await debugPrintDone;
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) {
            if (line.startsWith('DIAG=')) records.add(line);
          },
        ),
      );
    },
  );
}
