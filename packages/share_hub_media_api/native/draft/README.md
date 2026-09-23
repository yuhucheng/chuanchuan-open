# Native media boundary — review draft 2

**Unimplemented draft.** No shipping SDK exports `shm_draft_*`. This directory is
not consumed by the Dart package, plugin build or installer. Dart media API
0.7.0, session API 0.1.0 and existing wire profiles are unchanged. The header is
public interface work, not private SDK implementation or a binary delivery.

The boundary header specifies authorization/provider, resource ownership and
shutdown. [Media operations](MEDIA.md) and `share_hub_media_operations.h` add
sources, start, playback, recovery, measurements, presentation, wakeup and bounded
queues/frame storage. Both are review declarations; neither header has a linked
implementation. [Package layout and compatibility metadata](PACKAGING.md) now have a concrete
proposal and non-installable examples; production validation, GPU interop and stable
ABI extension rules remain design/acceptance work. No program can run media by including these headers alone.

## C representation and compatibility

The proposed calling surface is C11/C++17 with explicit 32/64-bit fields and
native pointer alignment on Windows x64/ARM64 and macOS arm64/x86_64. No packed
structs or language-dependent enums/booleans cross it. Integers and pointers are
process-local native-endian values, never a wire format. Each input/output struct
starts with its byte size and draft revision. This draft requires exact matches;
unknown revisions, nonzero reserved fields and unsupported enum values fail
before resource allocation. A future stable ABI must define minor-version tail
extension and optional function negotiation before it is released.

All pointer arguments must address valid caller storage. Null data is permitted
only for zero-length slices. Input slices are borrowed only during the call and
copied before return, including asynchronous work. They are bounded and validated
before copy/allocation; arbitrary readable-pointer validation is not promised.
Output structs are initialized by the caller with size/revision; no tail overwrite
is allowed. On error all handle outputs are zero and no ownership is transferred.
`available_revision` is the sole negotiation output still populated for an
incompatible valid create header. A null/short header is an invalid argument.
No C++/Swift exception crosses the ABI; status is returned by value.

Handles are nonzero, kind-checked IDs in the loaded runtime, not addresses or
caller-assigned session strings. They are scoped to their core and are never
recycled during that runtime's lifetime. Exhaustion fails closed. A stale, foreign
or wrong-kind handle cannot alias another object. Unloading the library invalidates
all IDs; the host must never unload it with a live core, job, event or frame lease.
The initial implementation should allow one live core per loaded SDK runtime,
with one shared media budget. Creating several links/providers cannot multiply
the current single-video limit; thumbnails borrow an existing operation.

## Trusted provider boundary

Register a provider only at the local authenticated connection composition root.
Registration is a trusted in-process extension point, equivalent to constructing
`GrantEndpoint.fromAuthenticatedPairing` and injecting a `GrantRegistry`; it is
not a cryptographic proof and does not resist a compromised host process. UI,
discovery records, network JSON and persisted grant metadata must not invoke
provider imports. The SDK never accepts a standalone `authorized` boolean. Creation starts in
CONFIGURING; register the trusted providers and call `seal_providers` before
exposing media controls. Sealing is irreversible for that core and prevents
later application code from adding its own registry. Imports/media require a
sealed core; zero providers is valid for local-only preview. The host retains
provider handles inside the connection adapter, not UI action models. This
limits accidental misuse, not malicious code already controlling the process.

The planned Dart adapter keeps a private mapping of each native grant handle to
the exact local `GrantEndpoint` and each authorization handle to its exact sealed
`LocalSessionRequest` or `VerifiedSessionMessage`. Before import it awaits
`GrantRegistry.verify`, checks the original object's current epoch, then performs
the native call synchronously without another await. Body/kind/operation/identity
come from that object, not separately supplied UI values. The adapter is owned by
the public session/connection layer and may not import private media state machines.

`provider_import_grant` copies the authenticated 32-byte grant ID and both public
keys, local role, policy type, whole-second duration and original local deadline.
It creates a suspended mirror, not an active permit. Same-identity keys, unsupported
policy, invalid duration and expired deadline are rejected. The current product
selects `short-code` / 28,800 seconds at trusted pairing admission; the ABI fields
remain extensible and do not encode eight hours as the only possible lifetime.
Policy validation follows the session API (type grammar and duration bounds).
The SDK must not enable a new product authorization mode merely because a remote
peer suggests another type.

