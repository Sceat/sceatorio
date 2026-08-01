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

    def test_team_charting_is_global_event_driven_and_entity_scan_free(self) -> None:
        radars = source("src/game/radars.lua")
        control = source("control.lua")
        self.assertIn("on_chunk_charted", control)
        self.assertIn("Radars.on_chunk_charted", control)
        self.assertIn("Radars.tick", control)
        self.assertIn("copy_chart", radars)
        self.assertIn('CHART_UNION_FORCE_NAME = "sceatorio-chart-union"', radars)
        self.assertIn("destination_force.copy_chart(canonical", radars)
        self.assertIn("already_registered", control)
        self.assertIn("if not already_registered", control)
        self.assertIn("canonical.chart(surface, entry.area)", radars)
        self.assertNotIn("accumulator.copy_chart", radars)
        self.assertIn("CHUNKS_PER_TICK", radars)
        self.assertIn("SUPPRESSION_GENERATIONS = 2", radars)
        self.assertIn("suppression_current", radars)
        self.assertIn("suppression_previous", radars)
        self.assertNotIn("SUPPRESSION_LIFETIME", radars)
        self.assertNotIn("suppression_expiry[#", radars)
        self.assertIn("suppression_count", radars)
        self.assertNotIn("chart_area", control)
        self.assertNotIn("sceatorio-cross-team-map-sharing", radars)
        self.assertNotIn("share_chart", radars)
        self.assertNotIn("find_entities_filtered", radars)

    def test_team_chart_queue_has_coalesced_backpressure_and_bounded_recovery(self) -> None:
        radars = source("src/game/radars.lua")
        control = source("control.lua")
        self.assertIn("MAX_PENDING_CHUNKS", radars)
        self.assertIn("CATCHUP_CHUNKS_PER_TICK = 16", radars)
        self.assertIn("catchup_by_surface", radars)
        self.assertIn("mark_surface_for_catchup", radars)
        self.assertIn("surface.get_chunks()", radars)
        self.assertIn("job.version", radars)
        self.assertIn("if job.version == runtime.version then", radars)
        self.assertIn("total_catchup_restarts", radars)
        self.assertIn("total_deferred", radars)
        self.assertIn("max_queue_depth", radars)
        self.assertIn("backpressure_active", radars)
        self.assertIn("queue_capacity = MAX_PENDING_CHUNKS", radars)
        self.assertIn("catchup_surface_count", radars)
        self.assertNotIn("for _, force in ipairs(valid_team_forces())", radars)
        self.assertIn("propagate(sync, entry, forces, canonical)", radars)
        self.assertIn(
            "if queue_depth(sync) == 0 and not next(sync.catchup_by_surface) then",
            radars,
        )
        self.assertIn('remote.add_interface("sceatorio_radars"', control)
        self.assertIn("Radars.share_chunk", control)
        self.assertIn('x ~= math.floor(x)', radars)
        self.assertNotIn("script.raise_event", radars)

    def test_security_fixture_saturates_and_recovers_the_real_chart_queue(self) -> None:
        fixture = source("tests/fixtures/security/control.lua")
        matrix = source("tests/headless/matrix.json")
        self.assertIn("CHART_QUEUE_CAPACITY = 4096", fixture)
        self.assertIn("for index = 1, CHART_QUEUE_CAPACITY do", fixture)
        self.assertIn('"sceatorio_radars"', fixture)
        self.assertIn('"share_chunk"', fixture)
        self.assertIn("radar.queue_depth ~= CHART_QUEUE_CAPACITY", fixture)
        self.assertIn("status.total_catchup_passes < 1", fixture)
        self.assertIn("status.total_catchup_restarts <= fixture.restart_before", fixture)
        self.assertIn("status.total_backpressure_recoveries < 1", fixture)
        self.assertIn("third_force.is_chunk_charted(surface, RECOVERY_CHUNK)", fixture)
        self.assertIn("saturated chart queue", matrix)


if __name__ == "__main__":
    unittest.main()
