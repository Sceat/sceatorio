#!/usr/bin/env python3
"""Contracts for the exact-engine offline-protection stress fixture."""

from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class OfflinePerformanceFixtureTests(unittest.TestCase):
    def test_transition_walks_force_bucket_without_an_o_n_snapshot(self) -> None:
        security = source("src/game/offlineSecurity.lua")
        transition = security[
            security.index("local function apply_record") : security.index(
                "local function refresh_record"
            )
        ]

        self.assertIn("local registration_number = next(bucket)", transition)
        self.assertIn(
            "local next_registration = next(bucket, registration_number)", transition
        )
        self.assertNotIn("local registrations = {}", transition)
        self.assertNotIn("table.insert", transition)

    def test_fixture_profiles_only_the_transition_and_checks_every_entity(self) -> None:
        fixture = source(
            "tests/fixtures/offline-security-performance/control.lua"
        )
        for token in (
            "ENTITY_COUNT = 10000",
            "ORIGINAL_FALSE_STRIDE = 10",
            "helpers.create_profiler",
            '"set_offline_protection"',
            "SCEATORIO_OFFLINE_PERFORMANCE_MEASURE",
            "SCEATORIO_OFFLINE_PERFORMANCE_CHECKPOINT",
            "SCEATORIO_OFFLINE_PERFORMANCE_PASS",
            "loaded_from_save",
        ):
            self.assertIn(token, fixture)

        call = fixture.split('"set_offline_protection"', 1)[1]
        call = call.split(")", 1)[0]
        self.assertIn("false", call)
        self.assertIn("for index = 1, ENTITY_COUNT do", fixture)
        self.assertIn("entity.destructible ~= expected", fixture)
        self.assertIn("if entity.destructible then", fixture)
        self.assertNotIn("find_entities_filtered", fixture)

    def test_quiet_dev_transition_preserves_the_default_status_contract(self) -> None:
        menu = source("src/game/testMenu.lua")
        transition = menu.split("set_offline_protection = function", 1)[1]
        transition = transition.split("offline_status = function", 1)[0]

        self.assertIn("include_status", transition)
        self.assertIn("include_status ~= false", transition)
        self.assertIn("OfflineSecurity.status(force)", transition)

    def test_matrix_marks_the_exact_fixture_implemented(self) -> None:
        matrix = json.loads(source("tests/headless/matrix.json"))
        case = next(
            entry
            for entry in matrix["cases"]
            if entry["id"] == "security.offline-transition-overhead"
        )

        self.assertEqual(case["profile"], "base")
        self.assertEqual(case["runner"], "mod-fixture")
        self.assertEqual(case["status"], "implemented")
        self.assertEqual(case["fixture"], "offline-security-performance")
        self.assertEqual(
            case["pass_marker"], "SCEATORIO_OFFLINE_PERFORMANCE_PASS"
        )


if __name__ == "__main__":
    unittest.main()
