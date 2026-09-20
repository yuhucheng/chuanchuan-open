import '../../platform/client_platform.dart';

/// Trust is only ever granted by a completed identity verification in this
/// process. A discovery record, a friendly name or a reused network identifier
/// never becomes trust, and nothing here is persisted across a restart.
enum DeviceTrust { unverified, verified }

/// Reachability is derived from current discovery feedback or a live
/// connection. A remembered record does not keep a device "online".
enum DeviceReachability { reachable, offline }

/// A peer that completed identity verification earlier in this process. The
/// profile keeps only display material; it grants no authorization.
class VerifiedPeer {
  const VerifiedPeer({
    required this.publicKey,
    this.name,
    this.connected = false,
    this.capabilities = const {},
  });
  final String publicKey;
  final String? name;
  final bool connected;

  /// Capability keys reported by the *current* authenticated peer. The set is
  /// empty until a media/input/file contract is delivered and accepted, so the
  /// field never offers an operation the peer did not negotiate.
  final Set<String> capabilities;
}

/// One entry of the client device directory.
///
/// Identity, not name, decides whether two records are the same device: two
/// peers showing the same name (or reusing the same discovered identifier) stay
/// separate entries. A verified identity keeps its own entry even after the
/// record disappears from discovery, and is then shown as saved material only.
class DirectoryDevice {
  const DirectoryDevice({
    required this.identityId,
    required this.name,
    required this.platform,
    required this.trust,
    required this.reachability,
    this.publicKey,
    this.host,
    this.port,
    this.connected = false,
    this.capabilities = const {},
  });

  /// An unverified discovery record: reachable, unknown identity, no
  /// operations. It is never treated as trusted material.
  factory DirectoryDevice.fromDiscovered(NearbyDevice device) => DirectoryDevice(
    identityId: device.publicKey ?? device.id,
    name: device.name,
    platform: device.platform,
    trust: DeviceTrust.unverified,
    reachability: DeviceReachability.reachable,
    publicKey: device.publicKey,
    host: device.host,
    port: device.port,
  );

  /// Stable per identity: the claimed key when one is advertised, otherwise the
  /// discovery identifier. Never the display name.
  final String identityId;
  final String name;
  final String platform;
  final DeviceTrust trust;
  final DeviceReachability reachability;
  final String? publicKey;
  final String? host;
  final int? port;
  final bool connected;
  final Set<String> capabilities;

  bool get verified => trust == DeviceTrust.verified;
  bool get online => reachability == DeviceReachability.reachable;

  /// An operation may be offered only from the capabilities of a live
  /// connection. Saved material alone authorizes nothing.
  bool hasCapability(String operation) =>
      connected && capabilities.contains(operation);

  /// Only a record that carries a verifiable endpoint may be asked to prove its
  /// identity; the proof is still the short-code handshake, not this flag.
  bool get connectable =>
      !connected && host != null && port != null && publicKey != null;

  /// A verified identity that is not currently reachable. Kept as a reminder
  /// only: reconnecting requires a new short code.
  bool get savedOnly => verified && !online && !connected;
}

/// Projects the discovery snapshot and the live verified peers into the field
/// directory. Pure: it holds no state, so display never creates a connection or
/// extends an authorization.
List<DirectoryDevice> buildDeviceDirectory({
  required DiscoverySnapshot discovery,
  Iterable<VerifiedPeer> verified = const [],
}) {
  final discovered = <String, NearbyDevice>{};
  for (final device in discovery.devices) {
    // A repeated identity keeps its first record; duplicates never overwrite an
    // existing entry, and a name clash never merges two identities.
    discovered.putIfAbsent(device.publicKey ?? device.id, () => device);
  }
  final entries = <DirectoryDevice>[];
  for (final peer in verified) {
    final match = discovered.remove(peer.publicKey);
    entries.add(
      DirectoryDevice(
        identityId: peer.publicKey,
        name: match?.name ?? peer.name ?? '设备 ${peer.publicKey.substring(0, 8)}',
        platform: match?.platform ?? 'unknown',
        trust: DeviceTrust.verified,
        reachability: peer.connected || match != null
            ? DeviceReachability.reachable
            : DeviceReachability.offline,
        publicKey: peer.publicKey,
        host: match?.host,
        port: match?.port,
        connected: peer.connected,
        capabilities: peer.connected ? peer.capabilities : const {},
      ),
    );
  }
  for (final device in discovered.values) {
    entries.add(DirectoryDevice.fromDiscovered(device));
  }
  return List.unmodifiable(entries);
}
