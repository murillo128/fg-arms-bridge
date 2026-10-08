#!/usr/bin/env python3
"""Independently verify the JSON used to typeset the Arms Bridge booklet.

Uses exact rational arithmetic and exhaustive dice convolution, not a normal
approximation or a reimplementation of Fantasy Grounds. export_tables.lua
supplies every curve and supported damage value from ArmsEngine itself.
"""
from __future__ import annotations

import argparse
from collections import Counter
from fractions import Fraction
import hashlib
import json
from pathlib import Path


BOOK = Path(__file__).resolve().parents[1]


def distribution(dice: list[int]) -> Counter[int]:
    histogram = Counter({0: 1})
    for sides in dice:
        combined: Counter[int] = Counter()
        for subtotal, ways in histogram.items():
            for face in range(1, sides + 1):
                combined[subtotal + face] += ways
        histogram = combined
    return histogram


def percentile(histogram: Counter[int], quality: float) -> int:
    q = Fraction(str(quality))
    total = sum(histogram.values())
    cumulative = 0
    for value, ways in sorted(histogram.items()):
        cumulative += ways
        if Fraction(cumulative, total) >= q:
            return value
    raise AssertionError("a validated percentile must select a dice sum")


def verify_groups(rows: list[dict], groups: list[dict]) -> int:
    covered = []
    for group in groups:
        indices = range(group["start_index"], group["end_index"] + 1)
        for index in indices:
            assert rows[index]["totals"] == group["totals"]
            covered.append(index)
        assert group["r_max"] == rows[group["end_index"]]["r"]
        expected_min = None if group["start_index"] == 0 else rows[group["start_index"]]["r"]
        assert group["r_min"] == expected_min
    assert covered == list(range(len(rows)))
    return len(covered)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("json_file", nargs="?", type=Path, default=BOOK / "data/tables.json")
    args = parser.parse_args()
    raw = args.json_file.read_bytes()
    data = json.loads(raw)
    assert data["schema_version"] == 1 and data["engine_version"] == "0.3.1"
    assert data["family_order"] == ["blunted", "bladed", "axes", "polearms", "bows", "crossbows", "exotic", "firearms"]
    assert len(data["armor_order"]) == 7 and len(data["pool_order"]) == 7
    assert data["grid"]["maximum_r"] is None and not data["grid"]["last_printed_r_is_damage_cap"]
    histograms = {pool: distribution(metadata["dice"]) for pool, metadata in data["pools"].items() if pool != "fixed1"}
    lookups = supported = fixed = misses = groups_checked = 0
    for family_id in data["family_order"]:
        family = data["families"][family_id]
        assert family["id"] == family_id and family["offset"] == 0
        assert len(family["lookup_rows"]) == 36
        for armor in data["armor_order"]:
            column = family["columns"][armor]
            rows = column["source_rows"]
            assert rows[0]["hit"] is False and rows[0]["quality"] == 0
            assert rows[-1]["max"] is None and column["maximum_r"] is None and column["maximum_index"] is None
            assert Fraction(rows[-1]["min"], 5) == Fraction(str(column["tail_start_r"]))
            assert rows[-1]["min"] == column["tail_start_index"]
            for first, second in zip(rows, rows[1:]):
                assert first["max"] + 1 == second["min"]
        for row_index, lookup in enumerate(family["lookup_rows"]):
            assert lookup["r"] == row_index
            for a, armor in enumerate(data["armor_order"]):
                column = family["columns"][armor]
                result = lookup["cells"][a]
                index = 5 * row_index
                source = next(row for row in column["source_rows"] if row["min"] <= index and (row["max"] is None or index <= row["max"]))
                assert result["index"] == index and result["hit"] == source["hit"] and result["quality"] == source["quality"]
                excess = max(Fraction(0), Fraction(index - column["tail_start_index"], 5)) if source["hit"] else Fraction(0)
                assert Fraction(str(result["overflow_d20"])) == excess
                lookups += 1
                for pool in data["pool_order"]:
                    grid = family["grids"][pool]
                    row = grid["full_rows"][row_index]
                    cell = row["cells"][a]
                    assert row["r"] == row_index and grid["maximum_r"] is None
                    if not source["hit"]:
                        assert cell is None and row["totals"][a] is None
                        misses += 1
                    elif pool == "fixed1":
                        assert grid["native_only"] and grid["unsupported_table_conversion"]
                        assert cell["base"] == 1 and cell["supplement"] == 0 and cell["total"] == 1
                        assert cell["dice"] is None and cell["unsupported_table_conversion"] and cell["native_only"]
                        assert row["totals"][a] == 1
                        fixed += 1
                    else:
                        metadata = data["pools"][pool]
                        dice = metadata["dice"]
                        mean = sum((Fraction(sides + 1, 2) for sides in dice), Fraction(0))
                        assert mean == Fraction(str(metadata["mu"]))
                        expected_base = percentile(histograms[pool], result["quality"])
                        expected_extra = int(mean * excess // 10)
                        assert cell["base"] == expected_base, (family_id, armor, pool, row_index, cell, expected_base)
                        assert cell["supplement"] == expected_extra
                        assert cell["total"] == expected_base + expected_extra == row["totals"][a]
                        assert len(cell["dice"]) == len(dice) and sum(cell["dice"]) == expected_base
                        assert all(isinstance(face, int) and 1 <= face <= sides for face, sides in zip(cell["dice"], dice))
                        assert not cell["native_only"] and not cell["unsupported_table_conversion"]
                        supported += 1
        for grid in family["grids"].values():
            groups_checked += verify_groups(grid["full_rows"], grid["grouped_rows"])
        for name, variant in family["versatile"].items():
            first, second = variant["pool_ids"]
            assert name == first + "_" + second
            for index, row in enumerate(variant["full_rows"]):
                for a in range(7):
                    one = family["grids"][first]["full_rows"][index]["totals"][a]
                    two = family["grids"][second]["full_rows"][index]["totals"][a]
                    assert row["totals"][a] == (None if one is None else [one, two])
            groups_checked += verify_groups(variant["full_rows"], variant["grouped_rows"])
    assert lookups == data["validation"]["lookup_points"] == 2016
    assert supported == data["validation"]["engine_damage_calls"] == 7236
    assert fixed == data["validation"]["fixed_native_derivations"] == 1206
    assert groups_checked == data["validation"]["grouped_range_checks"] == 2592
    assert supported + fixed + misses == 8 * 7 * 36 * 7
    for example in data["examples"]:
        assert example["roll_total"] == sum(example["open_roll"])
        assert example["critical"] and example["open_roll"][0] == 20 and example["open_roll"][-1] < 20
        assert example["r"] == example["roll_total"] + example["attack_bonus"] - example["defense"]
        excess = max(Fraction(0), Fraction(str(example["r"])) - Fraction(str(example["r0"])))
        for pool, extra in example["supplements"].items():
            assert extra == Fraction(str(data["pools"][pool]["mu"])) * excess // 10
    print(f"PASS: {lookups} table lookups; {supported} exact-PMF damage cells; {fixed} native fixed cells; {misses} null misses.")
    print(f"PASS: {groups_checked} grouped ranges and both versatile pairings; source final intervals remain unbounded.")
    print(f"JSON SHA256: {hashlib.sha256(raw).hexdigest()}")
    engine = BOOK.parent / data["source_engine"]
    assert engine.is_file(), "the shipped engine source is missing"
    print(f"Engine source SHA256: {hashlib.sha256(engine.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
