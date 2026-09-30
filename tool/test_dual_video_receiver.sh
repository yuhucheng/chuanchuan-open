#!/usr/bin/env bash
# Run from the Mac's interactive Terminal so login-keychain signing may prompt.
# This receiver never queries capture sources or requests recording permission.
set -uo pipefail
umask 077
if [ "$(uname -s)" != "Darwin" ]; then
  echo 'This receiver requires macOS.' >&2
  exit 1
fi
project=$(cd "$(dirname "$0")/.." && pwd)
cd "$project" || exit 1
flutter_bin=${SHM_FLUTTER_BIN:-flutter}
rounds=${SHM_DUAL_ROUNDS:-1}
if ! [[ "$rounds" =~ ^([1-9]|1[0-9]|20)$ ]]; then
  echo 'SHM_DUAL_ROUNDS must be 1..20.' >&2
  exit 1
fi
mkdir -p .local/dual-media
log="$project/.local/dual-media/receiver.log"
restore_log="$project/.local/dual-media/restore.log"
terminal="$project/.local/dual-media/receiver-terminal.json"
run_id=$(uuidgen)
printf '{"runId":"%s","wrapperPid":%s,"completed":false}\n' "$run_id" "$$" > "$terminal.next"
mv "$terminal.next" "$terminal"
: > "$log"
: > "$restore_log"
chmod 600 "$log" "$restore_log"
restore() {
  probe_result=$?
  trap - EXIT
  "$flutter_bin" build macos --debug --no-pub > "$restore_log" 2>&1
  restore_result=$?
  printf '{"runId":"%s","wrapperPid":%s,"completed":true,"probeExit":%s,"restoreExit":%s}\n' \
    "$run_id" "$$" "$probe_result" "$restore_result" > "$terminal.next"
  mv "$terminal.next" "$terminal"
  if [ "$restore_result" -ne 0 ]; then
    echo "Normal application restore failed; inspect $restore_log" >&2
    exit "$restore_result"
  fi
  echo "Receiver result=$probe_result; normal Debug application restored."
  exit "$probe_result"
}
trap restore EXIT
echo 'Building receiver and waiting for Windows. Keep this terminal open.'
"$flutter_bin" test integration_test/dual_machine_video_test.dart -d macos \
  --no-pub --reporter expanded --dart-define=CHUAN_DUAL_PROBE_CONSOLE=true \
  "--dart-define=CHUAN_DUAL_PROBE_RUN=$run_id" \
  "--dart-define=CHUAN_DUAL_PROBE_ROUNDS=$rounds" \
  > "$log" 2>&1 &
test_pid=$!
# The live integration binding waits for real engine frames. Activate only the
# already-running PID after its matching ready record. Activation must never
# have application-launch semantics if that process exits during the check.
for ((attempt=0; attempt<120; attempt++)); do
  if ! kill -0 "$test_pid" 2>/dev/null; then break; fi
  app_pid=$(python3 - "$log" "$run_id" <<'PY'
import json,pathlib,sys
for line in reversed(pathlib.Path(sys.argv[1]).read_text(errors='replace').splitlines()):
    if 'DUAL_READY=' not in line: continue
    try: ready=json.loads(line.split('DUAL_READY=',1)[1])
    except ValueError: continue
    if ready.get('runId')==sys.argv[2] and isinstance(ready.get('pid'),int):
        print(ready['pid'])
        break
PY
  )
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    expected="$project/build/macos/Build/Products/Debug/Share Hub.app/Contents/MacOS/Share Hub"
    actual=$(ps -p "$app_pid" -o comm=)
    if [ "$actual" = "$expected" ]; then
      if xcrun swift - "$app_pid" "$expected" > .local/dual-media/activation.log 2>&1 <<'SWIFT'
import AppKit
import Foundation
guard CommandLine.arguments.count == 3,
      let pid = Int32(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: pid),
      app.executableURL?.path == CommandLine.arguments[2],
      !app.isTerminated else { exit(1) }
// NSRunningApplication has no launch behavior if this exact PID exits.
guard app.activate(options: [.activateIgnoringOtherApps]) else { exit(1) }
SWIFT
      then
        echo "Requested activation of owned receiver PID $app_pid."
      else
        echo 'Owned receiver activation failed; inspect activation.log.' >&2
      fi
    else
      echo 'Receiver process identity did not match; no activation attempted.' >&2
    fi
    break
  fi
  sleep 1
done
wait "$test_pid"
probe_result=$?
if [ "$probe_result" -ne 0 ]; then
  echo "Receiver failed; raw temporary test log remains at $log" >&2
fi
exit "$probe_result"
