import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_open/features/devices/device_directory.dart';
import 'package:share_hub_open/platform/client_platform.dart';
import 'package:share_hub_open/ui/field/device_field.dart';

const _trusted = 'trusted-identity-key';
const _stranger = 'stranger-identity-key';

DiscoverySnapshot snapshotOf(List<NearbyDevice> devices) =>
    DiscoverySnapshot(state: 'searching', devices: devices);

void main() {
  test('a shared display name never merges two identities', () {
    final entries = buildDeviceDirectory(
      discovery: snapshotOf(const [
        NearbyDevice(
          'shared-uuid',
          '书房 Mac',
          'macos',
          host: 'stranger.local',
          port: 4100,
          publicKey: _stranger,
        ),
      ]),
      verified: const [
        VerifiedPeer(publicKey: _trusted, name: '书房 Mac'),
      ],
    );
    expect(entries.length, 2);
    final trusted = entries.singleWhere((e) => e.identityId == _trusted);
    final stranger = entries.singleWhere((e) => e.identityId == _stranger);
    // The trusted identity keeps its own entry and is not overwritten by the
    // unverified peer that reused the name and the discovered identifier.
    expect(trusted.verified, isTrue);
    expect(trusted.host, isNull);
    expect(stranger.verified, isFalse);
    expect(stranger.connectable, isTrue);
    expect(stranger.hasCapability('watch'), isFalse);
  });

  test('a reused discovery identifier still yields two entries', () {
    final entries = buildDeviceDirectory(
      discovery: snapshotOf(const [
        NearbyDevice('same-uuid', '客厅 Mac', 'macos', publicKey: _stranger),
      ]),
      verified: const [VerifiedPeer(publicKey: _trusted, name: '客厅 Mac')],
    );
    // Identity, not the network identifier, decides the entry: an unverified
    // peer cannot inherit trust by replaying a name or a discovery UUID.
    expect(entries.map((e) => e.identityId).toSet(), {_trusted, _stranger});
  });

  test('an offline verified identity is saved material only', () {
    final entries = buildDeviceDirectory(
      discovery: snapshotOf(const []),
      verified: const [VerifiedPeer(publicKey: _trusted, name: '书房 Mac')],
    );
    final entry = entries.single;
    expect(entry.verified, isTrue);
    expect(entry.reachability, DeviceReachability.offline);
    expect(entry.savedOnly, isTrue);
    expect(entry.connectable, isFalse);
    expect(entry.capabilities, isEmpty);
    expect(entry.hasCapability('control'), isFalse);
  });

  test('discovery expiry does not fabricate reachability or connection', () {
    final before = buildDeviceDirectory(
      discovery: snapshotOf(const [
        NearbyDevice('uuid', '平板', 'android', publicKey: _trusted),
      ]),
      verified: const [VerifiedPeer(publicKey: _trusted, name: '平板')],
    );
    expect(before.single.online, isTrue);
    expect(before.single.connected, isFalse);
    final after = buildDeviceDirectory(
      discovery: snapshotOf(const []),
      verified: const [VerifiedPeer(publicKey: _trusted, name: '平板')],
    );
    // The record expired; the entry is neither reachable nor connected, and no
    // new connection was invented from the history.
    expect(after.single.online, isFalse);
    expect(after.single.connected, isFalse);
    expect(after.single.connectable, isFalse);
  });

  test('a withdrawn capability is no longer offered', () {
    DiscoverySnapshot discovery() => snapshotOf(const [
      NearbyDevice('uuid', '平板', 'android', publicKey: _trusted),
    ]);
    final granted = buildDeviceDirectory(
      discovery: discovery(),
      verified: const [
        VerifiedPeer(
          publicKey: _trusted,
          name: '平板',
          connected: true,
          capabilities: {'watch', 'control'},
        ),
      ],
    );
    expect(granted.single.hasCapability('watch'), isTrue);
    expect(granted.single.hasCapability('control'), isTrue);
    final withdrawn = buildDeviceDirectory(
      discovery: discovery(),
      verified: const [
        VerifiedPeer(publicKey: _trusted, name: '平板', connected: true),
      ],
    );
    expect(withdrawn.single.hasCapability('watch'), isFalse);
    expect(withdrawn.single.hasCapability('control'), isFalse);
  });

  test('capabilities are never offered without a live connection', () {
    final entries = buildDeviceDirectory(
      discovery: snapshotOf(const [
        NearbyDevice('uuid', '平板', 'android', publicKey: _trusted),
      ]),
      verified: const [
        VerifiedPeer(publicKey: _trusted, name: '平板', capabilities: {'watch'}),
      ],
    );
    // A remembered capability claim cannot authorize an operation while the
    // identity-bound connection is down.
    expect(entries.single.connected, isFalse);
    expect(entries.single.capabilities, isEmpty);
    expect(entries.single.hasCapability('watch'), isFalse);
  });

  test('duplicate discovery records keep one entry per identity', () {
    final entries = buildDeviceDirectory(
      discovery: snapshotOf(const [
        NearbyDevice('a', '平板', 'android', publicKey: _trusted, port: 1),
        NearbyDevice('b', '平板（重命名）', 'android', publicKey: _trusted, port: 2),
      ]),
    );
    expect(entries.length, 1);
    expect(entries.single.name, '平板');
  });

  testWidgets('the field offers no operation a peer did not negotiate', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DeviceField(
              entries: const [
                DirectoryDevice(
                  identityId: _trusted,
                  name: '平板',
                  platform: 'android',
                  trust: DeviceTrust.verified,
                  reachability: DeviceReachability.reachable,
                  connected: true,
                ),
                DirectoryDevice(
                  identityId: _stranger,
                  name: '离线平板',
                  platform: 'android',
                  trust: DeviceTrust.verified,
                  reachability: DeviceReachability.offline,
                ),
              ],
              localName: '本机',
              allowConnections: false,
              onLocal: () {},
              onDevice: (_) async {},
            ),
          ),
        ),
      ),
    );
    expect(
      find.text('android · 已验证连接 · 暂无可用操作'),
      findsOneWidget,
    );
    expect(find.text('已保存资料 · 需重新输码'), findsOneWidget);
    // A saved, unreachable identity cannot be acted on from the field.
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('device-$_stranger')),
          )
          .onPressed,
      isNull,
    );
  });
}
