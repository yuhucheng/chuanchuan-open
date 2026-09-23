import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/remote/windows_control_clipboard_controller_owner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sharehub.client/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<ControlContext> controllerContext() async {
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
      'clipboard-controller-1',
      ControlStart({ControlCapability.clipboardText}).encode(),
    );
    return ControlContext.fromRequest(
      GrantRegistry()..register(controller),
      local,
    );
  }

  final controllerState = ClipboardSideState(
    revision: 1,
    enabled: true,
    available: true,
  );
  final targetState = ClipboardSideState(
    revision: 1,
    enabled: true,
    available: true,
  );
  final ready = ClipboardReady(
    epoch: 1,
    controllerStateRevision: 1,
    targetStateRevision: 1,
    text: 'target baseline',
  );

  test(
    'target baseline wins; later local copy proposes and echo does not loop',
    () async {
      final context = await controllerContext();
      var sequence = 10, writes = 0, closes = 0;
      String? osText = 'controller old';
      final sent = <ClipboardWireMessage>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'control.clipboard.open':
            return 8;
          case 'control.clipboard.read':
            return {'sequence': sequence, 'text': osText};
          case 'control.clipboard.write':
            final args = call.arguments as Map;
            expect(args['expectedSequence'], sequence);
            writes++;
            sequence++;
            osText = args['text'] as String;
            return {'status': 'written', 'sequence': sequence};
          case 'control.clipboard.close':
            closes++;
            return null;
        }
        throw StateError(call.method);
      });
      final owner = await WindowsControlClipboardControllerOwner.open(
        context: context,
        ready: ready,
        controllerState: controllerState,
        targetState: targetState,
        pictureReady: true,
        newUpdateId: () => 'a' * 32,
        send: (message) async => sent.add(message),
      );
      expect(osText, 'target baseline');
      expect(writes, 1);
      owner.startWatching(
        onFailure: (_) => fail('unexpected clipboard notification failure'),
      );
      Future<void> notify() => messenger.handlePlatformMessage(
        'dev.sharehub.client/control-clipboard',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('changed'),
        ),
        (_) {},
      );
      await notify();
      expect(sent, isEmpty);
      sequence++;
      osText = '中文\nnew';
      await notify();
      final proposal = sent.single as ClipboardProposal;
      expect(proposal.text, '中文\nnew');
      expect(proposal.baseRevision, 1);
      await owner.receive(
        ClipboardCommit(
          epoch: 1,
          controllerStateRevision: 1,
          targetStateRevision: 1,
          revision: 2,
          text: '中文\nnew',
          sourceUpdateId: proposal.updateId,
        ),
      );
      expect(writes, 1);
      expect(sent, hasLength(1));
      await owner.close();
      expect(closes, 1);
    },
  );

  test(
    'baseline write conflict preserves a new local copy and proposes it',
    () async {
      final context = await controllerContext();
      var sequence = 10;
      String? osText = 'controller old';
      final sent = <ClipboardWireMessage>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'control.clipboard.open':
            return 9;
          case 'control.clipboard.read':
            return {'sequence': sequence, 'text': osText};
          case 'control.clipboard.write':
            sequence++;
            osText = 'new local';
            return {'status': 'conflict', 'sequence': null};
          case 'control.clipboard.close':
            return null;
        }
        throw StateError(call.method);
      });
      final owner = await WindowsControlClipboardControllerOwner.open(
        context: context,
        ready: ready,
        controllerState: controllerState,
        targetState: targetState,
        pictureReady: true,
        newUpdateId: () => 'b' * 32,
        send: (message) async => sent.add(message),
      );
      expect(osText, 'new local');
      expect((sent.single as ClipboardProposal).text, 'new local');
      await owner.close();
    },
  );

  test(
    'later target commit cannot overwrite a copy racing with OS write',
    () async {
      final context = await controllerContext();
      var sequence = 1, closes = 0;
      String? osText = 'target baseline';
      final sent = <ClipboardWireMessage>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'control.clipboard.open':
            return 11;
          case 'control.clipboard.read':
            return {'sequence': sequence, 'text': osText};
          case 'control.clipboard.write':
            sequence++;
            osText = 'racing local';
            return {'status': 'conflict', 'sequence': null};
          case 'control.clipboard.close':
            closes++;
            return null;
        }
        throw StateError(call.method);
      });
      final owner = await WindowsControlClipboardControllerOwner.open(
        context: context,
        ready: ready,
        controllerState: controllerState,
        targetState: targetState,
        pictureReady: true,
        newUpdateId: () => 'c' * 32,
        send: (message) async => sent.add(message),
      );
      await owner.receive(
        ClipboardCommit(
          epoch: 1,
          controllerStateRevision: 1,
          targetStateRevision: 1,
          revision: 2,
          text: 'new target',
        ),
      );
      expect(osText, 'racing local');
      expect((sent.single as ClipboardProposal).baseRevision, 2);
      expect((sent.single as ClipboardProposal).text, 'racing local');
      await owner.settingsChanged(
        controllerState: ClipboardSideState(
          revision: 2,
          enabled: false,
          available: true,
        ),
        targetState: targetState,
      );
      await owner.close();
      expect(closes, 1);
      await expectLater(owner.observe(), throwsA(isA<SessionFailure>()));
    },
  );
}
