local State = require("src.core.state")
local Teams = require("src.game.teams")
local Spawns = require("src.game.spawns")
local Evolution = require("src.game.evo")
local Chat = require("src.game.chat")
local DeathMessage = require("src.game.deathMessage")
local Radars = require("src.game.radars")
local PlayerList = require("src.game.playerList")
local Security = require("src.game.security")
local OfflineSecurity = require("src.game.offlineSecurity")
local PlanetSpawns = require("src.game.planetSpawns")
local RobotPolicy = require("src.game.robotPolicy")
local TestMenu = require("src.game.testMenu")
local AiGateway = require("src.game.aiGateway")
local AiBlueprintGui = require("src.game.aiBlueprintGui")

require("src.game.admin")

remote.add_interface("sceatorio_teams", {
  register_force = function(force_name, owner_player_index, display_name)
    local force = type(force_name) == "string" and game.forces[force_name] or nil
    local record, reason = Teams.register_force(force, owner_player_index, display_name)
    if not record then return {ok = false, error = reason} end
    return {
      ok = true,
      id = record.id,
      force_name = record.force_name,
      enemy_force_name = record.enemy_force_name
    }
  end,
  chart_status = function()
    return Radars.status()
  end
})

remote.add_interface("sceatorio_radars", {
  share_chunk = function(force_name, surface_identifier, chunk_position)
    return Radars.share_chunk(force_name, surface_identifier, chunk_position)
  end
})

local function initialize_common()
  Spawns.configure_freeplay()
  State.initialize()
  Teams.initialize()
  Radars.initialize()
  Evolution.configure_vanilla()
  Evolution.sync_connected(game.tick)
  Security.initialize()
  OfflineSecurity.initialize()
  PlanetSpawns.initialize()
  RobotPolicy.initialize()
  TestMenu.initialize()
  PlayerList.initialize()
  AiGateway.initialize()
  AiBlueprintGui.initialize()
end

script.on_init(function()
  initialize_common()
  Spawns.initialize_new_game()
end)

script.on_configuration_changed(function()
  initialize_common()
  Spawns.on_configuration_changed()
end)

script.on_load(OfflineSecurity.on_load)

script.on_event(defines.events.on_chunk_generated, Spawns.on_chunk_generated)
script.on_event(defines.events.on_biter_base_built, Spawns.on_biter_base_built)
script.on_event(defines.events.on_build_base_arrived, Spawns.on_build_base_arrived)
script.on_event(defines.events.on_player_created, function(event)
  Spawns.on_player_created(event)
  PlayerList.on_player_created(event)
end)
script.on_event(defines.events.on_player_died, DeathMessage.on_player_died)

script.on_event(defines.events.on_entity_died, function(event)
  Evolution.on_entity_died(event)
  RobotPolicy.on_entity_removed(event)
  OfflineSecurity.on_entity_removed(event)
  AiGateway.on_entity_removed(event)
end)

script.on_event(defines.events.on_player_left_game, function(event)
  AiGateway.on_player_left(event)
  Evolution.sync_connected(event.tick)
  Spawns.on_player_left(event)
  OfflineSecurity.on_player_left(event)
  PlayerList.on_player_left(event)
end)

