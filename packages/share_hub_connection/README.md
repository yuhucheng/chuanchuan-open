# Share Hub Connection

Public Dart pairing and authenticated operation transport. Current package/product
version is 0.1.0-dev.1. The [session API](../share_hub_session_api/README.md) owns
grant roles, fixed deadlines, recovery proofs and operation authorization.

## Auxiliary TURN service client

`AuxiliaryServiceClient` uses the existing `DeviceIdentity` for the public
[auxiliary service protocol](../../docs/protocols/auxiliary-service.md). It
registers identity ownership and requests a short-lived `AuxiliaryTurnCredential`
through `HttpsAuxiliaryTransport`. The caller supplies a configured HTTPS origin;
there is no baked-in production URL or implicit public-network fallback.
`AuxiliaryCancellation` aborts active requests and discards late results.
Credentials remain in memory, are redacted by `toString`, and grant no pairing or
media authority. The desktop app supplies an explicit HTTPS origin at build time,
fetches and renews only while a trusted connection is being made or retained,
and lets new SDK ICE Peers read only
an already available credential. This package alone does not establish relay;
official deployment, custom intranet selection and a real selected-pair proof
remain necessary.

## Connection recovery adapter

Pairing protocol 2 binds the encrypted `connected` reply, the local connection
lease and the authenticated `GrantBinding` to the same locally selected
`GrantPolicy` type and lifetime. The production client selects only
`short-code` / eight hours. A future product profile needs its own admission
decision at both endpoints; a peer cannot activate it by sending a longer
lifetime or a new type. A missing `grantType` in an older v2 reply is interpreted
as `short-code` only, while a mismatched type or lifetime is rejected. Protocol
1 remains limited to the existing short-code profile.

`PairingHost` and `PairingAttempt` accept an optional `enableRecovery` flag
(default false). Both endpoints must opt in on pairing protocol 2. The initiator
sends integer `recovery: 1` in encrypted `ready`; an enabled host acknowledges
it in encrypted `connected`. Absence of either opt-in preserves terminal close.
The production client opts in with process-owned bounded retry and cancellation.
This adapter alone does not resume video or confer an operation permission.

For an opted-in connection, actual socket loss or heartbeat timeout closes the
transport and synchronously suspends its grant. `whenClosed` reports
`transport_suspended`; old operation permits immediately fail. `canRecover`
indicates retained in-process eligibility, not a new usable transport or a
promise that the next authoritative clock check will pass. Suspended grants
remain subject to continuous-clock expiry checks. Explicit `close()`, clock
failure, invalid authentication/protocol, expiry, or closing host admission
revokes eligibility. No grant, transport base key or recovery secret is persisted.

The owner may create one `ConnectionRecoveryAttempt(previous)` and call
`connect(address, port)` on its explicitly selected route. There is no route
fallback or short-code re-pairing inside this attempt. The default caller-facing
deadline is five seconds. Timeout closes the owned socket and gates late results;
explicit `cancel()` also revokes the grant. A pending platform call continues to
own its reservation until `settled` completes, so timeout does not permit piling
up another handshake. A late socket is closed. The caller must bound retry count,
backoff and the overall recovery window, retain cleanup handles and revoke an
abandoned grant. The client currently uses three attempts with 1/2/4-second
backoff, five seconds per attempt and a 30-second total window. These are local
engineering defaults, independent of the extensible grant policy and its current
eight-hour lifetime. Only the original initiator retries its selected route;
there is no discovery-based substitution or public-network fallback. Receivers
wait within the same bounded policy. Both re-read the platform identity before
adoption. Pending retries count toward the client's eight-connection limit.

Explicit close invalidates authority synchronously and sends one encrypted
`{ "type": "revoked" }` terminal notice to opted-in peers; they do not treat this
as recoverable loss. The notice/flush is bounded (500 ms each), after which the
socket closes even if delivery fails. `whenTransportClosed` lets the owner await
physical cleanup separately from immediate `whenClosed`/grant invalidation.
A lost notice cannot restore a revoked grant; the other endpoint's recovery
attempts fail and expire. Exit retains late platform/socket owners until they
settle; cancellation gates their results immediately.

On success the result is a new `TrustedConnection` using the **same grant and
lease**, original peer identity and expiry, but new transport generation and
keys. The old handle cannot mint operations. Replace its routing/receiver owner;
SDK resources must finish old-generation cleanup before starting any new media.
Recovery never reuses an old media operation identifier or confirms a first frame.

### Wire profile

