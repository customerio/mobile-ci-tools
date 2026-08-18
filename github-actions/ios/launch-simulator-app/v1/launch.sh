#!/usr/bin/env bash

set -euo pipefail

xcrun_bin="${XCRUN_BIN:-xcrun}"
python_bin="${PYTHON_BIN:-python3}"
plist_buddy_bin="${PLIST_BUDDY_BIN:-/usr/libexec/PlistBuddy}"
ps_bin="${PS_BIN:-ps}"
sleep_bin="${SLEEP_BIN:-sleep}"

app_path="${APP_PATH:-}"
expected_ios_major="${EXPECTED_IOS_MAJOR:-}"
survival_seconds="${SURVIVAL_SECONDS:-10}"
log_path="${LAUNCH_LOG_PATH:-${RUNNER_TEMP:-/tmp}/ios-simulator-launch-${BASHPID:-$$}.log}"
bundle_id=unknown
executable=unknown
sdk_name=unknown
app_sdk_major=unknown
simulator_udid=unknown
simulator_runtime=unknown
initial_state=unknown
launched_pid=unknown
booted_by_script=false
installed=false
failure_recorded=false

early_failure() {
  local message="$1"
  echo "::error title=iOS simulator launch smoke::$message"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "bundle-id=$bundle_id"
      echo "launched-pid=$launched_pid"
      echo "simulator-udid=$simulator_udid"
      echo "simulator-runtime=$simulator_runtime"
      echo "app-sdk-name=$sdk_name"
      echo "app-sdk-major=$app_sdk_major"
      echo 'classification=launch-failed'
      echo 'failure-reason=invalid-input'
      echo 'log-path=unknown'
    } >> "$GITHUB_OUTPUT"
  fi
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo '## iOS simulator launch smoke'
      echo
      echo '**Classification:** launch-failed'
      echo '**Failure category:** invalid-input'
      echo '**Reason:**'
      echo
      echo "    $message"
      echo "**Failure log:** \`unknown\`"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
}

if [[ "$log_path" == *$'\r'* || "$log_path" == *$'\n'* ]]; then
  early_failure 'LAUNCH_LOG_PATH must be a single-line path.'
fi
if ! mkdir -p "$(dirname "$log_path")" || ! : > "$log_path"; then
  early_failure 'LAUNCH_LOG_PATH could not be created.'
fi

single_line() {
  local value="$1"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  printf '%s' "$value"
}

github_command_value() {
  local value="$1"
  value="${value//'%'/'%25'}"
  value="${value//$'\r'/'%0D'}"
  value="${value//$'\n'/'%0A'}"
  printf '%s' "$value"
}

record_failure() {
  local reason="$1"
  local message="$2"
  local safe_message
  local annotation_message
  local safe_bundle_id
  local safe_launched_pid
  local safe_simulator_udid
  local safe_simulator_runtime
  local safe_sdk_name
  local safe_app_sdk_major
  local safe_log_path
  failure_recorded=true
  safe_message="$(single_line "$message")"
  annotation_message="$(github_command_value "$message")"
  safe_bundle_id="$(single_line "$bundle_id")"
  safe_launched_pid="$(single_line "$launched_pid")"
  safe_simulator_udid="$(single_line "$simulator_udid")"
  safe_simulator_runtime="$(single_line "$simulator_runtime")"
  safe_sdk_name="$(single_line "$sdk_name")"
  safe_app_sdk_major="$(single_line "$app_sdk_major")"
  safe_log_path="$(single_line "$log_path")"

  printf '%s\n' "$message" >> "$log_path"
  printf 'iOS simulator launch smoke failed: %s\n' "$safe_message" >&2
  echo "::error title=iOS simulator launch smoke::$annotation_message"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "bundle-id=$safe_bundle_id"
      echo "launched-pid=$safe_launched_pid"
      echo "simulator-udid=$safe_simulator_udid"
      echo "simulator-runtime=$safe_simulator_runtime"
      echo "app-sdk-name=$safe_sdk_name"
      echo "app-sdk-major=$safe_app_sdk_major"
      echo 'classification=launch-failed'
      echo "failure-reason=$reason"
      echo "log-path=$safe_log_path"
    } >> "$GITHUB_OUTPUT"
  fi
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo '## iOS simulator launch smoke'
      echo
      echo '**Classification:** launch-failed'
      echo "**Failure category:** $reason"
      echo '**Reason:**'
      echo
      echo "    $safe_message"
      echo "**App SDK:** \`$safe_sdk_name\`"
      echo "**Runtime:** \`$safe_simulator_runtime\`"
      echo "**Failure log:** \`$safe_log_path\`"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

