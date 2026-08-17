#!/usr/bin/env bash

set -Eeuo pipefail

current_case=setup
report_test_failure() {
  local status="$?"
  trap - ERR
  echo "launch-simulator-app test failed at line $1 while running $current_case" >&2
  exit "$status"
}
trap 'report_test_failure "$LINENO"' ERR

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
  *CFBundleIdentifier*) key=CFBundleIdentifier; value="${STUB_BUNDLE_ID:-io.customer.test.launch-smoke}" ;;
  *CFBundleExecutable*) key=CFBundleExecutable; value="${STUB_EXECUTABLE:-LaunchSmoke}" ;;
  *DTSDKName*) key=DTSDKName; value="${STUB_SDK_NAME:-iphonesimulator27.0}" ;;
  *) exit 2 ;;
esac
[[ "${STUB_PLIST_FAIL_KEY:-}" != "$key" ]] || exit 2
printf '%s\n' "$value"
STUB

cat > "$stub_bin/xcrun" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
  if [[ "$1 $2 $3 $4" == 'simctl list devices available' ]]; then
  [[ "${STUB_LIST_WARNING:-false}" != true ]] || echo 'stubbed simctl warning' >&2
  if [[ "${STUB_MALFORMED_SELECTION:-false}" == true ]]; then
    printf '%s\n' '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"state":"Shutdown","isAvailable":true,"name":"iPhone 17 Pro","udid":"INVALID UDID"}]}}'
  elif [[ "${STUB_BOOT_RACE_OTHER_OWNER:-false}" == true ]] \
    && [[ "$(grep -Fc 'simctl list devices available --json' "$STUB_CALLS")" -gt 1 ]]; then
    if [[ "${STUB_RACE_DEVICE_MISSING:-false}" == true ]]; then
      printf '%s\n' '{"devices":{}}'
    else
      printf '%s\n' "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-27-0\":[{\"state\":\"${STUB_RACE_STATE:-Booted}\",\"isAvailable\":true,\"name\":\"iPhone 17 Pro\",\"udid\":\"SIM-27\"}]}}"
    fi
  elif [[ "${STUB_NO_DEVICES:-false}" == true ]]; then
    printf '%s\n' '{"devices":{}}'
  elif [[ "${STUB_DEVICE_BOOTED:-false}" == true ]]; then
    cat <<'JSON'
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"state":"Booted","isAvailable":true,"name":"iPhone 17 Pro","udid":"SIM-27"}]}}
JSON
  elif [[ "${STUB_PREFER_BOOTED_DEVICE:-false}" == true ]]; then
    cat <<'JSON'
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-1":[{"state":"Shutdown","isAvailable":true,"name":"iPhone Newer","udid":"SIM-27-1"}],"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"state":"Booted","isAvailable":true,"name":"iPhone Booted","udid":"SIM-27"}]}}
JSON
  elif [[ "${STUB_TRANSITIONAL_DEVICE:-false}" == true ]]; then
    cat <<'JSON'
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"state":"Shutting Down","isAvailable":true,"name":"iPhone Transitional","udid":"ZZZ-TRANSITIONAL"},{"state":"Shutdown","isAvailable":true,"name":"iPhone 17 Pro","udid":"SIM-27"}]}}
JSON
  else
    cat <<'JSON'
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"state":"Shutdown","isAvailable":true,"name":"iPhone 17 Pro","udid":"SIM-27"}],"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"state":"Booted","isAvailable":true,"name":"iPhone 16","udid":"SIM-26"}]}}
JSON
  fi
elif [[ "$1 $2" == 'simctl boot' && "${STUB_BOOT_FAILS:-false}" == true ]]; then
  echo 'stubbed boot transition rejection' >&2
  exit 3
elif [[ "$1 $2" == 'simctl bootstatus' && "${STUB_BOOTSTATUS_FAILS:-false}" == true ]]; then
  echo 'stubbed bootstatus rejection' >&2
  exit 3
elif [[ "$1 $2" == 'simctl install' && "${STUB_INSTALL_FAILS:-false}" == true ]]; then
  echo 'stubbed install rejection' >&2
  exit 3
elif [[ "$1 $2" == 'simctl launch' ]]; then
  if [[ "${STUB_LAUNCH_FAILS:-false}" == true ]]; then
    printf '%s\n' 'stubbed launch rejection' '::warning title=forged::must-not-run' >&2
    exit 3
  elif [[ "${STUB_LAUNCH_MALFORMED:-false}" == true ]]; then
    echo 'launch completed without pid'
  else
    [[ "${STUB_LAUNCH_WARNING:-false}" != true ]] || echo '::notice title=forged::must-not-run'
    echo 'io.customer.test.launch-smoke: 4242'
  fi
