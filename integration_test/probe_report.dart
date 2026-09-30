import 'dart:convert';

import 'package:flutter/foundation.dart';

void writeProbeRecord(String kind, Map<String, Object?> value) {
  // These desktop runner records are a protocol read by the coordinator.
  // The UI logger's 12 KiB/second queue can silently delay later lifecycle
  // snapshots past their deadline and lose terminal records at process exit.
  debugPrintSynchronously('$kind=${jsonEncode(value)}', wrapWidth: null);
}
