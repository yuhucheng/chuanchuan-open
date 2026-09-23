# Share Hub Media API 0.8.0

Version 0.8.0 adds optional `RemoteMediaProvider`, `RemoteMediaFactory`,
`RemoteMediaLink` and `RemoteVideoSession` contracts. The existing SDK preview
factory remains the entry point: the client discovers remote composition through
public types and does not require concrete remote SDK exports. Preview-only
implementations keep working and declare no remote operations. Obtaining the
factory creates no capture or peer resources. The client supplies the same verified
transport, shared process budget and local source/recovery policy to every link.
Closing a link waits for media cleanup without revoking the trusted connection.
This is a Dart source contract, not a stable native ABI or binary release.

Version 0.7.0 added explicit media-recovery lineage and local admission; ordinary
requests remain profile 3, recovery uses profile 4. Old SDKs reject recovery
rather than treating it as a fresh capture. Preview/session interfaces remain
source compatible. Two-device recovery acceptance is still unfinished; this API
does not restore video by itself.

Version 0.6.0 added `VideoFrameProbe` and `peerFrameProgress` alongside local
`frameProgress`. Exhaustive event consumers must handle both kinds. PreviewEngine
and session method signatures remain unchanged. Ordinary video request intent
uses **profile 3**, requiring frame-probe parsing; older request profiles are rejected
before capture or transmission. There is no silent downgrade. The outer
session protocol 2, SDP profile 2, existing ICE/presentation/playback messages and
grant lifetime are unchanged. Both endpoints must use compatible media builds.

`frameProbe` version 1 carries exactly `version`, `kind`, `revision`, `probe`
(positive 31-bit integer) and `progress` (null query, typed sample reply). It is
accepted only through an authenticated signal for the exact operation/slot,
current revision and opposite endpoint's assigned stage. Samples contain only
stage, active, sequence/age, outputSequence/outputAge/sourceUnchanged and
consumedSequence/consumedFrameAge. Ages are integer microseconds; unknown is all
null except stage. No source paths, frame contents or authority are carried.
The maximum body is 1024 bytes. One outstanding probe per direction is matched
once; expired/duplicate answers cannot refresh evidence. Peer ages include the
whole local sleep-inclusive round trip, not just time since receipt. This does
not establish a first-frame receipt or matching frame identity across RTP.

Frame observations are strictly local: capture output (including idle callbacks)
is distinct from captured images, and decoded frames from texture consumption.
They neither establish first presentation nor prove end-to-end liveness. Unknown
samples have null activity/counters/ages, whereas zero counters mean a valid
native observation with no image yet. The constructor rejects inconsistent stage,
count and age combinations. Cache redraw does not advance image sequences. Ages
include sleep and query latency and can only increase while retaining a sample.
Pause, stop, invalidation and replacement media revisions discard old samples.
Polling timeout cannot authorize capture or enqueue unbounded native calls.

Apache-2.0 公共契约。客户端和媒体实现共享此包，SDK 不依赖客户端 UI 或平台宿主。产品版本与 API 版本独立。

`CaptureSource`、`CaptureSourceType` 和 `PreviewEngine` 保持源码兼容。`unavailableReason == null` 只表示存在媒体实现，不代表录屏权限、远端连接或真实首帧。

新增可选 `RemoteMediaEngine`、版本与能力协商、来源几何、会话事件和共享画面预算。旧引擎经 `capabilitiesOf()` 得到仅本地预览能力；远端可用性仍以实际 SDK 入口和能力声明为准。协议版本不兼容时远端能力为空，不回退假成功。

公共纯 Dart 包 `share_hub_session_api` 经本包导出，统一提供方向授权、认证恢复和可验证消息。连接服务在可信握手后登记 `GrantRegistry`，SDK 以该 registry 校验请求，不能从 UI 布尔值、自签证明或任意来源路径推导授权。完整协议见 [会话契约](../share_hub_session_api/README.md)。

