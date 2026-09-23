import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';

void main() {
  test('matching OS token and text suppress repeated own-write echo', () {
    final guard = ClipboardEchoGuard();
    guard.recordOwnWrite(changeToken: 'token-1', text: '中文');
    expect(
      guard.observe(changeToken: 'token-1', text: '中文'),
      ClipboardObservation.ownEcho,
    );
    expect(
      guard.observe(changeToken: 'token-1', text: '中文'),
      ClipboardObservation.ownEcho,
    );
    expect(
      guard.observe(changeToken: 'token-2', text: '中文'),
      ClipboardObservation.localText,
    );
    expect(
      guard.observe(changeToken: 'token-1', text: 'different'),
      ClipboardObservation.localText,
    );
  });

  test('no plain-text format is not an empty text update', () {
    final guard = ClipboardEchoGuard();
    expect(
      guard.observe(changeToken: 'token-1', text: null),
      ClipboardObservation.noText,
    );
    expect(
      guard.observe(changeToken: 'token-2', text: ''),
      ClipboardObservation.localText,
    );
  });

  test('recent marker memory stays bounded and clears on stop', () {
    final guard = ClipboardEchoGuard();
    for (var i = 0; i < 5; i++) {
      guard.recordOwnWrite(changeToken: 'token-$i', text: '$i');
    }
    expect(guard.rememberedCount, 4);
    expect(
      guard.observe(changeToken: 'token-0', text: '0'),
      ClipboardObservation.localText,
    );
    expect(
      guard.observe(changeToken: 'token-4', text: '4'),
      ClipboardObservation.ownEcho,
    );
    guard.clear();
    expect(guard.rememberedCount, 0);
    expect(
      guard.observe(changeToken: 'token-4', text: '4'),
      ClipboardObservation.localText,
    );
  });

  test('missing or reused ambiguous OS token fails closed', () {
    final guard = ClipboardEchoGuard();
    expect(
      () => guard.recordOwnWrite(changeToken: '', text: 'A'),
      throwsA(isA<SessionFailure>()),
    );
    guard.recordOwnWrite(changeToken: 'token-1', text: 'A');
    expect(
      () => guard.recordOwnWrite(changeToken: 'token-1', text: 'B'),
      throwsA(isA<SessionFailure>()),
    );
    expect(
      () => guard.observe(changeToken: '', text: 'A'),
      throwsA(isA<SessionFailure>()),
    );
  });
}
