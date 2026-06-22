plugins {
    `kotlin-dsl`
    `maven-publish`
    signing
    // Used to publish THIS plugin to the Sonatype Central Portal (close + release), the same way
    // the convention applies it to consumer projects.
    id("io.github.gradle-nexus.publish-plugin") version "2.0.0"
}

group = "io.customer.android"
// Single source of truth for the plugin version. Bumping this line in a PR is what triggers a
// release (see RELEASING.md) — bump only when the publishing logic changes (historically ~once/year).
version = providers.gradleProperty("pluginVersion").get()

repositories {
    gradlePluginPortal()
    google()
    mavenCentral()
}

// Maven Central requires a -sources.jar and -javadoc.jar for the published plugin artifact.
java {
    withSourcesJar()
    withJavadocJar()
}

dependencies {
    // The convention scripts apply these plugins, so their markers must be on the classpath.
    // Both are pinned, in-house-reviewed versions — see README for the supply-chain rationale.
    implementation("io.github.gradle-nexus:publish-plugin:2.0.0")
    implementation("org.jetbrains.dokka:dokka-gradle-plugin:1.9.20")
}

// Precompiled script plugins under src/main/kotlin are auto-registered by file name:
//   io.customer.android.publish-root.gradle.kts    -> id "io.customer.android.publish-root"
//   io.customer.android.publish-module.gradle.kts  -> id "io.customer.android.publish-module"

// Maven Central requires complete POM metadata on every published artifact, including the
// auto-generated plugin-marker publications.
publishing {
    publications.withType<MavenPublication>().configureEach {
        pom {
            name.set("Customer.io Android Publishing Plugin")
            description.set("Shared in-house Gradle convention for publishing Customer.io Android artifacts to Maven Central.")
            url.set("https://github.com/customerio/mobile-ci-tools")
            licenses {
                license {
                    name.set("MIT")
                    url.set("https://github.com/customerio/mobile-ci-tools/blob/main/LICENSE")
                }
            }
            developers {
                developer {
                    id.set("customerio")
                    name.set("Customer.io Team")
                    email.set("win@customer.io")
                }
            }
            scm {
                url.set("https://github.com/customerio/mobile-ci-tools")
                connection.set("scm:git@github.com:customerio/mobile-ci-tools.git")
                developerConnection.set("scm:git@github.com:customerio/mobile-ci-tools.git")
            }
        }
    }
}

// Sonatype Central Portal staging. `publishToSonatype closeAndReleaseSonatypeStagingRepository`
// uploads and promotes to Maven Central in one shot.
nexusPublishing {
    repositories {
        sonatype {
            username.set(System.getenv("OSSRH_USERNAME") ?: "")
            password.set(System.getenv("OSSRH_PASSWORD") ?: "")
            // Optional: when unset, the plugin auto-detects the profile for the namespace.
            System.getenv("SONATYPE_STAGING_PROFILE_ID")?.takeIf { it.isNotBlank() }?.let {
                stagingProfileId.set(it)
            }
            nexusUrl.set(uri("https://ossrh-staging-api.central.sonatype.com/service/local/"))
            snapshotRepositoryUrl.set(uri("https://central.sonatype.com/repository/maven-snapshots/"))
        }
    }
}

signing {
    val signingKey = System.getenv("SIGNING_KEY")
    val signingPassword = System.getenv("SIGNING_PASSWORD")
    val signingKeyId = System.getenv("SIGNING_KEY_ID")
    if (!signingKey.isNullOrBlank()) {
        useInMemoryPgpKeys(signingKeyId, signingKey, signingPassword)
        sign(publishing.publications)
    }
}
