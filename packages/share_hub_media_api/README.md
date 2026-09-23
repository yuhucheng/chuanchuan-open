# Share Hub Media API 0.4.0

Apache-2.0 公共契约。客户端和媒体实现共享此包，SDK 不依赖客户端 UI 或平台宿主。产品版本与 API 版本独立。

## Control contract (0.4.0)

The public entrypoint now exports version-1 `ControlStart`, geometry, input,
stage and clipboard messages, strict codecs, `ControlContext`, and pure input
and clipboard state helpers. A control request remains one authenticated
`SessionOperation.control` with the original grant deadline. `ControlContext`
checks the exact sealed authorization, requested capability and message sender;
it does not reserve a picture, negotiate native capability, present a frame,
grant OS permission or execute an input event. Watch/cast/file authority cannot
be upgraded by supplying a control body.

The target must bind a locally verified source and current presented geometry
before accepting input. Input sequence, inputEpoch, release-all and stop gates
are separate from clipboardEpoch. The pure input state bounds pending events to
64, coalesces only adjacent unsent pointer moves, limits admissions to 240/s
with burst 64, and records only successful native key/button results. An SDK
owner must stop new native admission synchronously, drain in-flight calls and
release only its own actually held keys/buttons before reporting cleanup.
`ControlInputState.invalidatePicture()` immediately seals the old geometry on
local source loss; cleanup must finish before a newer geometry can complete its
own presented-frame handshake and use a new input epoch.

Clipboard messages distinguish no plain-text format from an empty string and
carry at most 32 KiB of UTF-8 text in a 48 KiB body. Proposal/commit send
helpers use a 4/s, burst-2 budget. `ClipboardEchoGuard` matches OS change token
and SHA-256 text digest; the host must provide a real token, check the current
owner/epoch/settings at the final write boundary, and keep existing OS text
when sync stops. `text-input` submits text separately and never reads or
replaces the system clipboard.

This API version exposes contracts for SDK integration. It does not enable
client controls, advertise platform input/clipboard capabilities, or claim
Windows/macOS native execution or two-device acceptance. The product version
and existing preview/video behavior are unchanged.

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
`{"version":2,"kind":"video"}`. The admission layer checks this profile before
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
| `failed` / `ended` | Failure or terminal end; owned resources must be released | Cleanup already succeeded if release failed |

A cast starts with the current local primary source. Changing it to an explicitly
selected local window goes through pause/paused revision 0, resume/ready revision
1, then fresh SDP/ICE and a revision-1 presentation receipt. The window ID stays
local; it is not inserted into the remote intent payload. A revision-0 receipt
cannot mark the new window live. A watch uses the same exchange, with capture and
source selection on the responder, independent of who assigns the next revision.

Failure examples: adding `source` to `{"version":2,"kind":"video"}` is rejected;
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
| Old video profile 1 vs current profile 2 | Explicit rejection, no silent downgrade |

Executable examples: `test/remote_contract_test.dart` covers legacy engines,
budget, expiry and revocation; `test/video_session_messages_test.dart` covers
intent/termination/playback and remote source-field rejection;
`test/video_description_test.dart` covers descriptions, candidates, fingerprints
and revision isolation. Client tests additionally exercise directional rejection,
source selection, failure and first-frame deadlines. These tests do not claim
Windows/macOS or two-machine delivery acceptance.
