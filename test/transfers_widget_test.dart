import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/transfers/file_access.dart';
import 'package:share_hub_open/ui/client_app.dart';

import 'fakes.dart';
import 'file_fakes.dart';

void main() {
  testWidgets(
    'file page shows checked-but-unsent status and releases on removal',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = FakePlatform();
      final files = TestFileAccess()
        ..selection = [
          const SelectedFile(token: 'readme', name: '项目说明.txt', size: 3),
        ]
        ..data['readme'] = Uint8List.fromList([97, 98, 99]);
      await tester.pumpWidget(
        ShareHubApp(
          platform: platform,
          previewEngine: FakePreviewEngine(),
          fileAccess: files,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文件传送'));
      await tester.pumpAndSettle();
      expect(files.reads, isEmpty);
      await tester.tap(find.text('选择文件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已检查 · 等待连接'), findsOneWidget);
      expect(find.textContaining('尚未发送'), findsOneWidget);
      expect(find.text('发送成功'), findsNothing);
      await tester.tap(find.text('查看文件校验值'));
      await tester.pumpAndSettle();
      expect(find.textContaining('ba7816bf8f01cfea'), findsOneWidget);
      await tester.tap(find.byTooltip('移除 项目说明.txt'));
      await tester.pumpAndSettle();
      expect(find.text('先加入想分享的文件'), findsOneWidget);
      expect(files.releases, ['readme']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await platform.events.close();
    },
  );

  testWidgets(
    'compact file queue remains usable during pending read and cancellation',
    (tester) async {
      tester.view.physicalSize = const Size(860, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final platform = FakePlatform();
      final files = TestFileAccess()
        ..selection = [
          const SelectedFile(
            token: 'pending',
            name: '一份很长很长的文件名称，用于检查窄窗口中的布局.txt',
            size: 3,
          ),
        ]
        ..pendingRead = Completer<Uint8List>();
      await tester.pumpWidget(
        ShareHubApp(
          platform: platform,
          previewEngine: FakePreviewEngine(),
          fileAccess: files,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文件传送'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择文件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('正在检查文件'), findsOneWidget);
      await tester.tap(find.text('取消准备'));
      files.pendingRead!.complete(Uint8List.fromList([1, 2, 3]));
      await tester.pumpAndSettle();
      expect(find.textContaining('已取消准备'), findsOneWidget);
      expect(files.finished, isEmpty);
      await tester.tap(find.text('清空队列'));
      await tester.pumpAndSettle();
      expect(find.text('先加入想分享的文件'), findsOneWidget);
      expect(files.releases, ['pending']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await platform.events.close();
    },
  );
}
