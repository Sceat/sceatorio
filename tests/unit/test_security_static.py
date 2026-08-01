#!/usr/bin/env python3
"""Regression checks for Sceatorio's bounded anti-grief policy."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class ElectricityIsolationTests(unittest.TestCase):
    def test_factorio_2_1_connector_api_preserves_wire_origin(self) -> None:
        security = source("src/game/security.lua")
        compact = re.sub(r"\s+", "", security)
        self.assertIn(
            "get_wire_connector(defines.wire_connector_id.pole_copper,false)",
            compact,
        )
        self.assertIn("connection.origin", security)
        self.assertIn("disconnect_from", security)

    def test_implicit_foreign_supply_is_checked_exactly(self) -> None:
        security = source("src/game/security.lua")
        self.assertIn("electric_networks", security)
        self.assertIn("get_supply_area_distance", security)
        self.assertIn("max_electric_pole_supply_area_distance", security)

    def test_all_build_paths_are_wired_and_script_builds_fail_closed(self) -> None:
        control = source("control.lua")
        security = source("src/game/security.lua")
        for event in (
            "on_built_entity",
            "on_robot_built_entity",
            "script_raised_built",
            "script_raised_revive",
            "on_entity_cloned",
        ):
            self.assertIn(event, control)
        self.assertIn("event.consumed_items", security)
        self.assertIn("event.stack", security)
        self.assertIn('build_context(event, entity, "script")', security)
        self.assertIn("enqueue_deferred_build_audit(entity, context)", security)
        self.assertIn("process_build(entity, context, true)", security)
        self.assertIn("Security.on_tick(event)", control)
        self.assertNotIn("log_script_conflict", security)

    def test_silent_composite_children_are_audited_with_fixed_bounds(self) -> None:
        security = source("src/game/security.lua")
        for invariant in (
            "DEFERRED_BUILD_AUDIT_BUDGET = 8",
            "MAX_PENDING_BUILD_AUDITS = 4096",
            "MAX_LOCAL_CHILD_POLES = 16",
            "MAX_LOCAL_SUPPLIED_ENTITIES = 256",
            "audit_silent_child_poles",
            "ready_tick = game.tick + 1",
        ):
            self.assertIn(invariant, security)
        self.assertIn("force = entity.force", security)
        self.assertIn("register_connector_entity(pole)", security)
        self.assertIn("sanitize_entity_wires(pole)", security)

    def test_child_pole_bound_only_counts_unregistered_poles(self) -> None:
        security = source("src/game/security.lua")
        self.assertIn("MAX_LOCAL_POLE_SCAN = 256", security)
        start = security.index("local function audit_silent_child_poles")
        end = security.index("function Security.initialize", start + 1)
        body = security[start:end]
        self.assertIn("limit = MAX_LOCAL_POLE_SCAN + 1", body)
        self.assertLess(
            body.index("registry.slot_by_unit[pole.unit_number]"),
            body.index("#silent_children > MAX_LOCAL_CHILD_POLES"),
        )
        self.assertNotIn("#poles > MAX_LOCAL_CHILD_POLES", body)

    def test_local_supply_bound_only_counts_other_teams_entities(self) -> None:
        security = source("src/game/security.lua")
        start = security.index("local function unauthorized_entity_supplied_by_pole")
        end = security.index("local function", start + 1)
        body = security[start:end]
        self.assertIn("State.get().teams_by_id", body)
        self.assertIn("force = force", body)
        self.assertLess(
            body.index("power_sharing_allowed(pole_team, other_team)"),
            body.index("find_entities_filtered"),
        )
        self.assertIn("query = {area = area, force = force}", body)
        self.assertEqual(body.count("find_entities_filtered(query)"), 1)

    def test_manual_wire_connections_are_audited_boundedly(self) -> None:
        control = source("control.lua")
        security = source("src/game/security.lua")
        self.assertIn("on_selected_entity_changed", control)
        self.assertIn("audit_poles", security)
        self.assertIn("sceatorio-electricity-audit-budget", security)
        self.assertNotIn("game.get_entity_by_unit_number", security)

    def test_existing_save_poles_use_a_bounded_chunk_migration(self) -> None:
        control = source("control.lua")
        security = source("src/game/security.lua")
        self.assertIn("get_chunks", security)
        self.assertIn("chunk_migration", security)
        self.assertIn("sceatorio-electricity-migration-chunks-per-audit", security)
        self.assertIn("on_surface_created", control)
        self.assertIn("on_force_created", control)
        self.assertNotRegex(
            security,
            r"find_entities_filtered\(\{\s*type\s*=\s*[{\"]electric-pole",
        )

    def test_only_real_team_planet_entities_are_policy_subjects(self) -> None:
        security = source("src/game/security.lua")
        self.assertIn("Teams.get_by_force", security)
        self.assertIn("surface.platform", security)


class SecuritySettingsTests(unittest.TestCase):
    def test_remote_chunk_wrapper_normalizes_both_position_forms(self) -> None:
        radars = source("src/game/radars.lua")
        normalizer = re.search(
            r"local function normalize_chunk_position\(position\)(.*?)\nend",
            radars,
            re.DOTALL,
        )
        self.assertIsNotNone(normalizer)
        body = normalizer.group(1)
        self.assertIn("position.x", body)
        self.assertIn("position[1]", body)
        self.assertIn("position.y", body)
        self.assertIn("position[2]", body)
        self.assertIn("surface.is_chunk_generated(position)", radars)
        self.assertIn("force.is_chunk_charted(surface, position)", radars)

    def test_settings_are_runtime_global_and_localized(self) -> None:
        settings = source("settings.lua")
        locale = source("locale/en/sceatorio.cfg")
        expected = (
            "sceatorio-electricity-isolation",
            "sceatorio-electricity-audit-budget",
            "sceatorio-electricity-migration-chunks-per-audit",
            "sceatorio-offline-defense-enabled",
        )
        for name in expected:
            self.assertIn(name, settings)
            self.assertIn(name, locale)
        self.assertGreaterEqual(settings.count('setting_type = "runtime-global"'), 10)

    def test_team_charting_uses_only_bounded_physical_sources(self) -> None:
        radars = source("src/game/radars.lua")
        control = source("control.lua")
        self.assertNotIn("on_chunk_charted", control)
        self.assertNotIn("Radars.tick", control)
        self.assertNotIn("copy_chart", radars)
        self.assertNotIn("chart-union", radars)
        self.assertNotIn("canonical", radars)
        self.assertNotIn("catchup", radars)
        self.assertNotIn("surface.get_chunks", radars)
        self.assertIn("PLAYER_RADIUS_TILES = 70", radars)
        self.assertIn("RADAR_RADIUS_TILES = 112", radars)
        self.assertIn("game.connected_players", radars)
        self.assertIn('find_entities_filtered({type = "radar"})', radars)
        self.assertIn("Teams.get_by_force(radar.force)", radars)
        self.assertIn("Radars.share_discoveries(event)", control)

    def test_joining_does_not_script_chart_ungenerated_terrain(self) -> None:
        control = source("control.lua")
        self.assertNotIn("Radars.chart(player.force", control)

    def test_each_chart_refresh_is_generated_visible_aware_and_request_bounded(self) -> None:
        control = source("control.lua")
        radars = source("src/game/radars.lua")
        chart_helper = re.search(
            r"local function chart_generated_chunk\(.*?\nend",
            radars,
            re.DOTALL,
        )
        self.assertIsNotNone(chart_helper)
        helper = chart_helper.group(0)
        self.assertLess(
            helper.index("surface.is_chunk_generated(position)"),
            helper.index("force.chart(surface, area)"),
        )
        self.assertIn("force.is_chunk_visible(surface, position)", helper)
        self.assertIn("force.is_chunk_requested_for_charting(surface, position)", helper)
        self.assertNotIn("force.is_chunk_charted(surface, position)", helper)
        self.assertIn("CHUNK_END_EPSILON", helper)
        self.assertEqual(radars.count("force.chart("), 1)
        self.assertNotIn("request_to_generate_chunks", radars)
        self.assertNotIn("force_generate_chunk_requests", radars)
        self.assertNotIn("Radars.chart(player.force", control)

    def test_remote_sharing_cannot_reveal_undiscovered_chunks(self) -> None:
        radars = source("src/game/radars.lua")
        control = source("control.lua")
        self.assertIn('remote.add_interface("sceatorio_radars"', control)
        self.assertIn("Radars.share_chunk", control)
        self.assertIn('x ~= math.floor(x)', radars)
        remote_start = radars.index("function Radars.share_chunk")
        remote_end = radars.index("function Radars.status")
        remote = radars[remote_start:remote_end]
        self.assertLess(
            remote.index("surface.is_chunk_generated(position)"),
            remote.index("chart_generated_chunk("),
        )
        self.assertLess(
            remote.index("force.is_chunk_charted(surface, position)"),
            remote.index("chart_generated_chunk("),
        )
        self.assertNotIn("surface.get_chunks", remote)

    def test_security_fixture_exercises_generated_only_chart_sharing(self) -> None:
        fixture = source("tests/fixtures/security/control.lua")
        matrix = source("tests/headless/matrix.json")
        self.assertIn('"sceatorio_radars"', fixture)
        self.assertIn('"share_chunk"', fixture)
        self.assertIn("chunk is not generated", fixture)
        self.assertIn("source team has not charted", fixture)
        self.assertIn("source team has not charted check did not fail closed", fixture)
        self.assertIn("generated-only chart sharing", matrix)


class RuntimeSettingsReconcileTests(unittest.TestCase):
    def test_settings_reconcile_is_gated_and_fails_closed_per_key(self) -> None:
        admin = source("src/game/admin.lua")
        self.assertIn('commands.add_command(\n  "sceatorio-apply-settings"', admin)

        gate = admin[
            admin.index("local function command_player") : admin.index("local function reply")
        ]
        self.assertIn("if not event.player_index then return nil, true end", gate)
        self.assertIn("player and player.admin", gate)

        handler = admin[admin.index("local function apply_settings") :]
        self.assertLess(
            handler.index("if not allowed then"),
            handler.index("settings.global[name] = {value = value}"),
        )
        self.assertIn("pcall(helpers.json_to_table, event.parameter", handler)
        self.assertIn('type(desired) == "table"', handler)
        self.assertIn('if type(name) ~= "string" then', handler)
        self.assertIn("#names == 0 or #names > MAX_SETTING_KEYS", handler)
        self.assertIn("table.sort(names)", handler)

        # A payload that never becomes a settings map must fail loudly with an
        # error marker and never reach the success marker, so a reconciler that
        # gates on SCEATORIO_SETTINGS_APPLIED retries instead of reporting success.
        self.assertEqual(handler.count("SCEATORIO_SETTINGS_ERROR="), 3)
        for guard in (
            "if not names then",
            "#names == 0 or #names > MAX_SETTING_KEYS",
        ):
            self.assertLess(
                handler.index(guard),
                handler.index("SCEATORIO_SETTINGS_APPLIED changed="),
            )
        self.assertIn("name:sub(1, #SETTING_PREFIX) ~= SETTING_PREFIX", handler)
        self.assertIn("elseif not setting then", handler)
        self.assertIn("type(value) ~= type(setting.value)", handler)
        self.assertIn("elseif setting.value == value then", handler)
        # The engine coerces out-of-domain values; an unverified write would
        # report "changed" on every reconcile pass and never converge.
        self.assertIn("local stored = settings.global[name].value", handler)
        self.assertIn("reason=value_was_coerced_to_", handler)
        self.assertIn("SCEATORIO_SETTINGS_APPLIED changed=", handler)
        self.assertIn("SCEATORIO_SETTINGS_REJECTED name=", handler)

        self.assertIn('SETTING_PREFIX = "sceatorio-"', admin)
        self.assertIn("MAX_SETTING_KEYS = 100", admin)
        self.assertNotIn("settings.global[name].value =", admin)


if __name__ == "__main__":
    unittest.main()
