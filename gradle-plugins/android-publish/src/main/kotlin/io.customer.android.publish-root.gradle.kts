/**
 * Root-project convention: configures the Sonatype Central Portal staging repository and reads
 * publishing credentials from the environment (or `local.properties`).
 *
 * Apply to the ROOT project once. Ported from customerio-android's `scripts/publish-root.gradle`.
 */
plugins {
    id("io.github.gradle-nexus.publish-plugin")
}

// `IS_DEVELOPMENT=true` produces a hard-coded "local" version (easier local installs) and skips
// signing — see the module convention.
val isDevelopment = System.getenv("IS_DEVELOPMENT") == "true"
extra["IS_DEVELOPMENT"] = isDevelopment

extra["signing.keyId"] = System.getenv("SIGNING_KEY_ID") ?: ""
extra["signing.password"] = System.getenv("SIGNING_PASSWORD") ?: ""
extra["signing.key"] = System.getenv("SIGNING_KEY") ?: ""

val ossrhUsername = System.getenv("OSSRH_USERNAME") ?: ""
val ossrhPassword = System.getenv("OSSRH_PASSWORD") ?: ""
val sonatypeStagingProfileId = System.getenv("SONATYPE_STAGING_PROFILE_ID") ?: ""

val publishVersion = if (isDevelopment) "local" else (System.getenv("MODULE_VERSION") ?: "")
extra["PUBLISH_VERSION"] = publishVersion
version = publishVersion

// Allow overriding any of the above from local.properties (keys like `signing.keyId`, etc.).
val secretPropsFile = rootProject.file("local.properties")
if (secretPropsFile.exists()) {
    val props = java.util.Properties()
    secretPropsFile.inputStream().use { props.load(it) }
    props.forEach { (name, value) -> extra[name.toString()] = value }
}

nexusPublishing {
    repositories {
        sonatype {
            // Optional: when unset, the plugin auto-detects the profile for the namespace.
            if (sonatypeStagingProfileId.isNotBlank()) {
                stagingProfileId.set(sonatypeStagingProfileId)
            }
            username.set(ossrhUsername)
            password.set(ossrhPassword)
            nexusUrl.set(uri("https://ossrh-staging-api.central.sonatype.com/service/local/"))
            snapshotRepositoryUrl.set(uri("https://central.sonatype.com/repository/maven-snapshots/"))
        }
    }
}
