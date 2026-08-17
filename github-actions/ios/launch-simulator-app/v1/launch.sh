#!/usr/bin/env bash

set -euo pipefail

xcrun_bin="${XCRUN_BIN:-xcrun}"
python_bin="${PYTHON_BIN:-python3}"
plist_buddy_bin="${PLIST_BUDDY_BIN:-/usr/libexec/PlistBuddy}"
ps_bin="${PS_BIN:-ps}"
sleep_bin="${SLEEP_BIN:-sleep}"

app_path="${APP_PATH:?APP_PATH is required}"
expected_ios_major="${EXPECTED_IOS_MAJOR:-}"
survival_seconds="${SURVIVAL_SECONDS:-5}"
log_path="${LAUNCH_LOG_PATH:-${RUNNER_TEMP:-/tmp}/ios-simulator-launch.log}"
bundle_id=unknown
executable=unknown
sdk_name=unknown
app_sdk_major=unknown
simulator_udid=unknown
simulator_runtime=unknown
initial_state=unknown
launched_pid=
booted_by_script=false
installed=false

mkdir -p "$(dirname "$log_path")"
: > "$log_path"

record_failure() {
  local message="$1"
  echo "$message" | tee -a "$log_path" >&2
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
      echo "log-path=$log_path"
    } >> "$GITHUB_OUTPUT"
  fi
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo '## iOS simulator launch smoke'
      echo
      echo '**Classification:** launch-failed'
      echo "**Reason:** $message"
      echo "**App SDK:** \`$sdk_name\`"
      echo "**Runtime:** \`$simulator_runtime\`"
      echo "**Failure log:** \`$log_path\`"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

fail() {
  record_failure "$1"
  exit 1
}

if [[ ! -d "$app_path" || ! -f "$app_path/Info.plist" ]]; then
  fail "Built simulator app is missing or has no Info.plist: $app_path"
fi
if [[ ! "$expected_ios_major" =~ ^[0-9]+$ ]]; then
  fail 'EXPECTED_IOS_MAJOR must be a whole number.'
fi
if [[ ! "$survival_seconds" =~ ^[1-9][0-9]*$ ]]; then
  fail 'SURVIVAL_SECONDS must be a positive whole number.'
fi

if ! bundle_id="$("$plist_buddy_bin" -c 'Print :CFBundleIdentifier' "$app_path/Info.plist" 2>&1)"; then
  fail "The built app has no readable CFBundleIdentifier: $bundle_id"
fi
if ! executable="$("$plist_buddy_bin" -c 'Print :CFBundleExecutable' "$app_path/Info.plist" 2>&1)"; then
  fail "The built app has no readable CFBundleExecutable: $executable"
fi
if ! sdk_name="$("$plist_buddy_bin" -c 'Print :DTSDKName' "$app_path/Info.plist" 2>&1)"; then
  fail "The built app has no readable DTSDKName: $sdk_name"
fi
if [[ ! "$sdk_name" =~ ^iphonesimulator([0-9]+)(\.[0-9]+)?$ ]]; then
  fail "The built app is not an iPhone simulator product: DTSDKName=$sdk_name"
fi
app_sdk_major="${BASH_REMATCH[1]}"

if ! selection="$("$xcrun_bin" simctl list devices available --json | "$python_bin" -c '
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
        candidates.append((major, minor, state == "Booted", device["udid"], state, runtime))

if not candidates:
    sys.exit("No available iPhone simulator matches the requested iOS runtime.")
candidates.sort(reverse=True)
_, _, _, udid, state, runtime = candidates[0]
print(f"{udid}\t{state}\t{runtime}")
' "$expected_ios_major" 2>&1)"; then
  fail "Could not select an iPhone simulator for iOS $expected_ios_major: $selection"
fi

IFS=$'\t' read -r simulator_udid initial_state simulator_runtime <<< "$selection"
if (( expected_ios_major != app_sdk_major )); then
  fail "The app SDK $sdk_name does not match the requested iOS $expected_ios_major validation runtime."
fi

collect_failure_log() {
  local failure_log
  failure_log="$({
    echo
    echo "===== Simulator log for $executable ====="
    "$xcrun_bin" simctl spawn "$simulator_udid" log show \
      --last 2m \
      --style compact \
      --predicate "process == '$executable'" || true
  } 2>&1)"
  printf '%s\n' "$failure_log" | tee -a "$log_path"
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

if [[ "$initial_state" != "Booted" ]]; then
  if ! boot_output="$("$xcrun_bin" simctl boot "$simulator_udid" 2>&1)"; then
    fail "Could not boot simulator $simulator_udid: $boot_output"
  fi
  booted_by_script=true
fi
if ! bootstatus_output="$("$xcrun_bin" simctl bootstatus "$simulator_udid" -b 2>&1)"; then
  fail "Simulator $simulator_udid did not finish booting: $bootstatus_output"
fi
if ! install_output="$("$xcrun_bin" simctl install "$simulator_udid" "$app_path" 2>&1)"; then
  fail "Could not install $bundle_id on simulator $simulator_udid: $install_output"
fi
installed=true

if ! launch_output="$("$xcrun_bin" simctl launch --terminate-running-process "$simulator_udid" "$bundle_id" 2>&1)"; then
  record_failure "simctl could not launch $bundle_id: $launch_output"
  collect_failure_log
  exit 1
fi
printf '%s\n' "$launch_output" | tee -a "$log_path"
escaped_bundle_id="${bundle_id//./\\.}"
launched_pid="$(printf '%s\n' "$launch_output" | sed -nE "s/^${escaped_bundle_id}: ([0-9]+)$/\\1/p" | tail -1)"
if [[ -z "$launched_pid" ]]; then
  record_failure "simctl launch did not return a PID for $bundle_id."
  collect_failure_log
  exit 1
fi

for ((elapsed = 1; elapsed <= survival_seconds; elapsed++)); do
  "$sleep_bin" 1
  if ! process_command="$("$ps_bin" -ww -p "$launched_pid" -o comm= 2>/dev/null)" || [[ "${process_command##*/}" != "$executable" ]]; then
    record_failure "$bundle_id exited or changed identity after ${elapsed}s of the ${survival_seconds}s survival window."
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
