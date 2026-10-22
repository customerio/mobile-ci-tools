#!/usr/bin/env bash

set -Eeuo pipefail

current_case=setup
report_test_failure() {
  local status="$?"
  trap - ERR
  echo "slack-notify-scheduled-failure test failed at line $1 while running $current_case" >&2
  exit "$status"
}
trap 'report_test_failure "$LINENO"' ERR

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
action_file="$script_dir/action.yml"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/slack-notify-scheduled-failure.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

fail_test() {
  echo "$1" >&2
  exit 1
}

# macOS /bin/bash 3.2 does not apply set -e to a failing [[ ]], so every
# assertion below ends in an explicit fail_test.
expect_post() {
  local case_name="$1"
  local expected="$2"
  local actual
  actual="$(output_value "$case_name" post)"
  [[ "$actual" == "$expected" ]] || fail_test "$case_name: expected post=$expected, got post=${actual:-<unset>}."
}

# The composite must keep its own event guard and post only a prebuilt file.
current_case=action-definition
grep -Fq "default: '#squad-mobile-alerts'" "$action_file"
grep -Fq "if: steps.prepare.outputs.post == 'true' && inputs.dry_run == 'false' && github.event_name == 'schedule'" "$action_file"
grep -Fq 'uses: slackapi/slack-github-action@dcb1066f776dd043e64d0e8ba94ca15cc7e1875d # v4.0.0' "$action_file"
# shellcheck disable=SC2016 # Matches a literal GitHub expression.
grep -Fq 'payload-file-path: ${{ steps.prepare.outputs.payload-path }}' "$action_file"
grep -Fq 'errors: true' "$action_file"
if grep -Eq '^[[:space:]]+payload:' "$action_file"; then
  fail_test "The action must post a jq-built payload file, not an interpolated payload."
fi
if grep -Fq 'secrets.' "$action_file"; then
  fail_test "The action must receive its webhook through the slack_webhook_url input."
fi

# run_prepare <case> [VAR=value ...] runs prepare.sh with a scheduled-run
# environment. Arguments override the defaults.
run_prepare() {
  local case_name="$1"
  shift
  current_case="$case_name"
  local case_root="$temporary_root/$case_name"
  mkdir -p "$case_root/runner-temp"
  : > "$case_root/output"
  : > "$case_root/summary"
  (
    cd "$case_root"
    env \
      GITHUB_OUTPUT="$case_root/output" \
      GITHUB_STEP_SUMMARY="$case_root/summary" \
      RUNNER_TEMP="$case_root/runner-temp" \
      GITHUB_EVENT_NAME=schedule \
      GITHUB_SERVER_URL=https://github.com \
      GITHUB_REPOSITORY=customerio/customerio-example \
      GITHUB_WORKFLOW='Nightly E2E' \
      GITHUB_JOB=e2e-android \
      GITHUB_RUN_ID=123456789 \
      GITHUB_RUN_ATTEMPT=2 \
      GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
      GITHUB_REF_NAME=main \
      SLACK_ALERT_LABEL='' \
      SLACK_ALERT_CHANNEL='#squad-mobile-alerts' \
      SLACK_ALERT_DRY_RUN=false \
      SLACK_ALERT_HAS_WEBHOOK=true \
      "$@" \
      bash "$script_dir/prepare.sh"
  ) > "$temporary_root/$case_name/stdout" 2> "$temporary_root/$case_name/stderr"
}

output_value() {
  local case_name="$1"
  local key="$2"
  sed -n "s/^$key=//p" "$temporary_root/$case_name/output" | tail -n 1
}

payload_of() {
  output_value "$1" payload-path
}

assert_no_payload() {
  local case_name="$1"
  [[ -z "$(payload_of "$case_name")" ]] || fail_test "$case_name built a payload."
  if find "$temporary_root/$case_name/runner-temp" -name payload.json | grep -q .; then
    fail_test "$case_name wrote a payload file."
  fi
}

# Scheduled run with a label: the payload is posted and carries every field.
run_prepare scheduled-label SLACK_ALERT_LABEL='Inbox E2E'
expect_post scheduled-label true
payload="$(payload_of scheduled-label)"
[[ -f "$payload" && "$payload" == "$temporary_root/scheduled-label/runner-temp/"*"/payload.json" ]] \
  || fail_test "The payload must be a file under RUNNER_TEMP: $payload"
