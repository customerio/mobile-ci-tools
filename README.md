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
