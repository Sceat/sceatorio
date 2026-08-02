local State = require("src.core.state")
local AiConstants = require("src.core.aiConstants")
local Blueprints = require("src.game.aiBlueprints")

local AiBlueprintGui = {}

local BUTTON_NAME = "sceatorio_ai_blueprint_button"
local FRAME_NAME = "sceatorio_ai_blueprint_frame"
local ROWS_PER_PAGE = 6
local BUTTON_SIZE = 40
local GAP = 8
-- The player list owns the upper-left corner; these mirror its own geometry so
-- the inbox button docks beside that panel instead of on top of it.
local PLAYER_PANEL_NAME = "sceatorio_player_panel"
local PLAYER_PANEL_FALLBACK_WIDTH = 340
local PLAYER_PANEL_LEFT_OFFSET = 8
local PLAYER_PANEL_TOP_OFFSET = 52

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

local function style(element, values)
  for key, value in pairs(values) do element.style[key] = value end
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

local function button_sprite()
  for _, path in ipairs(BUTTON_SPRITES) do
    local ok, valid = pcall(helpers.is_valid_sprite_path, path)
    if ok and valid then return path end
  end
  return nil
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
    local width = panel.style.width
    if not (type(width) == "number" and width > 0) then
      width = PLAYER_PANEL_FALLBACK_WIDTH
    end
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

local function add_row(container, record)
  local revisions = record.revisions
  local latest = revisions[#revisions]
  local row = container.add({type = "flow", direction = "horizontal"})
  local label = row.add({
    type = "label",
    caption = {
      "gui.sceatorio-ai-blueprints-row",
      text(record.name),
      number(latest and latest.revision),
      number(record.created_tick),
      number(record.updated_tick)
    }
  })
  row.add({
    type = "button",
    caption = {"gui.sceatorio-ai-blueprints-to-cursor"},
    tags = {sceatorio_action = ACTION_LOAD, sceatorio_blueprint_id = record.id}
  })
  style(row, {vertical_align = "center", horizontally_stretchable = true})
  style(label, {horizontally_stretchable = true, width = 320})
end

local function render_frame(player, page, message)
  destroy_frame(player)
  local records = inbox_records(player.index)
  local page_count = math.max(1, math.ceil(#records / ROWS_PER_PAGE))
  page = math.max(1, math.min(page or 1, page_count))

  local frame = player.gui.screen.add({
    type = "frame",
    name = FRAME_NAME,
    caption = {"gui.sceatorio-ai-blueprints-title"},
    direction = "vertical",
    tags = {sceatorio_page = page}
  })
  frame.auto_center = true

  local title = frame.add({type = "flow", direction = "horizontal"})
  title.drag_target = frame
  local hint = title.add({type = "label", caption = {"gui.sceatorio-ai-blueprints-hint"}})
  local spacer = title.add({type = "empty-widget"})
  title.add({
    type = "sprite-button",
    sprite = "utility/close",
    style = "frame_action_button",
    tags = {sceatorio_action = ACTION_CLOSE}
  })
  style(title, {vertical_align = "center", horizontally_stretchable = true})
  style(hint, {horizontally_stretchable = true})
  style(spacer, {horizontally_stretchable = true})

  if message then frame.add({type = "label", caption = message}) end

  local rows = frame.add({type = "flow", name = "rows", direction = "vertical"})
  style(rows, {horizontally_stretchable = true})
  if #records == 0 then
    rows.add({type = "label", caption = {"gui.sceatorio-ai-blueprints-empty"}})
    return frame
  end

  -- Only one page of rows is ever built, so a full 100-record inbox still
  -- renders a constant number of elements.
  local first = (page - 1) * ROWS_PER_PAGE + 1
  local last = math.min(#records, first + ROWS_PER_PAGE - 1)
  for index = first, last do add_row(rows, records[index]) end

  local footer = frame.add({type = "flow", direction = "horizontal"})
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

local function deliver(player, blueprint_id)
  if type(blueprint_id) ~= "string" then return {"gui.sceatorio-ai-blueprints-missing"} end
  local result, code, message = Blueprints.load(
    {
      player = player,
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
