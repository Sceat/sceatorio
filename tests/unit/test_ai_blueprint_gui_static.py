#!/usr/bin/env python3
"""Contract for the in-game AI blueprint inbox window.

The window is Factorio's own inventory GUI opened on a mod-owned inventory, not
a hand-drawn slot grid: the engine renders the real blueprint stacks. These
assertions pin that, plus the safety properties the panel had before it.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def block(text: str, signature: str) -> str:
    match = re.search(
        re.escape(signature) + r".*?\nend\n",
        text,
        re.S,
    )
    assert match is not None, signature
    return match.group(0)


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
            # The inventory has a lifecycle now: it must be released when its
            # window closes and destroyed when its player is removed.
            "on_gui_closed",
            "on_player_removed",
        ):
            self.assertIn(f"AiBlueprintGui.{handler}(event)", control)
        # Chaining onto on_gui_closed must not drop the gateway's own handler.
        self.assertIn("AiGateway.on_gui_closed(event)", control)
        # The existing dispatch chain must stay intact.
        for existing in (
            "PlayerList.on_gui_click(event)",
            "TestMenu.on_gui_click(event)",
            "AiGateway.on_gui_click(event)",
            "RobotPolicy.on_gui_click(event)",
            "Spawns.on_gui_click(event)",
        ):
            self.assertIn(existing, control)

    def test_click_handler_dispatches_on_the_single_toggle_tag(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        self.assertRegex(
            gui,
            re.compile(
                r"function AiBlueprintGui\.on_gui_click\(event\).*?"
                r"tags\.sceatorio_action ~= ACTION_TOGGLE then return false",
                re.S,
            ),
        )
        self.assertIn("tags = {sceatorio_action = ACTION_TOGGLE}", gui)
        # The engine owns the window, so the mod owns exactly one element: the
        # button. No load, page or close actions survive.
        self.assertEqual(re.findall(r"local (ACTION_\w+) = ", gui), ["ACTION_TOGGLE"])
        # Gateway swallows every action prefixed "ai_"; ours must not collide.
        for match in re.findall(r'local ACTION_\w+ = "([^"]+)"', gui):
            self.assertFalse(match.startswith("ai_"), match)

    def test_window_is_the_engine_inventory_gui(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        # The one line that opens the window: Factorio renders the stacks.
        self.assertIn("player.opened = inventory", gui)
        toggle = block(gui, "function AiBlueprintGui.toggle(player)")
        self.assertIn("ensure_inventory(player)", toggle)
        self.assertIn("fill(player, inventory)", toggle)
        self.assertLess(
            toggle.index("fill(player, inventory)"),
            toggle.index("player.opened = inventory"),
        )
        # A second click closes it again.
        self.assertIn("player.opened = nil", toggle)
        # Nothing hand-draws a slot any more: no custom frame, no pagination,
        # no sprite-button grid, no per-record tooltip.
        for gone in (
            "render_frame",
            "add_slot",
            "SLOT_COLUMNS",
            "SLOTS_PER_PAGE",
            "FRAME_NAME",
            "FRAME_WIDTH",
            "slot_button",
            "draggable_space_header",
            "auto_center",
        ):
            self.assertNotIn(gone, gui)

    def test_inventory_is_mod_owned_and_has_a_lifecycle(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        # Created through the script-inventory API, titled by our locale key.
        self.assertIn(
            'game.create_inventory(MAX_SLOTS, {"gui.sceatorio-ai-blueprints-title"})',
            gui,
        )
        self.assertRegex(gui, r"local MAX_SLOTS = \d+")
        # The handle is persisted so it survives save/load, keyed per player.
        self.assertIn("store[player.index] = created", gui)
        # A stale handle from an older save never reaches the engine.
        stored = block(gui, "local function stored_inventory(player_index)")
        self.assertIn("inventory.valid", stored)
        # And it is destroyed when its player goes, so nothing leaks.
        removed = block(gui, "function AiBlueprintGui.on_player_removed(event)")
        self.assertIn("store[event.player_index] = nil", removed)
        self.assertIn("inventory.destroy()", removed)
        # Closing the window releases it instead of leaving stacks parked.
        closed = block(gui, "function AiBlueprintGui.on_gui_closed(event)")
        self.assertIn("defines.gui_type.script_inventory", closed)
        self.assertIn("release(player, inventory)", closed)

    def test_stacks_come_from_the_blueprint_module_seam(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        self.assertIn('require("src.game.aiBlueprints")', gui)
        self.assertRegex(
            gui,
            re.compile(
                r"Blueprints\.load\(\s*\{.*?player = slot_sink\(player, stack\),.*?"
                r"player_index = player\.index,.*?allow_cursor = true.*?\},\s*"
                r"blueprint_id,\s*nil,\s*\"cursor\"",
                re.S,
            ),
        )
        # The window must never rebuild a blueprint item: aiBlueprints owns the
        # only layout-to-stack conversion, modules and control behavior included.
        for owned in (
            "deliver_to_clipboard",
            "set_blueprint_entities",
            "set_blueprint_tiles",
            "blueprint_description",
        ):
            self.assertNotIn(owned, gui)
        # The sink writes the finished stack into our own slot, not the cursor
        # and not the clipboard queue.
        sink = block(gui, "local function slot_sink(player, stack)")
        self.assertIn("add_to_clipboard = function(source)", sink)
        self.assertIn("stack.set_stack(source)", sink)

    def test_blueprint_module_keeps_the_contract_the_window_leans_on(self) -> None:
        # The window hands aiBlueprints a delivery sink in place of the player,
        # so the sink must keep covering every member deliver_to_clipboard uses,
        # and contents must still precede the description or Factorio refuses it
        # on an empty blueprint.
        blueprints = source("src/game/aiBlueprints.lua")
        body = block(blueprints, "local function deliver_to_clipboard(player, layout)")
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

    def test_contents_are_rebuilt_from_the_inbox_on_every_open(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        fill = block(gui, "local function fill(player, inventory)")
        self.assertIn("inbox_records(player.index)", fill)
        # Reclaim runs before the wipe, so nothing of the player's is destroyed.
        self.assertLess(fill.index("reclaim("), fill.index("inventory.clear()"))
        self.assertLess(fill.index("inventory.clear()"), fill.index("write_stack("))
        # Bounded twice: the caller's own inbox and a hard slot ceiling.
        self.assertIn("math.min(#records, MAX_SLOTS)", fill)
        self.assertIn("for index = 1, math.min(#records, count) do", fill)

    def test_inserted_items_are_returned_not_destroyed(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        # Anything that is not one of our own blueprint copies goes back to the
        # player, and only spills to the ground when it does not fit -- a
        # partially accepted stack must spill its remainder, never drop it.
        give_back = block(gui, "local function give_back(player, stack)")
        self.assertIn("player.insert(stack)", give_back)
        self.assertLess(
            give_back.index("player.insert(stack)"),
            give_back.index("spill(player, stack)"),
        )
        self.assertIn("if moved >= count then return end", give_back)
        self.assertIn("local remainder = count - moved", give_back)
        self.assertIn("spill(player, {name = stack.name, count = remainder", give_back)
        self.assertIn("spill_item_stack", block(gui, "local function spill(player, stack)"))
        reclaim = block(gui, "local function reclaim(player, inventory, owned)")
        self.assertIn("give_back(player, stack)", reclaim)
        # Ownership is decided by the label of a blueprint still in the inbox.
        self.assertIn('stack.name == "blueprint"', reclaim)
        self.assertIn("owned[label]", reclaim)
        # And the return is announced: nothing disappears silently.
        self.assertIn('player.print({"gui.sceatorio-ai-blueprints-returned"', reclaim)
        # Release runs the same reclaim before emptying the window.
        release = block(gui, "local function release(player, inventory)")
        self.assertLess(release.index("reclaim("), release.index("inventory.clear()"))

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
        writer = block(gui, "local function style(element, values)")
        self.assertIn("pcall", writer)

    def test_button_sprite_is_prototype_derived_and_validated(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        validator = block(gui, "local function first_valid_sprite(paths)")
        self.assertIn("pcall(helpers.is_valid_sprite_path, path)", validator)
        # No element spec builds its own sprite path from a prototype name.
        self.assertNotRegex(gui, r"sprite\s*=\s*\"(entity|item|technology)/")
        self.assertNotRegex(gui, r"(?m)^\s+sprite = .*\.\.")

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
        # Losing access takes the button away and shuts the window with it.
        self.assertRegex(
            gui,
            re.compile(
                r"function AiBlueprintGui\.update\(player\).*?"
                r"if not available\(player\) then.*?button\.destroy\(\).*?"
                r"close_window\(player\)",
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
        body = block(gui, "local function inbox_records(player_index)")
        self.assertNotIn("Blueprints.save", body)
        self.assertNotRegex(body, r"inbox\.(order|by_id|bytes)\s*=")
        self.assertNotRegex(body, r"table\.(insert|remove)")
        # Nothing in the module writes to another player's data or walks the
        # whole player table.
        self.assertNotIn("Blueprints.save", gui)
        self.assertNotRegex(gui, r"for .* in pairs\(game\.players\)")

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
