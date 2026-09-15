# Source origin

This repository was extracted on 2026-09-15 from the Share Hub desktop client at source revision `f5904ce`. It starts with a new Git history and contains selected source files, not the original repository history.

| Original client-relative location | Open location | Treatment |
| --- | --- | --- |
| `lib/features/devices`, `lib/features/transfers`, `lib/platform`, `lib/ui` | Same paths | Shared source moved; imports renamed to `share_hub_open` |
| `lib/features/preview/preview_controller.dart` | Same path | Shared lifecycle, extended to handle unavailable media |
| `lib/features/preview/preview_engine.dart` | Same path | Types/interface only; new unavailable implementation; original WebRTC adapter excluded |
| `test/*` | Same paths | Shared tests retained; WebRTC adapter tests excluded |
| `windows/platform`, `windows/tests`, `macos/Platform` | Same paths | Shared native source/test ownership moved here |
| Windows/macOS runners and tools | Same paths | Public hosts and channel bindings; separate application identity |
| `lib/main.dart` | Same path | New standalone entrypoint without a media engine |

Original private integration tests, media fixtures, operations, activation/backend material and deployment credentials are excluded. Runner scaffolds keep Flutter's upstream license; see THIRD_PARTY_NOTICES.md. The repository's new license does not apply to excluded source or prior private history.

Only existing implementations were extracted. Pairing, actual network file transfer, Android adapters and production SDK delivery are future work, not claimed as completed modules.
