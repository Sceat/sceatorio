local Teams = require("src.game.teams")
local PlanetSpawns = require("src.game.planetSpawns")
local Evolution = require("src.game.evo")
local OfflineSecurity = require("src.game.offlineSecurity")
local RobotPolicy = require("src.game.robotPolicy")
local Security = require("src.game.security")
local Radars = require("src.game.radars")

local TestMenu = {}

local BUTTON_NAME = "sceatorio_dev_tools_button"
local FRAME_NAME = "sceatorio_dev_tools_frame"
local BUILTIN_PLANET_ORDER = {
  nauvis = 1,
  vulcanus = 2,
  gleba = 3,
  fulgora = 4,
  aquilo = 5
}

local function enabled()
  local value = settings.global["sceatorio-dev-tools-enabled"]
  return value and value.value or false
end

local function authorized(player)
  return enabled() and player and player.valid and player.admin
end

local function remove_gui(player)
  if not (player and player.valid) then return end
  local button = player.gui.top[BUTTON_NAME]
  if button and button.valid then button.destroy() end
  local frame = player.gui.screen[FRAME_NAME]
  if frame and frame.valid then frame.destroy() end
end

function TestMenu.update_button(player)
  if not authorized(player) then
    remove_gui(player)
    return
  end
  local button = player.gui.top[BUTTON_NAME]
  if not button then
    player.gui.top.add({
      type = "button",
      name = BUTTON_NAME,
      caption = {"sceatorio.dev-tools-button"},
      tooltip = {"sceatorio.dev-tools-tooltip"},
      tags = {sceatorio_action = "dev_tools_toggle"}
    })
  end
end

local function planet_surface(planet)
  if not (planet and planet.valid) then return nil end
  local ok, surface = pcall(function() return planet.surface end)
  return ok and surface and surface.valid and surface or nil
end

