import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/preview/preview_controller.dart';
import 'package:share_hub_open/features/remote/remote_media.dart';
import 'package:share_hub_open/features/remote/remote_session_controller.dart';
import 'package:share_hub_open/platform/client_platform.dart';
import 'package:share_hub_open/ui/remote/remote_panel.dart';
import 'package:share_hub_open/ui/field/device_field.dart';
import 'package:share_hub_open/features/devices/device_directory.dart';

import 'fakes.dart';

/// Two real authenticated connections over loopback plus a fake media layer, so
/// authorization, direction, grant lifetime and the single picture budget are
/// real while capture, peer connection and rendering are substituted.
class _FakeConnectionPlatform implements ConnectionPlatform {
  final seed = Completer<DeviceIdentity>();
  final advertisements = <int?>[];
  @override
  Future<DeviceIdentity> identity() => seed.future;
  @override
  Future<int> now() async => 1000;
  @override
  Future<String?> advertise(int? port, String? key) async {
    advertisements.add(port);
    return 'test.local';
  }
}

class _FakePicture
    implements SourceSelectableRemotePicture, ThumbnailRemotePicture {
  _FakePicture({
    required this.id,
    required this.operation,
    required this.sends,
  });
  @override
  final String id;
  @override
  final SessionOperation operation;
  @override
  final bool sends;
  final _events = StreamController<MediaSessionEvent>.broadcast(sync: true);
  Stream<MediaSessionEvent>? eventStreamOverride;
  VideoEndReason? endedBy;
  bool failStop = false;
  final stopReasons = <VideoEndReason>[];
  int stops = 0, resumes = 0;
  bool stoppedFlag = false;

  @override
  Stream<MediaSessionEvent> get events => eventStreamOverride ?? _events.stream;
  @override
  Widget get view =>
      const SizedBox(key: ValueKey('remote-view'), width: 8, height: 8);
  @override
  Widget get thumbnailView =>
      const SizedBox(key: ValueKey('borrowed-thumbnail'), height: 90);
  @override
  int mediaRevision = 0;
  @override
  CaptureSource? localSource;
  final changes = <CaptureSource>[];
  Completer<void>? changeGate;
  Completer<void>? playbackGate;
  Completer<void>? stopGate;
  bool failPlayback = false;
  bool failChange = false;
  @override
  Future<void> changeSource(CaptureSource source) async {
    changes.add(source);
    if (changeGate != null) await changeGate!.future;
    if (stoppedFlag) throw const SessionFailure('operation_stopped');
    if (failChange) throw const SessionFailure('source_unavailable');
    localSource = source;
    mediaRevision++;
    emit(MediaEventKind.waitingFirstFrame);
  }

  @override
  bool get stopped => stoppedFlag;
  @override
  VideoEndReason? get remoteEndReason => endedBy;

  void emit(
    MediaEventKind kind, {
    String? failureCode,
    int? revision,
    MediaTransportPath? transportPath,
    Duration? roundTripTime,
    int? bitsPerSecond,
    int? frameWidth,
    int? frameHeight,
    MediaFrameProgress? frameProgress,
  }) {
    if (_events.isClosed) return;
    _events.add(
      MediaSessionEvent(
        grantId: 'grant',
        sessionId: id,
        transportGeneration: 1,
        mediaRevision: revision ?? mediaRevision,
        kind: kind,
        failureCode: failureCode,
        transportPath: transportPath,
        roundTripTime: roundTripTime,
        bitsPerSecond: bitsPerSecond,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        frameProgress: frameProgress,
      ),
    );
  }

  void finish() {
    if (!_events.isClosed) unawaited(_events.close());
  }

  @override
  Future<void> pause() async {
    if (playbackGate != null) await playbackGate!.future;
    if (failPlayback) throw StateError('playback failed');
  }

  @override
  Future<void> resume() async {
    if (playbackGate != null) await playbackGate!.future;
    if (failPlayback) throw StateError('playback failed');
    resumes++;
    mediaRevision++;
    emit(MediaEventKind.waitingFirstFrame);
  }

  @override
  Future<void> stop({VideoEndReason reason = VideoEndReason.stopped}) async {
    stops++;
    stopReasons.add(reason);
    if (stopGate != null) await stopGate!.future;
    if (failStop) throw StateError('cleanup failed');
    stoppedFlag = true;
    finish();
  }
}

/// Tracks real subscriptions, optionally failing the first native detach while
/// its listener remains owned until cancellation is retried.
class _CancelOnceStream<T> extends Stream<T> {
  _CancelOnceStream(this.source, {this.failFirstCancel = true});
  final Stream<T> source;
  final bool failFirstCancel;
  int listeners = 0, cancellations = 0;

  @override
  bool get isBroadcast => source.isBroadcast;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listeners++;
    return _CancelOnceSubscription(
      this,
      source.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      ),
    );
  }
}

class _CancelOnceSubscription<T> implements StreamSubscription<T> {
  _CancelOnceSubscription(this.owner, this.delegate);
  final _CancelOnceStream<T> owner;
  final StreamSubscription<T> delegate;

  @override
  Future<void> cancel() async {
    if (++owner.cancellations == 1 && owner.failFirstCancel) {
      throw StateError('subscription cleanup');
    }
    await delegate.cancel();
  }

  @override
  void onData(void Function(T data)? handleData) => delegate.onData(handleData);
  @override
  void onError(Function? handleError) => delegate.onError(handleError);
  @override
  void onDone(void Function()? handleDone) => delegate.onDone(handleDone);
  @override
  void pause([Future<void>? resumeSignal]) => delegate.pause(resumeSignal);
  @override
  void resume() => delegate.resume();
  @override
  bool get isPaused => delegate.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => delegate.asFuture<E>(futureValue);
}

class _FakeLink {
  _FakeLink(this.transport, this.onSession, this.onFailure);
  final SessionTransport transport;
  final void Function(RemotePicture) onSession;
  final void Function(String, String) onFailure;
  final starts = <SessionOperation>[];
  Completer<void>? gate;
  Completer<void>? closeGate, pictureStopGate;
  bool failStartAfterAdoption = false, failStop = false;
  bool failClose = false;
  int closeCalls = 0;
  bool closed = false;
  _FakePicture? picture;

  Future<void> close() async {
    closeCalls++;
    closed = true;
    if (closeGate != null) await closeGate!.future;
    if (failClose) throw StateError('link cleanup failed');
    picture?.finish();
  }
}

class _FakeFactory implements RemotePictureFactory {
  _FakeFactory({MediaCapabilities? declared})
    : declared =
          declared ??
          MediaCapabilities(
            protocolVersion: sessionProtocolVersion,
            operations: const {SessionOperation.watch, SessionOperation.cast},
            maxVideoSessions: 1,
          );
  final MediaCapabilities declared;
  final links = <_FakeLink>[];
  final delivered = <RemotePicture>[];
  final failures = <String>[];
  bool failNextEventCancellation = false;

  @override
  MediaCapabilities get capabilities => declared;

  _FakeLink get link => links.last;
  _FakePicture get current => links.last.picture!;

  @override
  RemotePictureLink create({
    required SessionTransport transport,
    required MediaSessionBudget budget,
    required Future<CaptureSource> Function() resolveSource,
    required void Function(RemotePicture session) onSession,
    required void Function(String sessionId, String code) onFailure,
  }) {
    final link = _FakeLink(transport, onSession, onFailure);
    links.add(link);
    // The real authorization path is sealed through the connection's grant.
    return _GrantCheckedLink(link, transport, resolveSource, this);
  }

  void deliver(RemotePicture picture, {_FakeLink? via}) {
    delivered.add(picture);
    (via ?? link).onSession(picture);
  }

  _FakeLink forConnection(TrustedConnection connection) =>
      links.singleWhere((link) => identical(link.transport, connection));

  void reportFailure(String sessionId, String code, {_FakeLink? via}) {
    (via ?? link).onFailure(sessionId, code);
  }
}

/// Mirrors the media link: authorize through the real transport, resolve the
/// local source only when this endpoint sends, and report the failure code.
class _GrantCheckedLink implements RemotePictureLink {
  _GrantCheckedLink(
    this._link,
    this._transport,
    this._resolveSource,
    this._factory,
  );
  final _FakeLink _link;
  final SessionTransport _transport;
  final Future<CaptureSource> Function() _resolveSource;
  final _FakeFactory _factory;

  @override
  Future<RemotePicture> start(
    SessionOperation operation,
    String sessionId,
  ) async {
    _link.starts.add(operation);
    // Throws direction_denied / capability_unavailable for a refused direction.
    await _transport.createRequest(
      operation,
      sessionId,
      VideoSessionRequest.body,
    );
    if (_link.gate != null) await _link.gate!.future;
    if (operation == SessionOperation.cast) {
      try {
        await _resolveSource();
      } catch (error) {
        _factory.reportFailure(
          sessionId,
          error is SessionFailure ? error.code : 'media_start_failed',
          via: _link,
        );
        rethrow;
      }
    }
    final picture =
        _FakePicture(
            id: sessionId,
            operation: operation,
            sends: operation == SessionOperation.cast,
          )
          ..failStop = _link.failStop
          ..stopGate = _link.pictureStopGate;
    if (_factory.failNextEventCancellation) {
      _factory.failNextEventCancellation = false;
      picture.eventStreamOverride = _CancelOnceStream(picture.events);
    }
    _link.picture = picture;
    _factory.deliver(picture, via: _link);
    if (_link.failStartAfterAdoption) {
      throw const SessionFailure('media_start_failed');
    }
    return picture;
  }

  @override
  Future<void> close() => _link.close();
}

