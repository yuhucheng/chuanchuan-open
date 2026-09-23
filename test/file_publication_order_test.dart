import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_file_transfer/share_hub_file_transfer.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart' show GrantRole;
import 'package:share_hub_open/features/transfers/file_publication_order.dart';

void main() {
  test('data attempts increase without reusing an abandoned request ID', () {
    final order = FilePublicationOrder();
    final ticket = order.reserve();
    expect(ticket.nextOperation(GrantRole.initiator).encoded, 'file-v2-i-1-1');
    // Allocation is consumed even if request creation or transmission fails.
    expect(ticket.nextOperation(GrantRole.initiator).encoded, 'file-v2-i-1-2');
    order.suspend();
    expect(
      () => ticket.nextOperation(GrantRole.initiator),
      throwsA(isA<FileProtocolFailure>()),
    );
    order.resume();
    expect(ticket.nextOperation(GrantRole.initiator).encoded, 'file-v2-i-1-3');
    expect(
      order.reserve().nextOperation(GrantRole.initiator).encoded,
      'file-v2-i-2-1',
    );
    order.close();
    expect(
      () => ticket.nextOperation(GrantRole.initiator),
      throwsA(isA<FileProtocolFailure>()),
    );
  });

  test('a ticket cannot change its authenticated producer direction', () {
    final order = FilePublicationOrder();
    final ticket = order.reserve();
    expect(ticket.nextOperation(GrantRole.receiver).encoded, 'file-v2-r-1-1');
    expect(
      () => ticket.nextOperation(GrantRole.initiator),
      throwsA(isA<FileProtocolFailure>()),
    );
    expect(ticket.nextOperation(GrantRole.receiver).encoded, 'file-v2-r-1-2');
    ticket.abandon();
    expect(
      () => ticket.nextOperation(GrantRole.receiver),
      throwsA(isA<FileProtocolFailure>()),
    );
    order.close();
  });

  test(
    'recovery restores the barrier for a written but unconfirmed low ordinal',
    () async {
      final order = FilePublicationOrder();
      final first = order.reserve(), second = order.reserve();
      await first.publish(() async {});
      expect(second.canPublish, isTrue);
      order.suspend();
      order.resume();
      expect(second.canPublish, isFalse);
      var laterWritten = false;
      final later = second.publish(() async => laterWritten = true);
      await Future<void>.delayed(Duration.zero);
      expect(laterWritten, isFalse);
      await first.publish(() async {});
      await later;
      expect(laterWritten, isTrue);
    },
  );

  test(
    'confirmed observation survives physical recovery without republishing',
    () async {
      final order = FilePublicationOrder();
      final first = order.reserve();
      await first.publish(() async {});
      first.confirmReceived();
      order.suspend();
      order.resume();
      final second = order.reserve();
      expect(second.canPublish, isTrue);
      await second.publish(() async {});
    },
  );

  test(
    'a late write from an old transport cannot release a recovered barrier',
    () async {
      final order = FilePublicationOrder();
      final first = order.reserve(), second = order.reserve();
      final write = Completer<void>(), entered = Completer<void>();
      final sending = first.publish(() {
        entered.complete();
        return write.future;
      });
      final rejected = expectLater(
        sending,
        throwsA(isA<FileProtocolFailure>()),
      );
      await entered.future;
      order.suspend();
      await rejected;
      order.resume();
      var laterWritten = false;
      final later = second.publish(() async => laterWritten = true);
      write.complete();
      await Future<void>.delayed(Duration.zero);
      expect(laterWritten, isFalse);
      await expectLater(
        Future.sync(first.confirmReceived),
        throwsA(isA<FileProtocolFailure>()),
      );
      await first.publish(() async {});
      await later;
      expect(laterWritten, isTrue);
    },
  );

  test('successful writes without peer confirmation still consume bounded retention', () async {
    final order = FilePublicationOrder();
    final written = <FilePublication>[];
    for (var index = 0; index < 64; index++) {
      final ticket = order.reserve();
      await ticket.publish(() async {});
      written.add(ticket);
    }
    expect(order.reserve, throwsA(isA<FileProtocolFailure>()));
    written.first.confirmReceived();
    expect(order.reserve().ordinal, 65);
    order.close();
  });

  test('an authenticated peer confirmation preserves publication across a lost write completion', () async {
    final order = FilePublicationOrder();
    final first = order.reserve(), next = order.reserve();
    final write = Completer<void>(),
        entered = Completer<void>(),
        stopped = Completer<void>();
    final sending = first.publish(() {
      entered.complete();
      return write.future;
    }, stopped: stopped.future);
    final rejected = expectLater(sending, throwsA(isA<FileProtocolFailure>()));
    await entered.future;
    first.confirmReceived();
    stopped.complete();
    await rejected;
    await next.publish(() async {}).timeout(const Duration(seconds: 1));
    expect(order.pendingCount, 0);
    write.complete();
  });

  test('stopping a queued attempt does not let its successor overtake an active write', () async {
    final order = FilePublicationOrder();
    final ticket = order.reserve();
    final active = Completer<void>(),
        entered = Completer<void>(),
        stopped = Completer<void>();
    final first = ticket.publish(() {
      entered.complete();
      return active.future;
    });
    await entered.future;
    final cancelled = ticket.publish(
      () async => fail('stopped queued write'),
      stopped: stopped.future,
    );
    final rejected = expectLater(
      cancelled,
      throwsA(isA<FileProtocolFailure>()),
    );
    stopped.complete();
    await rejected;
    var thirdWritten = false;
    final third = ticket.publish(() async => thirdWritten = true);
    await Future<void>.delayed(Duration.zero);
    expect(thirdWritten, isFalse);
    active.complete();
    await Future.wait([first, third]);
    expect(thirdWritten, isTrue);
  });

  test(
    'stopped attempts waiting for an earlier file leave no admission backlog',
    () async {
      final order = FilePublicationOrder();
      final first = order.reserve(), later = order.reserve();
      for (var attempt = 0; attempt < 128; attempt++) {
        final stopped = Completer<void>();
        final queued = later.publish(
          () async => fail('not admitted'),
          stopped: stopped.future,
        );
        final rejected = expectLater(
          queued,
          throwsA(isA<FileProtocolFailure>()),
        );
        stopped.complete();
        await rejected.timeout(const Duration(seconds: 1));
      }
      first.abandon();
      await later.publish(() async {}).timeout(const Duration(seconds: 1));
      expect(order.pendingCount, 0);
    },
  );

  test(
    'repeated stops finish each attempt while old writes remain unresolved',
    () async {
      final order = FilePublicationOrder();
      final ticket = order.reserve();
      final oldWrites = <Completer<void>>[];
      for (var attempt = 0; attempt < 16; attempt++) {
        final write = Completer<void>(),
            entered = Completer<void>(),
            stopped = Completer<void>();
        oldWrites.add(write);
        final publication = ticket.publish(() {
          entered.complete();
          return write.future;
        }, stopped: stopped.future);
        final rejected = expectLater(
          publication,
          throwsA(isA<FileProtocolFailure>()),
        );
        await entered.future.timeout(const Duration(seconds: 1));
        stopped.complete();
        await rejected.timeout(const Duration(seconds: 1));
        expect(order.pendingCount, 1);
      }
      await ticket.publish(() async {}).timeout(const Duration(seconds: 1));
      expect(order.pendingCount, 0);
      for (final old in oldWrites) {
        old.complete();
      }
      await order.reserve().publish(() async {});
      expect(order.pendingCount, 0);
    },
  );

  test('stopped transport releases an unfinished write for a fresh publication attempt', () async {
    final order = FilePublicationOrder();
    final first = order.reserve(), second = order.reserve();
    final oldWrite = Completer<void>(),
        entered = Completer<void>(),
        stopped = Completer<void>();
    final running = first.publish(() {
      entered.complete();
      return oldWrite.future;
    }, stopped: stopped.future);
    final rejected = expectLater(running, throwsA(isA<FileProtocolFailure>()));
    await entered.future;
    stopped.complete();
    await rejected.timeout(const Duration(seconds: 1));
    var laterWritten = false;
    final later = second.publish(() async => laterWritten = true);
    // The old completion cannot release its ordinal after the stop won.
    oldWrite.complete();
    await Future<void>.delayed(Duration.zero);
    expect(laterWritten, isFalse);
    await first.publish(() async {}).timeout(const Duration(seconds: 1));
    await later;
    expect(laterWritten, isTrue);
  });

  test(
    'abandoning a middle ordinal cannot bypass an earlier pending file',
    () async {
      final order = FilePublicationOrder();
      final first = order.reserve(),
          middle = order.reserve(),
          third = order.reserve();
      var sent = false;
      middle.abandon();
      final later = third.publish(() async => sent = true);
      await Future<void>.delayed(Duration.zero);
      expect(sent, isFalse);
      expect(third.canPublish, isFalse);
      await first.publish(() async {});
      await later;
      expect(sent, isTrue);
    },
  );

  test(
    'later first publication waits for an earlier source or termination',
    () async {
      final order = FilePublicationOrder();
      final first = order.reserve(), second = order.reserve();
      final sent = <String>[];
      final later = second.publish(() async => sent.add('offer-2'));
      await Future<void>.delayed(Duration.zero);
      expect(sent, isEmpty);
      expect(first.canPublish, isTrue);
      expect(second.canPublish, isFalse);
      await first.publish(() async => sent.add('terminate-1'));
      await later;
      expect(sent, ['terminate-1', 'offer-2']);
      expect(order.pendingCount, 0);
    },
  );

  test(
    'failed first write retains the barrier until a successful retry',
    () async {
      final order = FilePublicationOrder();
      final first = order.reserve(), second = order.reserve();
      final sent = <int>[];
      final later = second.publish(() async => sent.add(2));
      await expectLater(
        first.publish(() async => throw StateError('transport lost')),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(sent, isEmpty);
      expect(order.pendingCount, 2);
      await first.publish(() async => sent.add(1));
      await later;
      expect(sent, [1, 2]);
    },
  );

  test(
    'concurrent termination cannot overtake an in-flight first offer',
    () async {
      final order = FilePublicationOrder();
      final first = order.reserve(), second = order.reserve();
      final gate = Completer<void>(), entered = Completer<void>();
      final sent = <String>[];
      final offering = first.publish(() async {
        sent.add('offer');
        entered.complete();
        await gate.future;
      });
      await entered.future;
      final terminating = first.publish(() async => sent.add('terminate'));
      final next = second.publish(() async => sent.add('next'));
      await Future<void>.delayed(Duration.zero);
      expect(sent, ['offer']);
      gate.complete();
      await Future.wait([offering, terminating, next]);
      expect(sent.first, 'offer');
      expect(sent, containsAll(['terminate', 'next']));
      expect(order.pendingCount, 0);
    },
  );

  test('abandoning a never-owned ordinal unblocks its successor but cannot publish later', () async {
    final order = FilePublicationOrder();
    final first = order.reserve(), second = order.reserve();
    var sent = false;
    final next = second.publish(() async => sent = true);
    first.abandon();
    await next;
    expect(sent, isTrue);
    await expectLater(
      first.publish(() async => fail('abandoned publication')),
      throwsA(isA<FileProtocolFailure>()),
    );
  });

  test(
    'a waiting owner rechecks cancellation immediately before its write',
    () async {
      final order = FilePublicationOrder();
      final first = order.reserve(), second = order.reserve();
      var cancelled = false;
      final next = second.publish(() async {
        if (cancelled) throw StateError('owner stopped');
        fail('cancelled owner wrote');
      });
      final assertion = expectLater(next, throwsStateError);
      cancelled = true;
      first.abandon();
      await assertion;
      expect(order.pendingCount, 1);
      await second.publish(() async {}); // Its terminal control may publish.
      expect(order.pendingCount, 0);
    },
  );

  test('close releases waiters without allowing a queued write', () async {
    final order = FilePublicationOrder();
    order.reserve();
    final second = order.reserve();
    final pending = second.publish(() async => fail('closed order wrote'));
    final assertion = expectLater(pending, throwsA(isA<FileProtocolFailure>()));
    order.close();
    await assertion;
    expect(order.pendingCount, 0);
    expect(order.reserve, throwsA(isA<FileProtocolFailure>()));
  });

  test(
    'pending barriers are bounded and completed ones do not accumulate',
    () async {
      final order = FilePublicationOrder();
      final held = List.generate(64, (_) => order.reserve());
      expect(order.reserve, throwsA(isA<FileProtocolFailure>()));
      for (final ticket in held) {
        ticket.abandon();
      }
      for (var index = 0; index < 1000; index++) {
        final ticket = order.reserve();
        await ticket.publish(() async {});
        ticket.confirmReceived();
        expect(order.pendingCount, 0);
      }
      expect(order.reserve().ordinal, 1065);
      order.close();
    },
  );
}
