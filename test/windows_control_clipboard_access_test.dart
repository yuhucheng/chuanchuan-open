import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_open/features/remote/windows_control_clipboard_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.sharehub.client/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<(ControlContext, GrantEndpoint)> context() async {
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
    final registry = GrantRegistry()..register(target);
    final local = await controller.authorizeLocal(
      SessionOperation.control,
      'clipboard-1',
      ControlStart({ControlCapability.clipboardText}).encode(),
    );
    final remote = await target.open(await controller.sealRequest(local));
    return (await ControlContext.fromRequest(registry, remote), target);
  }

  test('uses original grant deadline and exact clipboard scope', () async {
    final (authority, _) = await context();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'control.clipboard.open' => 7,
        'control.clipboard.read' => {'sequence': 17, 'text': '中文\n'},
        'control.clipboard.write' => {'status': 'written', 'sequence': 19},
        _ => null,
      };
    });
    final access = await WindowsControlClipboardAccess.open(
      context: authority,
      epoch: 3,
      controllerState: ClipboardSideState(
        revision: 4,
        enabled: true,
        available: true,
      ),
      targetState: ClipboardSideState(
        revision: 5,
        enabled: true,
        available: true,
      ),
    );
    expect(calls.first.arguments, {
      'deadlineMicros': authority.authorization.expiresMicros,
      'epoch': 3,
      'controllerRevision': 4,
      'targetRevision': 5,
    });
    expect((await access.read()).text, '中文\n');
    expect(calls.last.arguments, {
      'lease': 7,
      'epoch': 3,
      'controllerRevision': 4,
      'targetRevision': 5,
    });
    expect(
      (await access.write(expectedSequence: 17, text: '后续')).status,
      ClipboardNativeWriteStatus.written,
    );
    await access.close();
    expect(calls.last.method, 'control.clipboard.close');
    expect(calls.last.arguments, {'lease': 7});
  });

  test('revocation prevents read and write after opening', () async {
    final (authority, grant) = await context();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'control.clipboard.open' ? 8 : null;
    });
    final access = await WindowsControlClipboardAccess.open(
      context: authority,
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
    );
    grant.revoke();
    await expectLater(access.read(), throwsA(isA<SessionFailure>()));
    await expectLater(
      access.write(expectedSequence: 1, text: 'late'),
      throwsA(isA<SessionFailure>()),
    );
    expect(
      calls.where((call) => call.method == 'control.clipboard.write'),
      isEmpty,
    );
    await access.close();
  });

  test(
    'unknown write retires lease; invalid text never crosses channel',
    () async {
      final (authority, _) = await context();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'control.clipboard.open' => 9,
          'control.clipboard.write' => {'status': 'unknown', 'sequence': null},
          _ => null,
        };
      });
      final access = await WindowsControlClipboardAccess.open(
        context: authority,
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
      );
      await expectLater(
        access.write(expectedSequence: 1, text: 'a\u0000b'),
        throwsA(isA<SessionFailure>()),
      );
      expect(
        calls.where((call) => call.method == 'control.clipboard.write'),
        isEmpty,
      );
      expect(
        (await access.write(expectedSequence: 1, text: 'safe')).status,
        ClipboardNativeWriteStatus.unknown,
      );
      await expectLater(access.read(), throwsA(isA<SessionFailure>()));
      expect(
        calls.where((call) => call.method == 'control.clipboard.close'),
        hasLength(1),
      );
    },
  );
}
