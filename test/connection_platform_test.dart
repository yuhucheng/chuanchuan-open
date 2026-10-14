import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/platform/client_platform.dart';

void main() {
  test('trusted connections ship for the desktop hosts only', () {
    expect(connectionHostSupported(TargetPlatform.macOS), isTrue);
    expect(connectionHostSupported(TargetPlatform.windows), isTrue);
    // Every other host keeps discovery read-only, so the UI never offers a
    // connection the platform cannot finish.
    for (final platform in const [
      TargetPlatform.linux,
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.fuchsia,
    ]) {
      expect(connectionHostSupported(platform), isFalse, reason: '$platform');
    }
  });

  test('discovery snapshot decodes the numeric fallback address', () {
    final snapshot = DiscoverySnapshot.fromMap({
      'state': 'searching',
      'devices': [
        {
          'id': 'peer',
          'name': '对端电脑',
          'platform': 'macos',
          'host': 'peer.local',
          'port': '31000',
          'key': 'k' * 44,
          'address': '172.20.102.31',
        },
        {'id': 'legacy', 'name': '旧端', 'platform': 'macos'},
      ],
    });
    expect(snapshot.devices[0].address, '172.20.102.31');
    expect(snapshot.devices[0].host, 'peer.local');
    expect(snapshot.devices[0].port, 31000);
    // Older native hosts never send the key; absence stays null, never ''.
    expect(snapshot.devices[1].address, isNull);
  });
}
