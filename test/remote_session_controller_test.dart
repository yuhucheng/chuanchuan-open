import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_connection/share_hub_connection.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/connection_controller.dart';
import 'package:share_hub_open/features/preview/preview_controller.dart';
import 'package:share_hub_open/features/remote/remote_media.dart';
import 'package:share_hub_open/features/remote/remote_session_controller.dart';
import 'package:share_hub_open/platform/client_platform.dart';
import 'package:share_hub_open/ui/remote/remote_panel.dart';

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

class _FakePicture implements RemotePicture {
  _FakePicture({required this.id, required this.operation, required this.sends});
  @override
  final String id;
  @override
  final SessionOperation operation;
  @override
  final bool sends;
  final _events = StreamController<MediaSessionEvent>.broadcast(sync: true);
  VideoEndReason? endedBy;
  bool failStop = false;
  int stops = 0, resumes = 0;
  bool stoppedFlag = false;

  @override
  Stream<MediaSessionEvent> get events => _events.stream;
  @override
  Widget get view =>
      const SizedBox(key: ValueKey('remote-view'), width: 8, height: 8);
  @override
  int get mediaRevision => 0;
  @override
  bool get stopped => stoppedFlag;
  @override
  VideoEndReason? get remoteEndReason => endedBy;

  void emit(MediaEventKind kind, {String? failureCode}) {
    if (_events.isClosed) return;
    _events.add(
      MediaSessionEvent(
        grantId: 'grant',
        sessionId: id,
        transportGeneration: 1,
        kind: kind,
        failureCode: failureCode,
      ),
    );
  }

  void finish() {
    if (!_events.isClosed) unawaited(_events.close());
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async => resumes++;
  @override
  Future<void> stop() async {
    stops++;
    if (failStop) throw StateError('cleanup failed');
    stoppedFlag = true;
    finish();
  }
}

class _FakeLink {
  _FakeLink();
  final starts = <SessionOperation>[];
  Completer<void>? gate;
  bool closed = false;
  _FakePicture? picture;

  Future<void> close() async {
    closed = true;
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
  void Function(RemotePicture)? _onSession;
  void Function(String, String)? _onFailure;

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
    _onSession = onSession;
    _onFailure = onFailure;
    final link = _FakeLink();
    links.add(link);
    // The real authorization path is sealed through the connection's grant.
    return _GrantCheckedLink(link, transport, resolveSource, this);
  }

  void deliver(RemotePicture picture) {
    delivered.add(picture);
    _onSession?.call(picture);
  }

  void reportFailure(String sessionId, String code) {
    final callback = _onFailure;
    if (callback == null) {
      failures.add('$sessionId:$code');
      return;
    }
    callback(sessionId, code);
  }
}

/// Mirrors the media link: authorize through the real transport, resolve the
/// local source only when this endpoint sends, and report the failure code.
class _GrantCheckedLink implements RemotePictureLink {
  _GrantCheckedLink(this._link, this._transport, this._resolveSource, this._factory);
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
    await _transport.createRequest(operation, sessionId, VideoSessionRequest.body);
    if (_link.gate != null) await _link.gate!.future;
    if (operation == SessionOperation.cast) {
      try {
        await _resolveSource();
      } catch (error) {
        _factory.reportFailure(
          sessionId,
          error is SessionFailure ? error.code : 'media_start_failed',
        );
        rethrow;
      }
    }
    final picture = _FakePicture(
      id: sessionId,
      operation: operation,
      sends: operation == SessionOperation.cast,
    );
    _link.picture = picture;
    _factory.deliver(picture);
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
    factoryA = _FakeFactory();
    factoryB = _FakeFactory();
  });

  tearDown(() async {
    remoteA.dispose();
    remoteB.dispose();
    await a.disconnectAll();
    await b.disconnectAll();
    a.dispose();
    b.dispose();
  });

  void build() {
    remoteA = RemoteSessionController(
      connections: a,
      platform: platformA,
      factory: factoryA,
      listSources: () async => sourcesA,
      localCaptureActive: () => previewActive,
      firstFrameDeadline: const Duration(milliseconds: 150),
      permissionPoll: const Duration(milliseconds: 20),
    );
    remoteB = RemoteSessionController(
      connections: b,
      platform: platformB,
      factory: factoryB,
      listSources: () async => sourcesA,
      localCaptureActive: () => previewActive,
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

  test('an unconnected peer is refused before the code flow, with no capture', () async {
    build();
    await remoteA.start(SessionOperation.watch, peerKey: 'stranger');
    expect(remoteA.error, contains('短接码'));
    expect(remoteA.occupied, isFalse);
    expect(factoryA.links.single.starts, isEmpty);
    expect(platformA.permissionRequests, 0);
  });

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
    expect(remoteB.error, '当前连接方向不允许该操作，需由对端主动发起。');
    expect(factoryB.delivered, isEmpty);
    expect(remoteB.occupied, isFalse);
  });

  test('a missing capture permission fails the cast instead of faking it', () async {
    platformA.status = const PermissionStatus();
    platformA.grantPermission = false;
    build();
    await remoteA.start(
      SessionOperation.cast,
      peerKey: a.sessions.single.peerKey,
    );
    expect(
      remoteA.error,
      '屏幕录制权限不可用，请在系统设置中允许 Share Hub 后重试。',
    );
    expect(remoteA.phase, RemotePhase.failed);
    expect(factoryA.delivered, isEmpty);
    expect(remoteA.occupied, isFalse);
  });

  test('an unidentifiable primary screen never falls back to another source', () async {
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
  });

  test('a locally started capture is never reported as the peer presenting', () async {
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
    // and the field never reports a successful share.
    await waitFor(() => !remoteA.occupied);
    expect(remoteA.phase, RemotePhase.failed);
    expect(remoteA.error, contains('未呈现共享画面'));
    expect(picture.stops, greaterThanOrEqualTo(1));
  });

  test('the peer presenting the frame is what makes the share active', () async {
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
  });

  test('cancelling mid-start stops the late session and isolates its callbacks', () async {
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
  });

  test('a second operation is refused while the picture budget is spent', () async {
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
  });

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

  test('the peer ending the operation is reported as the peer ending it', () async {
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
  });

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
    // Release the session inside the test body so no timer outlives the tree.
    await tester.runAsync(() => remoteA.stop());
    await tester.pump();
    expect(remoteA.occupied, isFalse);
  });
}
