import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

void main() {
  ControlInputState ready({int Function()? clock}) {
    final state = ControlInputState(monotonicMicros: clock ?? () => 0);
    state.publish(
      ControlGeometry(
        sourceToken: 'a' * 32,
        revision: 1,
        mediaRevision: 1,
        width: 1920,
        height: 1080,
        originX: 0,
        originY: 0,
        scaleX: 1,
        scaleY: 1,
        rotation: 0,
      ),
    );
    state.geometryReady(
      ControlGeometryReady(
        sourceToken: 'a' * 32,
        geometryRevision: 1,
        mediaRevision: 1,
      ),
    );
    state.enable(inputEpoch: 1);
    return state;
  }

  ControlPointerMove move(int sequence, {int epoch = 1}) => ControlPointerMove(
    sequence: sequence,
    inputEpoch: epoch,
    geometryRevision: 1,
    x: .5,
    y: .5,
  );
  ControlKey key(int sequence, int usage, ControlKeyAction action) =>
      ControlKey(
        sequence: sequence,
        inputEpoch: 1,
        geometryRevision: 1,
        usage: usage,
        action: action,
      );

  test('only adjacent pending moves coalesce across input barriers', () {
    final state = ready();
    state.offer(move(1));
    state.offer(move(2));
    state.offer(key(3, 0x04, ControlKeyAction.down));
    state.offer(move(4));
    state.offer(move(5));
    expect(state.pendingCount, 3);
    final first = state.takeNext()!;
    expect(first.sequence, 2);
    state.complete(first, succeeded: true);
    final down = state.takeNext()!;
    expect(down.sequence, 3);
    state.complete(down, succeeded: true);
    expect(state.pressedKeys, [0x04]);
    final last = state.takeNext()!;
    expect(last.sequence, 5);
    state.complete(last, succeeded: true);
    expect(state.takeNext(), isNull);
  });

  test('rate limit and full edge queue stop instead of losing key-up', () {
    var now = 0;
    final state = ready(clock: () => now);
    for (var i = 1; i <= 64; i++) {
      state.offer(key(i, 0x04, ControlKeyAction.up));
    }
    expect(state.pendingCount, 64);
    expect(
      () => state.offer(key(65, 0x04, ControlKeyAction.down)),
      throwsA(isA<SessionFailure>()),
    );
    expect(state.isStopped, isTrue);
    expect(state.pendingCount, 0);
    final later = ready(clock: () => now);
    for (var i = 1; i <= 64; i++) {
      later.offer(move(i));
    }
    now = 1000000;
    later.offer(move(65));
    expect(later.isStopped, isFalse);
  });

  test('successful in-flight down after stop stays in cleanup ledger', () {
    final state = ready();
    final down = key(1, 0x04, ControlKeyAction.down);
    state.offer(down);
    expect(state.takeNext(), same(down));
    state.stop();
    state.complete(down, succeeded: true);
    expect(state.pressedKeys, [0x04]);
    expect(state.hasInFlight, isFalse);
    state.markKeyReleased(0x04);
    expect(state.pressedKeys, isEmpty);
    expect(() => state.offer(move(2)), throwsA(isA<SessionFailure>()));
  });

  test('release waits for in-flight completion and actual key cleanup', () {
    final state = ready();
    final down = key(1, 0x04, ControlKeyAction.down);
    state.offer(down);
    expect(state.takeNext(), same(down));
    state.beginRelease(ControlReleaseAll(inputEpoch: 1));
    expect(() => state.offer(move(2)), throwsA(isA<SessionFailure>()));
    expect(
      () => state.finishRelease(inputEpoch: 2),
      throwsA(isA<SessionFailure>()),
    );
    state.complete(down, succeeded: true);
    expect(
      () => state.finishRelease(inputEpoch: 2),
      throwsA(isA<SessionFailure>()),
    );
    state.markKeyReleased(0x04);
    state.finishRelease(inputEpoch: 2);
    state.offer(move(2, epoch: 2));
  });

  test('release can cancel an admitted call before native execution', () {
    final state = ready();
    final down = key(1, 0x04, ControlKeyAction.down);
    state.offer(down);
    expect(state.takeNext(), same(down));
    state.beginRelease(ControlReleaseAll(inputEpoch: 1));
    state.cancelUnexecuted(down);
    expect(state.hasInFlight, isFalse);
    expect(state.pressedKeys, isEmpty);
    final released = state.finishRelease(inputEpoch: 2);
    expect(released.inputEpoch, 2);
    state.offer(move(2, epoch: 2));
    expect(() => state.cancelUnexecuted(down), throwsA(isA<SessionFailure>()));
  });

  test(
    'failed down is not held and duplicate transitions need no native call',
    () {
      final state = ready();
      final failed = key(1, 0x04, ControlKeyAction.down);
      state.offer(failed);
      state.complete(state.takeNext()!, succeeded: false);
      expect(state.pressedKeys, isEmpty);
      expect(state.isStopped, isTrue);
      expect(
        () => state.offer(key(2, 0x04, ControlKeyAction.down)),
        throwsA(isA<SessionFailure>()),
      );
      final another = ready();
      final down = key(1, 0x04, ControlKeyAction.down);
      another.offer(down);
      another.complete(another.takeNext()!, succeeded: true);
      another.offer(key(2, 0x04, ControlKeyAction.down));
      another.offer(key(3, 0x04, ControlKeyAction.up));
      expect(another.takeNext()!.sequence, 3);
    },
  );

  test('failed key-up remains held until native release succeeds', () {
    final state = ready();
    state.offer(key(1, 0x04, ControlKeyAction.down));
    state.complete(state.takeNext()!, succeeded: true);
    state.offer(key(2, 0x04, ControlKeyAction.up));
    state.complete(state.takeNext()!, succeeded: false);
    expect(state.pressedKeys, [0x04]);
    expect(state.isStopped, isTrue);
    state.markKeyReleased(0x04);
    expect(state.pressedKeys, isEmpty);
  });

  test('33rd held key stops before another native down is dispatched', () {
    final state = ready();
    for (var i = 0; i < 32; i++) {
      state.offer(key(i + 1, 0x04 + i, ControlKeyAction.down));
      state.complete(state.takeNext()!, succeeded: true);
    }
    expect(state.pressedKeys.length, 32);
    state.offer(key(33, 0x24, ControlKeyAction.down));
    expect(() => state.takeNext(), throwsA(isA<SessionFailure>()));
    expect(state.isStopped, isTrue);
    expect(state.pressedKeys.length, 32);
    expect(state.hasInFlight, isFalse);
  });

  test(
    'cleanup cannot erase a held key while its key-up is still in flight',
    () {
      final state = ready();
      state.offer(key(1, 0x04, ControlKeyAction.down));
      state.complete(state.takeNext()!, succeeded: true);
      state.offer(key(2, 0x04, ControlKeyAction.up));
      final up = state.takeNext()!;
      state.stop();
      expect(() => state.markKeyReleased(0x04), throwsA(isA<SessionFailure>()));
      expect(state.pressedKeys, [0x04]);
      state.complete(up, succeeded: false);
      state.markKeyReleased(0x04);
      expect(state.pressedKeys, isEmpty);
    },
  );

  test('held mouse button also blocks release completion', () {
    final state = ready();
    final down = ControlPointerButton(
      sequence: 1,
      inputEpoch: 1,
      geometryRevision: 1,
      x: .5,
      y: .5,
      button: ControlButton.primary,
      down: true,
    );
    state.offer(down);
    state.complete(state.takeNext()!, succeeded: true);
    expect(state.pressedButtons, [ControlButton.primary]);
    state.beginRelease(ControlReleaseAll(inputEpoch: 1));
    expect(
      () => state.finishRelease(inputEpoch: 2),
      throwsA(isA<SessionFailure>()),
    );
    state.markButtonReleased(ControlButton.primary);
    state.finishRelease(inputEpoch: 2);
  });
}
