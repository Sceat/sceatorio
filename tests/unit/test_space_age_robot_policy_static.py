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
        surfaces = source("src/game/surfacePolicy.lua")
        self.assertIn("surface.planet", surfaces)
        self.assertIn("surface.platform", surfaces)
        self.assertIn("SurfacePolicy.is_real_planet(surface)", planets)
        self.assertIn("player.character.surface", planets)
        core_arrival = planets.split(
            "-- Explicit administrator diagnostic path.", 1
        )[0]
        self.assertNotIn("game.surfaces.nauvis", core_arrival)

    def test_generation_is_async_and_never_rewrites_planet_resources(self) -> None:
        planets = source("src/game/planetSpawns.lua")
        self.assertIn("request_to_generate_chunks", planets)
        self.assertIn("is_chunk_generated", planets)
        self.assertIn("find_non_colliding_position", planets)
        self.assertNotIn("force_generate_chunk_requests", planets)
        self.assertNotIn("set_tiles", planets)
        self.assertNotIn("destroy_decoratives", planets)
        self.assertNotRegex(planets, r'type\s*=\s*["\']resource["\']')

    def test_existing_generated_hostiles_are_reconciled_in_a_bounded_area(self) -> None:
        planets = source("src/game/planetSpawns.lua")
        self.assertIn("hostile_generation_area", planets)
        self.assertIn("generation_chunk_radius", planets)
        self.assertIn("reassign_existing_default_hostiles", planets)
        self.assertIn("force = game.forces.enemy", planets)
        self.assertIn("entity.force = nearest.enemy_force", planets)
        self.assertIn("own_enemy", planets)

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

    def test_cargo_hold_is_claimed_only_after_write_readback(self) -> None:
        planets = source("src/game/planetSpawns.lua")
        hold = planets.split("local function set_cargo_hold", 1)[1]
        hold = hold.split("local function route_cargo_pods", 1)[0]
        self.assertIn("cargo_pod.disabled_by_script = held", hold)
        self.assertIn("cargo_pod.disabled_by_script == held", hold)
        self.assertIn("return ok and confirmed", hold)
        self.assertIn("planet-spawn-cargo-native-fallback", planets)

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
        self.assertNotIn("find_entities_filtered", policy)
        self.assertNotRegex(policy, r"\.logistic_robots\b")
        self.assertNotRegex(policy, r"\.construction_robots\b")

    def test_enforcement_pauses_only_robot_recipe_machines_and_restores_state(self) -> None:
        policy = source("src/game/robotPolicy.lua")
        self.assertIn("get_recipe", policy)
        self.assertIn("recipe.products", policy)
        self.assertIn("item.place_result", policy)
        self.assertIn('placed.type == "logistic-robot"', policy)
        self.assertIn('placed.type == "construction-robot"', policy)
        self.assertIn("machine.disabled_by_script", policy)
        self.assertIn("prior_disabled_by_script", policy)
        self.assertIn("MACHINE_SCAN_BUDGET", policy)
        self.assertIn("prototypes.recipe", policy)
        self.assertIn("recipe.categories", policy)
        self.assertIn("prototype.crafting_categories", policy)
        self.assertIn("on_entity_settings_pasted", source("control.lua"))
        self.assertNotIn("defines.inventory.roboport_robot", policy)
        self.assertNotIn("game.create_inventory", policy)

    def test_threshold_transitions_use_a_bounded_robot_recipe_priority_queue(self) -> None:
        policy = source("src/game/robotPolicy.lua")
        self.assertIn("MACHINE_REEVALUATION_BUDGET = 32", policy)
        self.assertIn("robot_machine_order_by_force", policy)
        self.assertIn("reevaluation_force_order", policy)
        self.assertIn("process_force_reevaluations", policy)
        reevaluate = re.search(
            r"reevaluate_force = function\(force_index\)(.*?)\nend",
            policy,
            re.DOTALL,
        )
        self.assertIsNotNone(reevaluate)
        self.assertIn("dense_add", reevaluate.group(1))
        self.assertNotIn("for ", reevaluate.group(1))
        processor = re.search(
            r"local function process_force_reevaluations\(\)(.*?)\nend",
            policy,
            re.DOTALL,
        )
        self.assertIsNotNone(processor)
        self.assertIn("processed < MACHINE_REEVALUATION_BUDGET", processor.group(1))
        self.assertIn("apply_machine_policy(record)", processor.group(1))
        built = policy[policy.index("function RobotPolicy.on_entity_built"):policy.index(
            "function RobotPolicy.on_entity_cloned"
        )]
        self.assertIn("register_machine(entity)", built)
        self.assertNotIn("transfer_from_inventory", policy)
        self.assertNotIn("stack.count", policy)
        self.assertNotRegex(policy, r"\.destroy\s*\(")

    def test_paused_clone_preserves_an_explicit_false_prior_state(self) -> None:
        policy = source("src/game/robotPolicy.lua")
        self.assertIn("if source_record and source_record.paused then", policy)
        self.assertIn(
            "cloned_prior = source_record.prior_disabled_by_script == true",
            policy,
        )
        self.assertIn("if cloned_prior ~= nil then", policy)

    def test_modes_limits_and_diagnostics_are_exposed(self) -> None:
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
        self.assertIn("sceatorio-robot-status", policy)
        self.assertNotIn("sceatorio-robot-recover", policy)
        for mode in ('"disabled"', '"warn"', '"enforce"'):
            self.assertIn(mode, policy)
        self.assertRegex(
            settings,
            re.compile(
                r'name = "sceatorio-robot-policy-mode".*?'
                r'default_value = "enforce"',
                re.S,
            ),
        )

    def test_build_remove_tick_gui_and_lifecycle_paths_are_wired(self) -> None:
        control = source("control.lua")
        for event in (
            "on_built_entity",
            "on_robot_built_entity",
            "on_player_mined_entity",
            "on_robot_mined_entity",
            "script_raised_destroy",
            "on_entity_settings_pasted",
            "on_space_platform_built_entity",
            "on_space_platform_mined_entity",
            "on_gui_click",
        ):
            self.assertIn(event, control)
        self.assertIn("RobotPolicy.tick", control)
        self.assertIn("RobotPolicy.on_gui_click", control)


if __name__ == "__main__":
    unittest.main()
