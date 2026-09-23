import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:share_hub_open/features/transfers/receive_access.dart';
import 'package:share_hub_open/features/transfers/source_access.dart';

class MemorySourceAccess implements SourceAccess {
  MemorySourceAccess(this.bytes);
  final Map<String, Uint8List> bytes;
  Completer<void>? readGate;
  final readEntered = Completer<void>();
  final stops = <SourceStopMode>[];
  int reads = 0, passes = 0, opens = 0, activeScopes = 0, maxScopes = 0;
  final closed = <String>{};
  bool failClose = false;
  bool failPause = false;
  @override
  Future<SourceScope> openScope({
    required String fileToken,
    required String key,
    required int deadlineMicros,
  }) async {
    activeScopes++;
    if (activeScopes > maxScopes) maxScopes = activeScopes;
    return SourceScope(
      token: '${++opens}',
      fileToken: fileToken,
      key: key,
      deadlineMicros: deadlineMicros,
    );
  }

  @override
  Future<SourceStopState> stopScope(
    SourceScope scope,
    SourceStopMode mode,
  ) async {
    stops.add(mode);
    if (mode == SourceStopMode.pause && failPause) {
      throw const SourceAccessFailure('io_failure');
    }
    return mode == SourceStopMode.cancel
        ? SourceStopState.cancelled
        : SourceStopState.paused;
  }

  @override
  Future<void> closeScope(SourceScope scope) async {
    if (readGate != null) await readGate!.future;
    if (failClose) throw const SourceAccessFailure('cleanup_failed');
    if (closed.add(scope.token)) activeScopes--;
  }

  @override
  Future<SourceReadPass> beginPass(SourceScope scope) async =>
      SourceReadPass(id: '${++passes}', scope: scope);
  @override
  Future<Uint8List> readPass(
    SourceReadPass pass,
    int offset,
    int length,
  ) async {
    reads++;
    if (!readEntered.isCompleted) readEntered.complete();
    if (readGate != null) await readGate!.future;
    return Uint8List.fromList(
      bytes[pass.scope.fileToken]!.sublist(offset, offset + length),
    );
  }

  @override
  Future<void> finishPass(SourceReadPass pass) async {}
}

class MemoryReceiveAccess implements ReceiveAccess {
  bool failCancel = false;
  bool failClose = false;
  Completer<void>? appendGate;
  final appendEntered = Completer<void>();
  Completer<void>? commitGate;
  final commitEntered = Completer<void>();
  Completer<void>? resumeGate;
  final resumeEntered = Completer<void>();
  bool failDirectory = false;
  final files = <String, List<int>>{};
  final destinations = <String>[];
  final directoryReleases = <String>[];
  final receipts = <ReceiveReceipt>[];
  int opens = 0, begins = 0, releasedFiles = 0, directoryPicks = 0;
  @override
  Future<ReceiveDirectory> configuredDirectory() async {
    if (failDirectory) throw const ReceiveAccessFailure('permission_denied');
    return const ReceiveDirectory(token: 'default', label: 'Downloads/串串');
  }

  @override
  Future<ReceiveDirectory?> pickDirectory() async =>
      ReceiveDirectory(token: 'chosen-${++directoryPicks}', label: 'Chosen');
  @override
  Future<void> releaseDirectory(ReceiveDirectory directory) async {
    directoryReleases.add(directory.token);
  }

  @override
  Future<ReceiveScope> openScope({
    required String key,
    required int deadlineMicros,
  }) async => ReceiveScope(
    token: '${++opens}',
    key: key,
    deadlineMicros: deadlineMicros,
  );
  @override
  Future<ReceiveStopState> stopScope(
    ReceiveScope scope,
    ReceiveStopMode mode,
  ) async {
    if (mode == ReceiveStopMode.cancel && failCancel) {
      throw const ReceiveAccessFailure('io_failure');
    }
    return mode == ReceiveStopMode.cancel
        ? ReceiveStopState.cancelled
        : ReceiveStopState.paused;
  }

  @override
  Future<void> closeScope(ReceiveScope scope) async {
    if (failClose) throw const ReceiveAccessFailure('io_failure');
  }
  @override
  Future<ReceiveFile> begin({
    required ReceiveDirectory directory,
    required ReceiveScope scope,
    required ReceiveMetadata metadata,
  }) async {
    destinations.add(directory.token);
    final token = '${++begins}';
    files[token] = [];
    return ReceiveFile(
      token: token,
      metadata: metadata,
      key: scope.key,
      deadlineMicros: scope.deadlineMicros,
    );
  }

  @override
  Future<int> append(
    ReceiveFile file,
    ReceiveScope scope,
    int offset,
    Uint8List bytes,
  ) async {
    if (!appendEntered.isCompleted) appendEntered.complete();
    if (appendGate != null) await appendGate!.future;
    final data = files[file.token]!;
    if (offset != data.length) throw StateError('offset');
    data.addAll(bytes);
    return data.length;
  }

  @override
  Future<ReceiveReceipt> commit(ReceiveFile file, ReceiveScope scope) async {
    if (!commitEntered.isCompleted) commitEntered.complete();
    if (commitGate != null) await commitGate!.future;
    final data = files[file.token]!;
    if (data.length != file.metadata.size ||
        hashes.sha256.convert(data).toString() != file.metadata.sha256) {
      throw const ReceiveAccessFailure('integrity_mismatch');
    }
    final receipt = ReceiveReceipt(
      name: '${file.metadata.name} (${file.token})',
      size: data.length,
      sha256: file.metadata.sha256,
    );
    receipts.add(receipt);
    return receipt;
  }

  @override
  Future<ReceiveCheckpoint> checkpoint(ReceiveFile file) async =>
      ReceiveCheckpoint(
        offset: files[file.token]!.length,
        sha256: hashes.sha256.convert(files[file.token]!).toString(),
        identity: file.token,
      );
  @override
  Future<void> resume(
    ReceiveFile file,
    ReceiveScope scope,
    ReceiveCheckpoint checkpoint,
  ) async {
    if (!resumeEntered.isCompleted) resumeEntered.complete();
    if (resumeGate != null) await resumeGate!.future;
    final data = files[file.token]!;
    if (checkpoint.identity != file.token ||
        checkpoint.offset != data.length ||
        checkpoint.sha256 != hashes.sha256.convert(data).toString()) {
      throw const ReceiveAccessFailure('integrity_mismatch');
    }
  }
  @override
  Future<void> abort(ReceiveFile file) async {}
  @override
  Future<void> retryCleanup(ReceiveFile file) async {}
  @override
  Future<void> release(ReceiveFile file) async {
    releasedFiles++;
  }
}
