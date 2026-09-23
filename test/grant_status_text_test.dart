import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/connections/grant_status_text.dart';
import 'package:share_hub_open/ui/field/appearance.dart';

class _Grants {
  _Grants({GrantPolicy policy = GrantPolicy.shortCode, int id = 1}) {
    final binding = GrantBinding(
      id: List.filled(32, id),
      initiatorKey: List.filled(32, 2),
      receiverKey: List.filled(32, 3),
      policy: policy,
    );
    GrantEndpoint endpoint(GrantRole role) =>
        GrantEndpoint.fromAuthenticatedPairing(
          binding: binding,
          role: role,
          establishedMicros: 1000000,
          recoverySecret: List.filled(32, 7),
          clock: readClock,
          onInvalidated: () {},
        );
    a = endpoint(GrantRole.initiator);
    b = endpoint(GrantRole.receiver);
  }

  late final GrantEndpoint a, b;
  int now = 1000000, reads = 0;
  bool failClock = false;
  Completer<int>? pending;

  Future<int> readClock() {
    reads++;
    if (failClock) return Future.error(StateError('private clock diagnostic'));
    return pending?.future ?? Future.value(now);
  }

  Future<void> resume() async {
    final response = await b.answerResume(await a.beginResume());
    await b.acceptResume(await a.finishResume(response));
  }

  void dispose() {
    a.revoke();
    b.revoke();
  }
}

