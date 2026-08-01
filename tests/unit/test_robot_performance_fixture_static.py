#!/usr/bin/env python3
"""Contracts for the exact-engine robot policy stress fixture."""

from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class RobotPerformanceFixtureTests(unittest.TestCase):
    def test_network_sampling_has_a_small_per_tick_budget(self) -> None:
        policy = (ROOT / "src/game/robotPolicy.lua").read_text(encoding="utf-8")

        self.assertIn("PORT_SCAN_BUDGET = 2", policy)
        once_per_tick = policy.split("function RobotPolicy.on_tick()", 1)[1]
        once_per_tick = once_per_tick.split("\nend", 1)[0]
        self.assertIn("scan_registered_ports()", once_per_tick)
        once_per_second = policy.split("function RobotPolicy.tick(event)", 1)[1]
        once_per_second = once_per_second.split("\nend", 1)[0]
        self.assertNotIn("scan_registered_ports()", once_per_second)

    def test_reevaluation_budget_includes_empty_force_queue_work(self) -> None:
        policy = (ROOT / "src/game/robotPolicy.lua").read_text(encoding="utf-8")
        processor = policy.split("local function process_force_reevaluations()", 1)[1]
        processor = processor.split("\nend", 1)[0]

        budget_increment = processor.index("processed = processed + 1")
        empty_force_branch = processor.index("if cursor > #order then")
        self.assertLess(budget_increment, empty_force_branch)

    def test_fixture_exercises_real_default_caps_and_wide_registries(self) -> None:
        fixture = (
            ROOT / "tests/fixtures/robot-policy-performance/control.lua"
        ).read_text(encoding="utf-8")

        for token in (
            "LOGISTIC_CAP = 500",
            "CONSTRUCTION_CAP = 5000",
            "PORT_COUNT = 64",
            "CANDIDATE_MACHINE_COUNT = 1024",
            "LOGISTIC_MACHINE_COUNT = 256",
            "CONSTRUCTION_MACHINE_COUNT = 256",
            "helpers.create_profiler",
            "SCEATORIO_ROBOT_PERFORMANCE_MEASURE",
            "SCEATORIO_ROBOT_PERFORMANCE_PASS",
        ):
            self.assertIn(token, fixture)

        self.assertIn('set_recipe("logistic-robot")', fixture)
        self.assertIn('set_recipe("construction-robot")', fixture)
        self.assertIn('set_recipe("iron-gear-wheel")', fixture)
        self.assertIn("disabled_by_script", fixture)
        self.assertNotIn("find_entities_filtered", fixture)

    def test_matrix_marks_the_exact_fixture_implemented(self) -> None:
        matrix = json.loads(
            (ROOT / "tests/headless/matrix.json").read_text(encoding="utf-8")
        )
        case = next(
            entry
            for entry in matrix["cases"]
            if entry["id"] == "robot.cap-overhead"
        )

        self.assertEqual(case["profile"], "base")
        self.assertEqual(case["runner"], "mod-fixture")
        self.assertEqual(case["status"], "implemented")
        self.assertEqual(case["fixture"], "robot-policy-performance")
        self.assertEqual(case["pass_marker"], "SCEATORIO_ROBOT_PERFORMANCE_PASS")

    def test_fixture_benchmark_length_is_reproducibly_configurable(self) -> None:
        runner = (ROOT / "tests/headless/run.sh").read_text(encoding="utf-8")

        self.assertIn('"${FACTORIO_FIXTURE_BENCHMARK_TICKS:-900}"', runner)
        self.assertIn('"${FACTORIO_FIXTURE_BENCHMARK_RUNS:-1}"', runner)


if __name__ == "__main__":
    unittest.main()