run_url='https://github.com/customerio/customerio-example/actions/runs/123456789/attempts/2'
jq -e --arg run_url "$run_url" '
  .channel == "#squad-mobile-alerts"
  and (.text | contains("customerio/customerio-example"))
  and (.text | contains("Nightly E2E"))
  and (.text | contains("Inbox E2E"))
  and (.text | contains("attempt 2"))
  and (.text | contains("0123456 on main"))
  and (.text | contains("<\($run_url)|View run>"))
  and (.blocks | length == 3)
  and (.blocks | all(.type == "section"))
  and (.blocks[0].text.text | contains("<https://github.com/customerio/customerio-example|customerio/customerio-example>"))
  and (.blocks[1].fields | map(.text) == [
    "*Workflow*\nNightly E2E",
    "*Label*\nInbox E2E",
    "*Attempt*\n2",
    "*Commit*\n<https://github.com/customerio/customerio-example/commit/0123456789abcdef0123456789abcdef01234567|0123456> on main"
  ])
  and (.blocks[2].text.text == "<\($run_url)|View run (attempt 2)>")
' "$payload" > /dev/null
grep -Fq 'Posting the scheduled-run failure to #squad-mobile-alerts.' "$temporary_root/scheduled-label/stdout"
[[ ! -s "$temporary_root/scheduled-label/summary" ]] || fail_test "A live post must not write a step summary."

# Without a label the job id is shown instead.
run_prepare scheduled-job-id
jq -e '
  (.blocks[1].fields[1].text == "*Job*\ne2e-android")
  and (.text | contains("Nightly E2E / e2e-android"))
' "$(payload_of scheduled-job-id)" > /dev/null

# A custom channel reaches the payload.
run_prepare custom-channel SLACK_ALERT_CHANNEL='#mobile-ci-test'
jq -e '.channel == "#mobile-ci-test"' "$(payload_of custom-channel)" > /dev/null

# Event guard: every non-scheduled event exits 0 and builds nothing.
for event in pull_request push workflow_dispatch workflow_run ''; do
  case_name="guard-${event:-empty}"
  run_prepare "$case_name" GITHUB_EVENT_NAME="$event"
  expect_post "$case_name" false
  assert_no_payload "$case_name"
  grep -Fq '::notice title=Slack scheduled-failure alert skipped::' "$temporary_root/$case_name/stdout"
  [[ ! -s "$temporary_root/$case_name/summary" ]] || fail_test "$case_name wrote a step summary."
done

# The guard holds even when the caller's inputs are wrong.
run_prepare guard-invalid-inputs \
  GITHUB_EVENT_NAME=pull_request \
  SLACK_ALERT_DRY_RUN=yes \
  SLACK_ALERT_CHANNEL='' \
  SLACK_ALERT_HAS_WEBHOOK=false
expect_post guard-invalid-inputs false
assert_no_payload guard-invalid-inputs

# Dry run on a pull request: payload in the log and summary, nothing posted.
run_prepare dry-run-pull-request \
  GITHUB_EVENT_NAME=pull_request \
  SLACK_ALERT_DRY_RUN=true \
  SLACK_ALERT_HAS_WEBHOOK=false \
  SLACK_ALERT_LABEL='Dry run'
expect_post dry-run-pull-request false
payload="$(payload_of dry-run-pull-request)"
jq -e '.channel == "#squad-mobile-alerts" and (.text | contains("Dry run"))' "$payload" > /dev/null
grep -Fq 'Dry run: nothing was posted to Slack. A live run with this event (pull_request) would post nothing' \
  "$temporary_root/dry-run-pull-request/stdout"
grep -Fq '"channel": "#squad-mobile-alerts"' "$temporary_root/dry-run-pull-request/stdout"
grep -Eq '^::stop-commands::slack-payload-[0-9a-f]{32}$' "$temporary_root/dry-run-pull-request/stdout"
stop_token="$(sed -n 's/^::stop-commands:://p' "$temporary_root/dry-run-pull-request/stdout")"
grep -Fxq "::$stop_token::" "$temporary_root/dry-run-pull-request/stdout"
grep -Fxq '### Slack scheduled-failure alert (dry run)' "$temporary_root/dry-run-pull-request/summary"
grep -Fq 'Nothing was posted to Slack.' "$temporary_root/dry-run-pull-request/summary"
grep -Fxq '```json' "$temporary_root/dry-run-pull-request/summary"
grep -Fq '"channel": "#squad-mobile-alerts"' "$temporary_root/dry-run-pull-request/summary"