script.on_event(defines.events.on_player_joined_game, function(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  OfflineSecurity.on_player_joined(event)
  PlayerList.on_player_joined(event)
  Spawns.on_player_joined(event)
  PlanetSpawns.on_player_joined(event)
  RobotPolicy.on_player_joined(event)
  TestMenu.on_player_joined(event)
  Evolution.sync_connected(event.tick)
  AiGateway.on_player_joined(event)
  AiBlueprintGui.on_player_joined(event)
end)

script.on_event(defines.events.on_player_changed_force, function(event)
  Teams.on_player_changed_force(event)
  Evolution.sync_connected(event.tick)
  OfflineSecurity.on_player_changed_force(event)
  Spawns.on_player_changed_force(event)
  RobotPolicy.on_player_joined(event)
  TestMenu.on_player_changed_force(event)
  PlayerList.on_player_changed(event)
  AiGateway.on_player_changed_force(event)
  AiBlueprintGui.on_player_changed_force(event)
end)

script.on_event(defines.events.on_player_changed_surface, function(event)
  Evolution.sync_connected(event.tick)
  PlanetSpawns.on_player_changed_surface(event)
  PlayerList.on_player_changed(event)
  AiGateway.on_player_changed_surface(event)
end)
script.on_event(defines.events.on_player_respawned, function(event)
  PlanetSpawns.on_player_respawned(event)
  PlayerList.on_player_changed(event)
end)
if defines.events.on_player_removed then
  script.on_event(defines.events.on_player_removed, function(event)
    Teams.on_player_removed(event)
    PlayerList.on_player_removed(event)
    AiGateway.on_player_removed(event)
  end)
end

local display_events = {}
for _, event_id in pairs({
  defines.events.on_player_display_density_scale_changed,
  defines.events.on_player_display_resolution_changed,
  defines.events.on_player_display_scale_changed
}) do
  if event_id then display_events[#display_events + 1] = event_id end
end
if #display_events > 0 then
  script.on_event(display_events, function(event)
    PlayerList.on_display_changed(event)
    AiBlueprintGui.on_display_changed(event)
  end)
end
if defines.events.on_cargo_pod_finished_descending then
  script.on_event(
    defines.events.on_cargo_pod_finished_descending,
    PlanetSpawns.on_cargo_pod_finished_descending
  )
end
if defines.events.on_cargo_pod_started_ascending then
  script.on_event(
    defines.events.on_cargo_pod_started_ascending,
    PlanetSpawns.on_cargo_pod_started_ascending
  )
end

script.on_event(defines.events.on_console_chat, Chat.forward)
script.on_event(defines.events.on_research_started, function(event)
  Chat.on_research_started(event)
  AiGateway.on_research_started(event)
end)
script.on_event(defines.events.on_research_finished, function(event)
  AiGateway.on_research_finished(event)
  AiBlueprintGui.on_research_finished(event)
end)
script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  Evolution.on_setting_changed(event)
  OfflineSecurity.on_setting_changed(event)
  PlanetSpawns.on_setting_changed(event)
  RobotPolicy.on_setting_changed(event)
  TestMenu.on_setting_changed(event)
  AiGateway.on_setting_changed(event)
  AiBlueprintGui.on_setting_changed(event)
end)
script.on_event(defines.events.on_surface_created, function(event)
  Teams.on_surface_created(event)
  Security.on_surface_created(event)
end)
script.on_event(defines.events.on_force_created, Teams.on_force_created)
script.on_event(defines.events.on_surface_deleted, function(event)
  Security.on_surface_deleted(event)
  PlanetSpawns.on_surface_deleted(event)
  RobotPolicy.on_surface_deleted(event)
  OfflineSecurity.on_surface_deleted(event)
  Spawns.on_surface_deleted(event)
  Teams.on_surface_deleted(event)
  AiGateway.on_surface_deleted(event)
end)
script.on_event(defines.events.on_forces_merged, function(event)
  Teams.on_forces_merged(event)
  OfflineSecurity.on_forces_merged(event)
  Spawns.on_forces_merged(event)
  PlanetSpawns.on_forces_merged(event)
  RobotPolicy.on_forces_merged(event)
  AiGateway.on_forces_merged(event)
end)

script.on_event(defines.events.on_built_entity, function(event)
  Security.on_player_built(event)
  RobotPolicy.on_entity_built(event)
  OfflineSecurity.on_entity_built(event)
  AiGateway.on_entity_built(event)
end)
script.on_event(defines.events.on_robot_built_entity, function(event)
  Security.on_robot_built(event)
  RobotPolicy.on_entity_built(event)
  OfflineSecurity.on_entity_built(event)
  AiGateway.on_entity_built(event)
end)
script.on_event({
  defines.events.script_raised_built,
  defines.events.script_raised_revive
}, function(event)
  Security.on_script_built(event)
  RobotPolicy.on_entity_built(event)
  OfflineSecurity.on_entity_built(event)
  AiGateway.on_entity_built(event)
end)
script.on_event(defines.events.on_entity_cloned, function(event)
  Security.on_entity_cloned(event)
  RobotPolicy.on_entity_cloned(event)
  OfflineSecurity.on_entity_cloned(event)
  AiGateway.on_entity_built(event)
end)
script.on_event({
  defines.events.on_player_mined_entity,
  defines.events.on_robot_mined_entity,
  defines.events.script_raised_destroy
}, function(event)
  RobotPolicy.on_entity_removed(event)
  OfflineSecurity.on_entity_removed(event)
  AiGateway.on_entity_removed(event)
end)
if defines.events.on_space_platform_built_entity then
  script.on_event(defines.events.on_space_platform_built_entity, function(event)
    RobotPolicy.on_entity_built(event)
    OfflineSecurity.on_entity_built(event)
    AiGateway.on_entity_built(event)
  end)
end
if defines.events.on_space_platform_mined_entity then
  script.on_event(defines.events.on_space_platform_mined_entity, function(event)
    RobotPolicy.on_entity_removed(event)
    OfflineSecurity.on_entity_removed(event)
    AiGateway.on_entity_removed(event)
  end)
end
script.on_event(defines.events.on_entity_settings_pasted, RobotPolicy.on_entity_settings_pasted)
script.on_event(defines.events.on_object_destroyed, OfflineSecurity.on_object_destroyed)
if defines.events.on_udp_packet_received then
  script.on_event(defines.events.on_udp_packet_received, AiGateway.on_udp_packet_received)
end
script.on_event(defines.events.on_gui_opened, AiGateway.on_gui_opened)
script.on_event(defines.events.on_gui_closed, AiGateway.on_gui_closed)
script.on_event(
  defines.events.on_selected_entity_changed,
  Security.on_selected_entity_changed
)
script.on_event(
  defines.events.on_player_cursor_stack_changed,
  Security.on_player_cursor_stack_changed
)
script.on_nth_tick(60, function(event)
  Spawns.tick(event)
  Evolution.sync_connected(event.tick)
  OfflineSecurity.tick(event)
  PlanetSpawns.tick(event)
  RobotPolicy.tick(event)
end)

script.on_nth_tick(30, Security.tick)

script.on_event(defines.events.on_tick, function(event)
  Security.on_tick(event)
  OfflineSecurity.on_tick(event)
  RobotPolicy.on_tick(event)
  AiGateway.poll(event)
end)

script.on_nth_tick(10 * 60, function(event)
  Radars.share_discoveries(event)
  PlayerList.tick(event)
end)

script.on_event(defines.events.on_gui_click, function(event)
  if not (event.element and event.element.valid) then return end
  if AiBlueprintGui.on_gui_click(event) then
    return
  elseif PlayerList.on_gui_click(event) then
    return
  elseif TestMenu.on_gui_click(event) then
    return
  elseif AiGateway.on_gui_click(event) then
    return
  elseif RobotPolicy.on_gui_click(event) then
    return
  else
    Spawns.on_gui_click(event)
  end
end)
