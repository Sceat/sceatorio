local State = require("src.core.state")
local AiConstants = require("src.core.aiConstants")
local Blueprints = require("src.game.aiBlueprints")

local AiBlueprintGui = {}

local BUTTON_NAME = "sceatorio_ai_blueprint_button"
local FRAME_NAME = "sceatorio_ai_blueprint_frame"
-- The panel is a slot grid, not a list: six slots per row like the vanilla
-- blueprint book, two rows per page, so a full 100-blueprint inbox still builds
-- a constant number of elements per render.
local SLOT_COLUMNS = 6
local SLOTS_PER_PAGE = 12
local SLOT_SIZE = 48
local SLOT_LABEL_WIDTH = 88
local FRAME_WIDTH = 640
-- Vanilla shows at most four icons per blueprint; a sprite-button carries one
-- sprite, so the leading prototype becomes the slot icon and the rest of the
-- ranking is spelled out in the tooltip.
local MAX_ICONS = 4
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

local ACTION_TOGGLE = "sceatorio_ai_blueprints_toggle"
local ACTION_CLOSE = "sceatorio_ai_blueprints_close"
local ACTION_PAGE = "sceatorio_ai_blueprints_page"
local ACTION_LOAD = "sceatorio_ai_blueprints_load"

-- The technology icon is not a declared sprite prototype, but the engine
-- publishes prototype-backed sprite paths; the first path that the running
-- Factorio accepts wins, so a missing graphic degrades instead of crashing.
local BUTTON_SPRITES = {
  "technology/" .. AiConstants.TECHNOLOGY,
  "item/" .. AiConstants.UPLINK,
  "utility/side_menu_blueprint_library_icon"
}

