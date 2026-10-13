# Auxiliary TLS segmentation comparison — 2026-10-13

The normal Dart 3.13.2 HTTPS health probe still fails on Mac. A custom, normally trusted context requiring TLS 1.3 also fails, so raising the client minimum alone did not resolve this observation. Windows separately reports failure after clock synchronization and a contemporaneous server handshake reset; its origin remains unproven.

Read-only OpenSSL 3.6.4 handshakes on 8443/5349 validate with the default offer and TLS 1.3. Restricting the offer to X25519 fails even with TLS 1.3, although successful default handshakes ultimately select X25519. An owned loopback listener observes only structural lengths/types: Dart's default first ClientHello record is 251 bytes, while default OpenSSL/Python records are 1545/1519 bytes. No session randoms, keys, certificate/private data or other processes' traffic are recorded.

With the same OpenSSL TLS 1.3/X25519 options, diagnostic ALPN offer lengths change the outcome: 1438-byte first records fail and 1448-byte first records validate. The remote socket reports TCP MSS 1444 on this Mac path. This correlates with segmentation; it is not a proven universal threshold or identification of a resetting network device.

The repeatable tool keeps the default Dart ClientHello bytes unchanged and uses an ephemeral loopback byte relay. Two unsplit attempts fail; splitting the first 251-byte write at byte 100 with a 30 ms gap passes normal certificate/hostname verification and HTTP 200 with JSON `status: ok` twice. TLS is never terminated by the relay. The normal app transport is unchanged, and the output always leaves `normalTransportReady`, `pairingVerified` and `relayVerified` false.

Run from the public checkout with Python and the locked Dart runtime:

```powershell
python packages/share_hub_connection/tool/auxiliary_tls_segmentation_probe.py --origin https://chuanchuan.xyz:8443 --dart dart
```

The tool does not need pub get, a private SDK, OpenSSL or server access. Windows Flutter's `dart.bat` is resolved to its cached native `dart.exe`; other batch shims require an explicit native executable. It reads only `/health`, rejects credentials/query/fragment/extra paths, bounds I/O and response size, and prints no raw error, payload, certificate or key. TCP MSS is optional on hosts where that socket option is unavailable. A zero process exit means the diagnostic completed, not that the normal connection or pairing passed.

The controlled byte-relay tests check preservation of both directions and later opaque records, rejection of non-ClientHello input, origin validation, and owned thread/socket cleanup. Dart analysis and the actual Mac endpoint comparison pass. Windows execution is pending.

Next evidence: repeat on Windows and compare a narrowly scoped client/server packet-header and handshake timeline for unsplit/split attempts. Distinguish peer resets, retransmission/path handling and service-side behavior before selecting a deployment repair. No diagnostic fragmentation or ALPN padding is added to the normal client, and no TLS downgrade, certificate bypass or production service change has been made. First pairing, signaling and TURN/media acceptance remain pending.
