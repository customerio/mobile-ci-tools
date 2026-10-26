"""Runs wait_until_downloadable.py, with real curl, against a local fake registry.

Run with: python3 -m unittest discover -s github-actions/wait-until-downloadable/v1 -v
"""

import base64
import hashlib
import json
import os
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT = Path(__file__).with_name("wait_until_downloadable.py")


def ok(body):
    return {"status": 200, "body": body}


def status(code):
    return {"status": code, "body": "unavailable"}


def redirect(path):
    return {"status": 302, "location": path}


class FakeRegistry:
    """Serves each route's responses in order, then keeps repeating the last one."""

    def __init__(self, tls=False):
        self.routes = {}
        self.requests = []
        self._served = {}
        self._lock = threading.Lock()
        registry = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                registry._serve(self)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.tls_files = None
        self.ca_bundle = None
        if tls:
            # Disposable test certificate and key, trusted only by this test's curl.
            self.tls_files = tempfile.TemporaryDirectory()
            self.ca_bundle = Path(self.tls_files.name) / "cert.pem"
            key = Path(self.tls_files.name) / "key.pem"
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
                "-keyout", str(key), "-out", str(self.ca_bundle),
            ], check=True, capture_output=True)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(self.ca_bundle, key)
            self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
            self.url = f"https://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def route(self, path, *responses):
        self.routes[path] = list(responses)

    def paths(self):
        return [path for path, _ in self.requests]

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        if self.tls_files:
            self.tls_files.cleanup()

    def _serve(self, handler):
        with self._lock:
            self.requests.append((handler.path, handler.headers.get("Accept", "")))
            responses = self.routes.get(handler.path) or [status(404)]
            index = self._served.get(handler.path, 0)
            self._served[handler.path] = index + 1
        response = responses[min(index, len(responses) - 1)]
        time.sleep(response.get("delay", 0))
        body = response.get("body", b"")
        if isinstance(body, (dict, list)):
            body = json.dumps(body)
        if isinstance(body, str):
            body = body.encode()
        try:
            handler.send_response(response["status"])
            if "location" in response:
                location = response["location"]
                handler.send_header("Location", location if location.startswith(("http://", "https://")) else self.url + location)
            handler.send_header("Content-Length", str(len(body)))
            handler.end_headers()
            handler.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


