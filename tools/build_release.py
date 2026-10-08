#!/usr/bin/env python3
"""Validate and build the versioned extension, illustrated PDF and source ZIP.

Usage: python3 tools/build_release.py [--output dist/release]
The full product suite runs once. Tracked tables must match a fresh engine export.
Existing output files are verified, never silently replaced with different bytes.
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

from build import collect_files, write_zip
from check_versions import check_versions, verify_inputs
import test as test_runner


PROJECT = Path(__file__).resolve().parents[1]


def artifact_names(version: str) -> tuple[str, str, str]:
    return (f"ArmsBridge-{version}.ext", f"El-nuevo-Arms-Law-{version}.pdf", f"fg-arms-bridge-{version}-source.zip")


def install_artifacts(artifacts: list[Path], output: Path) -> list[Path]:
    """Preflight every existing file before completing an identical partial build."""
    output.mkdir(parents=True, exist_ok=True)
    for source in artifacts:
        target = output / source.name
        if target.exists() and (not target.is_file() or target.read_bytes() != source.read_bytes()):
            raise ValueError(f"Existing release artifact differs; refusing to overwrite {target}")
    installed = []
    for source in artifacts:
        target = output / source.name
        if not target.exists():
            try:
                with target.open("xb") as handle, source.open("rb") as reader:
                    shutil.copyfileobj(reader, handle)
            except FileExistsError:
                if not target.is_file() or target.read_bytes() != source.read_bytes():
                    raise ValueError(f"Release artifact changed concurrently: {target}")
        installed.append(target)
    return installed


def build_release(project: Path, output: Path) -> list[Path]:
    project, output = project.resolve(), output.resolve()
    if output == project or project.is_relative_to(output) or output.is_relative_to(project / "extension"):
        raise ValueError("Release output must be separate from the project root and extension directory")
    versions = check_versions(project)
    inputs = verify_inputs(project)
    print(f"PASS synchronized version {versions['release']}; {inputs['artwork']} artwork and {inputs['fonts']} font hashes", flush=True)
    subprocess.run([sys.executable, str(project / "tools/test.py"), "--require-lua"], cwd=project, check=True)
    backend = test_runner.find_lua()
    if backend is None:
        raise ValueError("A Lua runtime is required to export the shipped tables")
    ext_name, pdf_name, source_name = artifact_names(versions["release"])
    with tempfile.TemporaryDirectory(prefix="armsbridge-release-") as directory:
        stage = Path(directory)
        exported = stage / "tables.json"
        old_output = os.environ.get("ARMSBRIDGE_TABLE_OUTPUT")
        os.environ["ARMSBRIDGE_TABLE_OUTPUT"] = str(exported)
        try:
            okay, report = test_runner.run_lua(backend, "test", project / "manual/tools/export_tables.lua", project, 60)
        finally:
            if old_output is None:
                os.environ.pop("ARMSBRIDGE_TABLE_OUTPUT", None)
            else:
                os.environ["ARMSBRIDGE_TABLE_OUTPUT"] = old_output
        if report:
            print(report, flush=True)
        if not okay:
            raise ValueError("The table exporter failed")
        if exported.read_bytes() != (project / "manual/data/tables.json").read_bytes():
            raise ValueError("manual/data/tables.json is stale; regenerate it with manual/tools/export_tables.lua and review the change")
        subprocess.run([sys.executable, str(project / "manual/tools/verify_tables.py"), str(exported)], cwd=project, check=True)
        pdf, audit = stage / pdf_name, stage / "layout-audit.json"
        subprocess.run([sys.executable, str(project / "manual/tools/build_book.py"), "--output", str(pdf), "--audit", str(audit)], cwd=project, check=True)
        subprocess.run([sys.executable, str(project / "manual/tools/verify_book.py"), "--pdf", str(pdf), "--audit", str(audit)], cwd=project, check=True)
        ext, source = stage / ext_name, stage / source_name
        write_zip(ext, collect_files(project / "extension"), project / "extension")
        write_zip(source, collect_files(project, output), project, f"fg-arms-bridge-{versions['release']}/")
        artifacts = [ext, pdf, source]
        checksums = stage / "SHA256SUMS"
        checksums.write_text("".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in sorted(artifacts)), encoding="utf-8", newline="\n")
        return install_artifacts([*artifacts, checksums], output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("dist/release"))
    args = parser.parse_args()
    try:
        artifacts = build_release(PROJECT, (PROJECT / args.output).resolve())
    except (OSError, ValueError, KeyError, ET.ParseError, subprocess.CalledProcessError) as exc:
        print(f"Release build failed: {exc}", file=sys.stderr)
        return 1
    for artifact in artifacts:
        print(f"Verified release artifact: {artifact} ({artifact.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
