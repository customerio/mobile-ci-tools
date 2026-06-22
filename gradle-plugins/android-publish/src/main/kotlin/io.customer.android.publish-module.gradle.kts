/**
 * Module convention: publishes an Android library (or Kotlin/Java) module to Maven Central under
 * the `io.customer.android` group, with sources, dokka javadoc, POM metadata, and signing.
 *
 * Apply to a publishable module. Configure via the `customerIoPublish { }` extension. Ported from
 * customerio-android's `scripts/publish-module.gradle`. Requires the root project to apply
 * `io.customer.android.publish-root` (for credentials + Sonatype staging).
 */
import org.gradle.api.publish.maven.tasks.AbstractPublishToMaven

plugins {
    `maven-publish`
    signing
    id("org.jetbrains.dokka")
}

val cioPublish = extensions.create("customerIoPublish", CioPublishExtension::class.java)

val isDevelopment = (rootProject.extra.properties["IS_DEVELOPMENT"] as? Boolean)
    ?: (System.getenv("IS_DEVELOPMENT") == "true")
val publishVersion = (rootProject.extra.properties["PUBLISH_VERSION"] as? String)
    ?: if (isDevelopment) "local" else (System.getenv("MODULE_VERSION") ?: "")

version = publishVersion

// Fail a *publish* (not other builds) when a non-dev release has no version, so an empty-version
// GAV is never pushed toward Maven Central. Configuration of non-publishing tasks is unaffected.
tasks.withType<AbstractPublishToMaven>().configureEach {
    doFirst {
        check(isDevelopment || publishVersion.isNotBlank()) {
            "Refusing to publish ${project.path}: version is empty. Set MODULE_VERSION (or IS_DEVELOPMENT=true for a local install)."
        }
    }
}

// Match customerio-android's generated docs: separate inherited members in the dokka output.
tasks.withType<org.jetbrains.dokka.gradle.DokkaTaskPartial>().configureEach {
    pluginsMapConfiguration.set(
        mapOf("org.jetbrains.dokka.base.DokkaBase" to """{ "separateInheritedMembers": true }"""),
    )
}

// To speed up local development builds, dokka (javadoc) is only attached for real releases.
val javadocJar by tasks.registering(Jar::class) {
    val dokkaJavadoc = tasks.named("dokkaJavadoc")
    dependsOn(dokkaJavadoc)
    archiveClassifier.set("javadoc")
    from(dokkaJavadoc)
}

afterEvaluate {
    // Resolved after the consumer has configured the extension.
    val publishGroupId = cioPublish.group
    group = publishGroupId

    publishing {
        publications {
            create<MavenPublication>("release") {
                groupId = publishGroupId
                artifactId = cioPublish.artifactId ?: project.name
                version = publishVersion

                if (project.plugins.findPlugin("com.android.library") != null) {
                    from(components["release"])
                } else {
                    from(components["java"])
                    tasks.findByName("kotlinSourcesJar")?.let { artifact(it) }
                }

                if (!isDevelopment) {
                    artifact(javadocJar)
                }

                pom {
                    name.set(cioPublish.artifactName ?: cioPublish.artifactId ?: project.name)
                    description.set(cioPublish.description)
                    url.set(cioPublish.url)
                    licenses {
                        license {
                            name.set(cioPublish.licenseName)
                            url.set(cioPublish.licenseUrl ?: "${cioPublish.url}/blob/main/LICENSE")
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
                        // Host-agnostic `scm:git:<url>.git` form so a non-GitHub url can't produce
                        // a malformed connection (the previous github.com-specific derivation fell
                        // back to the full url when the host didn't match).
                        url.set(cioPublish.url)
                        connection.set("scm:git:${cioPublish.url}.git")
                        developerConnection.set("scm:git:${cioPublish.url}.git")
                    }
                }
            }
        }
    }

    signing {
        useInMemoryPgpKeys(
            rootProject.extra.properties["signing.keyId"] as String?,
            rootProject.extra.properties["signing.key"] as String?,
            rootProject.extra.properties["signing.password"] as String?,
        )
        // Skip signing for local installs during development.
        if (!isDevelopment) {
            sign(publishing.publications)
        }
    }
}