# Dry run on a scheduled event still posts nothing.
run_prepare dry-run-schedule SLACK_ALERT_DRY_RUN=true
expect_post dry-run-schedule false
grep -Fq 'A live run with this event (schedule) would post this payload.' "$temporary_root/dry-run-schedule/summary"

# Invalid inputs on a scheduled run fail without posting.
expect_scheduled_failure() {
  local case_name="$1"
  local message="$2"
  shift 2
  if run_prepare "$case_name" "$@"; then
    fail_test "Expected $case_name to fail."
  fi
  [[ "$(output_value "$case_name" post)" != true ]] || fail_test "$case_name reported post=true."
  assert_no_payload "$case_name"
  grep -Fq "$message" "$temporary_root/$case_name/stdout"
}
expect_scheduled_failure invalid-dry-run "dry_run must be 'true' or 'false'" SLACK_ALERT_DRY_RUN=True
expect_scheduled_failure missing-webhook 'slack_webhook_url is empty' SLACK_ALERT_HAS_WEBHOOK=false
expect_scheduled_failure empty-channel 'channel must be a Slack channel name' SLACK_ALERT_CHANNEL=''
expect_scheduled_failure spaced-channel 'channel must be a Slack channel name' SLACK_ALERT_CHANNEL='#squad mobile'
expect_scheduled_failure missing-run-id 'GITHUB_RUN_ID is not set' GITHUB_RUN_ID=

# Hostile values stay data: valid JSON, mrkdwn-escaped, never executed.
# run_prepare runs inside the case directory, so a relative pwned file would
# land there if any value were evaluated.
# shellcheck disable=SC2016 # The command substitutions must stay literal.
hostile_label='Suite "quoted" <!here> & $(touch pwned) `touch pwned`
::warning title=forged::must-not-run'
run_prepare hostile-label SLACK_ALERT_LABEL="$hostile_label" GITHUB_WORKFLOW='Nightly <E2E> & "smoke"'
[[ ! -e "$temporary_root/hostile-label/pwned" ]] || fail_test "A label value was executed."
payload="$(payload_of hostile-label)"
jq -e '
  (.blocks[1].fields[1].text == "*Label*\nSuite \"quoted\" &lt;!here&gt; &amp; $(touch pwned) `touch pwned`\n::warning title=forged::must-not-run")
  and (.blocks[1].fields[0].text == "*Workflow*\nNightly &lt;E2E&gt; &amp; \"smoke\"")
  and ([.. | strings | select(contains("<!here>"))] | length == 0)
' "$payload" > /dev/null

# The dry-run log wraps the payload so a forged command cannot run.
run_prepare hostile-dry-run SLACK_ALERT_DRY_RUN=true SLACK_ALERT_LABEL="$hostile_label"
[[ ! -e "$temporary_root/hostile-dry-run/pwned" ]] || fail_test "A label value was executed."
stdout_file="$temporary_root/hostile-dry-run/stdout"
grep -Eq '^::stop-commands::slack-payload-[0-9a-f]{32}$' "$stdout_file"
if grep -q '^::warning' "$stdout_file"; then
  fail_test "The dry-run log printed a payload line that starts a workflow command."
fi

# Long values are capped below Slack's field limits.
long_label="$(printf 'x%.0s' {1..500})"
run_prepare long-label SLACK_ALERT_LABEL="$long_label"
jq -e '
  (.blocks[1].fields[1].text | length) == ("*Label*\n" | length) + 200
  and (.blocks[1].fields[1].text | endswith("…"))
' "$(payload_of long-label)" > /dev/null

# No branch name: the commit is shown without "on".
run_prepare no-branch GITHUB_REF_NAME=
jq -e '.blocks[1].fields[3].text | endswith("|0123456>")' "$(payload_of no-branch)" > /dev/null

current_case=finished
echo "slack-notify-scheduled-failure tests passed"
