#!/usr/bin/env python3
"""Checks and actions behind the SDK team review bot approval.

An engineer runs the Claude review locally (the sdk-team-review skill). When it
passes, the skill triggers the caller repo's workflow with the PR number, the
reviewed commit and a short review summary. This script decides on GitHub's
side whether that commit can get the bot's approval, and dismisses the bot's
approvals that no longer match the PR.

Commands
  evaluate  Check the PR head. Shadow mode comments the decision on the PR.
            Enforce mode approves the reviewed commit, or comments the reasons.
  dismiss   Dismiss bot approvals whose commit is not the PR head, or all of
            them when the PR's base branch changed.

Inputs come from environment variables (see action.yml). DRY_RUN=true prints
the decision and writes nothing, which also works from a laptop:

  REPO=customerio/customerio-ios-fcm PR_NUMBER=12 HEAD_SHA=<sha> \\
  ATTESTATION='{"v":1,...}' READ_TOKEN="$(gh auth token)" DRY_RUN=true \\
  python3 sdk_team_review.py evaluate
"""

import base64
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

API_URL = os.environ.get("GITHUB_API_URL", "https://api.github.com")
MARKER = "<!-- sdk-team-review -->"
ATTESTATION_VERSION = 1
OK_CONCLUSIONS = {"success", "neutral", "skipped"}
MAX_LISTED_FILES = 10
# Always need a human, whatever the policy says: workflows (including these
# approval workflows), code ownership and repo guidance the reviewer reads.
ALWAYS_PROTECTED = [".github/**", "**/CODEOWNERS", "**/REVIEW.md", "**/CLAUDE.md", "**/AGENTS.md", ".claude/**"]


# ---------------------------------------------------------------------------
# Pure helpers (unit tested)
# ---------------------------------------------------------------------------

def glob_to_regex(pattern):
    """Translate a path glob to a regex. `*` stays inside one directory,
    `**` crosses directories, and `**/` also matches zero directories."""
    out = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def protected_matches(paths, patterns):
    """Return the changed paths that match any protected pattern."""
    regexes = [glob_to_regex(p) for p in patterns]
    return sorted({p for p in paths if any(r.match(p) for r in regexes)})


def changed_paths(files):
    """Paths a PR touches, including the old name of a renamed file."""
    paths = set()
    for f in files:
        paths.add(f["filename"])
        if f.get("previous_filename"):
            paths.add(f["previous_filename"])
    return sorted(paths)


def attestation_problems(raw, head_sha):
    """Check the review summary the skill sent. It is self-reported, so these
    checks only make sure it describes a passing review of this exact commit."""
    try:
        summary = json.loads(raw or "")
    except ValueError:
        return ["The review summary is not valid JSON."]
    if not isinstance(summary, dict):
        return ["The review summary is not a JSON object."]
    problems = []
    if summary.get("v") != ATTESTATION_VERSION:
        problems.append(f"The review summary has unsupported version {summary.get('v')!r}.")
    if summary.get("reviewed_sha") != head_sha:
        problems.append("The review summary is for a different commit than the PR head.")
    if summary.get("verdict") != "pass":
        problems.append("The local review did not pass.")
    if summary.get("important") != 0:
        problems.append("The local review reported Important findings.")
    if str(summary.get("change_safety", "")).strip().lower() != "none":
        problems.append("The local review reported change-safety factors.")
    return problems


def latest_by(items, key, order):
    latest = {}
    for item in items:
        k = key(item)
        if k not in latest or order(item) > order(latest[k]):
            latest[k] = item
    return latest


def ci_problems(check_runs, statuses, advisory=(), ignored=()):
    """Judge CI on the head commit by the latest run of each check, so a run
    cancelled and then re-run counts as its re-run."""
    skip = set(advisory) | set(ignored)
    problems = []
    runs = latest_by(check_runs, lambda r: r["name"], lambda r: r["id"])
    for name, run in sorted(runs.items()):
        if name in skip:
            continue
        if run.get("status") != "completed":
            problems.append(f"`{name}` has not finished.")
        elif run.get("conclusion") not in OK_CONCLUSIONS:
            problems.append(f"`{name}` concluded `{run.get('conclusion')}`.")
    contexts = latest_by(
        statuses,
        lambda s: s["context"],
        lambda s: (s.get("updated_at") or s.get("created_at") or "", s.get("id", 0)),
    )
    for name, status in sorted(contexts.items()):
        if name in skip:
            continue
        if status.get("state") == "pending":
            problems.append(f"`{name}` has not finished.")
        elif status.get("state") != "success":
            problems.append(f"`{name}` reported `{status.get('state')}`.")
    if not [n for n in runs if n not in skip] and not [n for n in contexts if n not in skip]:
        problems.append("No CI ran on this commit.")
    return problems