elif [[ "$1 $2" == 'simctl spawn' ]]; then
  printf '%s\n' 'stubbed simulator failure log' '::warning title=forged-log::must-not-run'
fi
STUB

cat > "$stub_bin/ps" <<'STUB'
#!/usr/bin/env bash
printf 'ps %s\n' "$*" >> "$STUB_CALLS"
[[ "${STUB_PROCESS_ALIVE:-true}" == true ]] || exit 1
[[ -z "${STUB_PS_EXIT_STATUS:-}" ]] || exit "$STUB_PS_EXIT_STATUS"
printf '%s %s\n' \
  "${STUB_PROCESS_STATE:-S}" \
  "${STUB_PROCESS_COMMAND:-/Users/runner/Library/Developer/CoreSimulator/Devices/${STUB_DEVICE_UDID:-SIM-27}/data/Containers/Bundle/Application/11111111-1111-1111-1111-111111111111/LaunchSmoke.app/LaunchSmoke}"
STUB

cat > "$stub_bin/sleep" <<'STUB'
#!/usr/bin/env bash
[[ "${STUB_SLEEP_FAILS:-false}" != true ]] || exit 9
exit 0
STUB

chmod +x "$stub_bin"/*

run_case() {
  local name="$1"
  shift
  current_case="$name"
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
    STUB_DEVICE_UDID=SIM-27 \
    "$@" \
    "$BASH" "$script_dir/launch.sh" > "$case_root/command.log" 2>&1
}

run_case success
grep -Fxq 'bundle-id=io.customer.test.launch-smoke' "$temporary_root/success/output"
grep -Fxq 'launched-pid=4242' "$temporary_root/success/output"
grep -Fxq 'classification=launch-passed' "$temporary_root/success/output"
grep -Fxq 'failure-reason=none' "$temporary_root/success/output"
grep -Fxq 'simulator-runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-0' "$temporary_root/success/output"
grep -Fxq 'app-sdk-name=iphonesimulator27.0' "$temporary_root/success/output"
grep -Fxq 'app-sdk-major=27' "$temporary_root/success/output"
grep -Fxq 'simctl boot SIM-27' "$temporary_root/success/calls"
grep -Fxq "simctl install SIM-27 $app_path" "$temporary_root/success/calls"
grep -Fxq 'simctl launch --terminate-running-process SIM-27 io.customer.test.launch-smoke' "$temporary_root/success/calls"
test "$(grep -Fxc 'ps -ww -p 4242 -o state= -o comm=' "$temporary_root/success/calls")" -eq 5
grep -Fxq 'simctl terminate SIM-27 io.customer.test.launch-smoke' "$temporary_root/success/calls"
grep -Fxq 'simctl uninstall SIM-27 io.customer.test.launch-smoke' "$temporary_root/success/calls"
grep -Fxq 'simctl shutdown SIM-27' "$temporary_root/success/calls"
grep -Fq '**Classification:** launch-passed' "$temporary_root/success/summary"

run_case launch-warning STUB_LAUNCH_WARNING=true
grep -Fq '::notice title=forged::must-not-run' "$temporary_root/launch-warning/launch.log"
if grep -Fxq '::notice title=forged::must-not-run' "$temporary_root/launch-warning/command.log"; then
  echo 'simctl launch output emitted a forged GitHub workflow command.' >&2
  exit 1
fi

if run_case process-exited STUB_PROCESS_ALIVE=false; then
  echo 'Expected an app that exits during the survival window to fail.' >&2
  exit 1
fi
grep -Fq 'exited or changed identity after 1s of the 5s survival window' "$temporary_root/process-exited/launch.log"
grep -Fq 'ps observation after 1s:' "$temporary_root/process-exited/launch.log"
grep -Fxq 'failure-reason=did-not-survive' "$temporary_root/process-exited/output"
grep -Fxq 'launched-pid=4242' "$temporary_root/process-exited/output"
grep -Fq 'stubbed simulator failure log' "$temporary_root/process-exited/launch.log"
grep -Fxq 'simctl terminate SIM-27 io.customer.test.launch-smoke' "$temporary_root/process-exited/calls"
grep -Fxq 'simctl uninstall SIM-27 io.customer.test.launch-smoke' "$temporary_root/process-exited/calls"
grep -Fxq 'simctl shutdown SIM-27' "$temporary_root/process-exited/calls"

if run_case process-inspection-failed STUB_PS_EXIT_STATUS=2; then
  echo 'Expected a process-inspection failure to fail.' >&2
  exit 1
fi
grep -Fxq 'failure-reason=unexpected-error' "$temporary_root/process-inspection-failed/output"

if run_case launch-rejected STUB_LAUNCH_FAILS=true; then
  echo 'Expected a rejected simctl launch to fail.' >&2
  exit 1
fi
grep -Fq 'stubbed launch rejection' "$temporary_root/launch-rejected/launch.log"
grep -Fxq 'failure-reason=launch-failed' "$temporary_root/launch-rejected/output"
grep -Fq 'stubbed simulator failure log' "$temporary_root/launch-rejected/launch.log"
grep -Fq '::warning title=forged-log::must-not-run' "$temporary_root/launch-rejected/launch.log"
if grep -Fxq '::warning title=forged::must-not-run' "$temporary_root/launch-rejected/command.log"; then
  echo 'A multiline tool error emitted a forged GitHub workflow command.' >&2
  exit 1
fi
grep -Eq '^::error title=iOS simulator launch smoke::.*stubbed launch rejection.*must-not-run$' \
  "$temporary_root/launch-rejected/command.log"
if grep -Fxq '::warning title=forged-log::must-not-run' "$temporary_root/launch-rejected/command.log"; then
  echo 'Simulator diagnostics emitted a forged GitHub workflow command.' >&2
  exit 1
fi

if run_case malformed-launch STUB_LAUNCH_MALFORMED=true; then
  echo 'Expected launch output without a PID to fail.' >&2
  exit 1
fi
grep -Fq 'simctl launch did not return a PID' "$temporary_root/malformed-launch/launch.log"

if run_case wrong-simulator-process \
  STUB_PROCESS_COMMAND='/Users/runner/Library/Developer/CoreSimulator/Devices/OTHER-SIM/data/LaunchSmoke.app/LaunchSmoke'; then
  echo 'Expected a process from another simulator to fail identity validation.' >&2
  exit 1
fi
grep -Fq 'exited or changed identity' "$temporary_root/wrong-simulator-process/launch.log"

if run_case wrong-executable-process \
  STUB_PROCESS_COMMAND='/Users/runner/Library/Developer/CoreSimulator/Devices/SIM-27/data/LaunchSmoke.app/OtherExecutable'; then
  echo 'Expected a different executable in the selected simulator to fail identity validation.' >&2
  exit 1
fi
grep -Fq 'exited or changed identity' "$temporary_root/wrong-executable-process/launch.log"

if run_case zombie-process STUB_PROCESS_STATE=Z+; then
  echo 'Expected a zombie process to fail the survival check.' >&2
  exit 1
fi
grep -Fq 'exited or changed identity' "$temporary_root/zombie-process/launch.log"

if run_case invalid-bundle-id STUB_BUNDLE_ID=$'io.customer.test\ninjected=value'; then
  echo 'Expected an invalid bundle identifier to fail.' >&2
  exit 1
fi
grep -Fq 'invalid CFBundleIdentifier' "$temporary_root/invalid-bundle-id/launch.log"
grep -Fxq 'failure-reason=invalid-app' "$temporary_root/invalid-bundle-id/output"
if grep -Fq 'injected=value' "$temporary_root/invalid-bundle-id/output"; then
  echo 'Invalid bundle metadata injected a forged GitHub output.' >&2
  exit 1
fi
grep -Fxq 'bundle-id=unknown' "$temporary_root/invalid-bundle-id/output"

if run_case invalid-executable STUB_EXECUTABLE=$'LaunchSmoke\ninjected=value'; then
  echo 'Expected an invalid executable name to fail.' >&2
  exit 1
fi
grep -Fq 'invalid CFBundleExecutable' "$temporary_root/invalid-executable/launch.log"

if run_case invalid-sdk-name STUB_SDK_NAME=$'iphonesimulator27.0\ninjected=value'; then
  echo 'Expected an invalid SDK name to fail.' >&2
  exit 1
fi
grep -Fq 'not an iPhone simulator product' "$temporary_root/invalid-sdk-name/launch.log"
if grep -Fq 'injected=value' "$temporary_root/invalid-sdk-name/output"; then
  echo 'Invalid SDK metadata injected a forged GitHub output.' >&2
  exit 1
fi
grep -Fxq 'app-sdk-name=unknown' "$temporary_root/invalid-sdk-name/output"

if run_case unreadable-sdk STUB_PLIST_FAIL_KEY=DTSDKName; then
  echo 'Expected an unreadable SDK name to fail.' >&2
  exit 1
fi
grep -Fq 'no readable DTSDKName' "$temporary_root/unreadable-sdk/launch.log"

for key in CFBundleIdentifier CFBundleExecutable; do
  case_name="unreadable-$key"
  if run_case "$case_name" STUB_PLIST_FAIL_KEY="$key"; then
    echo "Expected an unreadable $key to fail." >&2
    exit 1
  fi
  grep -Fq "no readable $key" "$temporary_root/$case_name/launch.log"
done

if run_case device-missing STUB_NO_DEVICES=true; then
  echo 'Expected a missing matching simulator to fail.' >&2
  exit 1
fi
grep -Fq 'No available iPhone simulator matches' "$temporary_root/device-missing/launch.log"
grep -Fxq 'failure-reason=runtime-unavailable' "$temporary_root/device-missing/output"

run_case selection-warning STUB_LIST_WARNING=true
grep -Fq 'stubbed simctl warning' "$temporary_root/selection-warning/launch.log"
grep -Fxq 'simulator-udid=SIM-27' "$temporary_root/selection-warning/output"

if run_case sdk-mismatch STUB_SDK_NAME=iphonesimulator26.5; then
  echo 'Expected an app SDK/runtime mismatch to fail.' >&2
  exit 1
fi
grep -Fq 'does not match the requested iOS 27' "$temporary_root/sdk-mismatch/launch.log"
grep -Fxq 'failure-reason=sdk-mismatch' "$temporary_root/sdk-mismatch/output"

if run_case zero-padded-sdk STUB_SDK_NAME=iphonesimulator08.0; then
  echo 'Expected a zero-padded mismatched SDK major to fail.' >&2
  exit 1
fi
grep -Fq 'does not match the requested iOS 27' "$temporary_root/zero-padded-sdk/launch.log"

run_case zero-padded-sdk-match STUB_SDK_NAME=iphonesimulator027.0
grep -Fxq 'classification=launch-passed' "$temporary_root/zero-padded-sdk-match/output"
grep -Fxq 'app-sdk-major=27' "$temporary_root/zero-padded-sdk-match/output"

if run_case boot-transition STUB_BOOT_FAILS=true; then
  : # bootstatus is authoritative and the transitioning simulator became ready.
else
  echo 'Expected bootstatus to recover from a duplicate/transitional boot rejection.' >&2
  exit 1
fi
grep -Fq 'stubbed boot transition rejection' "$temporary_root/boot-transition/launch.log"
grep -Fxq 'simctl bootstatus SIM-27 -b' "$temporary_root/boot-transition/calls"
grep -Fxq 'simctl shutdown SIM-27' "$temporary_root/boot-transition/calls"

run_case already-booted STUB_DEVICE_BOOTED=true
grep -Fxq 'simctl bootstatus SIM-27' "$temporary_root/already-booted/calls"
if grep -Fq 'simctl boot SIM-27' "$temporary_root/already-booted/calls" \
  || grep -Fq 'simctl shutdown SIM-27' "$temporary_root/already-booted/calls"; then
  echo 'The action mutated the lifecycle of a simulator that was already booted.' >&2
  exit 1
fi

run_case prefer-booted-device STUB_PREFER_BOOTED_DEVICE=true
grep -Fxq 'simulator-udid=SIM-27' "$temporary_root/prefer-booted-device/output"
if grep -Fq 'SIM-27-1' "$temporary_root/prefer-booted-device/calls"; then
  echo 'The action preferred a newer shutdown runtime over a matching booted runtime.' >&2
  exit 1
fi

run_case transitional-device STUB_TRANSITIONAL_DEVICE=true
grep -Fxq 'simulator-udid=SIM-27' "$temporary_root/transitional-device/output"
if grep -Fq 'ZZZ-TRANSITIONAL' "$temporary_root/transitional-device/calls"; then
  echo 'The action selected a simulator in an unsupported transitional state.' >&2
  exit 1
fi

run_case executable-with-space \
  STUB_EXECUTABLE='Launch Smoke' \
  STUB_PROCESS_COMMAND='/Users/runner/Library/Developer/CoreSimulator/Devices/SIM-27/data/Launch Smoke.app/Launch Smoke'
grep -Fxq 'classification=launch-passed' "$temporary_root/executable-with-space/output"

for invalid_executable in ' LaunchSmoke' 'LaunchSmoke '; do
  if run_case invalid-executable-whitespace STUB_EXECUTABLE="$invalid_executable"; then
    echo 'Expected executable whitespace at the boundary to fail.' >&2
    exit 1
  fi
  grep -Fxq 'failure-reason=invalid-app' "$temporary_root/invalid-executable-whitespace/output"
done

if run_case bootstatus-rejected STUB_BOOTSTATUS_FAILS=true; then
  echo 'Expected bootstatus failure to fail.' >&2
  exit 1
fi
grep -Fq 'did not finish booting' "$temporary_root/bootstatus-rejected/launch.log"
grep -Fxq 'failure-reason=simulator-boot-failed' "$temporary_root/bootstatus-rejected/output"

if run_case install-rejected STUB_INSTALL_FAILS=true; then
  echo 'Expected install failure to fail.' >&2
  exit 1
fi
grep -Fq 'stubbed install rejection' "$temporary_root/install-rejected/launch.log"
grep -Fxq 'failure-reason=install-failed' "$temporary_root/install-rejected/output"

if run_case missing-app APP_PATH="$temporary_root/Missing.app"; then
  echo 'Expected a missing app to fail.' >&2
  exit 1
fi
grep -Fq 'Built simulator app is missing or has no Info.plist' "$temporary_root/missing-app/launch.log"
grep -Fxq 'launched-pid=unknown' "$temporary_root/missing-app/output"

if run_case missing-app-input APP_PATH=; then
  echo 'Expected an empty app path to fail through the action contract.' >&2
  exit 1
fi
grep -Fq 'APP_PATH is required' "$temporary_root/missing-app-input/launch.log"
grep -Fxq 'classification=launch-failed' "$temporary_root/missing-app-input/output"
grep -Fxq 'failure-reason=invalid-input' "$temporary_root/missing-app-input/output"

if run_case invalid-survival SURVIVAL_SECONDS=0; then
  echo 'Expected an invalid survival window to fail.' >&2
  exit 1
fi
grep -Fq 'SURVIVAL_SECONDS must be a whole number from 1 through 120' "$temporary_root/invalid-survival/launch.log"
grep -Fxq 'failure-reason=invalid-input' "$temporary_root/invalid-survival/output"

if run_case malformed-selection STUB_MALFORMED_SELECTION=true; then
  echo 'Expected a malformed selected simulator identity to fail.' >&2
  exit 1
fi
grep -Fxq 'failure-reason=runtime-selection-failed' "$temporary_root/malformed-selection/output"

if run_case unexpected-command-failure STUB_SLEEP_FAILS=true; then
  echo 'Expected an unexpected sleep failure to fail.' >&2
  exit 1
fi
grep -Fxq 'failure-reason=unexpected-error' "$temporary_root/unexpected-command-failure/output"

if run_case boot-race-other-owner STUB_BOOT_FAILS=true STUB_BOOT_RACE_OTHER_OWNER=true; then
  :
else
  echo 'Expected a simulator booted by another process to become ready.' >&2
  exit 1
fi
if grep -Fq 'simctl shutdown SIM-27' "$temporary_root/boot-race-other-owner/calls"; then
  echo 'The action shut down a simulator booted by another process.' >&2
  exit 1
fi
grep -Fxq 'simctl bootstatus SIM-27' "$temporary_root/boot-race-other-owner/calls"

run_case boot-race-other-owner-booting \
  STUB_BOOT_FAILS=true \
  STUB_BOOT_RACE_OTHER_OWNER=true \
  STUB_RACE_STATE=Booting
if grep -Fq 'simctl shutdown SIM-27' "$temporary_root/boot-race-other-owner-booting/calls"; then
  echo 'The action shut down a simulator another process was still booting.' >&2
  exit 1
fi
grep -Fxq 'simctl bootstatus SIM-27' "$temporary_root/boot-race-other-owner-booting/calls"

run_case boot-race-reread-shutdown \
  STUB_BOOT_FAILS=true \
  STUB_BOOT_RACE_OTHER_OWNER=true \
  STUB_RACE_STATE=Shutdown
grep -Fxq 'simctl bootstatus SIM-27 -b' "$temporary_root/boot-race-reread-shutdown/calls"
grep -Fxq 'simctl shutdown SIM-27' "$temporary_root/boot-race-reread-shutdown/calls"

if run_case boot-race-state-unreadable \
  STUB_BOOT_FAILS=true \
  STUB_BOOT_RACE_OTHER_OWNER=true \
  STUB_RACE_DEVICE_MISSING=true; then
  echo 'Expected an unreadable simulator state after boot rejection to fail.' >&2
  exit 1
fi
grep -Fxq 'failure-reason=simulator-boot-failed' "$temporary_root/boot-race-state-unreadable/output"
if grep -Fq 'simctl bootstatus SIM-27' "$temporary_root/boot-race-state-unreadable/calls"; then
  echo 'The action waited for a simulator whose ownership and state were unknown.' >&2
  exit 1
fi
if grep -Fq 'simctl shutdown SIM-27' "$temporary_root/boot-race-state-unreadable/calls"; then
  echo 'The action claimed ownership after the simulator state became unreadable.' >&2
  exit 1
fi

run_case three-component-sdk STUB_SDK_NAME=iphonesimulator27.0.1
grep -Fxq 'classification=launch-passed' "$temporary_root/three-component-sdk/output"
grep -Fxq 'app-sdk-major=27' "$temporary_root/three-component-sdk/output"

if run_case excessive-survival SURVIVAL_SECONDS=121; then
  echo 'Expected an excessive survival window to fail.' >&2
  exit 1
fi
grep -Fq 'SURVIVAL_SECONDS must be a whole number from 1 through 120' "$temporary_root/excessive-survival/launch.log"

if run_case invalid-ios-major EXPECTED_IOS_MAJOR=019; then
  echo 'Expected a zero-padded iOS major to fail.' >&2
  exit 1
fi
grep -Fq 'EXPECTED_IOS_MAJOR must be a positive whole number' "$temporary_root/invalid-ios-major/launch.log"

if run_case invalid-log-path LAUNCH_LOG_PATH=$'/tmp/launch.log\ninjected=value'; then
  echo 'Expected a multiline log path to fail.' >&2
  exit 1
fi
grep -Fq 'LAUNCH_LOG_PATH must be a single-line path' "$temporary_root/invalid-log-path/command.log"
if [[ -e "$temporary_root/invalid-log-path/output" ]]; then
  grep -Fxq 'classification=launch-failed' "$temporary_root/invalid-log-path/output"
  grep -Fxq 'bundle-id=unknown' "$temporary_root/invalid-log-path/output"
  grep -Fxq 'launched-pid=unknown' "$temporary_root/invalid-log-path/output"
  grep -Fxq 'simulator-udid=unknown' "$temporary_root/invalid-log-path/output"
else
  echo 'A rejected log path did not publish its failure classification.' >&2
  exit 1
fi

unwritable_parent="$temporary_root/unwritable-parent"
touch "$unwritable_parent"
if run_case unwritable-log-path LAUNCH_LOG_PATH="$unwritable_parent/launch.log"; then
  echo 'Expected an uncreatable log path to fail.' >&2
  exit 1
fi
grep -Fq 'LAUNCH_LOG_PATH could not be created' "$temporary_root/unwritable-log-path/command.log"
grep -Fxq 'classification=launch-failed' "$temporary_root/unwritable-log-path/output"
grep -Fxq 'bundle-id=unknown' "$temporary_root/unwritable-log-path/output"
grep -Fxq 'launched-pid=unknown' "$temporary_root/unwritable-log-path/output"

default_log_root="$temporary_root/default-log-path"
mkdir -p "$default_log_root"
current_case=default-log-path
: > "$default_log_root/calls"
env \
  APP_PATH="$app_path" \
  EXPECTED_IOS_MAJOR=27 \
  SURVIVAL_SECONDS=1 \
  LAUNCH_LOG_PATH= \
  RUNNER_TEMP="$default_log_root" \
  GITHUB_OUTPUT="$default_log_root/output" \
  GITHUB_STEP_SUMMARY="$default_log_root/summary" \
  XCRUN_BIN="$stub_bin/xcrun" \
  PYTHON_BIN=python3 \
  PLIST_BUDDY_BIN="$stub_bin/plist-buddy" \
  PS_BIN="$stub_bin/ps" \
  SLEEP_BIN="$stub_bin/sleep" \
  STUB_CALLS="$default_log_root/calls" \
  STUB_DEVICE_UDID=SIM-27 \
  "$BASH" "$script_dir/launch.sh" > "$default_log_root/command.log" 2>&1
default_log_path="$(sed -n 's/^log-path=//p' "$default_log_root/output")"
[[ "$default_log_path" == "$default_log_root"/ios-simulator-launch-*.log ]]
test -s "$default_log_path"

echo 'launch-simulator-app tests passed'
