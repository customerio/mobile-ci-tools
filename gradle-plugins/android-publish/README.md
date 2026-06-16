# `io.customer.android.publish`

Shared, **in-house** Gradle convention plugin for publishing Customer.io Android artifacts to
Maven Central under the `io.customer.android` group. One source of truth for signing, POM metadata,
and the Sonatype Central Portal upload — applied by every Android repo (jist, customerio-android, …)
instead of each repo copy-pasting publish scripts.

This is a faithful port of `customerio-android`'s hand-rolled `scripts/publish-root.gradle` +
`scripts/publish-module.gradle`.

## Supply-chain stance

This is **our own code**, in **our own** repo. It deliberately introduces **no third-party
publishing convention plugin** (e.g. vanniktech). It wires only:

- Gradle-core `maven-publish` + `signing`
- `org.jetbrains.dokka` (javadoc jar) — pinned `1.9.20`
- `io.github.gradle-nexus:publish-plugin` — pinned `2.0.0`, the same plugin customerio-android
  already uses for the Sonatype Central Portal staging upload

Both external plugins are version-pinned and already trusted by the SDK build today. The
publishing logic itself changes ~once a year, so the published plugin needs new versions rarely.

## Plugins

| Plugin id | Apply to | Responsibility |
| --- | --- | --- |
| `io.customer.android.publish-root` | root project (once) | Sonatype Central Portal staging repo + credentials from env / `local.properties` |
| `io.customer.android.publish-module` | each publishable module | `maven-publish` publication, sources + dokka javadoc, POM, signing |

## Consuming from another repo

Once this plugin is published to Maven Central:

```kotlin
// settings.gradle.kts
pluginManagement { repositories { mavenCentral() } }

// root build.gradle.kts
plugins { id("io.customer.android.publish-root") version "<version>" }

// module build.gradle.kts
plugins { id("io.customer.android.publish-module") version "<version>" }

customerIoPublish {
    artifactId = "jist"
    description = "Customer.io Jist native renderer for Android"
    url = "https://github.com/customerio/jist"
}
```

For local development before the plugin is published, consume it as an included build:

```kotlin
// settings.gradle.kts
includeBuild("../mobile-ci-tools/gradle-plugins/android-publish")
```

## Environment variables (publishing)

`MODULE_VERSION`, `OSSRH_USERNAME`, `OSSRH_PASSWORD`, `SONATYPE_STAGING_PROFILE_ID`,
`SIGNING_KEY_ID`, `SIGNING_KEY`, `SIGNING_PASSWORD`. Set `IS_DEVELOPMENT=true` for a hard-coded
`local` version with signing skipped (e.g. `publishToMavenLocal`).
