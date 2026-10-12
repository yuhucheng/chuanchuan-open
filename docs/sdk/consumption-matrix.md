# SDK source consumption matrix

The normal client still requires an SDK and uses its existing
`createPreviewEngine()` entry. Public media API **0.8.0** adds optional
`RemoteMediaProvider`, `RemoteMediaFactory`, `RemoteMediaLink` and
`RemoteVideoSession` contracts. Production remote UI/coordinator code imports
these public contracts, not concrete remote SDK types. PreviewEngine's original
source interface is unchanged; a null `unavailableReason` grants no remote support.

| Consumed implementation | Expected client behavior | Evidence scope |
| --- | --- | --- |
| Historical preview-only development SDK with the canonical API override | Same entry compiles; preview retained; remote unavailable | Actual historical SDK sources, two platform-selection entry tests, isolated analysis and Darwin Dart bundle |
| Preview-only engine without optional provider | No watch/cast controls; explicit unavailable explanation | Unit and device-panel widget tests; local preview callbacks retained |
| Public provider declaring cast only | Cast entry only; no watch/control/file inference | Public adapter and device-panel widget tests |
| Provider with zero video capacity | No remote action entry or incompatible factory link creation | Controller and device-panel tests |
| Provider with incompatible session protocol | No remote action entry or incompatible factory link creation | Controller and device-panel tests |
| Current normal Mac development SDK | The default factory composes preview and the public remote port through the same native core; one remote video slot, lookup does not capture | Native root/contract tests, normal Mac builds and independent generated-media checks; OS/GUI/two-device acceptance remains separate |
| Current normal Windows development SDK | Native preview plus the public remote port through Dart RTC; one shared remote video slot | Platform-selection and SDK regression tests; native Windows remote migration and actual Windows acceptance remain outstanding |
| Current internal Mac universal core and thin package | Same normal Mac entry; relocated SDK without private source access; native API 0.8.0 / draft 2 / protocol 2 / features 255, local and remote limits one each | Source-denied pub get, analysis, 334 client tests (one Windows-only skip), Mac Release build and embedded binary identity checks; application not launched |
| Authenticated request reaches preview-only client | Bounded unavailable reply; no source enumeration, capture or video slot | Real grant cryptography with controlled transport; close waits for pending replies |

The historical SDK test substitutes the canonical public API via the client's
existing override; it does not promise arbitrary old API package or native ABI
compatibility. Old source metadata may lack primary-display identity: the client
must not guess a primary screen from list order. Actual source selection and OS
permissions still apply. Platform-selection tests are not Windows native tests.
A Dart bundle is not a signed native app, and the historical probe does not test
screen capture or load historical native binaries.

The earlier source-consumption check recorded 241 client, 201 SDK and 35 API
passes; those are historical counts, not current full-suite totals. Checks use
Flutter 3.47.2 / Dart 3.13.2. As of 2026-10-13, the internal Mac candidate includes
preview, watch/cast, source change, recovery, CPU BGRA, frame progress and statistics.
The candidate's 22 independent binary checks use generated pixels and controlled
sources/providers; x86_64 checks use Rosetta, not Intel hardware. The source-denied
client result above belongs to the committed client snapshot tested with that
candidate, not arbitrary current working-tree edits.

The development source adapter and internal Mac binary/thin candidate are distinct
artifacts. A formally distributed SDK, stable ABI, complete Windows/macOS matrix,
final licenses, release source trust/signing and actual media acceptance remain
outstanding. No formal package download is available. Loaded capabilities decide
admission; a platform name or these recorded values cannot substitute for a query.
See the [native boundary status](../../packages/share_hub_media_api/native/draft/README.md)
and [Mac Release signing check](../validation/2026-10-13-release-hardening.md).
Internal candidate build evidence does not satisfy Developer ID, notarization,
application launch or two-device acceptance.

To repeat the isolated historical-source probe, supply a repository you are
already authorized to read and a full immutable commit containing the SDK package:

```sh
python3 tool/check_preview_sdk_consumption.py \
  --sdk-repository /path/to/authorized-sdk-repository \
  --sdk-revision <full-40-character-commit> \
  --flutter /path/to/flutter \
  --output /path/to/private-validation-result.json
```

This diagnostic tool alone reads the supplied SDK Git source. Normal client
builds do not invoke it or require that repository. It copies the selected SDK
only to a temporary tree, verifies those source bytes remain unchanged, and
removes that tree. It copies the current client `lib`, public `packages` and
build manifests, without management/project/design directories. Offline pub
resolution selects only the temporary canonical public API and SDK paths. The
same unchanged `lib/main.dart` produces the Dart bundle there. Result JSON stores
source identities, command output and the limited verification scope; use an
appropriate private destination when testing private source history.

The separate [inventory](inventory-verifier.md) and
[declaration compatibility](compatibility-preflight.md) tools concern proposed
binary-package metadata. Their results do not replace this source-consumption
matrix or make a formal package available. No alternate SDK-free product entry,
private implementation copy in the public checkout, or new download is introduced.
