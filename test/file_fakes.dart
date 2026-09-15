import 'dart:async';

import 'package:flutter/services.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';

class TestFileAccess implements FileAccess {
  List<SelectedFile> selection = [];
  final data = <String, Uint8List>{};
  final releases = <String>[];
  final finished = <String>[];
  final reads = <(String, int, int)>[];
  Completer<List<SelectedFile>>? picker;
  Completer<Uint8List>? pendingRead;
  bool shortRead = false;
  bool failFinish = false;
  bool failRelease = false;
  int activeReads = 0;
  int maximumActiveReads = 0;
  int picks = 0;
  @override
  Future<List<SelectedFile>> pickFiles() async {
    picks++;
    return picker?.future ?? selection;
  }

  @override
  Future<Uint8List> read(String token, int offset, int length) async {
    reads.add((token, offset, length));
    activeReads++;
    if (activeReads > maximumActiveReads) maximumActiveReads = activeReads;
    try {
      if (pendingRead != null) return await pendingRead!.future;
      return Uint8List.sublistView(
        data[token]!,
        offset,
        offset + length - (shortRead ? 1 : 0),
      );
    } finally {
      activeReads--;
    }
  }

  @override
  Future<void> finish(String token) async {
    if (failFinish) throw PlatformException(code: 'changed', message: '文件已变化');
    finished.add(token);
  }

  @override
  Future<void> release(String token) async {
    if (failRelease) throw PlatformException(code: 'release_failed');
    releases.add(token);
  }
}
