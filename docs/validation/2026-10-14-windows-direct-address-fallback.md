# Windows direct-connect address fallback + auxiliary ICP root cause (2026-10-14)

Dual-machine session (Windows 11 x64 `172.20.102.24`, macOS `172.20.102.31`, same LAN). Symptom reported by the user: "Mac can connect to Windows, but Windows cannot connect to Mac", with the client banner "所选辅助服务不可达或 TLS 校验失败".

## Fresh pairing evidence (protocol layer)

Two fresh short-code pairings Windows→Mac via `tool/pair_probe.dart` (pure Dart, same `share_hub_connection` code as the product, no build pollution):

| code | session_id | result |
| --- | --- | --- |
| 057010 | `gGZTs3EaLg6w7ZWBBi88o4CrDMKBljLi7fvltXegjnk=` | connected, `lease_hours=8` |
| 093897 | `Q-xOra-Pj27lj0zQ9SFHhmkolPUO_Y_QqES35sy-VzE=` | connected, `lease_hours=8` |

Both: `peer_key` identical to the advertised key, stable `peer_id=f69eebc0c5796bd6…` (same Mac identity as 2026-09-20), LAN direct. In both rounds the `.local`-name attempt failed with `signal_unreachable` while the numeric-address attempt succeeded — the first concrete lead.

## Root causes (two independent ones, both proven)

**1. Windows could not resolve the Mac's `.local` name; the product had no address fallback.**

- `ping appledeMacBook-Pro-2.local` → host not found; the Mac's DHCP address changed `.49` → `.31` since 2026-09-20.
- Raw mDNS A query for the same name (own socket to 224.0.0.251:5353, no OS resolver): **the Mac answers** from `172.20.102.31:5353` — the peer publishes correctly; the failure is inside the Windows name-resolution path.
- Product chain: device card `connect(host=.local)` → `signal_unreachable` → existing auxiliary `connectByCode` fallback → second root cause below. The discovery model carried only `host/port/key`, no numeric address, so no direct retry was possible.

**2. The auxiliary service domain is blocked by Aliyun ICP compliance interception; the service itself is alive.**

- `curl --noproxy '*' https://chuanchuan.xyz:8443/` (47.106.9.163): TCP connects, TLS handshake never returns.
- Plain HTTP on the same port: `403 Forbidden`, `Server: Beaver`, body title **"Non-compliance ICP Filing"** with an iframe to `www.aliyun.com/beian/beian-block` — the ICP-filing block page.
- HTTPS by IP (`-k`, diagnostic only): `404 {"error":"not_found"}` from `Server: BaseHTTP/0.6 Python/3.12.3` — **the real auxiliary service is up and serving TLS**. Only domain-based access is intercepted.

This is an operations/compliance blocker for trusted-connection 7.4/8.4 online acceptance (needs a filing, a different filed domain, or a non-mainland node), not a client defect. No cloud changes were made.

## Fix: direct connect now tries host → resolve-answer address → auxiliary

Only `signal_unreachable` triggers a fallback; a bad code, rejected identity or cancelled handshake still never retries a second target, and the advertised public key still pins the peer on every path.

- `windows/platform/native_discovery.cpp`: `ResolveComplete` reads `DNS_SERVICE_INSTANCE.ip4Address` (`IP4_ADDRESS*`, single address) → `inet_ntop` → `Event.address` → model.
- `windows/platform/discovery_model.{h,cpp}`: `Device.address`, propagated by `Update`/`Resolved`; a refresh without an address clears the stale one; address alone never makes a peer connectable.
- `windows/platform/platform_bridge.cpp`: snapshot emits `address` when present.
- Dart: `NearbyDevice.address` (+ `DiscoverySnapshot.fromMap`), `DirectoryDevice.address` (both verified and discovered projections), `field_shell` passes it into the connection dialog.
- `connection_panel.submit`: on `signal_unreachable`, retry the same code against `address` before the auxiliary `connectByCode` fallback. Auxiliary order and gating unchanged otherwise.

## Verification

- `flutter analyze --no-pub`: no issues.
- `flutter test --no-pub --concurrency=1`: **382/382** (was 378; +3 widget cases: host→address success without auxiliary, address also unreachable continues to auxiliary, identity_mismatch never retries address; +1 snapshot decode case incl. legacy maps without `address`).
- Windows native (VS BuildTools CMake): `platform_tests` **72 checks** (was 68; address supplied/cleared/replaced/non-connectable), ctest **5/5**.
- `flutter build windows --debug --no-pub`: `share_hub.exe` built; kernel blob has no integration_test entry.
- Note: native MSBuild `MSB6001` failures were reproduced and root-caused to `HTTP_PROXY`/`HTTPS_PROXY` case-duplicate keys crashing the MSBuild environment dictionary — unset all proxy vars (both cases) before native builds.

Real-machine UI acceptance of the new fallback (user clicks the device card with a live code) is a separate record; this document covers implementation, simulated evidence and the dual-machine probe rounds.
