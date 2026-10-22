#!/usr/bin/env bash
#
# Decides whether a failed run should be posted to Slack and builds the JSON
# payload with jq. This script never contacts Slack. The composite action's
# next step posts the payload file only when this script reports post=true.

set -euo pipefail

label="${SLACK_ALERT_LABEL:-}"
channel="${SLACK_ALERT_CHANNEL:-}"
dry_run="${SLACK_ALERT_DRY_RUN:-false}"
has_webhook="${SLACK_ALERT_HAS_WEBHOOK:-false}"
event_name="${GITHUB_EVENT_NAME:-}"

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

fail() {
  echo "::error title=Slack scheduled-failure alert::$1"
  exit 1
}

# Event guard. Outside a dry run, only scheduled runs reach the payload step.
if [[ "$dry_run" != true ]]; then
  if [[ "$event_name" != schedule ]]; then
    echo "::notice title=Slack scheduled-failure alert skipped::Only scheduled runs post to Slack. This run's event is '${event_name:-unknown}', so nothing was posted."
    write_output post false
    exit 0
  fi
  if [[ "$dry_run" != false ]]; then
    fail "dry_run must be 'true' or 'false'. Nothing was posted."
  fi
fi

channel_pattern='^#?[A-Za-z0-9._-]{1,80}$'
if [[ ! "$channel" =~ $channel_pattern ]]; then
  fail "channel must be a Slack channel name such as '#squad-mobile-alerts' or a channel ID. Nothing was posted."
fi

if ! command -v jq > /dev/null 2>&1; then
  fail "jq is required to build the Slack payload. Nothing was posted."
fi

for required in GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_WORKFLOW GITHUB_JOB GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_SHA; do
  if [[ -z "${!required:-}" ]]; then
    fail "$required is not set. Nothing was posted."
  fi
done

if [[ "$dry_run" == false && "$has_webhook" != true ]]; then
  fail "slack_webhook_url is empty. Check that the webhook secret exists in this repository. Nothing was posted."
fi

repository_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"
run_url="$repository_url/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT"
commit_url="$repository_url/commit/$GITHUB_SHA"

if [[ -n "$label" ]]; then
  subject_title=Label
  subject="$label"
else
  subject_title=Job
  subject="$GITHUB_JOB"
fi

payload_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/slack-notify-scheduled-failure.XXXXXX")"
payload_path="$payload_dir/payload.json"

# Every value enters the payload through --arg. Slack mrkdwn needs &, < and >
# escaped, and caps keep the blocks under Slack's per-field limits.
jq -n \
  --arg channel "$channel" \
  --arg repository "$GITHUB_REPOSITORY" \
  --arg repository_url "$repository_url" \
  --arg workflow "$GITHUB_WORKFLOW" \
  --arg subject_title "$subject_title" \
  --arg subject "$subject" \
  --arg attempt "$GITHUB_RUN_ATTEMPT" \
  --arg sha "$GITHUB_SHA" \
  --arg branch "${GITHUB_REF_NAME:-}" \
  --arg commit_url "$commit_url" \
  --arg run_url "$run_url" \
  '
  def cap($n): if length > $n then .[0:$n - 1] + "…" else . end;
  def mrkdwn: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
  ($repository | cap(200) | mrkdwn) as $repository_text
  | ($workflow | cap(200) | mrkdwn) as $workflow_text
  | ($subject | cap(200) | mrkdwn) as $subject_text
  | ($branch | cap(200) | mrkdwn) as $branch_text
  | ($sha | .[0:7]) as $short_sha
  | (if $branch_text == "" then "" else " on \($branch_text)" end) as $on_branch
  | {
      channel: $channel,
      username: "Scheduled CI",
      icon_emoji: ":rotating_light:",
      text: ":rotating_light: Scheduled run failed in \($repository_text): \($workflow_text) / \($subject_text) (attempt \($attempt), \($short_sha)\($on_branch)). <\($run_url)|View run>",
      blocks: [
        {
          type: "section",
          text: {
            type: "mrkdwn",
            text: ":rotating_light: *Scheduled run failed* in <\($repository_url)|\($repository_text)>"
          }
        },
        {
          type: "section",
          fields: [
            { type: "mrkdwn", text: "*Workflow*\n\($workflow_text)" },
            { type: "mrkdwn", text: "*\($subject_title)*\n\($subject_text)" },
            { type: "mrkdwn", text: "*Attempt*\n\($attempt)" },
            { type: "mrkdwn", text: "*Commit*\n<\($commit_url)|\($short_sha)>\($on_branch)" }
          ]
        },
        {
          type: "section",
          text: {
            type: "mrkdwn",
            text: "<\($run_url)|View run (attempt \($attempt))>"
          }
        }
      ]
    }
  ' > "$payload_path"

write_output payload-path "$payload_path"

if [[ "$dry_run" == true ]]; then
  if [[ "$event_name" == schedule ]]; then
    live_behaviour="A live run with this event (schedule) would post this payload."
  else
    live_behaviour="A live run with this event (${event_name:-unknown}) would post nothing: only scheduled runs post."
  fi

  echo "Dry run: nothing was posted to Slack. $live_behaviour"
  # Keep payload text out of the workflow command parser.
  stop_token="slack-payload-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  echo "::stop-commands::$stop_token"
  jq . "$payload_path"
  echo "::$stop_token::"

  write_summary "### Slack scheduled-failure alert (dry run)"
  write_summary ""
  write_summary "Nothing was posted to Slack. $live_behaviour"
  write_summary ""
  write_summary '```json'
  write_summary "$(jq . "$payload_path")"
  write_summary '```'
  write_output post false
  exit 0
fi

write_output post true
echo "Posting the scheduled-run failure to $channel."
