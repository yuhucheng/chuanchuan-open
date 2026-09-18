#!/bin/zsh
# macOS real-client acceptance runner for the desktop preview work.
#
# The acceptance entry (lib/dev/macos_acceptance_main.dart) is a development
# target, never part of the shipped client. It must be launched through
# LaunchServices, because a sandboxed app spawned directly by another sandboxed
# process cannot initialise its App Sandbox container (SIGTRAP in
# `_libsecinit_appsandbox`).
#
# The acceptance build deliberately does NOT go through
# `flutter build macos --target=...`, because that writes to the same path as a
# product build (build/macos/Build/Products/Debug/Share Hub.app) and silently
# replaces the product app with the development entry. Instead the Dart target
# is written with `--config-only` and xcodebuild compiles it into its own
# DerivedData (build/acceptance-dd). The app is then copied to
# build/acceptance/Share Hub Acceptance.app and launched from there, so the
# product app is never touched. The bundle identifier is kept identical on
# purpose: the App Sandbox container and the Screen Recording grant are keyed by
# it, so acceptance keeps using the same container and the same grant.
#
# Usage:
#   tool/test_macos_acceptance.sh full        # permissions, sources, captures, controller
#   tool/test_macos_acceptance.sh lifecycle   # stop releases the surface + 20 start/stop cycles
#   tool/test_macos_acceptance.sh source-loss # capture a real window, then close that window
#   tool/test_macos_acceptance.sh revocation  # real permission withdrawal mid-capture
#
# Set ACCEPTANCE_CLEAN=1 to wipe the acceptance DerivedData and rebuild from
# scratch (slower, but rules out stale intermediates).
#
# `revocation` clears the Screen Recording grant for the bundle id, so every
# later real-capture run needs the grant re-enabled in System Settings and the
# app reopened. Run it last.
set -euo pipefail

MODE="${1:-full}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ACCEPTANCE_DD="$REPO/build/acceptance-dd"
APP="$REPO/build/acceptance/Share Hub Acceptance.app"
BUILT="$ACCEPTANCE_DD/Build/Products/Debug/Share Hub.app"
PRODUCT_APP="$REPO/build/macos/Build/Products/Debug/Share Hub.app"
BUNDLE="dev.sharehub.client"
DATA="$HOME/Library/Containers/$BUNDLE/Data"
REPORT="$DATA/macos-acceptance.json"
READY="$DATA/acceptance-ready.json"
# Window source names are "<app> · <title>"; cover both localisations.
NEEDLES="未命名,Untitled,文本编辑,TextEdit"

# Flutter is often not on PATH; FLUTTER_BIN overrides the lookup.
FLUTTER="${FLUTTER_BIN:-}"
if [[ -z "$FLUTTER" ]]; then
  if [[ -x "$HOME/development/flutter/bin/flutter" ]]; then
    FLUTTER="$HOME/development/flutter/bin/flutter"
  elif command -v flutter >/dev/null 2>&1; then
    FLUTTER="$(command -v flutter)"
  fi
fi
if [[ -z "$FLUTTER" || ! -x "$FLUTTER" ]]; then
  echo "找不到 flutter。请设置 FLUTTER_BIN=/absolute/path/to/flutter 后重试。" >&2
  exit 1
fi
export PATH="$(dirname "$FLUTTER"):$PATH"

# An injected proxy breaks the loopback WebSocket used by flutter_tester.
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY 2>/dev/null || true

case "$MODE" in
  full) FILE_MODE="full" ;;
  lifecycle) FILE_MODE="lifecycle" ;;
  source-loss) FILE_MODE="source-loss|$NEEDLES" ;;
  revocation) FILE_MODE="revocation" ;;
  *) echo "未知模式: $MODE（可选 full|lifecycle|source-loss|revocation）" >&2; exit 2 ;;
esac

crashes() { ls "$HOME/Library/Logs/DiagnosticReports/" 2>/dev/null | grep -c "Share Hub" || true }
product_stamp() { stat -f "%m" "$PRODUCT_APP/Contents/MacOS/Share Hub" 2>/dev/null || echo missing }

# The generated config must not stay pointing at the development entry, or a
# later plain `xcodebuild` would silently build the acceptance app.
restore_config() {
  "$FLUTTER" build macos --debug --no-pub --config-only >/dev/null 2>&1 || true
}
trap restore_config EXIT

PRODUCT_BEFORE="$(product_stamp)"

echo "=== 构建验收 target (mode=$MODE) ==="
if [[ "${ACCEPTANCE_CLEAN:-0}" == "1" ]]; then
  echo "ACCEPTANCE_CLEAN=1 → 清空 $ACCEPTANCE_DD"
  rm -rf "$ACCEPTANCE_DD"
fi
"$FLUTTER" build macos --debug --no-pub --config-only \
  --target=lib/dev/macos_acceptance_main.dart 2>&1 | tail -3
xcodebuild -workspace "$REPO/macos/Runner.xcworkspace" -scheme Runner \
  -configuration Debug \
  -derivedDataPath "$ACCEPTANCE_DD" \
  -clonedSourcePackagesDirPath "$REPO/build/macos/SourcePackages" \
  build 2>&1 | tail -5

if [[ ! -d "$BUILT" ]]; then
  echo "!! 验收构建未产出 app: $BUILT" >&2
  exit 1
fi

