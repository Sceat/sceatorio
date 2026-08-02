#!/usr/bin/env python3
"""Fast regression checks for the runtime contract we can verify without Factorio."""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class MetadataTests(unittest.TestCase):
    def test_targets_exact_2_1_12_floor(self) -> None:
        info = json.loads(source("info.json"))
        matrix = json.loads(source("tests/headless/matrix.json"))
        target = matrix["factorio"]["version"]
        self.assertEqual(info["version"], "2.1.1")
        self.assertEqual(info["factorio_version"], ".".join(target.split(".")[:2]))
        self.assertIn(f"base >= {target}", info["dependencies"])
        self.assertIn(f"? space-age >= {target}", info["dependencies"])

    def test_headless_ci_uses_one_exact_pinned_provenance(self) -> None:
        matrix = json.loads(source("tests/headless/matrix.json"))
        target = matrix["factorio"]["version"]
        headless = matrix["factorio"]["headless"]
        self.assertEqual(
            headless["filename"], f"factorio-headless_linux_{target}.tar.xz"
        )
        self.assertEqual(
            headless["url"],
            f"https://factorio.com/get-download/{target}/headless/linux64",
        )
        self.assertRegex(headless["sha256"], r"^[0-9a-f]{64}$")

        suite = source("tests/headless/ci.sh")
        harness = source("tests/headless/run.sh")
        self.assertNotIn("required-server", suite)
        self.assertIn("run_factorio_background()", harness)
        self.assertNotIn("--disable-audio", harness)
        background = re.search(
            r"run_factorio_background\(\) \{(.*?)\n\}",
            harness,
            re.DOTALL,
        )
        self.assertIsNotNone(background)
        self.assertIn('exec "$FACTORIO_BIN_PATH"', background.group(1))
        self.assertEqual(harness.count("run_factorio_background \\\n"), 4)
        self.assertEqual(harness.count("ACTIVE_FACTORIO_PID=$!"), 4)
        self.assertIn("stop_active_factorio()", harness)
        self.assertNotIn("AI_SERVER_PID", harness)
        self.assertIn('completed-mod-fixtures/$case_id', harness)
        self.assertIn('mv "$MODS_DIR/mod-settings.dat"', harness)
        cleanup = re.search(
            r"safe_cleanup\(\) \{(.*?)\n\}",
            harness,
            re.DOTALL,
        )
        self.assertIsNotNone(cleanup)
        cleanup_body = cleanup.group(1)
        self.assertIn('if [ "${KEEP_TEST_DATA:-0}" = "1" ]', cleanup_body)
        self.assertNotIn('|| [ "$status" -ne 0 ]', cleanup_body)
        self.assertIn("rerun with KEEP_TEST_DATA=1", cleanup_body)
        self.assertIn('"$TEST_ROOT_PREFIX"??????', cleanup_body)
        self.assertIn('rm -rf -- "$TEST_ROOT"', cleanup_body)
        for foreground_name, next_name in (
            ("run_smoke", "run_benchmark"),
            ("run_benchmark", "run_server"),
        ):
            foreground = harness[
                harness.index(f"{foreground_name}()") : harness.index(
                    f"{next_name}()"
                )
            ]
            self.assertIn("run_factorio \\\n", foreground)
            self.assertNotIn("run_factorio_background", foreground)
        for command in (
            'sh "$RUNNER" smoke all',
            'sh "$RUNNER" server space-age',
            'sh "$RUNNER" fixture base security',
            'sh "$RUNNER" mod-fixture base all',
            'sh "$RUNNER" mod-fixture space-age space-age-planets',
            'sh "$RUNNER" ai-e2e base',
        ):
            self.assertIn(command, suite)

        for workflow_path in (
            ".github/workflows/ci.yml",
            ".github/workflows/release.yml",
        ):
            workflow = source(workflow_path)
            self.assertIn("headless-env", workflow)
            self.assertIn("sha256sum --check --strict", workflow)
            self.assertIn("sh tests/headless/ci.sh", workflow)
            self.assertNotIn(headless["sha256"], workflow)
            self.assertNotIn(headless["url"], workflow)
            self.assertNotIn("get-download/latest", workflow)


