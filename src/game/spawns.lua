local State = require("src.core.state")
local Teams = require("src.game.teams")
local Compute = require("src.utils.compute")
local Message = require("src.utils.msg")
local PlanetSpawns = require("src.game.planetSpawns")
local SurfacePolicy = require("src.game.surfacePolicy")

local Spawns = {}

local CONFIG = {
  minimum_spawn_distance_chunks = 90,
  maximum_spawn_distance_chunks = 110,
  base_size = 90,
  safe_zone = 220,
  warning_zone = 500,
  water_modifier = 3000,
  terrain_tile = "sand-1",
  lobby_spawn = {x = 0, y = 0},
  lobby_size = 20,
  join_request_lifetime = 60 * 60,
  gui_delay = 10 * 60,
  teleport_delay = 5 * 60,
  spawn_generation_radius_chunks = 3,
  resources = {
    {name = "stone", x = -55, y = 25, size = 15, amount = 1000},
    {name = "coal", x = -30, y = 25, size = 15, amount = 1500},
    {name = "copper-ore", x = -5, y = 25, size = 15, amount = 1500},
    {name = "iron-ore", x = 20, y = 25, size = 15, amount = 1500},
    {name = "uranium-ore", x = 45, y = 25, size = 15, amount = 1000}
  },
  oil = {count = 4, x = 15, y = 60, x_offset = -5, y_offset = 0, amount = 300000},
  water = {x = -10, y = -50, length = 20, width = 5}
}

function Spawns.configure_freeplay()
  local interface = remote.interfaces.freeplay
  if not interface then return end
  local calls = {
    {name = "set_skip_intro", value = true},
    {name = "set_disable_crashsite", value = true},
    {name = "set_created_items", value = {}},
    {name = "set_respawn_items", value = {}}
  }
  for _, request in ipairs(calls) do
    if interface[request.name] then
      local ok, reason = pcall(remote.call, "freeplay", request.name, request.value)
      if not ok then
        log("[Sceatorio] freeplay " .. request.name .. " was unavailable: " .. reason)
      end
    end
  end
end

local function destroy_named_gui(player, name)
  local element = player.gui.screen[name]
  if element and element.valid then
    element.destroy()
  end
end

local function clear_hostiles(surface, area)
  for _, entity in pairs(surface.find_entities_filtered({
    area = area,
    type = {"unit", "unit-spawner", "turret"}
  })) do
    if entity.force == game.forces.enemy or Teams.get_by_enemy_force(entity.force) then
      entity.destroy()
    end
  end
end

local DOWNGRADED_WORMS = {
  ["big-worm-turret"] = true,
  ["behemoth-worm-turret"] = true
}
local WORM_REPLACEMENT = "small-worm-turret"

-- Vanilla map generation places big and behemoth worms purely by distance from
-- the origin, and team spawns land 90-110 chunks out. Multiplayer lockstep
-- forbids drawing from the shared RNG stream here: the surviving set has to
-- resolve identically on every peer, so it is derived from the entity's own
-- position instead. Keeps one nest in three.
local function survives_thinning(position)
  return (math.floor(position.x) + math.floor(position.y)) % 3 == 0
end

-- Warning ring, between the safe zone and the warning zone: worms are
-- downgraded to their smallest variant and nests are thinned rather than the
-- ring being wiped, so it stays a soft border instead of a second safe zone.
local function soften_in_warning_ring(surface, entity)
  local position = entity.position
  if DOWNGRADED_WORMS[entity.name] then
    local force = entity.force
    entity.destroy()
    if prototypes.entity[WORM_REPLACEMENT] then
      surface.create_entity({
        name = WORM_REPLACEMENT,
        position = position,
        force = force
      })
    end
  elseif not survives_thinning(position) then
    entity.destroy()
  end
end

