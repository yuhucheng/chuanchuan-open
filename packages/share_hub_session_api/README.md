# Share Hub Session API 0.1.0

Apache-2.0, pure Dart. Shared by the authenticated connection service and the public media API; it has no Flutter, client UI or SDK dependency. This is a protocol core, not a deployed reconnect service or a binary ABI.

## Trust boundary

Only the pairing service constructs `GrantEndpoint.fromAuthenticatedPairing`, after successful short-code PAKE, mutual Ed25519 identity proof and atomic code consumption. The constructor is a trusted composition API, never a parser for remote/UI input. The connection service owns `GrantRegistry`; SDK resource owners receive that registry at construction. The sealed `SessionAuthorization` has two final variants: `VerifiedSessionMessage`, privately minted by authenticated decode, and `LocalSessionRequest`, minted by a live endpoint for a permitted outgoing operation. Both must belong to the injected registry; neither can be constructed or implemented by UI consumers. A local request proves local authorization only, not peer acceptance or rendering. A self-issued cryptographic proof cannot register itself.

`GrantBinding` holds a 32-byte grant ID and the two authenticated 32-byte public keys. A is the code-entering initiator; B is the code-displaying receiver. Watch requests, cast requests and control requests go A→B; watching produces B→A media, casting produces A→B media. File requests may go both ways. B→A watch/control requires a different grant with reversed roles. This control-message envelope is not a video, input, clipboard or file payload implementation. Text synchronization still requires the active control operation in its capability implementation.

The bootstrap exporter is HKDF-SHA256(SRP session key, salt = authenticated pairing transcript, info = `chuanchuan.grant.v2/recovery`, length = 32). The grant ID is SHA-256 of that transcript. Never use a short code as an exporter or expose/export recovery secrets to UI, logs or persistent storage.

## Recovery transcript and keys

Protocol version is 2. Existing connection v1 remains supported separately; a v2 attempt refuses a v1 peer without downgrade. API package version is independent.

Canonical encoding is UTF-8 JSON **arrays** in the order below, using canonical padded base64url strings for binary fields. No object-key ordering is used. Integers are nonnegative, transport generations are 1..2^32−1, and each challenge is 32 cryptographically random bytes.

`context = [2, grantId, initiatorKey, receiverKey, policy.type, policy.lifetime.inSeconds]`. The current pairing profile is `short-code` with 28800 seconds.

1. A reserves a single local attempt and sends `ResumeHello(generation, challengeA)`.
2. B, which must be suspended, chooses challengeB. `T = ["chuanchuan.resume.v2", ...context, generation, challengeA, challengeB]`. B sends challengeB and HMAC-SHA256(root, JSON `["receiver", base64url(T)]`).
3. A checks its outstanding challenge and B's proof, then sends HMAC-SHA256(root, JSON `["initiator", base64url(T)]`). B verifies before activation. Role labels prevent reflection; identities, grant and generation are all covered.
4. Both derive separate 32-byte HKDF-SHA256 keys, salt = T, info = `chuanchuan.transport.v2/initiator-to-receiver` or `chuanchuan.transport.v2/receiver-to-initiator`. Fresh challenges and incremented generations prevent reuse of the previous transport keys. Unauthenticated hello messages do not commit B's generation.

The transport adapter must deliver the final proof before application packets and must invalidate/suspend abandoned attempts. It must bound handshake time, attempts and network buffers; the current pairing handshake retains its 30-second timeout. The [connection package](../share_hub_connection/README.md) now provides an opt-in socket recovery adapter with final encrypted acknowledgement. The production client now opts in through bounded process-owned retry on the original selected route, with identity rechecks and cancellation/exit cleanup. Two-device recovery acceptance and media resumption remain separate unfinished work; a restored transport never authorizes an old media operation.

## Authenticated request envelopes

AES-256-GCM with 16-byte tag. Nonce is eight zero bytes followed by the unsigned 32-bit big-endian sequence. Send/receive keys differ; sequence starts at zero for a new transport and may never reach 2^32. AAD is JSON `["chuanchuan.packet.v2", ...context, generation, sequence]`. Cleartext is JSON `[operation.name, sessionId, body]`, limited to 65,536 UTF-8 bytes; session IDs are nonempty and at most 128 UTF-16 code units. The encrypted body is authenticated data, not trusted application semantics: capability owners must validate their own schema, source selection and system permissions.

