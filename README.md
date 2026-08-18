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
`log-path` output. Use a distinct path for each invocation because the action
truncates its requested log before launch. The action intentionally does not replay app-controlled
simulator logs through the GitHub command parser. Consumers must also set a
job-level `timeout-minutes`, because CoreSimulator commands have no portable
macOS command-level timeout. The requested runtime major must match the built
app's normalized `DTSDKName` major. The app must use an Apple-conforming bundle
identifier containing only ASCII letters, digits, hyphens, and periods.

The action assumes exclusive use of the selected simulator for the tested
bundle identifier. Concurrent jobs sharing one simulator and bundle identifier
can terminate or uninstall each other's fixture; serialize those jobs or use
isolated simulators.

The failure log contains the tested app's own unified-log output. Consumers
should use short artifact retention and must not exercise fixtures that emit
real customer profiles, device tokens, or other sensitive data.