def evaluate(pr, repo, input_sha, paths, check_runs, statuses, attestation, policy, actor, team_member):
    """Return the reasons the bot must not approve. An empty list means approve.

    team_member is True, False, or None when membership was not checked."""
    reasons = []
    head = pr["head"]
    if pr.get("state") != "open":
        reasons.append("The PR is not open.")
    if pr.get("draft"):
        reasons.append("The PR is a draft.")
    if (head.get("repo") or {}).get("full_name") != repo:
        reasons.append("The PR comes from a fork. Fork PRs always get a human review.")
    if head["sha"] != input_sha:
        reasons.append("The PR head changed after the review. Run the review again on the new commit.")
    reasons.extend(attestation_problems(attestation, head["sha"]))
    hits = protected_matches(paths, ALWAYS_PROTECTED + policy.get("protected_paths", []))
    if hits:
        listed = ", ".join(f"`{p}`" for p in hits[:MAX_LISTED_FILES])
        more = f" and {len(hits) - MAX_LISTED_FILES} more" if len(hits) > MAX_LISTED_FILES else ""
        reasons.append(f"Changes files that always need a human review: {listed}{more}.")
    reasons.extend(ci_problems(
        check_runs, statuses, policy.get("advisory_checks", []), policy.get("ignored_checks", [])))
    if team_member is False:
        reasons.append(f"`{actor}` is not in the `{policy.get('team')}` team.")
    return reasons


def reviews_to_dismiss(reviews, head_sha, bot_login, base_changed):
    """Bot approvals that no longer describe the PR."""
    return [
        r["id"]
        for r in reviews
        if r.get("state") == "APPROVED"
        and (r.get("user") or {}).get("login") == bot_login
        and (base_changed or r.get("commit_id") != head_sha)
    ]


def render_comment(mode, actor, sha, reasons, notes=()):
    short = sha[:7]
    lines = [MARKER]
    if mode == "shadow":
        verdict = "would approve" if not reasons else "would not approve"
        lines.append(f"**SDK team review (shadow mode):** {verdict} `{short}`. Requested by `{actor}`.")
    else:
        lines.append(f"**SDK team review:** did not approve `{short}`. Requested by `{actor}`. A teammate's review is needed, or fix the items below and run the review again.")
    if reasons:
        lines.append("")
        lines.extend(f"- {r}" for r in reasons)
    if notes:
        lines.append("")
        lines.extend(f"_{n}_" for n in notes)
    return "\n".join(lines)


def approval_body(actor, sha, attestation):
    try:
        summary = json.loads(attestation)
    except ValueError:
        summary = {}
    reviewer = summary.get("reviewer", "local Claude review")
    version = summary.get("reviewer_version", "unknown")
    nits = summary.get("nits", 0)
    return (
        f"{MARKER}\nApproved `{sha[:7]}` after a local Claude review with no blocking findings and green CI. "
        f"Requested by `{actor}`. Reviewer: {reviewer} {version}, {nits} nit(s). "
        "Any new push dismisses this approval."
    )


# ---------------------------------------------------------------------------
# GitHub API
# ---------------------------------------------------------------------------

class ApiError(Exception):
    def __init__(self, status, url, payload):
        message = (payload or {}).get("message", "") if isinstance(payload, dict) else str(payload)
        super().__init__(f"GitHub API {status} for {url}: {message}")
        self.status = status