Only the exact next sequence of the active generation is accepted. Counter consumption is serialized; authentication or parsing failures never mint a permit. Old keys, packets, callbacks and permits cannot cross a recovery epoch. Session IDs identify operations independently of grants and transports. Media slots reject reuse of stopped IDs; a new control session remains possible under the same valid grant.

## Deadline, revocation and resource ownership

Each endpoint captures its original local sleep-inclusive monotonic deadline at pairing. A uses its pre-ready timestamp conservatively; B uses atomic successful code consumption. Peer wall clocks or retries never change either deadline. `checkValidity()` must be polled by the connection owner even without traffic; every proof, packet and permit also rechecks the clock. Rollback, expiration or unavailable clocks fail closed.

`suspend()` synchronously invalidates existing permits and notifies resource owners through `invalidated`; it retains only recovery eligibility. `revoke()` additionally drops the root reference and is irreversible. `GrantRegistry.revokeAll()` removes registered grants before revoking them. The host must also cancel pending pairing attempts before turning admission off. Complete process restart must start with an empty registry; there is intentionally no persistence or restoration API. Dart garbage collection does not provide a secure-memory-erasure guarantee.

SDKs subscribe to invalidation, stop input/media/file execution immediately, recheck permits after every asynchronous operation, and retain occupied media slots until native cleanup succeeds. The client now explicitly selects v2 pairing and owns a process-local `GrantRegistry`. Completed connections register their authenticated grants; disconnect, admission-off and exit revoke them. The connection adapter routes authenticated operation requests/signals over the paired TCP connection; SDK media negotiation and automatic reconnect are not yet implemented. The connection package retains explicit v1 support for compatibility tests, but the client never silently downgrades. A grant alone does not advertise remote capabilities.

For the draft native provider bridge, `GrantRegistry.withVerifiedEndpoint` checks the exact sealed `SessionAuthorization` against this registry and invokes a trusted adapter callback with its original `GrantEndpoint` synchronously. The callback must recheck `authorization.requireCurrent()` immediately before a native import and must not await between that check and the call. Deadline conversion reads `authorization.readCurrentMicros()`, which validates the sample for rollback and expiry in the exact permit epoch; reading the raw endpoint clock would skip that validation. Other asynchronous preparation requires a fresh registry verification afterward. This handoff does not itself register a native provider, convert clock domains, or implement media.

## Verification

Run `dart test` and `dart analyze` here. Executable vectors cover forward/reverse roles, separate reverse grants, stale ciphertext with forged new headers, replay/reflection, identity and secret mismatch, revoke/recovery races, continuous-clock rollback and sleep crossing the deadline. The connection package additionally tests v2 material from real loopback PAKE and legacy rejection. These tests do not establish platform sleep behavior, double-device recovery or a production cryptographic audit.

## Initial activation and SDK consumers

The v2 pairing adapter activates generation 1 over its authenticated `CipherChannel` before publishing success. A sends `grant-hello` with generation/challenge; B sends `grant-response` with generation/challenge/proof; A sends `grant-finish` with proof; B verifies and sends `grant-active` with generation. Binary fields use the same canonical padded base64url encoding. B accepts only initial generation 1 in this exchange. It shares the pairing timeout and cancellation owner. Any failure revokes the new grant; a consumed code remains consumed. This initial activation is not automatic network recovery.

`authorizeLocal(operation, sessionId, body)` rechecks the endpoint's active epoch, original deadline and initiating direction before minting `LocalSessionRequest`. It does not send packets, choose a screen or confirm remote success. The local SDK consumes it through `BidirectionalRemoteMediaEngine.startOutgoing`; the receiving SDK consumes an authenticated `VerifiedSessionMessage` through `RemoteMediaEngine.startRemote`. Both resource owners use `MediaSessionBudget` with their own registry, recheck after asynchronous work and stop on invalidation. A permit from the other endpoint's registry is rejected even when its grant ID matches.