Re-importing an existing grant ID/local endpoint is rejected, including across
providers in the same core. It must not create a second budget/history domain or
extend the old deadline. Recovery reuses the existing native grant handle.
Revoked bindings remain tombstoned for the core lifetime; history exhaustion
fails closed rather than evicting replay guards. The proposed registry/history bounds and limit errors are specified in
[MEDIA.md](MEDIA.md); their enforcement still needs implementation and tests.

Activation is called only after the real provider authenticates its transport
proof. The generation strictly increases in the range 1..2^32−1; binding, policy
and deadline are immutable. Suspension synchronously invalidates all prior
permits/jobs and stops admission. Reactivation does not revive any old operation.
Revocation is irreversible. Calls from a different provider, or an old generation,
fail even when their public grant ID matches.

An authorization import binds kind, operation, session ID/body and current grant
generation. The native side independently derives sender/receiver roles and media
direction: A initiates watch/cast, watch sends B→A, cast sends A→B. The provider
cannot grant a reversed request through a signal. Native media still validates
request profile 3/4, SDP/ICE semantics, source/permission and operation state.
Session ID validation preserves the Dart limit of 128 UTF-16 code units after
strict UTF-8 decoding (the 512-byte header limit is only a conservative allocation
cap). Signals obey their existing 65,536-byte body cap and each media message's
stricter schema limits. Signal delivery is never media-start authority.

A native adapter for a non-Flutter host must implement the same real session
contract and registry checks, including authentication/replay/epoch behavior.
Neither that adapter nor the Dart/native mapping is implemented by this draft.
The intended deliverable includes a distributable public provider adapter/sample;
a callback that always approves cannot satisfy native SDK independence acceptance.
The provider must keep the real endpoint/transport and exact authorization
mapping alive while a native operation can still use them, and until all original
jobs drain. Dropping a caller authorization reference must not remove the
provider mapping of an operation that retains its own reference.

## Deadline and revocation ordering

Native effects recheck active grant, original deadline, operation cancellation,
transport generation and media revision immediately before allocation/application
and again after every asynchronous boundary. Native workers use a sleep-inclusive
continuous clock and audit deadlines during silence. Clock failure/rollback gates
the affected grant. Peer wall clocks and newly computed eight-hour windows are
never accepted as deadline evidence.

Prefer using the native clock domain from original pairing. When bridging an
already established endpoint in another continuous-clock domain, conversion must
be conservative: read native `t0`, await the provider's current continuous time
`p`, verify its exact endpoint/epoch, and import `t0 + (originalDeadline - p)` with
checked arithmetic. Time spent obtaining `p` can shorten, never extend, authority.
Reject an expired/rolled-back provider clock; recheck native expiry during import.
Store this conversion once for the grant, not at each recovery. A provider must
not use the later native `t1` plus an earlier sampled remaining duration.

Provider invalidation calls native suspend/revoke synchronously as part of the
local stop barrier, before waiting for socket/native cleanup. Those functions
linearize with worker admission: after returning, no new effect may begin under
that permit. Already pending native owners remain tracked until their real
completion/cleanup; immediate invalidation is not a promise that operating-system
release has completed. A late result cannot alter a later epoch or mint a permit.

## Threads, events and transport ownership

The proposed API uses a bounded pollable event queue, avoiding callbacks into a
Dart isolate on a native worker. ABI calls are thread-safe except concurrent
reading/releasing the same borrowed lease, which the host must serialize. Only
one event consumer drains a core. Polling is nonblocking and never calls user
code under a native lock. Callers may request stop/close while processing an
event; no callback-return deadlock is possible. The worker wait/change-sequence API in [MEDIA.md](MEDIA.md) avoids a busy loop
and lost wakeup; the thin plugin must implement its isolate integration.