The host's existing bounded listener recognizes the following recovery exchange,
without reserving/consuming a short code. The grant id is only an in-memory lookup
hint. A connection must already be suspended and only one recovery reservation
per retained connection is allowed; unauthenticated hello cannot commit a generation.

1. Plain `resume-hello`: exactly `v: 2`, `type`, `grant` (canonical encoded id),
   integer `generation`, and a canonical 32-byte `challenge`.
2. Plain `resume-response`: exactly `v: 2`, `type`, matching integer `generation`,
   a fresh 32-byte `challenge`, and 32-byte `proof` from `GrantEndpoint.answerResume`.
3. Plain `resume-finish`: exactly `v: 2`, `type`, and the 32-byte initiator `proof`.
4. Newly encrypted `resume-active`: exactly `type` and matching integer `generation`.
   Initiator publication waits for this acknowledgement. All binary fields use
   canonical padded base64url; the grant API verifies role-separated HMAC proofs
   bound to both identities, policy, grant, generation and both challenges.

The operation layer already derives fresh directional transport keys through the
session API. The outer heartbeat/framing cipher also gets new keys: retain only
the original PAKE-established **directional base keys** in process, and derive
32-byte HKDF-SHA256 keys from each corresponding directional base with salt equal
to UTF-8 JSON `["chuanchuan.connection.resume.v1", grantId, generation,
challengeA, challengeB]` and info `chuanchuan.connection.resume.v1`. Its session id
is canonical base64url SHA-256 of that same transcript. Existing AES-GCM framing,
AAD, sequence bounds and buffer limits apply, with counters reset for the fresh
keys. Deriving from the stable base, rather than chaining the last attempted
keys, allows a lost final acknowledgement to recover through another fresh proof.
No key is exported to application code or sent over the wire.

The host retains its four-pending-socket and handshake-deadline limits. Silent or
malformed new-pairing sockets still consume their offer reservation; recovery
prefaces do not guess or consume a short code. `refreshOffer()` rotates the
admission code on the existing listener, preserving its port and authenticated
recovery entries; old pairing attempts cannot publish against the new offer.
Closing/reopening admission cancels pending sockets and removes recovery entries.
Revoked entries are removed even when no further connection arrives.

## Relay signaling draft wire

`RelayRoomClaim` and `RelaySignalEnvelope` define strict version-1 canonical
JSON for a relay serving a grant already held by both endpoints in the current
process. Room IDs hash the canonical claim with the
`chuanchuan.signal.room.v1\0` domain. A service challenge is signed over the
`chuanchuan.signal.join.v1\0` domain, room ID, member public key and 32-byte
nonce. The claim retains the grant's policy type and lifetime as fields; it
does not force an eight-hour-only schema. Envelope fields are `v`, `room`,
`sender`, `generation`, `seq`, `kind`, `payload`; the payload is opaque sealed
bytes, never SDP interpreted by the relay. `RelaySignalInbox` rejects a wrong
member, room, old generation, replay or any data after cancellation. The
public Dart and private Python packages pin identical wire, room and signature
vectors. `RelayServiceClient` now opens a cancellable HTTPS room only from a
process-owned grant and matching device identity; it refuses a lost send
acknowledgement rather than guessing the next sequence. The Python auxiliary
service offers an opt-in bounded room route, with a local Dart-to-Python TLS
probe. The production connection owner tries its saved local TCP route first,
then the explicitly selected HTTPS room within the original recovery window.
Both endpoints seal resume frames with the original pairing's directional keys,
complete the existing two-way grant proof and install new transport/session keys
without changing the original deadline. The local Python HTTPS probe exercises
this full recovery. A room never authorizes an operation, and first-time cross-network
pairing needs a separate rendezvous design. A caller supplying
`HttpsAuxiliaryTransport` for relay polling must set a timeout longer than the
selected service's configured `poll_wait_seconds`; the local TLS probe uses
35 seconds for the service's bounded one-second poll.

## Verification boundary

`dart analyze` and `dart test` cover real local TCP, PAKE, encrypted operation
traffic, recovery after an owned proxy cuts the socket, old-permit/packet rejection,
unchanged identity/deadline, forged final proof, lost encrypted final acknowledgement,
wrong process, opt-out peers, cancellation, expiry and a timed-out platform read.
They are not two-device, real sleep, deployed relay, OS permission or media-resumption
acceptance. Client integration tests additionally exercise repeated recovery,
short-code rotation, explicit close, both identity changes, cancellation/off/exit,
pending platform admission and deadline cleanup. Recovery cancellation is visible
in both connection contexts; it is not an active-connection or first-frame signal.
The session API additionally rejects stale-epoch clock completions
before they can alter the new generation's validity.