class LifecycleTests(unittest.TestCase):
    def test_storage_replaces_removed_global(self) -> None:
        gameplay = "\n".join(
            source(str(path.relative_to(ROOT)))
            for path in [ROOT / "control.lua", *sorted((ROOT / "src").rglob("*.lua"))]
            if path.name != "offlineSecurity.lua"
        )
        self.assertNotRegex(gameplay, r"(?<![\w.])global\s*\.")
        self.assertIn("storage.sceatorio", gameplay)

    def test_configuration_change_migrates_existing_saves(self) -> None:
        control = source("control.lua")
        self.assertIn("script.on_configuration_changed", control)
        self.assertRegex(control, r"State\.(?:initialize|migrate)")


class TeamAndJoinTests(unittest.TestCase):
    def test_team_identity_uses_explicit_force_indexes(self) -> None:
        teams = source("src/game/teams.lua")
        self.assertIn("team_id_by_force_index", teams)
        self.assertIn("team_id_by_enemy_force_index", teams)

    def test_force_creation_requires_explicit_registration(self) -> None:
        teams = source("src/game/teams.lua")
        control = source("control.lua")
        handler = re.search(
            r"function Teams\.on_force_created\(event\)(.*?)\nend",
            teams,
            re.DOTALL,
        )
        self.assertIsNotNone(handler)
        self.assertNotIn("register_force", handler.group(1))
        self.assertNotIn("make_record", handler.group(1))
        self.assertIn("Teams.register_force", teams)
        self.assertIn('remote.add_interface("sceatorio_teams"', control)
        self.assertIn("is_legacy_player_force", teams)

    def test_new_team_forces_cancel_factorio_origin_chart_requests(self) -> None:
        teams = source("src/game/teams.lua")
        helper = re.search(
            r"local function reset_new_force_charting\(force\)(.*?)\nend",
            teams,
            re.DOTALL,
        )
        self.assertIsNotNone(helper)
        self.assertIn("force.cancel_charting(surface)", helper.group(1))
        self.assertNotIn("force.clear_chart(surface)", helper.group(1))
        create = teams[
            teams.index("function Teams.create") : teams.index("function Teams.get(")
        ]
        self.assertIn("reset_new_force_charting(team_force)", create)
        self.assertIn("reset_new_force_charting(enemy_force)", create)
        self.assertLess(
            create.index("reset_new_force_charting(team_force)"),
            create.index("make_record("),
        )

    def test_enemy_isolation_does_not_write_human_team_relations(self) -> None:
        teams = source("src/game/teams.lua")
        self.assertIn("configure_enemy_matrix", teams)
        self.assertIn("owner_enemy", teams)
        self.assertIn("other.force_index", teams)
        self.assertNotIn("share_chart", teams)
        self.assertNotIn("friendly_fire", teams)

    def test_team_owner_is_reassigned_deterministically_across_lifecycle(self) -> None:
        teams = source("src/game/teams.lua")
        control = source("control.lua")
        self.assertIn("lowest_valid_player", teams)
        self.assertIn("player.index < selected.index", teams)
        self.assertIn("function Teams.ensure_owner", teams)
        self.assertIn("function Teams.on_player_changed_force", teams)
        self.assertIn("event.force", teams)
        self.assertIn("function Teams.on_player_removed", teams)
        self.assertGreaterEqual(teams.count("Teams.ensure_owner(record)"), 2)
        changed = control[control.index("on_player_changed_force"):control.index(
            "on_player_changed_surface"
        )]
        self.assertLess(
            changed.index("Teams.on_player_changed_force"),
            changed.index("PlayerList.on_player_changed"),
        )
        removed = control[control.index("on_player_removed"):control.index(
            "local display_events"
        )]
        self.assertLess(
            removed.index("Teams.on_player_removed"),
            removed.index("PlayerList.on_player_removed"),
        )

    def test_join_gui_uses_tags_and_validated_tokens(self) -> None:
        spawns = source("src/game/spawns.lua")
        self.assertIn("tags =", spawns)
        self.assertIn("join_token", spawns)
        self.assertNotIn('name=("joinMate="', spawns)
        self.assertNotRegex(spawns, r"string\.gmatch\([^\n]*%w\+")
        self.assertRegex(spawns, r"player\.force\s*=\s*target_force")
        self.assertIn('type(token) == "number"', spawns)
        self.assertIn("mark_force_transition", spawns)
        self.assertIn("Spawns.on_player_left", spawns)
        self.assertIn("Spawns.on_forces_merged", spawns)

    def test_spawn_and_chunk_logic_use_event_surface(self) -> None:
        spawns = source("src/game/spawns.lua")
        self.assertIn("event.surface", spawns)
        self.assertNotIn("game.surfaces.nauvis.find_entities_filtered", spawns)

    def test_enemy_geometry_is_deterministic_and_native_only(self) -> None:
        teams = source("src/game/teams.lua")
        surfaces = source("src/game/surfacePolicy.lua")
        spawns = source("src/game/spawns.lua")
        planet_spawns = source("src/game/planetSpawns.lua")

        self.assertIn("squared == nearest_squared", teams)
        self.assertIn("record.id < nearest.id", teams)
        self.assertIn("surface.planet", surfaces)
        self.assertIn("surface.platform", surfaces)
        self.assertIn('planet.name == "nauvis"', surfaces)
        self.assertIn('planet.name == "gleba"', surfaces)
        self.assertIn("SurfacePolicy.is_native_hostile_surface(surface)", spawns)
        biter_expansion = spawns[
            spawns.index("function Spawns.on_biter_base_built") : spawns.index(
                "function Spawns.on_build_base_arrived"
            )
        ]
        build_arrival = spawns[
            spawns.index("function Spawns.on_build_base_arrived") : spawns.index(
                "function Spawns.initialize_new_game"
            )
        ]
        self.assertIn(
            "SurfacePolicy.is_native_hostile_surface(entity.surface)",
            biter_expansion,
        )
        self.assertIn(
            "SurfacePolicy.is_native_hostile_surface(commandable.surface)",
            build_arrival,
        )
        self.assertIn(
            'type = {"unit", "unit-spawner", "turret"}',
            spawns,
        )
        self.assertGreaterEqual(
            planet_spawns.count("SurfacePolicy.is_native_hostile_surface(surface)"),
            2,
        )

    def test_primary_spawn_generation_is_asynchronous(self) -> None:
        spawns = source("src/game/spawns.lua")
        tick = re.search(
            r"function Spawns\.tick\(event\)(.*?)\nend\n\nfunction Spawns\.on_chunk_generated",
            spawns,
            re.DOTALL,
        )
        self.assertIsNotNone(tick)
        self.assertIn("requested_chunks_ready", tick.group(1))
        self.assertNotIn("force_generate_chunk_requests", tick.group(1))

    def test_new_team_force_is_assigned_only_after_spawn_teleport(self) -> None:
        spawns = source("src/game/spawns.lua")
        create = spawns[
            spawns.index("local function generate_player_spawn") : spawns.index(
                "function Spawns.on_gui_click"
            )
        ]
        self.assertNotIn("player.force = team_force", create)
        self.assertIn("State.get().pending_teleports[player.index]", create)
        tick = re.search(
            r"function Spawns\.tick\(event\)(.*?)\nend\n\nfunction Spawns\.on_chunk_generated",
            spawns,
            re.DOTALL,
        )
        self.assertIsNotNone(tick)
        body = tick.group(1)
        self.assertIn("local team_force = Teams.get_force(record)", body)
        self.assertIn("mark_force_transition(player, team_force, event.tick)", body)
        self.assertIn("player.force = team_force", body)
        self.assertLess(
            body.index("player.teleport(pending.spawn, surface)"),
            body.index("player.force = team_force"),
        )
        joined = spawns[
            spawns.index("function Spawns.on_player_joined") : spawns.index(
                "local function requested_chunks_ready"
            )
        ]
        self.assertIn("pending_teleports[player.index]", joined)
        self.assertIn("not root.pending_teleports[player_index]", body)