fail() {
  record_failure "$1" "$2"
  exit 1
}

unexpected_failure() {
  local status="$?"
  trap - ERR
  if [[ "$failure_recorded" != true ]]; then
    record_failure unexpected-error "An unexpected command failed while running the launch smoke test."
  fi
  exit "$status"
}
trap unexpected_failure ERR

if [[ -z "$app_path" ]]; then
  fail invalid-input 'APP_PATH is required.'
fi
if [[ ! -d "$app_path" || ! -f "$app_path/Info.plist" ]]; then
  fail invalid-input "Built simulator app is missing or has no Info.plist: $app_path"
fi
if [[ ! "$expected_ios_major" =~ ^[1-9][0-9]*$ ]]; then
  fail invalid-input 'EXPECTED_IOS_MAJOR must be a positive whole number.'
fi
survival_pattern='^([1-9]|[1-9][0-9]|1[01][0-9]|120)$'
if [[ ! "$survival_seconds" =~ $survival_pattern ]]; then
  fail invalid-input 'SURVIVAL_SECONDS must be a whole number from 1 through 120.'
fi

if ! raw_bundle_id="$("$plist_buddy_bin" -c 'Print :CFBundleIdentifier' "$app_path/Info.plist" 2>&1)"; then
  fail invalid-app "The built app has no readable CFBundleIdentifier: $raw_bundle_id"
fi
if [[ ! "$raw_bundle_id" =~ ^[A-Za-z0-9.-]+$ ]]; then
  fail invalid-app 'The built app has an invalid CFBundleIdentifier.'
fi
bundle_id="$raw_bundle_id"

if ! raw_executable="$("$plist_buddy_bin" -c 'Print :CFBundleExecutable' "$app_path/Info.plist" 2>&1)"; then
  fail invalid-app "The built app has no readable CFBundleExecutable: $raw_executable"
fi
# Spaces are valid in an executable name. Restrict the remaining shape so the
# value cannot inject GitHub outputs or an NSPredicate used for failure logs.
executable_pattern='^[-A-Za-z0-9._]+([ ]+[-A-Za-z0-9._]+)*$'
if [[ ! "$raw_executable" =~ $executable_pattern ]]; then
  fail invalid-app 'The built app has an invalid CFBundleExecutable.'
fi
executable="$raw_executable"

if ! raw_sdk_name="$("$plist_buddy_bin" -c 'Print :DTSDKName' "$app_path/Info.plist" 2>&1)"; then
  fail invalid-app "The built app has no readable DTSDKName: $raw_sdk_name"
fi
if [[ ! "$raw_sdk_name" =~ ^iphonesimulator([0-9]+)(\.[0-9]+)*$ ]]; then
  fail invalid-app 'The built app is not an iPhone simulator product.'
fi
app_sdk_major="$((10#${BASH_REMATCH[1]}))"
sdk_name="$raw_sdk_name"
if (( expected_ios_major != app_sdk_major )); then
  fail sdk-mismatch "The app SDK $sdk_name does not match the requested iOS $expected_ios_major validation runtime."
fi

if ! selection="$("$xcrun_bin" simctl list devices available --json 2>> "$log_path" | "$python_bin" -c '
import json
import re
import sys

