#!/usr/bin/env bash
#
# Picks the runner label for one macOS job. It returns the overflow label (the
# second pool) only when the switch is on, the run is not a fork PR, a token is
# present, and GitHub's macOS pool is busy:
#   - capacity: running-threshold or more mobile Mac jobs are running there, or
#   - queued: a mobile Mac job has waited there longer than queued-seconds.
# Every other path, including any API error, returns the GitHub label, so a
# failure here never runs a job anywhere it would not run today.

set -euo pipefail

enabled="${SELECT_ENABLED:-}"
github_label="${SELECT_GITHUB_LABEL:-}"
overflow_label="${SELECT_OVERFLOW_LABEL:-}"
running_threshold="${SELECT_RUNNING_THRESHOLD:-13}"
queued_seconds="${SELECT_QUEUED_SECONDS:-30}"
repositories="${SELECT_REPOSITORIES:-}"
token="${SELECT_TOKEN:-}"
owner="${GITHUB_REPOSITORY_OWNER:-}"
pr_number="${SELECT_PR_NUMBER:-}"
pr_head_repository="${SELECT_PR_HEAD_REPOSITORY:-}"
api_url="${GITHUB_API_URL:-https://api.github.com}"

# Bounds on the API work for one selection. The overrides exist for test.sh.
request_seconds="${SELECT_REQUEST_SECONDS:-5}"
total_seconds="${SELECT_TOTAL_SECONDS:-20}"
max_api_calls="${SELECT_MAX_API_CALLS:-40}"

running=0
queued=0
api_calls=0
note=""

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

# Writes the outputs and the summary, then exits with the given status.
finish() {
  local reason="$1"
  local status="${2:-0}"
  local label="$github_label"
  if [[ "$reason" == capacity || "$reason" == queued ]]; then
    label="$overflow_label"
  fi

  echo "Selected runner label '$label' (reason: $reason; running: $running, queued over ${queued_seconds}s: $queued, API calls: $api_calls)."
  if [[ -n "$note" ]]; then
    echo "$note"
  fi

  write_output label "$label"
  write_output reason "$reason"
  write_output running "$running"
  write_output queued "$queued"
  write_output api-calls "$api_calls"

  write_summary "## macOS runner selection"
  write_summary ""
  write_summary "| Field | Value |"
  write_summary "| --- | --- |"
  write_summary "| Label | \`$label\` |"
  write_summary "| Reason | \`$reason\` |"
  write_summary "| Mobile Mac jobs running on GitHub's pool | $running |"
  write_summary "| Mobile Mac jobs queued there over ${queued_seconds}s | $queued |"
  write_summary "| API calls | $api_calls |"
  if [[ -n "$note" ]]; then
    write_summary ""
    write_summary "$note"
  fi
  exit "$status"
}

# A label or name that could start a new output line or command is rejected.
label_pattern='^[A-Za-z0-9._-]+$'
if [[ ! "$github_label" =~ $label_pattern ]]; then
  echo "::error title=macOS runner selection::github-label must be a runner label such as xcode-27, got '${github_label//$'\n'/ }'."
  exit 2
fi

if [[ ! "$running_threshold" =~ ^[1-9][0-9]*$ || ! "$queued_seconds" =~ ^[0-9]+$ ]]; then
  note="running-threshold must be a positive whole number and queued-seconds a whole number."
  echo "::error title=macOS runner selection::$note Using the GitHub label."
  finish invalid-input 1
fi

if [[ "$enabled" != true ]]; then
  note="The switch is not 'true', so the overflow check did not run."
  finish switch-off
fi

if [[ -z "$overflow_label" ]]; then
  note="The switch is on but overflow-label is empty, so the overflow check did not run."
  echo "::warning title=macOS runner selection::$note"
  finish switch-off
fi
if [[ ! "$overflow_label" =~ $label_pattern ]]; then
  note="overflow-label must be a runner label made of letters, digits, '.', '_' and '-'."
  echo "::error title=macOS runner selection::$note Using the GitHub label."
  finish invalid-input 1
fi

# A fork's code never runs on the second pool. A PR whose head repository was
# deleted has an empty head repository and counts as a fork.
if [[ -n "$pr_number" && "$pr_head_repository" != "${GITHUB_REPOSITORY:-}" ]]; then
  note="Pull requests from forks always use the GitHub label."
  finish fork
fi

if [[ -z "$token" ]]; then
  note="No token, so the overflow check did not run. Check the app credentials passed to the selector."
  finish no-credentials
fi

name_pattern='^[A-Za-z0-9._-]+$'
if [[ ! "$owner" =~ $name_pattern ]]; then
  note="GITHUB_REPOSITORY_OWNER is not a valid owner name."
  finish api-error