The client controller test exercises real loopback v2 activation, register/revoke boundaries and outgoing admission while the switch is off. Media contract tests exercise local direction denial, foreign registry rejection, shared watch/cast budget and revoke/expiry during asynchronous checks. The SDK consumer test exercises both variants using only the public media API.

## Bidirectional operation signaling

Once A owns a `LocalSessionRequest` and B has decoded the matching `VerifiedSessionMessage`, both may use `sealSignal(authorization, body)`. The encrypted plaintext is `["signal", operation.name, sessionId, body]`; it shares the active transport's directional key, sequence and replay guard with request packets. `openSignal(localAuthorization, envelope)` checks the endpoint instance, current epoch and exact operation/session binding and returns a privately minted `VerifiedSessionSignal`. A signal is a separate type, never a start permit; it cannot be passed to media admission or decoded as a reverse watch/control request.

Signal authentication is only the transport boundary. SDP/ICE/source/first-frame semantics still require their own bounded schema and operation-state checks. Consumers verify `signal.authorization` against their local registry and check their live session slot immediately before effects. A stopped operation must not process signals merely because its eight-hour grant remains valid. The public `SessionTransport` interface is implemented by `TrustedConnection`; SDKs consume the public interface without importing the connection implementation or client UI. The client has not attached a remote-media coordinator yet.

The legacy pairing cipher serializes concurrent encryption/writes, snapshots caller data and bounds its pending queue to eight messages and each clear payload to 4096 bytes (under the existing 8192-byte wire frame cap). These are the pre-authentication/v1 limits. After v2 grant proof, the adapter enables the bounded operation profile below.

## Paired TCP operation profile

The pairing cipher enables 131072-byte wire frames and 98304-byte clear control frames only after the v2 grant proof (before the final activation acknowledgement). Grant payloads retain their 65536-byte clear limit, which fits after the two base64 envelope layers. At most eight raw frames, eight pending cipher sends and eight pending operation sends are queued; raw receive buffering is capped at eight maximum frames. These are defensive implementation bounds, not measured media performance thresholds. Video frames do not travel over this control channel.

Authenticated outer messages are `operation-request` with `packet`, or `operation-signal` with `sessionId` and `packet`. The packet map contains integer `generation`/`sequence`, canonical padded base64url `ciphertext`, and a 16-byte `mac`. The session routing hint is not a permit: the inner authenticated payload must match the selected authorization. One coordinator attaches callbacks through `SessionTransport.attachReceiver`. Callbacks enqueue bounded work and return; media execution separately verifies the grant registry and operation slot.

`sendRequest` accepts only a local request owned by that exact grant endpoint. Operation sealing/writing is serialized. A failure after reserving a packet sequence closes the connection rather than leaving a sequence gap. Detaching a receiver invalidates its callback generation; closing the connection revokes its grant and rejects queued work. Authenticated signals for removed operations are consumed without minting a new permit so they cannot revive a session or desynchronize subsequent traffic.

Real loopback tests cover 60 KB requests/replies, both signal directions, foreign local-authority rejection, late old-operation replies followed by current replies, and revocation while an asynchronous clock check blocks the send. These are TCP/protocol tests with injected identities/clocks, not cross-device media or relay acceptance.

## Extensible grant policy

`GrantBinding.policy` explicitly carries an immutable `GrantPolicy` (type and whole-second lifetime). The default/current product profile is `GrantPolicy.shortCode`, eight hours; endpoint deadlines derive from the binding's policy, not a universal lifetime constant. Type and duration participate in recovery proofs, transport derivation and packet AAD. Supported product profiles are selected at trusted admission, not from arbitrary remote input. Tests using a 15-minute test profile prove the contract is extensible without enabling another product authorization mode. Mismatched type or duration fails authentication.

This refines the unpublished v2 development transcript: both peers must use the matching implementation. Earlier development binaries without the policy type in the transcript are incompatible and must reconnect using matching versions; there is no downgrade or silent renewal. Existing short-code UI and pairing continue to use eight hours.
