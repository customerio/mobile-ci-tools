# Releasing & versioning — `io.customer.android:android-publish`

This plugin is published to Maven Central. Releases are **automated but gated on an explicit,
reviewable version bump**, so they can't fire by accident.

## Versioning

- The version lives in **one place**: `pluginVersion` in [`gradle.properties`](./gradle.properties).
- Standard [semver](https://semver.org/). Because consumers **pin** the plugin version, a change
  here never affects a repo until it bumps on its own schedule.
- A `-SNAPSHOT` suffix marks a non-release (overwritable, never promoted to Central). The default
  state of `main` is a `-SNAPSHOT` so merges don't release anything (see below).
- This logic changes rarely (historically ~once a year), so releases are infrequent.

## How a real release happens

The only manual step is bumping `pluginVersion` to a **non-SNAPSHOT** value:

1. In the PR that changes the plugin, set `pluginVersion` (e.g. `0.1.0-SNAPSHOT` → `0.1.0`).
2. Merge to `main`. The [release workflow](../../.github/workflows/android-publish-release.yml)
   then automatically:
   - builds + publishes to the Sonatype Central Portal and **closes + releases** the staging repo
     (`publishToSonatype closeAndReleaseSonatypeStagingRepository`),
   - tags the commit `android-publish-v<version>`.

No version is typed at release time, no tag is cut by hand.

## Why merging can't over-release

| Guard | Prevents |
| --- | --- |
| **`paths:` filter** (`gradle-plugins/android-publish/**`) | Releases from unrelated commits — iOS/Android actions, Slack, root README, other CI. |
| **SNAPSHOT is inert on push** | A merge releases nothing while `pluginVersion` ends in `-SNAPSHOT`. The first real release is a deliberate bump to a non-SNAPSHOT version. |
| **Tag idempotency** (`android-publish-v<version>` must not exist) | Releases from plugin-dir changes that don't bump the version (a comment, a test). The run no-ops. |
| **Credential guard** | If the publishing secrets aren't set, publish steps are skipped (the run stays green) instead of failing. |

This is deliberately not semantic-release: in a shared, mixed-purpose repo, commit-message-driven
versioning would sweep in unrelated commits and mis-attribute or over-fire releases.

## Testing without a real release (`workflow_dispatch`)

Run the workflow manually with a `mode`:

| `mode` | What it does | Secrets needed |
| --- | --- | --- |
| `dry-run` | prints the publish task graph, uploads nothing | none |
| `snapshot` | publishes a SNAPSHOT to the snapshot repo (real upload, never released, overwritable) | `GRADLE_PUBLISH_USERNAME` + `GRADLE_PUBLISH_PASSWORD` |
| `close` | publishes + **closes** the staging repo on a release-shaped version (runs Central's validation) **without releasing** — drop it afterward in the Central Portal | full set (publish + signing) |

Recommended order before the first real release: `dry-run` → `snapshot` → one `close`→drop → then bump to a non-SNAPSHOT version and merge.

## Recovering a half-failed release

The tag is created **after** a successful publish. If `publishToSonatype`/release succeeds but the
tag push fails, a re-run would try to publish the same version again and Sonatype will reject the
duplicate. Recover by creating the tag manually so the gate sees it as already-released:

```bash
git tag android-publish-v<version> <commit> && git push origin android-publish-v<version>
```

## Secrets

Set in the `mobile-ci-tools` repo (reusing the same names/values as `customerio-android`):

| Secret | Needed for |
| --- | --- |
| `GRADLE_PUBLISH_USERNAME`, `GRADLE_PUBLISH_PASSWORD` | any real upload (snapshot, close, release) |
| `GRADLE_SIGNING_KEYID`, `GRADLE_SIGNING_PRIVATE_KEY`, `GRADLE_SIGNING_PASSPHRASE` | close + release (Central validates signatures) |
| `SONATYPE_STAGING_PROFILE_ID` | **optional** — the plugin auto-detects the namespace profile when unset |

> The `GRADLE_*` secret names are mapped to the build's `OSSRH_*` / `SIGNING_*` env vars in the
> workflow. The legacy `SNAPSHOT` env var from customerio-android's old script is intentionally not
> ported (it was never read).

## Consuming a released version

```kotlin
// settings.gradle.kts
pluginManagement { repositories { mavenCentral() } }

// root build.gradle(.kts)
plugins { id("io.customer.android.publish-root") version "<version>" }

// module build.gradle(.kts)
plugins { id("io.customer.android.publish-module") version "<version>" }

customerIoPublish {
    artifactId = "jist"                 // group defaults to io.customer.android
    description = "…"
    url = "https://github.com/customerio/jist"
}
```

### Migrating an existing module onto the plugin

Replace the old per-module publishing wiring:

```diff
- ext {
-     PUBLISH_GROUP_ID = Configurations.artifactGroup
-     PUBLISH_ARTIFACT_ID = "messaging-in-app"
- }
- apply from: "${rootDir}/scripts/publish-module.gradle"
+ apply plugin: 'io.customer.android.publish-module'
+ customerIoPublish { artifactId = "messaging-in-app" }
```

> ⚠️ `artifactId` now comes **only** from `customerIoPublish` — the old `PUBLISH_ARTIFACT_ID`
> property is ignored. If a module is migrated without setting `artifactId`, it falls back to the
> Gradle project name (e.g. `messaginginapp` instead of `messaging-in-app`), which is wrong. Set it
> explicitly for every module.

### Multi-module consumers (`customerio-android`)

When publishing **multiple** modules in one run, keep `--max-workers 1` so the modules don't race
on the shared Sonatype staging repository:

```bash
./gradlew publishReleasePublicationToSonatypeRepository --max-workers 1 closeAndReleaseSonatypeStagingRepository
```

(The single-artifact plugin release above doesn't need it.)

## Local development (no release)

```kotlin
// consumer settings.gradle(.kts)
includeBuild("../mobile-ci-tools/gradle-plugins/android-publish")
```

In the SDK repos this is gated behind `-PuseLocalPublishPlugin=true`. You can also install to your
local Maven cache: `IS_DEVELOPMENT=true ./gradlew publishToMavenLocal` (version `local`, signing skipped).
