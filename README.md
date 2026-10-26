<p align=center>
  <a href="https://customer.io">
    <img src="https://avatars.githubusercontent.com/u/1152079?s=200&v=4" height="60">
  </a>
</p>

# Customer.io Mobile CI/CD Tools

This repository centralizes **GitHub Actions, workflows, Fastlane lanes, and automation scripts** to streamline SDK development across our **Android, iOS, Flutter, React Native, and Expo** repositories.

## Components

- 🚀 **GitHub Actions & Workflows** – Automate builds, tests, and deployments
- 📱 **Fastlane Lanes** – Manage SDK versioning, sample app builds, and releases
- 🔧 **Utility Scripts** – Support automation for CI/CD tasks

### iOS simulator launch smoke

`github-actions/ios/launch-simulator-app/v1` installs an existing simulator
`.app`, launches it on an available iPhone runtime, and fails when the process
does not remain alive for the configured survival window. It is a launch-crash
sentinel, not evidence of lifecycle callbacks, push delivery, signing, or App
Store compatibility.

The action terminates and uninstalls the app after the smoke test. On failure,
launch and survival failures write simulator diagnostics to the explicit
`log-path` input. The `failure-reason` output is one of `invalid-input`, `invalid-app`,
`sdk-mismatch`, `runtime-unavailable`, `runtime-selection-failed`,
`simulator-boot-failed`, `install-failed`, `launch-failed`, `did-not-survive`,
`unexpected-error`, or `none` after success. Outputs
that could not yet be determined use `unknown`. Consumers should pass a known
`log-path`, then add an `if: failure()` artifact-upload step for that same path
with `if-no-files-found: ignore`. A failed composite action is not required to
propagate its mapped outputs, so diagnostics upload must not depend on the
`log-path` output. If the action uses `continue-on-error: true`, gate that upload
on `steps.<id>.outcome == 'failure'` because the job-level `failure()` predicate
remains false. Use a distinct path for each invocation because the action
truncates its requested log before launch. The action intentionally does not replay app-controlled
simulator logs through the GitHub command parser. Consumers must also set a
job-level `timeout-minutes`, because CoreSimulator commands have no portable
macOS command-level timeout. The requested runtime major must match the built
app's normalized `DTSDKName` major. The app must use an Apple-conforming bundle
identifier containing only ASCII letters, digits, hyphens, and periods.
Hosted macOS runners provide the required Python 3, `xcrun`, `ps`, `sleep`, and
`/usr/libexec/PlistBuddy` tools. A self-hosted runner must provide the same tools.

The action assumes exclusive use of the selected simulator for the tested
bundle identifier. Concurrent jobs sharing one simulator and bundle identifier
can terminate or uninstall each other's fixture; serialize those jobs or use
isolated simulators.

The failure log contains the tested app's own unified-log output. Consumers
should use short artifact retention and must not exercise fixtures that emit
real customer profiles, device tokens, or other sensitive data.

### Wait until a release is downloadable

`github-actions/wait-until-downloadable/v1` polls a public registry until one
exact version of every listed package can be downloaded. Run it between the job
that publishes a release and any job that installs that release.

```yaml
  wait-for-registry:
    needs: deploy
    runs-on: ubuntu-latest
    timeout-minutes: 70 # Above the action's 60 minutes, so its report is not cut off.
    steps:
      - uses: customerio/mobile-ci-tools/github-actions/wait-until-downloadable/v1@main
        with:
          ecosystem: maven
          version: ${{ needs.deploy.outputs.version }}
          packages: |
            io.customer.android:core
            io.customer.android:datapipelines
```

| Input | Required | Default | Purpose |
| --- | --- | --- | --- |
| `ecosystem` | yes | | `maven` (Maven Central), `npm`, `pub` (pub.dev) or `cocoapods` (CocoaPods CDN). |
| `version` | yes | | Exact release version, such as `5.0.0` or `3.14.2-beta.1`. Dist-tags such as `latest` are rejected. |
| `packages` | yes | | One per line. Maven packages are `group:artifact`. List every module the consumer resolves, including transitive modules from the same release. |
| `timeout-minutes` | no | `60` | Whole minutes before the action fails. |

The action requests the same URLs the package manager does, over HTTPS only
(including redirects) and without cache busting. A package counts as downloadable
only when the files name the requested package and version:

- npm: the abbreviated packument lists the version, and the tarball matches `dist.integrity` (sha512).
- pub: `/api/packages/<name>` lists the version, and the archive matches `archive_sha256`.
- Maven: the POM coordinates match. When the POM says Gradle metadata was published, the `.module` component must match too. The `.aar` or `.jar` must download and match the `.module` sha256 when one is listed.
- CocoaPods: the CDN version index lists the version, and the podspec JSON names the pod and version.

Missing files, other HTTP statuses, network errors and mismatches are retried
with backoff from 10 to 60 seconds. Each request is limited to 30 seconds and to
the remaining budget. When the budget runs out, the action fails with one
`::error::` that names each pending package and its last check, and writes a
table to the step summary. Invalid input fails before any request is made. The
action needs Python 3.9 or later as `python3`, and `curl`. Hosted Ubuntu and
macOS runners provide both.

### Scheduled-run failure alerts to Slack

`github-actions/slack-notify-scheduled-failure/v1` posts a failed **scheduled**
run to `#squad-mobile-alerts`. Add it as the last step of every job in a
scheduled workflow:

```yaml
      - name: Alert Slack on a failed scheduled run
        timeout-minutes: 2
        if: (failure() || cancelled()) && github.event_name == 'schedule'
        uses: customerio/mobile-ci-tools/github-actions/slack-notify-scheduled-failure/v1@main
        with:
          slack_webhook_url: ${{ secrets.SLACK_WEBHOOK_URL }}
          label: Inbox E2E # Optional. The job id is shown when it is empty.
```

Set explicit step timeouts whose total stays below the job timeout, including
setup, evidence upload and the alert. For example, reserve 5 minutes of a
60-minute job for evidence and notification. A test **step** timeout makes
`failure()` true and leaves later steps able to run. A **job** timeout can stop
all remaining steps; adding `cancelled()` does not guarantee an alert then.
The condition also attempts an alert for a manually cancelled scheduled run.
Runner loss or failure during job setup still requires monitoring outside the job.

| Input | Required | Default | Purpose |
| --- | --- | --- | --- |
| `slack_webhook_url` | yes | | A legacy Slack incoming webhook that honours the payload's `channel` field. Pass it from a secret. |
| `label` | no | job id | Shown in the message, for example a suite name or a matrix value. |
| `channel` | no | `#squad-mobile-alerts` | Channel name or ID to post to. |
| `dry_run` | no | `'false'` | `'true'` writes the payload to the step summary and the log and posts nothing. |

The message shows the repository, workflow, label (or job id), run attempt,
short SHA and branch, and a link to that run attempt. The action posts only
when `github.event_name` is `schedule`. For any other event it logs a notice
and exits 0, so a mistaken caller `if:` still cannot post for pull request or
manual runs. Keep the caller `if:` anyway so the step is skipped.

Each job that runs the step posts once, so set `label` from the matrix value
in matrix jobs. A job skipped because a job it `needs` failed runs no steps,
so the alert comes from the job that failed. The payload is built with `jq`
and posted by `slackapi/slack-github-action` with `errors: true`, so a
rejected post marks the step as failed in the run.

GitHub loads every action a job references during "Set up job", including
steps whose `if:` is false. Every caller job therefore loads this action on
every run. `action.yml` must stay loadable at `main`, as a composite action
without `pre:` or `post:` steps.