class EvolutionTests(unittest.TestCase):
    def test_deaths_drive_team_surface_counters(self) -> None:
        evolution = source("src/game/evo.lua")
        control = source("control.lua")
        self.assertIn("on_entity_died", control)
        self.assertIn("worm_kills", evolution)
        self.assertIn("spawner_kills", evolution)
        self.assertNotIn("kill_count_statistics", evolution)

    def test_bounded_raw_conversion_is_explicit(self) -> None:
        evolution = source("src/game/evo.lua")
        compact = re.sub(r"\s+", "", evolution)
        self.assertIn("raw/(1+raw)", compact)

    def test_factorio_2_1_surface_api_is_used(self) -> None:
        evolution = source("src/game/evo.lua")
        self.assertRegex(evolution, r"set_evolution_factor\([^,]+,\s*surface")
        self.assertNotRegex(evolution, r"\.evolution_factor(?:_by_\w+)?\s*=")

    def test_connected_time_is_deduplicated_per_team_surface(self) -> None:
        evolution = source("src/game/evo.lua")
        evolution_math = source("src/game/evolution_math.lua")
        self.assertIn("connected_since", evolution_math)
        self.assertIn("active_team_surfaces", evolution)
        self.assertIn("EvolutionMath.sync_connected_time", evolution)
        self.assertIn("connected_progression_enabled", evolution_math)
        self.assertIn("connected_time_coefficient", evolution_math)
        self.assertIn(
            "ledger.connected_progression_enabled = progression_enabled == true",
            evolution_math,
        )
        self.assertIn("if previous_policy then", evolution_math)

    def test_pollution_uses_one_bounded_statistics_sample_per_surface(self) -> None:
        evolution = source("src/game/evo.lua")
        evolution_math = source("src/game/evolution_math.lua")
        evolution_implementation = evolution + evolution_math
        state = source("src/core/state.lua")
        settings = source("settings.lua")
        fixture = source("tests/fixtures/evolution/control.lua")
        self.assertIn("statistics.output_counts", evolution)
        self.assertNotIn("pollution_statistics.input_counts", evolution)
        self.assertIn("prototypes.entity[prototype_name]", evolution)
        self.assertIn('prototype.type == "unit-spawner"', evolution)
        self.assertIn("surface.pollutant_type", evolution)
        self.assertIn("affects_evolution", evolution)
        self.assertIn("EvolutionMath.sync_pollution", evolution)
        self.assertIn("raw_pollution", evolution_implementation)
        self.assertIn("pollution_units", evolution_implementation)
        self.assertIn("pollution_cursor", evolution_implementation)
        self.assertIn("pollution_progression_enabled", evolution_math)
        self.assertIn("pollution_coefficient", evolution_math)
        self.assertIn("MAX_POLLUTION_UNITS = 1e300", evolution)
        self.assertGreaterEqual(evolution_math.count("math.min("), 2)
        self.assertIn('sceatorio-evolution-pollution-per-unit', settings)
        self.assertIn('default_value = 0.0000009', settings)
        self.assertIn('nauvis.pollute(', fixture)
        self.assertIn('"stone-furnace"', fixture)
        self.assertIn('output_counts["biter-spawner"]', fixture)
        self.assertIn('create_victim(nauvis, "biter-spawner"', fixture)
        self.assertIn("assert_pollution_semantics_migration", fixture)
        self.assertIn('ledger.raw_pollution ~= 0.25', fixture)
        self.assertIn("local SCHEMA_VERSION = 5", state)
        self.assertIn("if previous_schema >= 5 then return end", state)
        self.assertIn("ledger.pollution_cursor = nil", state)
        self.assertNotIn("ledger.raw_pollution = 0", state)
        for unbounded_api in (
            "get_total_pollution",
            "get_pollution",
            "get_chunks",
            "find_entities",
            "find_entities_filtered",
        ):
            self.assertNotIn(unbounded_api, evolution)

    def test_connected_time_uses_physical_character_not_remote_view(self) -> None:
        evolution = source("src/game/evo.lua")
        teams = source("src/game/teams.lua")
        players = source("src/game/playerList.lua")
        self.assertIn("player.character", evolution)
        self.assertIn("character.surface", evolution)
        self.assertNotIn("player.surface", evolution)
        self.assertIn("player.character", teams)
        self.assertIn("character.surface.index == surface.index", teams)
        self.assertNotIn("player.surface.index == surface.index", teams)
        self.assertIn("physical_surface", players)
        self.assertIn("Evolution.get_factor(record, physical_surface)", players)
        self.assertNotIn("Evolution.get_factor(record, listed_player.surface)", players)
        spawns = source("src/game/spawns.lua")
        create_start = spawns.index("local function generate_player_spawn")
        create_end = spawns.index("function Spawns.on_gui_click")
        create_team = spawns[create_start:create_end]
        self.assertIn("local surface = physical_surface(player)", create_team)
        self.assertNotIn("local surface = player.surface", create_team)