PRODUCT_AFTER="$(product_stamp)"
if [[ "$PRODUCT_BEFORE" == "$PRODUCT_AFTER" ]]; then
  echo "产品 app 未被覆盖 (mtime=$PRODUCT_AFTER)"
else
  echo "!! 产品路径被改动了 (before=$PRODUCT_BEFORE after=$PRODUCT_AFTER)" >&2
  exit 1
fi

echo "=== 复制到 $APP ==="
rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
ditto "$BUILT" "$APP"

# Guard against ever launching the product entry by mistake.
KERNEL="$APP/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/kernel_blob.bin"
if [[ "$(grep -c "acceptance-mode" "$KERNEL" 2>/dev/null || echo 0)" -lt 1 ]]; then
  echo "!! 复制出来的 app 不是验收入口，已停止" >&2
  exit 1
fi
echo "验收 app 就绪: $(stat -f "%Sm" "$APP/Contents/MacOS/Share Hub")"

mkdir -p "$DATA"
pkill -f "$APP/Contents/MacOS/Share Hub" 2>/dev/null || true
sleep 1
rm -f "$REPORT" "$READY"
printf '%s' "$FILE_MODE" > "$DATA/acceptance-mode"
BEFORE=$(crashes)

if [[ "$MODE" == "source-loss" ]]; then
  echo "=== 打开可关闭的采集对象 (TextEdit) ==="
  pkill -x TextEdit 2>/dev/null || true
  sleep 1
  open -a TextEdit
  sleep 3
fi

echo "=== 启动 $(date +%H:%M:%S) 崩溃报告基线=$BEFORE ==="
open -n "$APP"

case "$MODE" in
  revocation|source-loss)
    for _ in $(seq 1 80); do
      [[ -f "$READY" ]] && break
      [[ -f "$REPORT" ]] && break
      sleep 0.5
    done
    if [[ -f "$READY" ]]; then
      echo "采集中标记 $(date +%H:%M:%S): $(cat "$READY")"
      if [[ "$MODE" == "revocation" ]]; then
        echo "=== 撤回权限 $(date +%H:%M:%S) ==="
        tccutil reset ScreenCapture "$BUNDLE"
      else
        echo "=== 关闭被采集的窗口 $(date +%H:%M:%S) ==="
        pkill -x TextEdit 2>/dev/null || echo "(TextEdit 未在运行)"
      fi
    else
      echo "!! 未观测到采集中标记，直接读结果"
    fi
    ;;
esac

for _ in $(seq 1 600); do
  [[ -f "$REPORT" ]] && break
  sleep 0.5
done
sleep 1

echo "=== 崩溃报告 基线=$BEFORE 现在=$(crashes) ==="
[[ -f "$REPORT" ]] || { echo "!! 未产出报告"; exit 1; }

python3 - "$REPORT" "$MODE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
mode = sys.argv[2]
keep = [
    'mode', 'watchdogExpired', 'permissions', 'permissionsBefore', 'permissionsAfter',
    'device', 'deviceStable', 'sources', 'sourceCount', 'primary', 'primarySelection',
    'firstRun', 'resumeRun', 'controller', 'loadSources', 'captureStarted',
    'revocation', 'sourceLoss', 'endedPath', 'doubleStop', 'sourcesAfterRevocation',
    'outcome', 'engineError', 'error',
]
for key in keep:
    if key in d:
        print(f'{key}: {json.dumps(d[key], ensure_ascii=False)}')

if mode == 'lifecycle':
    print('stopReleasesSurface:', json.dumps(d.get('stopReleasesSurface'), ensure_ascii=False))
    print('recovery:', json.dumps(d.get('recovery'), ensure_ascii=False))
    print('surfaceAfterCycles:', json.dumps(d.get('surfaceAfterCycles'), ensure_ascii=False))
    cycles = d.get('cycles') or []
    print(f'cycles: {len(cycles)} 无首帧={d.get("cyclesWithoutFirstFrame")} 报错={d.get("cycleErrors")} 总耗时={d.get("cyclesElapsedMs")}ms')
    ms = [c['firstFrameMs'] for c in cycles if c.get('firstFrame')]
    if ms:
        print(f'  首帧 min={min(ms)} p50={sorted(ms)[len(ms)//2]} max={max(ms)} ms')
    for c in cycles:
        if c.get('firstFrame') is not True or c.get('error'):
            print('  异常周期:', json.dumps(c, ensure_ascii=False))

if mode == 'source-loss':
    print('needles:', json.dumps(d.get('needles'), ensure_ascii=False))
    print('matchedNeedle:', d.get('matchedNeedle'), '| selected:', d.get('selected'))
    print('windowSources:', json.dumps(d.get('windowSources'), ensure_ascii=False))
    print('noFallbackAfterLoss:', json.dumps(d.get('noFallbackAfterLoss'), ensure_ascii=False))
    print('recovery:', json.dumps(d.get('recovery'), ensure_ascii=False))

if mode == 'revocation':
    print('permissionSamples 首/末:',
          json.dumps((d.get('permissionSamples') or [{}])[0], ensure_ascii=False),
          json.dumps((d.get('permissionSamples') or [{}])[-1], ensure_ascii=False),
          '采样数=', len(d.get('permissionSamples') or []))

for t in d.get('transitions') or []:
    print('transition:', json.dumps(t, ensure_ascii=False))
PY
