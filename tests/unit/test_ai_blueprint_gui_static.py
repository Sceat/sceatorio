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
        # The panel must never rebuild a blueprint item: aiBlueprints owns the
        # only layout-to-stack conversion, modules and control behavior included.
        self.assertNotIn("deliver_to_clipboard", gui)
        self.assertNotIn("set_blueprint_entities", gui)
        self.assertNotIn("set_blueprint_tiles", gui)

    def test_delivery_lands_in_the_cursor_and_spares_a_busy_one(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        # The finished stack goes into the player's hand, not the clipboard queue.
        self.assertIn("player.cursor_stack.set_stack(stack)", gui)
        sink = re.search(
            r"local function cursor_sink\(player\).*?\nend\n",
            gui,
            re.S,
        )
        assert sink is not None
        self.assertIn("add_to_clipboard = function(stack)", sink.group(0))
        # An occupied cursor holds the player's own item; delivering would
        # destroy it, so the busy check must run before Blueprints.load.
        delivery = re.search(
            r"local function deliver\(player, blueprint_id\).*?\nend\n",
            gui,
            re.S,
        )
        assert delivery is not None
        body = delivery.group(0)
        self.assertLess(
            body.index("cursor.valid_for_read"),
            body.index("Blueprints.load"),
        )
        self.assertRegex(
            body,
            re.compile(
                r"if cursor\.valid_for_read then\s*\n\s*return "
                r"\{\"gui\.sceatorio-ai-blueprints-cursor-busy\"\}",
            ),
        )
        # The existing failure surface stays the one report channel.
        self.assertIn('"gui.sceatorio-ai-blueprints-failed"', body)

    def test_blueprint_module_keeps_the_contract_the_panel_leans_on(self) -> None:
        # The panel hands aiBlueprints a delivery sink in place of the player,
        # so the sink must keep covering every member deliver_to_clipboard uses,
        # and contents must still precede the description or Factorio refuses it
        # on an empty blueprint.
        blueprints = source("src/game/aiBlueprints.lua")
        delivery = re.search(
            r"local function deliver_to_clipboard\(player, layout\).*?\nend\n",
            blueprints,
            re.S,
        )
        assert delivery is not None
        body = delivery.group(0)
        self.assertEqual(
            sorted(set(re.findall(r"player\.(\w+)", body))),
            ["add_to_clipboard", "connected", "valid"],
        )
        self.assertLess(
            body.index("set_blueprint_entities"),
            body.index("stack.blueprint_description"),
        )
        self.assertLess(
            body.index("set_blueprint_entities"),
            body.index("stack.label"),
        )
        self.assertLess(
            body.index("stack.set_stack({name = \"blueprint\", count = 1})"),
            body.index("set_blueprint_entities"),
        )

    def test_slot_icons_are_prototype_derived_and_validated(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        validator = re.search(
            r"local function first_valid_sprite\(paths\).*?\nend\n",
            gui,
            re.S,
        )
        assert validator is not None
        self.assertIn("pcall(helpers.is_valid_sprite_path, path)", validator.group(0))
        # Every drawn sprite is resolved through the validator, never built
        # straight into an element spec from a prototype name.
        self.assertNotRegex(gui, r"sprite\s*=\s*\"(entity|item|technology)/")
        # No element spec builds its own sprite path from a prototype name.
        self.assertNotRegex(gui, r"(?m)^\s+sprite = .*\.\.")
        self.assertIn('first_valid_sprite({"entity/" .. name, "item/" .. name})', gui)
        self.assertIn("return first_valid_sprite(GENERIC_SPRITES)", gui)
        # The icon ranking is derived from the stored layout, deterministically.
        ranking = re.search(
            r"local function summarize\(layout\).*?\nend\n",
            gui,
            re.S,
        )
        assert ranking is not None
        self.assertIn("table.sort(names", ranking.group(0))
        self.assertIn("return left < right", ranking.group(0))

    def test_no_removed_scroll_policy_style(self) -> None:
        self.assertNotIn(
            "vertical_scroll_policy",
            source("src/game/aiBlueprintGui.lua"),
        )

    def test_no_unguarded_style_property_read(self) -> None:
        # A LuaStyle only carries the keys its own prototype defines, and reading
        # an absent one raises immediately: LuaStyle.width is write-only, so the
        # 2.1.0 `panel.style.width` crashed on_configuration_changed before its
        # own numeric guard could run. Every style read here must sit inside a
        # pcall, and every style write goes through the guarded helper.
        gui = source("src/game/aiBlueprintGui.lua")
        access = re.compile(r"\.style\s*(?:\.\s*\w+|\[[^\]]*\])\s*(?P<assign>=?)")
        unguarded = []
        for number, line in enumerate(gui.splitlines(), start=1):
            for match in access.finditer(line):
                trailing = line[match.end():]
                is_write = match.group("assign") == "=" and not trailing.startswith("=")
                if is_write or "pcall" in line:
                    continue
                unguarded.append(f"{number}: {line.strip()}")
        self.assertEqual(unguarded, [])
        self.assertNotIn("panel.style.width", gui)
        writer = re.search(
            r"local function style\(element, values\).*?\nend\n",
            gui,
            re.S,
        )
        assert writer is not None
        self.assertIn("pcall", writer.group(0))

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

    def test_slots_are_bounded_and_paged_for_the_viewer_only(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        self.assertRegex(gui, r"local SLOTS_PER_PAGE = \d+")
        self.assertIn("local first = (page - 1) * SLOTS_PER_PAGE + 1", gui)
        self.assertIn("local last = math.min(#records, first + SLOTS_PER_PAGE - 1)", gui)
        self.assertIn("for index = first, last do add_slot(grid, records[index]) end", gui)
        self.assertIn("inbox_records(player.index)", gui)
        self.assertNotRegex(gui, r"for .* in pairs\(game\.players\)")

    def test_records_render_as_a_slot_grid(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        # A table of sprite-button slots, vanilla blueprint-book width.
        self.assertRegex(gui, r"local SLOT_COLUMNS = \d+")
        self.assertRegex(
            gui,
            re.compile(
                r"type = \"table\",\s*\n\s*name = \"slots\",\s*\n\s*"
                r"column_count = SLOT_COLUMNS",
            ),
        )
        slot = re.search(
            r"local function add_slot\(container, record\).*?\nend\n",
            gui,
            re.S,
        )
        assert slot is not None
        body = slot.group(0)
        self.assertIn('type = "sprite-button"', body)
        self.assertIn('style = "slot_button"', body)
        self.assertIn('tooltip = {\n      "gui.sceatorio-ai-blueprints-slot"', body)
        self.assertIn("sceatorio_action = ACTION_LOAD", body)
        # The row caption is gone; the detail it crammed in lives in the tooltip.
        self.assertNotIn("sceatorio-ai-blueprints-row", gui)
        self.assertNotIn("sceatorio-ai-blueprints-to-cursor", gui)

    def test_title_bar_carries_the_close_button_alone(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        frame = re.search(
            r"local function render_frame\(player, page, message\).*?\nend\n",
            gui,
            re.S,
        )
        assert frame is not None
        body = frame.group(0)
        # The frame itself carries no caption: the title bar row owns the title,
        # a draggable spacer, and the close button, in that order.
        header = re.search(
            r'type = "frame",\s*\n\s*name = FRAME_NAME,\s*\n\s*direction = "vertical"',
            body,
        )
        assert header is not None
        self.assertLess(
            body.index('style = "frame_title"'),
            body.index('style = "draggable_space_header"'),
        )
        self.assertLess(
            body.index('style = "draggable_space_header"'),
            body.index('sprite = "utility/close"'),
        )
        # The hint is a full-width wrapping label, not a title-bar neighbour.
        self.assertRegex(
            body,
            re.compile(
                r'caption = \{"gui\.sceatorio-ai-blueprints-hint"\}\}\)\s*\n\s*'
                r"style\(hint, \{single_line = false, maximal_width = ",
            ),
        )
        self.assertRegex(gui, r"local FRAME_WIDTH = \d+")

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
        # And no string outlives its caller.
        declared = set(re.findall(r"(?m)^(sceatorio-ai-blueprints-[a-z-]+)=", locale))
        self.assertEqual(declared - keys, set())


if __name__ == "__main__":
    unittest.main()
