#!/usr/bin/env python3
"""Regression check for the bounded, deterministic spawn warning ring."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class SpawnWarningRingTests(unittest.TestCase):
    def test_warning_ring_downgrade_is_wired_bounded_and_deterministic(self) -> None:
        spawns = source("src/game/spawns.lua")
        control = source("control.lua")

        # Wired to the one event that bounds the work to a single chunk.
        self.assertIn(
            "script.on_event(defines.events.on_chunk_generated, Spawns.on_chunk_generated)",
            control,
        )

        handler = re.search(
            r"function Spawns\.on_chunk_generated\(event\).*?\nend\n",
            spawns,
            re.DOTALL,
        )
        self.assertIsNotNone(handler, "Spawns.on_chunk_generated must exist")
        body = handler.group(0)

        # Bounded to the generated chunk, never re-entrant into generation.
        self.assertIn("area = event.area", body)
        self.assertNotIn("request_to_generate_chunks", body)

        # Ring is keyed on the registered team spawn distance, not the origin.
        self.assertIn("Teams.find_nearest(surface, entity.position)", body)
        self.assertIn("nearest.distance < safe_zone", body)
        self.assertIn("nearest.distance < CONFIG.warning_zone", body)
        self.assertIn("soften_in_warning_ring(surface, entity)", body)

        # Big and behemoth worms become small ones, keeping the entity's force.
        for worm in ("big-worm-turret", "behemoth-worm-turret", "small-worm-turret"):
            self.assertIn(worm, spawns)
        self.assertIn("local force = entity.force", spawns)
        self.assertIn("force = force", spawns)

        # Multiplayer lockstep: chunk generation must never consult the RNG.
        self.assertNotIn("math.random", spawns)
        self.assertIn(
            "return (math.floor(position.x) + math.floor(position.y)) % 3 == 0",
            spawns,
        )


if __name__ == "__main__":
    unittest.main()