local function prepare_spawn(record, surface, spawn)
  local base_area = Compute.area_around(spawn, CONFIG.base_size)
  local safe_area = Compute.area_around(spawn, CONFIG.safe_zone)

  Compute.remove_in_circle(surface, base_area, "tree", spawn, CONFIG.base_size + 5)
  Compute.remove_in_circle(surface, base_area, "resource", spawn, CONFIG.base_size + 5)
  Compute.remove_in_circle(surface, base_area, "cliff", spawn, CONFIG.base_size + 5)
  surface.destroy_decoratives({area = base_area})
  Compute.crop_border(surface, spawn, base_area, CONFIG.base_size, CONFIG.terrain_tile)
  Compute.water_border(
    surface,
    spawn,
    safe_area,
    CONFIG.base_size,
    CONFIG.water_modifier
  )

  for _, resource in ipairs(CONFIG.resources) do
    if prototypes.entity[resource.name] then
      Compute.generate_resource_patch(
        surface,
        resource.name,
        resource.size,
        {x = spawn.x + resource.x, y = spawn.y + resource.y},
        resource.amount
      )
    end
  end

  if prototypes.entity["crude-oil"] then
    for index = 0, CONFIG.oil.count - 1 do
      surface.create_entity({
        name = "crude-oil",
        amount = CONFIG.oil.amount,
        position = {
          spawn.x + CONFIG.oil.x + CONFIG.oil.x_offset * index,
          spawn.y + CONFIG.oil.y + CONFIG.oil.y_offset * index
        }
      })
    end
  end

  for row = 0, CONFIG.water.width - 1 do
    Compute.create_water_strip(
      surface,
      {x = spawn.x + CONFIG.water.x, y = spawn.y + CONFIG.water.y + row},
      CONFIG.water.length
    )
  end

  clear_hostiles(surface, Compute.area_around(spawn, CONFIG.safe_zone))
  Teams.ensure_surface(record, surface, spawn).terrain_ready = true
end

local function schedule_spawn_gui(player_index, tick)
  State.get().scheduled_gui[player_index] = tick + CONFIG.gui_delay
end

local function lobby_force()
  return Teams.ensure_lobby()
end

local function is_in_lobby(player)
  local lobby = lobby_force()
  return player.force.index == lobby.index
end

local function physical_surface(player)
  local surface, position = PlanetSpawns.physical_surface(player)
  return surface, position
end

