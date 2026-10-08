"""Version consistency and local artifact immutability at their owning boundary."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from build_release import artifact_names, install_artifacts
from check_versions import check_versions


class ReleaseBuildTests(unittest.TestCase):
    def version_fixture(self, directory):
        project = Path(directory)
        (project / "extension/scripts").mkdir(parents=True)
        (project / "manual/data").mkdir(parents=True)
        (project / "VERSION").write_text("0.3.1-alpha\n")
        (project / "extension/extension.xml").write_text("<root><properties><version>0.3.1</version></properties></root>")
        for name, version in (("arms_engine", "0.3.1"), ("arms_catalog", "0.3.1"), ("arms_data", "0.3.1-alpha.1")):
            (project / "extension/scripts" / (name + ".lua")).write_text(f'local VERSION = "{version}"\n')
        for name, value in (("tables.json", {"schema_version": 1, "engine_version": "0.3.1", "source_engine": "extension/scripts/arms_engine.lua"}),
                            ("weapons.json", {"document_version": "0.3.1"}),
                            ("manual_text.json", {"version": "0.3.1 alpha"})):
            (project / "manual/data" / name).write_text(json.dumps(value))
        return project

    def test_release_names_and_distinct_version_representations(self):
        with tempfile.TemporaryDirectory() as directory:
            versions = check_versions(self.version_fixture(directory))
            self.assertEqual(versions, {"release": "0.3.1-alpha", "base": "0.3.1", "editorial": "0.3.1 alpha", "data": "0.3.1-alpha.1"})
            self.assertEqual(artifact_names(versions["release"]), ("ArmsBridge-0.3.1-alpha.ext", "El-nuevo-Arms-Law-0.3.1-alpha.pdf", "fg-arms-bridge-0.3.1-alpha-source.zip"))

    def test_mismatched_editorial_prefix_and_engine_are_rejected(self):
        cases = (("manual/data/manual_text.json", '{"version": "0.3.10 alpha"}', "manual_text.json"),
                 ("extension/scripts/arms_engine.lua", 'local VERSION = "0.3.2"\n', "arms_engine"),
                 ("VERSION", "../0.3.1-alpha\n", "VERSION"))
        for path, contents, message in cases:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                project = self.version_fixture(directory)
                (project / path).write_text(contents)
                with self.assertRaisesRegex(ValueError, message):
                    check_versions(project)

    def test_identical_partial_output_is_completed_without_overwriting(self):
        with tempfile.TemporaryDirectory() as directory:
            stage, output = Path(directory) / "stage", Path(directory) / "release"
            stage.mkdir(); output.mkdir()
            artifacts = [stage / "a.ext", stage / "b.pdf"]
            artifacts[0].write_bytes(b"extension"); artifacts[1].write_bytes(b"manual")
            existing = output / "a.ext"
            existing.write_bytes(b"extension")
            os.utime(existing, (1234567890, 1234567890))
            installed = install_artifacts(artifacts, output)
            self.assertEqual([path.read_bytes() for path in installed], [b"extension", b"manual"])
            self.assertEqual(existing.stat().st_mtime, 1234567890)
            install_artifacts(artifacts, output)
            self.assertEqual(existing.stat().st_mtime, 1234567890)

    def test_conflict_is_detected_before_any_missing_artifact_is_written(self):
        with tempfile.TemporaryDirectory() as directory:
            stage, output = Path(directory) / "stage", Path(directory) / "release"
            stage.mkdir(); output.mkdir()
            first, second = stage / "a.ext", stage / "b.pdf"
            first.write_bytes(b"new extension"); second.write_bytes(b"new manual")
            (output / "b.pdf").write_bytes(b"published manual")
            with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
                install_artifacts([first, second], output)
            self.assertFalse((output / "a.ext").exists())
            self.assertEqual((output / "b.pdf").read_bytes(), b"published manual")


if __name__ == "__main__":
    unittest.main()
