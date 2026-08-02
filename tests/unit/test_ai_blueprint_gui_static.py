#!/usr/bin/env python3
"""Contract for the in-game AI blueprint inbox GUI."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


class AiBlueprintGuiTests(unittest.TestCase):
    def test_module_exists_and_is_wired_into_control(self) -> None:
        control = source("control.lua")
        self.assertTrue((ROOT / "src/game/aiBlueprintGui.lua").is_file())
        self.assertIn('require("src.game.aiBlueprintGui")', control)
        self.assertIn("AiBlueprintGui.initialize()", control)
        self.assertIn("AiBlueprintGui.on_gui_click(event)", control)
        for handler in (
            "on_player_joined",
            "on_player_changed_force",
            "on_research_finished",
            "on_setting_changed",
            "on_display_changed",
        ):
            self.assertIn(f"AiBlueprintGui.{handler}(event)", control)
        # The existing dispatch chain must stay intact.
        for existing in (
            "PlayerList.on_gui_click(event)",
            "TestMenu.on_gui_click(event)",
            "AiGateway.on_gui_click(event)",
            "RobotPolicy.on_gui_click(event)",
            "Spawns.on_gui_click(event)",
        ):
            self.assertIn(existing, control)

    def test_click_handler_dispatches_on_action_tags(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        self.assertRegex(
            gui,
            re.compile(
                r"function AiBlueprintGui\.on_gui_click\(event\).*?"
                r"local action = tags\.sceatorio_action.*?return false",
                re.S,
            ),
        )
        self.assertIn("tags = {sceatorio_action = ACTION_TOGGLE}", gui)
        self.assertIn("sceatorio_action = ACTION_LOAD", gui)
        self.assertIn("sceatorio_action = ACTION_PAGE", gui)
        self.assertIn("sceatorio_action = ACTION_CLOSE", gui)
        # Gateway swallows every action prefixed "ai_"; ours must not collide.
        for match in re.findall(r'local ACTION_\w+ = "([^"]+)"', gui):
            self.assertFalse(match.startswith("ai_"), match)

    def test_delivery_reuses_the_blueprint_module(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        self.assertIn('require("src.game.aiBlueprints")', gui)
        self.assertRegex(
            gui,
            re.compile(
                r"Blueprints\.load\(\s*\{.*?player_index = player\.index,.*?"
                r"allow_cursor = true.*?\},\s*blueprint_id,\s*nil,\s*\"cursor\"",
                re.S,
            ),
        )
        self.assertNotIn("deliver_to_clipboard", gui)
        self.assertNotIn("add_to_clipboard", gui)
        self.assertNotIn("set_blueprint_entities", gui)

    def test_no_removed_scroll_policy_style(self) -> None:
        self.assertNotIn(
            "vertical_scroll_policy",
            source("src/game/aiBlueprintGui.lua"),
        )

    def test_rendering_is_gated_on_technology_and_global_setting(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        self.assertIn('settings.global["sceatorio-ai-enabled"]', gui)
        self.assertIn("force.technologies[AiConstants.TECHNOLOGY]", gui)
        self.assertRegex(
            gui,
            re.compile(
                r"local function available\(player\).*?ai_enabled\(\).*?"
                r"technology_researched\(player\.force\)",
                re.S,
            ),
        )
        self.assertRegex(
            gui,
            re.compile(
                r"function AiBlueprintGui\.update\(player\).*?"
                r"if not available\(player\) then.*?button\.destroy\(\).*?"
                r"destroy_frame\(player\)",
                re.S,
            ),
        )
        self.assertRegex(
            gui,
            re.compile(
                r"function AiBlueprintGui\.toggle\(player\).*?if not available\(player\)",
                re.S,
            ),
        )

    def test_rows_are_bounded_and_paged_for_the_viewer_only(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        self.assertRegex(gui, r"local ROWS_PER_PAGE = \d+")
        self.assertIn("local first = (page - 1) * ROWS_PER_PAGE + 1", gui)
        self.assertIn("local last = math.min(#records, first + ROWS_PER_PAGE - 1)", gui)
        self.assertIn("for index = first, last do add_row(rows, records[index]) end", gui)
        self.assertIn("inbox_records(player.index)", gui)
        self.assertNotRegex(gui, r"for .* in pairs\(game\.players\)")

    def test_inbox_read_is_read_only_and_owner_scoped(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        self.assertRegex(
            gui,
            re.compile(
                r"local function inbox_records\(player_index\).*?"
                r"inboxes\[player_index\].*?return records",
                re.S,
            ),
        )
        reader = re.search(
            r"local function inbox_records\(player_index\).*?\nend\n",
            gui,
            re.S,
        )
        assert reader is not None
        body = reader.group(0)
        self.assertNotIn("Blueprints.save", body)
        self.assertNotRegex(body, r"inbox\.(order|by_id|bytes)\s*=")
        self.assertNotRegex(body, r"table\.(insert|remove)")

    def test_locale_strings_exist_for_every_gui_key(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        locale = source("locale/en/sceatorio.cfg")
        keys = set(re.findall(r'"gui\.(sceatorio-ai-blueprints-[a-z-]+)"', gui))
        self.assertTrue(keys)
        for key in keys:
            self.assertRegex(locale, rf"(?m)^{re.escape(key)}=")


if __name__ == "__main__":
    unittest.main()
