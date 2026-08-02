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
        self.assertIn("release(player, inventory,", closed)

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
        reclaim = block(gui, "local function reclaim(player, inventory, manifest)")
        self.assertIn("give_back(player, stack)", reclaim)
        # Ownership is decided by the label of a blueprint this window wrote.
        self.assertIn('stack.name == "blueprint"', reclaim)
        self.assertIn("manifest[label]", reclaim)
        # And the return is announced: nothing disappears silently.
        self.assertIn('player.print({"gui.sceatorio-ai-blueprints-returned"', reclaim)
        # Release runs the same reclaim before emptying the window.
        release = block(gui, "local function release(player, inventory, reconcile)")
        self.assertLess(release.index("reclaim("), release.index("inventory.clear()"))

    def test_taking_a_blueprint_out_deletes_its_record(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        release = block(gui, "local function release(player, inventory, reconcile)")
        # Removal goes through the module that owns the inbox; the window never
        # edits storage itself.
        self.assertIn(
            "pcall(Blueprints.delete, {player_index = player.index}, entry.id)",
            release,
        )
        self.assertIn('player.print({"gui.sceatorio-ai-blueprints-removed"', release)
        # Only the engine naming this exact inventory reconciles; every other
        # close path empties the window without deleting anything.
        closed = block(gui, "function AiBlueprintGui.on_gui_closed(event)")
        self.assertIn("local closed = event.inventory", closed)
        self.assertIn("if closed ~= nil and closed ~= inventory then return end", closed)
        self.assertIn("release(player, inventory, closed == inventory)", closed)
        self.assertIn(
            "release(player, inventory, false)",
            block(gui, "local function close_window(player)"),
        )

    def test_deletion_is_refused_whenever_the_window_is_not_certain(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        # A walk that raised returns nil, and release stops before reconciling
        # or clearing: the records and the stacks both stay.
        reclaim = block(gui, "local function reclaim(player, inventory, manifest)")
        self.assertIn("local walked = pcall(function()", reclaim)
        self.assertIn("if not walked then return nil end", reclaim)
        release = block(gui, "local function release(player, inventory, reconcile)")
        self.assertLess(release.index("if not present then return end"), release.index("if reconcile then"))
        self.assertLess(release.index("if not present then return end"), release.index("Blueprints.delete"))
        # A record only becomes deletable once its stack really landed in a
        # slot, so a failed rebuild and anything past MAX_SLOTS are never in the
        # manifest at all.
        fill = block(gui, "local function fill(player, inventory)")
        self.assertRegex(
            fill,
            re.compile(
                r"if not write_stack\(player, inventory\[index\], record\.id\) then\s+"
                r"failures = failures \+ 1\s+"
                r"elseif type\(record\.name\) == \"string\" then",
                re.S,
            ),
        )
        # A name two records share carries no id, which is what keeps both.
        self.assertIn("entry.id = nil", fill)
        self.assertIn("if entry.id ~= nil and entry.count == 1 then", release)
        self.assertIn('player.print({"gui.sceatorio-ai-blueprints-ambiguous"', release)
        # And an invalid handle never reaches any of it.
        closed = block(gui, "function AiBlueprintGui.on_gui_closed(event)")
        self.assertLess(
            closed.index("stored_inventory(player.index)"),
            closed.index("release(player, inventory,"),
        )
        self.assertIn("if not inventory then return end", closed)

    def test_books_are_real_book_items_built_by_the_blueprint_module(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        blueprints = source("src/game/aiBlueprints.lua")
        # The window asks aiBlueprints for the finished book stack through the
        # same sink it already uses for a blueprint; it never assembles one.
        book = block(gui, "local function write_book(player, stack, book_id)")
        self.assertIn("Blueprints.load_book(", book)
        self.assertIn("player = slot_sink(player, stack),", book)
        self.assertIn("player_index = player.index,", book)
        # Assembling the item -- creating the book stack, reaching into its page
        # inventory, filling the pages -- belongs to aiBlueprints alone.
        for owned in ("get_inventory", "defines.inventory", 'name = "blueprint-book"'):
            self.assertNotIn(owned, gui)
        for owned in ("set_stack", "get_inventory", "insert("):
            self.assertNotIn(owned, book)
        # The record kind lives in the ID namespace, and the module that owns
        # both IDs is the one that answers which kind an ID is.
        self.assertIn("Blueprints.is_book_id(blueprint_id)", block(gui, "local function write_stack(player, stack, blueprint_id)"))
        self.assertNotRegex(gui, r'string\.(sub|match|find)\(')

        # Factorio 2.1 exposes a book's pages as an ordinary inventory on the
        # item stack; each page is written by the single emitter this module
        # already owns, so a page and a delivered blueprint cannot drift apart.
        deliver = block(blueprints, "local function deliver_book(player, book, layouts)")
        self.assertIn('stack.set_stack({name = "blueprint-book", count = 1})', deliver)
        self.assertIn("stack.get_inventory(defines.inventory.item_main)", deliver)
        self.assertIn('pages.insert({name = "blueprint", count = 1})', deliver)
        self.assertIn("deliver_to_clipboard(page_sink(page), layout)", deliver)
        self.assertNotIn("set_blueprint_entities", deliver)
        # Every step is fail-closed: a page the engine refuses aborts the whole
        # delivery instead of handing over a half-built book.
        self.assertIn("local ok, reason = pcall(function()", deliver)
        self.assertIn("if not written then error(", deliver)
        self.assertIn("inventory.destroy()", deliver)
        self.assertIn('"BLUEPRINT_BOOK_DELIVERY_FAILED"', deliver)
        # Naming a book is cosmetic and must never fail its delivery.
        self.assertIn("pcall(function() stack.label = book.name end)", deliver)

    def test_a_book_edited_since_the_last_open_renders_its_current_pages(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        blueprints = source("src/game/aiBlueprints.lua")
        # Nothing about a book is cached in the window: fill rebuilds the record
        # list on every open, and the stack is rebuilt from the live member list
        # each time, so an edit made between two opens is what the player sees.
        records = block(gui, "local function inbox_records(player_index)")
        self.assertIn("inbox.book_order", records)
        self.assertIn("records[#records + 1] = {id = book.id, name = book.name}", records)
        self.assertNotRegex(records, r"members\s*=")
        load = blueprints[
            blueprints.index("function Blueprints.load_book") :
            blueprints.index("function Blueprints.update_book")
        ]
        self.assertIn("local book = inbox.books[book_id]", load)
        self.assertIn("for _, member_id in ipairs(book.members) do", load)
        self.assertIn("local record = inbox.by_id[member_id]", load)
        # A member whose record is gone is simply not a page.
        self.assertIn("if record then layouts[#layouts + 1]", load)
        self.assertNotIn("cache", gui)

    def test_carrying_a_book_out_never_deletes_the_blueprints_inside_it(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        blueprints = source("src/game/aiBlueprints.lua")
        release = block(gui, "local function release(player, inventory, reconcile)")
        # The window removes exactly one record kind per manifest entry, chosen
        # by the ID namespace, and a book removal goes through the book delete.
        self.assertIn("Blueprints.is_book_id(entry.id)", release)
        self.assertIn(
            "pcall(Blueprints.delete_book, {player_index = player.index}, entry.id)",
            release,
        )
        self.assertIn('player.print({"gui.sceatorio-ai-blueprints-book-removed"', release)
        # Both kinds still obey the ambiguity rule: an entry that lost its ID
        # because two records share a name deletes nothing at all.
        self.assertIn("if entry.id ~= nil and entry.count == 1 then", release)
        # A book stack is recognised by label like a blueprint stack is, in the
        # same manifest namespace, so a book and a blueprint sharing a name make
        # each other ambiguous instead of guessing.
        reclaim = block(gui, "local function reclaim(player, inventory, manifest)")
        self.assertIn('stack.name == "blueprint-book"', reclaim)
        self.assertIn("manifest[label]", reclaim)
        # And the module keeps the promise the window's message makes.
        delete_book = blueprints[blueprints.index("function Blueprints.delete_book"):]
        delete_book = delete_book[: delete_book.index("\nend\n")]
        self.assertNotIn("inbox.by_id", delete_book)
        self.assertIn("releasedMemberCount = #book.members", delete_book)

    def test_books_render_first_and_their_members_leave_the_flat_list(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        records = block(gui, "local function inbox_records(player_index)")
        # Books are appended before the flat run, so every book precedes every
        # bookless blueprint in the rendered order.
        self.assertLess(
            records.index("records[#records + 1] = {id = book.id, name = book.name}"),
            records.index("for index = #inbox.order, 1, -1 do"),
        )
        # Both groups walk their own order table backwards: newest first, which
        # is the only ordering either loop can produce.
        self.assertIn("for index = #inbox.book_order, 1, -1 do", records)
        self.assertIn("for index = #inbox.order, 1, -1 do", records)
        # Membership is collected from the books this open really renders -- the
        # marking sits inside the same guard that decided to render the book, so
        # a malformed book hides nothing and its members stay visible.
        self.assertRegex(
            records,
            re.compile(
                r'if type\(book\) == "table" and type\(book\.members\) == "table" then\s+'
                r"records\[#records \+ 1\] = \{id = book\.id, name = book\.name\}\s+"
                r"(?:--[^\n]*\n\s+)*"
                r"for _, member_id in ipairs\(book\.members\) do in_a_book\[member_id\] = true end",
                re.S,
            ),
        )
        # And the flat run is exactly the bookless remainder.
        self.assertIn("if not in_a_book[id] then", records)
        self.assertLess(
            records.index("if not in_a_book[id] then"),
            records.index("records[#records + 1] = {id = record.id, name = record.name}"),
        )

    def test_a_blueprint_in_two_books_is_hidden_once_and_still_in_both(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        records = block(gui, "local function inbox_records(player_index)")
        # Membership, not a reference count: the mark is a plain set write, so a
        # blueprint two books name is marked twice to the same value and drops
        # out of the flat run exactly once. Any counter here would be a bug --
        # decrementing it would put the blueprint back in the flat list while it
        # is still inside a book.
        self.assertIn("in_a_book[member_id] = true", records)
        self.assertEqual(
            re.findall(r"in_a_book\[[^\]]*\]\s*=\s*(\S+)", records),
            ["true"],
        )
        self.assertNotRegex(records, r"in_a_book\[[^\]]*\][^\n]*[-+]\s*1")
        # The books themselves are untouched by hiding: each still renders from
        # its own live member list, so the shared blueprint is a page in both.
        self.assertNotRegex(records, r"table\.(insert|remove)")
        self.assertIn("Blueprints.load_book(", gui)
        # Bounded by storage's caps, never a scan of the whole inbox per book.
        self.assertIn("for _, member_id in ipairs(book.members) do", records)
        self.assertNotIn("while", records)

    def test_deleting_a_book_unhides_its_members_with_no_bookkeeping(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        records = block(gui, "local function inbox_records(player_index)")
        # The membership set is a local rebuilt on every open from live storage
        # and never persisted, so a book deleted by the MCP tool or carried out
        # of this window simply is not in book_order the next time this runs, and
        # its blueprints reappear in the flat run on their own. Nothing has to
        # remember to un-hide them.
        self.assertIn("local in_a_book = {}", records)
        self.assertNotRegex(gui, r"(?<!local )in_a_book\s*=")
        for persisted in ("root.in_a_book", "State.set", "in_a_book)"):
            self.assertNotIn(persisted, gui)
        # fill re-derives the list on every open; nothing survives between two.
        fill = block(gui, "local function fill(player, inventory)")
        self.assertIn("local records = inbox_records(player.index)", fill)
        # And the module that owns the deletion keeps the members it grouped.
        blueprints = source("src/game/aiBlueprints.lua")
        delete_book = blueprints[blueprints.index("function Blueprints.delete_book"):]
        delete_book = delete_book[: delete_book.index("\nend\n")]
        self.assertNotIn("inbox.by_id", delete_book)
        self.assertIn("inbox.books[book_id] = nil", delete_book)

    def test_a_hidden_record_can_never_be_reached_by_the_delete_path(self) -> None:
        # THE property. Hiding a blueprint means its stack is never written into
        # the inventory, so a close that reconciled by "what is missing from the
        # inventory" would read every hidden member as carried out and delete the
        # player's saved work wholesale. It cannot, because reconciliation reads
        # the manifest and nothing else, and the manifest only ever learns an ID
        # that was rendered.
        gui = source("src/game/aiBlueprintGui.lua")
        fill = block(gui, "local function fill(player, inventory)")
        release = block(gui, "local function release(player, inventory, reconcile)")

        # 1. The manifest is written in exactly one place: fill's write loop.
        self.assertEqual(gui.count("store[player.index] = manifest"), 1)
        self.assertIn("store[player.index] = manifest", fill)
        self.assertEqual(len(re.findall(r"(?<!local )manifest\[[^\]]*\]\s*=", gui)), 1)
        self.assertIn("manifest[record.name] = {count = 1, id = record.id}", fill)

        # 2. The only ID that loop can store is one inbox_records handed it, and
        #    it stores it only after the stack really landed in a slot.
        self.assertEqual(
            sorted(set(re.findall(r"\bid = ([\w.]+)", fill))),
            ["nil", "record.id"],
        )
        self.assertIn("local record = records[index]", fill)
        self.assertRegex(
            fill,
            re.compile(
                r"if not write_stack\(player, inventory\[index\], record\.id\) then\s+"
                r"failures = failures \+ 1\s+"
                r'elseif type\(record\.name\) == "string" then',
                re.S,
            ),
        )

        # 3. Reconciliation deletes nothing but an ID it read out of that
        #    manifest -- no name lookup, no inbox walk, no second record list.
        self.assertIn("for name, entry in pairs(manifest) do", release)
        self.assertEqual(
            re.findall(r"Blueprints\.delete(?:_book)?, \{player_index = player\.index\}, ([\w.]+)", release),
            ["entry.id", "entry.id"],
        )
        # Those two are the module's only removal call sites, full stop.
        call_site = r"Blueprints\.delete(?:_book)?, \{player_index"
        self.assertEqual(len(re.findall(call_site, release)), 2)
        self.assertEqual(len(re.findall(call_site, gui)), 2)

        # 4. The close path never re-derives what the inbox holds, so it has no
        #    way to name a record this open chose not to render, and it never
        #    reaches into a book's members either.
        for unreachable in ("inbox_records", "inbox.by_id", "inbox.order", "in_a_book", "members"):
            self.assertNotIn(unreachable, release)
        closed = block(gui, "function AiBlueprintGui.on_gui_closed(event)")
        self.assertNotIn("inbox_records", closed)
        # members are read in exactly one place, and it is the render list.
        self.assertEqual(gui.count("book.members"), 2)
        self.assertIn("book.members", block(gui, "local function inbox_records(player_index)"))

    def test_the_window_never_edits_inbox_storage_itself(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        self.assertIn("Blueprints.delete", gui)
        # Only the module's own manifest is written here; the inbox tables are
        # never touched, only read.
        self.assertNotRegex(gui, r"inbox\.(order|by_id|bytes)\s*=")
        self.assertNotRegex(gui, r"by_id\[[^\]]*\]\s*=")
        self.assertNotIn("Blueprints.save", gui)

    def test_legacy_frames_from_older_versions_are_reaped(self) -> None:
        gui = source("src/game/aiBlueprintGui.lua")
        # GUI elements live in the save: 2.3.0 deleted the custom frame's code
        # but every older save still carries the frame itself, unclosable.
        self.assertIn(
            'local LEGACY_SCREEN_NAMES = {"sceatorio_ai_blueprint_frame"}',
            gui,
        )
        reaper = block(gui, "local function destroy_legacy(player)")
        self.assertIn("for _, name in ipairs(LEGACY_SCREEN_NAMES) do", reaper)
        self.assertIn("player.gui.screen[name]", reaper)
        # Every destroy is validity-guarded.
        for line in reaper.splitlines():
            if ".destroy()" in line:
                self.assertIn("element.valid", line)
        # The frame the robot policy still owns is not ours to reap.
        self.assertNotIn("sceatorio_robot_policy_frame", reaper)
        # It runs for every connected player on load and configuration change,
        # and for anyone who was offline when the mod changed, before the
        # feature-access gate can return early.
        update = block(gui, "function AiBlueprintGui.update(player)")
        self.assertLess(
            update.index("destroy_legacy(player)"),
            update.index("if not available(player) then"),
        )
        self.assertIn(
            "for _, player in pairs(game.connected_players) do AiBlueprintGui.update(player) end",
            block(gui, "function AiBlueprintGui.initialize()"),
        )
        self.assertIn(
            "AiBlueprintGui.update(game.get_player(event.player_index))",
            block(gui, "function AiBlueprintGui.on_player_joined(event)"),
        )
        # initialize is what on_configuration_changed runs.
        control = source("control.lua")
        self.assertRegex(
            control,
            re.compile(
                r"local function initialize_common\(\).*?AiBlueprintGui\.initialize\(\).*?"
                r"script\.on_configuration_changed\(function\(\).*?initialize_common\(\)",
                re.S,
            ),
        )

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