`MediaSessionBudget` 跨观看、投屏、带画面控制共用上限；首版协商一条画面，第二条返回 `busy` 而不抢占。缩略图复用原 slot。停止后 ID 不能复用，新的操作 ID 可使用仍有效的连接授权；原生清理失败时不能提前释放预算。接口能表达未来多会话，但当前 SDK 不因此宣称支持。

`SourceGeometry` 记录分享端实际选源与几何修订；来源与系统权限必须由执行方核验，不能让未验证请求任意选择屏幕。`MediaSessionEvent` 绑定 grantId、sessionId、transportGeneration，区分传输就绪、等待首帧和实际首帧；未测统计为 null。恢复后旧事件被 slot 拒绝。SDK 必须订阅授权失效信号并在异步操作后重新检查。

运行 `flutter test` 与 `flutter analyze` 验证契约。此包没有远端媒体引擎或正式二进制 ABI；协议/模拟测试不替代实机双机验收。

CaptureSource.isPrimary 是可选的原生主屏标记，旧引擎默认为 false，不能据此猜测列表首项为主屏。客户端在明确采集动作时重新枚举，只有唯一原生主屏才可自动选择。macOS SDK 当前提供此标记与启动前复核；Windows 适配仍需补齐，当前必须明确选源。

### 双端资源授权

`RemoteMediaEngine.startRemote(VerifiedSessionMessage)` 接收已经认证解码的对端请求。可选的 `BidirectionalRemoteMediaEngine.startOutgoing(LocalSessionRequest)` 支持发起端：请求必须由进程内有效 grant 的 `authorizeLocal` 生成，仍受方向、到期和当前传输代次约束。两个类型均继承不可由消费者实现的 `SessionAuthorization`，共用 `MediaSessionBudget`；原 PreviewEngine 和仅入站接口保持兼容。

本地请求不是对端确认，不允许用它宣布网络已通或远端首帧已呈现。两端注册表不能互相替代，来源、系统权限、媒体指纹、信令回复和真实帧仍由实际实现验证。该接口声明不等于正式 SDK 或跨平台远端验收已完成。

## Authenticated video description profile (development)

`VideoSessionDescription` defines description profile 2 inside the existing
version-2 authenticated operation signal. Its JSON body has exactly `version`,
`kind: description`, `revision`, `type: offer|answer`, `sdp`, and the uppercase colon-separated
SHA-256 `fingerprint` extracted from native SDP. SDP is limited to 48 KiB; the JSON-escaped body is separately checked against
the authenticated transport's 64 KiB limit. The profile permits
one non-rejected video m-section with DTLS-SRTP, RTCP multiplexing, one MID and
an explicit sendonly/recvonly direction. Audio, application/data, extra video,
sendrecv, conflicting fingerprints and unsupported descriptions fail closed.

`receive` requires a `VerifiedSessionSignal` for the **same authorization object**
as a live `MediaSessionSlot`. The owner chooses the expected offer/answer and
peer direction from the authorized operation, never from an untrusted role field.
Watch means the requester receives; cast means the requester sends. Native DTLS
must additionally verify the certificate against the authenticated SDP fingerprint;
matching two strings alone is not a completed DTLS or identity handshake.

SDP acceptance does not establish transport readiness or prove rendering. ICE,
source geometry, receiver presentation acknowledgement, pause/resume and runtime
resource management remain separate execution responsibilities. This initial
profile does not enable or advertise a remote engine by itself.

The same description profile now requires one unambiguous ICE username fragment.
`VideoIceCandidate` encodes candidate profile 2 (`version`, `kind: candidate`,
`revision`, `candidate`, `mid`, `mLineIndex`). Only m-line 0 and component 1 are accepted for
the single RTCP-multiplexed video. Candidate text is bounded to 2048 ASCII bytes,
with a 4096-byte encoded input limit. UDP/TCP, IPv4/IPv6 and mDNS names are accepted;
malformed fields and invalid ports are rejected. MID and any candidate `ufrag`
must match the authenticated remote description before native application.
An empty candidate is an authenticated end marker; it does not itself prove ICE
connectivity. Candidate payloads contain network addresses and must not be logged.

