#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/macos-runner-select.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

stub_bin="$temporary_root/bin"
mkdir -p "$stub_bin"

# Serves API responses from $STUB_FIXTURES. The URL path and query map to a
# file name with every character other than letters and digits turned into _.
# A runs listing without a fixture is empty; any other missing fixture is a 404.
# Each call's arguments and stdin are logged so tests can count calls and check
# that the token never reaches the command line.
cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
output=""
url=""
args=("$@")
while (( $# > 0 )); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --config|--connect-timeout|--max-time|--header) shift 2 ;;
    *) url="$1"; shift ;;
  esac
done
stdin="$(cat)"
printf '%s | %s\n' "${args[*]}" "$stdin" >> "$STUB_CALL_LOG"
if [[ "${STUB_CURL_FAIL:-false}" == "true" ]]; then
  echo "curl: (28) Operation timed out" >&2
  exit 28
fi
path="${url#https://api.example.test}"
fixture="$STUB_FIXTURES/$(printf '%s' "$path" | tr -c 'A-Za-z0-9' '_')"
if [[ -f "$fixture" ]]; then
  cp "$fixture" "$output"
elif [[ "$path" == *"/actions/runs?status="* ]]; then
  printf '%s\n' '{"total_count":0,"workflow_runs":[]}' > "$output"
else
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
STUB
chmod +x "$stub_bin/curl"

now=1793300000
iso_seconds_ago() {
  date -u -d "@$((now - $1))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$((now - $1))" +%Y-%m-%dT%H:%M:%SZ
}

fixture_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'
}

# write_runs <fixtures> <repository> <status> <run id>...
write_runs() {
  local fixtures="$1" repository="$2" run_status="$3"
  shift 3
  local runs
  runs="$(printf '%s\n' "$@" | jq -R 'tonumber | {id: .}' | jq -s .)"
  jq -n --argjson runs "$runs" '{total_count: ($runs | length), workflow_runs: $runs}' \
    > "$fixtures/$(fixture_name "/repos/customerio/$repository/actions/runs?status=$run_status&per_page=100")"
}

# write_jobs <fixtures> <repository> <run id> <job JSON>...
write_jobs() {
  local fixtures="$1" repository="$2" run_id="$3"
  shift 3
  printf '%s\n' "$@" | jq -s '{total_count: length, jobs: .}' \
    > "$fixtures/$(fixture_name "/repos/customerio/$repository/actions/runs/$run_id/jobs?filter=latest&per_page=100")"
}

# job <status> <label> <runner group or null> <seconds since created>
job() {
  jq -nc \
    --arg status "$1" \
    --arg label "$2" \
    --arg group "$3" \
    --arg created "$(iso_seconds_ago "$4")" \
    '{status: $status, labels: [$label], runner_group_name: (if $group == "null" then null else $group end), created_at: $created}'
}

# run_select <case> [VAR=value]... runs select.sh against $temporary_root/<case>/fixtures.
run_select() {
  local case_name="$1"
  shift
  local case_root="$temporary_root/$case_name"
  mkdir -p "$case_root/fixtures"
  : > "$case_root/calls"
  env \
    PATH="$stub_bin:/usr/bin:/bin" \
    GITHUB_OUTPUT="$case_root/output" \
    GITHUB_STEP_SUMMARY="$case_root/summary" \
    GITHUB_API_URL=https://api.example.test \
    GITHUB_REPOSITORY=customerio/customerio-ios \
    GITHUB_REPOSITORY_OWNER=customerio \
    STUB_FIXTURES="$case_root/fixtures" \
    STUB_CALL_LOG="$case_root/calls" \
    SELECT_NOW="$now" \
    SELECT_ENABLED=true \
    SELECT_GITHUB_LABEL=xcode-27 \
    SELECT_OVERFLOW_LABEL=second-pool-macos \
    SELECT_REPOSITORIES=customerio-ios,customerio-expo-plugin,customerio-reactnative,customerio-flutter,customerio-ios-fcm \
    SELECT_TOKEN=stub-token-value \
    "$@" \
    bash "$script_dir/select.sh"
}

prepare() {
  mkdir -p "$temporary_root/$1/fixtures"
  printf '%s\n' "$temporary_root/$1/fixtures"
}