-- Fallback for a slot whose entities resolve to no drawable prototype icon at
-- all: the panel still shows a blueprint-shaped slot instead of an empty one.
local GENERIC_SPRITES = {
  "item/blueprint",
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

-- Every sprite this panel draws is prototype-derived, so nothing may reach an
-- element before the running Factorio confirms it: an unknown prototype must
-- degrade to the next candidate, never raise inside the click that drew it.
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

-- A style NAME the running Factorio does not define raises inside add(), which
-- is the same crash class that bricked 2.1.0 through a style read. Retrying
-- without the style keeps the panel alive on an engine that renamed one.
local function add(parent, spec)
  if spec.style == nil then return parent.add(spec) end
  local ok, element = pcall(function() return parent.add(spec) end)
  if ok and element then return element end
  local plain = {}
  for key, value in pairs(spec) do
    if key ~= "style" then plain[key] = value end
  end
  return parent.add(plain)
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

local function destroy_frame(player)
  local frame = player.gui.screen[FRAME_NAME]
  if frame and frame.valid then frame.destroy() end
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

local function text(value)
  return type(value) == "string" and value or ""
end

local function number(value)
  return type(value) == "number" and value or 0
end

-- One pass over the stored layout yields everything a slot shows: the icon
-- ranking, the entity count and the tile footprint. The ranking is sorted by
-- count and then by prototype name, so the same record always draws the same
-- slot for every player.
local function summarize(layout)
  local counts = {}
  local names = {}
  local total = 0
  local min_x, min_y, max_x, max_y
  local entities = type(layout) == "table" and type(layout.entities) == "table"
    and layout.entities or {}
  for _, entity in ipairs(entities) do
    local prototype = type(entity) == "table" and entity.prototype or nil
    if type(prototype) == "string" then
      total = total + 1
      if counts[prototype] == nil then
        counts[prototype] = 0
        names[#names + 1] = prototype
      end
      counts[prototype] = counts[prototype] + 1
      local position = entity.position
      if type(position) == "table"
        and type(position.x) == "number" and type(position.y) == "number" then
        min_x = min_x and math.min(min_x, position.x) or position.x
        min_y = min_y and math.min(min_y, position.y) or position.y
        max_x = max_x and math.max(max_x, position.x) or position.x
        max_y = max_y and math.max(max_y, position.y) or position.y
      end
    end
  end
  table.sort(names, function(left, right)
    if counts[left] ~= counts[right] then return counts[left] > counts[right] end
    return left < right
  end)
  -- Stored positions are entity centers, so the tile span is the rounded
  -- distance between the outermost centers plus the entity they sit on.
  return {
    total = total,
    names = names,
    counts = counts,
    width = min_x and (math.floor(max_x - min_x + 0.5) + 1) or 0,
    height = min_y and (math.floor(max_y - min_y + 0.5) + 1) or 0
  }
end

local function slot_sprite(summary)
  for index = 1, math.min(#summary.names, MAX_ICONS) do
    local name = summary.names[index]
    local sprite = first_valid_sprite({"entity/" .. name, "item/" .. name})
    if sprite then return sprite end
  end
  return first_valid_sprite(GENERIC_SPRITES)
end

-- Prototype names are internal identifiers; the tooltip shows what the player
-- reads elsewhere in the game, and falls back to the raw name for a prototype
-- this save no longer defines.
local function prototype_caption(name)
  local prototype = prototypes.entity[name]
  local localised = prototype and prototype.localised_name or nil
  if localised ~= nil then return localised end
  return name
end

local function contents_caption(summary)
  local list = {""}
  for index = 1, math.min(#summary.names, MAX_ICONS) do
    local name = summary.names[index]
    list[#list + 1] = {"", "\n", tostring(summary.counts[name]), " x ", prototype_caption(name)}
  end
  if #summary.names > MAX_ICONS then
    list[#list + 1] = {
      "gui.sceatorio-ai-blueprints-more-kinds",
      #summary.names - MAX_ICONS
    }
  end
  return list
end

local function add_slot(container, record)
  local revisions = record.revisions
  local latest = revisions[#revisions]
  local summary = summarize(latest and latest.layout)
  local cell = add(container, {type = "flow", direction = "vertical"})
  local button = add(cell, {
    type = "sprite-button",
    style = "slot_button",
    sprite = slot_sprite(summary),
    number = summary.total > 0 and summary.total or nil,
    tooltip = {
      "gui.sceatorio-ai-blueprints-slot",
      text(record.name),
      number(latest and latest.revision),
      summary.total,
      summary.width,
      summary.height,
      number(record.created_tick),
      number(record.updated_tick),
      contents_caption(summary)
    },
    tags = {sceatorio_action = ACTION_LOAD, sceatorio_blueprint_id = record.id}
  })
  local label = add(cell, {type = "label", caption = text(record.name)})
  style(cell, {horizontal_align = "center", padding = 2})
  style(button, {width = SLOT_SIZE, height = SLOT_SIZE})
  style(label, {
    single_line = true,
    maximal_width = SLOT_LABEL_WIDTH,
    horizontal_align = "center"
  })
end

local function render_frame(player, page, message)
  destroy_frame(player)
  local records = inbox_records(player.index)
  local page_count = math.max(1, math.ceil(#records / SLOTS_PER_PAGE))
  page = math.max(1, math.min(page or 1, page_count))

  -- No frame caption: the title lives in the title bar row below, which is the
  -- only layout that keeps the close button out of the text it used to overlap.
  local frame = player.gui.screen.add({
    type = "frame",
    name = FRAME_NAME,
    direction = "vertical",
    tags = {sceatorio_page = page}
  })
  frame.auto_center = true
  style(frame, {width = FRAME_WIDTH})

  local title = add(frame, {type = "flow", direction = "horizontal"})
  title.drag_target = frame
  add(title, {
    type = "label",
    style = "frame_title",
    caption = {"gui.sceatorio-ai-blueprints-title"}
  })
  local spacer = add(title, {type = "empty-widget", style = "draggable_space_header"})
  spacer.drag_target = frame
  add(title, {
    type = "sprite-button",
    sprite = "utility/close",
    style = "frame_action_button",
    tags = {sceatorio_action = ACTION_CLOSE}
  })
  style(title, {vertical_align = "center", horizontally_stretchable = true})
  style(spacer, {horizontally_stretchable = true, height = 24, right_margin = 4})

  local hint = add(frame, {type = "label", caption = {"gui.sceatorio-ai-blueprints-hint"}})
  style(hint, {single_line = false, maximal_width = FRAME_WIDTH - 32})

  if message then
    local notice = add(frame, {type = "label", caption = message})
    style(notice, {single_line = false, maximal_width = FRAME_WIDTH - 32})
  end

  if #records == 0 then
    add(frame, {type = "label", caption = {"gui.sceatorio-ai-blueprints-empty"}})
    return frame
  end

  local grid = add(frame, {
    type = "table",
    name = "slots",
    column_count = SLOT_COLUMNS
  })
  style(grid, {horizontal_spacing = GAP, vertical_spacing = GAP})

  -- Only one page of slots is ever built, so a full 100-record inbox still
  -- renders a constant number of elements.
  local first = (page - 1) * SLOTS_PER_PAGE + 1
  local last = math.min(#records, first + SLOTS_PER_PAGE - 1)
  for index = first, last do add_slot(grid, records[index]) end

  local footer = add(frame, {type = "flow", direction = "horizontal"})
  local previous = footer.add({
    type = "button",
    caption = "<",
    tooltip = {"gui.sceatorio-ai-blueprints-previous-page"},
    tags = {sceatorio_action = ACTION_PAGE, sceatorio_page_delta = -1}
  })
  local indicator = footer.add({
    type = "label",
    caption = {"gui.sceatorio-ai-blueprints-page", page, page_count}
  })
  local following = footer.add({
    type = "button",
    caption = ">",
    tooltip = {"gui.sceatorio-ai-blueprints-next-page"},
    tags = {sceatorio_action = ACTION_PAGE, sceatorio_page_delta = 1}
  })
  style(footer, {vertical_align = "center", horizontally_stretchable = true})
  style(previous, {width = 28})
  style(following, {width = 28})
  previous.enabled = page > 1
  following.enabled = page < page_count
  previous.visible = page_count > 1
  indicator.visible = page_count > 1
  following.visible = page_count > 1
  return frame
end

-- aiBlueprints owns the only conversion from a stored layout into a real
-- blueprint item -- temporary inventory, contents before label and description,
-- every module, filter and control behavior. The panel must never rebuild that,
-- so it passes a delivery sink in place of the player: the finished stack lands
-- in the cursor instead of the clipboard queue. set_stack copies the item, so
-- the temporary inventory aiBlueprints destroys right after is never aliased.
local function cursor_sink(player)
  return {
    valid = true,
    connected = player.connected,
    add_to_clipboard = function(stack)
      player.cursor_stack.set_stack(stack)
    end
  }
end

local function deliver(player, blueprint_id)
  if type(blueprint_id) ~= "string" then return {"gui.sceatorio-ai-blueprints-missing"} end
  local cursor = player.cursor_stack
  if not (cursor and cursor.valid) then
    return {"gui.sceatorio-ai-blueprints-no-cursor"}
  end
  -- Whatever the cursor already holds belongs to the player; set_stack would
  -- destroy it, so a busy cursor reports and delivers nothing at all.
  if cursor.valid_for_read then
    return {"gui.sceatorio-ai-blueprints-cursor-busy"}
  end
  local result, code, message = Blueprints.load(
    {
      player = cursor_sink(player),
      player_index = player.index,
      allow_cursor = true
    },
    blueprint_id,
    nil,
    "cursor"
  )
  if not result then
    return {
      "gui.sceatorio-ai-blueprints-failed",
      message or code or "BLUEPRINT_NOT_FOUND"
    }
  end
  return {"gui.sceatorio-ai-blueprints-delivered"}
end

function AiBlueprintGui.update(player)
  if not (player and player.valid) then return end
  if not available(player) then
    local button = player.gui.screen[BUTTON_NAME]
    if button and button.valid then button.destroy() end
    destroy_frame(player)
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
  local frame = player.gui.screen[FRAME_NAME]
  if frame and frame.valid then
    frame.destroy()
    return
  end
  render_frame(player, 1)
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
  local action = tags.sceatorio_action
  if action ~= ACTION_TOGGLE and action ~= ACTION_CLOSE
    and action ~= ACTION_PAGE and action ~= ACTION_LOAD then return false end

  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return true end
  if action == ACTION_TOGGLE then
    AiBlueprintGui.toggle(player)
    return true
  end
  if action == ACTION_CLOSE then
    destroy_frame(player)
    return true
  end

  local frame = player.gui.screen[FRAME_NAME]
  local page = frame and frame.valid and frame.tags.sceatorio_page or 1
  if type(page) ~= "number" then page = 1 end
  if not available(player) then
    destroy_frame(player)
    AiBlueprintGui.update(player)
    return true
  end
  if action == ACTION_PAGE then
    local delta = tags.sceatorio_page_delta
    render_frame(player, page + ((delta == -1 or delta == 1) and delta or 0))
    return true
  end
  render_frame(player, page, deliver(player, tags.sceatorio_blueprint_id))
  return true
end

return AiBlueprintGui
