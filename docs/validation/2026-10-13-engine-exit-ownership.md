# Explicit desktop exit waits for the SDK engine owner

Date: 2026-10-13. Product 0.1.0, client/SDK 0.1.0-dev.1, public media API 0.8.0.

The desktop exit transaction originally awaited preview stop and remote links,
then approved native teardown. PreviewEngine.dispose only ran in the widget's
asynchronous fallback. An SDK entry may own resources beyond the stopped
preview, so successful stop did not prove the complete media engine had closed.
The first fix added an explicit disposal barrier and terminal admission gate.

A follow-up found that serial stop-before-dispose could make its own cancelling
operation unreachable: controller stop awaits a pending source read, while SDK
root disposal is responsible for cancelling catalogue queries. Exit now gates
admission before notifications, starts both preview stop and engine disposal,
and joins both actual results together with remote/transport/auxiliary cleanup.
Only then may native picker, file, discovery and exit teardown proceed. Widget
fallback uses the same combined owner instead of serializing the deadlock again.

Disposal failure preserves the owner and refuses exit; timeout retry joins the
same pending disposal. Early engine completion cannot bypass remaining remote
cleanup. Source results/first-frame callbacks after exit are ignored, and new
queries/start/selection remain forbidden even after failed exit. Capture-release
errors keep their existing actionable message. Once successful disposal and
stop settle, later widget teardown does not invoke the backend again.

The new pending-query regression first confirms an admitted unresolved source
request, then fails at the unreachable disposal call against the committed first
fix. It passes with the combined owner: disposal settles the query, its late
source list is discarded, and exit waits for all owners. The initial test setup
omitted permission and was corrected before recording this red/green result.
Controlled desktop/preview/SDK-public-port/widget checks: 51 passed. Complete
client worktree: 333 passed, 1 Windows-only test skipped. Flutter analyze passed
and the ordinary Mac Debug app built; it was not launched. No OS enumeration or
capture, real GUI/background, Windows build or two-device acceptance ran.

The worktree retains other-session device-name/discovery/platform edits; full
results are observations, not a reproducible release composition. Windows
should retest stop/quit and its assigned background matrix after synchronizing.
Platform host code, SDK implementation, public API/ABI and version are unchanged.
