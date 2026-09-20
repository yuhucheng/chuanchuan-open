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
#   tool/test_macos_acceptance.sh background  # minimize/hide/close-to-background/reopen/exit
#   tool/test_macos_acceptance.sh stop-freeze # stop really freezes capture and pixels + repeated stop
#
# `background` also wakes the app through LaunchServices (`open`, no `-n`) once
# the window has been closed to the background, so `applicationShouldHandleReopen`
# is exercised on the real system path instead of the in-app fallback.
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
# Written by the `background` entry once the main window is closed to the
# background; the runner reacts by waking the app through LaunchServices.
REOPEN_REQ="$DATA/acceptance-reopen-request"
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
  background) FILE_MODE="background" ;;
  stop-freeze) FILE_MODE="stop-freeze" ;;
  *) echo "未知模式: $MODE（可选 full|lifecycle|source-loss|revocation|background|stop-freeze）" >&2; exit 2 ;;
esac

crashes() { ls "$HOME/Library/Logs/DiagnosticReports/" 2>/dev/null | grep -c "Share Hub" || true }
product_stamp() { stat -f "%m" "$PRODUCT_APP/Contents/MacOS/Share Hub" 2>/dev/null || echo missing }

# The generated config must not stay pointing at the development entry, or a
# later plain `xcodebuild` would silently build the acceptance app.
restore_config() {
  "$FLUTTER" build macos --debug --no-pub --config-only >/dev/null 2>&1 || true
}
trap restore_config EXIT

# Same question as the `restore_config` comment, but read back from disk instead
# of trusting that the restore succeeded. It is checked explicitly at the end of
# the run so a failure exits non-zero; the trap above stays as a backstop for
# early exits.
product_entry_restored() {
  local found
  found="$(grep -h 'FLUTTER_TARGET' \
    "$REPO/macos/Flutter/ephemeral/flutter_export_environment.sh" \
    "$REPO/macos/Flutter/ephemeral/Flutter-Generated.xcconfig" 2>/dev/null \
    | sed 's/.*FLUTTER_TARGET=//; s/"//g' | sort -u)"
  [[ "$found" == "lib/main.dart" ]]
}

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
mkdir -p "$(dirname "$APP")"
# ditto merges into an existing bundle: every file this build produces replaces
# its counterpart, so the entry point, assets and frameworks are always current.
# A recursive bulk remove of the previous bundle is deliberately avoided (the
# runner blocks large single deletions, and the bundle is a rebuildable,
# gitignored build product). The kernel_blob guard below re-checks that the
# launched entry really is the acceptance one.
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
rm -f "$REPORT" "$READY" "$REOPEN_REQ"
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
  background)
    # Wait for the app to close its window to the background, then wake it the
    # way a user would: LaunchServices activation of the running instance, which
    # delivers the reopen event. No accessibility permission is involved.
    for _ in $(seq 1 200); do
      [[ -f "$REOPEN_REQ" ]] && break
      [[ -f "$REPORT" ]] && break
      sleep 0.5
    done
    if [[ -f "$REOPEN_REQ" ]]; then
      echo "=== 系统级唤醒 $(date +%H:%M:%S)（open，非 -n）==="
      open "$APP"
      # The app leaves the background stage within a few seconds of waking, so
      # a long probe here would race its own exit and read as a false failure.
      # The authoritative aliveness evidence is the in-app
      # `processAliveAfterClose` / `externalReopen` pair.
      sleep 1
      echo "唤醒已发出，等待应用自行完成剩余阶段"
    else
      echo "!! 未观测到唤醒标记（可能未进入关闭到后台阶段）"
    fi
    ;;
esac

for _ in $(seq 1 600); do
  [[ -f "$REPORT" ]] && break
  sleep 0.5
done
sleep 1

if [[ "$MODE" == "background" ]]; then
  if pgrep -f "$APP/Contents/MacOS/Share Hub" >/dev/null 2>&1; then
    echo "!! 退出后进程仍在运行"
    pkill -f "$APP/Contents/MacOS/Share Hub" 2>/dev/null || true
  else
    echo "退出后进程已终止"
  fi