fi
repositories="${repositories//[$'\r\n,']/ }"
read -r -a repository_list <<< "$repositories"
if (( ${#repository_list[@]} == 0 )); then
  note="repositories is empty."
  echo "::error title=macOS runner selection::$note Using the GitHub label."
  finish invalid-input 1
fi
for repository in "${repository_list[@]}"; do
  if [[ ! "$repository" =~ $name_pattern ]]; then
    note="repositories must be repository names without the owner, got '$repository'."
    echo "::error title=macOS runner selection::$note Using the GitHub label."
    finish invalid-input 1
  fi
done

if ! command -v jq > /dev/null 2>&1 || ! command -v curl > /dev/null 2>&1; then
  note="curl and jq are required."
  finish api-error
fi

now="${SELECT_NOW:-$(date +%s)}"
deadline=$((SECONDS + total_seconds))
response_file="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/macos-runner-select.XXXXXX")"
trap 'rm -f "$response_file"' EXIT

# GETs one API path into $response_file. Fails when the call cap or the total
# time budget is spent, or on any HTTP or network error. The token goes to curl
# on stdin so it never appears in the process list.
api_get() {
  local path="$1"
  local remaining=$((deadline - SECONDS))
  if (( api_calls >= max_api_calls )); then
    note="Stopped at the cap of $max_api_calls API calls before a decision."
    return 1
  fi
  if (( remaining <= 0 )); then
    note="Stopped at the ${total_seconds}s time budget before a decision."
    return 1
  fi
  local limit=$(( remaining < request_seconds ? remaining : request_seconds ))
  api_calls=$((api_calls + 1))
  if ! printf 'header = "Authorization: Bearer %s"\n' "$token" | curl \
      --config - \
      --silent --show-error --fail \
      --connect-timeout "$limit" \
      --max-time "$limit" \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --output "$response_file" \
      "$api_url$path"; then
    note="GET $path failed."
    return 1
  fi
}

# Counts this run's mobile Mac jobs that are on GitHub's pool. A Mac job has a
# label starting with macos or xcode, in any case. Jobs carrying the overflow
# label, or assigned to a runner group other than GitHub's, are on the second
# pool and are left out. Prints "<running> <queued over the limit>".
count_jobs() {
  jq -er \
    --arg overflow "$overflow_label" \
    --argjson now "$now" \
    --argjson queued_seconds "$queued_seconds" '
    [ .jobs[]
      | select(any(.labels[]?; test("^(macos|xcode)"; "i")))
      | select(any(.labels[]?; ascii_downcase == ($overflow | ascii_downcase)) | not)
      | select((.runner_group_name // "GitHub Actions") == "GitHub Actions")
    ] as $mac
    | ($mac | map(select(.status == "in_progress")) | length) as $running
    | ($mac | map(select(.status == "queued" and ($now - (.created_at | fromdateiso8601)) > $queued_seconds)) | length) as $queued
    | "\($running) \($queued)"
  ' "$response_file"
}

# Queued runs first in each repository: their jobs are all waiting, so a long
# wait is found with the fewest calls. The loop stops as soon as either signal
# fires, which keeps busy periods, when it fires early, the cheapest.
for repository in "${repository_list[@]}"; do
  for run_status in queued in_progress; do
    if ! api_get "/repos/$owner/$repository/actions/runs?status=$run_status&per_page=100"; then
      finish api-error
    fi
    if ! run_ids="$(jq -er '.workflow_runs | map(.id | tostring) | join(" ")' "$response_file")"; then
      note="The $run_status runs of $repository could not be read."
      finish api-error
    fi
    read -r -a run_id_list <<< "$run_ids"
    # The guarded expansion keeps an empty list safe under set -u in Bash 3.2.
    for run_id in ${run_id_list[@]+"${run_id_list[@]}"}; do
      if ! api_get "/repos/$owner/$repository/actions/runs/$run_id/jobs?filter=latest&per_page=100"; then
        finish api-error
      fi
      if ! counts="$(count_jobs)"; then
        note="The jobs of $repository run $run_id could not be read."
        finish api-error
      fi
      read -r run_running run_queued <<< "$counts"
      running=$((running + run_running))
      queued=$((queued + run_queued))
      if (( queued > 0 )); then
        note="Stopped early: a Mac job waited longer than ${queued_seconds}s, so counts may be partial."
        finish queued
      fi
      if (( running >= running_threshold )); then
        note="Stopped early: at least $running_threshold Mac jobs are running, so counts may be partial."
        finish capacity
      fi
    done
  done
done

finish free
