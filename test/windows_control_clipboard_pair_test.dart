import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/remote/windows_control_clipboard_pair.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const controllerChannel = MethodChannel('test/clipboard/controller');
  const targetChannel = MethodChannel('test/clipboard/target');
  const controllerNotice = MethodChannel('test/clipboard/controller/notice');
  const targetNotice = MethodChannel('test/clipboard/target/notice');
  tearDown(() {
    messenger.setMockMethodCallHandler(controllerChannel, null);
    messenger.setMockMethodCallHandler(targetChannel, null);
    messenger.setMockMethodCallHandler(controllerNotice, null);
    messenger.setMockMethodCallHandler(targetNotice, null);
  });

  Future<(ControlContext, ControlContext)> contexts() async {
    final binding = GrantBinding(
      id: List.filled(32, 1),
      initiatorKey: List.filled(32, 2),
      receiverKey: List.filled(32, 3),
    );
    GrantEndpoint endpoint(GrantRole role) =>
        GrantEndpoint.fromAuthenticatedPairing(
          binding: binding,
          role: role,
          establishedMicros: 0,
          recoverySecret: List.filled(32, 4),
          clock: () async => 0,
          onInvalidated: () {},
        );
    final controller = endpoint(GrantRole.initiator);
    final target = endpoint(GrantRole.receiver);
    await target.acceptResume(
      await controller.finishResume(
        await target.answerResume(await controller.beginResume()),
      ),
    );
    final local = await controller.authorizeLocal(
      SessionOperation.control,
      'clipboard-pair',
      ControlStart({ControlCapability.clipboardText}).encode(),
    );
    final remote = await target.open(await controller.sealRequest(local));
    return (
      await ControlContext.fromRequest(
        GrantRegistry()..register(controller),
        local,
      ),
      await ControlContext.fromRequest(
        GrantRegistry()..register(target),
        remote,
      ),
    );
  }

  test('saved disabled setting does not open a clipboard lease', () async {
    final (controllerContext, targetContext) = await contexts();
    final fromController = <ClipboardWireMessage>[];
    final fromTarget = <ClipboardWireMessage>[];
    var nativeCalls = 0;
    messenger.setMockMethodCallHandler(controllerChannel, (_) async {
      nativeCalls++;
      return null;
    });
    messenger.setMockMethodCallHandler(targetChannel, (_) async {
      nativeCalls++;
      return null;
    });
    final controller = WindowsControlClipboardPair(
      context: controllerContext,
      enabled: false,
      channel: controllerChannel,
      send: (message) async => fromController.add(message),
      onFailure: (_) => fail('controller clipboard failure'),
    );
    final target = WindowsControlClipboardPair(
      context: targetContext,
      enabled: false,
      channel: targetChannel,
      send: (message) async => fromTarget.add(message),
      onFailure: (_) => fail('target clipboard failure'),
    );
    await controller.markPictureReady();
    await target.markPictureReady();
    expect((fromController.single as ClipboardSideState).enabled, isFalse);
    expect((fromTarget.single as ClipboardSideState).enabled, isFalse);
    await controller.receive(fromTarget.single);
    await target.receive(fromController.single);
    expect(nativeCalls, 0);
    await controller.stop();
    await target.stop();
  });

  test(
    'ready handshake binds two owners and target copy reaches controller',
    () async {
      final (controllerContext, targetContext) = await contexts();
      var controllerSequence = 10, targetSequence = 20;
      var now = 0;
      String? controllerText = 'old controller', targetText = 'target baseline';
      var controllerCloses = 0, targetCloses = 0;
      final fromController = <ClipboardWireMessage>[];
      final fromTarget = <ClipboardWireMessage>[];
      messenger.setMockMethodCallHandler(controllerChannel, (call) async {
        switch (call.method) {
          case 'control.clipboard.open':
            return 1;
          case 'control.clipboard.read':
            return {'sequence': controllerSequence, 'text': controllerText};
          case 'control.clipboard.write':
            final args = call.arguments as Map;
            if (args['expectedSequence'] != controllerSequence) {
              return {'status': 'conflict', 'sequence': null};
            }
            controllerSequence++;
            controllerText = args['text'] as String;
            return {'status': 'written', 'sequence': controllerSequence};
          case 'control.clipboard.close':
            controllerCloses++;
            return null;
        }
        throw StateError(call.method);
      });
      messenger.setMockMethodCallHandler(targetChannel, (call) async {
        switch (call.method) {
          case 'control.clipboard.open':
            return 2;
          case 'control.clipboard.read':
            return {'sequence': targetSequence, 'text': targetText};
          case 'control.clipboard.write':
            final args = call.arguments as Map;
            if (args['expectedSequence'] != targetSequence) {
              return {'status': 'conflict', 'sequence': null};
            }
            targetSequence++;
            targetText = args['text'] as String;
            return {'status': 'written', 'sequence': targetSequence};
          case 'control.clipboard.close':
            targetCloses++;
            return null;
        }
        throw StateError(call.method);
      });
      final controller = WindowsControlClipboardPair(
        context: controllerContext,
        channel: controllerChannel,
        notificationChannel: controllerNotice,
        newUpdateId: () => 'a' * 32,
        send: (message) async => fromController.add(message),
        onFailure: (_) => fail('controller clipboard failure'),
      );
      final target = WindowsControlClipboardPair(
        context: targetContext,
        channel: targetChannel,
        notificationChannel: targetNotice,
        send: (message) async => fromTarget.add(message),
        onFailure: (_) => fail('target clipboard failure'),
        monotonicMicros: () => now,
        flushInterval: const Duration(milliseconds: 5),
      );
      await controller.markPictureReady();
      await target.markPictureReady();
      expect(fromController.single, isA<ClipboardSideState>());
      expect(fromTarget.single, isA<ClipboardSideState>());
      await controller.receive(fromTarget.removeAt(0));
      await target.receive(fromController.removeAt(0));
      expect(fromTarget.single, isA<ClipboardReady>());
      await controller.receive(fromTarget.removeAt(0));
      expect(controllerText, 'target baseline');
      targetSequence++;
      targetText = '中文\nnew target';
      await messenger.handlePlatformMessage(
        targetNotice.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('changed'),
        ),
        (_) {},
      );
      expect(fromTarget.single, isA<ClipboardCommit>());
      await controller.receive(fromTarget.removeAt(0));
      expect(controllerText, '中文\nnew target');
      for (final text in ['second copy', 'third copy']) {
        targetSequence++;
        targetText = text;
        await messenger.handlePlatformMessage(
          targetNotice.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('changed'),
          ),
          (_) {},
        );
      }
      expect(fromTarget, hasLength(1));
      await controller.receive(fromTarget.removeAt(0));
      now = 250000;
      for (var attempt = 0; attempt < 30 && fromTarget.isEmpty; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(fromTarget.single, isA<ClipboardCommit>());
      await controller.receive(fromTarget.removeAt(0));
      expect(controllerText, 'third copy');
      await target.invalidatePicture();
      expect(targetCloses, 1);
      await controller.receive(fromTarget.removeAt(0));
      expect(controllerCloses, 1);
      await target.markPictureReady();
      final nextState = fromTarget.removeAt(0) as ClipboardSideState;
      final nextReady = fromTarget.removeAt(0) as ClipboardReady;
      expect(nextState.revision, 3);
      expect(nextReady.epoch, 2);
      await controller.receive(nextState);
      await controller.receive(nextReady);
      await expectLater(
        controller.receive(
          ClipboardCommit(
            epoch: 1,
            controllerStateRevision: 1,
            targetStateRevision: 1,
            revision: 3,
            text: 'late old epoch',
          ),
        ),
        throwsA(isA<SessionFailure>()),
      );
      await controller.setEnabled(false);
      await target.receive(fromController.removeAt(0));
      expect(targetCloses, 2);
      await controller.setEnabled(true);
      await target.receive(fromController.removeAt(0));
      final resumedReady = fromTarget.removeAt(0) as ClipboardReady;
      expect(resumedReady.epoch, 3);
      await controller.receive(resumedReady);
      await controller.stop();
      await target.stop();
    },
  );
}