SEND_REQUEST/SEND_SIGNAL events identify the exact provider, authorization and
one outstanding job. The provider resolves its sealed mapping, validates again,
and performs `SessionTransport.sendRequest/sendSignal`; it completes the job with
OK, CANCELLED or FAILED (other result values are invalid) only
after the actual send future has finished. Body bytes are borrowed from the event
lease, so copy them before releasing the event if a send outlives it. Completing
a job consumes that job once; duplicate, foreign and stale completions cannot
start work or free another owner. Successful transport send is not peer admission
or a presented frame.

Cancellation marks the job and requests host cancellation; a timer, event release
or cancellation request is not completion. The host must finish/drain the real
future before `provider_complete_send`, including cancelled jobs. A send failure
after sequence reservation still causes the existing transport to close, preventing
a sequence gap. Close cannot claim success while a provider future remains live.
A late completion only settles its original owner and cannot resurrect media.

Authoritative send/signal queue exhaustion fails the affected operation closed;
notification hints may coalesce as specified in MEDIA.md. Terminal/cancellation state
must remain queryable even when normal events are full; never silently drop the
only cancellation notification. The bounded job tables, queryable cancellation and change sequence in
[MEDIA.md](MEDIA.md) remain authoritative if event hints coalesce. Queued sends
must be claimed with `provider_begin_send` before host work; cancelling an unclaimed
job requires no transport completion. The existing limits (eight admissions per
grant, sixteen queued media signals per operation) are preserved.

## Frames and shutdown

Acquire creates a lease for an actual immutable frame of the requested operation
and media revision. No frame produces `SHM_EMPTY`; stopped/foreign revisions fail.
Borrowed CPU BGRA pixels remain readable until that lease is released, including
after stop/resize. Width/height, row stride and total buffer length must be checked
with overflow-safe arithmetic. `frame_read` does not consume a new decoded frame
or send a presentation receipt. The separate `main_presented` API is tied to actual paint; thumbnail reads
cannot substitute for it. `frame_consumed` records receiver texture consumption
without producing a presentation receipt.

A lease is not authorization to keep showing stopped media. The host removes
views on invalidation/revision change and releases leases when paint work finishes.
Already acquired memory cannot be force-freed. The current Mac store bounds each
size pool to three live buffers; draft 2 specifies cross-size/global budgets in [MEDIA.md](MEDIA.md). These
limits still require a real allocator and platform-pressure tests.
CPU mapping is a baseline draft; optional CVPixelBuffer/D3D interop needs explicit
format, device/thread, reference ownership and capability negotiation. No Flutter
texture ID is passed into the media core.

`authorization_cancel`, `operation_stop`, provider close and core close synchronously
gate future effects, then asynchronously drain actual native/provider owners.
Repeated stop/close is idempotent and retries failed cleanup. Cleanup failure
retains ownership and the media slot. `authorization_release` only drops a caller
reference; live operations retain their authority and are stopped with cancel.
A stop keeps the device grant unless the provider separately revokes it.

`query_close` distinguishes CONFIGURING, OPEN, CLOSING, CLEANUP_FAILED and CLOSED and exposes
outstanding work/leases. CLOSED requires zero provider jobs and zero live native
owners; already borrowed immutable frames/events may outlive it. Final core
release additionally requires zero external leases (including source snapshots)
and no active worker wait call, releases all child metadata,
and invalidates its IDs. A host must not use timeouts to unload the library with
live owners. New acquisitions/imports are refused after close, but read/release
of existing leases and original job completion remain allowed. Drain terminal
notifications or release them before final destruction; notifications are not a
second success criterion after their underlying state is already observable.

## Current checks and outstanding gates

Run `python3 tool/check_native_boundary.py` from this media API package. It checks
this header as C11 and C++17 for four 64-bit compiler targets (import/export
declarations checked separately) and asserts sizes,
alignment and key offsets, then runs a host layout probe. Cross-target checks are
syntax/layout only: they neither link Windows dependencies nor run on Windows
or an Intel Mac. The script does not load a media SDK or authenticate a grant.

Before freezing an ABI: settle extension/packaging and optional GPU interfaces,
implement provider mappings and the media operations, compare behavior with public
session/media vectors, test revocation/cancellation and bounded native ownership,
and validate complete non-Flutter media and cleanup with actual binaries.
Source headers compiling is necessary but insufficient for any of those gates.