local function team_destination(record, target)
  local surface, position = physical_surface(target)
  local surface_record = surface and Teams.get_surface(record, surface) or nil
  if surface and (
    PlanetSpawns.is_supported(surface)
    or (surface.name == "nauvis" and surface_record and surface_record.spawn)
  ) then
    return surface, position
  end

  local nauvis = game.surfaces.nauvis
  local nauvis_record = nauvis and Teams.get_surface(record, nauvis) or nil
  if nauvis_record and nauvis_record.spawn then
    return nauvis, nauvis_record.spawn
  end
  local surface_indexes = {}
  for surface_index in pairs(record.surfaces or {}) do
    surface_indexes[#surface_indexes + 1] = surface_index
  end
  table.sort(surface_indexes)
  for _, surface_index in ipairs(surface_indexes) do
    local candidate = record.surfaces[surface_index]
    local candidate_surface = game.surfaces[surface_index]
    if candidate.spawn and PlanetSpawns.is_supported(candidate_surface) then
      return candidate_surface, candidate.spawn
    end
  end
  return nil, nil
end

local function invalidate_prompt(player)
  local prompt = player.gui.screen.sceatorio_join_request
  if prompt and prompt.valid then
    local token = prompt.tags and prompt.tags.join_token
    if type(token) == "number" then
      local request = State.get().join_requests[token]
      State.get().join_requests[token] = nil
      local requester = request and game.players[request.requester_index] or nil
      if requester and requester.valid and requester.connected and is_in_lobby(requester) then
        requester.print({"sceatorio.join-request-expired"})
        Spawns.show_spawn_gui(requester)
      end
    end
    prompt.destroy()
  end
end

function Spawns.show_spawn_gui(player)
  if not (player and player.valid and is_in_lobby(player)) then return end
  destroy_named_gui(player, "sceatorio_spawn")

  local frame = player.gui.screen.add({
    type = "frame",
    direction = "vertical",
    name = "sceatorio_spawn",
    caption = {"sceatorio.spawn-title"}
  })
  frame.auto_center = true
  frame.add({type = "label", caption = {"sceatorio.spawn-welcome"}})
  frame.add({
    type = "button",
    name = "sceatorio_spawn_alone",
    caption = {"sceatorio.create-team"},
    tags = {sceatorio_action = "spawn_alone"}
  })
  frame.add({type = "line"})
  frame.add({type = "label", caption = {"sceatorio.join-team"}})

  local listed_teams = {}
  for _, target in pairs(game.connected_players) do
    local record = Teams.get_for_player(target)
    if record and not listed_teams[record.id] then
      listed_teams[record.id] = true
      frame.add({
        type = "button",
        name = "sceatorio_join_team_" .. record.id,
        caption = {"sceatorio.join-player", target.name},
        tags = {
          sceatorio_action = "request_join",
          target_player_index = target.index,
          target_team_id = record.id
        }
      })
    end
  end
  player.opened = frame
end

local function show_join_prompt(target, requester, token)
  invalidate_prompt(target)
  local frame = target.gui.screen.add({
    type = "frame",
    direction = "vertical",
    name = "sceatorio_join_request",
    caption = {"sceatorio.join-request-title"},
    tags = {join_token = token}
  })
  frame.auto_center = true
  frame.add({type = "label", caption = {"sceatorio.join-request", requester.name}})
  local buttons = frame.add({type = "flow", direction = "horizontal"})
  buttons.add({
    type = "button",
    name = "sceatorio_accept_join",
    caption = {"sceatorio.accept"},
    tags = {sceatorio_action = "accept_join", join_token = token}
  })
  buttons.add({
    type = "button",
    name = "sceatorio_refuse_join",
    caption = {"sceatorio.refuse"},
    tags = {sceatorio_action = "refuse_join", join_token = token}
  })
  target.opened = frame
end

local function request_join(player, tags, tick)
  if not is_in_lobby(player) then return end
  local target = tags.target_player_index and game.players[tags.target_player_index] or nil
  local record = tags.target_team_id and Teams.get(tags.target_team_id) or nil
  if not (target and target.valid and target.connected and record) then
    player.print({"sceatorio.join-target-unavailable"})
    Spawns.show_spawn_gui(player)
    return
  end
  local current_record = Teams.get_for_player(target)
  if not current_record or current_record.id ~= record.id then
    player.print({"sceatorio.join-target-changed-team"})
    Spawns.show_spawn_gui(player)
    return
  end

  local target_surface, target_position = team_destination(record, target)
  if not target_surface then
    player.print({"sceatorio.join-target-unavailable"})
    Spawns.show_spawn_gui(player)
    return
  end

  local root = State.get()
  local token = root.next_join_token
  root.next_join_token = token + 1
  root.join_requests[token] = {
    token = token,
    requester_index = player.index,
    target_player_index = target.index,
    target_team_id = record.id,
    target_surface_index = target_surface.index,
    target_position = target_position and {x = target_position.x, y = target_position.y} or nil,
    expires_tick = tick + CONFIG.join_request_lifetime
  }
  destroy_named_gui(player, "sceatorio_spawn")
  show_join_prompt(target, player, token)
  player.print({"sceatorio.join-request-sent", target.name})
end

local function validated_request(actor, token, tick)
  if type(token) ~= "number" then return nil end
  local request = State.get().join_requests[token]
  if not request or request.target_player_index ~= actor.index or request.expires_tick < tick then
    return nil
  end
  local requester = game.players[request.requester_index]
  local record = Teams.get(request.target_team_id)
  local target_record = Teams.get_for_player(actor)
  if not (requester and requester.valid and requester.connected and is_in_lobby(requester)) then
    return nil
  end
  if not (record and target_record and target_record.id == record.id) then
    return nil
  end
  return request, requester, record
end

local function finish_request(actor, token)
  if type(token) == "number" then
    State.get().join_requests[token] = nil
  end
  local prompt = actor.gui.screen.sceatorio_join_request
  if prompt and prompt.valid then
    local prompt_token = prompt.tags and prompt.tags.join_token
    if type(token) == "number" and prompt_token == token then
      prompt.destroy()
    end
  end
end

local function destroy_request_prompt(request, token)
  local target = request and game.players[request.target_player_index] or nil
  local prompt = target and target.valid and target.gui.screen.sceatorio_join_request or nil
  if prompt and prompt.valid and prompt.tags and prompt.tags.join_token == token then
    prompt.destroy()
  end
end

local function reopen_requester(request, message)
  local requester = request and game.players[request.requester_index] or nil
  if requester and requester.valid and requester.connected and is_in_lobby(requester) then
    if message then requester.print(message) end
    Spawns.show_spawn_gui(requester)
  end
end

local function mark_force_transition(player, force, tick)
  local root = State.get()
  root.force_transitions = root.force_transitions or {}
  root.force_transitions[player.index] = {
    force_index = force.index,
    tick = tick
  }
end

local function accept_join(actor, token, tick)
  local request, player, record = validated_request(actor, token, tick)
  if not request then
    actor.print({"sceatorio.join-request-expired"})
    finish_request(actor, token)
    return
  end

  local target_force = Teams.get_force(record)
  local destination_surface = game.surfaces[request.target_surface_index]
  if not (target_force and destination_surface and destination_surface.valid) then
    actor.print({"sceatorio.join-target-unavailable"})
    finish_request(actor, token)
    return
  end

  local spawn = PlanetSpawns.request_spawn(
    record,
    destination_surface,
    request.target_position,
    player,
    "team-join"
  )
  if spawn then
    if not player.teleport(spawn, destination_surface) then
      player.print({"sceatorio.teleport-failed"})
      finish_request(actor, token)
      Spawns.show_spawn_gui(player)
      return
    end
  end

  -- A normal force-change hook interprets the player's old physical lobby
  -- position as a new team arrival. Suppress only this deliberate transition:
  -- the requested destination above is already authoritative.
  mark_force_transition(player, target_force, tick)
  player.force = target_force
  if not spawn then player.print({"sceatorio.planet-spawn-preparing"}) end
  finish_request(actor, token)
  Message.say(player.name .. " joined " .. record.display_name .. ".")
end

local function refuse_join(actor, token, tick)
  local request, requester = validated_request(actor, token, tick)
  finish_request(actor, token)
  if request and requester then
    requester.print({"sceatorio.join-refused", actor.name})
    Spawns.show_spawn_gui(requester)
  else
    actor.print({"sceatorio.join-request-expired"})
  end
end

local function generate_player_spawn(player, tick)
  if not is_in_lobby(player) then return false end
  if State.get().pending_teleports[player.index] then
    player.print({"sceatorio.spawn-preparing"})
    return true
  end
  if not Teams.can_create() then
    player.print({"sceatorio.force-limit"})
    return false
  end

  local surface = physical_surface(player)
  if not surface then
    player.print({"sceatorio.no-spawn-found"})
    return false
  end
  local spawn = Compute.find_ungenerated_coordinates(
    CONFIG.minimum_spawn_distance_chunks,
    CONFIG.maximum_spawn_distance_chunks,
    surface
  )
  if not spawn then
    player.print({"sceatorio.no-spawn-found"})
    return false
  end

  local record, reason = Teams.create(player)
  if not record then
    player.print(reason)
    return false
  end
  local team_force = Teams.get_force(record)
  team_force.set_spawn_position(spawn, surface)
  Teams.ensure_surface(record, surface, spawn)
  surface.request_to_generate_chunks(spawn, CONFIG.spawn_generation_radius_chunks)

  State.get().pending_teleports[player.index] = {
    player_index = player.index,
    team_id = record.id,
    surface_index = surface.index,
    spawn = {x = spawn.x, y = spawn.y},
    due_tick = tick + CONFIG.teleport_delay,
    terrain_ready = false
  }
  player.print({"sceatorio.spawn-preparing"})
  Message.say(player.name .. " created a new team.")
  return true
end

function Spawns.on_gui_click(event)
  local element = event.element
  if not (element and element.valid) then return false end
  local tags = element.tags or {}
  local action = tags.sceatorio_action
  if not action then return false end

  local player = game.players[event.player_index]
  if not (player and player.valid) then return true end
  if action == "spawn_alone" then
    if generate_player_spawn(player, event.tick) then
      destroy_named_gui(player, "sceatorio_spawn")
    end
  elseif action == "request_join" then
    request_join(player, tags, event.tick)
  elseif action == "accept_join" then
    accept_join(player, tags.join_token, event.tick)
  elseif action == "refuse_join" then
    refuse_join(player, tags.join_token, event.tick)
  end
  return true
end

function Spawns.on_player_created(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  local lobby = lobby_force()
  player.force = lobby
  lobby.set_spawn_position(CONFIG.lobby_spawn, player.surface)
  player.teleport(CONFIG.lobby_spawn, player.surface)
  schedule_spawn_gui(player.index, event.tick)
  Message.say(player.name .. " joined the lobby.")
end

function Spawns.on_player_joined(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  if is_in_lobby(player) and not State.get().pending_teleports[player.index] then
    schedule_spawn_gui(player.index, event.tick)
  end
end

local function requested_chunks_ready(surface, position)
  local center = {
    x = math.floor(position.x / 32),
    y = math.floor(position.y / 32)
  }
  local radius = CONFIG.spawn_generation_radius_chunks
  for x = center.x - radius, center.x + radius do
    for y = center.y - radius, center.y + radius do
      if not surface.is_chunk_generated({x = x, y = y}) then return false end
    end
  end
  return true
end

function Spawns.tick(event)
  local root = State.get()
  for player_index, show_tick in pairs(root.scheduled_gui) do
    if event.tick >= show_tick then
      local player = game.players[player_index]
      if player and player.valid and player.connected
        and not root.pending_teleports[player_index] then
        Spawns.show_spawn_gui(player)
      end
      root.scheduled_gui[player_index] = nil
    end
  end

  for token, request in pairs(root.join_requests) do
    if event.tick > request.expires_tick then
      destroy_request_prompt(request, token)
      reopen_requester(request, {"sceatorio.join-request-expired"})
      root.join_requests[token] = nil
    end
  end

  -- Full primary-spawn terraforming is a one-off synchronous operation. Never
  -- stack multiple preparations in the same once-per-second pass.
  local prepared_this_tick = false
  for player_index, pending in pairs(root.pending_teleports) do
    local surface = game.surfaces[pending.surface_index]
    local record = Teams.get(pending.team_id)
    local player = game.players[player_index]
    if not (surface and surface.valid and record and player and player.valid) then
      root.pending_teleports[player_index] = nil
    else
      if not prepared_this_tick and not pending.terrain_ready
        and requested_chunks_ready(surface, pending.spawn) then
        prepare_spawn(record, surface, pending.spawn)
        pending.terrain_ready = true
        prepared_this_tick = true
      end
      if pending.terrain_ready and event.tick >= pending.due_tick and player.connected then
        local team_force = Teams.get_force(record)
        if not (team_force and team_force.valid) then
          root.pending_teleports[player_index] = nil
        elseif player.teleport(pending.spawn, surface) then
          mark_force_transition(player, team_force, event.tick)
          player.force = team_force
          player.print({"sceatorio.teleported"})
          root.pending_teleports[player_index] = nil
        else
          player.print({"sceatorio.teleport-failed"})
          pending.due_tick = event.tick + 60
        end
      end
    end
  end


  local transitions = root.force_transitions or {}
  for player_index, transition in pairs(transitions) do
    if event.tick > transition.tick + 1 then transitions[player_index] = nil end
  end
end

function Spawns.on_chunk_generated(event)
  local surface = event.surface
  if not SurfacePolicy.is_native_hostile_surface(surface) then return end
  for _, entity in pairs(surface.find_entities_filtered({
    force = game.forces.enemy,
    area = event.area,
    type = {"unit", "unit-spawner", "turret"}
  })) do
    local nearest = Teams.find_nearest(surface, entity.position)
    if nearest.team and nearest.enemy_force then
      entity.force = nearest.enemy_force
      local planet_spawn = nearest.surface_record and nearest.surface_record.planet_spawn
      local native_preserving = planet_spawn and not planet_spawn.migrated_existing
      local safe_zone = native_preserving
        and settings.global["sceatorio-planet-spawn-safety-radius"].value
        or CONFIG.safe_zone
      if nearest.distance < safe_zone then
        entity.destroy()
      elseif not native_preserving and nearest.distance < CONFIG.warning_zone then
        soften_in_warning_ring(surface, entity)
      end
    end
  end
end

function Spawns.on_biter_base_built(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if not SurfacePolicy.is_native_hostile_surface(entity.surface) then return end
  local nearest = Teams.find_nearest(entity.surface, entity.position)
  if nearest.enemy_force and entity.force.index ~= nearest.enemy_force.index then
    entity.destroy()
  end
end

function Spawns.on_build_base_arrived(event)
  local commandable = event.group or event.unit
  if not (commandable and commandable.valid) then return end
  if not SurfacePolicy.is_native_hostile_surface(commandable.surface) then return end
  local nearest = Teams.find_nearest(commandable.surface, commandable.position)
  if not nearest.enemy_force or commandable.force.index == nearest.enemy_force.index then return end

  if event.unit then
    event.unit.destroy()
  elseif event.group then
    for _, entity in ipairs(event.group.members) do
      if entity.valid then entity.destroy() end
    end
  end
end

function Spawns.initialize_new_game()
  local surface = game.surfaces.nauvis or game.surfaces[1]
  local lobby = lobby_force()
  lobby.set_spawn_position(CONFIG.lobby_spawn, surface)
  surface.request_to_generate_chunks(CONFIG.lobby_spawn, 4)
  surface.force_generate_chunk_requests()

  local base_area = Compute.area_around(CONFIG.lobby_spawn, CONFIG.lobby_size)
  local safe_area = Compute.area_around(CONFIG.lobby_spawn, CONFIG.lobby_size * 2)
  local lobby_tile = prototypes.tile["tutorial-grid"] and "tutorial-grid" or CONFIG.terrain_tile
  Compute.create_terrain(surface, CONFIG.lobby_spawn, base_area, CONFIG.lobby_size, lobby_tile)
  surface.destroy_decoratives({area = base_area})
  Compute.water_border(
    surface,
    CONFIG.lobby_spawn,
    safe_area,
    CONFIG.lobby_size,
    CONFIG.water_modifier
  )
  clear_hostiles(surface, Compute.area_around(CONFIG.lobby_spawn, 200))
  Compute.remove_in_circle(surface, base_area, "tree", CONFIG.lobby_spawn, CONFIG.lobby_size + 5)
  Compute.remove_in_circle(surface, base_area, "resource", CONFIG.lobby_spawn, CONFIG.lobby_size + 5)
  Compute.remove_in_circle(surface, base_area, "cliff", CONFIG.lobby_spawn, CONFIG.lobby_size + 5)
end

function Spawns.on_player_left(event)
  local root = State.get()
  for token, request in pairs(root.join_requests) do
    if request.requester_index == event.player_index then
      destroy_request_prompt(request, token)
      root.join_requests[token] = nil
    elseif request.target_player_index == event.player_index then
      destroy_request_prompt(request, token)
      reopen_requester(request, {"sceatorio.join-target-unavailable"})
      root.join_requests[token] = nil
    end
  end
end

function Spawns.on_player_changed_force(event)
  local root = State.get()
  local transitions = root.force_transitions or {}
  local transition = transitions[event.player_index]
  local player = game.players[event.player_index]
  if transition then
    transitions[event.player_index] = nil
    if player and player.valid and player.force.index == transition.force_index
      and event.tick <= transition.tick + 1 then
      return
    end
  end
  PlanetSpawns.on_player_changed_force(event)
end

function Spawns.on_surface_deleted(event)
  local root = State.get()
  for player_index, pending in pairs(root.pending_teleports) do
    if pending.surface_index == event.surface_index then
      local player = game.players[player_index]
      if player and player.valid and player.connected then
        player.print({"sceatorio.join-target-unavailable"})
      end
      root.pending_teleports[player_index] = nil
    end
  end
  for token, request in pairs(root.join_requests) do
    if request.target_surface_index == event.surface_index then
      destroy_request_prompt(request, token)
      reopen_requester(request, {"sceatorio.join-target-unavailable"})
      root.join_requests[token] = nil
    end
  end
end

function Spawns.on_forces_merged()
  local root = State.get()
  for player_index, pending in pairs(root.pending_teleports) do
    if not Teams.get(pending.team_id) then
      local player = game.players[player_index]
      local surviving = player and player.valid and Teams.get_for_player(player) or nil
      if surviving then
        pending.team_id = surviving.id
      else
        root.pending_teleports[player_index] = nil
      end
    end
  end
  for token, request in pairs(root.join_requests) do
    if not Teams.get(request.target_team_id) then
      local target = game.players[request.target_player_index]
      local surviving = target and target.valid and Teams.get_for_player(target) or nil
      if surviving then
        request.target_team_id = surviving.id
      else
        destroy_request_prompt(request, token)
        reopen_requester(request, {"sceatorio.join-target-unavailable"})
        root.join_requests[token] = nil
      end
    end
  end
end

function Spawns.on_configuration_changed()
  local surface = game.surfaces.nauvis or game.surfaces[1]
  lobby_force().set_spawn_position(CONFIG.lobby_spawn, surface)
  for player_index, pending in pairs(State.get().pending_teleports) do
    if not pending.team_id then
      local player = game.players[player_index]
      local record = player and Teams.get_for_player(player) or nil
      if record then
        pending.team_id = record.id
        pending.surface_index = pending.surface_index or player.surface.index
      end
    end
  end
  State.get().force_transitions = {}
end

function Spawns.find_nearest(surface, position, ignore_team_id)
  return Teams.find_nearest(surface, position, ignore_team_id)
end

return Spawns