Widget _host(GrantEndpoint? grant, {bool closed = false}) => MaterialApp(
  theme: fieldTheme(Brightness.light, TargetPlatform.macOS),
  home: Scaffold(
    body: SingleChildScrollView(
      child: GrantStatusText(
        key: const ValueKey('grant'),
        grant: grant,
        connectionClosed: closed,
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'reads the authenticated type and actual non-eight-hour lifetime',
    (tester) async {
      final short = _Grants(
        policy: const GrantPolicy(
          type: 'short-code',
          lifetime: Duration(seconds: 90),
        ),
      );
      final custom = _Grants(
        policy: const GrantPolicy(
          type: 'test-session',
          lifetime: Duration(minutes: 15),
        ),
        id: 4,
      );
      addTearDown(short.dispose);
      addTearDown(custom.dispose);
      await short.resume();
      await tester.pumpWidget(_host(short.a));
      await tester.pump();
      expect(find.text('短接码授权 · 总期限 1 分钟 30 秒'), findsOneWidget);
      expect(find.text('授权剩余 1 分钟 30 秒'), findsOneWidget);
      expect(find.textContaining('8 小时'), findsNothing);

      await tester.pumpWidget(_host(custom.a));
      await tester.pump();
      expect(find.text('授权类型：test-session · 总期限 15 分钟'), findsOneWidget);
      expect(find.textContaining('授权已暂停'), findsOneWidget);
      // Displaying an extensible type must not activate or enable that grant.
      expect(custom.a.phase, GrantPhase.suspended);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'expiration uses the original monotonic deadline without renewal',
    (tester) async {
      final grants = _Grants(
        policy: const GrantPolicy(
          type: 'short-code',
          lifetime: Duration(minutes: 2),
        ),
      );
      addTearDown(grants.dispose);
      await grants.resume();
      grants.now += const Duration(seconds: 30).inMicroseconds;
      await tester.pumpWidget(_host(grants.a));
      await tester.pump();
      expect(find.text('授权剩余 1 分钟 30 秒'), findsOneWidget);
      grants.now = grants.a.expiresMicros;
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('授权已到期，请重新连接'), findsOneWidget);
      // Authorization enforcement belongs to the owner, never to this readout.
      expect(grants.a.phase, GrantPhase.active);
      final reads = grants.reads;
      await tester.pump(const Duration(minutes: 10));
      expect(grants.reads, reads);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('suspend and authenticated resume retain the same deadline', (
    tester,
  ) async {
    final grants = _Grants(
      policy: const GrantPolicy(
        type: 'short-code',
        lifetime: Duration(minutes: 5),
      ),
    );
    addTearDown(grants.dispose);
    await grants.resume();
    final deadline = grants.a.expiresMicros;
    grants.now += const Duration(minutes: 1).inMicroseconds;
    await tester.pumpWidget(_host(grants.a));
    await tester.pump();
    expect(find.text('授权剩余 4 分钟'), findsOneWidget);
    grants.a.suspend();
    grants.b.suspend();
    await tester.pump();
    expect(find.text('授权已暂停 · 剩余 4 分钟（恢复不续期）'), findsOneWidget);
    grants.now += const Duration(seconds: 30).inMicroseconds;
    await grants.resume();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('授权剩余 3 分钟 30 秒'), findsOneWidget);
    expect(grants.a.expiresMicros, deadline);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('clock failure and rollback never display a new full lifetime', (
    tester,
  ) async {
    final grants = _Grants();
    addTearDown(grants.dispose);
    await grants.resume();
    grants.now += const Duration(hours: 1).inMicroseconds;
    await tester.pumpWidget(_host(grants.a));
    await tester.pump();
    expect(find.text('授权剩余 7 小时'), findsOneWidget);
    grants.failClock = true;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('授权剩余时间不可用'), findsOneWidget);
    expect(find.textContaining('private clock'), findsNothing);
    grants.failClock = false;
    grants.now += const Duration(minutes: 1).inMicroseconds;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('授权剩余 6 小时 59 分钟'), findsOneWidget);
    grants.now -= const Duration(minutes: 1).inMicroseconds;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('授权剩余时间不可用'), findsOneWidget);
    expect(find.text('授权剩余 7 小时'), findsNothing);
    expect(grants.a.phase, GrantPhase.active);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'hidden UI stops polling and resumes from the sleep-inclusive clock',
    (tester) async {
      final grants = _Grants();
      addTearDown(grants.dispose);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await grants.resume();
      await tester.pumpWidget(_host(grants.a));
      await tester.pump();
      final reads = grants.reads;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump(const Duration(hours: 9));
      expect(grants.reads, reads);
      grants.now = grants.a.expiresMicros + 1;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('授权已到期，请重新连接'), findsOneWidget);
      expect(grants.reads, reads + 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'hidden pending clock remains single-flight and times out on resume',
    (tester) async {
      final grants = _Grants()..pending = Completer<int>();
      addTearDown(grants.dispose);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await tester.pumpWidget(_host(grants.a));
      expect(grants.reads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump(const Duration(seconds: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('授权剩余时间不可用'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(grants.reads, 1);
      final pending = grants.pending!;
      grants.pending = null;
      grants.now += const Duration(hours: 1).inMicroseconds;
      pending.complete(1000000); // A pre-hide result cannot restore old time.
      await tester.pumpAndSettle();
      expect(grants.reads, 2);
      expect(find.textContaining('剩余 7 小时'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('late old-grant reads and disposed timers cannot update the UI', (
    tester,
  ) async {
    final old = _Grants()..pending = Completer<int>();
    final current = _Grants(
      policy: const GrantPolicy(
        type: 'short-code',
        lifetime: Duration(minutes: 3),
      ),
      id: 8,
    );
    addTearDown(old.dispose);
    addTearDown(current.dispose);
    await current.resume();
    await tester.pumpWidget(_host(old.a));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('授权剩余时间不可用'), findsOneWidget);
    expect(old.reads, 1);
    await tester.pumpWidget(_host(current.a));
    await tester.pump();
    old.pending!.complete(old.a.expiresMicros + 1);
    await tester.pump();
    expect(find.text('授权剩余 3 分钟'), findsOneWidget);
    expect(find.text('授权已到期，请重新连接'), findsNothing);

    current.pending = Completer<int>();
    await tester.pump(const Duration(seconds: 1));
    final reads = current.reads;
    await tester.pumpWidget(const SizedBox());
    current.pending!.completeError(StateError('late private error'));
    await tester.pump(const Duration(seconds: 20));
    expect(tester.takeException(), isNull);
    expect(current.reads, reads);
  });

  testWidgets(
    'revocation is immediate and missing grant has no invented lifetime',
    (tester) async {
      final grants = _Grants();
      addTearDown(grants.dispose);
      await grants.resume();
      await tester.pumpWidget(_host(grants.a));
      await tester.pump();
      grants.a.revoke();
      await tester.pump();
      expect(find.text('授权已撤销或到期'), findsOneWidget);
      expect(find.text('授权剩余 8 小时'), findsNothing);
      final reads = grants.reads;
      await tester.pump(const Duration(seconds: 10));
      expect(grants.reads, reads);
      await tester.pumpWidget(_host(null));
      expect(find.text('授权期限未提供'), findsOneWidget);
      expect(find.textContaining('8 小时'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('long actual type and deadline remain readable at 200 percent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 400);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final grants = _Grants(
      policy: const GrantPolicy(
        type: 'a-long-but-authenticated-future-type',
        lifetime: Duration(days: 2, hours: 3, minutes: 4, seconds: 5),
      ),
    );
    addTearDown(grants.dispose);
    await tester.pumpWidget(_host(grants.a));
    await tester.pump();
    for (final element in find.byType(Text).evaluate()) {
      final paragraph = element.renderObject! as RenderParagraph;
      expect(paragraph.didExceedMaxLines, isFalse);
    }
    expect(find.textContaining('2 天 3 小时 4 分钟 5 秒'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
