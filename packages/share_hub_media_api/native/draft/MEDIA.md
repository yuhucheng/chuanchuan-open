# Media operations and bounded ownership — draft 2

These are proposed semantics for `share_hub_media_operations.h`, not implemented
SDK behavior. Read [the authorization/lifetime boundary](README.md) first. Draft
revision 2 replaces draft 1 declarations; neither has a compatibility promise.
The current Dart API and wire formats remain unchanged.

## Capability and source flow

After creating a core and sealing its providers, query capabilities and effective
limits. Capability bits describe the actual loaded implementation, never platform
names or roadmap plans. A preview-only implementation reports no watch/cast bits
and zero remote sessions. The current remote profile has at most one video session
across links/providers; local preview has a separate maximum of one. Thumbnail
borrowing adds neither. A host may not raise either limit by creating another core.
Unsupported functions return UNAVAILABLE before creating owners. The reported
media API tuple is the implemented contract version, not the draft revision;
peer operation negotiation must still match session protocol 2 and media profile
3/4. No remote control, file transfer, audio or multiple-video capability is added.

`sources` returns a task immediately. Actual platform enumeration runs under an
owned native job; the task eventually holds a source snapshot or an error. Poll
the task or wait for a core change, then take its result exactly once. A snapshot
owns its strings and source handles. Task read merely borrows an untaken result;
releasing that result is rejected until it has been taken. The snapshot remains
valid while owned by either its task or the caller. Releasing its owner invalidates
all borrowed strings/handles; copied source IDs are display/preferences data,
not handles that may be reconstructed as start authority.

Only select a source from the local snapshot. The host's initial default is the
sole positively identified primary screen; zero or multiple primaries fail rather
than choosing the first source. A start copies the selected identity/metadata
before returning, so releasing the snapshot afterward is safe. Core re-enumerates
and rechecks exact identity/type and required system permissions at allocation,
after awaited work and on resume/recovery. Never substitute another screen/window.
Enumeration does not silently truncate on a limit: return LIMIT without a partial
selectable snapshot. Names/IDs are local only and never inserted into signaling.
The native core does not request OS permissions implicitly or accept a caller's
`permissionGranted` boolean; permission explanation/prompting stays in the host.

## Start, task ownership and state

`preview_start` requires a selected local source, authorization=0 and recovery=0.
`remote_start` requires an imported authorization. On an ordinary profile-3 start,
the sharing endpoint provides its exact source selection; the receiving endpoint
must pass both selection fields as zero. Direction is derived from the sealed
request kind, grant role and watch/cast operation. Profile-4 start instead requires
a recovery handle and zero source selection, so caller input cannot replace the
retained source. Wrong combinations fail before an operation is accepted.

Acceptance atomically reserves operation/task IDs and the appropriate shared slot
before asynchronous work. OK returns both IDs even though startup is unfinished;
a synchronous error returns neither and leaves no owner. The operation is queryable
immediately and owns every late native result. A start task reports negotiation/
startup completion, never proof of first presentation. Its result_kind is NONE
because its operation ID was already returned. A failed asynchronous start leaves
the operation queryable until its actual resources are cleaned up; cleanup failure
retains the slot and reports CLEANUP_FAILED. No task/operation ID is reused. Authorization import is also bounded independently
of started operations; importing and abandoning permits cannot grow memory without
limit. The adapter reuses its existing exact-object mapping instead of importing
an identical grant/session ID twice.

Task states are PENDING, CANCELLING and FINISHED. result_status/kind/handle only
carry a result in FINISHED. A cancelled source task awaits real enumeration and
releases its unused snapshot. Cancelling a start/playback/change task gates the
whole affected operation, not merely its notification, and awaits actual late
owners. Task release while unfinished returns BUSY and does not cancel it.
`task_take_result` succeeds once for a successful snapshot result; repeated take
or take before completion fails. Task release frees an untaken result; it does
not stop an operation already returned by start.

Operation states are STARTING, WAITING_FIRST_FRAME, STREAMING, PAUSED,
TRANSITIONING, STOPPING, CLEANUP_FAILED and ENDED. An ordinary remote operation
enters STREAMING only after the receiving main view presents a current frame and
the sender receives the matching authenticated receipt. ICE connected, decoder
output and a successful task are insufficient. A local preview may report its
first valid captured image without remote presentation. Terminal failure_status
is a stable category, not a platform exception or raw source description.
`operation_release` requires ENDED with no live owners; it can discard caller
metadata while an internal recovery intent still retains the old lineage.

Pause/resume/change take expected_revision; stale concurrent commands fail rather
than apply to a later source. Only one transition task per operation is admitted.
Both endpoints may pause/resume remote media using the existing authenticated
playback handshake; only the sharing endpoint can change source. The original
request initiator allocates revisions after both sides quiesce old owners.
Changing source follows the same cleanup/ready transition and uses the locally
selected exact source. Geometry and frame queries for a retired revision fail.
Preview resume rechecks the selected source but has no network handshake.

