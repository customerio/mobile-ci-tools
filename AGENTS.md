# Customer.io mobile CI tools

Shared GitHub Actions, reusable workflows, and a Gradle plugin used by the Customer.io mobile SDK repos.

## Layout
- `github-actions/<platform>/<name>/v1/` holds composite actions for iOS and Android (for example `github-actions/ios/report-toolchain/v1`). Platform-neutral actions sit at `github-actions/<name>/v1/` (for example `github-actions/wait-until-downloadable/v1`).
- `.github/workflows/` holds this repo's own CI. `ios-test.yml`, `ios-lint.yml`, `ios-lint-linux.yml`, `macos-runner-select.yml` and `dismiss-stale-approvals.yml` are reusable workflows (`workflow_call`) that other repos call. `macos-runner-select.yml` wraps `github-actions/macos-runner-select/v1/` and picks the runner label for a caller's macOS job; release jobs must not call it. `dismiss-stale-approvals.yml` dismisses approvals of earlier commits on PRs opened by one author (Moby by default); callers trigger it on `pull_request` because GitHub blocks `pull_request_target` in public repos by default.
- `gradle-plugins/android-publish/` is the Gradle plugin published to Maven Central as `io.customer.android:android-publish`.

## Commands
Run from the repo root.
- iOS action tests: `bash github-actions/ios/report-toolchain/v1/test.sh` and `bash github-actions/ios/launch-simulator-app/v1/test.sh`
- Slack action test: `bash github-actions/slack-notify-scheduled-failure/v1/test.sh`
- macOS runner selector test: `bash github-actions/macos-runner-select/v1/test.sh`
- Shell lint: `shellcheck github-actions/ios/*/v1/*.sh`, `shellcheck github-actions/slack-notify-scheduled-failure/v1/*.sh` and `shellcheck github-actions/macos-runner-select/v1/*.sh`
- wait-until-downloadable tests: `python3 -m unittest discover -s github-actions/wait-until-downloadable/v1 -v`
- android-publish plugin: `cd gradle-plugins/android-publish && ./gradlew build publishToMavenLocal`

## Gotchas
- Do not change `pluginVersion` in `gradle-plugins/android-publish/gradle.properties` unless you intend a release. Merging a non-SNAPSHOT `pluginVersion` that has no `android-publish-v<version>` tag to `main` publishes to Maven Central (`.github/workflows/android-publish-release.yml`). A `-SNAPSHOT` version or an already-tagged version publishes nothing on push. The release and dry-run procedure is in `gradle-plugins/android-publish/RELEASING.md`.
