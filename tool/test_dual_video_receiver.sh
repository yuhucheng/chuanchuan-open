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
  > "$log" 2>&1
probe_result=$?
if [ "$probe_result" -ne 0 ]; then
  echo "Receiver failed; raw temporary test log remains at $log" >&2
fi
exit "$probe_result"
