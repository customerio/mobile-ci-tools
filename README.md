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
launch and survival failures write simulator diagnostics to its `log-path`
output. The `failure-reason` output distinguishes invalid inputs and products,
SDK/runtime mismatch, runtime selection or boot failure, install failure,
launch rejection, failure to survive, and unexpected command failure. Outputs
that could not yet be determined use `unknown`. Consumers should add an `if: failure()` artifact-upload step when the
`log-path` output is non-empty; the action intentionally does not replay app-controlled
simulator logs through the GitHub command parser. Consumers must also set a
job-level `timeout-minutes`, because CoreSimulator commands have no portable
macOS command-level timeout. The requested runtime major must match the built
app's normalized `DTSDKName` major.

The failure log contains the tested app's own unified-log output. Consumers
should use short artifact retention and must not exercise fixtures that emit
real customer profiles, device tokens, or other sensitive data.
