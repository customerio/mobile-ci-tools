#!/usr/bin/env bash

set -euo pipefail

expected_xcode_major="${EXPECTED_XCODE_MAJOR:-}"
expected_ios_sdk_major="${EXPECTED_IOS_SDK_MAJOR:-}"

for expected_major in "$expected_xcode_major" "$expected_ios_sdk_major"; do
  if [[ -n "$expected_major" && ! "$expected_major" =~ ^[0-9]+$ ]]; then
    echo "Expected major versions must contain only decimal digits: $expected_major" >&2
    exit 2
  fi
done

write_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

write_summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

record_mismatch() {
  mismatch_reasons+=("$1")
}

version_major() {
  local version="$1"
  local major="${version%%.*}"
  if [[ ! "$major" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  printf '%s\n' "$major"
}

mismatch_reasons=()
actual_image_os="${ImageOS:-missing}"
actual_image_version="${ImageVersion:-missing}"

if ! actual_macos_version="$(sw_vers -productVersion 2>&1)"; then
  record_mismatch "sw_vers could not read the macOS version: $actual_macos_version"
  actual_macos_version="missing"
fi
if ! actual_macos_build="$(sw_vers -buildVersion 2>&1)"; then
  record_mismatch "sw_vers could not read the macOS build: $actual_macos_build"
  actual_macos_build="missing"
fi
if ! actual_architecture="$(uname -m 2>&1)"; then
  record_mismatch "uname could not read the runner architecture: $actual_architecture"
  actual_architecture="missing"
fi

actual_xcode_version="missing"
actual_xcode_build="missing"
if xcode_version_output="$(xcodebuild -version 2>&1)"; then
  actual_xcode_version="$(awk '/^Xcode / { print $2; exit }' <<< "$xcode_version_output")"
  actual_xcode_build="$(awk '/^Build version / { print $3; exit }' <<< "$xcode_version_output")"
  if [[ -z "$actual_xcode_version" || -z "$actual_xcode_build" ]]; then
    record_mismatch "xcodebuild returned an unrecognized version response: $xcode_version_output"
    actual_xcode_version="${actual_xcode_version:-missing}"
    actual_xcode_build="${actual_xcode_build:-missing}"
  fi
else
  record_mismatch "xcodebuild could not inspect the selected Xcode: $xcode_version_output"
fi

actual_iphoneos_sdk="missing"
if ! actual_iphoneos_sdk="$(xcrun --sdk iphoneos --show-sdk-version 2>&1)"; then
  record_mismatch "xcrun could not inspect the iphoneos SDK: $actual_iphoneos_sdk"
  actual_iphoneos_sdk="missing"
fi
actual_simulator_sdk="missing"
if ! actual_simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-version 2>&1)"; then
  record_mismatch "xcrun could not inspect the iphonesimulator SDK: $actual_simulator_sdk"
  actual_simulator_sdk="missing"
fi
runtime_output=""
if ! runtime_output="$(xcrun simctl list runtimes 2>&1)"; then
  record_mismatch "simctl could not list installed runtimes: $runtime_output"
  runtime_output="unavailable"
fi

if [[ -n "$expected_xcode_major" ]]; then
  if ! actual_xcode_major="$(version_major "$actual_xcode_version")"; then
    record_mismatch "Xcode version is not numeric: $actual_xcode_version"
  elif [[ "$actual_xcode_major" != "$expected_xcode_major" ]]; then
    record_mismatch "Xcode major expected $expected_xcode_major, found $actual_xcode_version"
  fi
fi

if [[ -n "$expected_ios_sdk_major" ]]; then
  if ! actual_iphoneos_major="$(version_major "$actual_iphoneos_sdk")"; then
    record_mismatch "iphoneos SDK version is not numeric: $actual_iphoneos_sdk"
  elif [[ "$actual_iphoneos_major" != "$expected_ios_sdk_major" ]]; then
    record_mismatch "iphoneos SDK major expected $expected_ios_sdk_major, found $actual_iphoneos_sdk"
  fi
  if ! actual_simulator_major="$(version_major "$actual_simulator_sdk")"; then
    record_mismatch "iphonesimulator SDK version is not numeric: $actual_simulator_sdk"
  elif [[ "$actual_simulator_major" != "$expected_ios_sdk_major" ]]; then
    record_mismatch "iphonesimulator SDK major expected $expected_ios_sdk_major, found $actual_simulator_sdk"
  fi
fi

echo "Apple toolchain report"
echo "  runner image: $actual_image_os $actual_image_version"
echo "  macOS: $actual_macos_version ($actual_macos_build)"
echo "  architecture: $actual_architecture"
echo "  Xcode: $actual_xcode_version ($actual_xcode_build)"
echo "  iphoneos SDK: $actual_iphoneos_sdk"
echo "  iphonesimulator SDK: $actual_simulator_sdk"
echo
echo "$runtime_output"

write_output image-version "$actual_image_version"
write_output xcode-version "$actual_xcode_version"
write_output xcode-build "$actual_xcode_build"
write_output iphoneos-sdk "$actual_iphoneos_sdk"
write_output iphonesimulator-sdk "$actual_simulator_sdk"

write_summary "## Apple toolchain"
write_summary ""
write_summary "| Field | Value |"
write_summary "| --- | --- |"
write_summary "| Runner image | \`$actual_image_os $actual_image_version\` |"
write_summary "| macOS | \`$actual_macos_version ($actual_macos_build)\` |"
write_summary "| Architecture | \`$actual_architecture\` |"
write_summary "| Xcode | \`$actual_xcode_version ($actual_xcode_build)\` |"
write_summary "| iphoneos SDK | \`$actual_iphoneos_sdk\` |"
write_summary "| iphonesimulator SDK | \`$actual_simulator_sdk\` |"

if (( ${#mismatch_reasons[@]} > 0 )); then
  write_output classification toolchain-mismatch
  write_summary ""
  write_summary "**Classification:** toolchain-mismatch"
  for reason in "${mismatch_reasons[@]}"; do
    echo "::error title=Apple toolchain mismatch::$reason"
    write_summary "- $reason"
  done
  exit 1
fi

classification="reported-toolchain"
if [[ -n "$expected_xcode_major" || -n "$expected_ios_sdk_major" ]]; then
  classification="verified-toolchain"
fi
write_output classification "$classification"
write_summary ""
write_summary "**Classification:** $classification"
