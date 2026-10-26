#!/usr/bin/env python3
"""Wait until one exact version of every listed package can be downloaded from its public registry.

Each check requests the URLs the package manager itself requests, without cache busting, and checks
that the metadata names the requested package and version before the archive or podspec counts.
Exits 0 when every package is downloadable, 1 when the time budget runs out and 2 on invalid input.
"""

import argparse
import base64
import contextlib
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ElementTree

REGISTRIES = {
    "cocoapods": "https://cdn.cocoapods.org",
    "maven": "https://repo.maven.apache.org/maven2",
    "npm": "https://registry.npmjs.org",
    "pub": "https://pub.dev",
}
PACKAGE_PATTERNS = {
    "cocoapods": r"[A-Za-z0-9_][A-Za-z0-9_.+-]*",
    "maven": r"[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*:[A-Za-z0-9_][A-Za-z0-9_.-]*",
    "npm": r"(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*",
    "pub": r"[a-z_][a-z0-9_]*",
}
# Release versions only. Dist-tags such as latest, and anything carrying a path or query, are rejected.
VERSION_PATTERN = r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?"
HTTP_URL_PATTERN = r"https?://\S+"
NPM_ACCEPT = "application/vnd.npm.install-v1+json; q=1.0, application/json; q=0.8, */*"
PUB_ACCEPT = "application/vnd.pub.v2+json"
GRADLE_METADATA_MARKER = b"published-with-gradle-metadata"
REQUEST_SECONDS = 30
# How long curl may take to exit after its own --max-time before it is killed.
TEARDOWN_SECONDS = 2
MIN_REQUEST_SECONDS = 0.5


class NotDownloadable(Exception):
    def __init__(self, stage, url, detail, skipped=False):
        super().__init__(detail)
        self.stage = stage
        self.url = url
        # One line, so registry-controlled text cannot start a new workflow command.
        self.detail = " ".join(str(detail).split())[:300]
        self.skipped = skipped


def log(message):
    print(message, flush=True)


def escape_command(value):
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def describe_duration(seconds):
    return f"{seconds // 60:.0f} minutes" if seconds % 60 == 0 else f"{seconds:g} seconds"


def file_digest(path, algorithm):
    digest = hashlib.new(algorithm)
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest


def read_json(stage, url, path):
    try:
        with open(path, "rb") as stream:
            document = json.load(stream)
    except ValueError:
        raise NotDownloadable(stage, url, "response is not JSON") from None
    if not isinstance(document, dict):
        raise NotDownloadable(stage, url, "response is not a JSON object")
    return document


def checked_url(stage, url, value, field):
    if not isinstance(value, str) or not re.fullmatch(HTTP_URL_PATTERN, value):
        raise NotDownloadable(stage, url, f"{field} is not an http(s) URL: {value!r:.80}")
    return value


def local_name(tag):
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def pom_coordinates(pom):
    root = ElementTree.fromstring(pom)
    parent = next((child for child in root if local_name(child.tag) == "parent"), None)

    def text(element, tag):
        for child in element if element is not None else ():
            if local_name(child.tag) == tag:
                return (child.text or "").strip()
        return None

    return (
        text(root, "groupId") or text(parent, "groupId"),
        text(root, "artifactId"),
        text(root, "version") or text(parent, "version"),
        text(root, "packaging") or "jar",
    )