expect() {
  local case_name="$1" label="$2" reason="$3"
  grep -qx "label=$label" "$temporary_root/$case_name/output"
  grep -qx "reason=$reason" "$temporary_root/$case_name/output"
}

expect_calls() {
  local case_name="$1" expected="$2" actual
  actual="$(wc -l < "$temporary_root/$case_name/calls" | tr -d ' ')"
  if [[ "$actual" != "$expected" ]]; then
    echo "$case_name: expected $expected API calls, made $actual." >&2
    exit 1
  fi
  grep -qx "api-calls=$expected" "$temporary_root/$case_name/output"
}

# The switch: only the exact string 'true' turns the check on.
for value in false '' TRUE yes 1; do
  run_select "switch-${value:-unset}" SELECT_ENABLED="$value"
  expect "switch-${value:-unset}" xcode-27 switch-off
  expect_calls "switch-${value:-unset}" 0
done

run_select missing-overflow-label SELECT_OVERFLOW_LABEL= > "$temporary_root/missing-overflow-label.log"
expect missing-overflow-label xcode-27 switch-off
expect_calls missing-overflow-label 0
grep -Fq '::warning' "$temporary_root/missing-overflow-label.log"

run_select fork SELECT_PR_NUMBER=42 SELECT_PR_HEAD_REPOSITORY=someone/customerio-ios
expect fork xcode-27 fork
expect_calls fork 0

run_select deleted-fork SELECT_PR_NUMBER=42 SELECT_PR_HEAD_REPOSITORY=
expect deleted-fork xcode-27 fork

run_select no-token SELECT_TOKEN=
expect no-token xcode-27 no-credentials
expect_calls no-token 0

# Quiet pool: every repository is listed twice and nothing fires.
fixtures="$(prepare free)"
write_runs "$fixtures" customerio-ios in_progress 101
write_jobs "$fixtures" customerio-ios 101 \
  "$(job in_progress xcode-27 'GitHub Actions' 300)" \
  "$(job completed ubuntu-latest 'GitHub Actions' 300)" \
  "$(job queued xcode-27 null 10)"
run_select free SELECT_PR_NUMBER=42 SELECT_PR_HEAD_REPOSITORY=customerio/customerio-ios
expect free xcode-27 free
expect_calls free 11
grep -qx 'running=1' "$temporary_root/free/output"
grep -qx 'queued=0' "$temporary_root/free/output"
grep -Fq "| Reason | \`free\` |" "$temporary_root/free/summary"
if grep -Fq 'stub-token-value' <(cut -d'|' -f1 "$temporary_root/free/calls"); then
  echo "The token reached curl's command line." >&2
  exit 1
fi
grep -Fq 'Authorization: Bearer stub-token-value' "$temporary_root/free/calls"
grep -Fq -- '--max-time 5' "$temporary_root/free/calls"

# Capacity: 12 running is free, 13 overflows. Jobs already on the second pool,
# by label or by runner group, and non-Mac jobs are not counted.
build_capacity() {
  local fixtures="$1" count="$2" index jobs=()
  for (( index = 0; index < count; index++ )); do
    if (( index % 2 == 0 )); then
      jobs+=("$(job in_progress macOS-26 'GitHub Actions' 600)")
    else
      jobs+=("$(job in_progress Xcode-27 'GitHub Actions' 600)")
    fi
  done
  write_runs "$fixtures" customerio-expo-plugin in_progress 201 202
  write_jobs "$fixtures" customerio-expo-plugin 201 "${jobs[@]}"
  write_jobs "$fixtures" customerio-expo-plugin 202 \
    "$(job in_progress second-pool-macos 'GitHub Actions' 600)" \
    "$(job in_progress SECOND-POOL-MACOS null 600)" \
    "$(job in_progress macos-26 'Another group' 600)" \
    "$(job in_progress ubuntu-latest 'GitHub Actions' 600)" \
    "$(job queued second-pool-macos null 900)"
}
build_capacity "$(prepare twelve-running)" 12
run_select twelve-running
expect twelve-running xcode-27 free
grep -qx 'running=12' "$temporary_root/twelve-running/output"

