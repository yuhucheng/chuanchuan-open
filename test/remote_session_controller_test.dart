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

class _FakePicture implements SourceSelectableRemotePicture {
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
  VideoEndReason? endedBy;
  bool failStop = false;
  final stopReasons = <VideoEndReason>[];
  int stops = 0, resumes = 0;
  bool stoppedFlag = false;

  @override
  Stream<MediaSessionEvent> get events => _events.stream;
  @override
  Widget get view =>
      const SizedBox(key: ValueKey('remote-view'), width: 8, height: 8);
  @override
  int mediaRevision = 0;
  @override
  CaptureSource? localSource;
  final changes = <CaptureSource>[];
  Completer<void>? changeGate;
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

  void emit(MediaEventKind kind, {String? failureCode, int? revision}) {
    if (_events.isClosed) return;
    _events.add(
      MediaSessionEvent(
        grantId: 'grant',
        sessionId: id,
        transportGeneration: 1,
        mediaRevision: revision ?? mediaRevision,
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
  Future<void> resume() async {
    resumes++;
    mediaRevision++;
    emit(MediaEventKind.waitingFirstFrame);
  }

  @override
  Future<void> stop({VideoEndReason reason = VideoEndReason.stopped}) async {
    stops++;
    stopReasons.add(reason);
    if (failStop) throw StateError('cleanup failed');
    stoppedFlag = true;
    finish();
  }
}

class _FakeLink {
  _FakeLink(this.transport, this.onSession, this.onFailure);
  final SessionTransport transport;
  final void Function(RemotePicture) onSession;
  final void Function(String, String) onFailure;
  final starts = <SessionOperation>[];
  Completer<void>? gate;
  bool failStartAfterAdoption = false, failStop = false;
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
    final picture = _FakePicture(
      id: sessionId,
      operation: operation,
      sends: operation == SessionOperation.cast,
    )..failStop = _link.failStop;
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

  void build({bool Function()? localCaptureOccupied}) {
    remoteA = RemoteSessionController(
      connections: a,
      platform: platformA,
      factory: factoryA,
      listSources: () async => sourceListGate?.future ?? sourcesA,
      localCaptureActive: localCaptureOccupied ?? () => previewActive,
      firstFrameDeadline: const Duration(milliseconds: 150),
      permissionPoll: const Duration(milliseconds: 20),
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
      // and the field never reports a successful share.
      await waitFor(() => !remoteA.occupied);
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
          expect(remoteB.occupied, isFalse);
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
      await remoteA.changeSource(window);
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
    expect(find.text('更换分享来源'), findsNothing);
    // Release the session inside the test body so no timer outlives the tree.
    await tester.runAsync(() => remoteA.stop());
    await tester.pump();
    expect(remoteA.occupied, isFalse);
  });
}
