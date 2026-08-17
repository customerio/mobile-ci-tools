#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/launch-ios-simulator-app.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

app_path="$temporary_root/Test.app"
mkdir -p "$app_path"
touch "$app_path/Info.plist"

stub_bin="$temporary_root/bin"
mkdir -p "$stub_bin"

cat > "$stub_bin/plist-buddy" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  *CFBundleIdentifier*) printf '%s\n' 'io.customer.test.launch-smoke' ;;
  *CFBundleExecutable*) printf '%s\n' 'LaunchSmoke' ;;
  *DTSDKName*) printf '%s\n' 'iphonesimulator27.0' ;;
  *) exit 2 ;;
esac
STUB

cat > "$stub_bin/xcrun" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
if [[ "$1 $2 $3 $4" == 'simctl list devices available' ]]; then
  cat <<'JSON'
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"state":"Shutdown","isAvailable":true,"name":"iPhone 17 Pro","udid":"SIM-27"}],"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"state":"Booted","isAvailable":true,"name":"iPhone 16","udid":"SIM-26"}]}}
JSON
elif [[ "$1 $2" == 'simctl launch' ]]; then
  if [[ "${STUB_LAUNCH_FAILS:-false}" == true ]]; then
    echo 'stubbed launch rejection' >&2
    exit 3
  elif [[ "${STUB_LAUNCH_MALFORMED:-false}" == true ]]; then
    echo 'launch completed without pid'
  else
    echo 'io.customer.test.launch-smoke: 4242'
  fi
elif [[ "$1 $2" == 'simctl spawn' ]]; then
  echo 'stubbed simulator failure log'
fi
STUB

cat > "$stub_bin/ps" <<'STUB'
#!/usr/bin/env bash
printf 'ps %s\n' "$*" >> "$STUB_CALLS"
[[ "${STUB_PROCESS_ALIVE:-true}" == true ]] || exit 1
printf '%s\n' '/Users/runner/Library/Developer/CoreSimulator/Devices/00000000-0000-0000-0000-000000000000/data/Containers/Bundle/Application/11111111-1111-1111-1111-111111111111/LaunchSmoke.app/LaunchSmoke'
STUB

cat > "$stub_bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

chmod +x "$stub_bin"/*

run_case() {
  local name="$1"
  shift
  local case_root="$temporary_root/$name"
  mkdir -p "$case_root"
  : > "$case_root/calls"
  env \
    APP_PATH="$app_path" \
    EXPECTED_IOS_MAJOR=27 \
    SURVIVAL_SECONDS=5 \
    LAUNCH_LOG_PATH="$case_root/launch.log" \
    GITHUB_OUTPUT="$case_root/output" \
    GITHUB_STEP_SUMMARY="$case_root/summary" \
    XCRUN_BIN="$stub_bin/xcrun" \
    PYTHON_BIN=python3 \
    PLIST_BUDDY_BIN="$stub_bin/plist-buddy" \
    PS_BIN="$stub_bin/ps" \
    SLEEP_BIN="$stub_bin/sleep" \
    STUB_CALLS="$case_root/calls" \
    "$@" \
    bash "$script_dir/launch.sh"
}

run_case success
grep -Fxq 'bundle-id=io.customer.test.launch-smoke' "$temporary_root/success/output"
grep -Fxq 'launched-pid=4242' "$temporary_root/success/output"
grep -Fxq 'classification=launch-passed' "$temporary_root/success/output"
grep -Fxq 'simulator-runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-0' "$temporary_root/success/output"
grep -Fxq 'app-sdk-name=iphonesimulator27.0' "$temporary_root/success/output"
grep -Fxq 'app-sdk-major=27' "$temporary_root/success/output"
grep -Fxq 'simctl boot SIM-27' "$temporary_root/success/calls"
grep -Fxq "simctl install SIM-27 $app_path" "$temporary_root/success/calls"
grep -Fxq 'simctl launch --terminate-running-process SIM-27 io.customer.test.launch-smoke' "$temporary_root/success/calls"
test "$(grep -Fxc 'ps -ww -p 4242 -o comm=' "$temporary_root/success/calls")" -eq 5
grep -Fxq 'simctl terminate SIM-27 io.customer.test.launch-smoke' "$temporary_root/success/calls"
grep -Fxq 'simctl uninstall SIM-27 io.customer.test.launch-smoke' "$temporary_root/success/calls"
grep -Fxq 'simctl shutdown SIM-27' "$temporary_root/success/calls"
grep -Fq '**Classification:** launch-passed' "$temporary_root/success/summary"

if run_case process-exited STUB_PROCESS_ALIVE=false; then
  echo 'Expected an app that exits during the survival window to fail.' >&2
  exit 1
fi
grep -Fq 'exited or changed identity after 1s of the 5s survival window' "$temporary_root/process-exited/launch.log"
grep -Fq 'stubbed simulator failure log' "$temporary_root/process-exited/launch.log"

if run_case launch-rejected STUB_LAUNCH_FAILS=true; then
  echo 'Expected a rejected simctl launch to fail.' >&2
  exit 1
fi
grep -Fq 'stubbed launch rejection' "$temporary_root/launch-rejected/launch.log"
grep -Fq 'stubbed simulator failure log' "$temporary_root/launch-rejected/launch.log"

if run_case malformed-launch STUB_LAUNCH_MALFORMED=true; then
  echo 'Expected launch output without a PID to fail.' >&2
  exit 1
fi
grep -Fq 'simctl launch did not return a PID' "$temporary_root/malformed-launch/launch.log"

missing_error="$temporary_root/missing-error"
if APP_PATH="$temporary_root/Missing.app" EXPECTED_IOS_MAJOR=27 bash "$script_dir/launch.sh" 2>"$missing_error"; then
  echo 'Expected a missing app to fail.' >&2
  exit 1
fi
grep -Fq 'Built simulator app is missing or has no Info.plist' "$missing_error"

survival_error="$temporary_root/survival-error"
if APP_PATH="$app_path" EXPECTED_IOS_MAJOR=27 SURVIVAL_SECONDS=0 bash "$script_dir/launch.sh" 2>"$survival_error"; then
  echo 'Expected an invalid survival window to fail.' >&2
  exit 1
fi
grep -Fq 'SURVIVAL_SECONDS must be a positive whole number' "$survival_error"

echo 'launch-simulator-app tests passed'
