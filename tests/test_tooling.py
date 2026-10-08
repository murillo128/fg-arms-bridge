"""Packaging and validator checks independent of the Fantasy Grounds runtime."""
from pathlib import Path
import importlib.util
import os
import shutil
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]


def import_tool(name):
    spec = importlib.util.spec_from_file_location("armsbridge_" + name, ROOT / "tools" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


builder = import_tool("build")
validator = import_tool("test")


class ToolingTests(unittest.TestCase):
    def make_project(self, directory):
        project = Path(directory) / "example-project"
        (project / "extension" / "scripts").mkdir(parents=True)
        (project / "extension" / "extension.xml").write_text(
            '<root><properties><name>Example</name></properties><base>'
            '<script name="Example" file="scripts/example.lua"/>'
            '</base></root>', encoding="utf-8")
        (project / "extension" / "scripts" / "example.lua").write_text("return 42\n", encoding="utf-8")
        (project / "README.md").write_text("Instructions\n", encoding="utf-8")
        (project / "LICENSE").write_text("Example license fixture\n", encoding="utf-8")
        (project / "docs").mkdir()
        (project / "docs" / "DESIGN.md").write_text("Design notes\n", encoding="utf-8")
        (project / "examples").mkdir()
        (project / "examples" / "synthetic.csv").write_text("original,test,data\n", encoding="utf-8")
        (project / "tests").mkdir()
        (project / "tests" / "test_example.lua").write_text("assert(true)\n", encoding="utf-8")
        (project / "manual" / "data").mkdir(parents=True)
        (project / "manual" / "data" / "source.json").write_text("{\"example\": true}\n", encoding="utf-8")
        (project / ".env").write_text("SECRET=fixture-only\n", encoding="utf-8")
        (project / "manual" / ".env.local").write_text("SECRET=fixture-only\n", encoding="utf-8")
        (project / ".env.example").write_text("SETTING=example\n", encoding="utf-8")
        for generated in ("output", "tmp"):
            (project / "manual" / generated).mkdir()
            (project / "manual" / generated / "stale.bin").write_bytes(b"previous build")
        return project

    def test_zip_layout_source_completeness_and_reproducibility(self):
        with tempfile.TemporaryDirectory() as directory:
            project = self.make_project(directory)
            output = project / "dist"
            paths = builder.build_archives(project, output)
            before = [path.read_bytes() for path in paths]
            with zipfile.ZipFile(paths[0]) as archive:
                self.assertEqual(set(archive.namelist()), {"extension.xml", "scripts/example.lua"})
                self.assertIsNone(archive.testzip())
            with zipfile.ZipFile(paths[1]) as archive:
                self.assertIn("ArmsBridge/README.md", archive.namelist())
                self.assertIn("ArmsBridge/LICENSE", archive.namelist())
                self.assertIn("ArmsBridge/docs/DESIGN.md", archive.namelist())
                self.assertIn("ArmsBridge/examples/synthetic.csv", archive.namelist())
                self.assertIn("ArmsBridge/tests/test_example.lua", archive.namelist())
                self.assertIn("ArmsBridge/manual/data/source.json", archive.namelist())
                self.assertIn("ArmsBridge/.env.example", archive.namelist())
                self.assertNotIn("ArmsBridge/.env", archive.namelist())
                self.assertNotIn("ArmsBridge/manual/.env.local", archive.namelist())
                self.assertFalse(any("/dist/" in name for name in archive.namelist()))
                self.assertFalse(any("/manual/output/" in name or "/manual/tmp/" in name for name in archive.namelist()))
            for path in project.rglob("*"):
                if path.is_file():
                    os.utime(path, (1234567890, 1234567890))
            rebuilt = builder.build_archives(project, output)
            self.assertEqual(before, [path.read_bytes() for path in rebuilt])
            relocated = Path(directory) / "different-checkout-name"
            shutil.copytree(project, relocated)
            moved = builder.build_archives(relocated, relocated / "dist")
            self.assertEqual(before, [path.read_bytes() for path in moved])

    def test_xml_invalid_missing_and_traversing_references_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            project = self.make_project(directory)
            self.assertEqual(validator.validate_xml(project)[0], [])
            script = project / "extension" / "scripts" / "example.lua"
            script.unlink()
            self.assertTrue(any("missing" in error for error in validator.validate_xml(project)[0]))
            entry = project / "extension" / "extension.xml"
            entry.write_text('<root><properties><name>Example</name></properties><base><includefile source="../README.md"/></base></root>', encoding="utf-8")
            self.assertTrue(any("invalid local" in error for error in validator.validate_xml(project)[0]))
            entry.write_text("<root><broken></root>", encoding="utf-8")
            self.assertTrue(validator.validate_xml(project)[0])

    def test_unsafe_output_and_symlinks_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            project = self.make_project(directory)
            with self.assertRaises(ValueError):
                builder.build_archives(project, project / "extension" / "generated")
            with self.assertRaises(ValueError):
                builder.build_archives(project, project / "dist", "../escape")
            try:
                (project / "extension" / "leak.txt").symlink_to(project / "README.md")
            except (OSError, NotImplementedError):
                return
            with self.assertRaises(ValueError):
                builder.build_archives(project, project / "dist")

    def test_lua_compile_does_not_execute_and_errors_are_reported(self):
        backend = validator.find_lua()
        if not backend:
            self.skipTest("No local Lua runtime")
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            code = project / "sample.lua"
            code.write_text("error('runtime-only-error')\n", encoding="utf-8")
            self.assertTrue(validator.run_lua(backend, "syntax", code, project, 5)[0])
            okay, output = validator.run_lua(backend, "test", code, project, 5)
            self.assertFalse(okay)
            self.assertIn("runtime-only-error", output)
            code.write_text("this is not valid Lua !", encoding="utf-8")
            self.assertFalse(validator.run_lua(backend, "syntax", code, project, 5)[0])

    def test_each_lua_test_has_an_isolated_state(self):
        backend = validator.find_lua()
        if not backend:
            self.skipTest("No local Lua runtime")
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            first = project / "first.lua"
            second = project / "second.lua"
            first.write_text("ARMSBRIDGE_TEST_SENTINEL = true\n", encoding="utf-8")
            second.write_text("assert(ARMSBRIDGE_TEST_SENTINEL == nil)\n", encoding="utf-8")
            self.assertTrue(validator.run_lua(backend, "test", first, project, 5)[0])
            self.assertTrue(validator.run_lua(backend, "test", second, project, 5)[0])


if __name__ == "__main__":
    unittest.main()