build_capacity "$(prepare thirteen-running)" 13
run_select thirteen-running
expect thirteen-running second-pool-macos capacity
grep -qx 'running=13' "$temporary_root/thirteen-running/output"
# Stops at the first run that crosses the threshold: ios (2), expo queued and in_progress, run 201.
expect_calls thirteen-running 5

build_capacity "$(prepare custom-threshold)" 2
run_select custom-threshold SELECT_RUNNING_THRESHOLD=2
expect custom-threshold second-pool-macos capacity

# Queued: a GitHub-pool Mac job waiting 31s overflows; 30s does not.
fixtures="$(prepare queued-30)"
write_runs "$fixtures" customerio-flutter queued 301
write_jobs "$fixtures" customerio-flutter 301 "$(job queued macos-26 null 30)"
run_select queued-30
expect queued-30 xcode-27 free

fixtures="$(prepare queued-31)"
write_runs "$fixtures" customerio-flutter queued 301
write_jobs "$fixtures" customerio-flutter 301 "$(job queued macos-26 null 31)"
run_select queued-31
expect queued-31 second-pool-macos queued
grep -qx 'queued=1' "$temporary_root/queued-31/output"

cp "$temporary_root/queued-31/fixtures/"* "$(prepare queued-custom)/"
run_select queued-custom SELECT_QUEUED_SECONDS=60
expect queued-custom xcode-27 free

# Newline-separated repositories are accepted, and only listed ones are read.
fixtures="$(prepare newline-repositories)"
write_runs "$fixtures" customerio-flutter queued 301
write_jobs "$fixtures" customerio-flutter 301 "$(job queued macos-26 null 31)"
run_select newline-repositories SELECT_REPOSITORIES=$'customerio-ios\ncustomerio-flutter\n'
expect newline-repositories second-pool-macos queued
expect_calls newline-repositories 4

# API errors fall back to the GitHub label.
run_select network-failure STUB_CURL_FAIL=true
expect network-failure xcode-27 api-error
expect_calls network-failure 1

fixtures="$(prepare missing-jobs)"
write_runs "$fixtures" customerio-ios in_progress 404
run_select missing-jobs
expect missing-jobs xcode-27 api-error

fixtures="$(prepare malformed-runs)"
printf '%s\n' 'not json' > "$fixtures/$(fixture_name '/repos/customerio/customerio-ios/actions/runs?status=queued&per_page=100')"
run_select malformed-runs
expect malformed-runs xcode-27 api-error

fixtures="$(prepare malformed-jobs)"
write_runs "$fixtures" customerio-ios in_progress 101
printf '%s\n' '{"jobs":[{"status":"queued","labels":["macos-26"],"created_at":"yesterday"}]}' \
  > "$fixtures/$(fixture_name '/repos/customerio/customerio-ios/actions/runs/101/jobs?filter=latest&per_page=100')"
run_select malformed-jobs
expect malformed-jobs xcode-27 api-error

run_select call-cap SELECT_MAX_API_CALLS=3
expect call-cap xcode-27 api-error
expect_calls call-cap 3
grep -Fq 'cap of 3 API calls' "$temporary_root/call-cap/summary"

run_select time-budget SELECT_TOTAL_SECONDS=0
expect time-budget xcode-27 api-error
expect_calls time-budget 0

# Invalid input.
if run_select bad-threshold SELECT_RUNNING_THRESHOLD=0 > /dev/null; then
  echo "Expected a zero running-threshold to fail." >&2
  exit 1
fi
expect bad-threshold xcode-27 invalid-input

if run_select bad-overflow-label SELECT_OVERFLOW_LABEL=$'second-pool\nreason=free' > /dev/null; then
  echo "Expected a multiline overflow-label to fail." >&2
  exit 1
fi
expect bad-overflow-label xcode-27 invalid-input
if grep -qx 'reason=free' "$temporary_root/bad-overflow-label/output"; then
  echo "overflow-label injected a GitHub output line." >&2
  exit 1
fi

if run_select bad-repository SELECT_REPOSITORIES='customerio/customerio-ios' > /dev/null; then
  echo "Expected an owner-qualified repository to fail." >&2
  exit 1
fi
expect bad-repository xcode-27 invalid-input

if run_select empty-github-label SELECT_GITHUB_LABEL= > /dev/null; then
  echo "Expected an empty github-label to fail." >&2
  exit 1
fi

echo "macos-runner-select tests passed"
