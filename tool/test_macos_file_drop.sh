#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
flutter_root="${1:?Usage: bash tool/test_macos_file_drop.sh /absolute/path/to/flutter-sdk}"
framework="$flutter_root/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64"
test -d "$framework/FlutterMacOS.framework"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/share-hub-file-drop.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

swift test --package-path "$root/macos/Platform"
swiftc -F "$framework" -framework FlutterMacOS \
  -Xlinker -rpath -Xlinker "$framework" \
  "$root/macos/Platform/Sources/ShareHubPlatform/SelectedFileStore.swift" \
  "$root/macos/Platform/Sources/ShareHubPlatform/NativeFileDrop.swift" \
  "$root/macos/Runner/FileAccessBridge.swift" \
  "$root/tool/test_macos_file_drop.swift" -o "$temporary/bridge-probe"
"$temporary/bridge-probe"

# Compile the real AppKit overrides against Flutter's framework. Plugin
# registration is outside this check; ordinary application builds verify it.
cat > "$temporary/registration.swift" <<'SWIFT'
import FlutterMacOS
func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {}
SWIFT
swiftc -typecheck -F "$framework" \
  "$root/macos/Platform/Sources/ShareHubPlatform/"*.swift \
  "$root/macos/Runner/FileAccessBridge.swift" \
  "$root/macos/Runner/MainFlutterWindow.swift" "$temporary/registration.swift"
