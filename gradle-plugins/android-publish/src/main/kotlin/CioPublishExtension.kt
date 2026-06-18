/**
 * Configuration for the `io.customer.android.publish-module` convention plugin.
 *
 * Defaults target the customerio-android SDK so that repo needs minimal config; other repos
 * (e.g. jist) override [artifactId], [description], and [url].
 */
open class CioPublishExtension {
    /** Maven groupId. Defaults to the verified `io.customer.android` namespace. */
    var group: String = "io.customer.android"

    /** Maven artifactId. Defaults to the Gradle project name when null. */
    var artifactId: String? = null

    /** Human-readable POM `<name>`. Defaults to [artifactId] / project name when null. */
    var artifactName: String? = null

    /** POM `<description>`. */
    var description: String = "Customer.io Android SDK"

    /** Project / SCM url. */
    var url: String = "https://github.com/customerio/customerio-android"

    /** SPDX-style license name. */
    var licenseName: String = "MIT"

    /** License url. Defaults to `${url}/blob/main/LICENSE` when null. */
    var licenseUrl: String? = null
}
