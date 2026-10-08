#!/usr/bin/env python3
"""Publish an already validated release bundle without replacing a version.

Run in GitHub Actions with its native GITHUB_TOKEN. --preflight performs only
reads and writes the `publish` step output. See docs/RELEASING.md for recovery.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
API_VERSION = "2026-03-10"
OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
VERSION_RE = re.compile(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?")
SHA_RE = re.compile(r"[0-9a-f]{40}")


class PublicationError(RuntimeError):
    """An incomplete, conflicting or unverifiable publication."""


class HTTPFailure(PublicationError):
    def __init__(self, status, url, body=b"", headers=None):
        self.status = status
        self.body = body
        self.headers = headers or {}
        location = urllib.parse.urlsplit(url)
        # Do not expose credentials, signed queries or remote response bodies.
        super().__init__(f"HTTP {status}: {location.netloc}{location.path}")


class SafeRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        old, new = urllib.parse.urlsplit(req.full_url), urllib.parse.urlsplit(newurl)
        if new.scheme != "https":
            raise PublicationError("Refusing a non-HTTPS redirect")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected and (old.scheme, old.netloc) != (new.scheme, new.netloc):
            redirected.remove_header("Authorization")
            redirected.remove_header("Cookie")
        return redirected


class HTTP:
    def __init__(self):
        self.opener = urllib.request.build_opener(SafeRedirects())

    def request(self, method, url, *, headers=None, data=None, output=None):
        request = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
        try:
            with self.opener.open(request, timeout=60) as response:
                if output is None:
                    return response.read()
                with Path(output).open("wb") as destination:
                    while block := response.read(1024 * 1024):
                        destination.write(block)
                return b""
        except urllib.error.HTTPError as exc:
            raise HTTPFailure(exc.code, url, exc.read(8192), dict(exc.headers or {})) from None
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise PublicationError(f"Transport failed for {urllib.parse.urlsplit(url).netloc}: {type(exc).__name__}") from None

    def json(self, method, url, *, headers=None, payload=None):
        headers = dict(headers or {})
        data = None
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        return decode_json(self.request(method, url, headers=headers, data=data))


def decode_json(raw):
    try:
        return json.loads(raw)
    except (ValueError, UnicodeError, TypeError):
        raise PublicationError("Invalid JSON returned by the remote service") from None


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def filenames(version):
    return {
        f"ArmsBridge-{version}.ext": "application/zip",
        f"El-nuevo-Arms-Law-{version}.pdf": "application/pdf",
        f"fg-arms-bridge-{version}-source.zip": "application/zip",
        "SHA256SUMS": "text/plain",
    }


def read_bundle(directory, version):
    directory = Path(directory)
    expected = filenames(version)
    if not directory.is_dir() or {p.name for p in directory.iterdir()} != set(expected):
        raise PublicationError("Release directory must contain exactly the three versioned artifacts and SHA256SUMS")
    if any(p.is_symlink() or not p.is_file() for p in directory.iterdir()):
        raise PublicationError("Release artifacts must be regular files, not symbolic links")
    checksums = {}
    for line in (directory / "SHA256SUMS").read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)", line)
        if not match or match[2] in checksums:
            raise PublicationError("Malformed or duplicate SHA256SUMS entry")
        checksums[match[2]] = match[1]
    if set(checksums) != set(expected) - {"SHA256SUMS"}:
        raise PublicationError("SHA256SUMS must cover exactly the three versioned artifacts")
    for name, expected_hash in checksums.items():
        if digest(directory / name) != expected_hash:
            raise PublicationError(f"Local checksum mismatch: {name}")
    checksums["SHA256SUMS"] = digest(directory / "SHA256SUMS")
    return checksums


class GitHub:
    def __init__(self, http, repository, token):
        self.http = http
        self.repository = repository
        self.base = f"https://api.github.com/repos/{repository}"
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": API_VERSION,
            "User-Agent": "fg-arms-bridge-release",
        }

    def api(self, path="", *, method="GET", payload=None):
        return self.http.json(method, self.base + path, headers=self.headers, payload=payload)

    def optional(self, path):
        try:
            return self.api(path)
        except HTTPFailure as exc:
            if exc.status == 404:
                return None
            raise

    def verify_access(self):
        repository = self.api()
        if repository.get("full_name", "").lower() != self.repository.lower():
            raise PublicationError("GitHub repository identity differs from the workflow repository")
        # Installation tokens need not expose user-style permissions.push here.
        # The workflow requests contents/packages write; actual denials propagate.
        if repository.get("private") is not False:
            raise PublicationError("Publication requires the public repository")

    def listing(self, path):
        result = []
        for page in range(1, 1001):
            batch = self.api(f"{path}?per_page=100&page={page}")
            if not isinstance(batch, list):
                raise PublicationError("Expected a paginated GitHub list")
            result.extend(batch)
            if len(batch) < 100:
                return result
        raise PublicationError("GitHub pagination exceeded its safety bound")

    def release(self, tag):
        # Listing includes authenticated drafts; GET /releases/tags is documented
        # for published releases and must not hide an interrupted draft upload.
        matches = [r for r in self.listing("/releases") if r.get("tag_name") == tag]
        if len(matches) > 1:
            raise PublicationError(f"Multiple releases use {tag}; refusing to select one")
        return matches[0] if matches else None

    def tag_commit(self, tag):
        ref = self.optional("/git/ref/tags/" + urllib.parse.quote(tag, safe=""))
        if ref is None:
            return None
        if not isinstance(ref, dict) or ref.get("ref") != "refs/tags/" + tag:
            raise PublicationError("GitHub returned a different tag reference")
        obj = ref.get("object", {})
        for _ in range(10):
            if not SHA_RE.fullmatch(obj.get("sha", "")):
                raise PublicationError("GitHub returned an invalid tag object")
            if obj.get("type") == "commit":
                return obj["sha"]
            if obj.get("type") != "tag":
                break
            obj = self.api("/git/tags/" + obj["sha"]).get("object", {})
        raise PublicationError("The release tag does not resolve to a commit")

    def ensure_tag(self, tag, revision):
        if self.tag_commit(tag) is None:
            try:
                self.api("/git/refs", method="POST", payload={"ref": "refs/tags/" + tag, "sha": revision})
            except HTTPFailure as exc:
                if exc.status not in (409, 422) or self.tag_commit(tag) != revision:
                    raise
        if self.tag_commit(tag) != revision:
            raise PublicationError("Existing tag points at another commit; it will not be moved")

    def assets(self, release):
        assets = self.listing(f"/releases/{int(release['id'])}/assets")
        names = [asset.get("name") for asset in assets]
        if len(set(names)) != len(names):
            raise PublicationError("Duplicate release asset names")
        return {asset["name"]: asset for asset in assets}

    def download(self, asset, destination):
        headers = dict(self.headers, Accept="application/octet-stream")
        self.http.request("GET", f"{self.base}/releases/assets/{int(asset['id'])}", headers=headers, output=destination)

    def upload(self, release, path, media_type):
        url = f"https://uploads.github.com/repos/{self.repository}/releases/{int(release['id'])}/assets"
        url += "?" + urllib.parse.urlencode({"name": path.name})
        headers = dict(self.headers, **{"Content-Type": media_type})
        return decode_json(self.http.request("POST", url, headers=headers, data=path.read_bytes()))


class Registry:
    def __init__(self, http, actor, token):
        self.http, self.actor, self.token = http, actor, token

    def manifest(self, package, version):
        url = f"https://ghcr.io/v2/{package}/manifests/{version}"
        headers = {"Accept": OCI_MANIFEST}
        try:
            raw = self.http.request("GET", url, headers=headers)
        except HTTPFailure as exc:
            if exc.status != 401:
                # In particular an unauthenticated 404 cannot establish absence.
                raise
            challenge = next((v for k, v in exc.headers.items() if k.lower() == "www-authenticate"), "")
            params = dict(re.findall(r'([A-Za-z_]+)="([^"]*)"', challenge))
            if not challenge.lower().startswith("bearer ") or params.get("realm") != "https://ghcr.io/token" or params.get("service") != "ghcr.io":
                raise PublicationError("Unexpected GHCR authentication challenge") from None
            query = urllib.parse.urlencode({"service": "ghcr.io", "scope": f"repository:{package}:pull,push"})
            credentials = base64.b64encode(f"{self.actor}:{self.token}".encode()).decode()
            auth = self.http.json("GET", params["realm"] + "?" + query,
                                  headers={"Authorization": "Basic " + credentials})
            bearer = auth.get("token") or auth.get("access_token")
            if not isinstance(bearer, str) or not bearer:
                raise PublicationError("GHCR did not return an authorization token")
            headers["Authorization"] = "Bearer " + bearer
            try:
                raw = self.http.request("GET", url, headers=headers)
            except HTTPFailure as authenticated:
                if authenticated.status == 404:
                    errors = decode_json(authenticated.body).get("errors", [])
                    if errors and all(e.get("code") in {"MANIFEST_UNKNOWN", "NAME_UNKNOWN"} for e in errors):
                        return None
                raise
        return decode_json(raw), "sha256:" + hashlib.sha256(raw).hexdigest()


class Oras:
    def __init__(self, actor, token, config):
        self.actor, self.token, self.config = actor, token, Path(config)
        self.logged_in = False

    def run(self, command, *, cwd=None, input_text=None):
        try:
            result = subprocess.run(["oras", *command, "--registry-config", str(self.config)],
                                    cwd=cwd, input=input_text, text=True, capture_output=True, timeout=600)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise PublicationError(f"ORAS {command[0]} failed: {type(exc).__name__}") from None
        if result.returncode:
            detail = result.stderr.strip().replace(self.token, "[redacted]")[-1600:]
            raise PublicationError(f"ORAS {command[0]} failed ({result.returncode}): {detail}")
        return result.stdout

    def login(self):
        if not self.logged_in:
            self.run(["login", "ghcr.io", "--username", self.actor, "--password-stdin"], input_text=self.token)
            if self.config.exists():
                self.config.chmod(0o600)
            self.logged_in = True

    def push(self, reference, path, media_type, artifact_type, annotations):
        self.login()
        command = ["push", reference, "--image-spec", "v1.1", "--artifact-type", artifact_type]
        for key, value in sorted(annotations.items()):
            command.extend(["--annotation", f"{key}={value}"])
        command.append(f"{path.name}:{media_type}")
        self.run(command, cwd=path.parent)

    def pull(self, reference, destination):
        self.login()
        self.run(["pull", reference, "--output", str(destination)])


def release_marker(version, revision):
    return f"<!-- arms-bridge-release:v1 version={version} revision={revision} -->"


class Publisher:
    def __init__(self, github, registry, oras, *, version, revision, mode, is_ancestor, created):
        self.github, self.registry, self.oras = github, registry, oras
        self.version, self.revision, self.mode = version, revision, mode
        self.is_ancestor, self.created = is_ancestor, created
        self.tag = "v" + version

    def preflight(self):
        self.github.verify_access()
        tag_revision = self.github.tag_commit(self.tag)
        release = self.github.release(self.tag)
        if release and tag_revision is None:
            raise PublicationError("Release exists without its tag; refusing to recreate provenance")
        if tag_revision and tag_revision != self.revision:
            if self.mode == "main" and release and not release.get("draft") and self.is_ancestor(tag_revision, self.revision):
                assets = self.github.assets(release)
                if (set(assets) != set(filenames(self.version))
                        or any(a.get("state") != "uploaded" or not isinstance(a.get("size"), int)
                               or a["size"] <= 0 for a in assets.values())):
                    raise PublicationError("Earlier published version is incomplete; rerun its original workflow")
                print(f"SKIP {self.tag}: already published from earlier commit {tag_revision}")
                return False
            raise PublicationError("Version/tag belongs to another commit; bump VERSION or rerun the original workflow")
        if release and release.get("draft") and release_marker(self.version, self.revision) not in (release.get("body") or ""):
            raise PublicationError("Existing draft has no matching publication marker; it will not be modified")
        if release and release.get("prerelease") != ("-" in self.version):
            raise PublicationError("Existing release has a different prerelease designation")
        return True

    def packages(self):
        base = self.github.repository.lower()
        return [
            (base + "-extension", f"ArmsBridge-{self.version}.ext", "application/zip", "application/vnd.fg-arms-bridge.extension.v1"),
            (base + "-manual", f"El-nuevo-Arms-Law-{self.version}.pdf", "application/pdf", "application/vnd.fg-arms-bridge.manual.v1"),
        ]

    def annotations(self):
        return {
            "org.opencontainers.image.source": "https://github.com/" + self.github.repository,
            "org.opencontainers.image.version": self.version,
            "org.opencontainers.image.revision": self.revision,
            "org.opencontainers.image.created": self.created,
        }

    def check_manifest(self, found, package, name, media_type, artifact_type, directory, checksums):
        if found is None:
            return
        manifest, _ = found
        annotations = manifest.get("annotations", {})
        if manifest.get("schemaVersion") != 2 or manifest.get("mediaType") != OCI_MANIFEST or manifest.get("artifactType") != artifact_type:
            raise PublicationError(f"Existing package has a different artifact format: {package}")
        if any(annotations.get(key) != value for key, value in self.annotations().items()):
            raise PublicationError(f"Existing package has different source/version/revision metadata: {package}")
        layers = manifest.get("layers", [])
        if len(layers) != 1:
            raise PublicationError(f"Existing package has unexpected payloads: {package}")
        layer = layers[0]
        if (layer.get("digest") != "sha256:" + checksums[name]
                or layer.get("size") != (directory / name).stat().st_size
                or layer.get("mediaType") != media_type
                or layer.get("annotations", {}).get("org.opencontainers.image.title") != name):
            raise PublicationError(f"Existing package payload differs: {package}; refusing to overwrite")

    def check_assets(self, release, directory, checksums, *, complete=False):
        assets = self.github.assets(release)
        if set(assets) - set(checksums) or (complete and set(assets) != set(checksums)):
            raise PublicationError("Release asset set differs from the expected bundle")
        with tempfile.TemporaryDirectory(prefix="armsbridge-release-download-") as temporary:
            for name, asset in assets.items():
                if asset.get("state") != "uploaded" or asset.get("size") != (directory / name).stat().st_size:
                    raise PublicationError(f"Existing release asset is incomplete or differs: {name}")
                remote_digest = asset.get("digest")
                if remote_digest is not None and remote_digest != "sha256:" + checksums[name]:
                    raise PublicationError(f"Existing release asset checksum differs: {name}")
                path = Path(temporary) / name
                self.github.download(asset, path)
                if digest(path) != checksums[name]:
                    raise PublicationError(f"Downloaded release asset checksum differs: {name}")
        return assets

    def publish(self, directory):
        if not self.preflight():
            return "skipped"
        directory = Path(directory)
        checksums = read_bundle(directory, self.version)
        release = self.github.release(self.tag)
        if release:
            self.check_assets(release, directory, checksums)
        packages = self.packages()
        for package, name, media_type, artifact_type in packages:
            found = self.registry.manifest(package, self.version)
            self.check_manifest(found, package, name, media_type, artifact_type, directory, checksums)

        # The Git tag reserves provenance before any binary is published. Never
        # PATCH a ref or DELETE an asset/package to recover from a conflict.
        self.github.ensure_tag(self.tag, self.revision)
        if release is None:
            notes = (
                f"Arms Bridge {self.version}: extensión para Fantasy Grounds 5E y manual ilustrado de 52 páginas.\n\n"
                "Tablas experimentales originales; calibración y prueba real en Fantasy Grounds pendientes. "
                "Los archivos .ext, PDF y código fuente se adjuntan con SHA256SUMS.\n\n"
                "Paquetes OCI (GHCR puede conservar su visibilidad inicial privada):\n"
                + "\n".join(f"- `ghcr.io/{package}:{self.version}`" for package, *_ in packages)
                + "\n\n" + release_marker(self.version, self.revision)
            )
            payload = {"tag_name": self.tag, "target_commitish": self.revision,
                       "name": "Arms Bridge " + self.version, "body": notes,
                       "draft": True, "prerelease": "-" in self.version, "make_latest": "false"}
            try:
                release = self.github.api("/releases", method="POST", payload=payload)
            except HTTPFailure as exc:
                if exc.status != 422:
                    raise
                release = self.github.release(self.tag)
                if not release or release_marker(self.version, self.revision) not in (release.get("body") or ""):
                    raise
                self.check_assets(release, directory, checksums)

        for package, name, media_type, artifact_type in packages:
            # Re-read immediately before writing; workflow concurrency serializes
            # our publishers. External tools must not retag these versions.
            found = self.registry.manifest(package, self.version)
            self.check_manifest(found, package, name, media_type, artifact_type, directory, checksums)
            if found is None:
                self.oras.push(f"ghcr.io/{package}:{self.version}", directory / name,
                               media_type, artifact_type, self.annotations())
                found = self.registry.manifest(package, self.version)
                if found is None:
                    raise PublicationError(f"Package is missing after upload: {package}")
                self.check_manifest(found, package, name, media_type, artifact_type, directory, checksums)
            with tempfile.TemporaryDirectory(prefix="armsbridge-oci-download-") as temporary:
                self.oras.pull(f"ghcr.io/{package}@{found[1]}", Path(temporary))
                paths = list(Path(temporary).iterdir())
                if len(paths) != 1 or paths[0].name != name or paths[0].is_symlink() or not paths[0].is_file() or digest(paths[0]) != checksums[name]:
                    raise PublicationError(f"OCI round-trip checksum differs: {package}")
            after = self.registry.manifest(package, self.version)
            if after is None or after[1] != found[1]:
                raise PublicationError(f"Package tag changed during verification: {package}")

        existing = self.check_assets(release, directory, checksums)
        for name, media_type in filenames(self.version).items():
            if name not in existing:
                self.github.upload(release, directory / name, media_type)
        self.check_assets(release, directory, checksums, complete=True)
        if self.github.tag_commit(self.tag) != self.revision:
            raise PublicationError("Git tag changed during publication")
        if release.get("draft"):
            self.github.api(f"/releases/{int(release['id'])}", method="PATCH",
                            payload={"draft": False, "prerelease": "-" in self.version, "make_latest": "false"})
        final = self.github.release(self.tag)
        if not final or final.get("draft") or final.get("prerelease") != ("-" in self.version):
            raise PublicationError("Release did not reach its expected published state")
        print(f"VERIFIED https://github.com/{self.github.repository}/releases/tag/{self.tag}")
        return "verified"


def git(*args):
    result = subprocess.run(["git", *args], cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise PublicationError("Unable to establish source revision with git")
    return result.stdout.strip()


def is_ancestor(older, newer):
    result = subprocess.run(["git", "merge-base", "--is-ancestor", older, newer], cwd=ROOT)
    if result.returncode not in (0, 1):
        raise PublicationError("Unable to verify earlier release ancestry; checkout requires fetch-depth: 0")
    return result.returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--artifacts", type=Path, default=ROOT / "dist" / "release")
    args = parser.parse_args()
    try:
        version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
        if not VERSION_RE.fullmatch(version) or len(version) > 100:
            raise PublicationError("VERSION is not a supported SemVer/OCI tag")
        repository = os.environ.get("GITHUB_REPOSITORY", "")
        if repository != "murillo128/fg-arms-bridge":
            raise PublicationError("Publication is restricted to murillo128/fg-arms-bridge")
        token, actor = os.environ.get("GITHUB_TOKEN", ""), os.environ.get("GITHUB_ACTOR", "")
        if not token or not actor:
            raise PublicationError("The workflow's native GITHUB_TOKEN and GITHUB_ACTOR are required")
        revision = git("rev-parse", "HEAD")
        if not SHA_RE.fullmatch(revision) or os.environ.get("GITHUB_SHA") != revision:
            raise PublicationError("Checked-out commit differs from GITHUB_SHA")
        ref = os.environ.get("GITHUB_REF", "")
        if os.environ.get("GITHUB_EVENT_NAME") not in {"push", "workflow_dispatch"}:
            raise PublicationError("Publication requires a main/tag push or workflow_dispatch")
        if ref == "refs/heads/main":
            mode = "main"
        elif ref == "refs/tags/v" + version:
            mode = "tag"
        else:
            raise PublicationError("Publishing ref must be main or the explicit tag matching VERSION")
        http = HTTP()
        with tempfile.TemporaryDirectory(prefix="armsbridge-registry-auth-") as temporary:
            publisher = Publisher(GitHub(http, repository, token), Registry(http, actor, token),
                                  Oras(actor, token, Path(temporary) / "config.json"),
                                  version=version, revision=revision, mode=mode,
                                  is_ancestor=is_ancestor, created=git("show", "-s", "--format=%cI", "HEAD"))
            if args.preflight:
                should_publish = publisher.preflight()
                if output := os.environ.get("GITHUB_OUTPUT"):
                    with Path(output).open("a", encoding="utf-8") as stream:
                        stream.write(f"publish={str(should_publish).lower()}\n")
                print(f"Publication required: {str(should_publish).lower()}")
            else:
                publisher.publish(args.artifacts.resolve())
    except (PublicationError, OSError, ValueError, KeyError, TypeError) as exc:
        print(f"FAIL publication: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