A paused operation retains its original authorization and budget, allocates no
capture/peer/renderer until explicit resume, and continues deadline auditing.
Authorization loss, permission/source failure or explicit stop cannot be undone
by late transition completion. Repeated stop retries failed cleanup. An ended
operation cannot be restarted by resuming it or reusing its session ID.

## Recovery intent and admission

A recoverable transport suspension gates old media immediately. The core retains
the old operation's settled source, pause state, revision and original grant as
metadata while cleaning up its real owners. `recovery_retain` may create an intent
only from such an actually admitted operation. Explicit stop, core/provider close,
grant revocation, expired authority, ambiguous source-change/transition state or
absence of retained lineage rejects the request. The host cannot supply a prior
session, prior generation, pause bit, source or cleanup-success flag.

Intent deadline is the minimum of the original grant deadline, host's requested
absolute deadline and interruption time plus the effective recovery window.
It is anchored to the interruption, not to a late call to retain. The proposed
initial window is 45 seconds, matching the current client. It is not a grant
renewal. Retention uses bounded metadata, never a second media slot or capture.

`recovery_copy_request` copies the canonical existing profile-4 request derived
from native lineage. The host uses it when the real public provider creates a
fresh local request; for incoming recovery, it maps the actually authenticated
request from the peer. Reconstructed body bytes alone carry no authority. The
new authorization must reference the same native grant, same operation/direction,
same original deadline, a new session ID and a strictly newer transport generation.
Its authenticated recovery body must exactly match local lineage. Media-layer
generation/revision bounds remain those of the current profile (including its
31-bit recovery limits); a wider grant-generation field does not widen them.

Remote start claims an intent once, then waits for actual old cleanup to succeed
before acquiring the replacement media slot. Failure/cancellation consumes the
attempt and cancels the intent; it cannot be claimed again. The initiating SDK
sends the fresh request and waits for the authenticated `recovery-ready` bound to
that new operation before any native allocation. The receiver confirms only after
its own intent/cleanup checks. The peer-ready timeout is five seconds, separately
bounded by intent/grant deadlines. Timeout or lost confirmation sends end to any
peer already admitted, then drains actual work. A send/end failure does not justify
abandoning owned resources.

The new media revision starts at zero, with no inherited frame/statistics success.
Paused recovery stays paused without native allocation and still needs explicit
resume. A sharing endpoint rechecks native permission without prompting and the
exact saved source; a saved primary must still be the uniquely identified primary.
There is no fallback to the current primary or another window. Either user stop
or intent cancel permanently prevents late confirmation/start. Releasing an
unclaimed intent cancels it; after claim the operation retains the record, and
explicit intent cancel also gates that replacement operation.

## Geometry, measurements and presentation

Geometry is a copied value at the requested operation/revision: actual positive
width/height, source type, finite origin, finite positive scale and rotation in
0/90/180/270. It is neither input authority nor a remote-control implementation.
Before actual geometry exists the query returns EMPTY, not invented zero dimensions.
`operation_local_source` supplies an owned one-entry snapshot of the settled local
source for host labels/current selection; a receiver returns EMPTY, a source
transition returns BUSY. It does not enumerate, choose a replacement or expose the
other endpoint's screen/window identity.

Statistics and progress are snapshots with a native sample time and explicit
validity bits. Clear bit means unknown and its storage is zero; known zero is
allowed only where the existing Dart contract permits it. Unknown bits/reserved
fields are zero. Path comes from the actually selected ICE pair; bitrate comes
from consecutive video RTP counters; dimensions are an observed pair, never
configured dimensions. Reads neither fabricate samples nor refresh their times.
A new revision clears prior metrics. Preview has no transport statistics.

Progress scopes LOCAL/PEER remain separate. PEER is populated only from the
existing authenticated, correlated frame-probe protocol and aged for local query
latency, never from an arbitrary host sample. A reply timeout returns unknown
with no new evidence. Stage specifies capture or receiver even if all validity
bits are clear. After a valid sample, active/image sequence are known; zero image
sequence has unknown age. Capture also knows output sequence/source-unchanged and
never consumed sequence; receiver knows consumed sequence and never output/idle.
In a valid sample every positive sequence requires a known matching age, and
every zero sequence requires unknown age. An invalid/future/overflowing timestamp
invalidates the whole coherent progress sample (valid_fields=0, with its stage
still known), rather than returning a positive sequence with a missing age.
Output sequence cannot
trail image sequence, consumed cannot exceed decoded, and their ages preserve
the existing ordering. Ages/counters obey the current signed-64-bit domain and
invalid/overflowing evidence becomes unknown rather than wraparound. A cached
snapshot ages from its sample time; repeated read/paint is not a new frame.

