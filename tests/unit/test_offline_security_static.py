#!/usr/bin/env python3
"""Contract tests for immediate, reversible offline base protection."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class OfflineRegistryTests(unittest.TestCase):
    def test_offline_transition_is_immediate_and_exactly_reversible(self) -> None:
        security = source("src/game/offlineSecurity.lua")
        self.assertIn("connected_players", security)
        self.assertIn("entity.destructible", security)
        self.assertIn("entry.restore_destructible", security)
        self.assertIn("entity.destructible = false", security)
        self.assertIn("entity.destructible = entry.restore_destructible", security)
        transition = security[
            security.index("local function apply_record") : security.index(
                "local function refresh_record"
            )
        ]
        self.assertIn(
            "local next_registration = next(bucket, registration_number)", transition
        )
        self.assertNotIn("local registrations = {}", transition)
        self.assertNotIn("offline_since", security)
        self.assertNotIn("grace", security.lower())

    def test_registry_is_event_driven_without_world_discovery(self) -> None:
        security = source("src/game/offlineSecurity.lua")
        self.assertIn("register_on_object_destroyed", security)
        self.assertIn("on_object_destroyed", security)
        self.assertIn("CLEANUP_BUDGET", security)
        self.assertNotIn("find_entities", security)
        self.assertNotIn("get_chunks", security)
        self.assertNotIn("force_generate", security)

    def test_first_tick_after_load_reconciles_disconnected_server_state(self) -> None:
        control = source("control.lua")
        security = source("src/game/offlineSecurity.lua")
        self.assertIn("script.on_load(OfflineSecurity.on_load)", control)
        self.assertIn("needs_presence_reconcile", security)
        self.assertIn("function OfflineSecurity.on_tick", security)
        self.assertIn("OfflineSecurity.on_tick", control)
        on_load = security.split("function OfflineSecurity.on_load", 1)[1]
        on_load = on_load.split("function OfflineSecurity.on_tick", 1)[0]
        self.assertNotIn("game.", on_load)

    def test_base_classification_uses_2_1_prototype_semantics(self) -> None:
        security = source("src/game/offlineSecurity.lua")
        self.assertIn("prototype.is_building", security)
        for entity_type in (
            "car",
            "spider-vehicle",
            "locomotive",
            "cargo-wagon",
            "fluid-wagon",
            "artillery-wagon",
            "land-mine",
        ):
            self.assertIn(entity_type, security)
        for excluded_type in (
            "character",
            "construction-robot",
            "logistic-robot",
            "combat-robot",
            "resource",
            "projectile",
        ):
            self.assertIn(excluded_type, security)
        self.assertIn("surface.planet", security)
        self.assertIn("surface.platform", security)
        self.assertIn("game.surfaces.nauvis", security)

    def test_all_creation_removal_and_lifecycle_paths_are_wired(self) -> None:
        control = source("control.lua")
        security = source("src/game/offlineSecurity.lua")
        for event in (
            "on_built_entity",
            "on_robot_built_entity",
            "script_raised_built",
            "script_raised_revive",
            "on_entity_cloned",
            "on_space_platform_built_entity",
            "on_player_mined_entity",
            "on_robot_mined_entity",
            "script_raised_destroy",
            "on_space_platform_mined_entity",
            "on_entity_died",
            "on_object_destroyed",
        ):
            self.assertIn(event, control)
        for callback in (
            "on_entity_built",
            "on_entity_cloned",
            "on_entity_removed",
            "on_object_destroyed",
            "on_surface_deleted",
            "on_forces_merged",
        ):
            self.assertIn(f"OfflineSecurity.{callback}", control)
            self.assertRegex(security, rf"function OfflineSecurity\.{callback}\b")

    def test_quality_and_contents_are_preserved_by_not_recreating_entities(self) -> None:
        security = source("src/game/offlineSecurity.lua")
        self.assertNotIn("create_entity", security)
        self.assertNotIn(".destroy(", security)
        self.assertNotIn(".die(", security)
        self.assertNotIn(".health =", security)

    def test_protected_clone_restores_logical_prior_for_online_destination(self) -> None:
        security = source("src/game/offlineSecurity.lua")
        self.assertIn("has_restore_override", security)
        self.assertIn("entity.destructible = restore_override", security)


class OfflineSettingTests(unittest.TestCase):
    def test_only_master_setting_remains_and_is_localized(self) -> None:
        settings = source("settings.lua")
        locale = source("locale/en/sceatorio.cfg")
        self.assertIn("sceatorio-offline-defense-enabled", settings)
        self.assertIn("sceatorio-offline-defense-enabled", locale)
        for obsolete in (
            "sceatorio-offline-defense-grace-minutes",
            "sceatorio-offline-defense-radius",
        ):
            self.assertNotIn(obsolete, settings)
            self.assertNotIn(obsolete, locale)
        self.assertRegex(
            settings,
            re.compile(
                r'name = "sceatorio-offline-defense-enabled".*?'
                r'default_value = true',
                re.S,
            ),
        )


if __name__ == "__main__":
    unittest.main()