SDK candidate application is serialized, with at most 16 queued operations,
64 pre-description candidates and 256 candidates per media session. Candidates
wait for validated native remote-description completion; cancellation, revocation,
slot release and negotiation failure prevent further application. This development
profile still requires matching implementations at both endpoints.

`VideoPresentationReceipt` is profile 1 (`kind: presented`, `revision`, `width`,
`height`, plus `version`) within the authenticated operation signal. Inputs are
bounded to 512 bytes and integer dimensions 1–65535; those wire bounds are not a
claim about supported display sizes. The current initial media revision is 0.
Resume revisions are coordinated and increase separately from
the grant transport generation; an old revision cannot acknowledge a new image.
The receipt does not renew the grant or authorize another operation.

The receiver produces a receipt only after native nonzero frame evidence and an
actual Flutter paint of that renderer, not merely a mounted/Offstage view. The
sender consumes it through the same live `MediaSessionSlot` and requires native
transport readiness before its firstFrame event. Repeated current receipts are
idempotent. Local capture or transport readiness without a receipt times out; a
receipt is the authenticated peer's report, not independent remote attestation.
## Video operation intent and termination

`VideoSessionRequest.body` is the authenticated operation payload
`{"version":3,"kind":"video"}`. The admission layer checks this profile before
allocating native media. `watch` and `cast` remain distinct grant operations;
neither payload can select the remote endpoint's source or grant reverse access.
Unknown versions, extra source fields and non-video operations fail closed.

`VideoSessionEnd` carries an authenticated `ended` signal with one fixed reason:
`stopped`, `busy`, `unavailable` or `failed`. Receivers verify the exact current
operation authority, including before native allocation. Ending media preserves
the device connection/grant. An end response is terminal and must not be echoed.
Sender-owned source changes use the pause/resume revision handshake below.

## Pause and resume

`VideoPlaybackMessage` is a bounded 512-byte authenticated control payload with
exactly `version: 1`, `kind: playback`, `action`, and integer `revision` (0 through
2^31−1). Actions are `pause`, `paused`, `resumeRequest`, `resume`, and `ready`.
Either endpoint can pause; both stop the current native resources and send
`paused` only after cleanup. The shared operation slot remains reserved.

After both acknowledgements, the original operation initiator allocates the next
revision with `resume`; its peer requests this via `resumeRequest`. Both validate
the original grant and same local source before allocating fresh native resources,
then exchange `ready`. Only then does the initiator publish a new offer. This
initiator role does not change which endpoint captures in watch versus cast.
Crossed requests converge to one revision; missing acknowledgement/startup times
out, and explicit stop cannot resume. Paused operations still audit grant expiry.

All SDP, ICE, presentation receipts and `MediaSessionEvent.mediaRevision` are
bound to the revision. Old video messages cannot affect a new peer or acknowledge
a new image. Stop remains terminal across every revision of the operation.
Development video intent/SDP/ICE profile 1 is rejected rather than silently
downgraded; both endpoints must update together. The outer authorization protocol,
grant type/duration and eight-hour current product policy are unchanged.

## Sender-owned source selection (0.3.0)

`SourceSelectableMediaSession` is an optional extension of `RemoteMediaSession`;
existing preview engines and sessions need not implement it. `localSource` exposes
only this endpoint's current capture source (null on receivers).
`changeSource(CaptureSource)` is permitted only on the endpoint actually sending:
the cast initiator or the watch responder. It never requests a broader source on
the other device, and never adds reverse authorization.

The implementation quiesces the old revision through pause/paused, then starts
the exact selected local source through resume/ready with a new media revision,
retaining the same grant, deadline and budget. Native source identity and system
permission are rechecked; missing sources fail without fallback. Concurrent
changes are rejected, and stop or revoked authorization wins over late work.
`sourceChanged` signals selection, not presentation: each new revision must get
its own first-frame receipt before being shown as live. No geometry or quality
metrics are invented. The public API addition does not change wire payloads,
product version, grant duration or formal SDK delivery status.

## Client state and compatibility examples

