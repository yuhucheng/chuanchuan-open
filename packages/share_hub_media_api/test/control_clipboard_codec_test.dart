import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

void main() {
  const id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final state = ClipboardSideState(revision: 1, enabled: true, available: true);
  final ready = ClipboardReady(
    epoch: 1,
    controllerStateRevision: 1,
    targetStateRevision: 1,
    text: null,
  );
  final proposal = ClipboardProposal(
    epoch: 1,
    controllerStateRevision: 1,
    targetStateRevision: 1,
    updateSequence: 1,
    updateId: id,
    baseRevision: 1,
    text: '中\n😀\u0000\ufeff',
  );
  final commit = ClipboardCommit(
    epoch: 1,
    controllerStateRevision: 1,
    targetStateRevision: 1,
    revision: 2,
    text: proposal.text,
    sourceUpdateId: id,
  );

  test('typed clipboard messages have canonical round trips', () {
    final messages = <ClipboardWireMessage>[
      state,
      ready,
      proposal,
      commit,
      ClipboardConflict(updateId: id, current: commit),
      ClipboardWriteFailed(
        epoch: 1,
        controllerStateRevision: 1,
        targetStateRevision: 1,
        updateId: id,
      ),
    ];
    for (final message in messages) {
      final body = ControlClipboardCodec.encode(message);
      expect(utf8.encode(body).length, lessThanOrEqualTo(48 * 1024));
      final decoded = ControlClipboardCodec.decode(body);
      expect(decoded.runtimeType, message.runtimeType);
      expect(ControlClipboardCodec.encode(decoded), body);
    }
    expect(
      (ControlClipboardCodec.decode(
        ControlClipboardCodec.encode(ready),
      ) as ClipboardReady).text,
      isNull,
    );
    final empty = ClipboardReady(
      epoch: 2,
      controllerStateRevision: 1,
      targetStateRevision: 1,
      text: '',
    );
    expect(
      (ControlClipboardCodec.decode(
        ControlClipboardCodec.encode(empty),
      ) as ClipboardReady).text,
      '',
    );
    expect(
      (ControlClipboardCodec.decode(
        ControlClipboardCodec.encode(proposal),
      ) as ClipboardProposal).text,
      proposal.text,
    );
  });

  test(
    '32 KiB UTF-8 text survives wire limit and authenticated-sized body',
    () {
      final maximum = ClipboardProposal(
        epoch: 1,
        controllerStateRevision: 1,
        targetStateRevision: 1,
        updateSequence: 1,
        updateId: id,
        baseRevision: 1,
        text: 'x' * 32768,
      );
      final body = ControlClipboardCodec.encode(maximum);
      expect(utf8.encode(body).length, lessThanOrEqualTo(48 * 1024));
      expect(
        (ControlClipboardCodec.decode(body) as ClipboardProposal).text,
        maximum.text,
      );
    },
  );

  test('leading BOM survives strict clipboard UTF-8 round trip', () {
    final withBom = ClipboardCommit(
      epoch: 1,
      controllerStateRevision: 1,
      targetStateRevision: 1,
      revision: 2,
      text: '\ufeff中文',
    );
    final received = ControlClipboardCodec.decode(
      ControlClipboardCodec.encode(withBom),
    ) as ClipboardCommit;
    expect(received.text, withBom.text);
  });

  test('non-text clipboard messages keep the 4 KiB ordinary limit', () {
    final body = ControlClipboardCodec.encode(ready).padRight(4096);
    expect(ControlClipboardCodec.decode(body), isA<ClipboardReady>());
    expect(
      () => ControlClipboardCodec.decode('$body '),
      throwsA(
        isA<SessionFailure>().having(
          (failure) => failure.code,
          'code',
          'message_limit',
        ),
      ),
    );
  });

  test('duplicate, unknown, wrong type and noncanonical fields reject', () {
    final valid = jsonDecode(
      ControlClipboardCodec.encode(proposal),
    ) as Map<String, dynamic>;
    for (final bad in [
      {...valid, 'clipboardEpoch': '01'},
      {...valid, 'clipboardEpoch': 1},
      {...valid, 'updateSequence': '9223372036854775808'},
      {...valid, 'updateId': 'A' * 32},
      {...valid, 'textUtf8': 'YQ=='},
      {...valid, 'textUtf8': '_x'},
      {...valid, 'path': 'secret'},
      {...valid, 'v': true},
    ]) {
      expect(
        () => ControlClipboardCodec.decode(jsonEncode(bad)),
        throwsA(isA<SessionFailure>()),
      );
    }
    expect(
      () => ControlClipboardCodec.decode(
        '{"v":1,"v":1,"type":"clipboard-state"}',
      ),
      throwsA(isA<SessionFailure>()),
    );
    final noText =
        jsonDecode(ControlClipboardCodec.encode(ready)) as Map<String, dynamic>;
    final missingMarker = {...noText}..remove('hasText');
    expect(
      () => ControlClipboardCodec.decode(jsonEncode(missingMarker)),
      throwsA(isA<SessionFailure>()),
    );
    expect(
      () =>
          ControlClipboardCodec.decode(jsonEncode({...noText, 'textUtf8': ''})),
      throwsA(isA<SessionFailure>()),
    );
  });

  test('rejected clipboard messages do not echo text or extra fields', () {
    const privateText = '诊断不可回显-剪贴板';
    const privateCredential = 'private-credential-material';
    final fields = jsonDecode(
      ControlClipboardCodec.encode(
        ClipboardProposal(
          epoch: 1,
          controllerStateRevision: 1,
          targetStateRevision: 1,
          updateSequence: 1,
          updateId: id,
          baseRevision: 1,
          text: privateText,
        ),
      ),
    ) as Map<String, dynamic>;
    fields['credential'] = privateCredential;
    try {
      ControlClipboardCodec.decode(jsonEncode(fields));
      fail('extra credential field must be rejected');
    } on SessionFailure catch (error) {
      expect(error.toString(), isNot(contains(privateText)));
      expect(error.toString(), isNot(contains(privateCredential)));
    }
  });
}
