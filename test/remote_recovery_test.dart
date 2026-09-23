import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/remote/remote_session_controller.dart';
import 'package:share_hub_open/platform/client_platform.dart';
import 'package:share_hub_open/ui/remote/remote_panel.dart';

import 'connection_recovery_test.dart'
    show RecoveryPlatform, RecoveryProxy, until;
import 'fakes.dart';
import 'support/recovery_media.dart';

void main() {
  late RecoveryPlatform ca, cb;
  late ConnectionController a, b;
  late RecoveryProxy proxy;
  late FakePlatform pa, pb;
  late RecoveryMedia fa, fb;
  late RemoteSessionController ra, rb;
  late List<CaptureSource> sourcesA, sourcesB;
  Completer<List<CaptureSource>>? lookupA, lookupB;
  int readsA = 0, readsB = 0;
  const primary = CaptureSource('primary', 'Primary', isPrimary: true);
  const window = CaptureSource(
    'window',
    'Window',
    type: CaptureSourceType.window,
  );
  setUp(() async {
    readsA = readsB = 0;
    sourcesA = sourcesB = [primary, window];
    lookupA = lookupB = null;
    ca = RecoveryPlatform(await DeviceIdentity.fromSeed(List.filled(32, 121)));
    cb = RecoveryPlatform(await DeviceIdentity.fromSeed(List.filled(32, 122)));
    a = ConnectionController(
      ca,
      recoveryBackoff: const [Duration(milliseconds: 100)],
    );
    b = ConnectionController(cb);
    pa = FakePlatform()..status = const PermissionStatus(screenRecording: true);
    pb = FakePlatform()..status = const PermissionStatus(screenRecording: true);
    fa = RecoveryMedia();
    fb = RecoveryMedia();
    ra = RemoteSessionController(
      connections: a,
      platform: pa,
      factory: fa,
      listSources: () {
        readsA++;
        return lookupA?.future ?? Future.value(sourcesA);
      },
      firstFrameDeadline: const Duration(milliseconds: 300),
      mediaRecoveryDeadline: const Duration(seconds: 2),
    );
    rb = RemoteSessionController(
      connections: b,
      platform: pb,
      factory: fb,
      listSources: () {
        readsB++;
        return lookupB?.future ?? Future.value(sourcesB);
      },
      firstFrameDeadline: const Duration(milliseconds: 300),
      mediaRecoveryDeadline: const Duration(seconds: 2),
    );
    await b.open();
    proxy = RecoveryProxy();
    await proxy.start(cb.port!);
    await a.connect('127.0.0.1', proxy.server.port, b.code!);
  });
  tearDown(() async {
    if (lookupA != null && !lookupA!.isCompleted) lookupA!.complete(sourcesA);
    if (lookupB != null && !lookupB!.isCompleted) lookupB!.complete(sourcesB);
    for (final picture in [...fa.pictures, ...fb.pictures]) {
      picture.failStop = false;
      if (picture.stopGate != null && !picture.stopGate!.isCompleted) {
        picture.stopGate!.complete();
      }
    }
    await Future.wait([
      ra.shutdown(),
      rb.shutdown(),
      a.shutdown(),
      b.shutdown(),
    ]);
    ra.dispose();
    rb.dispose();
    a.dispose();
    b.dispose();
    await proxy.close();
    await pa.events.close();
    await pb.events.close();
  });
  Future<void> start(SessionOperation op) async {
    await ra.start(op, peerKey: cb.key.encodedKey, label: 'Peer');
    await until(
      () =>
          fb.pictures.length == 1 && rb.phase == RemotePhase.waitingFirstFrame,
    );
    fa.pictures.single.emit(MediaEventKind.firstFrame);
    fb.pictures.single.emit(MediaEventKind.firstFrame);
  }

  Future<void> cut() async {
    proxy.cut();
    await until(() => ra.recovering && rb.recovering);
    expect(ra.phase, RemotePhase.recovering);
    expect(rb.phase, RemotePhase.recovering);
    expect(ra.transportReady, false);
    expect(ra.frameProgress, isNull);
  }

  Future<void> restored() async {
    await until(
      () =>
          fa.pictures.length == 2 &&
          fb.pictures.length == 2 &&
          !ra.recovering &&
          !rb.recovering,
    );
    expect(a.sessions.single.grant!.generation, 2);
    expect(ra.session!.id, isNot(fa.pictures.first.id));
  }

  for (final op in [SessionOperation.watch, SessionOperation.cast]) {
    test(
      '$op auto recovery retains selected window and awaits a new first frame',
      () async {
        await start(op);
        final sender = op == SessionOperation.cast ? ra : rb;
        await sender.loadSourceChoices();
        await sender.changeSource(window);
        await until(
          () =>
              fa.pictures.first.mediaRevision ==
              fb.pictures.first.mediaRevision,
        );
        fa.pictures.first.emit(MediaEventKind.firstFrame);
        fb.pictures.first.emit(MediaEventKind.firstFrame);
        final expiry = a.sessions.single.grant!.expiresMicros;
        await cut();
        await restored();
        expect(sender.localSource?.id, window.id);
        expect(ra.phase, RemotePhase.waitingFirstFrame);
        expect(rb.phase, RemotePhase.waitingFirstFrame);
        expect(a.sessions.single.grant!.expiresMicros, expiry);
        fa.pictures.first.emit(MediaEventKind.firstFrame);
        expect(ra.phase, RemotePhase.waitingFirstFrame);
        fa.pictures.last.emit(MediaEventKind.firstFrame);
        expect(ra.phase, RemotePhase.active);
      },
    );
  }
  test(
    'paused media stays paused without capture on restored transport',
    () async {
      await start(SessionOperation.cast);
      await ra.pause();
      await until(() => rb.phase == RemotePhase.paused);
      final captures = fa.captures + fb.captures;
      await cut();
      await restored();
      expect(ra.phase, RemotePhase.paused);
      expect(rb.phase, RemotePhase.paused);
      expect(fa.captures + fb.captures, captures);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(ra.phase, RemotePhase.paused);
      expect(rb.phase, RemotePhase.paused);
    },
  );
  testWidgets('media recovery remains stoppable at 200 percent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 600);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    late Completer<void> release;
    await tester.runAsync(() async {
      await start(SessionOperation.watch);
      release = fa.pictures.first.stopGate = Completer<void>();
      await cut();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AnimatedBuilder(
              animation: ra,
              builder: (_, _) => RemotePicturePanel(controller: ra),
            ),
          ),
        ),
      ),
    );
    expect(find.text('正在恢复与 Peer 的画面连接'), findsOneWidget);
    expect(find.textContaining('正在核验原来源和授权'), findsOneWidget);
    expect(ra.receiving, false); // Old cleanup owner must not expose its view.
    expect(find.text('已收到对端画面。'), findsNothing);
    expect(find.text('暂停'), findsNothing);
    final stop = find.text('停止并释放');
    await tester.ensureVisible(stop);
    await tester.tap(stop);
    expect(ra.recovering, false);
    await tester.runAsync(() async {
      release.complete();
      await ra.stop();
      await until(() => !rb.recovering);
    });
    await tester.pump();
    expect(ra.occupied, false);
    expect(fa.pictures, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final receiver in [false, true]) {
    test(
      '${receiver ? 'receiver' : 'initiator'} stop during loss cannot be restarted by reconnection',
      () async {
        await start(SessionOperation.cast);
        await cut();
        await (receiver ? rb : ra).stop();
        await until(() => a.sessions.length == 1 && b.sessions.length == 1);
        await until(() => !ra.recovering && !rb.recovering);
        expect(fa.pictures, hasLength(1));
        expect(fb.pictures, hasLength(1));
        expect(fa.captures, 1);
      },
    );
  }
  for (final reason in ['missing', 'primary-changed', 'permission']) {
    test(
      '$reason stops auto recovery without widening source or prompting',
      () async {
        await start(SessionOperation.watch);
        await cut();
        if (reason == 'missing') sourcesB = [window];
        if (reason == 'primary-changed') {
          sourcesB = [
            const CaptureSource('primary', 'Old'),
            const CaptureSource('other', 'New', isPrimary: true),
          ];
        }
        if (reason == 'permission') pb.status = const PermissionStatus();
        await until(() => !ra.recovering && !rb.recovering);
        expect(fb.captures, 1);
        expect(fb.pictures, hasLength(1));
        expect(pb.permissionRequests, 0);
        expect(rb.phase, RemotePhase.failed);
      },
    );
  }
  test(
    'pending old native release holds the original budget before replacement',
    () async {
      await start(SessionOperation.cast);
      final release = fa.pictures.first.stopGate = Completer<void>();
      await cut();
      await until(() => a.sessions.length == 1 && b.sessions.length == 1);
      expect(ra.budget.activeCount, 1);
      expect(fa.captures, 1);
      expect(fa.pictures, hasLength(1));
      release.complete();
      await restored();
      expect(ra.budget.activeCount, 1);
    },
  );
  test(
    'stop while source revalidation is pending isolates its late result',
    () async {
      await start(SessionOperation.cast);
      await cut();
      lookupA = Completer<List<CaptureSource>>();
      await until(() => readsA > 1 && a.sessions.length == 1);
      await ra.stop();
      lookupA!.complete(sourcesA);
      await until(() => !ra.recovering && !rb.recovering);
      expect(fa.captures, 1);
      expect(fa.pictures, hasLength(1));
    },
  );
  test(
    'native cleanup failure cancels recovery and remains retryable',
    () async {
      await start(SessionOperation.cast);
      fa.pictures.first.failStop = true;
      proxy.cut();
      await until(() => ra.cleanupFailed && !ra.recovering);
      expect(ra.budget.activeCount, 1);
      await until(
        () =>
            a.sessions.length == 1 && a.sessions.single.grant!.generation == 2,
      );
      expect(fa.captures, 1);
      expect(fa.pictures, hasLength(1));
      fa.pictures.first.failStop = false;
      await ra.stop();
      expect(ra.budget.activeCount, 0);
      expect(ra.cleanupFailed, false);
      expect(ra.occupied, false);
    },
  );

  test('exit waits for pending source revalidation and rejects its late completion', () async {
    await start(SessionOperation.cast);
    await cut();
    lookupA = Completer<List<CaptureSource>>();
    await until(() => readsA > 1);
    var exited = false;
    final exiting = ra.shutdown().then((_) => exited = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(exited, false);
    expect(ra.recovering, false);
    lookupA!.complete(sourcesA);
    await exiting;
    expect(fa.captures, 1);
    expect(ra.budget.activeCount, 0);
  });

  test(
    'synchronous exit on recovery notification owns pending cleanup',
    () async {
      await start(SessionOperation.cast);
      final released = fa.pictures.first.stopGate = Completer<void>();
      Future<void>? exiting;
      void exitListener() {
        if (ra.recovering && exiting == null) exiting = ra.shutdown();
      }

      ra.addListener(exitListener);
      proxy.cut();
      await until(() => exiting != null);
      var completed = false;
      final finished = exiting!.then((_) => completed = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(completed, false);
      released.complete();
      await finished;
      ra.removeListener(exitListener);
      expect(ra.budget.activeCount, 0);
      expect(fa.captures, 1);
      expect(ra.recovering, false);
    },
  );

  for (final receiver in [false, true]) {
    test(
      '${receiver ? 'receiver' : 'initiator'} continuous-clock window includes delayed source lookup',
      () async {
        await start(receiver ? SessionOperation.watch : SessionOperation.cast);
        await cut();
        final gate = Completer<List<CaptureSource>>();
        if (receiver) {
          lookupB = gate;
        } else {
          lookupA = gate;
        }
        await until(() => receiver ? readsB > 1 : readsA > 1);
        final clock = receiver ? cb : ca;
        clock.time += const Duration(seconds: 3).inMicroseconds;
        gate.complete(receiver ? sourcesB : sourcesA);
        await until(() => !(receiver ? rb : ra).recovering);
        expect((receiver ? rb : ra).phase, RemotePhase.failed);
        expect(fa.captures + fb.captures, 1);
      },
    );
  }

  test(
    'revoking admission during media recovery abandons both intents',
    () async {
      await start(SessionOperation.watch);
      await cut();
      await b.disconnectAll();
      await until(() => !ra.recovering && !rb.recovering);
      expect(fb.captures, 1);
      expect(fa.pictures, hasLength(1));
      expect(fb.pictures, hasLength(1));
    },
  );
}