local function sorted_planets()
  local result = {}
  for _, planet in pairs(game.planets) do
    if planet and planet.valid then result[#result + 1] = planet end
  end
  table.sort(result, function(first, second)
    local first_order = BUILTIN_PLANET_ORDER[first.name] or 1000
    local second_order = BUILTIN_PLANET_ORDER[second.name] or 1000
    if first_order ~= second_order then return first_order < second_order end
    return first.name < second.name
  end)
  return result
end

local function planet_status(record, planet)
  local surface = planet_surface(planet)
  if not surface then return "unvisited", "-", "-" end
  local surface_record = Teams.get_surface(record, surface)
  local spawn = surface_record and surface_record.spawn or nil
  local metadata = surface_record and surface_record.planet_spawn or nil
  local state = metadata and metadata.state or (spawn and "ready" or "unvisited")
  local position = spawn and string.format("%.1f, %.1f", spawn.x, spawn.y) or "-"
  local factor = Evolution.get_factor(record, surface)
  local evolution = factor and string.format("%.4f", factor) or "-"
  return state, position, evolution
end

local function show_menu(player)
  local existing = player.gui.screen[FRAME_NAME]
  if existing and existing.valid then existing.destroy() end

  local record = Teams.get_for_player(player)
  local frame = player.gui.screen.add({
    type = "frame",
    direction = "vertical",
    name = FRAME_NAME,
    caption = {"sceatorio.dev-tools-title"}
  })
  frame.auto_center = true
  if not record then
    frame.add({type = "label", caption = {"sceatorio.dev-tools-no-team"}})
  else
    local offline = OfflineSecurity.status(player.force) or {
      active = false,
      registered = 0,
      protected = 0
    }
    frame.add({
      type = "label",
      caption = {
        "sceatorio.dev-tools-team-status",
        record.id,
        record.display_name,
        offline.active and "active" or "inactive",
        offline.protected,
        offline.registered
      }
    })

    local planet_table = frame.add({type = "table", column_count = 2})
    for _, planet in ipairs(sorted_planets()) do
      local state, position, evolution = planet_status(record, planet)
      planet_table.add({
        type = "label",
        caption = {"sceatorio.dev-tools-planet-status", planet.name, state, evolution},
        tooltip = {"sceatorio.dev-tools-surface-status", planet.name, state, position, evolution}
      })
      planet_table.add({
        type = "button",
        caption = {"sceatorio.dev-tools-test-arrival"},
        tags = {
          sceatorio_action = "dev_tools_planet",
          planet_name = planet.name
        }
      })
    end

    local actions = frame.add({type = "flow", direction = "horizontal"})
    actions.add({
      type = "button",
      caption = {"sceatorio.dev-tools-robot-status"},
      tags = {sceatorio_action = "dev_tools_robot_status"}
    })
    actions.add({
      type = "button",
      caption = {"sceatorio.dev-tools-electricity-audit"},
      tags = {sceatorio_action = "dev_tools_electricity_audit"}
    })
    actions.add({
      type = "button",
      caption = {"sceatorio.dev-tools-research-all"},
      tags = {sceatorio_action = "dev_tools_research_all"}
    })
  end
  frame.add({
    type = "button",
    caption = {"sceatorio.close"},
    tags = {sceatorio_action = "dev_tools_close"}
  })
  player.opened = frame
end

local function reject(player)
  remove_gui(player)
  if player and player.valid then player.print({"sceatorio.admin-only"}) end
end

function TestMenu.on_gui_click(event)
  local element = event.element
  if not (element and element.valid) then return false end
  local action = (element.tags or {}).sceatorio_action
  if type(action) ~= "string" or string.sub(action, 1, #"dev_tools_") ~= "dev_tools_" then
    return false
  end
  local player = game.players[event.player_index]
  if not authorized(player) then
    reject(player)
    return true
  end

  if action == "dev_tools_toggle" then
    local frame = player.gui.screen[FRAME_NAME]
    if frame and frame.valid then frame.destroy() else show_menu(player) end
  elseif action == "dev_tools_close" then
    local frame = player.gui.screen[FRAME_NAME]
    if frame and frame.valid then frame.destroy() end
  elseif action == "dev_tools_planet" then
    local planet_name = element.tags.planet_name
    local planet = type(planet_name) == "string" and game.planets[planet_name] or nil
    local ok, state = PlanetSpawns.debug_route_player_to_planet(player, planet)
    player.print(ok
      and {"sceatorio.dev-tools-travel-result", state}
      or {"sceatorio.dev-tools-action-failed", state})
    show_menu(player)
  elseif action == "dev_tools_return_nauvis" then
    local ok, state = PlanetSpawns.debug_return_to_nauvis(player)
    player.print(ok
      and {"sceatorio.dev-tools-travel-result", state}
      or {"sceatorio.dev-tools-action-failed", state})
  elseif action == "dev_tools_robot_status" then
    RobotPolicy.show_status(player)
  elseif action == "dev_tools_electricity_audit" then
    local processed = Security.audit_poles(Security.AUDIT_BUDGET)
    player.print({"sceatorio.dev-tools-audit-result", processed})
  elseif action == "dev_tools_research_all" then
    local record = Teams.get_for_player(player)
    if not record then
      player.print({"sceatorio.dev-tools-action-failed", {"sceatorio.dev-tools-no-team"}})
    else
      -- Factorio 2.1.12 raises the normal research-finished events for this
      -- force-local diagnostic. Explicitly leave disabled prototypes locked.
      player.force.research_all_technologies(false)
      player.print({"sceatorio.dev-tools-research-all-result", record.display_name})
      show_menu(player)
    end
  end
  return true
end

function TestMenu.initialize()
  for _, player in pairs(game.players) do TestMenu.update_button(player) end
end

function TestMenu.on_player_joined(event)
  TestMenu.update_button(game.players[event.player_index])
end

function TestMenu.on_player_changed_force(event)
  local player = game.players[event.player_index]
  TestMenu.update_button(player)
  local frame = player and player.valid and player.gui.screen[FRAME_NAME] or nil
  if frame and frame.valid and authorized(player) then show_menu(player) end
end

function TestMenu.on_setting_changed(event)
  if event.setting ~= "sceatorio-dev-tools-enabled" then return end
  TestMenu.initialize()
end

-- This interface is for deterministic Factorio fixtures and trusted tooling.
-- It cannot do anything while the production-off dev setting is disabled and
-- does not expose arbitrary Lua, event fabrication, or world mutation.
remote.add_interface("sceatorio_dev_tools", {
  set_evolution_enabled = function(value)
    if not enabled() then return {ok = false, error = "development tools are disabled"} end
    -- Account up to this instant under the old policy, then move the cursor as
    -- the runtime setting changes so re-enabling can never back-charge.
    Evolution.sync_connected(game.tick)
    settings.global["sceatorio-evolution-enabled"] = {value = value == true}
    Evolution.sync_connected(game.tick)
    return {ok = true, enabled = settings.global["sceatorio-evolution-enabled"].value}
  end,
  set_offline_protection = function(force_name, protected, include_status)
    if not enabled() then return {ok = false, error = "development tools are disabled"} end
    local force = game.forces[force_name]
    if not force then return {ok = false, error = "force not found"} end
    local ok = OfflineSecurity.set_force_protected(force, protected == true)
    local status = nil
    if ok and include_status ~= false then status = OfflineSecurity.status(force) end
    return {ok = ok, status = status}
  end,
  offline_status = function(force_name)
    if not enabled() then return {ok = false, error = "development tools are disabled"} end
    local force = game.forces[force_name]
    local status = force and OfflineSecurity.status(force) or nil
    return status and {ok = true, status = status}
      or {ok = false, error = "team force not found"}
  end,
  share_chart_chunk = function(force_name, surface_name, chunk_position)
    if not enabled() then return {ok = false, error = "development tools are disabled"} end
    return Radars.share_chunk(force_name, surface_name, chunk_position)
  end,
  reserve_planet_spawn = function(force_name, surface_name, anchor)
    if not enabled() then return {ok = false, error = "development tools are disabled"} end
    local force = type(force_name) == "string" and game.forces[force_name] or nil
    local surface = (type(surface_name) == "string" or type(surface_name) == "number")
      and game.surfaces[surface_name] or nil
    local record = force and Teams.get_by_force(force) or nil
    if not record then return {ok = false, error = "team force not found"} end
    if not PlanetSpawns.is_supported(surface) then
      return {ok = false, supported = false, error = "surface is not a real planet"}
    end
    local position = type(anchor) == "table" and anchor or {x = 0, y = 0}
    PlanetSpawns.request_spawn(record, surface, position, nil, "development-fixture")
    local surface_record = Teams.get_surface(record, surface)
    local metadata = surface_record and surface_record.planet_spawn or nil
    return {
      ok = true,
      supported = true,
      state = metadata and metadata.state or "unvisited",
      spawn = surface_record and surface_record.spawn or nil,
      preserve_native = metadata and metadata.preserve_native == true or false
    }
  end,
  planet_spawn_status = function(force_name, surface_name)
    if not enabled() then return {ok = false, error = "development tools are disabled"} end
    local force = type(force_name) == "string" and game.forces[force_name] or nil
    local surface = (type(surface_name) == "string" or type(surface_name) == "number")
      and game.surfaces[surface_name] or nil
    local record = force and Teams.get_by_force(force) or nil
    local surface_record = record and surface and Teams.get_surface(record, surface) or nil
    local metadata = surface_record and surface_record.planet_spawn or nil
    if not (record and surface) then return {ok = false, error = "team or surface not found"} end
    return {
      ok = true,
      supported = PlanetSpawns.is_supported(surface),
      state = metadata and metadata.state or "unvisited",
      spawn = surface_record and surface_record.spawn or nil,
      preserve_native = metadata and metadata.preserve_native == true or false
    }
  end
})

return TestMenu
