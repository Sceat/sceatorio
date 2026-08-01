#!/usr/bin/env python3
"""Equivalence and work-bound checks for spawn terrain helpers."""

from __future__ import annotations

import math
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def integer_sequence(first: float, last: float) -> list[float]:
    return [first + offset for offset in range(math.floor(last - first) + 1)]


def selected_points(
    center: tuple[float, float],
    area: tuple[float, float, float, float],
    radius: int,
    modifier: int,
) -> set[tuple[float, float]]:
    left, top, right, bottom = area
    radius_squared = radius * radius
    return {
        (x, y)
        for x in integer_sequence(left, right)
        for y in integer_sequence(top, bottom)
        if radius_squared
        < math.floor((center[0] - x) ** 2 + (center[1] - y) ** 2)
        < radius_squared + modifier
    }


def clamped_area(
    center: tuple[float, float],
    area: tuple[float, float, float, float],
    radius: int,
    modifier: int,
) -> tuple[float, float, float, float]:
    left, top, right, bottom = area
    outer = math.ceil(math.sqrt(radius * radius + modifier))

    def axis(
        first: float, last: float, minimum: float, maximum: float
    ) -> tuple[float, float]:
        return (
            first + max(0, math.ceil(minimum - first)),
            first + min(last - first, math.floor(maximum - first)),
        )

    minimum_x, maximum_x = axis(left, right, center[0] - outer, center[0] + outer)
    minimum_y, maximum_y = axis(top, bottom, center[1] - outer, center[1] + outer)
    return minimum_x, minimum_y, maximum_x, maximum_y


class WaterBorderTests(unittest.TestCase):
    def test_clamp_preserves_every_legacy_selected_tile(self) -> None:
        cases = (
            ((0, 0), (-220, -220, 220, 220), 90, 3000),
            ((16, -32), (-40, -75, 80, 91), 20, 73),
            ((0.25, -0.5), (-130.75, -99.5, 130.25, 100.5), 37, 801),
        )
        for center, area, radius, modifier in cases:
            with self.subTest(center=center, radius=radius):
                self.assertEqual(
                    selected_points(center, area, radius, modifier),
                    selected_points(
                        center,
                        clamped_area(center, area, radius, modifier),
                        radius,
                        modifier,
                    ),
                )

    def test_primary_spawn_candidate_iterations_drop_by_more_than_fourfold(self) -> None:
        center = (0, 0)
        area = (-220, -220, 220, 220)
        bounded = clamped_area(center, area, 90, 3000)
        before = len(integer_sequence(area[0], area[2])) * len(
            integer_sequence(area[1], area[3])
        )
        after = len(integer_sequence(bounded[0], bounded[2])) * len(
            integer_sequence(bounded[1], bounded[3])
        )
        self.assertEqual(before, 194_481)
        self.assertEqual(after, 45_369)
        self.assertGreater(before / after, 4)

    def test_runtime_uses_bound_and_only_prepares_one_spawn_per_pass(self) -> None:
        compute = (ROOT / "src/utils/compute.lua").read_text(encoding="utf-8")
        spawns = (ROOT / "src/game/spawns.lua").read_text(encoding="utf-8")
        self.assertIn("outer_radius = math.ceil(math.sqrt(outer_squared))", compute)
        self.assertIn("local prepared_this_tick = false", spawns)
        self.assertIn("if not prepared_this_tick and not pending.terrain_ready", spawns)
        self.assertIn("prepared_this_tick = true", spawns)


if __name__ == "__main__":
    unittest.main()
