# Windows wire-driven discovery (stale endpoint root cause + fix, 2026-10-14)

Second discovery fix of the day, after [the address fallback](2026-10-14-windows-direct-address-fallback.md). Symptom: with a freshly generated Mac short code **live**, the Windows client still showed "对端当前未开放连接入口", so no UI pairing was possible at all.

## Controlled comparison (same minute, same live offer)

| observation | result |
| --- | --- |
| raw mDNS sniffer (own socket, no OS resolver) | Mac advertises 7-key TXT: `host=appledeMacBook-Pro-2.local port=51656 key=…` |
| product-path probe (`DnsServiceBrowse`+`DnsServiceResolve`) | `endpoint=none` (stale 4-key view) |
| `resolve_dump` direct `DnsServiceResolve` minutes later | fresh 7-key — so the OS resolve path is *sometimes* fresh, sometimes stale: unusable either way |
| `DnsQuery_W(TXT, DNS_QUERY_BYPASS_CACHE)` | `9003` (NXDOMAIN via unicast DNS) — no classic-query bypass available |
| `DNS_SERVICE_RESOLVE_REQUEST` struct | only Version/InterfaceIndex/QueryName/callbacks — **no cache-bypass option exists** |

Decisive experiment: a modified `resolve_dump` printing every browse-callback record proved the **`DnsServiceBrowse` callback itself delivers full live record sets** (PTR/SRV/TXT/A/AAAA), including the fresh 7-key TXT the resolve path was hiding. Browse TXT strings are stored wide (UTF-16LE), which a naive `char*` print shows as single letters.

## Fix: discovery is now driven by the wire, not the OS resolve cache

`windows/platform/native_discovery.cpp`:

- `BrowseComplete` now consumes, in addition to PTR goodbyes: **TXT records** (wide strings → UTF-8, same `IsAcceptedTxtKey` contract, duplicate-key records ignored rather than flushing a healthy peer) and **A records** (numeric address for the connect fallback, matched to the advertised TXT `host` case-insensitively).
- `Pump` applies A answers, then PTR goodbyes, then TXT state via `DiscoveryModel.Update(..., address)`. Endpoint appearance *and withdrawal* now both propagate from live data.
- The `DnsServiceResolve` issuance, its callback and the pending-resolve bookkeeping are **removed** — it was the only cache-poisonable path. `DiscoveryModel.ResolveStarted/Resolved` remain as model API (covered by model tests); no production caller remains.

The 2026-10-14 address fallback (`host → address → auxiliary` in `connection_panel`) now gets its address from A records instead of the resolve answer; the field is populated as periodic full-set advertisements arrive.

## Verification

- `discovery_live_test` (real NIC, two native instances): **all PASS** — UTF-8 TXT discovery 818ms, peers retained across the 30s browse refresh (35s observation), **endpoint visible 833ms**, **endpoint withdrawal cleared 909ms**, stopped peer removed 63ms, full DNS-SD cleanup.
- Real Mac observation (`discovery_probe`): previously `endpoint=none` with a live offer; after the fix `endpoint=appledeMacBook-Pro-2.local:54987 key_length=44` immediately, and `address=172.20.102.31` attached after the periodic A-record set.
- `platform_tests` 72 checks, ctest 5/5, `flutter analyze --no-pub` clean, `flutter test --no-pub --concurrency=1` 384/384, `flutter build windows --debug --no-pub` OK.

UI-level pairing with the fixed build is recorded separately. macOS discovery (mDNSResponder pushes changes natively) never had this defect; no shared-protocol change was made, so no Mac rebuild is required for compatibility.
