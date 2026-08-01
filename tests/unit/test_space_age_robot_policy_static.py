#!/usr/bin/env python3
"""Contracts for Space Age spawns and bounded robot-cap enforcement."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class PlanetSpawnTests(unittest.TestCase):
    def test_freeplay_starter_flow_is_guarded_and_disabled(self) -> None:
        spawns = source("src/game/spawns.lua")
        control = source("control.lua")
        self.assertIn("remote.interfaces.freeplay", spawns)
        for function in (
            "set_skip_intro",
            "set_disable_crashsite",
            "set_created_items",
            "set_respawn_items",
        ):
            self.assertIn(function, spawns)
        self.assertIn("Spawns.configure_freeplay", control)

    def test_secondary_spawns_only_target_real_planet_surfaces(self) -> None:
        planets = source("src/game/planetSpawns.lua")
        self.assertIn("surface.planet", planets)
        self.assertIn("surface.platform", planets)
        self.assertIn("player.character.surface", planets)
        self.assertNotIn("game.surfaces.nauvis", planets)

    def test_generation_is_async_and_never_rewrites_planet_resources(self) -> None:
        planets = source("src/game/planetSpawns.lua")
        self.assertIn("request_to_generate_chunks", planets)
        self.assertIn("is_chunk_generated", planets)
        self.assertIn("find_non_colliding_position", planets)
        self.assertNotIn("force_generate_chunk_requests", planets)
        self.assertNotIn("set_tiles", planets)
        self.assertNotIn("destroy_decoratives", planets)
        self.assertNotRegex(planets, r'type\s*=\s*["\']resource["\']')

    def test_spawn_identity_is_team_and_surface_not_player(self) -> None:
        planets = source("src/game/planetSpawns.lua")
        teams = source("src/game/teams.lua")
        self.assertIn("Teams.ensure_surface", planets)
        self.assertIn("planet_spawn", planets)
        self.assertIn("for_each", teams)
        self.assertNotRegex(planets, r"spawn(?:s)?\s*\[\s*player\.index\s*\]")

    def test_arrival_respawn_join_and_cargo_paths_are_wired(self) -> None:
        control = source("control.lua")
        spawns = source("src/game/spawns.lua")
        for event in (
            "on_player_changed_surface",
            "on_player_respawned",
            "on_cargo_pod_started_ascending",
            "on_cargo_pod_finished_descending",
        ):
            self.assertIn(event, control)
        self.assertIn("PlanetSpawns", spawns)
        self.assertIn("physical_surface", spawns)

    def test_settings_are_configurable_and_localized(self) -> None:
        settings = source("settings.lua")
        locale = source("locale/en/sceatorio.cfg")
        for name in (
            "sceatorio-planet-spawns-enabled",
            "sceatorio-planet-spawn-safety-radius",
            "sceatorio-planet-spawn-separation",
        ):
            self.assertIn(name, settings)
            self.assertIn(name, locale)


class RobotPolicyTests(unittest.TestCase):
    def test_network_aggregate_counts_replace_robot_entity_scans(self) -> None:
        policy = source("src/game/robotPolicy.lua")
        self.assertIn("all_logistic_robots", policy)
        self.assertIn("all_construction_robots", policy)
        self.assertIn("available_logistic_robots", policy)
        self.assertIn("available_construction_robots", policy)
        self.assertIn("network.cells", policy)
        self.assertNotIn("find_entities_filtered", policy)
        self.assertNotRegex(policy, r"\.logistic_robots\b")
        self.assertNotRegex(policy, r"\.construction_robots\b")

    def test_enforcement_quarantines_only_idle_inventory_without_loss(self) -> None:
        policy = source("src/game/robotPolicy.lua")
        self.assertIn("defines.inventory.roboport_robot", policy)
        self.assertIn("game.create_inventory", policy)
        self.assertIn("inserted", policy)
        self.assertIn("stack.quality", policy)
        self.assertIn("stack.count = stack.count - inserted", policy)
        self.assertNotIn("stack.clear()", policy)
        self.assertNotRegex(policy, r"\.destroy\s*\(")

    def test_modes_limits_diagnostics_and_recovery_are_exposed(self) -> None:
        settings = source("settings.lua")
        locale = source("locale/en/sceatorio.cfg")
        policy = source("src/game/robotPolicy.lua")
        for name in (
            "sceatorio-robot-policy-mode",
            "sceatorio-logistic-robot-cap",
            "sceatorio-construction-robot-cap",
        ):
            self.assertIn(name, settings)
            self.assertIn(name, locale)
        for command in ("sceatorio-robot-status", "sceatorio-robot-recover"):
            self.assertIn(command, policy)
        for mode in ('"disabled"', '"warn"', '"enforce"'):
            self.assertIn(mode, policy)

    def test_build_remove_tick_gui_and_lifecycle_paths_are_wired(self) -> None:
        control = source("control.lua")
        for event in (
            "on_built_entity",
            "on_robot_built_entity",
            "on_player_mined_entity",
            "on_robot_mined_entity",
            "script_raised_destroy",
            "on_gui_click",
        ):
            self.assertIn(event, control)
        self.assertIn("RobotPolicy.tick", control)
        self.assertIn("RobotPolicy.on_gui_click", control)


if __name__ == "__main__":
    unittest.main()
