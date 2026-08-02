local State = require("src.core.state")
local Teams = require("src.game.teams")
local Evolution = require("src.game.evo")

local PlayerList = {}

local PANEL_NAME = "sceatorio_player_panel"
local PANEL_WIDTH = 340
local MINIMUM_PANEL_WIDTH = 260
-- Factorio 2.1 keeps its own controls out of the upper-left corner (the engine
-- buttons sit above the minimap on the right, the shortcut bar at the bottom),
-- and no vanilla script writes to player.gui.top. The panel therefore mirrors
-- its own left inset when that flow is empty, and only drops below one
-- mod-button row (mod_gui_button is 40 high, plus the flow's own padding) when
-- something -- another mod, or our admin dev menu -- actually occupies it.
local TOP_INSET = 8
local TOP_CLEARANCE = 52
local VIEWERS_PER_REFRESH = 4
local PLAYERS_PER_GROUP_PAGE = 6

-- Runtime-only indexes avoid rescanning historical game.players for every
-- connected viewer. They are rebuilt once after a load and then maintained by
-- the normal player lifecycle events.
local directory_cache

local function style(element, values)
  for key, value in pairs(values) do element.style[key] = value end
end

local function preferences()
  local root = State.get()
  root.player_list_collapsed = root.player_list_collapsed or {}
  return root.player_list_collapsed
end

local function page_preferences(player_index)
  local root = State.get()
  root.player_list_pages = root.player_list_pages or {}
  local values = root.player_list_pages[player_index]
  if not values then
    values = {online = 1, offline = 1}
    root.player_list_pages[player_index] = values
  end
  values.online = values.online or 1
  values.offline = values.offline or 1
  return values
end

local function insert_sorted(values, player_index)
  local low = 1
  local high = #values + 1
  while low < high do
    local middle = math.floor((low + high) / 2)
    if values[middle] and values[middle] < player_index then
      low = middle + 1
    else
      high = middle
    end
  end
  table.insert(values, low, player_index)
end

local function remove_sorted(values, player_index)
  local low = 1
  local high = #values
  while low <= high do
    local middle = math.floor((low + high) / 2)
    local value = values[middle]
    if value == player_index then
      table.remove(values, middle)
      return true
    elseif value < player_index then
      low = middle + 1
    else
      high = middle - 1
    end
  end
  return false
end

local function rebuild_directory()
  local directory = {
    online = {},
    offline = {},
    present = {},
    connected = {}
  }
  for _, player in pairs(game.players) do
    if player.valid then
      directory.present[player.index] = true
      directory.connected[player.index] = player.connected
      insert_sorted(
        player.connected and directory.online or directory.offline,
        player.index
      )
    end
  end
  directory_cache = directory
  return directory
end

local function ensure_directory()
  return directory_cache or rebuild_directory()
end

local function track_player(player, connected_override)
  if not (player and player.valid) then return ensure_directory() end
  local directory = ensure_directory()
  local player_index = player.index
  local connected = connected_override
  if connected == nil then connected = player.connected end

  if not directory.present[player_index] then
    directory.present[player_index] = true
    directory.connected[player_index] = connected
    insert_sorted(connected and directory.online or directory.offline, player_index)
    return directory
  end

  local previous = directory.connected[player_index]
  if previous ~= connected then
    remove_sorted(previous and directory.online or directory.offline, player_index)
    insert_sorted(connected and directory.online or directory.offline, player_index)
    directory.connected[player_index] = connected
  end
  return directory
end

local function untrack_player(player_index)
  local directory = ensure_directory()
  if not directory.present[player_index] then return directory end
  local connected = directory.connected[player_index]
  remove_sorted(connected and directory.online or directory.offline, player_index)
  directory.present[player_index] = nil
  directory.connected[player_index] = nil
  return directory
end

local function format_time(ticks)
  -- LuaPlayer.online_time is the engine-maintained total across all sessions.
  local total_minutes = math.floor(ticks / 60 / 60)
  local hours = math.floor(total_minutes / 60)
  local minutes = total_minutes - hours * 60
  return string.format("%dh:%02dm", hours, minutes)
end

local function top_offset(player)
  for _, element in pairs(player.gui.top.children) do
    if element.valid and element.visible then return TOP_CLEARANCE end
  end
  return TOP_INSET
end

local function position_panel(player, panel)
  local scale = player.display_scale > 0 and player.display_scale or 1
  local logical_width = player.display_resolution.width / scale
  local width = math.min(PANEL_WIDTH, math.max(MINIMUM_PANEL_WIDTH, logical_width - 24))
  panel.style.width = width
  panel.location = {
    -- Keep the compact status panel in Factorio's free upper-left corner.
    x = math.floor(8 * scale),
    y = math.floor(top_offset(player) * scale)
  }
end

-- Every upper-left leftover from an earlier Sceatorio dies here, so a save made
-- before this version stops showing it the moment the mod loads or a player
-- joins. The robot policy no longer draws a permanent status button; it reports
-- a reached cap in chat instead.
local LEGACY_TOP_NAMES = {"playerList", "sceatorio", "sceatorio_robot_policy_status"}

local function destroy_legacy(player)
  for _, name in ipairs(LEGACY_TOP_NAMES) do
    local element = player.gui.top[name]
    if element and element.valid then element.destroy() end
  end
  local legacy_pane = player.gui.left["playerList-panel"]
  if legacy_pane and legacy_pane.valid then legacy_pane.destroy() end
end

local function create_group(list, group_name, caption)
  local group = list.add({
    type = "flow",
    name = group_name .. "_list",
    direction = "vertical"
  })
  local header = group.add({
    type = "flow",
    name = "header",
    direction = "horizontal"
  })
  local count = header.add({
    type = "label",
    name = group_name .. "_count",
    caption = {caption, 0}
  })
  local previous = header.add({
    type = "button",
    name = "previous_page",
    caption = "<",
    tooltip = {"sceatorio.player-list-previous-page"},
    tags = {
      sceatorio_action = "player_list_page",
      sceatorio_player_group = group_name,
      sceatorio_page_delta = -1
    }
  })
  header.add({
    type = "label",
    name = "page",
    caption = {"sceatorio.player-list-page", 1, 1}
  })
  local following = header.add({
    type = "button",
    name = "next_page",
    caption = ">",
    tooltip = {"sceatorio.player-list-next-page"},
    tags = {
      sceatorio_action = "player_list_page",
      sceatorio_player_group = group_name,
      sceatorio_page_delta = 1
    }
  })
  group.add({
    type = "flow",
    name = "entries",
    direction = "vertical"
  })

  -- Flows default to 4px between children; the rows are single-line labels that
  -- already carry their own line height, so the list reads denser without any
  -- font change.
  style(group, {horizontally_stretchable = true, vertical_spacing = 2})
  style(header, {vertical_align = "center", horizontally_stretchable = true})
  style(count, {font = "default-semibold", horizontally_stretchable = true})
  style(previous, {width = 28})
  style(following, {width = 28})
  style(group.entries, {horizontally_stretchable = true, vertical_spacing = 0})
end

local function create_list(panel)
  -- Separate pages keep historical users accessible without letting either
  -- online or offline rows grow this always-visible HUD panel without bound.
  local list = panel.add({
    type = "flow",
    name = "player_list",
    direction = "vertical"
  })
  create_group(list, "online", "sceatorio.online-players")
  create_group(list, "offline", "sceatorio.offline-players")
  style(list, {horizontally_stretchable = true, vertical_spacing = 4})
end

local function update_toggle(panel)
  local button = panel.header and panel.header.toggle_players
  if not (button and button.valid) then return end
  local list = panel.player_list
  button.caption = list and list.valid
    and {"sceatorio.hide-players"}
    or {"sceatorio.show-players"}
end

local function render_entry(panel, listed_player, connected)
  local list = panel.player_list
  if not (list and list.valid and listed_player and listed_player.valid) then return end

  local name = "sceatorio_player_" .. listed_player.index
  local destination_name = connected and "online_list" or "offline_list"
  local other_name = connected and "offline_list" or "online_list"
  local destination = list[destination_name].entries
  local stale = list[other_name].entries[name]
  if stale and stale.valid then stale.destroy() end

  local record = Teams.get_for_player(listed_player)
  local character = listed_player.character
  local physical_surface = character and character.valid and character.surface or nil
  local factor = record and physical_surface
    and Evolution.get_factor(record, physical_surface) or nil
  local difficulty = factor and string.format("%.0f", math.min(100, factor * 100)) or "--"
  local label = destination[name]
  if not (label and label.valid) then
    label = destination.add({
      name = name,
      type = "label",
      tags = {sceatorio_player_index = listed_player.index}
    })
  end
  -- No team name in the row: an online row is drawn in that player's own team
  -- colour below, which already says whose team it is, and the bracketed prefix
  -- was what pushed evolution and playtime past the panel's right edge.
  label.caption = {
    "sceatorio.player-list-entry",
    listed_player.name,
    difficulty,
    format_time(listed_player.online_time)
  }
  if connected then
    style(label, {
      font_color = {
        r = listed_player.color.r,
        g = listed_player.color.g,
        b = listed_player.color.b,
        a = 1
      },
      font = "default-semibold"
    })
  else
    style(label, {
      font_color = {r = 0.5, g = 0.5, b = 0.5},
      font = "default"
    })
  end
end

local function render_group(panel, viewer, group_name, player_indexes)
  local list = panel.player_list
  if not (list and list.valid) then return end
  local group = list[group_name .. "_list"]
  if not (group and group.valid) then return end

  local total = #player_indexes
  local page_count = math.max(1, math.ceil(total / PLAYERS_PER_GROUP_PAGE))
  local viewer_pages = page_preferences(viewer.index)
  local page = math.max(1, math.min(viewer_pages[group_name] or 1, page_count))
  viewer_pages[group_name] = page

  local header = group.header
  header[group_name .. "_count"].caption = {
    "sceatorio." .. group_name .. "-players",
    total
  }
  header.page.caption = {"sceatorio.player-list-page", page, page_count}
  header.previous_page.visible = page_count > 1
  header.next_page.visible = page_count > 1
  header.page.visible = page_count > 1
  header.previous_page.enabled = page > 1
  header.next_page.enabled = page < page_count

  local desired = {}
  local first = (page - 1) * PLAYERS_PER_GROUP_PAGE + 1
  local last = math.min(total, first + PLAYERS_PER_GROUP_PAGE - 1)
  for index = first, last do
    local player_index = player_indexes[index]
    local listed_player = game.players[player_index]
    if listed_player and listed_player.valid then
      desired[player_index] = true
      render_entry(panel, listed_player, group_name == "online")
    end
  end
  for _, child in pairs(group.entries.children) do
    local player_index = child.tags and child.tags.sceatorio_player_index
    if player_index and not desired[player_index] then child.destroy() end
  end
end

function PlayerList.create_container(player)
  if not (player and player.valid) then return end
  destroy_legacy(player)
  local old = player.gui.screen[PANEL_NAME]
  if old and old.valid then old.destroy() end

  local panel = player.gui.screen.add({
    name = PANEL_NAME,
    type = "frame",
    direction = "vertical"
  })
  panel.auto_center = false
  style(panel, {padding = 2})
  position_panel(player, panel)

  local header = panel.add({name = "header", type = "flow", direction = "horizontal"})
  header.add({type = "label", caption = {"sceatorio.day-time"}})
  local progress = header.add({name = "day_progress", type = "progressbar", value = 0})
  style(progress, {width = 100})
  header.add({
    name = "toggle_players",
    type = "button",
    caption = {"sceatorio.show-players"},
    tags = {sceatorio_action = "toggle_players"}
  })
  style(header, {vertical_align = "center", horizontally_stretchable = true})

  if not preferences()[player.index] then create_list(panel) end
  update_toggle(panel)
  PlayerList.update(player)
end

function PlayerList.ensure(player)
  if not (player and player.valid) then return end
  local panel = player.gui.screen[PANEL_NAME]
  if not (panel and panel.valid) then
    PlayerList.create_container(player)
    return
  end
  position_panel(player, panel)
end

function PlayerList.initialize()
  local root = State.get()
  preferences()
  root.player_list_pages = root.player_list_pages or {}
  root.player_list_cursor = root.player_list_cursor or 1
  rebuild_directory()
  for _, player in pairs(game.connected_players) do
    PlayerList.create_container(player)
  end
end

function PlayerList.update(player)
  if not (player and player.valid) then return end
  local panel = player.gui.screen[PANEL_NAME]
  if not (panel and panel.valid) then
    PlayerList.create_container(player)
    return
  end
  position_panel(player, panel)
  panel.header.day_progress.value = math.max(0, math.min(1, player.surface.daytime))
  local list = panel.player_list
  update_toggle(panel)
  if not (list and list.valid) then return end

  local directory = ensure_directory()
  render_group(panel, player, "online", directory.online)
  render_group(panel, player, "offline", directory.offline)
end

function PlayerList.toggle(player)
  if not (player and player.valid) then return end
  PlayerList.ensure(player)
  local panel = player.gui.screen[PANEL_NAME]
  local collapsed = panel.player_list ~= nil
  preferences()[player.index] = collapsed
  if collapsed then
    panel.player_list.destroy()
  else
    create_list(panel)
    PlayerList.update(player)
  end
  update_toggle(panel)
end

local function refresh_viewers(excluded_player_index)
  for _, viewer in pairs(game.connected_players) do
    if viewer.index ~= excluded_player_index then
      local panel = viewer.gui.screen[PANEL_NAME]
      if panel and panel.valid then
        PlayerList.update(viewer)
      else
        PlayerList.create_container(viewer)
      end
    end
  end
end

function PlayerList.refresh_entry(player_index, connected_override)
  local listed_player = game.players[player_index]
  if listed_player and listed_player.valid then
    track_player(listed_player, connected_override)
  else
    untrack_player(player_index)
  end
  refresh_viewers()
end

function PlayerList.on_player_created(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  track_player(player, true)
  PlayerList.create_container(player)
  refresh_viewers(player.index)
end

function PlayerList.on_player_joined(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  track_player(player, true)
  PlayerList.create_container(player)
  refresh_viewers(player.index)
end

function PlayerList.on_player_left(event)
  PlayerList.refresh_entry(event.player_index, false)
end

function PlayerList.on_player_changed(event)
  PlayerList.refresh_entry(event.player_index)
end

function PlayerList.on_player_removed(event)
  preferences()[event.player_index] = nil
  local root = State.get()
  if root.player_list_pages then root.player_list_pages[event.player_index] = nil end
  untrack_player(event.player_index)
  refresh_viewers()
end

function PlayerList.tick()
  local viewers = {}
  for _, player in pairs(game.connected_players) do
    if player.valid then viewers[#viewers + 1] = player end
  end
  table.sort(viewers, function(first, second) return first.index < second.index end)
  if #viewers == 0 then
    State.get().player_list_cursor = 1
    return
  end

  local root = State.get()
  local cursor = math.max(1, math.min(root.player_list_cursor or 1, #viewers))
  for _ = 1, math.min(VIEWERS_PER_REFRESH, #viewers) do
    PlayerList.update(viewers[cursor])
    cursor = cursor % #viewers + 1
  end
  root.player_list_cursor = cursor
end

function PlayerList.on_display_changed(event)
  local player = game.players[event.player_index]
  if player and player.valid then PlayerList.ensure(player) end
end

function PlayerList.on_gui_click(event)
  if not (event.element and event.element.valid) then return false end
  local tags = event.element.tags or {}
  local action = tags.sceatorio_action
  if action == "toggle_players" then
    PlayerList.toggle(game.players[event.player_index])
    return true
  end
  if action ~= "player_list_page" then return false end

  local player = game.players[event.player_index]
  local group_name = tags.sceatorio_player_group
  local delta = tags.sceatorio_page_delta
  if not (player and player.valid)
    or (group_name ~= "online" and group_name ~= "offline")
    or (delta ~= -1 and delta ~= 1) then
    return true
  end

  local directory = ensure_directory()
  local page_count = math.max(
    1,
    math.ceil(#directory[group_name] / PLAYERS_PER_GROUP_PAGE)
  )
  local values = page_preferences(player.index)
  values[group_name] = math.max(
    1,
    math.min((values[group_name] or 1) + delta, page_count)
  )
  PlayerList.update(player)
  return true
end

return PlayerList