expected = int(sys.argv[1])
payload = json.load(sys.stdin)
candidates = []
for runtime, devices in payload.get("devices", {}).items():
    match = re.search(r"SimRuntime\.iOS-([0-9]+)(?:-([0-9]+))?", runtime)
    if not match:
        continue
    major = int(match.group(1))
    minor = int(match.group(2) or 0)
    if major != expected:
        continue
    for device in devices:
        if not device.get("isAvailable", True) or "iPhone" not in device.get("name", ""):
            continue
        state = device.get("state", "Shutdown")
        if state not in ("Booted", "Shutdown"):
            continue
        candidates.append((state == "Booted", major, minor, device["udid"], state, runtime))

if not candidates:
    sys.exit("No available iPhone simulator matches the requested iOS runtime.")
candidates.sort(reverse=True)
_, _, _, udid, state, runtime = candidates[0]
print(f"{udid}\t{state}\t{runtime}")
' "$expected_ios_major" 2>> "$log_path")"; then
  fail runtime-unavailable "Could not select an iPhone simulator for iOS $expected_ios_major."
fi

IFS=$'\t' read -r simulator_udid initial_state simulator_runtime <<< "$selection"
if [[ "$selection" == *$'\n'* \
  || ! "$simulator_udid" =~ ^[A-Za-z0-9-]+$ \
  || -z "$initial_state" \
  || ! "$simulator_runtime" =~ ^com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+$ ]]; then
  fail runtime-selection-failed 'Could not parse a single simulator identity from device selection.'
fi

collect_failure_log() {
  local failure_log
  local diagnostic_window_seconds=$((survival_seconds + 60))
  failure_log="$({
    echo
    echo "===== Simulator log for $executable ====="
    "$xcrun_bin" simctl spawn "$simulator_udid" log show \
      --last "${diagnostic_window_seconds}s" \
      --style compact \
      --predicate "process == '$executable' OR process == 'SpringBoard' OR process == 'ReportCrash' OR process == 'launchd_sim'" || true
  } 2>&1)"
  # App-controlled log lines may look like GitHub workflow commands. Preserve
  # them in the artifact without replaying them through the runner console.
  printf '%s\n' "$failure_log" >> "$log_path"
  printf 'Simulator diagnostics were written to %s.\n' "$log_path"
}