`frame_consumed` records current receiver texture consumption using the lease's
actual sequence and original timestamp. Repainting or consuming an older lease
cannot freshen time or regress a newer consumed sequence. It sends no receipt.
`main_presented` is called by the main display adapter only after that exact frame
participates in paint. It verifies a current receiving operation and revision;
its dimensions come from the frame. It issues the existing authenticated receipt
once per revision. Thumbnail/offscreen reads never call it. Neither API claims to
prove that a human looked at the picture; both are trusted presentation-adapter
observations and must not be invoked by UI success buttons.

## Bounds, queue saturation and wakeup

Effective limits are immutable after create. Proposed initial ceilings are:

| Resource | Ceiling | Accounting / exhaustion |
| --- | ---: | --- |
| Providers / active grants | 8 / 8 | Register/import rejects with LIMIT; suspended grants still count |
| Live operation metadata / task handles | 64 core, 8 per grant / 128 tasks | Pending, stopped-but-unreleased and cleanup-failed entries count |
| Live authorization handles | 128 core | Unstarted, externally retained and operation-held references count |
| Outstanding send jobs | 8 per grant | Queued/running/cancelling count until settled |
| Incoming media signals | 16 per operation, 64 MiB core bytes | Copied before return; overflow fails that operation closed |
| Event records / acquired event leases | 128 / 128 | Shared 8 MiB body budget includes queued and leased payloads |
| Source snapshots / entries per snapshot | 8 / 1,024 | Snapshot metadata/string bytes capped at 4 MiB each; no truncation |
| Recovery intents | 8 | Claimed/cancelled-but-retained metadata counts until released |
| SDK-owned immutable frame buffers / leases | 6 / 32 | Includes retired-size storage until all owners release |
| Immutable frame storage bytes | 512 MiB | Includes current and retained old-size buffers/pool storage |
| Grant/operation replay history | 65,536 entries each | Fail closed at limit, no evict-to-admit behavior |
| Recovery window / peer ready wait | 45 s / 5 s | Both capped by original authority and cancellation |

Replay tombstones retain only bounded identity/session keys and policy identity,
not old bodies, SDP, pixel storage or transport secrets. Live payloads count toward
their respective budgets and are released when their actual owners finish.

Frame limits may be lowered through create options (zero selects defaults), never
raised beyond the implementation's supported ceilings. They bound leaseable SDK
snapshots/pools, not decoder, GPU driver or total process memory. Validate dimensions,
row stride and all multiplication/addition before reservation. Reserve bytes/count
atomically before allocation; roll back on failure; retained old-size buffers stay
charged. A frame bigger than the whole configured budget fails with LIMIT; temporary
pool pressure drops the new snapshot while preserving true decoded/captured progress.
Never overwrite borrowed pixels. A new revision cannot expose an old revision's
cached frame even if the new allocation has to wait for consumer release.

Events are hints backed by durable operation/task/send tables, not the sole source
of truth. State hints may coalesce per owner when saturated. Creating a transport
job requires a reserved bounded job-table entry; its payload remains discoverable
through `provider_next_send`/`provider_send_event` even if its hint was coalesced.
Event read/release does not settle a job. A normal hint consuming the last event
slot cannot erase cancellation: the job/operation state and core change sequence
still change, independently of queue capacity.

The host begins a QUEUED send exactly once before calling its real transport.
`provider_begin_send` checks authority and transitions it to RUNNING atomically.
Cancellation before begin settles it without host work; a late event then fails
begin and must not send. Cancellation of RUNNING changes it to CANCEL_REQUESTED;
the host still owes completion after actual send/cancellation drains. Enumerating
by increasing job ID and restarting after a sequence change discovers durable
outstanding work. Removing a settled job cannot affect any other ID.

The core's change sequence increments on every queryable state change, including
frame availability and cancellation, even with no free event slot. A host reads
sequence S, drains events/queries tables, then `wait_change(S, timeout)` on a worker.
The wait compares and arms under the same lock, so a change during drain is not
lost. Timeout returns EMPTY/current sequence; changed state returns OK/new sequence.
Zero timeout only polls. Waiters are bounded to one per core; a second gets BUSY.
Close wakes the waiter; final release returns BUSY until the wait call exits.
Sequence exhaustion gates the core with LIMIT; it never wraps and reuses S.
The thin Flutter bridge may translate this into an isolate wakeup without running
a blocking wait on the UI thread. No native callbacks enter Dart under a lock.

## Remaining implementation/review gates

The declarations cover the intended CPU-frame v0.1.0 lifecycle, but no implementation
or performance promise exists. GPU interop remains an optional capability to design
and validate; it cannot be silently substituted with unsafe borrowed platform objects.
Package layout, ABI extension/version negotiation, stable error mapping, provider
implementation, target tools/minimum OS and actual media/cleanup acceptance still
must be resolved before a stable interface or binary is announced. Queue, memory
and timeout values require actual load/platform tests; compiler layouts do not
validate behavior, rendering latency or supported resolution.
