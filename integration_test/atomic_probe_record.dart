import 'dart:convert';
import 'dart:io';

Future<void> writeAtomicProbeRecord(
  File target,
  Map<String, Object?> value,
) async {
  final temporary = File('${target.path}.next');
  await temporary.writeAsString(jsonEncode(value), flush: true);
  for (var attempt = 0; ; attempt++) {
    try {
      await temporary.rename(target.path);
      return;
    } on FileSystemException catch (error) {
      // Short-lived Windows readers can deny replace/delete sharing. Preserve
      // atomic visibility; permanent access failures still surface within 1s.
      if (!Platform.isWindows ||
          attempt >= 50 ||
          ![5, 32, 33].contains(error.osError?.errorCode)) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}
