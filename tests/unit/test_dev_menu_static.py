#!/usr/bin/env python3
"""Safety contract for the production-off administrator test menu."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class DevMenuTests(unittest.TestCase):
    def test_setting_is_runtime_global_production_off_and_localized(self) -> None:
        settings = source("settings.lua")
        locale = source("locale/en/sceatorio.cfg")
        self.assertRegex(
            settings,
            re.compile(
                r'name = "sceatorio-dev-tools-enabled".*?'
                r'setting_type = "runtime-global".*?default_value = false',
                re.S,
            ),
        )
        self.assertIn("sceatorio-dev-tools-enabled", locale)

    def test_every_player_action_requires_setting_and_admin(self) -> None:
        menu = source("src/game/testMenu.lua")
        self.assertIn("player.admin", menu)
        self.assertIn("sceatorio-dev-tools-enabled", menu)
        self.assertIn("if not authorized(player)", menu)
        self.assertNotIn("loadstring", menu)
        self.assertNotIn("rcon", menu.lower())
        self.assertNotIn("reset", menu.lower())

    def test_planet_controls_use_explicit_safe_arrival_api(self) -> None:
        menu = source("src/game/testMenu.lua")
        planets = source("src/game/planetSpawns.lua")
        self.assertIn("pairs(game.planets)", menu)
        self.assertIn("BUILTIN_PLANET_ORDER", menu)
        self.assertIn("planet_name = planet.name", menu)
        self.assertNotIn("surface_index = surface.index", menu)
        self.assertIn("PlanetSpawns.debug_route_player_to_planet", menu)
        self.assertIn("PlanetSpawns.debug_return_to_nauvis", menu)
        self.assertIn("function PlanetSpawns.debug_route_player_to_planet", planets)
        self.assertIn("registered.create_surface()", planets)
        self.assertIn("function PlanetSpawns.debug_route_player", planets)
        self.assertIn("PlanetSpawns.request_spawn", planets)
        self.assertNotIn("raise_script", menu)
        self.assertNotRegex(menu, r"defines\.events\.on_")
        self.assertIn("reserve_planet_spawn", menu)
        self.assertIn("planet_spawn_status", menu)

    def test_menu_does_not_eagerly_create_unvisited_planet_surfaces(self) -> None:
        menu = source("src/game/testMenu.lua")
        self.assertIn("planet.surface", menu)
        self.assertNotIn("create_surface", menu)
        self.assertIn("sceatorio.dev-tools-planet-status", menu)

    def test_status_and_bounded_diagnostics_are_exposed(self) -> None:
        menu = source("src/game/testMenu.lua")
        self.assertIn("Evolution.get_factor", menu)
        self.assertIn("OfflineSecurity.status", menu)
        self.assertIn("RobotPolicy.show_status", menu)
        self.assertIn("Security.audit_poles", menu)
        self.assertIn("sceatorio-electricity-audit-budget", menu)

    def test_research_all_is_admin_dev_gui_only_and_force_local(self) -> None:
        menu = source("src/game/testMenu.lua")
        gui = menu[: menu.index('remote.add_interface("sceatorio_dev_tools"')]
        remote = menu[menu.index('remote.add_interface("sceatorio_dev_tools"') :]
        self.assertIn('sceatorio_action = "dev_tools_research_all"', gui)
        self.assertIn('action == "dev_tools_research_all"', gui)
        self.assertIn("local record = Teams.get_for_player(player)", gui)
        self.assertIn("player.force.research_all_technologies(false)", gui)
        self.assertNotIn("research_all_technologies", remote)

    def test_chart_fixture_hook_is_dev_gated_and_uses_production_queue(self) -> None:
        menu = source("src/game/testMenu.lua")
        hook = menu[menu.index("share_chart_chunk"):menu.index("reserve_planet_spawn")]
        self.assertIn("if not enabled()", hook)
        self.assertIn("Radars.share_chunk", hook)
        self.assertNotIn("force.chart", hook)

    def test_control_lifecycle_is_wired(self) -> None:
        control = source("control.lua")
        for token in (
            'require("src.game.testMenu")',
            "TestMenu.initialize",
            "TestMenu.on_player_joined",
            "TestMenu.on_player_changed_force",
            "TestMenu.on_setting_changed",
            "TestMenu.on_gui_click",
        ):
            self.assertIn(token, control)


if __name__ == "__main__":
    unittest.main()
