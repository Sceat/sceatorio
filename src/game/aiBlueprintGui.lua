local State = require("src.core.state")
local AiConstants = require("src.core.aiConstants")
local Blueprints = require("src.game.aiBlueprints")

local AiBlueprintGui = {}

local BUTTON_NAME = "sceatorio_ai_blueprint_button"
local ACTION_TOGGLE = "sceatorio_ai_blueprints_toggle"

-- The window is Factorio's own inventory GUI, opened on a mod-owned inventory:
-- the engine draws every slot, every blueprint preview, every tooltip and the
-- whole drag-and-pick-up behaviour, so nothing here imitates a slot. It is not
-- a viewer: while it is open the window IS the inbox, so a blueprint or book
-- carried out of it is removed from the inbox when it closes -- a book only as
-- a grouping, never taking its member blueprints with it.
-- aiBlueprints caps an inbox at 100 blueprints and 20 books; the inventory is
-- resized down to the records actually stored, so this is only the ceiling --
-- but it has to cover both collections at once, or grouping blueprints into a
-- book would silently push the oldest blueprints out of the window. 20 + 100 is
-- exactly this ceiling, and hiding a book's members only ever shrinks the set
-- below it, so the truncation this bounds cannot happen -- it stays as the
-- defence that makes an unrenderable record unreachable by the close.
local MAX_SLOTS = 120
local BUTTON_SIZE = 40
local GAP = 8
-- The player list owns the upper-left corner; these mirror its own geometry so
-- the inbox button docks beside that panel instead of on top of it.
local PLAYER_PANEL_NAME = "sceatorio_player_panel"
local PLAYER_PANEL_FALLBACK_WIDTH = 340
local PLAYER_PANEL_LEFT_OFFSET = 8
-- Only a fallback: the live panel position wins whenever the panel exists, and
-- the player list now hugs the free upper-left corner instead of clearing a
-- status button that no longer exists.
local PLAYER_PANEL_TOP_OFFSET = 8

-- The technology icon is not a declared sprite prototype, but the engine
-- publishes prototype-backed sprite paths; the first path that the running
-- Factorio accepts wins, so a missing graphic degrades instead of crashing.
local BUTTON_SPRITES = {
  "technology/" .. AiConstants.TECHNOLOGY,
  "item/" .. AiConstants.UPLINK,
  "utility/side_menu_blueprint_library_icon"
}

-- A LuaStyle only carries the keys its own style prototype defines, and touching
-- an absent key raises instead of returning nil. LuaStyle.width is worse still:
-- it is write-only, so reading it always raises. Every style access therefore
-- goes through pcall, so a style the running Factorio does not expose degrades
-- into the fallback instead of killing the event that touched it.
local function style(element, values)
  for key, value in pairs(values) do
    pcall(function() element.style[key] = value end)
  end
end

local function style_number(element, key)
  local ok, value = pcall(function() return element.style[key] end)
  if ok and type(value) == "number" and value > 0 then return value end
  return nil
end

local function ai_enabled()
  local setting = settings.global["sceatorio-ai-enabled"]
  return (setting and setting.value) == true
end

local function technology_researched(force)
  if not (force and force.valid) then return false end
  local technology = force.technologies[AiConstants.TECHNOLOGY]
  return technology ~= nil and technology.researched
end

local function available(player)
  return player ~= nil and player.valid
    and ai_enabled()
    and technology_researched(player.force)
end

-- The only sprite this module still draws is the toolbar button, and it is
-- prototype-derived: an unknown prototype must degrade to the next candidate,
-- never raise inside the tick that drew it.
local function first_valid_sprite(paths)
  for _, path in ipairs(paths) do
    local ok, valid = pcall(helpers.is_valid_sprite_path, path)
    if ok and valid then return path end
  end
  return nil
end

local function button_sprite()
  return first_valid_sprite(BUTTON_SPRITES)
end

