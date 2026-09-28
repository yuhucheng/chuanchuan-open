#!/bin/zsh
# Runs the isolated tray-state acceptance entry and restores the normal target.
# It injects a control-active flag; it does not execute SDK input.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER_BIN:-$HOME/development/flutter/bin/flutter}"
[[ -x "$FLUTTER" ]] || { echo "Flutter unavailable: $FLUTTER" >&2; exit 1; }
export PATH="$(dirname "$FLUTTER"):$PATH"
cd "$REPO"

DD="$REPO/build/control-tray-dd"
BUILT="$DD/Build/Products/Debug/Share Hub.app"
APP="$REPO/build/control-tray/Share Hub Control Tray Probe.app"
PRODUCT="$REPO/build/macos/Build/Products/Debug/Share Hub.app"
REPORT_DIR="$(mktemp -d /tmp/chuan-control-tray.XXXXXX)"
PRODUCT_BEFORE="$(stat -f %m "$PRODUCT/Contents/MacOS/Share Hub" 2>/dev/null || echo missing)"

restore_target() {
  "$FLUTTER" build macos --debug --no-pub --config-only >/dev/null 2>&1 || true
}
trap restore_target EXIT

"$FLUTTER" build macos --debug --no-pub --config-only \
  --target=lib/dev/control_tray_acceptance_main.dart >/dev/null
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Debug -derivedDataPath "$DD" \
  -clonedSourcePackagesDirPath "$REPO/build/macos/SourcePackages" \
  build > "$REPORT_DIR/build.log" 2>&1 || {
    tail -25 "$REPORT_DIR/build.log" >&2
    exit 1
  }
[[ -d "$BUILT" ]] || { echo "Acceptance bundle missing" >&2; exit 1; }
mkdir -p "$(dirname "$APP")"
ditto "$BUILT" "$APP"

open -n -W --stdout "$REPORT_DIR/stdout.log" \
  --stderr "$REPORT_DIR/stderr.log" "$APP"
grep 'TRAY_PROBE_JSON=' "$REPORT_DIR/stdout.log" | tail -1 \
  | sed 's/^TRAY_PROBE_JSON=//' > "$REPORT_DIR/report.json"
python3 - "$REPORT_DIR/report.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
if report.get('passed') is not True:
    raise SystemExit('Mac control tray probe failed')
PY

PRODUCT_AFTER="$(stat -f %m "$PRODUCT/Contents/MacOS/Share Hub" 2>/dev/null || echo missing)"
[[ "$PRODUCT_BEFORE" == "$PRODUCT_AFTER" ]] || {
  echo "Normal Mac app was modified by acceptance build" >&2
  exit 1
}
"$FLUTTER" build macos --debug --no-pub --config-only >/dev/null
grep -q 'FLUTTER_TARGET=lib/main.dart' \
  macos/Flutter/ephemeral/flutter_export_environment.sh || {
    echo "Normal Mac target was not restored" >&2
    exit 1
  }
echo "Mac control tray probe passed; report: $REPORT_DIR/report.json"