def request(method, url, token, body=None):
    if not url.startswith("http"):
        url = API_URL + url
    data = json.dumps(body).encode() if body is not None else None
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "sdk-team-review",
    }
    if data is not None:
        headers["Content-Type"] = "application/json"
    for attempt in range(3):
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else None), resp.headers.get("Link", "")
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                payload = json.loads(raw) if raw else None
            except ValueError:
                payload = {"message": raw.decode(errors="replace")}
            if e.code >= 500 and attempt < 2:
                time.sleep(2 * (attempt + 1))
                continue
            return e.code, payload, ""
        except urllib.error.URLError:
            if attempt < 2:
                time.sleep(2 * (attempt + 1))
                continue
            raise
        except (OSError, http.client.HTTPException):
            # A read timeout or a dropped connection after the request was sent. Only GET is safe to
            # repeat; a repeated POST could leave a second comment or approval.
            if method == "GET" and attempt < 2:
                time.sleep(2 * (attempt + 1))
                continue
            raise
    raise RuntimeError("unreachable")


def get(url, token):
    status, payload, _ = request("GET", url, token)
    if status != 200:
        raise ApiError(status, url, payload)
    return payload


def get_all(url, token, key=None):
    items = []
    url = url + ("&" if "?" in url else "?") + "per_page=100"
    while url:
        status, payload, link = request("GET", url, token)
        if status != 200:
            raise ApiError(status, url, payload)
        items.extend(payload[key] if key else payload)
        match = re.search(r'<([^>]+)>;\s*rel="next"', link)
        url = match.group(1) if match else None
    return items


def load_policy(repo, path, ref, token):
    status, payload, _ = request("GET", f"/repos/{repo}/contents/{path}?ref={ref}", token)
    if status == 404:
        return None
    if status != 200:
        raise ApiError(status, path, payload)
    return json.loads(base64.b64decode(payload["content"]).decode())


def team_membership(org, team, user, token):
    """True or False with a token that can read org teams, None otherwise."""
    if not token or not team:
        return None
    status, payload, _ = request("GET", f"/orgs/{org}/teams/{team}/memberships/{user}", token)
    if status == 200:
        return payload.get("state") == "active"
    if status == 404:
        return False
    return None


def upsert_comment(repo, number, body, token):
    comments = get_all(f"/repos/{repo}/issues/{number}/comments", token)
    mine = [c for c in comments if MARKER in (c.get("body") or "") and (c.get("user") or {}).get("type") == "Bot"]
    if mine:
        status, payload, _ = request("PATCH", f"/repos/{repo}/issues/comments/{mine[-1]['id']}", token, {"body": body})
    else:
        status, payload, _ = request("POST", f"/repos/{repo}/issues/{number}/comments", token, {"body": body})
    if status not in (200, 201):
        raise ApiError(status, "comment", payload)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def env(name, default=None, required=False):
    value = os.environ.get(name, default)
    if required and not value:
        sys.exit(f"Missing required input {name}.")
    return value