fi

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

if mode == 'background':
    for key in ('trayReady', 'trayAfterInitialize', 'captureStart', 'indicatorsWhileCapturing',
                'indicatorsAfterStop', 'processAliveAfterClose', 'controllerAfterClose',
                'externalReopen', 'externalReopenFallback', 'closedToBackgroundSkipped',
                'beforeExit', 'exit'):
        if key in d:
            print(f'{key}: {json.dumps(d[key], ensure_ascii=False)}')
    while_capturing = len(d.get('indicatorsWhileCapturing') or [])
    after_stop = len(d.get('indicatorsAfterStop') or [])
    print(f'录屏指示对照: 采集中={while_capturing} 项, 停止后={after_stop} 项')
    print('--- 阶段帧计数 ---')
    for s in d.get('stages') or []:
        w = s.get('window') or {}
        print(f"  {s['stage']}: visible={w.get('visible')} miniaturized={w.get('miniaturized')} "
              f"onscreen={w.get('onscreen')} tray={w.get('trayInstalled')} "
              f"captured {s.get('capturedFramesStart')}→{s.get('capturedFramesEnd')} (+{s.get('capturedDelta')}) "
              f"rendered +{s.get('renderedDelta')} 最后帧龄={s.get('lastFrameAgeMs')}ms")

if mode == 'stop-freeze':
    print('captureStart:', json.dumps(d.get('captureStart'), ensure_ascii=False))
    print('stop:', json.dumps(d.get('stop'), ensure_ascii=False))

    def counters(sample):
        return (f"captured={sample.get('capturedFrames')} rendered={sample.get('renderedFrames')} "
                f"rejected={sample.get('rejectedFrames')} blank={sample.get('blankFrames')} "
                f"contentChanges={sample.get('contentChanges')} "
                f"checksum={sample.get('lastFrameChecksum')} 帧龄={sample.get('lastFrameAgeMs')}ms")

    live = d.get('live') or {}
    print('--- 阳性对照（采集进行中 3s）---')
    print(f"  captured +{live.get('capturedDelta')} rendered +{live.get('renderedDelta')} "
          f"contentChanges +{live.get('contentChangesDelta')} "
          f"指纹变化={live.get('checksumChanged')} 帧龄={live.get('lastFrameAgeMs')}ms")
    print('--- 停止后（每次为瞬时读数）---')
    for s in d.get('afterStop') or []:
        print(f"  {s['stage']} (+{s.get('sinceStopMs')}ms): live={s.get('live')} "
              f"accepting={s.get('acceptingFrames')} buffer={s.get('hasPixelBuffer')} "
              f"texture={s.get('textureId')} session={s.get('sessionId')} | {counters(s)}")
    print('surfaceAfterStop:', json.dumps(d.get('surfaceAfterStop'), ensure_ascii=False))
    print('repeatedStop:', json.dumps(d.get('repeatedStop'), ensure_ascii=False))
    print('restart:', json.dumps(d.get('restart'), ensure_ascii=False))
    restart_live = d.get('restartLive') or {}
    if restart_live:
        print(f"  重启后: captured +{restart_live.get('capturedDelta')} "
              f"contentChanges +{restart_live.get('contentChangesDelta')} session={restart_live.get('sessionId')}")
    print('finalStop:', json.dumps(d.get('finalStop'), ensure_ascii=False))
    verdict = d.get('verdict') or {}
    print('--- 结论 ---')
    for key, value in verdict.items():
        print(f"  {'OK ' if value else 'NG '} {key}={value}")
    if verdict and not all(verdict.values()):
        print('!! 存在未达标项')

for t in d.get('transitions') or []:
    print('transition:', json.dumps(t, ensure_ascii=False))
PY

echo "=== 还原生成配置并核验 $(date +%H:%M:%S) ==="
restore_config
if product_entry_restored; then
  echo "生成配置已回到产品入口 (lib/main.dart)"
else
  echo "!! 生成配置未回到产品入口，后续 xcodebuild 可能把验收入口构建到产品路径" >&2
  exit 1
fi
