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
  test('native drop admission uses the same bounded preparation and owns tokens only on success', () async {
    final access = TestFileAccess();
    final queue = TransferQueue(access);
    final bytes = Uint8List(600000);
    access.data['drop'] = bytes;
    final admitted = queue.admitDroppedFiles([
      const SelectedFile(token: 'drop', name: 'drop.bin', size: 600000),
    ]);
    expect(admitted, isNotNull);
    await drainQueue(queue);
    expect(queue.items.single.state, PreparationState.ready);
    expect(queue.items.single.sha256, isNotNull);
    expect(access.reads.map((read) => read.$3), [262144, 262144, 75712]);
    expect(
      queue.admitDroppedFiles([
        const SelectedFile(token: 'drop', name: 'again.bin', size: 600000),
      ]),
      isNull,
    );
    expect(
      access.releases,
      isEmpty,
      reason: 'Rejected offer remains owned by native caller.',
    );
    await queue.close();
    expect(access.releases, ['drop']);
  });

  test(
    'native drops reject overflow atomically and cannot revive a closed queue',
    () async {
      final access = TestFileAccess();
      final queue = TransferQueue(access);
      final files = List.generate(
        65,
        (i) => SelectedFile(token: 'drop-$i', name: '$i.bin', size: 0),
      );
      expect(queue.admitDroppedFiles(files), isNull);
      expect(queue.items, isEmpty);
      expect(access.releases, isEmpty);
      expect(queue.admitDroppedFiles(files.take(64).toList()), hasLength(64));
      await drainQueue(queue);
      expect(
        queue.items.every((item) => item.state == PreparationState.ready),
        isTrue,
      );
      expect(queue.admitDroppedFiles([files.last]), isNull);
      expect(queue.items, hasLength(64));
      await queue.close();
      expect(queue.admitDroppedFiles(files.take(1).toList()), isNull);
      expect(queue.items, isEmpty);
    },
  );
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

  Future<TransferItem> ready(String token) async {
    access.selection = [SelectedFile(token: token, name: token, size: 0)];
    await queue.selectFiles();
    await drainQueue(queue);
    return queue.items.last;
  }

  test(
    'removal stops the network owner before releasing its selected token',
    () async {
      final item = await ready('held');
      final stopped = Completer<void>();
      var stopCalls = 0;
      final use = queue.claim(
        item,
        onStop: () {
          stopCalls++;
          return stopped.future;
        },
      );
      expect(use.file, same(item.file));
      expect(use.sha256, item.sha256);
      expect(item.canSend, isFalse);
      final removing = queue.remove(item);
      expect(stopCalls, 1);
      expect(access.releases, isEmpty);
      expect(queue.items, [item]);
      expect(() => queue.claim(item, onStop: () async {}), throwsStateError);
      stopped.complete();
      await removing;
      expect(access.releases, ['held']);
      expect(queue.items, isEmpty);
      await use.release();
      expect(stopCalls, 1);
    },
  );

  test(
    'clear dispatches every network stop before awaiting any one file',
    () async {
      final first = await ready('first');
      final second = await ready('second');
      final gate = Completer<void>();
      final stopped = <String>[];
      queue.claim(
        first,
        onStop: () {
          stopped.add('first');
          return gate.future;
        },
      );
      queue.claim(
        second,
        onStop: () async {
          stopped.add('second');
        },
      );
      final clearing = queue.clear();
      expect(stopped, ['first', 'second']);
      expect(access.releases, isNot(contains('first')));
      gate.complete();
      await clearing;
      expect(access.releases.toSet(), {'first', 'second'});
      expect(queue.items, isEmpty);
    },
  );

  test(
    'failed network cleanup retains the token and retries before release',
    () async {
      final item = await ready('retry');
      var failStop = true;
      var calls = 0;
      queue.claim(
        item,
        onStop: () async {
          calls++;
          if (failStop) throw StateError('native stop failed');
        },
      );
      await queue.remove(item);
      expect(queue.items, [item]);
      expect(access.releases, isEmpty);
      expect(item.error, contains('释放失败'));
      failStop = false;
      await queue.remove(item);
      expect(calls, 2);
      expect(access.releases, ['retry']);
    },
  );

  test(
    'finished use closes once but keeps selection until explicit removal',
    () async {
      final item = await ready('done');
      var calls = 0;
      final use = queue.claim(
        item,
        onStop: () async {
          calls++;
        },
      );
      await Future.wait([use.release(), use.release()]);
      expect(calls, 1);
      expect(access.releases, isEmpty);
      expect(
        item.canSend,
        isFalse,
        reason: 'Native source binding cannot be reused for another transfer.',
      );
      await queue.remove(item);
      expect(calls, 1);
      expect(access.releases, ['done']);
    },
  );

  test('claim rejects non-ready and foreign selections', () async {
    final foreign =
        TransferItem(const SelectedFile(token: 'foreign', name: 'x', size: 0))
          ..state = PreparationState.ready
          ..sha256 = '0' * 64;
    expect(() => queue.claim(foreign, onStop: () async {}), throwsStateError);
    await queue.remove(foreign);
    expect(access.releases, isEmpty);
    access.selection = [
      const SelectedFile(token: 'pending', name: 'x', size: 1),
    ];
    access.pendingRead = Completer<Uint8List>();
    await queue.selectFiles();
    expect(
      () => queue.claim(queue.items.single, onStop: () async {}),
      throwsStateError,
    );
    access.pendingRead!.complete(Uint8List.fromList([1]));
    await drainQueue(queue);
  });

  test(
    'close holds tokens until all claimed native owners have stopped',
    () async {
      final item = await ready('exit');
      final gate = Completer<void>();
      queue.claim(item, onStop: () => gate.future);
      final closing = queue.close();
      expect(access.releases, isEmpty);
      gate.complete();
      await closing;
      expect(queue.items, isEmpty);
      expect(access.releases, ['exit']);
      expect(() => queue.claim(item, onStop: () async {}), throwsStateError);
    },
  );

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