class Registry:
    def __init__(self, base_url, version, deadline, workdir):
        self.base_url = base_url
        self.version = version
        self.deadline = deadline
        self.workdir = workdir

    @contextlib.contextmanager
    def download(self, stage, url, accept=None):
        remaining = self.deadline - time.monotonic()
        if remaining < MIN_REQUEST_SECONDS:
            raise NotDownloadable(stage, url, "not requested before the deadline", skipped=True)
        max_time = min(REQUEST_SECONDS, remaining)
        handle, path = tempfile.mkstemp(dir=self.workdir)
        os.close(handle)
        command = [
            "curl", "--silent", "--show-error", "--location", "--max-redirs", "10",
            "--proto", "=http,https", "--proto-redir", "=http,https",
            "--connect-timeout", f"{min(max_time, 10):.3f}", "--max-time", f"{max_time:.3f}",
            "--output", path, "--write-out", "%{http_code}",
        ]
        if accept:
            command += ["--header", f"Accept: {accept}"]
        command += ["--url", url]
        try:
            try:
                completed = subprocess.run(
                    command, capture_output=True, text=True, errors="replace",
                    timeout=max_time + TEARDOWN_SECONDS,
                )
            except subprocess.TimeoutExpired:
                raise NotDownloadable(stage, url, f"curl did not exit within {max_time:.0f}s") from None
            if completed.returncode != 0:
                raise NotDownloadable(stage, url, f"curl exit {completed.returncode}: {completed.stderr.strip()}")
            if completed.stdout.strip() != "200":
                raise NotDownloadable(stage, url, f"HTTP {completed.stdout.strip()}")
            yield path
        finally:
            os.remove(path)

    def npm(self, name):
        url = f"{self.base_url}/{name.replace('/', '%2f')}"
        with self.download("metadata", url, NPM_ACCEPT) as path:
            document = read_json("metadata", url, path)
        if document.get("name") != name:
            raise NotDownloadable("metadata", url, f"metadata names package {document.get('name')!r:.80}")
        versions = document.get("versions")
        entry = versions.get(self.version) if isinstance(versions, dict) else None
        if not isinstance(entry, dict):
            raise NotDownloadable("metadata", url, f"version {self.version} is not listed yet")
        if (entry.get("name"), entry.get("version")) != (name, self.version):
            raise NotDownloadable("metadata", url, f"version entry is {entry.get('name')!r:.80} {entry.get('version')!r:.40}")
        dist = entry.get("dist") if isinstance(entry.get("dist"), dict) else {}
        expected = [
            token[len("sha512-"):].split("?")[0]
            for token in str(dist.get("integrity") or "").split()
            if token.startswith("sha512-")
        ]
        if not expected:
            raise NotDownloadable("integrity", url, "dist.integrity has no sha512 hash")
        tarball = checked_url("metadata", url, dist.get("tarball"), "dist.tarball")
        with self.download("archive", tarball) as path:
            actual = base64.b64encode(file_digest(path, "sha512").digest()).decode()
        if actual not in expected:
            raise NotDownloadable("integrity", tarball, "tarball sha512 does not match dist.integrity")

    def pub(self, name):
        url = f"{self.base_url}/api/packages/{name}"
        with self.download("metadata", url, PUB_ACCEPT) as path:
            document = read_json("metadata", url, path)
        if document.get("name") != name:
            raise NotDownloadable("metadata", url, f"metadata names package {document.get('name')!r:.80}")
        versions = document.get("versions") if isinstance(document.get("versions"), list) else []
        entry = next((item for item in versions if isinstance(item, dict) and item.get("version") == self.version), None)
        if entry is None:
            raise NotDownloadable("metadata", url, f"version {self.version} is not listed yet")
        pubspec = entry.get("pubspec") if isinstance(entry.get("pubspec"), dict) else {}
        if (pubspec.get("name"), pubspec.get("version")) != (name, self.version):
            raise NotDownloadable("metadata", url, f"pubspec is {pubspec.get('name')!r:.80} {pubspec.get('version')!r:.40}")
        expected = str(entry.get("archive_sha256") or "").lower()
        if not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise NotDownloadable("integrity", url, "archive_sha256 is missing")
        archive = checked_url("metadata", url, entry.get("archive_url"), "archive_url")
        with self.download("archive", archive) as path:
            actual = file_digest(path, "sha256").hexdigest()
        if actual != expected:
            raise NotDownloadable("integrity", archive, "archive sha256 does not match archive_sha256")

    def maven(self, coordinates):
        group, artifact = coordinates.split(":")
        base = f"{self.base_url}/{group.replace('.', '/')}/{artifact}/{self.version}/{artifact}-{self.version}"
        url = base + ".pom"
        with self.download("pom", url) as path:
            with open(path, "rb") as stream:
                pom = stream.read()
        try:
            found_group, found_artifact, found_version, packaging = pom_coordinates(pom)
        except ElementTree.ParseError:
            raise NotDownloadable("pom", url, "POM is not XML") from None
        if (found_group, found_artifact, found_version) != (group, artifact, self.version):
            raise NotDownloadable("pom", url, f"POM is for {found_group!r:.80}:{found_artifact!r:.80}:{found_version!r:.40}")
        file_hashes = {}
        if GRADLE_METADATA_MARKER in pom:
            # Gradle resolves from the .module file whenever the POM says one was published.
            url = base + ".module"
            with self.download("module", url) as path:
                module = read_json("module", url, path)
            component = module.get("component") if isinstance(module.get("component"), dict) else {}
            found = (component.get("group"), component.get("module"), component.get("version"))
            if found != (group, artifact, self.version):
                raise NotDownloadable("module", url, "Gradle metadata is for " + ":".join(f"{value!r:.80}" for value in found))
            for variant in module.get("variants") if isinstance(module.get("variants"), list) else []:
                files = variant.get("files") if isinstance(variant, dict) else None
                for item in files if isinstance(files, list) else []:
                    if isinstance(item, dict) and isinstance(item.get("name"), str):
                        file_hashes[item["name"]] = str(item.get("sha256") or "").lower()
        extension = {"aar": "aar", "pom": None}.get(packaging, "jar")
        if extension is None:
            return
        url = f"{base}.{extension}"
        with self.download("archive", url) as path:
            actual = file_digest(path, "sha256").hexdigest()
        expected = file_hashes.get(f"{artifact}-{self.version}.{extension}")
        if expected and actual != expected:
            raise NotDownloadable("integrity", url, "archive sha256 does not match the Gradle metadata")

    def cocoapods(self, name):
        shard = hashlib.md5(name.encode(), usedforsecurity=False).hexdigest()[:3]
        url = f"{self.base_url}/all_pods_versions_{'_'.join(shard)}.txt"
        with self.download("index", url) as path:
            with open(path, encoding="utf-8", errors="replace") as stream:
                versions = next((line.strip().split("/")[1:] for line in stream if line.split("/", 1)[0] == name), [])
        if self.version not in versions:
            raise NotDownloadable("index", url, f"version {self.version} is not listed yet")
        url = f"{self.base_url}/Specs/{'/'.join(shard)}/{name}/{self.version}/{name}.podspec.json"
        with self.download("podspec", url) as path:
            spec = read_json("podspec", url, path)
        if (spec.get("name"), spec.get("version")) != (name, self.version):
            raise NotDownloadable("podspec", url, f"podspec is {spec.get('name')!r:.80} {spec.get('version')!r:.40}")


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ecosystem", required=True, choices=sorted(REGISTRIES))
    parser.add_argument("--version", required=True)
    parser.add_argument("--packages", required=True, help="One per line. Maven packages are group:artifact.")
    parser.add_argument("--timeout-minutes", default="60")
    # Test-only overrides.
    parser.add_argument("--registry-url", help=argparse.SUPPRESS)
    parser.add_argument("--timeout-seconds", type=float, help=argparse.SUPPRESS)
    parser.add_argument("--initial-backoff-seconds", type=float, default=10, help=argparse.SUPPRESS)
    parser.add_argument("--max-backoff-seconds", type=float, default=60, help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def validate(arguments):
    packages = list(dict.fromkeys(line.strip() for line in arguments.packages.splitlines() if line.strip()))
    if not re.fullmatch(VERSION_PATTERN, arguments.version):
        return packages, f"version {arguments.version!r:.80} is not an exact release version such as 1.2.3 or 1.2.3-beta.1"
    if not packages:
        return packages, "packages is empty"
    for package in packages:
        if not re.fullmatch(PACKAGE_PATTERNS[arguments.ecosystem], package):
            return packages, f"{package!r:.80} is not a valid {arguments.ecosystem} package name"
    if not re.fullmatch(r"[1-9][0-9]{0,2}", arguments.timeout_minutes):
        return packages, f"timeout-minutes {arguments.timeout_minutes!r:.20} is not a whole number from 1 to 999"
    for value in (arguments.timeout_seconds, arguments.initial_backoff_seconds, arguments.max_backoff_seconds):
        if value is not None and not value > 0:
            return packages, "timeouts and backoff must be positive"
    if arguments.registry_url and not re.fullmatch(HTTP_URL_PATTERN, arguments.registry_url):
        return packages, "registry-url is not an http(s) URL"
    if shutil.which("curl") is None:
        return packages, "curl is not installed"
    return packages, None


def report_timeout(ecosystem, version, timeout, packages, pending, failures):
    def describe(package):
        failure = failures.get(package)
        return f"{failure.stage}: {failure.detail} ({failure.url})" if failure else "not checked before the deadline"

    still = "; ".join(f"{package}: {describe(package)}" for package in pending)
    log("::error::" + escape_command(
        f"{ecosystem} version {version} is still not downloadable after {describe_duration(timeout)}. {still}"
    ))
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    rows = [
        "### Registry propagation timed out",
        "",
        f"{ecosystem} version `{version}` after {describe_duration(timeout)}.",
        "",
        "| Package | Result | Last URL |",
        "| --- | --- | --- |",
    ]
    for package in packages:
        failure = failures.get(package)
        if package not in pending:
            result, url = "ready", ""
        elif failure:
            result, url = f"not downloadable ({failure.stage}: {failure.detail})", failure.url
        else:
            result, url = "not checked", ""
        rows.append("| " + " | ".join(cell.replace("|", "\\|") for cell in (package, result, url)) + " |")
    with open(summary_path, "a", encoding="utf-8") as stream:
        stream.write("\n".join(rows) + "\n")


def main(argv=None):
    arguments = parse_arguments(argv)
    packages, error = validate(arguments)
    if error:
        log("::error::" + escape_command(error))
        return 2
    version = arguments.version
    timeout = arguments.timeout_seconds or int(arguments.timeout_minutes) * 60
    started = time.monotonic()
    deadline = started + timeout
    base_url = (arguments.registry_url or REGISTRIES[arguments.ecosystem]).rstrip("/")
    log(f"Waiting up to {describe_duration(timeout)} for {arguments.ecosystem} version {version} of: {', '.join(packages)}")
    pending = list(packages)
    failures = {}
    backoff = arguments.initial_backoff_seconds
    with tempfile.TemporaryDirectory() as workdir:
        probe = getattr(Registry(base_url, version, deadline, workdir), arguments.ecosystem)
        while True:
            for package in list(pending):
                try:
                    probe(package)
                except NotDownloadable as failure:
                    # Keep the last real answer rather than a check the deadline cut short.
                    if not (failure.skipped and package in failures):
                        failures[package] = failure
                    if not failure.skipped:
                        log(f"{package} {version}: not downloadable yet. {failure.stage}: {failure.detail} ({failure.url})")
                else:
                    pending.remove(package)
                    failures.pop(package, None)
                    log(f"{package} {version}: downloadable after {time.monotonic() - started:.0f}s.")
            if not pending:
                log(f"All {len(packages)} packages are downloadable at version {version}.")
                return 0
            remaining = deadline - time.monotonic()
            if remaining < MIN_REQUEST_SECONDS:
                break
            time.sleep(min(backoff, remaining))
            backoff = min(backoff * 1.5, arguments.max_backoff_seconds)
    report_timeout(arguments.ecosystem, version, timeout, packages, pending, failures)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