cleanup() {
  if [[ "$installed" == true ]]; then
    "$xcrun_bin" simctl terminate "$simulator_udid" "$bundle_id" >/dev/null 2>&1 || true
    "$xcrun_bin" simctl uninstall "$simulator_udid" "$bundle_id" >/dev/null 2>&1 || true
  fi
  if [[ "$booted_by_script" == true ]]; then
    "$xcrun_bin" simctl shutdown "$simulator_udid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bootstatus_boot_if_needed=false
if [[ "$initial_state" == "Shutdown" ]]; then
  bootstatus_boot_if_needed=true
  if boot_output="$("$xcrun_bin" simctl boot "$simulator_udid" 2>&1)"; then
    booted_by_script=true
  else
    # A device observed while transitioning can reject a duplicate boot. Let
    # bootstatus be the authoritative readiness check. Re-read state first so
    # this narrows the chance that cleanup shuts down a simulator another
    # process booted in the race. Shared simulator ownership is unsupported.
    printf 'simctl boot returned: %s\n' "$boot_output" >> "$log_path"
    if current_state="$("$xcrun_bin" simctl list devices available --json 2>> "$log_path" | "$python_bin" -c '
import json
import sys

udid = sys.argv[1]
payload = json.load(sys.stdin)
for devices in payload.get("devices", {}).values():
    for device in devices:
        if device.get("udid") == udid:
            print(device.get("state", "unknown"))
            raise SystemExit(0)
raise SystemExit(1)
' "$simulator_udid" 2>> "$log_path")"; then
      if [[ "$current_state" == "Shutdown" ]]; then
        booted_by_script=true
      else
        # Another owner has already advanced this simulator out of Shutdown.
        # Wait for it without later shutting down state that we do not own.
        bootstatus_boot_if_needed=false
      fi
    else
      # State could not be re-read, so ownership cannot be established and
      # nothing in this job will boot the device. Fail rather than waiting on
      # a boot that may never happen.
      booted_by_script=false
      fail simulator-boot-failed \
        "Simulator $simulator_udid rejected boot and its state could not be re-read: $boot_output"
    fi
  fi
fi
bootstatus_arguments=(simctl bootstatus "$simulator_udid")
if [[ "$bootstatus_boot_if_needed" == true ]]; then
  bootstatus_arguments+=(-b)
fi
if ! bootstatus_output="$("$xcrun_bin" "${bootstatus_arguments[@]}" 2>&1)"; then
  fail simulator-boot-failed "Simulator $simulator_udid did not finish booting: $bootstatus_output"
fi
if ! install_output="$("$xcrun_bin" simctl install "$simulator_udid" "$app_path" 2>&1)"; then
  fail install-failed "Could not install $bundle_id on simulator $simulator_udid: $install_output"
fi
installed=true

if ! launch_output="$("$xcrun_bin" simctl launch --terminate-running-process "$simulator_udid" "$bundle_id" 2>&1)"; then
  record_failure launch-failed "simctl could not launch $bundle_id: $launch_output"
  collect_failure_log
  exit 1
fi
printf '%s\n' "$launch_output" >> "$log_path"
escaped_bundle_id="${bundle_id//./\\.}"
launched_pid="$(printf '%s\n' "$launch_output" | sed -nE "s/^${escaped_bundle_id}: ([1-9][0-9]*)$/\\1/p" | tail -1)"
if [[ -z "$launched_pid" ]]; then
  record_failure launch-failed "simctl launch did not return a PID for $bundle_id."
  collect_failure_log
  exit 1
fi

for ((elapsed = 1; elapsed <= survival_seconds; elapsed++)); do
  "$sleep_bin" 1
  # BSD ps returns the full executable path for comm=. Bind that path to the
  # selected simulator and reject a crashed process waiting to be reaped.
  if process_status="$("$ps_bin" -ww -p "$launched_pid" -o state= -o comm= 2>/dev/null)"; then
    process_status_code=0
  else
    process_status_code="$?"
    process_status=
  fi
  if (( process_status_code > 1 )); then
    record_failure unexpected-error "Could not inspect the launched process after ${elapsed}s."
    collect_failure_log
    exit 1
  fi
  read -r process_state process_command <<< "$process_status" || true
  if [[ -z "$process_status" \
    || "$process_state" != [RSIU]* \
    || "${process_command##*/}" != "$executable" \
    || "$process_command" != *"/Devices/$simulator_udid/"* ]]; then
    printf 'ps observation after %ss: %s\n' \
      "$elapsed" \
      "$(single_line "$process_status")" >> "$log_path"
    record_failure did-not-survive "$bundle_id exited, became non-runnable, or changed identity after ${elapsed}s of the ${survival_seconds}s survival window."
    collect_failure_log
    exit 1
  fi
done

{
  echo "bundle_id=$bundle_id"
  echo "launched_pid=$launched_pid"
  echo "simulator_udid=$simulator_udid"
  echo "simulator_runtime=$simulator_runtime"
  echo "app_sdk_name=$sdk_name"
  echo "app_sdk_major=$app_sdk_major"
  echo "survival_seconds=$survival_seconds"
} >> "$log_path"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "bundle-id=$bundle_id"
    echo "launched-pid=$launched_pid"
    echo "simulator-udid=$simulator_udid"
    echo "simulator-runtime=$simulator_runtime"
    echo "app-sdk-name=$sdk_name"
    echo "app-sdk-major=$app_sdk_major"
    echo 'classification=launch-passed'
    echo 'failure-reason=none'
    echo "log-path=$log_path"
  } >> "$GITHUB_OUTPUT"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo '## iOS simulator launch smoke'
    echo
    echo '**Classification:** launch-passed'
    echo "**Bundle identifier:** \`$bundle_id\`"
    echo "**Runtime:** \`$simulator_runtime\`"
    echo "**App SDK:** \`$sdk_name\`"
    echo "**Survival window:** ${survival_seconds}s"
    echo '**Scope:** install, launch, and process survival only; no callback, push-delivery, signing, or App Store claim'
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "$bundle_id remained alive for ${survival_seconds}s after simulator launch."
