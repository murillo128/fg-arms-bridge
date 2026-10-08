#!/usr/bin/env python3
"""Verify all forty printed weapon tables against the engine export and PDF text."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re

from pypdf import PdfReader


MANUAL = Path(__file__).resolve().parents[1]


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def verify(pdf: Path, audit_path: Path) -> dict[str, int]:
    tables = read_json(MANUAL / "data/tables.json")
    weapons = read_json(MANUAL / "data/weapons.json")["weapons"]
    audit = read_json(audit_path)
    reader = PdfReader(pdf)
    assert len(reader.pages) == len(audit["pages"]) == 52
    assert len(weapons) == len({w["id"] for w in weapons}) == 40
    assert audit["version"] == tables["engine_version"]
    assert audit["pdf_sha256"] == hashlib.sha256(pdf.read_bytes()).hexdigest()
    assert not audit["errors"] and audit["validation"]["errors"] == 0
    assert audit["validation"]["live_fantasy_grounds_test"] == "pending"
    for name, digest in audit["source_hashes"].items():
        assert hashlib.sha256((MANUAL / "data" / name).read_bytes()).hexdigest() == digest, name
    fonts = read_json(MANUAL / "fonts/manifest.json")["fonts"]
    assert audit["font_hashes"] == {font["file"]: font["sha256"] for font in fonts}
    for name, digest in audit["font_hashes"].items():
        assert hashlib.sha256((MANUAL / "fonts" / name).read_bytes()).hexdigest() == digest, name
    pages = {page["id"]: page for page in audit["pages"]}
    assert len(pages) == 52
    assert {name for name in pages if name.startswith("weapon_")} == {"weapon_" + w["id"] for w in weapons}
    counts = {"pages": 52, "weapon_tables": 0, "printed_rows": 0, "armor_cells": 0,
              "r0_values": 0, "score_positions": 0, "versatile_tables": 0, "native_fixed_tables": 0}
    for weapon in weapons:
        page_id = "weapon_" + weapon["id"]
        page = pages[page_id]
        assert page["page"] == audit["page_map"][page_id]
        matches = [table for table in page["tables"] if table["id"] == "damage_" + weapon["id"]]
        assert len(matches) == 1
        printed = matches[0]
        family = tables["families"][weapon["group"]]
        pools = []
        if weapon.get("fixed_damage") is not None:
            assert weapon["fixed_damage"] == 1
            pools = ["fixed1"]
            counts["native_fixed_tables"] += 1
        else:
            for key in ("dice_1h", "dice_2h"):
                dice = weapon.get(key)
                if dice:
                    pool = dice[1:] if dice.startswith("1d") else dice
                    if pool not in pools:
                        pools.append(pool)
        assert printed["family"] == weapon["group"] and printed["pools"] == pools
        assert printed["ordinary_only"] is True and printed["modifier_excluded"] is True
        if len(pools) == 2:
            grid = family["versatile"]["_".join(pools)]
            counts["versatile_tables"] += 1
        else:
            assert len(pools) == 1
            grid = family["grids"][pools[0]]
        expected_rows = grid["grouped_rows"]
        assert len(printed["rows"]) == len(expected_rows)
        coverage, table_text = [], []
        for actual, expected in zip(printed["rows"], expected_rows):
            assert (actual["label"], actual["r_min"], actual["r_max"]) == (expected["label"], expected["r_min"], expected["r_max"])
            cells = ["—" if value is None else " / ".join(map(str, value)) if isinstance(value, list) else str(value) for value in expected["totals"]]
            assert actual["cells"] == cells and len(cells) == 7, weapon["id"]
            table_text.extend([expected["label"], *cells])
            coverage.extend(range(0 if expected["r_min"] is None else expected["r_min"], expected["r_max"] + 1))
        assert coverage == list(range(36)), weapon["id"]
        r0 = [family["columns"][armor]["tail_start_r"] for armor in tables["armor_order"]]
        assert printed["r0"] == r0
        text = re.sub(r"\s+", " ", reader.pages[page["page"] - 1].extract_text() or "")
        assert "M FUERA DE LA CELDA" in text, weapon["id"]
        # The audit is checked against JSON above; this independently checks the
        # actual PDF text stream, including every cell and the continuation row.
        expected_text = re.sub(r"\s+", " ", " ".join([*table_text, "R₀", *map(str, r0)]))
        assert expected_text in text, "PDF table text differs: " + weapon["id"]
        if pools == ["fixed1"]:
            assert "DAÑO NATIVO" in text and "SIN CRECIMIENTO" in text
        else:
            assert "R > 35" in text and "dados nativos + M + Δ" in text, weapon["id"]
        counts["weapon_tables"] += 1
        counts["printed_rows"] += len(expected_rows)
        counts["armor_cells"] += 7 * len(expected_rows)
        counts["r0_values"] += 7
        counts["score_positions"] += len(coverage)
    assert counts["weapon_tables"] == 40 and counts["r0_values"] == 280
    assert counts["score_positions"] == 1440 and counts["native_fixed_tables"] == 1
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pdf", type=Path, default=MANUAL / "output/pdf/El-nuevo-Arms-Law.pdf")
    parser.add_argument("--audit", type=Path, default=MANUAL / "tmp/pdfs/layout-audit.json")
    args = parser.parse_args()
    counts = verify(args.pdf, args.audit)
    print("PASS manual: " + "; ".join(f"{value} {name}" for name, value in counts.items()))
    print("All printed rows, armor cells and R0 values agree with the export and PDF text; the tail remains unbounded.")


if __name__ == "__main__":
    main()
