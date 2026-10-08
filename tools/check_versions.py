#!/usr/bin/env python3
"""Check release/base/editorial versions and the pinned manual inputs."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET


PROJECT = Path(__file__).resolve().parents[1]


def check_versions(project: Path) -> dict[str, str]:
    release = (project / "VERSION").read_text(encoding="utf-8").strip()
    match = re.fullmatch(r"(\d+\.\d+\.\d+)-alpha", release)
    if not match:
        raise ValueError("VERSION must be a base version followed by -alpha")
    base = match.group(1)
    versions = {"release": release, "base": base, "editorial": base + " alpha", "data": release + ".1"}
    actual = {"extension manifest": ET.parse(project / "extension/extension.xml").findtext("properties/version")}
    expected = {"extension manifest": base}
    for name, wanted in (("arms_engine", base), ("arms_catalog", base), ("arms_data", versions["data"])):
        text = (project / "extension/scripts" / (name + ".lua")).read_text(encoding="utf-8")
        found = re.search(r'^local VERSION = "([^"\n]+)"$', text, re.MULTILINE)
        actual[name] = found.group(1) if found else None
        expected[name] = wanted
    for filename, key, wanted in (("tables.json", "engine_version", base),
                                  ("weapons.json", "document_version", base),
                                  ("manual_text.json", "version", versions["editorial"])):
        data = json.loads((project / "manual/data" / filename).read_text(encoding="utf-8"))
        actual[filename] = data.get(key)
        expected[filename] = wanted
        if filename == "tables.json":
            if data.get("schema_version") != 1:
                raise ValueError("tables.json schema_version must remain 1")
            if data.get("source_engine") != "extension/scripts/arms_engine.lua":
                raise ValueError("tables.json must identify the shipped extension engine")
    mismatches = [f"{name}: {actual[name]!r}, expected {wanted!r}" for name, wanted in expected.items() if actual[name] != wanted]
    if mismatches:
        raise ValueError("Version mismatch: " + "; ".join(mismatches))
    return versions


def verify_inputs(project: Path) -> dict[str, int]:
    manual = project / "manual"
    manifest = json.loads((manual / "data/image_manifest.json").read_text(encoding="utf-8"))
    artwork = [manifest["cover"], manifest["logo"], manifest["party"], *manifest["plates"].values()]
    if len(artwork) != 11:
        raise ValueError("The manual must retain the cover, logo, party reference and eight plates")
    for entry in artwork:
        path = manual / entry["file"]
        if not path.resolve().is_relative_to(manual.resolve()):
            raise ValueError("Artwork path leaves manual/: " + entry["file"])
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError("Artwork hash mismatch: " + entry["file"])
    font_root = manual / "fonts"
    font_manifest = json.loads((font_root / "manifest.json").read_text(encoding="utf-8"))
    fonts = font_manifest["fonts"]
    wanted = {f"LiberationSerif-{style}.ttf" for style in ("Regular", "Bold", "Italic", "BoldItalic")}
    wanted.update({"URWBookman-Demi.afm", "URWBookman-Demi.pfb"})
    if len(fonts) != 6 or {entry["file"] for entry in fonts} != wanted:
        raise ValueError("The six exact fonts required by the composition must be declared")
    for entry in [*fonts, *font_manifest.get("source_files", [])]:
        if hashlib.sha256((font_root / entry["file"]).read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError("Font hash mismatch: " + entry["file"])
        if not (font_root / entry["notice"]).is_file():
            raise ValueError("Missing font license: " + entry["notice"])
    return {"artwork": len(artwork), "fonts": len(fonts)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=PROJECT)
    args = parser.parse_args()
    try:
        versions = check_versions(args.project.resolve())
        inputs = verify_inputs(args.project.resolve())
    except (OSError, ValueError, KeyError, ET.ParseError) as exc:
        parser.exit(1, f"Version/input check failed: {exc}\n")
    print(f"PASS versions: {versions['release']} / base {versions['base']} / editorial {versions['editorial']}")
    print(f"PASS inputs: {inputs['artwork']} original PNGs and {inputs['fonts']} bundled font files match their hashes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