-- Read-only view of the same storage Blueprints owns. The GUI never creates or
-- mutates an inbox and never looks outside the viewer's own player index.
-- Books come first because they are the coarser thing to reach for, and both
-- kinds are flattened into one list of {id, name} so every slot below is
-- written the same way; the ID prefix is what tells the two apart.
-- A blueprint filed in a book is reached by opening that book, so listing it
-- flat as well would show the same saved blueprint twice. The flat run is
-- therefore the bookless remainder: every book, then the blueprints no book
-- holds. The MCP catalog is untouched by this -- list_ai_blueprints stays the
-- complete flat truth plus the books array, because that is what tooling reads.
local function inbox_records(player_index)
  local root = State.get()
  local ai = root and root.ai or nil
  local inboxes = ai and ai.blueprint_inbox or nil
  local inbox = type(inboxes) == "table" and inboxes[player_index] or nil
  if type(inbox) ~= "table"
    or type(inbox.order) ~= "table"
    or type(inbox.by_id) ~= "table" then return {} end
  local records = {}
  -- Filled by the book walk below and read by the flat walk after it, so a
  -- blueprint is only ever hidden by a book that this same open really renders:
  -- a malformed book is skipped, and its members stay visible rather than
  -- becoming unreachable. Recomputed from live storage every open, which is why
  -- deleting a book un-hides its members with no bookkeeping at all.
  local in_a_book = {}
  -- Storage keeps both collections oldest-first; walk them backwards for
  -- newest-first. Books are rebuilt from their live member list on every open,
  -- so a book edited since the last open renders with its current pages.
  if type(inbox.book_order) == "table" and type(inbox.books) == "table" then
    for index = #inbox.book_order, 1, -1 do
      local book = inbox.books[inbox.book_order[index]]
      if type(book) == "table" and type(book.members) == "table" then
        records[#records + 1] = {id = book.id, name = book.name}
        -- Membership, never a count: a blueprint two books name is marked once
        -- here, stays out of the flat run once, and still appears inside both
        -- books. Bounded by storage's own caps -- 20 books of at most 50 members.
        for _, member_id in ipairs(book.members) do in_a_book[member_id] = true end
      end
    end
  end
  for index = #inbox.order, 1, -1 do
    local id = inbox.order[index]
    if not in_a_book[id] then
      local record = inbox.by_id[id]
      if type(record) == "table" and type(record.revisions) == "table" then
        records[#records + 1] = {id = record.id, name = record.name}
      end
    end
  end
  return records
end

-- Script inventories survive save/load, so their handles live in the same state
-- root as everything else this mod owns: one inventory per player, created on
-- first open and destroyed when the player is removed.
local function inventories()
  local root = State.get()
  if type(root) ~= "table" then return nil end
  root.ai_blueprint_inventories = root.ai_blueprint_inventories or {}
  return root.ai_blueprint_inventories
end

-- What this window put in front of one player, by blueprint label: the count of
-- our own stacks that carry it and, when exactly one record does, that record's
-- id. Written only by a successful fill, read only by the close that follows,
-- and stored beside the inventory so an open window survives save/load. A name
-- carried by two records has no id here, which is what makes an ambiguous
-- removal keep both records instead of guessing.
local function manifests()
  local root = State.get()
  if type(root) ~= "table" then return nil end
  root.ai_blueprint_manifests = root.ai_blueprint_manifests or {}
  return root.ai_blueprint_manifests
end

local function stored_manifest(player_index)
  local store = manifests()
  local manifest = store and store[player_index] or nil
  if type(manifest) == "table" then return manifest end
  return {}
end

local function forget_manifest(player_index)
  local store = manifests()
  if store then store[player_index] = nil end
end

local function stored_inventory(player_index)
  local store = inventories()
  local inventory = store and store[player_index] or nil
  if inventory ~= nil and inventory.valid then return inventory end
  if store then store[player_index] = nil end
  return nil
end

local function ensure_inventory(player)
  local store = inventories()
  if not store then return nil end
  local existing = stored_inventory(player.index)
  if existing then return existing end
  -- gui_title is what Factorio prints on the window it draws for this
  -- inventory, so the engine window carries our name without a custom frame.
  -- An engine that rejects the title still gets a working window.
  local created
  local ok = pcall(function()
    created = game.create_inventory(MAX_SLOTS, {"gui.sceatorio-ai-blueprints-title"})
  end)
  if not ok or created == nil or not created.valid then
    created = nil
    ok = pcall(function() created = game.create_inventory(MAX_SLOTS) end)
    if not ok or created == nil or not created.valid then return nil end
  end
  store[player.index] = created
  return created
end

local function stack_label(stack)
  local ok, label = pcall(function() return stack.label end)
  if ok and type(label) == "string" then return label end
  return nil
end

local function spill(player, stack)
  pcall(function()
    player.surface.spill_item_stack({
      position = player.position,
      stack = stack,
      enable_looted = false,
      force = player.force,
      allow_belts = false
    })
  end)
end

-- Everything the player's own inventory refuses lands at their feet instead of
-- in the next wipe. A whole stack is spilled as the live item so a blueprint
-- keeps its contents; only a partially accepted stack falls back to a plain
-- remainder, which by definition holds no per-item data.
local function give_back(player, stack)
  local count = stack.count
  local moved = 0
  pcall(function() moved = player.insert(stack) end)
  if moved >= count then return end
  if moved <= 0 then
    spill(player, stack)
    return
  end
  local remainder = count - moved
  local quality
  pcall(function() quality = stack.quality end)
  spill(player, {name = stack.name, count = remainder, quality = quality})
end

-- One walk over the window that does both jobs at once. Anything the player
-- dropped in here is theirs, so it goes straight back to them instead of being
-- destroyed by the next wipe; the stacks this module wrote are recognised by
-- the manifest and counted, and that count is what tells the caller which
-- records the player carried out. Returns nil if the walk failed, which is the
-- caller's signal to keep every record and every stack untouched.
local function reclaim(player, inventory, manifest)
  local present = {}
  local returned = 0
  local walked = pcall(function()
    for slot = 1, #inventory do
      local stack = inventory[slot]
      if stack.valid_for_read then
        -- Both kinds this window writes are recognised by their label, and both
        -- share one manifest namespace on purpose: a book and a blueprint that
        -- carry the same name make each other ambiguous, which is exactly the
        -- rule that already keeps two same-named blueprints.
        local ours = stack.name == "blueprint" or stack.name == "blueprint-book"
        local label = ours and stack_label(stack) or nil
        local entry = label and manifest[label] or nil
        local seen = label and present[label] or 0
        if entry and seen < entry.count then
          present[label] = seen + 1
        else
          give_back(player, stack)
          returned = returned + 1
        end
      end
    end
  end)
  if returned > 0 then
    player.print({"gui.sceatorio-ai-blueprints-returned", returned})
  end
  if not walked then return nil end
  return present
end

-- aiBlueprints owns the only conversion from a stored layout into a real
-- blueprint item -- temporary inventory, contents before label and description,
-- every module, filter and control behavior. This module must never rebuild
-- that, so it passes a delivery sink in place of the player: the finished stack
-- is copied into our own slot instead of the clipboard queue. set_stack copies
-- the item, so the temporary inventory aiBlueprints destroys right after is
-- never aliased.
local function slot_sink(player, stack)
  return {
    valid = true,
    connected = player.connected,
    add_to_clipboard = function(source)
      stack.set_stack(source)
    end
  }
end

-- A book reaches the player as a real blueprint-book item, built by the same
-- module and handed to the same sink: aiBlueprints fills the book's pages from
-- the members it still owns and this window only receives the finished stack.
local function write_book(player, stack, book_id)
  local ok, result, code, message = pcall(function()
    return Blueprints.load_book(
      {
        player = slot_sink(player, stack),
        player_index = player.index,
        allow_cursor = true
      },
      book_id,
      "cursor"
    )
  end)
  if ok and result then return true end
  log("[Sceatorio] AI blueprint window could not rebuild "
    .. tostring(book_id) .. ": " .. tostring(message or code or result))
  return false
end

local function write_stack(player, stack, blueprint_id)
  -- The ID namespace is the record kind: aiBlueprints owns both, so the window
  -- asks it rather than parsing the string itself.
  if Blueprints.is_book_id(blueprint_id) then return write_book(player, stack, blueprint_id) end
  local ok, result, code, message = pcall(function()
    return Blueprints.load(
      {
        player = slot_sink(player, stack),
        player_index = player.index,
        allow_cursor = true
      },
      blueprint_id,
      nil,
      "cursor"
    )
  end)
  if ok and result then return true end
  log("[Sceatorio] AI blueprint window could not rebuild "
    .. tostring(blueprint_id) .. ": " .. tostring(message or code or result))
  return false
end

-- Rebuilt on every open from the live inbox, and the manifest is built with it.
-- A record only enters the manifest once its stack really landed in a slot, so
-- a rebuild that failed and a record past MAX_SLOTS are simply not in it -- and
-- what is not in the manifest is never deleted by the close. Bounded twice: by
-- the caller's own inbox and by MAX_SLOTS.
-- This loop is the ONLY writer of a manifest entry's id, and it can only ever
-- write an id inbox_records returned. That is what makes hiding a book's
-- members safe: a hidden member is not in `records`, so its id never reaches
-- the manifest, so release -- which deletes nothing but `entry.id` -- has no
-- way to name it. Never rendered is never deletable, by construction.
local function fill(player, inventory)
  local records = inbox_records(player.index)
  local walked = reclaim(player, inventory, stored_manifest(player.index))
  forget_manifest(player.index)
  -- A walk that failed leaves the window exactly as it is: wiping it could
  -- destroy an item that was never handed back.
  if not walked then return #records end
  inventory.clear()
  local count = math.max(1, math.min(#records, MAX_SLOTS))
  pcall(function() inventory.resize(count) end)
  local manifest = {}
  local failures = 0
  for index = 1, math.min(#records, count) do
    local record = records[index]
    if not write_stack(player, inventory[index], record.id) then
      failures = failures + 1
    elseif type(record.name) == "string" then
      local entry = manifest[record.name]
      if entry then
        entry.count = entry.count + 1
        entry.id = nil
      else
        manifest[record.name] = {count = 1, id = record.id}
      end
    end
  end
  if failures > 0 then
    player.print({"gui.sceatorio-ai-blueprints-failed", failures})
  end
  local store = manifests()
  if store then store[player.index] = manifest end
  return #records
end

local function is_open(player, inventory)
  if player.opened_gui_type ~= defines.gui_type.script_inventory then return false end
  return player.opened == inventory
end

-- Closing is the moment the window becomes the truth. It hands back whatever
-- the player left, and -- only when the engine told us this very window closed
-- (reconcile) -- deletes the records whose blueprint the player carried out.
-- Every uncertainty keeps the record: a walk that failed leaves the window and
-- the inbox exactly as they were, a name two records share is never guessed at,
-- and removal itself goes through Blueprints.delete, which owns the inbox.
local function release(player, inventory, reconcile)
  local manifest = stored_manifest(player.index)
  local present = reclaim(player, inventory, manifest)
  if not present then return end
  if reconcile then
    local removed = 0
    local removed_books = 0
    local ambiguous = 0
    -- Unordered on purpose: each removal takes one distinct id out of by_id and
    -- out of order, so the inbox this loop leaves behind is the same set
    -- whatever order pairs hands them over in.
    for name, entry in pairs(manifest) do
      if (present[name] or 0) < entry.count then
        if entry.id ~= nil and entry.count == 1 then
          -- A book carried out leaves the inbox as a grouping only: its member
          -- blueprints are separate records and stay exactly where they were.
          if Blueprints.is_book_id(entry.id) then
            local ok, deleted = pcall(Blueprints.delete_book, {player_index = player.index}, entry.id)
            if ok and deleted then removed_books = removed_books + 1 end
          else
            local ok, deleted = pcall(Blueprints.delete, {player_index = player.index}, entry.id)
            if ok and deleted then removed = removed + 1 end
          end
        else
          ambiguous = ambiguous + 1
        end
      end
    end
    if removed > 0 then
      player.print({"gui.sceatorio-ai-blueprints-removed", removed})
    end
    if removed_books > 0 then
      player.print({"gui.sceatorio-ai-blueprints-book-removed", removed_books})
    end
    if ambiguous > 0 then
      player.print({"gui.sceatorio-ai-blueprints-ambiguous", ambiguous})
    end
  end
  forget_manifest(player.index)
  inventory.clear()
end

-- Losing access is not the player deciding to file a blueprint away, so this
-- path empties the window without deleting anything.
local function close_window(player)
  local inventory = stored_inventory(player.index)
  if not inventory then return end
  if is_open(player, inventory) then player.opened = nil end
  release(player, inventory, false)
end

local function position_button(player, button)
  local scale = player.display_scale > 0 and player.display_scale or 1
  local panel = player.gui.screen[PLAYER_PANEL_NAME]
  local x, y
  if panel and panel.valid then
    -- The player list sets its panel through LuaStyle.width, which mirrors onto
    -- minimal_width; that is the readable half of the same value.
    local width = style_number(panel, "minimal_width") or PLAYER_PANEL_FALLBACK_WIDTH
    x = panel.location.x + math.floor((width + GAP) * scale)
    y = panel.location.y
  else
    x = math.floor((PLAYER_PANEL_LEFT_OFFSET + PLAYER_PANEL_FALLBACK_WIDTH + GAP) * scale)
    y = math.floor(PLAYER_PANEL_TOP_OFFSET * scale)
  end
  local limit = player.display_resolution.width - math.floor(BUTTON_SIZE * scale)
  button.location = {x = math.max(0, math.min(x, limit)), y = y}
end

-- GUI elements live in the save, not in mod storage, so deleting the code that
-- drew a frame never removes the frames an older version already put on a
-- player's screen. 2.3.0 replaced this module's custom frame with the engine's
-- inventory window and left every pre-2.3.0 save carrying that frame: no
-- caption, no working close button, and nothing left to dispatch its clicks.
-- Every element name this module has ever created and no longer owns dies here,
-- on load and on join, the same way playerList reaps its own leftovers.
-- sceatorio_robot_policy_frame is NOT ours and is still a live feature.
local LEGACY_SCREEN_NAMES = {"sceatorio_ai_blueprint_frame"}

local function destroy_legacy(player)
  for _, name in ipairs(LEGACY_SCREEN_NAMES) do
    local element = player.gui.screen[name]
    if element and element.valid then element.destroy() end
  end
end

local function ensure_button(player)
  local button = player.gui.screen[BUTTON_NAME]
  if button and button.valid then return button end
  local sprite = button_sprite()
  button = player.gui.screen.add(sprite and {
    type = "sprite-button",
    name = BUTTON_NAME,
    sprite = sprite,
    tooltip = {"gui.sceatorio-ai-blueprints-tooltip"},
    tags = {sceatorio_action = ACTION_TOGGLE}
  } or {
    type = "button",
    name = BUTTON_NAME,
    caption = {"gui.sceatorio-ai-blueprints-button"},
    tooltip = {"gui.sceatorio-ai-blueprints-tooltip"},
    tags = {sceatorio_action = ACTION_TOGGLE}
  })
  style(button, {width = BUTTON_SIZE, height = BUTTON_SIZE})
  return button
end

function AiBlueprintGui.update(player)
  if not (player and player.valid) then return end
  -- First, and whatever this player's access is: a leftover frame from an older
  -- Sceatorio must not survive this load or this join.
  destroy_legacy(player)
  if not available(player) then
    local button = player.gui.screen[BUTTON_NAME]
    if button and button.valid then button.destroy() end
    close_window(player)
    return
  end
  position_button(player, ensure_button(player))
end

-- Runs on every load and configuration change, so this is where a save made by
-- an older Sceatorio gets its leftover frames reaped: update does that for each
-- connected player before it looks at access, and on_player_joined covers
-- everyone who was offline when the mod changed.
function AiBlueprintGui.initialize()
  for _, player in pairs(game.connected_players) do AiBlueprintGui.update(player) end
end

function AiBlueprintGui.toggle(player)
  if not available(player) then
    AiBlueprintGui.update(player)
    return
  end
  local inventory = ensure_inventory(player)
  if not inventory then return end
  if is_open(player, inventory) then
    player.opened = nil
    return
  end
  if fill(player, inventory) == 0 then
    player.print({"gui.sceatorio-ai-blueprints-empty"})
    return
  end
  -- The engine draws it from here: real item stacks, real blueprint previews,
  -- real hover, drag and pick-up, exactly like the blueprint library.
  player.opened = inventory
end

local function update_force(force)
  if not (force and force.valid) then return end
  for _, player in pairs(force.connected_players) do AiBlueprintGui.update(player) end
end

function AiBlueprintGui.on_player_joined(event)
  AiBlueprintGui.update(game.get_player(event.player_index))
end

function AiBlueprintGui.on_player_changed_force(event)
  AiBlueprintGui.update(game.get_player(event.player_index))
end

function AiBlueprintGui.on_display_changed(event)
  AiBlueprintGui.update(game.get_player(event.player_index))
end

function AiBlueprintGui.on_player_removed(event)
  local store = inventories()
  if not store then return end
  local inventory = store[event.player_index]
  store[event.player_index] = nil
  if inventory ~= nil and inventory.valid then inventory.destroy() end
end

function AiBlueprintGui.on_gui_closed(event)
  if event.gui_type ~= defines.gui_type.script_inventory then return end
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return end
  local inventory = stored_inventory(player.index)
  if not inventory then return end
  -- Deleting is driven by one thing only: the engine naming THIS inventory as
  -- the one that just closed for THIS player. A close it does not identify
  -- still empties the window, but never removes a record.
  local closed = event.inventory
  if closed ~= nil and closed ~= inventory then return end
  release(player, inventory, closed == inventory)
end

function AiBlueprintGui.on_research_finished(event)
  local research = event.research
  if not (research and research.valid) then return end
  if research.name ~= AiConstants.TECHNOLOGY then return end
  update_force(research.force)
end

function AiBlueprintGui.on_setting_changed(event)
  if event.setting ~= "sceatorio-ai-enabled" then return end
  AiBlueprintGui.initialize()
end

function AiBlueprintGui.on_gui_click(event)
  local element = event.element
  if not (element and element.valid) then return false end
  local tags = element.tags or {}
  if tags.sceatorio_action ~= ACTION_TOGGLE then return false end
  local player = game.get_player(event.player_index)
  if player and player.valid then AiBlueprintGui.toggle(player) end
  return true
end

return AiBlueprintGui