| Evidence/event | Meaning available to a client | Must not imply |
| --- | --- | --- |
| Verified connection and live grant | Directional operations may be requested | A captured or received frame |
| `connecting` | Authorization/media negotiation is pending | Transport ready |
| `transportReady` | Native media transport is ready | Peer has presented the source |
| `waitingFirstFrame` | Waiting for this revision's presentation evidence | Old revision is live |
| `firstFrame` | This revision has presentation evidence | Continuous frame updates forever |
| `paused` | Media is quiesced; budget and original grant remain | A last frame is live |
| `sourceChanged` | Sender applied a new local source | Peer has presented the new source |
| `statistics` | Latest local path/RTT/video bitrate observation | First frame, continuous rendering or end-to-end video delay |
| `failed` / `ended` | Failure or terminal end; owned resources must be released | Cleanup already succeeded if release failed |

A cast starts with the current local primary source. Changing it to an explicitly
selected local window goes through pause/paused revision 0, resume/ready revision
1, then fresh SDP/ICE and a revision-1 presentation receipt. The window ID stays
local; it is not inserted into the remote intent payload. A revision-0 receipt
cannot mark the new window live. A watch uses the same exchange, with capture and
source selection on the responder, independent of who assigns the next revision.

Failure examples: adding `source` to `{"version":3,"kind":"video"}` is rejected;
a second budget reservation returns `busy`; reverse local operation authority
returns `direction_denied`; a receiver invoking `changeSource` returns
`invalid_media_role`; a disappeared local source is refused instead of selecting
the first available display. Client selection failures before switching retain
the existing explicit share; native failures after quiescence end the operation.
Current client policy bounds presentation waiting to 15 seconds per revision;
that timeout is an implementation policy, not a new wire or performance promise.

| Consumer/implementation | Compatibility |
| --- | --- |
| Legacy `PreviewEngine` | Source compatible, local preview only; never inferred remote capability |
| Existing `RemoteMediaSession` without source extension | Pause/resume/stop remain available; source selection unavailable |
| API 0.3.0 sender implementing `SourceSelectableMediaSession` | Exact local selection via the existing media revision handshake |
| API 0.3.0 receiver | No local capture source selection, even if its session class implements the extension |
| API 0.4.0 diagnostics consumer | Optional `transportPath`; older producers keep null, existing interfaces remain source compatible |
| Old video request profiles 1/2 vs current request profile 3 | Explicit rejection before capture, no silent downgrade; SDP/ICE remain profile 2 |

Executable examples: `test/remote_contract_test.dart` covers legacy engines,
budget, expiry and revocation; `test/video_session_messages_test.dart` covers
intent/termination/playback and remote source-field rejection;
`test/video_description_test.dart` covers descriptions, candidates, fingerprints
and revision isolation. Client tests additionally exercise directional rejection,
source selection, failure and first-frame deadlines. These tests do not claim
Windows/macOS or two-machine delivery acceptance.

## Sanitized local statistics (0.4.0)

`MediaSessionEvent.transportPath` is an optional `MediaTransportPath` (`direct`
or `relay`). It describes the actual selected ICE candidate pair: either relay
candidate means relay; both known non-relay candidates mean direct. A configured
TURN server, a nominated but unselected candidate or an unresolved report does
not establish a path. Addresses, ports, candidate text and credentials are not
part of this public diagnostic event.

`roundTripTime` is the selected ICE pair's latest round-trip measurement, not
one-way screen latency. `bitsPerSecond` is local video RTP payload throughput
over consecutive native samples: outgoing bytes on the sender, incoming bytes
on the receiver. It is neither available bandwidth nor remote presentation
evidence. Missing, ambiguous, reset or invalid observations remain null; a
measured zero is valid. No frames-per-second or liveness is inferred from idle
traffic, since a static desktop may produce no new encoded frames.

Each sample replaces the previous one, including null fields, and belongs to
its exact media revision. Consumers must clear old samples on pause, replacement
or stop, and expire stale samples. The current client expires them after six
seconds without a new sample. These are local diagnostics; the addition does
not change video wire profiles, authorization, product version or SDK delivery
status.

