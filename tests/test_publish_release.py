"""Publication boundary tests: real files/hashes and fake HTTP/ORAS transports.

The fixtures define a three-file release independently of the publisher. They
exercise the actual HTTP requests, manifests, downloads and publication state;
they do not claim to exercise an installed ORAS binary or live GitHub/GHCR.
"""
from pathlib import Path
import base64
import copy
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from unittest import mock
import urllib.error
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("armsbridge_publish", ROOT / "tools" / "publish_release.py")
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)
REAL_RUN = subprocess.run
REPOSITORY = "murillo128/fg-arms-bridge"
VERSION = "0.3.1-alpha"
REVISION = "a" * 40
LATER = "b" * 40
CREATED = "2026-10-08T14:00:00+00:00"
TOKEN = "test-only-token-never-a-real-secret"
FILES = {
    "ArmsBridge-0.3.1-alpha.ext": b"tiny extension fixture\n",
    "El-nuevo-Arms-Law-0.3.1-alpha.pdf": b"%PDF-1.4\ntiny manual fixture\n",
    "fg-arms-bridge-0.3.1-alpha-source.zip": b"tiny source fixture\n",
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


class Remote:
    """HTTP/command double retaining bytes, including lost-upload responses."""
    def __init__(self):
        self.tag = None
        self.release = None
        self.assets = {}
        self.packages = {}
        self.other_releases = []
        self.writes = []
        self.pushes = []
        self.pulls = []
        self.fail_route = None
        self.fail_registry = None
        self.fail_push = None
        self.lose_upload_response = None
        self.corrupt_pull = False
        self.corrupt_download = False
        self.tag_race = None

    def error(self, url, status, body=None, headers=None):
        body = {"message": "Not Found"} if body is None else body
        raise urllib.error.HTTPError(url, status, "fixture error", headers or {}, io.BytesIO(json.dumps(body).encode()))

    def open(self, request, timeout=None):
        url = urllib.parse.urlsplit(request.full_url)
        method = request.get_method()
        query = urllib.parse.parse_qs(url.query)
        headers = {key.lower(): value for key, value in request.header_items()}
        path = url.path
        if self.fail_route and path == self.fail_route[0]:
            failure = self.fail_route[1]
            if failure == "network":
                raise urllib.error.URLError("fixture connection failure")
            self.error(request.full_url, failure)
        if url.netloc in {"api.github.com", "uploads.github.com"}:
            if headers.get("authorization") != "Bearer " + TOKEN:
                self.error(request.full_url, 401)
            if method in {"POST", "PATCH", "DELETE"}:
                self.writes.append((method, path, copy.deepcopy(query)))
            endpoint = path.removeprefix("/repos/" + REPOSITORY)
            if method == "GET" and endpoint == "":
                # App installation tokens need not return user-style permissions.
                value = {"full_name": REPOSITORY, "private": False}
            elif method == "GET" and endpoint == "/git/ref/tags/v" + VERSION:
                if self.tag is None:
                    self.error(request.full_url, 404)
                value = {"ref": "refs/tags/v" + VERSION, "object": {"type": "commit", "sha": self.tag}}
            elif method == "POST" and endpoint == "/git/refs":
                payload = json.loads(request.data)
                if self.tag_race:
                    self.tag, self.tag_race = self.tag_race, None
                    self.error(request.full_url, 422)
                if self.tag is not None:
                    self.error(request.full_url, 422)
                self.tag = payload["sha"]
                value = {"ref": payload["ref"], "object": {"type": "commit", "sha": self.tag}}
            elif method == "GET" and endpoint == "/releases":
                all_releases = self.other_releases + ([self.release] if self.release else [])
                page = int(query["page"][0])
                value = all_releases[(page - 1) * 100:page * 100]
            elif method == "POST" and endpoint == "/releases":
                if self.release:
                    self.error(request.full_url, 422)
                self.release = dict(json.loads(request.data), id=1)
                value = self.release
            elif method == "PATCH" and endpoint == "/releases/1":
                self.release.update(json.loads(request.data))
                value = self.release
            elif method == "GET" and endpoint == "/releases/1/assets":
                value = [asset["metadata"] for asset in self.assets.values()]
            elif method == "POST" and endpoint == "/releases/1/assets":
                name = query["name"][0]
                if name in self.assets:
                    self.error(request.full_url, 422, {"message": "asset already exists"})
                data = request.data
                value = {"id": len(self.assets) + 1, "name": name, "size": len(data),
                         "state": "uploaded", "digest": "sha256:" + sha(data)}
                self.assets[name] = {"metadata": value, "data": data}
                if self.lose_upload_response == name:
                    self.lose_upload_response = None
                    raise urllib.error.URLError("fixture: upload accepted, response lost")
            elif method == "GET" and endpoint.startswith("/releases/assets/"):
                ident = int(endpoint.rsplit("/", 1)[1])
                entry = next(asset for asset in self.assets.values() if asset["metadata"]["id"] == ident)
                return io.BytesIO(entry["data"] + (b"CORRUPTION" if self.corrupt_download else b""))
            else:
                raise AssertionError(f"Unexpected GitHub operation: {method} {endpoint}")
            return io.BytesIO(json.dumps(value).encode())
        if url.netloc == "ghcr.io":
            if path == "/token":
                expected = "Basic " + base64.b64encode(("fixture-actor:" + TOKEN).encode()).decode()
                if headers.get("authorization") != expected:
                    self.error(request.full_url, 401)
                return io.BytesIO(b'{"token":"fixture-registry-bearer"}')
            package, tag = path.removeprefix("/v2/").split("/manifests/")
            if headers.get("authorization") != "Bearer fixture-registry-bearer":
                challenge = f'Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:{package}:pull"'
                self.error(request.full_url, 401, {"errors": [{"code": "UNAUTHORIZED"}]}, {"WWW-Authenticate": challenge})
            if self.fail_registry:
                status, code = self.fail_registry
                self.error(request.full_url, status, {"errors": [{"code": code}]})
            key = package + ":" + tag
            if key not in self.packages:
                self.error(request.full_url, 404, {"errors": [{"code": "MANIFEST_UNKNOWN"}]})
            return io.BytesIO(json.dumps(self.packages[key]["manifest"]).encode())
        raise AssertionError("Unexpected host: " + url.netloc)

    def run(self, command, **kwargs):
        if command[0] != "oras":
            return REAL_RUN(command, **kwargs)
        if TOKEN in " ".join(command):
            raise AssertionError("Token appeared in process arguments")
        operation = command[1]
        config = Path(command[command.index("--registry-config") + 1])
        if operation == "login":
            if kwargs.get("input") != TOKEN:
                raise AssertionError("Expected password through stdin")
            config.write_text("temporary fixture credentials", encoding="utf-8")
        elif operation == "push":
            reference = command[2].removeprefix("ghcr.io/")
            if self.fail_push and self.fail_push in reference:
                self.fail_push = None
                return subprocess.CompletedProcess(command, 1, "", "fixture network failure")
            if reference in self.packages:
                raise AssertionError("Publisher tried to replace an existing package")
            annotations = {}
            for index, part in enumerate(command):
                if part == "--annotation":
                    key, value = command[index + 1].split("=", 1)
                    annotations[key] = value
            name, media_type = command[-3].split(":", 1)
            data = (Path(kwargs["cwd"]) / name).read_bytes()
            artifact_type = command[command.index("--artifact-type") + 1]
            manifest = {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                        "artifactType": artifact_type, "annotations": annotations,
                        "layers": [{"mediaType": media_type, "digest": "sha256:" + sha(data),
                                    "size": len(data), "annotations": {"org.opencontainers.image.title": name}}]}
            self.packages[reference] = {"manifest": manifest, "name": name, "data": data}
            self.pushes.append(reference)
        elif operation == "pull":
            reference = command[2].removeprefix("ghcr.io/")
            package, expected = reference.split("@", 1)
            entry = next(p for key, p in self.packages.items()
                         if key.startswith(package + ":") and "sha256:" + sha(json.dumps(p["manifest"]).encode()) == expected)
            destination = Path(command[command.index("--output") + 1])
            (destination / entry["name"]).write_bytes(entry["data"] + (b"CORRUPTION" if self.corrupt_pull else b""))
            self.pulls.append(reference)
        else:
            raise AssertionError("Unexpected ORAS command: " + operation)
        return subprocess.CompletedProcess(command, 0, "", "")


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="publication-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.bundle = self.directory / "release"
        self.bundle.mkdir()
        for name, data in FILES.items():
            (self.bundle / name).write_bytes(data)
        checksum_text = "".join(f"{sha(data)}  {name}\n" for name, data in FILES.items())
        (self.bundle / "SHA256SUMS").write_text(checksum_text, encoding="utf-8")
        self.remote = Remote()
        http = publication.HTTP()
        http.opener = self.remote
        self.http = http
        self.github = publication.GitHub(http, REPOSITORY, TOKEN)
        self.registry = publication.Registry(http, "fixture-actor", TOKEN)
        self.oras = publication.Oras("fixture-actor", TOKEN, self.directory / "config.json")
        self.publisher = publication.Publisher(self.github, self.registry, self.oras,
            version=VERSION, revision=REVISION, mode="main", created=CREATED,
            is_ancestor=lambda older, newer: (older, newer) == (REVISION, LATER))
        patch = mock.patch.object(subprocess, "run", self.remote.run)
        patch.start()
        self.addCleanup(patch.stop)
        # These are mocked publications, not evidence of a live release URL.
        output = mock.patch("sys.stdout", new_callable=io.StringIO)
        self.output = output.start()
        self.addCleanup(output.stop)

    def publish(self):
        return self.publisher.publish(self.bundle)

    def test_first_publication_and_exact_repeat_preserve_all_bytes(self):
        self.assertEqual(self.publish(), "verified")
        self.assertEqual(self.remote.tag, REVISION)
        self.assertFalse(self.remote.release["draft"])
        self.assertTrue(self.remote.release["prerelease"])
        self.assertEqual(set(self.remote.assets), set(FILES) | {"SHA256SUMS"})
        for name, data in FILES.items():
            self.assertEqual(self.remote.assets[name]["data"], data)
        self.assertEqual(set(self.remote.packages), {
            REPOSITORY + "-extension:" + VERSION, REPOSITORY + "-manual:" + VERSION})
        for entry in self.remote.packages.values():
            self.assertEqual(entry["data"], FILES[entry["name"]])
            self.assertEqual(entry["manifest"]["annotations"], {
                "org.opencontainers.image.source": "https://github.com/" + REPOSITORY,
                "org.opencontainers.image.version": VERSION,
                "org.opencontainers.image.revision": REVISION,
                "org.opencontainers.image.created": CREATED,
            })
        writes = copy.deepcopy(self.remote.writes)
        self.assertEqual(self.publish(), "verified")
        self.assertEqual(self.remote.writes, writes)
        self.assertEqual(len(self.remote.pushes), 2)
        self.assertEqual(len(self.remote.pulls), 4)
        self.assertEqual((self.directory / "config.json").stat().st_mode & 0o777, 0o600)

    def test_partial_package_publication_resumes_without_replacing_first_package(self):
        self.remote.fail_push = "-manual:"
        with self.assertRaisesRegex(publication.PublicationError, "ORAS push failed"):
            self.publish()
        first = copy.deepcopy(self.remote.packages)
        self.assertEqual(len(first), 1)
        self.assertTrue(self.remote.release["draft"])
        self.assertEqual(self.remote.assets, {})
        self.assertEqual(self.publish(), "verified")
        self.assertEqual(len(self.remote.pushes), 2)
        for key, entry in first.items():
            self.assertEqual(self.remote.packages[key], entry)

    def test_lost_asset_response_resumes_paginated_draft_without_duplicate_upload(self):
        name = "ArmsBridge-0.3.1-alpha.ext"
        self.remote.lose_upload_response = name
        with self.assertRaisesRegex(publication.PublicationError, "Transport failed"):
            self.publish()
        self.assertTrue(self.remote.release["draft"])
        self.assertEqual(self.remote.assets[name]["data"], FILES[name])
        self.remote.other_releases = [{"id": n + 10, "tag_name": f"v0.0.{n}", "draft": False} for n in range(100)]
        self.assertEqual(self.publish(), "verified")
        uploads = [query["name"][0] for method, path, query in self.remote.writes
                   if method == "POST" and path.endswith("/assets")]
        self.assertEqual(uploads.count(name), 1)
        self.assertEqual(len(self.remote.pushes), 2)
        self.assertEqual(sum(path.endswith("/releases") for method, path, _ in self.remote.writes if method == "POST"), 1)

    def test_existing_package_payload_or_provenance_conflict_never_overwrites(self):
        self.publish()
        reference = REPOSITORY + "-extension:" + VERSION
        original = copy.deepcopy(self.remote.packages[reference])
        for change in ("revision", "payload"):
            with self.subTest(change=change):
                self.remote.packages[reference] = copy.deepcopy(original)
                manifest = self.remote.packages[reference]["manifest"]
                if change == "revision":
                    manifest["annotations"]["org.opencontainers.image.revision"] = LATER
                else:
                    manifest["layers"][0]["digest"] = "sha256:" + "0" * 64
                writes = copy.deepcopy(self.remote.writes)
                with self.assertRaisesRegex(publication.PublicationError, "Existing package"):
                    self.publish()
                self.assertEqual(self.remote.writes, writes)
                self.assertEqual(len(self.remote.pushes), 2)

    def test_existing_asset_without_digest_is_verified_from_downloaded_bytes(self):
        self.publish()
        entry = self.remote.assets["ArmsBridge-0.3.1-alpha.ext"]
        entry["metadata"].pop("digest")
        entry["data"] = b"X" + entry["data"][1:]
        writes = copy.deepcopy(self.remote.writes)
        with self.assertRaisesRegex(publication.PublicationError, "Downloaded release asset checksum differs"):
            self.publish()
        self.assertEqual(self.remote.writes, writes)
        self.assertEqual(len(self.remote.pushes), 2)

    def test_registry_round_trip_corruption_keeps_release_in_draft(self):
        self.remote.corrupt_pull = True
        with self.assertRaisesRegex(publication.PublicationError, "OCI round-trip checksum differs"):
            self.publish()
        self.assertTrue(self.remote.release["draft"])
        self.assertFalse(self.remote.assets)

    def test_release_download_corruption_keeps_release_in_draft(self):
        self.remote.corrupt_download = True
        with self.assertRaisesRegex(publication.PublicationError, "Downloaded release asset checksum differs"):
            self.publish()
        self.assertTrue(self.remote.release["draft"])
        self.assertEqual(set(self.remote.assets), set(FILES) | {"SHA256SUMS"})

    def test_later_main_skips_only_complete_ancestor_release_and_explicit_tag_conflicts(self):
        self.publish()
        self.publisher.revision = LATER
        writes = copy.deepcopy(self.remote.writes)
        self.assertEqual(self.publish(), "skipped")
        self.assertEqual(self.remote.writes, writes)
        self.publisher.mode = "tag"
        with self.assertRaisesRegex(publication.PublicationError, "another commit"):
            self.publish()
        self.assertEqual(self.remote.writes, writes)
        self.publisher.mode = "main"
        self.publisher.is_ancestor = lambda old, new: False
        with self.assertRaisesRegex(publication.PublicationError, "another commit"):
            self.publish()

    def test_later_main_does_not_hide_incomplete_published_release(self):
        self.publish()
        self.remote.assets.pop("SHA256SUMS")
        self.publisher.revision = LATER
        with self.assertRaisesRegex(publication.PublicationError, "incomplete"):
            self.publish()

    def test_tag_creation_race_accepts_same_commit_and_rejects_other_commit(self):
        self.remote.tag_race = LATER
        with self.assertRaises(publication.HTTPFailure):
            self.publish()
        self.assertEqual(self.remote.tag, LATER)
        self.assertIsNone(self.remote.release)
        self.assertEqual(self.remote.pushes, [])
        self.remote.tag = None
        self.remote.tag_race = REVISION
        self.assertEqual(self.publish(), "verified")
        self.assertEqual(self.remote.tag, REVISION)

    def test_unowned_draft_is_not_completed(self):
        self.remote.tag = REVISION
        self.remote.release = {"id": 1, "tag_name": "v" + VERSION, "draft": True, "body": "Another publisher's draft"}
        with self.assertRaisesRegex(publication.PublicationError, "publication marker"):
            self.publish()
        self.assertEqual(self.remote.writes, [])

    def test_github_auth_rate_limit_server_and_network_failures_are_not_absence(self):
        for endpoint in ("/repos/" + REPOSITORY, "/repos/" + REPOSITORY + "/git/ref/tags/v" + VERSION,
                         "/repos/" + REPOSITORY + "/releases"):
            for status in (401, 403, 429, 500, "network"):
                with self.subTest(endpoint=endpoint, status=status):
                    self.remote.fail_route = endpoint, status
                    with self.assertRaises(publication.PublicationError):
                        self.publish()
                    self.assertEqual(self.remote.writes, [])
                    self.assertEqual(self.remote.pushes, [])

    def test_registry_auth_unknown_404_and_server_errors_are_not_absence(self):
        for status, code in ((401, "UNAUTHORIZED"), (403, "DENIED"), (404, "DENIED"), (500, "UNKNOWN")):
            with self.subTest(status=status, code=code):
                self.remote.fail_registry = status, code
                with self.assertRaises(publication.HTTPFailure):
                    self.publish()
                self.assertEqual(self.remote.writes, [])
                self.assertEqual(self.remote.pushes, [])

    def test_corrupt_local_bundle_fails_before_remote_mutation(self):
        (self.bundle / "El-nuevo-Arms-Law-0.3.1-alpha.pdf").write_bytes(b"changed after build")
        with self.assertRaisesRegex(publication.PublicationError, "Local checksum mismatch"):
            self.publish()
        self.assertEqual(self.remote.writes, [])

    def test_checksum_manifest_rejects_duplicates_missing_entries_and_traversal(self):
        checksum_file = self.bundle / "SHA256SUMS"
        original = checksum_file.read_text(encoding="utf-8")
        for text in (original + original.splitlines()[0] + "\n", "\n".join(original.splitlines()[1:]),
                     original.replace("ArmsBridge-0.3.1-alpha.ext", "../ArmsBridge-0.3.1-alpha.ext")):
            with self.subTest(text=text):
                checksum_file.write_text(text, encoding="utf-8")
                with self.assertRaises(publication.PublicationError):
                    self.publish()
                self.assertEqual(self.remote.writes, [])

    def test_cross_origin_download_redirect_drops_credentials_and_rejects_http(self):
        request = urllib.request.Request("https://api.github.com/repos/a/b/releases/assets/1", headers={
            "Authorization": "Bearer " + TOKEN, "Cookie": "secret=fixture", "Accept": "application/octet-stream"})
        handler = publication.SafeRedirects()
        redirected = handler.redirect_request(request, None, 302, "Found", {}, "https://release-assets.githubusercontent.com/file?signed=fixture")
        headers = {key.lower(): value for key, value in redirected.header_items()}
        self.assertNotIn("authorization", headers)
        self.assertNotIn("cookie", headers)
        self.assertEqual(headers["accept"], "application/octet-stream")
        with self.assertRaises(publication.PublicationError):
            handler.redirect_request(request, None, 302, "Found", {}, "http://example.com/file")
        self.assertNotIn("signed=", str(publication.HTTPFailure(403, "https://example.com/file?signed=private")))

    def test_actions_entrypoint_rejects_wrong_tag_branch_repository_event_and_head(self):
        (self.directory / "VERSION").write_text(VERSION + "\n", encoding="utf-8")
        environment = {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_TOKEN": TOKEN,
                       "GITHUB_ACTOR": "fixture-actor", "GITHUB_SHA": REVISION,
                       "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main"}
        cases = [
            ("GITHUB_REF", "refs/tags/v9.9.9", "explicit tag matching VERSION"),
            ("GITHUB_REF", "refs/heads/feature", "explicit tag matching VERSION"),
            ("GITHUB_REPOSITORY", "different/repository", "restricted"),
            ("GITHUB_EVENT_NAME", "pull_request", "requires a main/tag push"),
            ("GITHUB_SHA", LATER, "differs from GITHUB_SHA"),
        ]
        for key, value, message in cases:
            with self.subTest(key=key, value=value), mock.patch.dict(os.environ, dict(environment, **{key: value}), clear=True), \
                 mock.patch.object(publication, "ROOT", self.directory), \
                 mock.patch.object(publication, "git", return_value=REVISION), \
                 mock.patch("sys.argv", ["publish_release.py", "--preflight"]), \
                 mock.patch("sys.stderr", new_callable=io.StringIO) as errors:
                self.assertEqual(publication.main(), 1)
                self.assertIn(message, errors.getvalue())
                self.assertEqual(self.remote.writes, [])

    def test_preflight_actions_output_is_read_only_and_supports_published_version_skip(self):
        (self.directory / "VERSION").write_text(VERSION + "\n", encoding="utf-8")
        output = self.directory / "step-output"
        environment = {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_TOKEN": TOKEN,
                       "GITHUB_ACTOR": "fixture-actor", "GITHUB_SHA": REVISION,
                       "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_OUTPUT": str(output)}
        with mock.patch.dict(os.environ, environment, clear=True), \
             mock.patch.object(publication, "ROOT", self.directory), \
             mock.patch.object(publication, "git", side_effect=lambda *args: REVISION if args[0] == "rev-parse" else CREATED), \
             mock.patch.object(publication, "HTTP", return_value=self.http), \
             mock.patch("sys.argv", ["publish_release.py", "--preflight"]):
            self.assertEqual(publication.main(), 0)
        self.assertEqual(output.read_text(encoding="utf-8"), "publish=true\n")
        self.assertEqual(self.remote.writes, [])
        self.assertEqual(self.remote.pushes, [])
        self.publish()
        writes = copy.deepcopy(self.remote.writes)
        with mock.patch.dict(os.environ, dict(environment, GITHUB_SHA=LATER), clear=True), \
             mock.patch.object(publication, "ROOT", self.directory), \
             mock.patch.object(publication, "git", side_effect=lambda *args: LATER if args[0] == "rev-parse" else CREATED), \
             mock.patch.object(publication, "is_ancestor", return_value=True), \
             mock.patch.object(publication, "HTTP", return_value=self.http), \
             mock.patch("sys.argv", ["publish_release.py", "--preflight"]):
            self.assertEqual(publication.main(), 0)
        self.assertEqual(output.read_text(encoding="utf-8"), "publish=true\npublish=false\n")
        self.assertEqual(self.remote.writes, writes)


if __name__ == "__main__":
    unittest.main()
