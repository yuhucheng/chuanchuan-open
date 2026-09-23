import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/transfers/receive_access.dart';
import 'package:share_hub_open/features/transfers/receive_directories.dart';

void main() {
  late _Access access;
  late ReceiveDirectories directories;
  setUp(() {
    access = _Access();
    directories = ReceiveDirectories(access);
  });
  tearDown(() async {
    if (access.openGate case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    if (access.pickGate case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    access.failRelease = false;
    await directories.close();
    directories.dispose();
  });

  test('concurrent acquires share one default capability and retain separate leases', () async {
    final uses = await Future.wait([
      directories.acquire(),
      directories.acquire(),
    ]);
    expect(access.opens, 1);
    expect(uses.first.directory, same(uses.last.directory));
    await uses.first.release();
    expect(access.released, isEmpty);
    await uses.last.release();
    expect(
      access.released,
      isEmpty,
      reason: 'Current setting remains available.',
    );
    await directories.close();
    expect(access.released, ['default']);
  });

  test(
    'changing directory affects new files and retains old active destination',
    () async {
      final old = await directories.acquire();
      await directories.pick();
      final next = await directories.acquire();
      expect(next.directory.token, 'picked');
      expect(old.directory.token, 'default');
      expect(access.released, isEmpty);
      await old.release();
      expect(access.released, ['default']);
      await next.release();
      await directories.close();
      expect(access.released, ['default', 'picked']);
    },
  );

  test('failed default does not fall back and settings can still choose a directory', () async {
    access.failDefault = true;
    await expectLater(
      directories.acquire(),
      throwsA(isA<ReceiveAccessFailure>()),
    );
    expect(directories.current, isNull);
    await directories.pick();
    final use = await directories.acquire();
    expect(use.directory.token, 'picked');
    expect(access.opens, 1);
    await use.release();
  });

  test('cancelled picker preserves the current destination', () async {
    final original = await directories.acquire();
    access.cancelPick = true;
    await directories.pick();
    expect(directories.current, same(original.directory));
    await original.release();
  });

  test('first receive waits for an in-flight directory selection', () async {
    access.pickGate = Completer<void>();
    final picking = directories.pick();
    final acquiring = directories.acquire();
    await Future<void>.delayed(Duration.zero);
    access.pickGate!.complete();
    await picking;
    final lease = await acquiring;
    try {
      expect(lease.directory.token, 'picked');
      expect(
        access.opens,
        0,
        reason: 'No stale setting replaces the selection.',
      );
    } finally {
      await lease.release();
    }
  });
  test(
    'failed native preference save preserves the current directory and lease',
    () async {
      final lease = await directories.acquire();
      access.failPick = true;
      await expectLater(
        directories.pick(),
        throwsA(isA<ReceiveAccessFailure>()),
      );
      expect(directories.current, same(lease.directory));
      final next = await directories.acquire();
      expect(next.directory, same(lease.directory));
      expect(access.released, isEmpty);
      expect(directories.error, isNotNull);
      await lease.release();
      await next.release();
    },
  );

  test(
    'release failure retains capability and a retry does not decrement twice',
    () async {
      final original = await directories.acquire();
      await directories.pick();
      access.failRelease = true;
      await expectLater(original.release(), throwsStateError);
      expect(access.released, isEmpty);
      access.failRelease = false;
      await original.release();
      await original.release();
      expect(access.released, ['default']);
    },
  );

  test(
    'close refuses to abandon active leases and succeeds after they release',
    () async {
      final use = await directories.acquire();
      await expectLater(directories.close(), throwsStateError);
      expect(access.released, isEmpty);
      await expectLater(directories.acquire(), throwsStateError);
      await use.release();
      await directories.close();
      expect(access.released, ['default']);
    },
  );

  test('closing during default lookup releases its late token without granting a lease', () async {
    access.openGate = Completer<void>();
    final acquiring = directories.acquire();
    final rejected = expectLater(acquiring, throwsStateError);
    final closing = directories.close();
    access.openGate!.complete();
    await Future.wait([rejected, closing]);
    expect(access.released, ['default']);
    expect(directories.current, isNull);
  });

  test('closing during picker releases the late chosen directory', () async {
    access.pickGate = Completer<void>();
    final picking = directories.pick();
    final rejected = expectLater(picking, throwsStateError);
    final closing = directories.close();
    access.pickGate!.complete();
    await Future.wait([rejected, closing]);
    expect(access.released, ['picked']);
    expect(directories.current, isNull);
  });
}

class _Access implements ReceiveAccess {
  int opens = 0;
  bool failDefault = false,
      failRelease = false,
      cancelPick = false,
      failPick = false;
  Completer<void>? openGate, pickGate;
  final released = <String>[];
  @override
  Future<ReceiveDirectory> configuredDirectory() async {
    opens++;
    if (openGate != null) await openGate!.future;
    if (failDefault) throw const ReceiveAccessFailure('permission_denied');
    return const ReceiveDirectory(token: 'default', label: 'Downloads/串串');
  }

  @override
  Future<ReceiveDirectory?> pickDirectory() async {
    if (pickGate != null) await pickGate!.future;
    if (failPick) throw const ReceiveAccessFailure('settings_unavailable');
    return cancelPick
        ? null
        : const ReceiveDirectory(token: 'picked', label: 'Chosen');
  }

  @override
  Future<void> releaseDirectory(ReceiveDirectory directory) async {
    if (failRelease) throw StateError('native close failed');
    released.add(directory.token);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
