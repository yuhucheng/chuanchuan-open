import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/remote/windows_control_clipboard_target_owner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sharehub.client/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<ControlContext> targetContext() async {
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
      'clipboard-owner-1',
      ControlStart({ControlCapability.clipboardText}).encode(),
    );
    final remote = await target.open(await controller.sealRequest(local));
    return ControlContext.fromRequest(
      GrantRegistry()..register(target),
      remote,
    );
  }

  test(
    'baseline, remote write, local copy and OS conflict stay scoped',
    () async {
      final context = await targetContext();
      var sequence = 10;
      String? osText = 'target';
      var closes = 0, forceConflict = false;
      final sent = <ClipboardWireMessage>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'control.clipboard.open':
            return 7;
          case 'control.clipboard.read':
            return {'sequence': sequence, 'text': osText};
          case 'control.clipboard.write':
            final args = call.arguments as Map;
            if (forceConflict) {
              forceConflict = false;
              sequence++;
              osText = 'new local';
            }
            if (args['expectedSequence'] != sequence) {
              return {'status': 'conflict', 'sequence': null};
            }
            sequence++;
            osText = args['text'] as String;
            return {'status': 'written', 'sequence': sequence};
          case 'control.clipboard.close':
            closes++;
            return null;
        }
        throw StateError(call.method);
      });
      final owner = await WindowsControlClipboardTargetOwner.open(
        context: context,
        epoch: 1,
        controllerState: ClipboardSideState(
          revision: 1,
          enabled: true,
          available: true,
        ),
        targetState: ClipboardSideState(
          revision: 1,
          enabled: true,
          available: true,
        ),
        pictureReady: true,
        send: (message) async => sent.add(message),
      );
      expect((sent.single as ClipboardReady).text, 'target');
      await owner.receive(
        ClipboardProposal(
          epoch: 1,
          controllerStateRevision: 1,
          targetStateRevision: 1,
          updateSequence: 1,
          updateId: 'a' * 32,
          baseRevision: 1,
          text: 'remote',
        ),
      );
      expect(osText, 'remote');
      expect((sent.last as ClipboardCommit).revision, 2);
      owner.startWatching(
        onFailure: (_) => fail('unexpected clipboard notification failure'),
      );
      sequence++;
      osText = 'copied here';
      await messenger.handlePlatformMessage(
        'dev.sharehub.client/control-clipboard',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('changed'),
        ),
        (_) {},
      );
      expect((sent.last as ClipboardCommit).text, 'copied here');
      expect((sent.last as ClipboardCommit).revision, 3);
      forceConflict = true;
      await owner.receive(
        ClipboardProposal(
          epoch: 1,
          controllerStateRevision: 1,
          targetStateRevision: 1,
          updateSequence: 2,
          updateId: 'b' * 32,
          baseRevision: 3,
          text: 'stale remote',
        ),
      );
      expect(osText, 'new local');
      expect((sent.last as ClipboardConflict).current.text, 'new local');
      expect((sent.last as ClipboardConflict).current.revision, 4);
      await owner.settingsChanged(
        controllerState: ClipboardSideState(
          revision: 1,
          enabled: true,
          available: true,
        ),
        targetState: ClipboardSideState(
          revision: 2,
          enabled: false,
          available: true,
        ),
      );
      await owner.close();
      expect(closes, 1);
      await expectLater(owner.observe(), throwsA(isA<SessionFailure>()));
    },
  );

  test(
    'stop during delayed OS read cannot publish a late local copy',
    () async {
      final context = await targetContext();
      final readEntered = Completer<void>();
      final releaseRead = Completer<void>();
      var reads = 0, closes = 0;
      final sent = <ClipboardWireMessage>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'control.clipboard.open':
            return 9;
          case 'control.clipboard.read':
            reads++;
            if (reads == 2) {
              readEntered.complete();
              await releaseRead.future;
              return {'sequence': 2, 'text': 'late'};
            }
            return {'sequence': 1, 'text': 'base'};
          case 'control.clipboard.close':
            closes++;
            return null;
        }
        throw StateError(call.method);
      });
      final owner = await WindowsControlClipboardTargetOwner.open(
        context: context,
        epoch: 1,
        controllerState: ClipboardSideState(
          revision: 1,
          enabled: true,
          available: true,
        ),
        targetState: ClipboardSideState(
          revision: 1,
          enabled: true,
          available: true,
        ),
        pictureReady: true,
        send: (message) async => sent.add(message),
      );
      final pending = owner.observe();
      final rejection = expectLater(pending, throwsA(isA<SessionFailure>()));
      await readEntered.future;
      final closing = owner.close();
      releaseRead.complete();
      await rejection;
      await closing;
      expect(closes, 1);
      expect(sent, hasLength(1));
    },
  );
}