def write_output(name, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as f:
            f.write(f"{name}={value}\n")


def write_summary(text):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as f:
            f.write(text + "\n")


def cmd_evaluate():
    repo = env("REPO", os.environ.get("GITHUB_REPOSITORY"), required=True)
    number = int(env("PR_NUMBER", required=True))
    input_sha = env("HEAD_SHA", required=True)
    attestation = env("ATTESTATION", "")
    mode = env("MODE", "shadow")
    actor = env("ACTOR", os.environ.get("GITHUB_ACTOR", "unknown"))
    policy_path = env("POLICY_PATH", ".github/sdk-team-review.json")
    read_token = env("READ_TOKEN", required=True)
    app_token = env("APP_TOKEN", "")
    dry_run = env("DRY_RUN", "false") == "true"
    if mode not in ("shadow", "enforce"):
        sys.exit(f"Unknown mode {mode!r}. Use shadow or enforce.")
    if mode == "enforce" and not app_token and not dry_run:
        sys.exit("Enforce mode needs the approver app token.")

    repo_info = get(f"/repos/{repo}", read_token)
    default_branch = env("DEFAULT_BRANCH", repo_info["default_branch"])
    pr = get(f"/repos/{repo}/pulls/{number}", read_token)
    notes = []

    # The policy is read from the default branch so a PR can't loosen it.
    policy = load_policy(repo, policy_path, default_branch, read_token)
    if policy is None:
        if mode == "enforce":
            sys.exit(f"No {policy_path} on {default_branch}. Enforce mode needs it.")
        policy = load_policy(repo, policy_path, pr["head"]["sha"], read_token) or {}
        notes.append(f"{policy_path} is not on {default_branch} yet, so this run used the PR's copy.")

    paths = changed_paths(get_all(f"/repos/{repo}/pulls/{number}/files", read_token))
    head_sha = pr["head"]["sha"]
    check_runs = get_all(f"/repos/{repo}/commits/{head_sha}/check-runs?filter=all", read_token, key="check_runs")
    statuses = get_all(f"/repos/{repo}/commits/{head_sha}/statuses", read_token)
    team_member = team_membership(repo.split("/")[0], policy.get("team"), actor, app_token)
    if team_member is None:
        if mode == "enforce" and not dry_run:
            sys.exit("Could not check team membership. The approver app needs members:read.")
        notes.append("Team membership was not checked in this run.")

    reasons = evaluate(pr, repo, input_sha, paths, check_runs, statuses, attestation, policy, actor, team_member)
    decision = "approve" if not reasons else "refuse"
    write_output("decision", decision)

    if dry_run:
        print(json.dumps({"decision": decision, "reasons": reasons, "notes": notes, "head": head_sha}, indent=2))
        return

    if mode == "shadow" or reasons:
        body = render_comment(mode, actor, head_sha, reasons, notes)
        upsert_comment(repo, number, body, read_token)
        write_summary(body)
        return

    # Enforce: approve only if the head is still the reviewed commit.
    if get(f"/repos/{repo}/pulls/{number}", read_token)["head"]["sha"] != input_sha:
        upsert_comment(repo, number, render_comment(mode, actor, head_sha, [
            "The PR head changed while this run was checking it. Run the review again on the new commit."]), read_token)
        write_output("decision", "refuse")
        return
    status, payload, _ = request("POST", f"/repos/{repo}/pulls/{number}/reviews", app_token, {
        "commit_id": input_sha, "event": "APPROVE", "body": approval_body(actor, input_sha, attestation)})
    if status != 200:
        raise ApiError(status, "approve", payload)
    # A push can land between the check and the approval; take it back if so.
    if get(f"/repos/{repo}/pulls/{number}", read_token)["head"]["sha"] != input_sha:
        request("PUT", f"/repos/{repo}/pulls/{number}/reviews/{payload['id']}/dismissals", app_token, {
            "message": "The PR head changed while the approval was being submitted."})
        write_output("decision", "refuse")
        return
    write_summary(f"Approved `{input_sha[:7]}` on PR #{number}.")


def cmd_dismiss():
    repo = env("REPO", os.environ.get("GITHUB_REPOSITORY"), required=True)
    number = int(env("PR_NUMBER", required=True))
    token = env("READ_TOKEN", required=True)
    bot_login = env("BOT_LOGIN", required=True)
    base_changed = env("BASE_CHANGED", "false") == "true"
    dry_run = env("DRY_RUN", "false") == "true"

    pr = get(f"/repos/{repo}/pulls/{number}", token)
    reviews = get_all(f"/repos/{repo}/pulls/{number}/reviews", token)
    stale = reviews_to_dismiss(reviews, pr["head"]["sha"], bot_login, base_changed)
    reason = "The PR's base branch changed." if base_changed else "New commits were pushed after this approval."
    for review_id in stale:
        if dry_run:
            print(f"Would dismiss review {review_id}: {reason}")
            continue
        status, payload, _ = request(
            "PUT", f"/repos/{repo}/pulls/{number}/reviews/{review_id}/dismissals", token,
            {"message": f"{reason} Run the SDK team review again on the current head."})
        if status != 200:
            raise ApiError(status, f"dismiss {review_id}", payload)
    write_output("dismissed", str(len(stale)))
    write_summary(f"Dismissed {len(stale)} bot approval(s) on PR #{number}.")
    print(f"Dismissed {len(stale)} bot approval(s).")


def main(argv):
    commands = {"evaluate": cmd_evaluate, "dismiss": cmd_dismiss}
    if len(argv) != 2 or argv[1] not in commands:
        sys.exit(f"Usage: {argv[0]} evaluate|dismiss")
    try:
        commands[argv[1]]()
    except ApiError as e:
        sys.exit(str(e))


if __name__ == "__main__":
    main(sys.argv)
