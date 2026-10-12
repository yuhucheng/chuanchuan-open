# Explicit desktop exit waits for the SDK engine owner

Date: 2026-10-13. Product 0.1.0, client/SDK 0.1.0-dev.1, public media API 0.8.0.

The desktop exit transaction previously awaited preview stop and remote links,
then approved native teardown. PreviewEngine.dispose only ran in the widget's
asynchronous fallback. An SDK entry may own resources beyond the stopped
preview, so successful stop did not prove the complete media engine had closed.

The preview controller now closes new source/start admission before exit
notifications can reenter it. After actual remote/local stop and connection
cleanup, desktop exit waits for dispose-media-engine before picker, file,
discovery and native exit teardown. Disposal failure preserves the owner and
refuses exit; timeout retry joins the same pending disposal. Once disposal
succeeds, later widget teardown does not invoke the backend again. Reopening
admission after an attempted process exit remains forbidden.

Three controlled regression cases failed before the change and pass afterward:
remote-before-engine cleanup with immediate admission closure, disposal failure
and explicit retry, and timeout retry without a second backend disposal.
Desktop/preview/public lifecycle checks: 44 passed. Complete client worktree:
332 passed, 1 Windows-only test skipped. Flutter analyze passed and the ordinary
Mac Debug app built; the app was not launched. No OS enumeration/capture,
real GUI/background, Windows build or two-device acceptance ran.

The tested worktree retains other-session device-name/discovery/platform edits;
full-worktree results are observations, not a reproducible release composition.
This changes shared Dart exit behavior; Windows should retest stop/quit and its
assigned real background matrix after synchronizing. Platform host code, SDK
implementation, public API/ABI and the version are unchanged.
