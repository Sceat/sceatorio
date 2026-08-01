#!/usr/bin/env python3
"""Small query/render helper for the headless test matrix."""

from __future__ import annotations

import json
import pathlib
import sys


def load_matrix(path: str) -> dict:
    with pathlib.Path(path).open(encoding="utf-8") as handle:
        return json.load(handle)


def main() -> int:
    if len(sys.argv) < 3:
        raise SystemExit(
            "usage: matrix.py MATRIX "
            "(version|profiles|mod-list|cases|external-mods) [ARG ...]"
        )

    matrix = load_matrix(sys.argv[1])
    command = sys.argv[2]

    if command == "version":
        print(matrix["factorio"]["version"])
        return 0

    if command == "profiles":
        runner = sys.argv[3]
        profiles = {
            case["profile"]
            for case in matrix["cases"]
            if case["runner"] == runner and case["status"] == "implemented"
        }
        for profile in matrix["profiles"]:
            if profile in profiles:
                print(profile)
        return 0

    if command == "mod-list":
        profile = sys.argv[3]
        mod_name = sys.argv[4]
        external_mod_set = sys.argv[5] if len(sys.argv) > 5 else None
        enabled = set(matrix["profiles"][profile]["enabled_built_in_mods"])
        mods = [
            {"name": name, "enabled": name in enabled}
            for name in matrix["factorio"]["built_in_mods"]
        ]
        mods.append({"name": mod_name, "enabled": True})
        if external_mod_set:
            mods.extend(
                {"name": mod["name"], "enabled": True}
                for mod in matrix["external_mod_sets"][external_mod_set]["mods"]
            )
        json.dump(
            {"mods": mods},
            sys.stdout,
            indent=2,
        )
        print()
        return 0

    if command == "external-mods":
        external_mod_set = sys.argv[3]
        for mod in matrix["external_mod_sets"][external_mod_set]["mods"]:
            print("\t".join((mod["name"], mod["version"], mod["sha1"])))
        return 0

    if command == "cases":
        runner = sys.argv[3]
        profile = sys.argv[4]
        for case in matrix["cases"]:
            if (
                case["runner"] == runner
                and case["profile"] == profile
                and case["status"] == "implemented"
            ):
                print(case["id"])
        return 0

    raise SystemExit(f"unknown matrix command: {command}")


if __name__ == "__main__":
    raise SystemExit(main())
