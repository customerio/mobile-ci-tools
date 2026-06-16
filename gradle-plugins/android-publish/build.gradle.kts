plugins {
    `kotlin-dsl`
    `maven-publish`
    signing
}

group = "io.customer.android"
// Plugin version — bump only when the publishing logic itself changes (historically ~once/year).
version = System.getenv("MODULE_VERSION") ?: "0.1.0"

repositories {
    gradlePluginPortal()
    google()
    mavenCentral()
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

// Bootstrap: this plugin publishes itself with plain maven-publish (it cannot apply itself the
// first time). CI injects the same Sonatype/signing env vars used by the module convention.
publishing {
    repositories {
        maven {
            name = "sonatypeStaging"
            url = uri("https://ossrh-staging-api.central.sonatype.com/service/local/staging/deploy/maven2/")
            credentials {
                username = System.getenv("OSSRH_USERNAME")
                password = System.getenv("OSSRH_PASSWORD")
            }
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
