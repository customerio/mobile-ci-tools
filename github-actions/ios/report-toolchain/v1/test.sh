#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/report-ios-toolchain.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

stub_bin="$temporary_root/bin"
mkdir -p "$stub_bin"

cat > "$stub_bin/sw_vers" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -productVersion) printf '%s\n' "${STUB_MACOS_VERSION:-26.5.2}" ;;
  -buildVersion) printf '%s\n' "${STUB_MACOS_BUILD:-25F84}" ;;
  *) exit 2 ;;
esac
STUB

cat > "$stub_bin/uname" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "-m" ]] || exit 2
printf '%s\n' "${STUB_ARCHITECTURE:-arm64}"
STUB

cat > "$stub_bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "-version" ]] || exit 2
printf 'Xcode %s\nBuild version %s\n' "${STUB_XCODE_VERSION:-27.0}" "${STUB_XCODE_BUILD:-27A5228h}"
STUB

cat > "$stub_bin/xcrun" <<'STUB'
#!/usr/bin/env bash
if [[ "${STUB_XCRUN_FAIL:-false}" == "true" ]]; then
  echo "stubbed xcrun failure" >&2
  exit 1
fi
if [[ "$1" == "--sdk" && "$3" == "--show-sdk-version" ]]; then
  case "$2" in
    iphoneos) printf '%s\n' "${STUB_IPHONEOS_SDK:-27.0}" ;;
    iphonesimulator) printf '%s\n' "${STUB_SIMULATOR_SDK:-27.0}" ;;
    *) exit 2 ;;
  esac
elif [[ "$1" == "simctl" && "$2" == "list" && "$3" == "runtimes" ]]; then
  printf '%s\n' 'iOS 27.0 (27.0 - 24A999) - com.apple.CoreSimulator.SimRuntime.iOS-27-0'
else
  exit 2
fi
STUB

chmod +x "$stub_bin/sw_vers" "$stub_bin/uname" "$stub_bin/xcodebuild" "$stub_bin/xcrun"

run_report() {
  local case_name="$1"
  shift
  local case_root="$temporary_root/$case_name"
  mkdir -p "$case_root"
  env \
    PATH="$stub_bin:/usr/bin:/bin" \
    ImageOS=macos26 \
    ImageVersion=20260810.0090.1 \
    GITHUB_OUTPUT="$case_root/output" \
    GITHUB_STEP_SUMMARY="$case_root/summary" \
    "$@" \
    bash "$script_dir/report.sh"
}

run_report verified EXPECTED_XCODE_MAJOR=27 EXPECTED_IOS_SDK_MAJOR=27
grep -qx 'classification=verified-toolchain' "$temporary_root/verified/output"
grep -Fq "Xcode | \`27.0 (27A5228h)\`" "$temporary_root/verified/summary"

run_report report-only EXPECTED_XCODE_MAJOR= EXPECTED_IOS_SDK_MAJOR=
grep -qx 'classification=reported-toolchain' "$temporary_root/report-only/output"

if run_report wrong-xcode EXPECTED_XCODE_MAJOR=26 EXPECTED_IOS_SDK_MAJOR=27; then
  echo "Expected the Xcode major mismatch to fail." >&2
  exit 1
fi
grep -qx 'classification=toolchain-mismatch' "$temporary_root/wrong-xcode/output"
grep -Fq 'Xcode major expected 26, found 27.0' "$temporary_root/wrong-xcode/summary"

if run_report wrong-sdk EXPECTED_XCODE_MAJOR=27 EXPECTED_IOS_SDK_MAJOR=26; then
  echo "Expected the iOS SDK major mismatch to fail." >&2
  exit 1
fi
grep -Fq 'iphoneos SDK major expected 26, found 27.0' "$temporary_root/wrong-sdk/summary"
grep -Fq 'iphonesimulator SDK major expected 26, found 27.0' "$temporary_root/wrong-sdk/summary"

if run_report inspection-failure EXPECTED_XCODE_MAJOR=27 EXPECTED_IOS_SDK_MAJOR=27 STUB_XCRUN_FAIL=true; then
  echo "Expected toolchain inspection failure to fail closed." >&2
  exit 1
fi
grep -qx 'classification=toolchain-mismatch' "$temporary_root/inspection-failure/output"

if run_report invalid-input EXPECTED_XCODE_MAJOR=twenty-seven EXPECTED_IOS_SDK_MAJOR=27; then
  echo "Expected invalid major input to fail." >&2
  exit 1
fi

echo "report-toolchain tests passed"
