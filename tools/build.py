#!/usr/bin/env python3
"""Create deterministic Fantasy Grounds .ext and complete source archives.

Usage: python3 tools/build.py [--output dist] [--name ArmsBridge]
Runs tools/test.py --require-lua before packaging. --skip-tests is available for
development, but still validates XML and references. Archives contain no local
paths, timestamps, symlinks, previous builds, or Python bytecode.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile


PROJECT = Path(__file__).resolve().parents[1]
EXCLUDED_PARTS = {".git", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", "dist", "build", "node_modules", ".venv", "venv"}
EXCLUDED_PREFIXES = {("manual", "output"), ("manual", "tmp")}
ZIP_DATE = (2020, 1, 1, 0, 0, 0)


def collect_files(base: Path, output: Path | None = None) -> list[Path]:
    files = []
    for path in sorted(base.rglob("*")):
        relative = path.relative_to(base)
        if any(part in EXCLUDED_PARTS for part in relative.parts):
            continue
        if relative.parts[:2] in EXCLUDED_PREFIXES:
            continue
        if path.name != ".env.example" and (path.name == ".env" or path.name.startswith(".env.")):
            continue
        if output is not None and path.resolve().is_relative_to(output.resolve()):
            continue
        if path.is_symlink():
            raise ValueError(f"Refusing to package a symlink: {relative}")
        if path.is_file() and path.suffix not in {".pyc", ".pyo"}:
            files.append(path)
    return files


def write_zip(destination: Path, files: list[Path], base: Path, prefix: str = "") -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".archive-", suffix=".tmp", dir=destination.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
    try:
        with zipfile.ZipFile(temporary_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for path in files:
                name = prefix + path.relative_to(base).as_posix()
                info = zipfile.ZipInfo(name, ZIP_DATE)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                archive.writestr(info, path.read_bytes(), compresslevel=9)
        temporary_path.replace(destination)
    finally:
        temporary_path.unlink(missing_ok=True)


def build_archives(project: Path, output: Path, name: str = "ArmsBridge") -> list[Path]:
    project, output = project.resolve(), output.resolve()
    if not name or not name[0].isalnum() or any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-" for character in name):
        raise ValueError("Archive name must begin with a letter or digit and use only letters, digits, dots, underscores, or hyphens")
    extension = project / "extension"
    if not (extension / "extension.xml").is_file():
        raise ValueError("Missing extension/extension.xml")
    if output == project or project.is_relative_to(output) or output.is_relative_to(extension):
        raise ValueError("Output must be separate from the project root and extension directory")
    extension_files = collect_files(extension)
    source_files = collect_files(project, output)
    ext_path = output / f"{name}.ext"
    source_path = output / f"{name}-source.zip"
    write_zip(ext_path, extension_files, extension)
    write_zip(source_path, source_files, project, name + "/")
    hashes = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in (ext_path, source_path))
    checksum_path = output / "SHA256SUMS.txt"
    checksum_path.write_text(hashes, encoding="utf-8", newline="\n")
    return [ext_path, source_path, checksum_path]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=PROJECT)
    parser.add_argument("--output", type=Path, default=Path("dist"))
    parser.add_argument("--name", default="ArmsBridge")
    parser.add_argument("--skip-tests", action="store_true")
    args = parser.parse_args()
    project = args.project.resolve()
    output = (project / args.output).resolve()
    checks = [sys.executable, str(PROJECT / "tools" / "test.py"), "--project", str(project)]
    checks.append("--xml-only" if args.skip_tests else "--require-lua")
    if args.skip_tests:
        print("Development build: Lua and unit tests skipped; validating XML and references.", flush=True)
    check = subprocess.run(checks, cwd=project)
    if check.returncode:
        return check.returncode
    try:
        artifacts = build_archives(project, output, args.name)
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print(f"Build failed: {exc}", file=sys.stderr)
        return 1
    for artifact in artifacts:
        print(f"Created {artifact} ({artifact.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