class ApiBreakTests(unittest.TestCase):
    def test_unit_group_members_are_iterated(self) -> None:
        gameplay = source("control.lua") + source("src/game/spawns.lua")
        self.assertIn("event.group.members", gameplay)


class PlayerListTests(unittest.TestCase):
    def test_panel_is_compact_screen_anchored_expanded_and_persistent(self) -> None:
        players = source("src/game/playerList.lua")
        self.assertIn("player.gui.screen", players)
        self.assertIn("display_resolution.width", players)
        self.assertIn("display_scale", players)
        self.assertIn("player_list_collapsed", players)
        self.assertIn("create_list(panel)", players)
        self.assertIn("PANEL_WIDTH = 340", players)
        self.assertIn("x = math.floor(8 * scale)", players)
        self.assertNotIn("player.display_resolution.width - (width + 12) * scale", players)
        self.assertNotIn('type = "scroll-pane"', players)
        self.assertNotIn("player.gui.top.add", players)

    def test_panel_hugs_the_free_corner_and_stays_compact(self) -> None:
        players = source("src/game/playerList.lua")
        blueprints = source("src/game/aiBlueprintGui.lua")
        # The old offset only existed to clear the retired robot status button.
        self.assertNotIn("TOP_OFFSET = 52", players)
        self.assertIn("TOP_INSET = 8", players)
        self.assertIn("TOP_CLEARANCE = 52", players)
        self.assertIn("y = math.floor(top_offset(player) * scale)", players)
        # The clearance is measured, not assumed: it applies only while some mod
        # actually occupies player.gui.top.
        offset = re.search(
            r"local function top_offset\(player\)(.*?)\nend",
            players,
            re.DOTALL,
        )
        self.assertIsNotNone(offset)
        self.assertIn("player.gui.top.children", offset.group(1))
        self.assertIn("return TOP_CLEARANCE", offset.group(1))
        self.assertIn("return TOP_INSET", offset.group(1))
        self.assertIn("style(panel, {padding = 2})", players)
        self.assertIn("vertical_spacing = 0", players)
        self.assertNotIn("padding = 4", players)
        # The inbox button docks off the live panel position, so it follows.
        self.assertIn("panel.location.x + math.floor((width + GAP) * scale)", blueprints)
        self.assertIn("y = panel.location.y", blueprints)
        self.assertIn("PLAYER_PANEL_TOP_OFFSET = 8", blueprints)

    def test_player_list_never_writes_scroll_policy_through_luastyle(self) -> None:
        players = source("src/game/playerList.lua")
        # Factorio 2.1 exposes these on LuaGuiElement, not LuaStyle. Writing
        # either key through element.style causes a non-recoverable GUI error.
        self.assertNotIn("vertical_scroll_policy", players)
        self.assertNotIn("horizontal_scroll_policy", players)
        self.assertNotIn('type = "scroll-pane"', players)

    def test_all_player_total_time_and_status_update_on_bounded_timer(self) -> None:
        players = source("src/game/playerList.lua")
        control = source("control.lua")
        self.assertIn("pairs(game.players)", players)
        self.assertIn("listed_player.online_time", players)
        self.assertIn("directory.connected[player.index] = player.connected", players)
        self.assertIn('render_entry(panel, listed_player, group_name == "online")', players)
        self.assertIn("VIEWERS_PER_REFRESH", players)
        self.assertIn("PlayerList.refresh_entry", players)
        self.assertIn("script.on_nth_tick(10 * 60", control)
        self.assertIn("PlayerList.tick", control)

    def test_player_directory_is_cached_and_both_groups_are_paginated(self) -> None:
        players = source("src/game/playerList.lua")
        state = source("src/core/state.lua")
        control = source("control.lua")
        self.assertIn("PLAYERS_PER_GROUP_PAGE", players)
        self.assertIn("directory_cache", players)
        self.assertIn("ensure_directory", players)
        self.assertIn("insert_sorted", players)
        self.assertIn("player_list_pages", players)
        self.assertIn("player_list_pages", state)
        self.assertIn('sceatorio_action = "player_list_page"', players)
        self.assertIn("function PlayerList.on_gui_click", players)
        self.assertIn("PlayerList.on_gui_click(event)", control)

        update = re.search(
            r"function PlayerList\.update\(player\)(.*?)\nend\n\nfunction PlayerList\.toggle",
            players,
            re.DOTALL,
        )
        self.assertIsNotNone(update)
        self.assertNotIn("pairs(game.players)", update.group(1))
        self.assertIn('render_group(panel, player, "online"', update.group(1))
        self.assertIn('render_group(panel, player, "offline"', update.group(1))

    def test_panel_survives_player_and_display_lifecycle(self) -> None:
        control = source("control.lua")
        for hook in (
            "PlayerList.initialize",
            "PlayerList.on_player_created",
            "PlayerList.on_player_joined",
            "PlayerList.on_player_left",
            "PlayerList.on_player_changed",
            "PlayerList.on_player_removed",
            "PlayerList.on_display_changed",
        ):
            self.assertIn(hook, control)
        self.assertIn("on_player_changed_force", control)
        self.assertIn("on_player_changed_surface", control)
        self.assertIn("on_player_respawned", control)
        self.assertIn("on_player_display_resolution_changed", control)


if __name__ == "__main__":
    unittest.main()
