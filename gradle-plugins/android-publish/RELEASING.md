# Releasing & versioning — `io.customer.android:android-publish`

This plugin is published to Maven Central. Releases are **automated but gated on an explicit,
reviewable version bump**, so they can't fire by accident.

## Versioning

- The version lives in **one place**: `pluginVersion` in [`gradle.properties`](./gradle.properties).
- Standard [semver](https://semver.org/). Because consumers **pin** the plugin version, a change
  here never affects a repo until it bumps on its own schedule.
- This logic changes rarely (historically ~once a year), so releases are infrequent and the
  version moves slowly.

## How a release is triggered

The release is driven by the [`Release android-publish plugin`](../../.github/workflows/android-publish-release.yml)
workflow. The **only manual step is bumping `pluginVersion`**:

1. In the PR that changes the plugin, bump `pluginVersion` (e.g. `0.1.0` → `0.2.0`).
2. Merge to `main`.
3. The workflow takes over automatically:
   - builds the plugin,
   - publishes to the Sonatype Central Portal and **closes + releases** the staging repo
     (`publishToSonatype closeAndReleaseSonatypeStagingRepository`),
   - tags the commit `android-publish-v<version>`.

No version is typed at release time, no tag is cut by hand, no dispatch to remember.

## Why it can't over-release

Two independent guards, both automatic:

| Guard | Prevents |
| --- | --- |
| **`paths:` filter** on `gradle-plugins/android-publish/**` | Releases from unrelated commits — iOS/Android actions, Slack, root README, other CI. Those never trigger the workflow. |
| **Tag idempotency** (`android-publish-v<version>` must not already exist) | Releases from plugin-dir changes that *don't* bump the version — a comment, a test, a doc tweak. The workflow runs but no-ops. |

So a release happens **only** when `pluginVersion` changes to a value that hasn't been tagged yet.
This is deliberately not semantic-release: in a shared, mixed-purpose repo, commit-message-driven
versioning would sweep in unrelated commits and mis-attribute or over-fire releases.

## Consuming a released version

```kotlin
// settings.gradle.kts
pluginManagement { repositories { mavenCentral() } }

// build.gradle(.kts)
plugins { id("io.customer.android.publish-root") version "<version>" }   // root
plugins { id("io.customer.android.publish-module") version "<version>" } // module
```

## Local development (no release)

Consume the plugin from a sibling `mobile-ci-tools` checkout instead of Maven Central:

```kotlin
// consumer settings.gradle(.kts)
includeBuild("../mobile-ci-tools/gradle-plugins/android-publish")
```

In the SDK repos this is gated behind `-PuseLocalPublishPlugin=true`. You can also install to your
local Maven cache: `./gradlew publishToMavenLocal`.

## Prerequisites (one-time, repo settings)

These secrets must exist in `mobile-ci-tools` for the release workflow to publish:
`OSSRH_USERNAME`, `OSSRH_PASSWORD`, `SONATYPE_STAGING_PROFILE_ID`, `SIGNING_KEY_ID`,
`SIGNING_KEY`, `SIGNING_PASSWORD`.