class WaitUntilDownloadableTest(unittest.TestCase):
    def setUp(self):
        self.registry = FakeRegistry()
        self.addCleanup(self.registry.close)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def run_wait(self, ecosystem, version, packages, timeout_seconds="5", timeout_minutes=None, registry=None):
        registry = registry or self.registry
        summary = Path(self.tmp.name) / "summary.md"
        if summary.exists():
            summary.unlink()
        args = [
            sys.executable, "-I", str(SCRIPT),
            f"--ecosystem={ecosystem}",
            f"--version={version}",
            f"--packages={packages}",
            f"--registry-url={registry.url}",
            "--initial-backoff-seconds=0.05",
            "--max-backoff-seconds=0.2",
        ]
        if timeout_seconds is not None:
            args.append(f"--timeout-seconds={timeout_seconds}")
        if timeout_minutes is not None:
            args.append(f"--timeout-minutes={timeout_minutes}")
        env = {key: value for key, value in os.environ.items() if "proxy" not in key.lower()}
        env["GITHUB_STEP_SUMMARY"] = str(summary)
        if registry.ca_bundle:
            env["CURL_CA_BUNDLE"] = str(registry.ca_bundle)
        started = time.monotonic()
        result = subprocess.run(args, capture_output=True, text=True, env=env, timeout=60)
        result.elapsed = time.monotonic() - started
        result.log = result.stdout + result.stderr
        result.summary = summary.read_text() if summary.exists() else ""
        return result

    def assertExit(self, result, code):
        self.assertEqual(result.returncode, code, result.log)

    def error_line(self, result):
        lines = [line for line in result.stdout.splitlines() if line.startswith("::error::")]
        self.assertEqual(len(lines), 1, result.log)
        return lines[0]

    # npm

    def npm_metadata(self, name, versions, tarball, integrity):
        entries = {
            version: {"name": name, "version": version, "dist": {"tarball": tarball, "integrity": integrity}}
            for version in versions
        }
        return {"name": name, "versions": entries}

    def test_npm_scoped_package_waits_for_metadata_then_tarball(self):
        tarball = b"package tarball"
        integrity = "sha512-" + base64.b64encode(hashlib.sha512(tarball).digest()).decode()
        tarball_url = self.registry.url + "/@cio/sdk/-/sdk-1.2.3.tgz"
        self.registry.route(
            "/@cio%2fsdk",
            ok(self.npm_metadata("@cio/sdk", ["1.2.2"], tarball_url, integrity)),
            ok(self.npm_metadata("@cio/sdk", ["1.2.2", "1.2.3"], tarball_url, integrity)),
        )
        self.registry.route("/@cio/sdk/-/sdk-1.2.3.tgz", status(404), status(404), ok(tarball))

        result = self.run_wait("npm", "1.2.3", "@cio/sdk")

        self.assertExit(result, 0)
        paths = self.registry.paths()
        self.assertEqual(paths.count("/@cio/sdk/-/sdk-1.2.3.tgz"), 3)
        # The tarball is only requested once metadata lists the version.
        self.assertGreaterEqual(paths.index("/@cio/sdk/-/sdk-1.2.3.tgz"), 2)
        accept = [accept for path, accept in self.registry.requests if path == "/@cio%2fsdk"]
        self.assertTrue(all("application/vnd.npm.install-v1+json" in value for value in accept), accept)
        self.assertFalse(any("?" in path for path in paths), paths)

    def test_npm_stays_pending_on_wrong_identity_or_integrity(self):
        tarball = b"package tarball"
        good = "sha512-" + base64.b64encode(hashlib.sha512(tarball).digest()).decode()
        wrong = "sha512-" + base64.b64encode(hashlib.sha512(b"other").digest()).decode()
        tarball_url = self.registry.url + "/sdk/-/sdk-1.2.3.tgz"
        self.registry.route("/sdk/-/sdk-1.2.3.tgz", ok(tarball))
        wrong_entry = self.npm_metadata("sdk", ["1.2.3"], tarball_url, good)
        wrong_entry["versions"]["1.2.3"]["version"] = "1.2.4"
        cases = {
            "package name": (self.npm_metadata("other", ["1.2.3"], tarball_url, good), "metadata"),
            "version entry": (wrong_entry, "metadata"),
            "missing integrity": (self.npm_metadata("sdk", ["1.2.3"], tarball_url, None), "integrity"),
            "integrity mismatch": (self.npm_metadata("sdk", ["1.2.3"], tarball_url, wrong), "integrity"),
        }
        for label, (metadata, expected_text) in cases.items():
            with self.subTest(label):
                self.registry.route("/sdk", ok(metadata))

                result = self.run_wait("npm", "1.2.3", "sdk", timeout_seconds="1.5")

                self.assertExit(result, 1)
                self.assertIn("sdk", self.error_line(result))
                self.assertIn(expected_text, self.error_line(result))

    # HTTPS transport

    def test_https_registry_rejects_http_archives_and_redirects(self):
        secure = FakeRegistry(tls=True)
        self.addCleanup(secure.close)
        archive = b"package tarball"
        integrity = "sha512-" + base64.b64encode(hashlib.sha512(archive).digest()).decode()
        insecure_url = self.registry.url + "/archive.tgz"
        self.registry.route("/archive.tgz", ok(archive))
        secure.route("/redirect", redirect(insecure_url))
        for label, archive_url in [("direct HTTP archive", insecure_url),
                                   ("HTTPS redirect to HTTP", secure.url + "/redirect")]:
            with self.subTest(case=label):
                self.registry.requests.clear()
                secure.route("/sdk", ok(self.npm_metadata("sdk", ["1.2.3"], archive_url, integrity)))

                result = self.run_wait("npm", "1.2.3", "sdk", timeout_seconds="1.5", registry=secure)

                self.assertExit(result, 1)
                self.assertIn("archive", self.error_line(result))
                self.assertIn("protocol", self.error_line(result).lower())
                self.assertEqual(self.registry.requests, [])

    def test_https_registry_follows_https_redirects(self):
        secure = FakeRegistry(tls=True)
        self.addCleanup(secure.close)
        archive = b"package tarball"
        integrity = "sha512-" + base64.b64encode(hashlib.sha512(archive).digest()).decode()
        secure.route("/sdk", ok(self.npm_metadata("sdk", ["1.2.3"], secure.url + "/redirect", integrity)))
        secure.route("/redirect", redirect("/archive.tgz"))
        secure.route("/archive.tgz", ok(archive))

        result = self.run_wait("npm", "1.2.3", "sdk", registry=secure)

        self.assertExit(result, 0)
        self.assertEqual(secure.paths(), ["/sdk", "/redirect", "/archive.tgz"])
        self.assertEqual(self.registry.requests, [])

    # pub

    def pub_metadata(self, versions, sha256):
        return {
            "name": "customer_io",
            "versions": [
                {
                    "version": version,
                    "pubspec": {"name": "customer_io", "version": version},
                    "archive_url": f"{self.registry.url}/api/archives/customer_io-{version}.tar.gz",
                    "archive_sha256": sha256,
                }
                for version in versions
            ],
        }

    def test_pub_retries_transient_errors_and_follows_archive_redirect(self):
        archive = b"pub archive"
        sha256 = hashlib.sha256(archive).hexdigest()
        self.registry.route(
            "/api/packages/customer_io",
            status(503),
            status(429),
            ok(self.pub_metadata(["4.8.0"], sha256)),
            ok(self.pub_metadata(["4.8.0", "4.9.0"], sha256)),
        )
        self.registry.route("/api/archives/customer_io-4.9.0.tar.gz", redirect("/storage/customer_io-4.9.0.tar.gz"))
        self.registry.route("/storage/customer_io-4.9.0.tar.gz", ok(archive))

        result = self.run_wait("pub", "4.9.0", "customer_io")

        self.assertExit(result, 0)
        self.assertEqual(self.registry.paths().count("/api/packages/customer_io"), 4)
        self.assertIn("/storage/customer_io-4.9.0.tar.gz", self.registry.paths())
        accept = [accept for path, accept in self.registry.requests if path == "/api/packages/customer_io"]
        self.assertTrue(all("application/vnd.pub.v2+json" in value for value in accept), accept)

    def test_pub_rejects_archive_sha256_mismatch(self):
        self.registry.route("/api/packages/customer_io", ok(self.pub_metadata(["4.9.0"], "0" * 64)))
        self.registry.route("/api/archives/customer_io-4.9.0.tar.gz", ok(b"pub archive"))

        result = self.run_wait("pub", "4.9.0", "customer_io", timeout_seconds="1.5")

        self.assertExit(result, 1)
        self.assertIn("integrity", self.error_line(result))

    # Maven

    def pom(self, group, artifact, version, packaging="aar", gradle_metadata=True):
        marker = "<!-- do_not_remove: published-with-gradle-metadata -->" if gradle_metadata else ""
        return (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<project xmlns="http://maven.apache.org/POM/4.0.0">\n'
            f"  {marker}\n"
            "  <modelVersion>4.0.0</modelVersion>\n"
            f"  <groupId>{group}</groupId>\n"
            f"  <artifactId>{artifact}</artifactId>\n"
            f"  <version>{version}</version>\n"
            f"  <packaging>{packaging}</packaging>\n"
            "</project>\n"
        )

    def module(self, group, artifact, version, files=()):
        return {
            "formatVersion": "1.1",
            "component": {"group": group, "module": artifact, "version": version},
            "variants": [{"name": "releaseVariantReleaseApiPublication", "files": list(files)}],
        }

    def publish_maven(self, artifact, version="5.0.0", aar=b"aar bytes"):
        base = f"/io/customer/android/{artifact}/{version}/{artifact}-{version}"
        files = [{"name": f"{artifact}-{version}.aar", "url": f"{artifact}-{version}.aar",
                  "sha256": hashlib.sha256(aar).hexdigest()}]
        self.registry.route(base + ".pom", ok(self.pom("io.customer.android", artifact, version)))
        self.registry.route(base + ".module", ok(self.module("io.customer.android", artifact, version, files)))
        self.registry.route(base + ".aar", ok(aar))
        return base

    def summary_row(self, result, artifact):
        rows = [row for row in result.summary.splitlines() if f"io.customer.android:{artifact} " in row]
        self.assertEqual(len(rows), 1, result.summary)
        return rows[0]

    def test_maven_partial_propagation_names_only_the_missing_module(self):
        self.publish_maven("location")
        base = self.publish_maven("base")
        pom = self.registry.routes[base + ".pom"][0]
        self.registry.route(base + ".pom", status(404), status(404), pom)
        # geofence is never published, as in the 5.0.0 release run.

        result = self.run_wait(
            "maven", "5.0.0",
            "io.customer.android:location\nio.customer.android:base\nio.customer.android:geofence\n",
            timeout_seconds="2",
        )

        self.assertExit(result, 1)
        error = self.error_line(result)
        self.assertIn("io.customer.android:geofence", error)
        self.assertNotIn("io.customer.android:base", error)
        self.assertNotIn("io.customer.android:location", error)
        self.assertIn("/io/customer/android/geofence/5.0.0/geofence-5.0.0.pom", error)
        self.assertIn("404", error)
        self.assertIn("404", self.summary_row(result, "geofence"))
        self.assertIn("ready", self.summary_row(result, "base"))

    def test_maven_gradle_metadata_must_match_before_the_archive_counts(self):
        base = self.publish_maven("geofence")
        good_module = self.registry.routes[base + ".module"][0]
        self.registry.route(
            base + ".module",
            status(404),
            ok(self.module("io.customer.android", "geofence", "4.9.9")),
            good_module,
        )

        result = self.run_wait("maven", "5.0.0", "io.customer.android:geofence")

        self.assertExit(result, 0)
        paths = self.registry.paths()
        self.assertEqual(paths.count(base + ".module"), 3)
        # The archive is not fetched while Gradle metadata is missing or for another version.
        self.assertEqual(paths.count(base + ".aar"), 1)

    def test_maven_without_gradle_metadata_skips_module_and_checks_pom_identity(self):
        base = "/io/customer/android/core/5.0.0/core-5.0.0"
        self.registry.route(
            base + ".pom",
            ok(self.pom("io.customer.android", "core", "4.9.9", gradle_metadata=False)),
            ok(self.pom("io.customer.android", "core", "5.0.0", gradle_metadata=False)),
        )
        self.registry.route(base + ".aar", ok(b"aar bytes"))

        result = self.run_wait("maven", "5.0.0", "io.customer.android:core")

        self.assertExit(result, 0)
        self.assertNotIn(base + ".module", self.registry.paths())
        self.assertEqual(self.registry.paths().count(base + ".aar"), 1)

    def test_maven_rejects_archive_that_does_not_match_gradle_metadata(self):
        base = self.publish_maven("geofence")
        self.registry.route(base + ".aar", ok(b"truncated"))

        result = self.run_wait("maven", "5.0.0", "io.customer.android:geofence", timeout_seconds="1.5")

        self.assertExit(result, 1)
        self.assertIn("integrity", self.error_line(result))

    # CocoaPods

    # The CDN shards by the first three hex digits of md5(pod name); AFNetworking lives under a/7/5.
    SHARD = "/all_pods_versions_a_7_5.txt"
    SPEC = "/Specs/a/7/5/AFNetworking/4.0.1/AFNetworking.podspec.json"

    def test_cocoapods_needs_the_podspec_after_the_index_lists_the_version(self):
        self.registry.route(
            self.SHARD,
            ok("AFNetworking/3.2.1/4.0.0\nAFNetworkingExtras/4.0.1\n"),
            ok("AFNetworking/3.2.1/4.0.0/4.0.1\nAFNetworkingExtras/4.0.1\n"),
        )
        self.registry.route(
            self.SPEC,
            status(404),
            ok({"name": "AFNetworking", "version": "4.0.0"}),
            redirect("/jsdelivr/AFNetworking.podspec.json"),
        )
        self.registry.route("/jsdelivr/AFNetworking.podspec.json", ok({"name": "AFNetworking", "version": "4.0.1"}))

        result = self.run_wait("cocoapods", "4.0.1", "AFNetworking")

        self.assertExit(result, 0)
        paths = self.registry.paths()
        # A line for another pod listing 4.0.1 must not count for AFNetworking.
        self.assertGreaterEqual(paths.index(self.SPEC), 2)
        self.assertEqual(paths.count(self.SPEC), 3)
        self.assertFalse(any("?" in path for path in paths), paths)

    # Deadline and input handling

    def test_slow_response_cannot_extend_the_deadline(self):
        self.registry.route("/api/packages/customer_io", {"status": 200, "body": "{}", "delay": 10})

        result = self.run_wait("pub", "4.9.0", "customer_io", timeout_seconds="2")

        self.assertExit(result, 1)
        self.assertLess(result.elapsed, 5, result.log)
        self.assertIn("customer_io", self.error_line(result))

    def test_invalid_input_exits_2_without_any_request(self):
        cases = [
            ("npm", "latest", "sdk", None),
            ("npm", "next", "sdk", None),
            ("npm", "", "sdk", None),
            ("npm", "1.2.3/../../x", "sdk", None),
            ("npm", "1.2.3?cache=1", "sdk", None),
            ("npm", "-1.2.3", "sdk", None),
            ("gradle", "1.2.3", "sdk", None),
            ("npm", "1.2.3", "", None),
            ("npm", "1.2.3", "../sdk", None),
            ("pub", "1.2.3", "Customer-IO", None),
            ("maven", "1.2.3", "io.customer.android", None),
            ("maven", "1.2.3", "io..customer:core", None),
            ("cocoapods", "1.2.3", "Pod/../x", None),
            ("npm", "1.2.3", "sdk", "0"),
            ("npm", "1.2.3", "sdk", "1.5"),
            ("npm", "1.2.3", "sdk", "60; exit 0"),
        ]
        for ecosystem, version, packages, minutes in cases:
            with self.subTest(ecosystem=ecosystem, version=version, packages=packages, minutes=minutes):
                result = self.run_wait(ecosystem, version, packages, timeout_seconds=None, timeout_minutes=minutes)

                self.assertExit(result, 2)
                self.assertEqual(self.registry.requests, [])

    def test_accepts_prerelease_and_build_versions(self):
        archive = b"pub archive"
        version = "4.9.0-beta.1+build.7"
        self.registry.route("/api/packages/customer_io", ok(self.pub_metadata([version], hashlib.sha256(archive).hexdigest())))
        self.registry.route(f"/api/archives/customer_io-{version}.tar.gz", ok(archive))

        result = self.run_wait("pub", version, "customer_io", timeout_seconds=None, timeout_minutes="1")

        self.assertExit(result, 0)


if __name__ == "__main__":
    unittest.main()
