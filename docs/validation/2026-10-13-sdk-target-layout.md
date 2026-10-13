# Development SDK target layout checks

The SDK configuration tool previously linked a package after checking only its
package name and Dart entry. A package missing the current desktop plugin hook
could therefore become the configured SDK before its platform build failed.

`configure_media_sdk.ps1` now checks the selected desktop target before creating
configuration directories, changing a link or running `pub get`. Windows requires
`windows/CMakeLists.txt`; Mac accepts the current podspec or Swift Package hook.
The target defaults to the local Windows/Mac host. Use `-TargetPlatform windows`
or `-TargetPlatform macos` for an explicit target; on another host, specify it.
A rejected replacement preserves the old SDK and project manifest.

PowerShell 7.6.6 on macOS arm64:

- The new missing-host-hook test failed against the old tool: it accepted the
  incomplete fixture and created a link.
- All 18 configuration scenarios passed after the fix, including Mac-only and
  Windows-only layouts, explicit target selection, a Swift-only Mac hook,
  directory masquerading as a hook, old SDK protection, non-ASCII/space paths,
  failed `pub get`, child-process interruption and retry.
- Read-only checks of actual SDK layouts accepted the current development SDK's
  Mac and Windows hooks, rejected the internal Mac-only thin candidate for a
  Windows target without creating `.local`, then accepted it for Mac. Links were
  created only in owned temporary projects and removed afterward. These checks
  used `-SkipPubGet`; no package hook or native media code was executed.

Hook-file presence is a limited development-layout diagnostic. It does not parse
all plugin metadata, authenticate package provenance, validate a native CPU/API/
ABI, install a formal binary package or prove Windows filesystem/build behavior.
The original directory/link protections remain. Final package format, signature
and cross-platform installation acceptance are still pending; no SDK download or
release is introduced. Client implementation and API versions are unchanged.