Optional `frameWidth` and `frameHeight` form a pair of actual local encoded or
decoded video dimensions from RTP statistics. Both stay null when missing,
invalid or ambiguous; valid values are 1–65535, matching the presentation
receipt's encoding bounds without claiming those resolutions are supported.
They do not replace `SourceGeometry`, describe input coordinates or prove a
fresh frame. No dimensions are inferred from a chosen screen's nominal size.

## Media recovery admission (0.7.0)

Normal requests still use `VideoSessionRequest.body` (profile 3). Recovery uses
`VideoSessionRequest.recoveryBody(request)`: exactly `version: 4`, `kind: "video"`
and `recovery`, whose four fields are `session` (old operation ID, 1–128 UTF-8
bytes), `generation` (old positive 31-bit transport generation), `revision`
(old nonnegative 31-bit media revision), and `paused` (boolean). Total request
body remains at most 512 bytes. Extra fields and non-integer counters fail.
The new authorization must have a different operation ID and newer transport
generation. No source ID/name, new permission, grant or deadline crosses this
boundary. The outer session protocol and grant policy are unchanged.

Each endpoint records `VideoRecoveryIntent` only from its actual admitted
picture, retaining its sealed old authorization, exact local source (sender
only), media revision, pause state, and real cleanup Future. A matching fresh
sealed authorization can claim it only once. The exact original grant object,
operation, role, old ID/generations, pause state and encoded request must match;
cleanup must succeed first. Cancel is irreversible and invalidates pending and
minted admissions; a new grant with the same device names cannot replace it.
The controller must cancel retained intents on explicit stop, source/permission
loss, exit, recovery abandonment, or grant revocation. It must not persist them.

The SDK rejects recovery unless the process supplies the local intent claim
callback. It reserves the shared budget after that claim. The initiating SDK
sends the new request and waits for an authenticated `recovery-ready` signal
(exactly `{"version":1,"kind":"recovery-ready"}`) for that new operation before
constructing native media. `VideoRecoveryAdmission.confirmPeer` verifies this
signal; `requireStart` prevents a caller from treating local intent as peer
confirmation. Duplicate/foreign/malformed confirmations fail. The SDK's default
wait is five seconds; refusal, timeout or close ends the new operation and
notifies any peer resources already started. Pending platform/native cleanup is
still owned until it actually settles.

A paused recovery creates a new paused operation with no native peer/capture/renderer
allocation. Either endpoint may later use the existing explicit playback resume
handshake. Sending uses the saved exact source, never the primary resolver;
native source and permission checks run again. A new operation begins with
media revision zero and fresh frame evidence, independent of its recorded old
revision. Recovery confirmation is not a channel/first-frame/health receipt.

The production client connects retained-intent lifetime, cancellation and source
checks through an optional recovery factory. Its default recovery window is 45
seconds, checked against the continuous clock after asynchronous source lookup.
It rechecks recording permission without prompting and rejects a missing source
or changed primary identity. Waiting has a stop action; exit awaits pending work.
Protocol, SDK simulated-media and client TCP tests do not establish actual screen
capture, platform sleep, two-device or relay acceptance.

### Native boundary draft

The [native boundary review draft](native/draft/README.md) proposes C declarations
for trusted provider imports, sources/start/playback/recovery, immutable frame
leases, presentation/measurements and bounded asynchronous ownership.
It is unimplemented and is not part of the exported Dart API or a released ABI.
`python3 tool/check_native_boundary.py` checks declaration/layout compatibility;
it does not load an SDK or prove native authorization or media behavior.

The [package-layout proposal](native/draft/PACKAGING.md) describes native-only and
self-contained thin-Flutter artifacts, public API snapshots and exact-byte
metadata. Its examples are non-installable. Run
`python3 tool/check_sdk_package_layout.py --flutter /path/to/flutter` to check the
public dependency graph offline with an SDK fixture; it does not test real SDK
binaries, signing or installation.
