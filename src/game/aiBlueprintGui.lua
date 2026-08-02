local State = require("src.core.state")
local AiConstants = require("src.core.aiConstants")
local Blueprints = require("src.game.aiBlueprints")

local AiBlueprintGui = {}

local BUTTON_NAME = "sceatorio_ai_blueprint_button"
local ACTION_TOGGLE = "sceatorio_ai_blueprints_toggle"

-- The window is Factorio's own inventory GUI, opened on a mod-owned inventory:
-- the engine draws every slot, every blueprint preview, every tooltip and the
-- whole drag-and-pick-up behaviour, so nothing here imitates a slot.
-- aiBlueprints caps an inbox at 100 records; the inventory is resized down to
-- the records actually stored, so this is only the ceiling.
local MAX_SLOTS = 100
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
local function inbox_records(player_index)
  local root = State.get()
  local ai = root and root.ai or nil
  local inboxes = ai and ai.blueprint_inbox or nil
  local inbox = type(inboxes) == "table" and inboxes[player_index] or nil
  if type(inbox) ~= "table"
    or type(inbox.order) ~= "table"
    or type(inbox.by_id) ~= "table" then return {} end
  local records = {}
  -- Storage keeps the inbox oldest-first; walk it backwards for newest-first.
  for index = #inbox.order, 1, -1 do
    local record = inbox.by_id[inbox.order[index]]
    if type(record) == "table" and type(record.revisions) == "table" then
      records[#records + 1] = record
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

local function owned_names(records)
  local names = {}
  for _, record in ipairs(records) do
    if type(record.name) == "string" then names[record.name] = true end
  end
  return names
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

-- Anything the player drops into this window is theirs, so it goes straight
-- back to them instead of being destroyed by the next rebuild. The blueprints
-- this module put there are the one exception: they are copies of records still
-- sitting in the inbox, and the next open rebuilds them for free.
local function reclaim(player, inventory, owned)
  local returned = 0
  for slot = 1, #inventory do
    local stack = inventory[slot]
    if stack.valid_for_read then
      local label = stack.name == "blueprint" and stack_label(stack) or nil
      if not (label and owned[label]) then
        give_back(player, stack)
        returned = returned + 1
      end
    end
  end
  if returned > 0 then
    player.print({"gui.sceatorio-ai-blueprints-returned", returned})
  end
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

local function write_stack(player, stack, blueprint_id)
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

-- Rebuilt on every open, so the window always shows the live inbox and never
-- becomes storage of its own. Bounded twice: by the caller's own inbox and by
-- MAX_SLOTS.
local function fill(player, inventory)
  local records = inbox_records(player.index)
  reclaim(player, inventory, owned_names(records))
  inventory.clear()
  local count = math.max(1, math.min(#records, MAX_SLOTS))
  pcall(function() inventory.resize(count) end)
  local failures = 0
  for index = 1, math.min(#records, count) do
    if not write_stack(player, inventory[index], records[index].id) then
      failures = failures + 1
    end
  end
  if failures > 0 then
    player.print({"gui.sceatorio-ai-blueprints-failed", failures})
  end
  return #records
end

local function is_open(player, inventory)
  if player.opened_gui_type ~= defines.gui_type.script_inventory then return false end
  return player.opened == inventory
end

-- Closing hands back whatever the player left and empties the window: every
-- blueprint in it is a copy the next open rebuilds, so nothing is kept here
-- between opens and the inbox stays the single source of truth.
local function release(player, inventory)
  reclaim(player, inventory, owned_names(inbox_records(player.index)))
  inventory.clear()
end

local function close_window(player)
  local inventory = stored_inventory(player.index)
  if not inventory then return end
  if is_open(player, inventory) then player.opened = nil end
  release(player, inventory)
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

local function ensure_button(player)
  local button = player.gui.screen[BUTTON_NAME]
  if button and button.valid then return button end
  local sprite = button_sprite()
  button = player.gui.screen.add(sprite and {
    type = "sprite-button",
    name = BUTTON_NAME,
    sprite = sprite,
    tooltip = {"gui.sceatorio-ai-blueprints-button"},
    tags = {sceatorio_action = ACTION_TOGGLE}
  } or {
    type = "button",
    name = BUTTON_NAME,
    caption = {"gui.sceatorio-ai-blueprints-button"},
    tooltip = {"gui.sceatorio-ai-blueprints-button"},
    tags = {sceatorio_action = ACTION_TOGGLE}
  })
  style(button, {width = BUTTON_SIZE, height = BUTTON_SIZE})
  return button
end

function AiBlueprintGui.update(player)
  if not (player and player.valid) then return end
  if not available(player) then
    local button = player.gui.screen[BUTTON_NAME]
    if button and button.valid then button.destroy() end
    close_window(player)
    return
  end
  position_button(player, ensure_button(player))
end

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
  if event.inventory ~= nil and event.inventory ~= inventory then return end
  release(player, inventory)
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
