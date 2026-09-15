import 'dart:async';

import 'package:flutter/services.dart';

import 'file_fakes.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';
import 'package:share_hub_open/features/transfers/transfer_queue.dart';

Future<void> drainQueue(TransferQueue queue) async {
  for (var count = 0; count < 50; count++) {
    if (!queue.items.any((item) => item.canCancel)) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Queue did not settle.');
}

void main() {
  late TestFileAccess access;
  late TransferQueue queue;
  setUp(() {
    access = TestFileAccess();
    queue = TransferQueue(access);
  });
  tearDown(() async {
    await queue.close();
    queue.dispose();
  });

  test(
    'bounded incremental SHA-256 matches independent one-shot digest',
    () async {
      final bytes = Uint8List.fromList(
        List.generate(1024 * 1024 + 17, (index) => index % 251),
      );
      access.selection = [
        SelectedFile(token: 'one', name: 'data.bin', size: bytes.length),
      ];
      access.data['one'] = bytes;
      await queue.selectFiles();
      await drainQueue(queue);
      final item = queue.items.single;
      expect(item.state, PreparationState.ready);
      expect(item.checkedBytes, bytes.length);
      expect(item.sha256, sha256.convert(bytes).toString());
      expect(access.reads.length, 5);
      expect(
        access.reads.every((read) => read.$3 <= TransferQueue.chunkSize),
        true,
      );
      expect(access.maximumActiveReads, 1);
      expect(
        access.releases,
        isEmpty,
        reason: 'Ready files keep their local selection until removed.',
      );
      await queue.remove(item);
      expect(access.releases, ['one']);
    },
  );

  test('empty file still validates and has standard empty digest', () async {
    access.selection = [
      const SelectedFile(token: 'empty', name: 'empty', size: 0),
    ];
    await queue.selectFiles();
    await drainQueue(queue);
    expect(
      queue.items.single.sha256,
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(access.reads, isEmpty);
    expect(access.finished, ['empty']);
  });

  test('queued cancellation skips reading; in-flight cancellation discards late bytes', () async {
    access.selection = [
      const SelectedFile(token: 'one', name: 'one', size: 3),
      const SelectedFile(token: 'two', name: 'two', size: 3),
    ];
    access.pendingRead = Completer<Uint8List>();
    await queue.selectFiles();
    await queue.cancel(queue.items.last);
    await queue.cancel(queue.items.first);
    access.pendingRead!.complete(Uint8List.fromList([1, 2, 3]));
    await Future<void>.delayed(Duration.zero);
    expect(
      queue.items.every(
        (item) =>
            item.state == PreparationState.cancelled && item.sha256 == null,
      ),
      true,
    );
    expect(access.reads.map((read) => read.$1), ['one']);
    expect(access.finished, isEmpty);
    expect(access.releases.toSet(), {'one', 'two'});
    expect(access.releases.length, 2);
  });

  test('clearing a pending picker releases its late selection', () async {
    access.picker = Completer<List<SelectedFile>>();
    final picking = queue.selectFiles();
    await queue.clear();
    access.picker!.complete([
      const SelectedFile(token: 'late', name: 'late', size: 3),
    ]);
    await picking;
    expect(queue.items, isEmpty);
    expect(access.releases, ['late']);
    expect(access.reads, isEmpty);
  });

  test(
    'short reads fail, release access, and do not publish a digest',
    () async {
      access.selection = [
        const SelectedFile(token: 'short', name: 'short', size: 3),
      ];
      access.data['short'] = Uint8List.fromList([1, 2, 3]);
      access.shortRead = true;
      await queue.selectFiles();
      await drainQueue(queue);
      expect(queue.items.single.state, PreparationState.failed);
      expect(queue.items.single.sha256, isNull);
      expect(access.releases, ['short']);
    },
  );

  test('changed file at final check is not marked ready', () async {
    access.selection = [
      const SelectedFile(token: 'changed', name: 'changed', size: 0),
    ];
    access.failFinish = true;
    await queue.selectFiles();
    await drainQueue(queue);
    expect(queue.items.single.state, PreparationState.failed);
    expect(queue.items.single.error, '文件已变化');
    expect(queue.items.single.sha256, isNull);
    expect(access.releases, ['changed']);
  });

  test('failed removal retains an item so release can be retried', () async {
    access.selection = [
      const SelectedFile(token: 'held', name: 'held', size: 0),
    ];
    await queue.selectFiles();
    await drainQueue(queue);
    final item = queue.items.single;
    access.failRelease = true;
    await queue.remove(item);
    expect(queue.items, [item]);
    expect(item.error, contains('释放失败'));
    access.failRelease = false;
    await queue.remove(item);
    expect(queue.items, isEmpty);
    expect(access.releases, ['held']);
  });

  test(
    'over-limit selection releases every new token without reading files',
    () async {
      access.selection = List.generate(
        65,
        (i) => SelectedFile(token: '$i', name: '$i', size: 0),
      );
      await queue.selectFiles();
      expect(queue.error, contains('64'));
      expect(queue.items, isEmpty);
      expect(access.releases.length, 65);
      expect(access.reads, isEmpty);
    },
  );

  test(
    'closing waits for pending reads and releases all selected handles',
    () async {
      access.selection = [
        const SelectedFile(token: 'one', name: 'one', size: 3),
      ];
      access.pendingRead = Completer<Uint8List>();
      await queue.selectFiles();
      final closing = queue.close();
      access.pendingRead!.complete(Uint8List.fromList([1, 2, 3]));
      await closing;
      expect(queue.items, isEmpty);
      expect(access.releases, ['one']);
      expect(access.finished, isEmpty);
    },
  );

  test(
    'one failed file does not prevent the following file from being checked',
    () async {
      access.selection = [
        const SelectedFile(token: 'bad', name: 'bad', size: 3),
        const SelectedFile(token: 'good', name: 'good', size: 0),
      ];
      access.data['bad'] = Uint8List.fromList([1, 2, 3]);
      access.shortRead = true;
      await queue.selectFiles();
      await drainQueue(queue);
      expect(queue.items.first.state, PreparationState.failed);
      expect(queue.items.last.state, PreparationState.ready);
      expect(access.finished, ['good']);
    },
  );

  test(
    'closing while picker is open releases the late selection without reading',
    () async {
      access.picker = Completer<List<SelectedFile>>();
      final picking = queue.selectFiles();
      final closing = queue.close();
      access.picker!.complete([
        const SelectedFile(token: 'late', name: 'late', size: 3),
      ]);
      await Future.wait([picking, closing]);
      expect(queue.items, isEmpty);
      expect(access.releases, ['late']);
      expect(access.reads, isEmpty);
    },
  );
}