void main() {
  late ConnectionController a, b;
  late RemoteSessionController remoteA, remoteB;
  late _FakeFactory factoryA, factoryB;
  late FakePlatform platformA, platformB;
  late List<CaptureSource> sourcesA;
  late bool previewActive;
  var sourceListCallsA = 0;

  MediaFrameProgress receiverProgress() => MediaFrameProgress(
    stage: MediaFrameStage.receiver,
    active: true,
    sequence: 2,
    age: const Duration(milliseconds: 10),
    consumedSequence: 1,
    consumedFrameAge: const Duration(seconds: 2),
  );
  Completer<List<CaptureSource>>? sourceListGate;

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  setUp(() async {
    final aPlatform = _FakeConnectionPlatform();
    final bPlatform = _FakeConnectionPlatform();
    a = ConnectionController(aPlatform);
    b = ConnectionController(bPlatform);
    final aIdentity = await DeviceIdentity.fromSeed(List.filled(32, 21));
    final bIdentity = await DeviceIdentity.fromSeed(List.filled(32, 22));
    aPlatform.seed.complete(aIdentity);
    bPlatform.seed.complete(bIdentity);
    await b.open();
    final port = bPlatform.advertisements.whereType<int>().last;
    await a.connect(
      '127.0.0.1',
      port,
      b.code!,
      expectedPeerKey: bIdentity.encodedKey,
    );
    expect(a.sessions, hasLength(1));
    expect(b.sessions, hasLength(1));
    platformA = FakePlatform()
      ..status = const PermissionStatus(screenRecording: true);
    platformB = FakePlatform()
      ..status = const PermissionStatus(screenRecording: true);
    sourcesA = const [CaptureSource('screen:1', '内建显示器', isPrimary: true)];
    previewActive = false;
    sourceListGate = null;
    sourceListCallsA = 0;
    factoryA = _FakeFactory();
    factoryB = _FakeFactory();
  });

  tearDown(() async {
    // Also unblock cleanup if a new shutdown assertion fails before releasing
    // its gate; leave existing fake success/failure semantics unchanged.
    for (final factory in [factoryA, factoryB]) {
      for (final link in factory.links) {
        link.failClose = false;
        for (final gate in [link.gate, link.closeGate, link.pictureStopGate]) {
          if (gate != null && !gate.isCompleted) gate.complete();
        }
      }
      for (final picture in factory.delivered.whereType<_FakePicture>()) {
        picture.failStop = false;
        final gate = picture.stopGate;
        if (gate != null && !gate.isCompleted) gate.complete();
      }
    }
    remoteA.dispose();
    remoteB.dispose();
    await a.disconnectAll();
    await b.disconnectAll();
    a.dispose();
    b.dispose();
  });

  void build({
    bool Function()? localCaptureOccupied,
    bool Function()? relayCredentialAvailable,
    Duration statisticsLifetime = const Duration(seconds: 6),
  }) {
    remoteA = RemoteSessionController(
      connections: a,
      platform: platformA,
      factory: factoryA,
      listSources: () async {
        sourceListCallsA++;
        return sourceListGate?.future ?? sourcesA;
      },
      localCaptureActive: localCaptureOccupied ?? () => previewActive,
      relayCredentialAvailable: relayCredentialAvailable,
      firstFrameDeadline: const Duration(milliseconds: 150),
      permissionPoll: const Duration(milliseconds: 20),
      statisticsLifetime: statisticsLifetime,
    );
    remoteB = RemoteSessionController(
      connections: b,
      platform: platformB,
      factory: factoryB,
      listSources: () async => sourceListGate?.future ?? sourcesA,
      localCaptureActive: localCaptureOccupied ?? () => previewActive,
      firstFrameDeadline: const Duration(milliseconds: 150),
      permissionPoll: const Duration(milliseconds: 20),
    );
  }

  test('declares the offered operations and one shared picture budget', () {
    build();
    expect(remoteA.offeredOperations, {'watch', 'cast'});
    expect(remoteA.budget.capabilities.maxVideoSessions, 1);
    expect(remoteA.occupied, isFalse);
    // One receiver per live connection, created without touching any device.
    expect(factoryA.links, hasLength(1));
    expect(factoryA.links.single.starts, isEmpty);
  });

  test('late relay lease retries a pre-transport timeout once with a new operation', () async {
    var relayReady = false;
    build(relayCredentialAvailable: () => relayReady);
    final peer = a.sessions.single.peerKey;
    await remoteA.start(SessionOperation.watch, peerKey: peer);
    final first = factoryA.current;
    final firstId = first.id;
    relayReady = true;
    first.emit(MediaEventKind.failed, failureCode: 'media_connection_timeout');
    first.stoppedFlag = true; // SDK releases native resources before ended.
    first.emit(MediaEventKind.ended);
    await waitFor(() => factoryA.link.starts.length == 2);
    expect(factoryA.current.id, isNot(firstId));
    expect(remoteA.phase, RemotePhase.connecting);
    final second = factoryA.current;
    second.emit(MediaEventKind.failed, failureCode: 'media_connection_timeout');
    second.stoppedFlag = true;
    second.emit(MediaEventKind.ended);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(factoryA.link.starts, hasLength(2));
  });

  test(
    'relay fallback cannot revive an explicitly stopped operation',
    () async {
      var relayReady = false;
      build(relayCredentialAvailable: () => relayReady);
      await remoteA.start(
        SessionOperation.watch,
        peerKey: a.sessions.single.peerKey,
      );
      final first = factoryA.current;
      relayReady = true;
      first.emit(
        MediaEventKind.failed,
        failureCode: 'media_connection_timeout',
      );
      await remoteA.stop();
      first.emit(MediaEventKind.ended);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(factoryA.link.starts, hasLength(1));
    },
  );

  test(
    'existing relay or failed event cleanup cannot start a fallback',
    () async {
      var relayReady = true;
      build(relayCredentialAvailable: () => relayReady);
      final peer = a.sessions.single.peerKey;
      await remoteA.start(SessionOperation.watch, peerKey: peer);
      final first = factoryA.current;
      first.emit(MediaEventKind.failed, failureCode: 'media_transport_lost');
      first.stoppedFlag = true;
      first.emit(MediaEventKind.ended);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(factoryA.link.starts, hasLength(1));

      relayReady = false;
      factoryA.failNextEventCancellation = true;
      await remoteA.start(SessionOperation.watch, peerKey: peer);
      final second = factoryA.current;
      relayReady = true;
      second.emit(MediaEventKind.failed, failureCode: 'media_transport_lost');
      second.stoppedFlag = true;
      second.emit(MediaEventKind.ended);
      await waitFor(() => remoteA.cleanupFailed);
      expect(factoryA.link.starts, hasLength(2));
    },
  );

  test('presentation deadline begins after ICE is connected', () async {
    build();
    await remoteA.start(
      SessionOperation.watch,
      peerKey: a.sessions.single.peerKey,
    );
    final picture = factoryA.current;
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(remoteA.phase, RemotePhase.connecting);
    expect(picture.stops, 0);
    picture.emit(MediaEventKind.transportReady);
    await waitFor(() => picture.stops == 1);
    expect(remoteA.phase, RemotePhase.failed);
  });

  for (final operation in [SessionOperation.watch, SessionOperation.cast]) {
    test(
      '$operation thumbnail is bound to the active identity and media revision',
      () async {
        build();
        final peer = a.sessions.single.peerKey;
        expect(remoteA.thumbnailFor(peer), isNull);
        await remoteA.start(operation, peerKey: peer);
        final picture = factoryA.current;
        expect(remoteA.thumbnailFor(peer), isNull);
        picture.emit(MediaEventKind.firstFrame);
        expect(remoteA.thumbnailFor(peer), same(picture));
        expect(remoteA.thumbnailFor('same-name-other-identity'), isNull);
        final lookups = sourceListCallsA;
        for (var i = 0; i < 20; i++) {
          remoteA.thumbnailFor(peer);
        }
        expect(sourceListCallsA, lookups);
        expect(factoryA.link.starts, [operation]);
        await remoteA.pause();
        picture.emit(MediaEventKind.paused);
        expect(remoteA.thumbnailFor(peer), isNull);
        await remoteA.resume();
        expect(remoteA.thumbnailFor(peer), isNull);
        picture.emit(MediaEventKind.firstFrame);
        expect(remoteA.thumbnailFor(peer), same(picture));
        picture.stopGate = Completer<void>();
        final stopping = remoteA.stop();
        expect(remoteA.thumbnailFor(peer), isNull);
        picture.emit(MediaEventKind.firstFrame);
        expect(remoteA.thumbnailFor(peer), isNull);
        picture.stopGate!.complete();
        await stopping;
      },
    );
  }

  test('changing source and revoking a connection remove its thumbnail immediately', () async {
    build();
    final peer = a.sessions.single.peerKey;
    await remoteA.start(SessionOperation.cast, peerKey: peer);
    final picture = factoryA.current;
    picture.emit(MediaEventKind.firstFrame);
    await remoteA.loadSourceChoices();
    picture.changeGate = Completer<void>();
    final change = remoteA.changeSource(sourcesA.single);
    expect(remoteA.thumbnailFor(peer), isNull);
    picture.changeGate!.complete();
    await change;
    expect(remoteA.thumbnailFor(peer), isNull);
    picture.emit(MediaEventKind.firstFrame);
    expect(remoteA.thumbnailFor(peer), same(picture));
    a.sessions.single.grant!.revoke();
    expect(remoteA.thumbnailFor(peer), isNull);
    await remoteA.stop();
  });

  testWidgets(
    'hover and keyboard focus borrow a picture without creating media at 200 percent',
    (tester) async {
      build();
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final peer = a.sessions.single.peerKey;
      final entry = DirectoryDevice(
        identityId: peer,
        publicKey: peer,
        name: '正在分享的电脑',
        platform: 'macos',
        trust: DeviceTrust.verified,
        reachability: DeviceReachability.reachable,
        connected: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AnimatedBuilder(
                animation: remoteA,
                builder: (_, _) => DeviceField(
                  entries: [entry],
                  localName: '本机',
                  allowConnections: false,
                  onLocal: () {},
                  onDevice: (_) async {},
                  thumbnailBuilder: (_, device) =>
                      remoteA.thumbnailFor(device.publicKey!)?.thumbnailView,
                ),
              ),
            ),
          ),
        ),
      );
      final node = find.byKey(ValueKey('device-$peer'));
      await tester.ensureVisible(node);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(tester.getCenter(node));
      await tester.pump();
      expect(factoryA.link.starts, isEmpty);
      expect(sourceListCallsA, 0);
      expect(find.byKey(const ValueKey('borrowed-thumbnail')), findsNothing);
      await tester.runAsync(
        () => remoteA.start(SessionOperation.watch, peerKey: peer),
      );
      factoryA.current.emit(MediaEventKind.firstFrame);
      await tester.pump();
      expect(find.byKey(const ValueKey('borrowed-thumbnail')), findsOneWidget);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pump();
      expect(find.byKey(const ValueKey('borrowed-thumbnail')), findsNothing);
      tester.widget<OutlinedButton>(node).focusNode!.requestFocus();
      await tester.pump();
      expect(find.byKey(const ValueKey('borrowed-thumbnail')), findsOneWidget);
      expect(factoryA.link.starts, [SessionOperation.watch]);
      expect(sourceListCallsA, 0);
      await tester.runAsync(remoteA.stop);
      await tester.pump();
      expect(find.byKey(const ValueKey('borrowed-thumbnail')), findsNothing);
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await remoteA.shutdown();
        await remoteB.shutdown();
      });
    },
  );

  Matcher cleanupFailure() => throwsA(
    isA<SessionFailure>().having(
      (failure) => failure.code,
      'code',
      'media_cleanup_failed',
    ),
  );

  testWidgets(
    'incoming adoption notified into shutdown leaves no subscription or permission timer',
    (tester) async {
      build();
      final incoming = _FakePicture(
        id: 'incoming-shutdown-on-notify',
        operation: SessionOperation.watch,
        sends: true,
      )..stopGate = Completer<void>();
      final stream = _CancelOnceStream(incoming.events, failFirstCancel: false);
      incoming.eventStreamOverride = stream;
      Future<void>? shutting;
      var requested = false;
      void listener() {
        if (requested || !remoteB.occupied) return;
        requested = true;
        shutting = remoteB.shutdown();
      }

      remoteB.addListener(listener);
      factoryB.deliver(incoming);
      remoteB.removeListener(listener);
      expect(requested, isTrue);
      expect(stream.listeners, 1);
      expect(stream.cancellations, 1);
      expect(incoming.stops, 1);
      expect(remoteB.sending, isFalse);
      expect(factoryB.link.closeCalls, 1);
      incoming.emit(MediaEventKind.firstFrame);
      incoming.emit(MediaEventKind.statistics, bitsPerSecond: 2000);
      expect(remoteB.phase, isNot(RemotePhase.active));
      expect(remoteB.bitsPerSecond, isNull);
      var shutdownCompleted = false;
      unawaited(shutting!.then<void>((_) => shutdownCompleted = true));
      incoming.stopGate!.complete();
      // Cleanup crosses the real connection fixture's zone and the widget
      // test's fake clock. Let the real event loop progress before draining
      // fake microtasks; awaiting that future directly can deadlock the test.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(shutdownCompleted, isTrue);
      // Flutter's widget-test invariant also rejects any permission/deadline
      // timer created after the synchronous shutdown listener returned.
      await tester.pump(const Duration(milliseconds: 100));
      expect(stream.cancellations, 1);
      expect(incoming.stops, 1);
      expect(remoteB.occupied, isFalse);
      expect(remoteB.cleanupFailed, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'ordinary stop retries a rejected orphan and unblocks local preview',
    () async {
      build();
      previewActive = true;
      final orphan = _FakePicture(
        id: 'preview-busy-retained-orphan',
        operation: SessionOperation.cast,
        sends: false,
      )..failStop = true;
      factoryA.deliver(orphan);
      expect(remoteA.session, isNull);
      expect(remoteA.occupied, isTrue);
      await waitFor(() => remoteA.cleanupFailed);
      expect(orphan.stopReasons, [VideoEndReason.busy]);
      previewActive = false;
      final engine = FakePreviewEngine();
      final preview = PreviewController(
        platformA,
        engine,
        blockedByRemotePicture: () => remoteA.occupied,
      );
      try {
        await preview.start();
        expect(preview.error, contains('单画面预算'));
        expect(preview.active, isFalse);
        expect(engine.starts, 0);
        orphan.failStop = false;
        await remoteA.stop();
        expect(orphan.stops, 2);
        expect(orphan.stopped, isTrue);
        expect(remoteA.occupied, isFalse);
        expect(remoteA.cleanupFailed, isFalse);
        // Retrying cleanup is an ordinary stop, not permanent process shutdown.
        expect(remoteA.offeredOperations, {'watch', 'cast'});
        await preview.start();
        expect(engine.starts, 1);
        expect(preview.active, isTrue);
      } finally {
        await preview.stop();
        preview.dispose();
      }
    },
  );

  for (final shuttingDown in [false, true]) {
    test(
      'a synchronous listener reenters ${shuttingDown ? 'shutdown' : 'stop'} through the same pending future',
      () async {
        build();
        await remoteA.start(
          SessionOperation.watch,
          peerKey: a.sessions.single.peerKey,
        );
        final picture = factoryA.current;
        final link = factoryA.link;
        picture.emit(MediaEventKind.firstFrame);
        picture.stopGate = Completer<void>();
        if (shuttingDown) link.closeGate = Completer<void>();
        Future<void> release() =>
            shuttingDown ? remoteA.shutdown() : remoteA.stop();
        Future<void>? nested;
        var reentered = false;
        void listener() {
          if (reentered) return;
          reentered = true;
          nested = release();
        }

        remoteA.addListener(listener);
        final original = release();
        remoteA.removeListener(listener);
        expect(reentered, isTrue);
        expect(nested, same(original));
        await waitFor(() => picture.stops == 1);
        expect(link.closeCalls, shuttingDown ? 1 : 0);
        picture.stopGate!.complete();
        link.closeGate?.complete();
        await original;
        expect(picture.stops, 1);
        expect(remoteA.occupied, isFalse);
        expect(remoteA.cleanupFailed, isFalse);
      },
    );
  }

  test('shutdown inside the first start notification prevents late link creation and waits for that start', () async {
    build();
    final originalLink = factoryA.link;
    Future<void>? shutting;
    var requested = false;
    void listener() {
      if (requested || !remoteA.busy) return;
      requested = true;
      shutting = remoteA.shutdown();
    }

    remoteA.addListener(listener);
    final starting = remoteA.start(
      SessionOperation.watch,
      peerKey: a.sessions.single.peerKey,
    );
    remoteA.removeListener(listener);
    expect(requested, isTrue);
    expect(shutting, isNotNull);
    expect(factoryA.links, [same(originalLink)]);
    expect(originalLink.starts, isEmpty);
    var startCompleted = false;
    final startCompletion = starting.then((_) => startCompleted = true);
    await shutting!;
    expect(startCompleted, isTrue);
    await startCompletion;
    expect(factoryA.links, [same(originalLink)]);
    expect(originalLink.starts, isEmpty);
    expect(originalLink.closeCalls, 1);
    expect(factoryA.delivered, isEmpty);
    expect(remoteA.occupied, isFalse);
    expect(remoteA.busy, isFalse);
    expect(remoteA.offeredOperations, isEmpty);
  });

  test('subscription cancellation failure still stops the picture and stays retryable by shutdown', () async {
    build();
    final picture = _FakePicture(
      id: 'subscription-cleanup',
      operation: SessionOperation.cast,
      sends: false,
    );
    final stream = _CancelOnceStream(picture.events);
    picture.eventStreamOverride = stream;
    factoryA.deliver(picture);
    picture.emit(MediaEventKind.firstFrame);
    expect(remoteA.receiving, isTrue);
    await expectLater(remoteA.shutdown(), cleanupFailure());
    expect(stream.cancellations, 1);
    expect(picture.stops, 1);
    expect(picture.stopped, isTrue);
    expect(remoteA.receiving, isFalse);
    expect(remoteA.cleanupFailed, isTrue);
    expect(remoteA.occupied, isTrue);
    await remoteA.shutdown();
    expect(stream.cancellations, 2);
    expect(remoteA.cleanupFailed, isFalse);
    expect(remoteA.occupied, isFalse);
    expect(factoryA.link.closeCalls, 1);
  });

  test('shutdown gates display and admission synchronously and waits for both native owners', () async {
    build();
    final peer = a.sessions.single.peerKey;
    await remoteA.start(SessionOperation.watch, peerKey: peer);
    final picture = factoryA.current;
    final link = factoryA.link;
    picture.emit(MediaEventKind.transportReady);
    picture.emit(MediaEventKind.firstFrame);
    picture.emit(
      MediaEventKind.statistics,
      transportPath: MediaTransportPath.direct,
      roundTripTime: const Duration(milliseconds: 12),
      bitsPerSecond: 1000,
      frameWidth: 640,
      frameHeight: 360,
    );
    picture.stopGate = Completer<void>();
    link.closeGate = Completer<void>();
    final shutting = remoteA.shutdown();
    expect(remoteA.shutdown(), same(shutting));
    expect(remoteA.offeredOperations, isEmpty);
    expect(remoteA.operationsFor(peer), isEmpty);
    expect(remoteA.phase, isNot(RemotePhase.active));
    expect(remoteA.receiving, isFalse);
    expect(remoteA.transportReady, isFalse);
    expect(remoteA.transportPath, isNull);
    expect(remoteA.roundTripTime, isNull);
    expect(remoteA.bitsPerSecond, isNull);
    expect(remoteA.frameWidth, isNull);
    expect(remoteA.frameHeight, isNull);
    var completed = false;
    final completion = shutting.then((_) => completed = true);
    await waitFor(() => picture.stops == 1 && link.closeCalls == 1);
    await remoteA.start(SessionOperation.watch, peerKey: peer);
    expect(link.starts, [SessionOperation.watch]);
    picture.emit(MediaEventKind.firstFrame);
    picture.emit(MediaEventKind.statistics, bitsPerSecond: 9999);
    expect(remoteA.phase, isNot(RemotePhase.active));
    expect(remoteA.bitsPerSecond, isNull);
    expect(completed, isFalse);

    picture.stopGate!.complete();
    await waitFor(() => picture.stopped);
    expect(completed, isFalse, reason: 'The link still owns native cleanup.');
    link.closeGate!.complete();
    await completion;
    expect(remoteA.occupied, isFalse);
    expect(remoteA.cleanupFailed, isFalse);
    await remoteA.shutdown();
    await remoteA.start(SessionOperation.cast, peerKey: peer);
    expect(link.starts, [SessionOperation.watch]);
    expect(link.closeCalls, 1);
    expect(picture.stops, 1);
  });

  test(
    'shutdown joins an already pending stop instead of releasing twice',
    () async {
      build();
      await remoteA.start(
        SessionOperation.watch,
        peerKey: a.sessions.single.peerKey,
      );
      final picture = factoryA.current;
      picture.emit(MediaEventKind.firstFrame);
      picture.stopGate = Completer<void>();
      final stopping = remoteA.stop();
      await waitFor(() => picture.stops == 1);
      final shutting = remoteA.shutdown();
      expect(remoteA.shutdown(), same(shutting));
      var completed = false;
      final completion = shutting.then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(picture.stops, 1);
      picture.stopGate!.complete();
      await stopping;
      await completion;
      expect(picture.stops, 1);
      expect(factoryA.link.closeCalls, 1);
      expect(remoteA.occupied, isFalse);
    },
  );

  test(
    'shutdown waits for a pending start and its late picture cleanup',
    () async {
      build();
      final link = factoryA.link;
      link.gate = Completer<void>();
      link.pictureStopGate = Completer<void>();
      final starting = remoteA.start(
        SessionOperation.watch,
        peerKey: a.sessions.single.peerKey,
      );
      await waitFor(() => link.starts.isNotEmpty);
      final shutting = remoteA.shutdown();
      var completed = false;
      final completion = shutting.then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(link.closeCalls, 1);
      expect(factoryA.delivered, isEmpty);

      link.gate!.complete();
      await waitFor(() => link.picture != null && link.picture!.stops == 1);
      final late = link.picture!;
      late.emit(MediaEventKind.firstFrame);
      expect(remoteA.receiving, isFalse);
      expect(remoteA.phase, isNot(RemotePhase.active));
      expect(
        completed,
        isFalse,
        reason: 'The late native owner has not stopped.',
      );
      link.pictureStopGate!.complete();
      await starting;
      await completion;
      expect(late.stopped, isTrue);
      expect(late.stops, 1);
      expect(remoteA.occupied, isFalse);
      expect(remoteA.cleanupFailed, isFalse);
    },
  );

  test(
    'shutdown reports an owned cleanup failure and retries its retained owner',
    () async {
      build();
      await remoteA.start(
        SessionOperation.watch,
        peerKey: a.sessions.single.peerKey,
      );
      final picture = factoryA.current;
      picture.emit(MediaEventKind.firstFrame);
      picture.failStop = true;
      await expectLater(remoteA.shutdown(), cleanupFailure());
      expect(remoteA.cleanupFailed, isTrue);
      expect(remoteA.occupied, isTrue);
      expect(remoteA.receiving, isFalse);
      expect(picture.stops, 1);
      picture.failStop = false;
      await remoteA.shutdown();
      expect(picture.stops, 2);
      expect(remoteA.cleanupFailed, isFalse);
      expect(remoteA.occupied, isFalse);
      expect(remoteA.offeredOperations, isEmpty);
    },
  );

  test(
    'shutdown waits for a disconnected link already being retired',
    () async {
      build();
      final link = factoryA.link;
      link.closeGate = Completer<void>();
      await a.disconnectAll();
      await waitFor(() => link.closeCalls == 1);
      final shutting = remoteA.shutdown();
      var completed = false;
      final completion = shutting.then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(link.closeCalls, 1);
      link.closeGate!.complete();
      await completion;
      expect(link.closeCalls, 1);
      expect(remoteA.cleanupFailed, isFalse);
    },
  );

  test(
    'a retired link remains owned after failed close and shutdown can retry',
    () async {
      build();
      final link = factoryA.link;
      link.failClose = true;
      await a.disconnectAll();
      await waitFor(() => link.closeCalls == 1 && remoteA.cleanupFailed);
      await expectLater(remoteA.shutdown(), cleanupFailure());
      expect(link.closeCalls, 2);
      expect(remoteA.cleanupFailed, isTrue);
      link.failClose = false;
      await remoteA.shutdown();
      expect(link.closeCalls, 3);
      expect(remoteA.cleanupFailed, isFalse);
    },
  );

  for (final previewOccupied in [true, false]) {
    test(
      'shutdown retains a rejected ${previewOccupied ? 'preview-busy' : 'other-operation'} orphan when cleanup fails',
      () async {
        build();
        if (previewOccupied) {
          previewActive = true;
        } else {
          await remoteA.start(
            SessionOperation.watch,
            peerKey: a.sessions.single.peerKey,
          );
          factoryA.current.emit(MediaEventKind.firstFrame);
        }
        final owned = remoteA.session;
        final orphan = _FakePicture(
          id: 'rejected-orphan',
          operation: SessionOperation.cast,
          sends: false,
        )..failStop = true;
        factoryA.deliver(orphan);
        await waitFor(() => orphan.stops == 1 && remoteA.cleanupFailed);
        expect(orphan.stopReasons, [VideoEndReason.busy]);
        expect(remoteA.session, same(owned));
        await expectLater(remoteA.shutdown(), cleanupFailure());
        expect(orphan.stops, 2);
        expect(remoteA.cleanupFailed, isTrue);
        orphan.failStop = false;
        await remoteA.shutdown();
        expect(orphan.stops, 3);
        expect(orphan.stopped, isTrue);
        expect(remoteA.occupied, isFalse);
        expect(remoteA.cleanupFailed, isFalse);
      },
    );
  }

  test(
    'shutdown owns a late rejected adoption and preserves its failed cleanup',
    () async {
      build();
      final link = factoryA.link;
      link.closeGate = Completer<void>();
      final shutting = remoteA.shutdown();
      final rejected = expectLater(shutting, cleanupFailure());
      final orphan = _FakePicture(
        id: 'late-during-shutdown',
        operation: SessionOperation.cast,
        sends: false,
      )..failStop = true;
      factoryA.deliver(orphan, via: link);
      await waitFor(() => orphan.stops == 1 && remoteA.cleanupFailed);
      expect(remoteA.session, isNull);
      expect(remoteA.receiving, isFalse);
      orphan.emit(MediaEventKind.firstFrame);
      expect(remoteA.phase, isNot(RemotePhase.active));
      link.closeGate!.complete();
      await rejected;
      expect(remoteA.cleanupFailed, isTrue);
      orphan.failStop = false;
      await remoteA.shutdown();
      expect(orphan.stops, 2);
      expect(orphan.stopped, isTrue);
      expect(remoteA.cleanupFailed, isFalse);
    },
  );

  test('shutdown permanently blocks new source and playback work', () async {
    build();
    final peer = a.sessions.single.peerKey;
    await remoteA.start(SessionOperation.cast, peerKey: peer);
    final picture = factoryA.current;
    picture.emit(MediaEventKind.firstFrame);
    await remoteA.loadSourceChoices();
    expect(remoteA.sourceChoices, isNotEmpty);
    final lists = sourceListCallsA;
    picture.stopGate = Completer<void>();
    final shutting = remoteA.shutdown();
    expect(remoteA.canChangeSource, isFalse);
    expect(remoteA.sourceChoices, isEmpty);
    await remoteA.loadSourceChoices();
    await remoteA.changeSource(sourcesA.single);
    await remoteA.pause();
    await remoteA.resume();
    await remoteA.start(SessionOperation.cast, peerKey: peer);
    expect(sourceListCallsA, lists);
    expect(picture.changes, isEmpty);
    expect(picture.resumes, 0);
    expect(factoryA.link.starts, [SessionOperation.cast]);
    picture.stopGate!.complete();
    await shutting;
    await remoteA.loadSourceChoices();
    await remoteA.changeSource(sourcesA.single);
    await remoteA.start(SessionOperation.cast, peerKey: peer);
    expect(sourceListCallsA, lists);
    expect(picture.changes, isEmpty);
    expect(factoryA.link.starts, [SessionOperation.cast]);
  });

  for (final resuming in [false, true]) {
    test(
      'late ${resuming ? 'resume' : 'pause'} failure cannot alter the next picture',
      () async {
        build();
        final peer = a.sessions.single.peerKey;
        await remoteA.start(SessionOperation.watch, peerKey: peer);
        final previous = factoryA.current;
        previous.emit(MediaEventKind.firstFrame);
        if (resuming) previous.emit(MediaEventKind.paused);
        previous.playbackGate = Completer<void>();
        previous.failPlayback = true;
        final pending = resuming ? remoteA.resume() : remoteA.pause();
        await remoteA.stop();
        await remoteA.start(SessionOperation.watch, peerKey: peer);
        final current = factoryA.current;
        current.emit(MediaEventKind.firstFrame);
        current.emit(MediaEventKind.statistics, bitsPerSecond: 1234);
        previous.playbackGate!.complete();
        await pending;
        expect(remoteA.session, same(current));
        expect(remoteA.phase, RemotePhase.active);
        expect(remoteA.error, isNull);
        expect(remoteA.bitsPerSecond, 1234);
        expect(current.stops, 0);
      },
    );
  }

  test('peer evidence is separate, role bound, expires and cannot establish first frame', () async {
    build(statisticsLifetime: const Duration(milliseconds: 30));
    await remoteA.start(
      SessionOperation.cast,
      peerKey: a.sessions.single.peerKey,
    );
    final picture = factoryA.current;
    picture.emit(MediaEventKind.waitingFirstFrame);
    picture.emit(
      MediaEventKind.peerFrameProgress,
      frameProgress: receiverProgress(),
    );
    expect(remoteA.peerFrameProgress!.sequence, 2);
    expect(remoteA.frameProgress, isNull);
    expect(remoteA.phase, RemotePhase.waitingFirstFrame);
    picture.emit(
      MediaEventKind.peerFrameProgress,
      revision: 1,
      frameProgress: const MediaFrameProgress.unknown(MediaFrameStage.receiver),
    );
    expect(remoteA.peerFrameProgress!.sequence, 2);
    picture.emit(
      MediaEventKind.peerFrameProgress,
      frameProgress: const MediaFrameProgress.unknown(MediaFrameStage.capture),
    );
    expect(remoteA.peerFrameProgress!.sequence, 2);
    await waitFor(() => remoteA.peerFrameProgress == null);
    picture.emit(
      MediaEventKind.peerFrameProgress,
      frameProgress: receiverProgress(),
    );
    remoteA.clearFrameProgress();
    expect(remoteA.peerFrameProgress, isNull);
    picture.emit(MediaEventKind.failed, failureCode: 'media_frames_stalled');
    expect(remoteA.error, contains('未恢复解码'));
    await remoteA.stop();
    expect(remoteA.peerFrameProgress, isNull);
  });

  test('frame evidence cannot establish first frame and expires independently of statistics', () async {
    build(statisticsLifetime: const Duration(milliseconds: 30));
    await remoteA.start(
      SessionOperation.watch,
      peerKey: a.sessions.single.peerKey,
    );
    final picture = factoryA.current;
    picture.emit(MediaEventKind.waitingFirstFrame);
    picture.emit(
      MediaEventKind.frameProgress,
      frameProgress: receiverProgress(),
    );
    expect(remoteA.frameProgress!.sequence, 2);
    expect(remoteA.phase, RemotePhase.waitingFirstFrame);
    picture.emit(MediaEventKind.statistics, bitsPerSecond: 1000);
    expect(remoteA.frameProgress!.sequence, 2);
    expect(remoteA.bitsPerSecond, 1000);
    await waitFor(() => remoteA.frameProgress == null);
    expect(picture.stops, 0);
  });

  test(
    'pause, future and old revisions cannot refresh frame evidence',
    () async {
      build();
      await remoteA.start(
        SessionOperation.watch,
        peerKey: a.sessions.single.peerKey,
      );
      final picture = factoryA.current;
      picture.emit(MediaEventKind.firstFrame);
      picture.emit(
        MediaEventKind.frameProgress,
        frameProgress: receiverProgress(),
      );
      picture.emit(MediaEventKind.paused);
      expect(remoteA.frameProgress, isNull);
      picture.emit(
        MediaEventKind.frameProgress,
        frameProgress: receiverProgress(),
      );
      expect(remoteA.frameProgress, isNull);
      await remoteA.resume();
      for (final revision in [0, 2]) {
        picture.emit(
          MediaEventKind.frameProgress,
          revision: revision,
          frameProgress: receiverProgress(),
        );
        expect(remoteA.frameProgress, isNull);
      }
      picture.emit(
        MediaEventKind.frameProgress,
        revision: 1,
        frameProgress: receiverProgress(),
      );
      expect(remoteA.frameProgress!.sequence, 2);
      expect(remoteA.phase, RemotePhase.waitingFirstFrame);
      await remoteA.stop();
      expect(remoteA.frameProgress, isNull);
    },
  );

  testWidgets(
    'frame wording distinguishes decoding from display and clears on window resume',
    (tester) async {
      build();
      await tester.runAsync(
        () => remoteA.start(
          SessionOperation.watch,
          peerKey: a.sessions.single.peerKey,
        ),
      );
      final picture = factoryA.current;
      await tester.pumpWidget(
        MaterialApp(
          home: AnimatedBuilder(
            animation: remoteA,
            builder: (_, _) => RemotePicturePanel(controller: remoteA),
          ),
        ),
      );
      picture.emit(MediaEventKind.firstFrame);
      picture.emit(
        MediaEventKind.frameProgress,
        frameProgress: receiverProgress(),
      );
      await tester.pump();
      expect(find.text('接收端最近已解码，尚未消费最新画面。'), findsOneWidget);
      picture.emit(
        MediaEventKind.peerFrameProgress,
        frameProgress: MediaFrameProgress(
          stage: MediaFrameStage.capture,
          active: true,
          sequence: 1,
          age: const Duration(seconds: 30),
          outputSequence: 2,
          outputAge: const Duration(seconds: 20),
          sourceUnchanged: true,
        ),
      );
      await tester.pump();
      expect(find.text('对端来源曾未变化，当前状态待确认。'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(remoteA.frameProgress, isNull);
      expect(find.text('本机接收帧状态：未测。'), findsOneWidget);
      expect(remoteA.peerFrameProgress, isNull);
      expect(find.text('对端帧状态：未测。'), findsOneWidget);
      expect(picture.stops, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'statistics do not establish presentation and missing values clear',
    () async {
      build();
      await remoteA.start(
        SessionOperation.watch,
        peerKey: a.sessions.single.peerKey,
      );
      final picture = factoryA.current;
      picture.emit(MediaEventKind.waitingFirstFrame);
      picture.emit(
        MediaEventKind.statistics,
        transportPath: MediaTransportPath.relay,
        roundTripTime: const Duration(milliseconds: 24),
        bitsPerSecond: 800000,
      );
      expect(remoteA.transportPath, MediaTransportPath.relay);
      expect(remoteA.roundTripTime, const Duration(milliseconds: 24));
      expect(remoteA.bitsPerSecond, 800000);
      expect(remoteA.transportReady, isFalse);
      expect(remoteA.phase, RemotePhase.waitingFirstFrame);
      picture.emit(MediaEventKind.statistics);
      expect(remoteA.transportPath, isNull);
      expect(remoteA.roundTripTime, isNull);
      expect(remoteA.bitsPerSecond, isNull);
      expect(remoteA.phase, RemotePhase.waitingFirstFrame);
    },
  );

  test(
    'expired statistics become unmeasured without ending a picture',
    () async {
      build(statisticsLifetime: const Duration(milliseconds: 30));
      await remoteA.start(
        SessionOperation.watch,
        peerKey: a.sessions.single.peerKey,
      );
      final picture = factoryA.current;
      picture.emit(MediaEventKind.firstFrame);
      picture.emit(
        MediaEventKind.statistics,
        transportPath: MediaTransportPath.direct,
        bitsPerSecond: 0,
      );
      expect(
        remoteA.bitsPerSecond,
        0,
      ); // Measured idle traffic, not a missing value.
      await waitFor(() => remoteA.bitsPerSecond == null);
      expect(remoteA.transportPath, isNull);
      expect(remoteA.phase, RemotePhase.active);
      expect(picture.stops, 0);
    },
  );

  test(
    'pause and revision changes clear statistics and reject stale samples',
    () async {
      build();
      await remoteA.start(
        SessionOperation.watch,
        peerKey: a.sessions.single.peerKey,
      );
      final picture = factoryA.current;
      picture.emit(MediaEventKind.firstFrame);
      picture.emit(
        MediaEventKind.statistics,
        transportPath: MediaTransportPath.relay,
        bitsPerSecond: 1000,
      );
      picture.emit(MediaEventKind.paused);
      expect(remoteA.bitsPerSecond, isNull);
      picture.emit(MediaEventKind.statistics, bitsPerSecond: 2000);
      expect(remoteA.bitsPerSecond, isNull);
      await remoteA.resume();
      picture.emit(MediaEventKind.statistics, revision: 0, bitsPerSecond: 3000);
      picture.emit(MediaEventKind.statistics, revision: 2, bitsPerSecond: 4000);
      expect(remoteA.bitsPerSecond, isNull);
      picture.emit(MediaEventKind.statistics, revision: 1, bitsPerSecond: 5000);
      expect(remoteA.bitsPerSecond, 5000);
      expect(remoteA.phase, RemotePhase.waitingFirstFrame);
      picture.emit(MediaEventKind.waitingFirstFrame, revision: 2);
      expect(remoteA.bitsPerSecond, isNull);
    },
  );

  test('failed cleanup cannot retain or revive statistics', () async {
    build();
    await remoteA.start(
      SessionOperation.watch,
      peerKey: a.sessions.single.peerKey,
    );
    final picture = factoryA.current;
    picture.emit(MediaEventKind.firstFrame);
    picture.emit(MediaEventKind.statistics, bitsPerSecond: 1000);
    picture.failStop = true;
    await remoteA.stop();
    expect(remoteA.cleanupFailed, isTrue);
    expect(remoteA.bitsPerSecond, isNull);
    picture.emit(MediaEventKind.statistics, bitsPerSecond: 2000);
    expect(remoteA.bitsPerSecond, isNull);
    picture.failStop = false;
    await remoteA.stop();
  });

  test(
    'an unconnected peer is refused before the code flow, with no capture',
    () async {
      build();
      await remoteA.start(SessionOperation.watch, peerKey: 'stranger');
      expect(remoteA.error, contains('短接码'));
      expect(remoteA.occupied, isFalse);
      expect(factoryA.links.single.starts, isEmpty);
      expect(platformA.permissionRequests, 0);
    },
  );

  test('a watch is authorized forward and refused in reverse', () async {
    build();
    await remoteA.start(
      SessionOperation.watch,
      peerKey: a.sessions.single.peerKey,
    );
    expect(factoryA.links.single.starts, [SessionOperation.watch]);
    expect(factoryA.delivered, hasLength(1));
    expect(remoteA.error, isNull);
    // B holds the receiving role of this connection, so it may not initiate.
    await remoteB.start(
      SessionOperation.watch,
      peerKey: b.sessions.single.peerKey,
    );
    expect(remoteB.error, '当前连接方向不允许该操作，请输入对方的短接码建立反向连接。');
    expect(remoteA.operationsFor(a.sessions.single.peerKey), {'watch', 'cast'});
    expect(remoteB.operationsFor(b.sessions.single.peerKey), isEmpty);
    expect(factoryB.delivered, isEmpty);
    expect(remoteB.occupied, isFalse);
  });

  test(
    'a missing capture permission fails the cast instead of faking it',
    () async {
      platformA.status = const PermissionStatus();
      platformA.grantPermission = false;
      build();
      await remoteA.start(
        SessionOperation.cast,
        peerKey: a.sessions.single.peerKey,
      );
      expect(remoteA.error, '屏幕录制权限不可用，请在系统设置中允许 Share Hub 后重试。');
      expect(remoteA.phase, RemotePhase.failed);
      expect(factoryA.delivered, isEmpty);
      expect(remoteA.occupied, isFalse);
    },
  );

  test(
    'an unidentifiable primary screen never falls back to another source',
    () async {
      sourcesA = const [
        CaptureSource('screen:1', '显示器 A'),
        CaptureSource('screen:2', '显示器 B', isPrimary: true),
        CaptureSource('screen:3', '显示器 C', isPrimary: true),
      ];
      build();
      await remoteA.start(
        SessionOperation.cast,
        peerKey: a.sessions.single.peerKey,
      );
      expect(remoteA.error, contains('不会自动切换到其他来源'));
      expect(remoteA.phase, RemotePhase.failed);
    },
  );

  test(
    'a locally started capture is never reported as the peer presenting',
    () async {
      build();
      await remoteA.start(
        SessionOperation.cast,
        peerKey: a.sessions.single.peerKey,
      );
      final picture = factoryA.current;
      picture.emit(MediaEventKind.connecting);
      picture.emit(MediaEventKind.transportReady);
      expect(remoteA.phase, RemotePhase.connecting);
      expect(remoteA.transportReady, isTrue);
      expect(remoteA.sending, isTrue);
      picture.emit(MediaEventKind.waitingFirstFrame);
      expect(remoteA.phase, RemotePhase.waitingFirstFrame);
      // No presentation receipt arrives, so the bounded policy ends the session
      // even while transport statistics continue arriving.
      final samples = Timer.periodic(const Duration(milliseconds: 20), (_) {
        picture.emit(MediaEventKind.statistics, bitsPerSecond: 4000);
      });
      try {
        await waitFor(() => !remoteA.occupied);
      } finally {
        samples.cancel();
      }
      expect(remoteA.phase, RemotePhase.failed);
      expect(remoteA.error, contains('未呈现共享画面'));
      expect(picture.stops, greaterThanOrEqualTo(1));
    },
  );

  test(
    'the peer presenting the frame is what makes the share active',
    () async {
      build();
      await remoteA.start(
        SessionOperation.cast,
        peerKey: a.sessions.single.peerKey,
      );
      final picture = factoryA.current;
      picture.emit(MediaEventKind.waitingFirstFrame);
      picture.emit(MediaEventKind.firstFrame);
      expect(remoteA.phase, RemotePhase.active);
      await remoteA.pause();
      picture.emit(MediaEventKind.paused);
      expect(remoteA.phase, RemotePhase.paused);
      await remoteA.resume();
      expect(picture.resumes, 1);
      await remoteA.stop(reason: '手动停止');
      expect(picture.stops, 1);
      expect(remoteA.occupied, isFalse);
      expect(remoteA.phase, RemotePhase.idle);
    },
  );

  test(
    'cancelling mid-start stops the late session and isolates its callbacks',
    () async {
      build();
      final link = factoryA.link;
      link.gate = Completer<void>();
      final starting = remoteA.start(
        SessionOperation.cast,
        peerKey: a.sessions.single.peerKey,
      );
      await waitFor(() => remoteA.busy);
      await remoteA.cancel();
      link.gate!.complete();
      await starting;
      final picture = factoryA.current;
      await waitFor(() => picture.stops >= 1);
      expect(remoteA.occupied, isFalse);
      // A late callback of the cancelled operation cannot revive the field.
      picture.emit(MediaEventKind.firstFrame);
      picture.emit(MediaEventKind.failed, failureCode: 'media_transport_lost');
      expect(remoteA.phase, RemotePhase.idle);
      expect(remoteA.sending, isFalse);
    },
  );

  test(
    'a second operation is refused while the picture budget is spent',
    () async {
      build();
      await remoteA.start(
        SessionOperation.cast,
        peerKey: a.sessions.single.peerKey,
      );
      factoryA.current.emit(MediaEventKind.firstFrame);
      await remoteA.start(
        SessionOperation.watch,
        peerKey: a.sessions.single.peerKey,
      );
      expect(remoteA.error, contains('单画面预算'));
      expect(factoryA.links.single.starts, [SessionOperation.cast]);
    },
  );

  test('losing the connection stops and releases the picture', () async {
    build();
    await remoteA.start(
      SessionOperation.cast,
      peerKey: a.sessions.single.peerKey,
    );
    final picture = factoryA.current;
    picture.emit(MediaEventKind.firstFrame);
    expect(remoteA.phase, RemotePhase.active);
    await a.disconnectAll();
    await waitFor(() => !remoteA.occupied);
    expect(remoteA.phase, RemotePhase.failed);
    expect(remoteA.error, contains('连接已断开'));
    expect(picture.stops, greaterThanOrEqualTo(1));
    await waitFor(() => factoryA.links.single.closed);
  });

  test('revoking the capture permission stops the share', () async {
    build();
    await remoteA.start(
      SessionOperation.cast,
      peerKey: a.sessions.single.peerKey,
    );
    factoryA.current.emit(MediaEventKind.firstFrame);
    expect(remoteA.phase, RemotePhase.active);
    platformA.status = const PermissionStatus();
    await waitFor(() => !remoteA.occupied);
    expect(remoteA.error, contains('屏幕录制权限已关闭'));
    expect(remoteA.phase, RemotePhase.failed);
  });

  test('a failed release stays visible and can be retried', () async {
    build();
    await remoteA.start(
      SessionOperation.cast,
      peerKey: a.sessions.single.peerKey,
    );
    final picture = factoryA.current;
    picture.emit(MediaEventKind.firstFrame);
    picture.failStop = true;
    await remoteA.stop(reason: '停止');
    expect(remoteA.cleanupFailed, isTrue);
    expect(remoteA.occupied, isTrue);
    expect(remoteA.phase, RemotePhase.failed);
    expect(remoteA.error, contains('释放失败'));
    picture.failStop = false;
    await remoteA.stop();
    expect(remoteA.cleanupFailed, isFalse);
    expect(remoteA.occupied, isFalse);
  });

  test('failed startup retains its owner when cleanup also fails', () async {
    build();
    factoryA.link
      ..failStartAfterAdoption = true
      ..failStop = true;
    await remoteA.start(
      SessionOperation.watch,
      peerKey: a.sessions.single.peerKey,
    );
    final picture = factoryA.current;
    expect(remoteA.session, same(picture));
    expect(remoteA.occupied, isTrue);
    expect(remoteA.cleanupFailed, isTrue);
    expect(remoteA.busy, isFalse);
    expect(remoteA.phase, RemotePhase.failed);
    expect(remoteA.error, contains('释放失败'));
    expect(picture.stops, 1);
    await remoteA.start(
      SessionOperation.cast,
      peerKey: a.sessions.single.peerKey,
    );
    expect(factoryA.link.starts, [SessionOperation.watch]);
    picture.failStop = false;
    await remoteA.stop();
    expect(picture.stops, 2);
    expect(remoteA.occupied, isFalse);
    expect(remoteA.cleanupFailed, isFalse);
  });

  for (final failAfterAdoption in [false, true]) {
    test(
      'cancelled startup retains a late owner when admission ${failAfterAdoption ? 'throws' : 'returns'} and cleanup fails',
      () async {
        build();
        final link = factoryA.link
          ..gate = Completer<void>()
          ..failStop = true
          ..failStartAfterAdoption = failAfterAdoption;
        final starting = remoteA.start(
          SessionOperation.watch,
          peerKey: a.sessions.single.peerKey,
        );
        await waitFor(() => remoteA.busy);
        await remoteA.cancel();
        link.gate!.complete();
        await starting;
        final picture = factoryA.current;
        expect(remoteA.session, same(picture));
        expect(remoteA.cleanupFailed, isTrue);
        expect(remoteA.occupied, isTrue);
        picture.emit(MediaEventKind.firstFrame);
        expect(remoteA.phase, RemotePhase.failed);
        expect(remoteA.transportReady, isFalse);
        picture.failStop = false;
        await remoteA.stop();
        expect(remoteA.cleanupFailed, isFalse);
        expect(remoteA.occupied, isFalse);
      },
    );
  }

  test(
    'the peer ending the operation is reported as the peer ending it',
    () async {
      build();
      await remoteA.start(
        SessionOperation.watch,
        peerKey: a.sessions.single.peerKey,
      );
      final picture = factoryA.current;
      picture.emit(MediaEventKind.firstFrame);
      expect(remoteA.receiving, isTrue);
      picture.endedBy = VideoEndReason.unavailable;
      picture.emit(MediaEventKind.ended);
      expect(remoteA.phase, RemotePhase.failed);
      expect(remoteA.error, '对端未提供该远端操作能力，未创建画面会话。');
      await waitFor(() => !remoteA.occupied);
    },
  );

  test('the local preview and the remote picture exclude each other', () async {
    previewActive = true;
    build();
    await remoteA.start(
      SessionOperation.cast,
      peerKey: a.sessions.single.peerKey,
    );
    expect(remoteA.error, contains('本机预览正在进行'));
    expect(factoryA.links.single.starts, isEmpty);
    previewActive = false;
    sourceListGate = null;
    await remoteA.start(
      SessionOperation.cast,
      peerKey: a.sessions.single.peerKey,
    );
    factoryA.current.emit(MediaEventKind.firstFrame);
    expect(remoteA.phase, RemotePhase.active);
    // The preview controller consults the same predicate in the real app.
    final engine = FakePreviewEngine();
    final preview = PreviewController(
      platformA,
      engine,
      blockedByRemotePicture: () => remoteA.occupied,
    );
    await preview.start();
    expect(preview.error, contains('单画面预算'));
    expect(preview.active, isFalse);
    expect(engine.starts, 0);
    preview.dispose();
  });

  test('a peer-initiated operation becomes visible and stoppable', () async {
    build();
    final incoming = _FakePicture(
      id: 'peer-watch',
      operation: SessionOperation.watch,
      sends: false,
    );
    factoryA.deliver(incoming);
    await waitFor(() => remoteA.occupied);
    expect(remoteA.phase, RemotePhase.connecting);
    expect(remoteA.sending, isFalse);
    expect(remoteA.receiving, isTrue);
    incoming.emit(MediaEventKind.firstFrame);
    expect(remoteA.phase, RemotePhase.active);
    await remoteA.stop(reason: '本地停止');
    expect(incoming.stops, 1);
    expect(remoteA.occupied, isFalse);
  });

  for (final operation in [SessionOperation.watch, SessionOperation.cast]) {
    for (final active in [false, true]) {
      test(
        'incoming $operation is gated while local preview is ${active ? 'active' : 'starting'}',
        () async {
          final engine = FakePreviewEngine()
            ..startCompleter = Completer<void>();
          final preview = PreviewController(platformA, engine);
          final starting = preview.start();
          await waitFor(() => engine.starts == 1);
          if (active) {
            engine.startCompleter!.complete();
            await starting;
            expect(preview.active, isTrue);
          } else {
            expect(preview.busy, isTrue);
            expect(preview.active, isFalse);
          }
          build(
            localCaptureOccupied: () =>
                preview.busy ||
                preview.active ||
                preview.stopping ||
                preview.cleanupFailed,
          );
          final incoming = _FakePicture(
            id: 'inbound-$operation',
            operation: operation,
            sends: operation == SessionOperation.watch,
          );
          factoryB.deliver(incoming);
          // No event-loop turn: the SDK's subsequent source resolution/start must
          // already see stopped and refuse all native allocation.
          expect(incoming.stopped, isTrue);
          expect(incoming.stops, 1);
          expect(incoming.stopReasons, [VideoEndReason.busy]);
          // Synchronous stop gates capture, but its completion must still be
          // observed before the retained cleanup owner releases the budget.
          expect(remoteB.occupied, isTrue);
          await waitFor(() => !remoteB.occupied);
          expect(remoteB.session, isNull);
          expect(engine.stops, 0);
          if (!active) engine.startCompleter!.complete();
          await starting;
          await preview.stop();
          preview.dispose();
        },
      );
    }
  }

  test(
    'sender selects exact source and requires a fresh revision presentation',
    () async {
      build();
      await remoteA.start(
        SessionOperation.cast,
        peerKey: a.sessions.single.peerKey,
      );
      final picture = factoryA.current;
      picture.emit(MediaEventKind.firstFrame);
      const window = CaptureSource(
        'window:42',
        '工作窗口',
        type: CaptureSourceType.window,
      );
      sourcesA = [...sourcesA, window];
      await remoteA.loadSourceChoices();
      expect(remoteA.sourceChoices, contains(window));
      picture.emit(
        MediaEventKind.statistics,
        transportPath: MediaTransportPath.relay,
        bitsPerSecond: 1000,
      );
      await remoteA.changeSource(window);
      expect(remoteA.bitsPerSecond, isNull);
      expect(remoteA.transportPath, isNull);
      picture.emit(MediaEventKind.statistics, revision: 0, bitsPerSecond: 2000);
      expect(remoteA.bitsPerSecond, isNull);
      expect(picture.changes, [window]);
      expect(remoteA.localSource, window);
      expect(remoteA.phase, RemotePhase.waitingFirstFrame);
      picture.emit(MediaEventKind.firstFrame, revision: 0);
      expect(remoteA.phase, RemotePhase.waitingFirstFrame);
      picture.emit(MediaEventKind.firstFrame);
      expect(remoteA.phase, RemotePhase.active);
      expect(a.sessions, hasLength(1));
      await remoteA.stop();
      expect(remoteA.sourceChoices, isEmpty);
    },
  );

  test(
    'source disappearing from picker never starts a fallback capture',
    () async {
      build();
      await remoteA.start(
        SessionOperation.cast,
        peerKey: a.sessions.single.peerKey,
      );
      final picture = factoryA.current;
      picture.emit(MediaEventKind.firstFrame);
      await remoteA.changeSource(const CaptureSource('missing', '已关闭窗口'));
      expect(picture.changes, isEmpty);
      expect(remoteA.sourceError, contains('未切换'));
      expect(remoteA.phase, RemotePhase.active);
      expect(remoteA.occupied, isTrue);
    },
  );

  test(
    'receiver has no source selection and cannot change peer capture',
    () async {
      build();
      await remoteA.start(
        SessionOperation.watch,
        peerKey: a.sessions.single.peerKey,
      );
      factoryA.current.emit(MediaEventKind.firstFrame);
      expect(remoteA.supportsSourceSelection, isFalse);
      await remoteA.loadSourceChoices();
      await remoteA.changeSource(sourcesA.single);
      expect(remoteA.sourceChoices, isEmpty);
      expect(factoryA.current.changes, isEmpty);
    },
  );

  test(
    'source change cancellation and failure never revive a stopped operation',
    () async {
      build();
      await remoteA.start(
        SessionOperation.cast,
        peerKey: a.sessions.single.peerKey,
      );
      final picture = factoryA.current;
      picture.emit(MediaEventKind.firstFrame);
      picture.changeGate = Completer<void>();
      final changing = remoteA.changeSource(sourcesA.single);
      await waitFor(() => picture.changes.isNotEmpty);
      await remoteA.stop();
      picture.changeGate!.complete();
      await changing;
      expect(remoteA.occupied, isFalse);
      expect(remoteA.phase, RemotePhase.idle);
      expect(remoteA.localSource, isNull);
    },
  );

  test(
    'changing source without a new first frame expires the old success state',
    () async {
      build();
      await remoteA.start(
        SessionOperation.cast,
        peerKey: a.sessions.single.peerKey,
      );
      factoryA.current.emit(MediaEventKind.firstFrame);
      await remoteA.changeSource(sourcesA.single);
      await waitFor(() => !remoteA.occupied);
      expect(remoteA.phase, RemotePhase.failed);
      expect(remoteA.error, contains('未呈现'));
    },
  );

  test(
    'native source switch failure stops and shows failure without fallback',
    () async {
      build();
      await remoteA.start(
        SessionOperation.cast,
        peerKey: a.sessions.single.peerKey,
      );
      factoryA.current.emit(MediaEventKind.firstFrame);
      factoryA.current.failChange = true;
      await remoteA.changeSource(sourcesA.single);
      expect(remoteA.occupied, isFalse);
      expect(remoteA.phase, RemotePhase.failed);
      expect(remoteA.error, contains('未切换'));
    },
  );

  test('resume also requires a new presentation instead of keeping the old first frame', () async {
    build();
    await remoteA.start(
      SessionOperation.cast,
      peerKey: a.sessions.single.peerKey,
    );
    final picture = factoryA.current;
    picture.emit(MediaEventKind.firstFrame);
    picture.emit(MediaEventKind.paused);
    await remoteA.resume();
    picture.emit(MediaEventKind.firstFrame, revision: 0);
    expect(remoteA.phase, RemotePhase.waitingFirstFrame);
    await waitFor(() => !remoteA.occupied);
    expect(remoteA.error, contains('未呈现'));
  });

  test('the watched endpoint may select its own source', () async {
    build();
    final incoming = _FakePicture(
      id: 'peer-watch',
      operation: SessionOperation.watch,
      sends: true,
    );
    factoryB.deliver(incoming);
    incoming.emit(MediaEventKind.firstFrame);
    expect(remoteB.canChangeSource, isTrue);
    await remoteB.changeSource(sourcesA.single);
    expect(incoming.changes, [sourcesA.single]);
    expect(remoteB.phase, RemotePhase.waitingFirstFrame);
  });

  testWidgets('sender source selector stays reachable at 200 percent text', (
    tester,
  ) async {
    build();
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.runAsync(
      () => remoteA.start(
        SessionOperation.cast,
        peerKey: a.sessions.single.peerKey,
      ),
    );
    factoryA.current.emit(MediaEventKind.firstFrame);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AnimatedBuilder(
              animation: remoteA,
              builder: (_, _) => RemotePicturePanel(controller: remoteA),
            ),
          ),
        ),
      ),
    );
    expect(find.text('更换分享来源'), findsOneWidget);
    expect(remoteA.sourceChoices, isEmpty);
    await tester.runAsync(() => remoteA.loadSourceChoices());
    await tester.pump();
    expect(find.text('选择本机显示器或窗口并分享'), findsOneWidget);
    await tester.ensureVisible(find.text('停止并释放'));
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => remoteA.stop());
    await tester.pumpWidget(const SizedBox());
  });

  test('source work belongs to its attempt and late completion cannot clear new work', () async {
    build();
    await remoteA.start(
      SessionOperation.cast,
      peerKey: a.sessions.single.peerKey,
    );
    factoryA.current.emit(MediaEventKind.firstFrame);
    final oldGate = sourceListGate = Completer<List<CaptureSource>>();
    final oldLoad = remoteA.loadSourceChoices();
    expect(remoteA.sourceBusy, isTrue);
    await remoteA.stop();
    sourceListGate = null;
    await remoteA.start(
      SessionOperation.cast,
      peerKey: a.sessions.single.peerKey,
    );
    factoryA.current.emit(MediaEventKind.firstFrame);
    expect(remoteA.sourceBusy, isFalse);
    expect(remoteA.canChangeSource, isTrue);
    final newGate = sourceListGate = Completer<List<CaptureSource>>();
    final newLoad = remoteA.loadSourceChoices();
    oldGate.complete(const [CaptureSource('old', '旧来源')]);
    await oldLoad;
    expect(remoteA.sourceBusy, isTrue);
    expect(remoteA.sourceChoices, isEmpty);
    newGate.complete(sourcesA);
    await newLoad;
    expect(remoteA.sourceBusy, isFalse);
    expect(remoteA.sourceChoices, sourcesA);
  });

  test(
    'a current revision failure stays visible after source change',
    () async {
      build();
      await remoteA.start(
        SessionOperation.cast,
        peerKey: a.sessions.single.peerKey,
      );
      final picture = factoryA.current;
      picture.emit(MediaEventKind.firstFrame);
      await remoteA.changeSource(sourcesA.single);
      picture.emit(MediaEventKind.firstFrame);
      picture.emit(
        MediaEventKind.failed,
        failureCode: 'source_ended',
        revision: 0,
      );
      expect(remoteA.phase, RemotePhase.active);
      picture.emit(MediaEventKind.failed, failureCode: 'source_ended');
      expect(remoteA.phase, RemotePhase.failed);
      expect(remoteA.error, contains('来源已结束'));
    },
  );

  Future<void> connectReverse() async {
    await a.open();
    final port = int.parse(a.address!.split(':').last);
    final connected = await b.connect(
      '127.0.0.1',
      port,
      a.code!,
      expectedPeerKey: b.sessions.first.peerKey,
    );
    expect(connected, isNotNull);
    expect(connected!.grant!.role, GrantRole.initiator);
    expect(a.sessions, hasLength(2));
    expect(b.sessions, hasLength(2));
  }

  test('opposite grants keep separate media receivers and select local initiation authority', () async {
    build();
    final aOutgoing = a.sessions.single;
    final bIncoming = b.sessions.single;
    final originalA = factoryA.link;
    final originalB = factoryB.link;
    await connectReverse();
    expect(factoryA.links, hasLength(2));
    expect(factoryB.links, hasLength(2));
    expect(originalA.closed, isFalse);
    expect(originalB.closed, isFalse);
    expect(a.outgoingFor(aOutgoing.peerKey), same(aOutgoing));
    expect(b.outgoingFor(bIncoming.peerKey), isNot(same(bIncoming)));
    await remoteA.start(SessionOperation.watch, peerKey: aOutgoing.peerKey);
    expect(originalA.starts, [SessionOperation.watch]);
    expect(factoryA.links.last.starts, isEmpty);
    expect(remoteA.session, same(originalA.picture));
    await remoteB.start(SessionOperation.cast, peerKey: bIncoming.peerKey);
    expect(originalB.starts, isEmpty);
    expect(factoryB.links.last.starts, [SessionOperation.cast]);
    expect(remoteB.session, same(factoryB.links.last.picture));
  });

  test(
    'disconnecting unrelated opposite direction keeps the current picture',
    () async {
      build();
      final aOutgoing = a.sessions.single;
      await connectReverse();
      final opposite = a.sessions.last;
      await remoteA.start(SessionOperation.cast, peerKey: aOutgoing.peerKey);
      final picture = factoryA.forConnection(aOutgoing).picture!;
      picture.emit(MediaEventKind.firstFrame);
      opposite.close();
      await waitFor(() => a.sessions.length == 1);
      expect(remoteA.occupied, isTrue);
      expect(remoteA.phase, RemotePhase.active);
      expect(picture.stops, 0);
      aOutgoing.close();
      await waitFor(() => !remoteA.occupied);
      expect(picture.stops, 1);
    },
  );

  test(
    'losing the owning connection stops even when another direction remains',
    () async {
      build();
      final owner = a.sessions.single;
      await connectReverse();
      await remoteA.start(SessionOperation.watch, peerKey: owner.peerKey);
      final picture = factoryA.forConnection(owner).picture!;
      picture.emit(MediaEventKind.firstFrame);
      owner.close();
      await waitFor(() => !remoteA.occupied);
      expect(a.sessions, hasLength(1));
      expect(a.sessions.single.isClosed, isFalse);
      expect(remoteA.phase, RemotePhase.failed);
      expect(picture.stops, 1);
      expect(remoteA.operationsFor(owner.peerKey), isEmpty);
    },
  );

  test(
    'same peer and operation ID on another transport cannot hijack a picture',
    () async {
      build();
      final owner = a.sessions.single;
      await connectReverse();
      await remoteA.start(SessionOperation.watch, peerKey: owner.peerKey);
      final owned = factoryA.forConnection(owner).picture!;
      owned.emit(MediaEventKind.firstFrame);
      final otherLink = factoryA.links.last;
      final unrelated = _FakePicture(
        id: owned.id,
        operation: SessionOperation.watch,
        sends: true,
      );
      factoryA.deliver(unrelated, via: otherLink);
      expect(unrelated.stops, 1);
      expect(unrelated.stopReasons, [VideoEndReason.busy]);
      expect(remoteA.session, same(owned));
      factoryA.reportFailure(owned.id, 'source_ended', via: otherLink);
      expect(remoteA.phase, RemotePhase.active);
      otherLink.onFailure('different-operation', 'source_ended');
      expect(remoteA.phase, RemotePhase.active);
    },
  );

  testWidgets('the panel keeps the real states distinct and mounts the view', (
    tester,
  ) async {
    build();
    // The controller does real work here: it authorizes the operation against
    // the live connection and later releases the session. A widget test's fake
    // clock never drives those futures, so both awaits run on the real event
    // loop; without this the release is left half-done when the test ends.
    await tester.runAsync(
      () => remoteA.start(
        SessionOperation.watch,
        peerKey: a.sessions.single.peerKey,
        label: '另一台电脑',
      ),
    );
    final picture = factoryA.current;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: remoteA,
            builder: (_, _) => RemotePicturePanel(controller: remoteA),
          ),
        ),
      ),
    );
    picture.emit(MediaEventKind.connecting);
    await tester.pump();
    expect(find.textContaining('正在建立媒体通道'), findsOneWidget);
    expect(find.text('画面尺寸：未测'), findsOneWidget);
    expect(find.text('媒体路径：未测 · 往返时延：未测 · 接收速率：未测'), findsOneWidget);
    // A receiving session keeps its view mounted; without it no receipt is sent.
    expect(find.byKey(const ValueKey('remote-view')), findsOneWidget);
    picture.emit(MediaEventKind.transportReady);
    picture.emit(MediaEventKind.waitingFirstFrame);
    await tester.pump();
    expect(find.textContaining('等待对端首帧'), findsOneWidget);
    expect(find.textContaining('已收到对端画面'), findsNothing);
    picture.emit(MediaEventKind.firstFrame);
    await tester.pump();
    expect(find.textContaining('已收到对端画面'), findsOneWidget);
    picture.emit(
      MediaEventKind.statistics,
      transportPath: MediaTransportPath.direct,
      roundTripTime: const Duration(milliseconds: 12),
      bitsPerSecond: 800000,
      frameWidth: 640,
      frameHeight: 360,
    );
    await tester.pump();
    expect(find.text('画面尺寸：640 × 360'), findsOneWidget);
    expect(
      find.text('媒体路径：直连 · 往返时延：12.0 ms · 接收速率：800.0 kbit/s'),
      findsOneWidget,
    );
    expect(find.text('更换分享来源'), findsNothing);
    // Release the session inside the test body so no timer outlives the tree.
    await tester.runAsync(() => remoteA.stop());
    await tester.pump();
    expect(remoteA.occupied, isFalse);
  });
}
