/**
 * Module convention: publishes an Android library (or Kotlin/Java) module to Maven Central under
 * the `io.customer.android` group, with sources, dokka javadoc, POM metadata, and signing.
 *
 * Apply to a publishable module. Configure via the `customerIoPublish { }` extension. Ported from
 * customerio-android's `scripts/publish-module.gradle`. Requires the root project to apply
 * `io.customer.android.publish-root` (for credentials + Sonatype staging).
 */
plugins {
    `maven-publish`
    signing
    id("org.jetbrains.dokka")
}

val cioPublish = extensions.create("customerIoPublish", CioPublishExtension::class.java)

val publishGroupId = (findProperty("PUBLISH_GROUP_ID") as String?) ?: "io.customer.android"
val isDevelopment = (rootProject.extra.properties["IS_DEVELOPMENT"] as? Boolean)
    ?: (System.getenv("IS_DEVELOPMENT") == "true")
val publishVersion = (rootProject.extra.properties["PUBLISH_VERSION"] as? String)
    ?: if (isDevelopment) "local" else (System.getenv("MODULE_VERSION") ?: "")

group = publishGroupId
version = publishVersion

// To speed up local development builds, dokka (javadoc) is only attached for real releases.
val javadocJar by tasks.registering(Jar::class) {
    val dokkaJavadoc = tasks.named("dokkaJavadoc")
    dependsOn(dokkaJavadoc)
    archiveClassifier.set("javadoc")
    from(dokkaJavadoc)
}

afterEvaluate {
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
                        url.set(cioPublish.url)
                        connection.set("scm:git@github.com:${cioPublish.url.substringAfter("github.com/")}.git")
                        developerConnection.set("scm:git@github.com:${cioPublish.url.substringAfter("github.com/")}.git")
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
