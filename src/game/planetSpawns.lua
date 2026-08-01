local State = require("src.core.state")
local Teams = require("src.game.teams")

local PlanetSpawns = {}

local CHUNK_SIZE = 32
local CANDIDATES_PER_RING = 8
local CANDIDATE_BUDGET = 8
local PROCESS_BUDGET = 2

local function setting(name, fallback)
  local value = settings.global[name]
  return value and value.value or fallback
end

local function enabled()
  return setting("sceatorio-planet-spawns-enabled", true)
end

local function safety_radius()
  return setting("sceatorio-planet-spawn-safety-radius", 48)
end

local function separation()
  return setting("sceatorio-planet-spawn-separation", 1024)
end

local function copy_position(position)
  return {x = position.x, y = position.y}
end

local function planet_for(surface)
  local ok, planet = pcall(function() return surface.planet end)
  return ok and planet or nil
end

local function platform_for(surface)
  local ok, platform = pcall(function() return surface.platform end)
  return ok and platform or nil
end

function PlanetSpawns.is_supported(surface)
  return enabled()
    and surface
    and surface.valid
    and platform_for(surface) == nil
    and planet_for(surface) ~= nil
end

function PlanetSpawns.physical_surface(player)
  local character = player and player.valid and player.character or nil
  if character and character.valid then
    -- player.surface can be a remote-view surface in Space Age. The character is
    -- the authoritative physical location for arrival and join routing.
    return player.character.surface, copy_position(character.position), character.name
  end
  return nil, nil, nil
end

local function queue_key(team_id, surface_index)
  return tostring(team_id) .. ":" .. tostring(surface_index)
end

local function queued(root, key)
  for _, entry in ipairs(root.planet_spawn_queue) do
    if entry.key == key then return true end
  end
  return false
end

local function enqueue(record, surface_record)
  local root = State.get()
  local key = queue_key(record.id, surface_record.surface_index)
  if not queued(root, key) then
    root.planet_spawn_queue[#root.planet_spawn_queue + 1] = {
      key = key,
      team_id = record.id,
      surface_index = surface_record.surface_index
    }
  end
  surface_record.planet_spawn.queued = true
end

local function distance_squared(first, second)
  local dx = first.x - second.x
  local dy = first.y - second.y
  return dx * dx + dy * dy
end

local function sufficiently_separated(record, surface, position)
  local minimum_squared = separation() * separation()
  local accepted = true
  Teams.for_each(function(other)
    if not accepted or other.id == record.id then return end
    local other_surface = Teams.get_surface(other, surface)
    if not other_surface then return end
    local other_planet = other_surface.planet_spawn
    local other_position = other_surface.spawn
      or (other_planet and other_planet.candidate)
    if other_position and distance_squared(position, other_position) < minimum_squared then
      accepted = false
    end
  end)
  return accepted
end

local function candidate_for(anchor, team_id, attempt)
  if attempt == 0 then return copy_position(anchor) end
  local slot = attempt - 1
  local ring = math.floor(slot / CANDIDATES_PER_RING) + 1
  local direction = slot % CANDIDATES_PER_RING
  local angle = direction * math.pi / 4 + (team_id % 8) * math.pi / 32
  local radius = separation() * ring
  return {
    x = anchor.x + math.cos(angle) * radius,
    y = anchor.y + math.sin(angle) * radius
  }
end

local function choose_candidate(record, surface, metadata)
  for _ = 1, CANDIDATE_BUDGET do
    local candidate = candidate_for(metadata.anchor, record.id, metadata.attempt)
    metadata.attempt = metadata.attempt + 1
    if sufficiently_separated(record, surface, candidate) then
      metadata.candidate = candidate
      local chunks = math.ceil(safety_radius() / CHUNK_SIZE) + 1
      surface.request_to_generate_chunks(candidate, chunks)
      return true
    end
  end
  return false
end

local function mark_existing_primary(record, surface, surface_record)
  local planet = planet_for(surface)
  if not (surface_record and surface_record.spawn) then return false end
  if not (surface_record.terrain_ready or (planet and planet.name == "nauvis")) then
    return false
  end
  surface_record.planet_spawn = {
    state = "ready",
    planet_name = planet and planet.name or surface.name,
    created_tick = game.tick,
    preserve_native = true,
    migrated_existing = true
  }
  local force = Teams.get_force(record)
  if force then force.set_spawn_position(surface_record.spawn, surface) end
  return true
end

local function add_waiter(metadata, player, reason, anchor)
  if not (player and player.valid) then return end
  metadata.waiting_players = metadata.waiting_players or {}
  metadata.waiting_players[player.index] = {
    reason = reason,
    anchor = anchor and copy_position(anchor) or nil
  }
end

-- Returns the stable spawn when it already exists. A nil result means the
-- caller was queued while native chunks generate asynchronously.
function PlanetSpawns.request_spawn(record, surface, anchor, player, reason)
  if not (record and surface and surface.valid) then return nil end
  local surface_record = Teams.get_surface(record, surface)

  if not PlanetSpawns.is_supported(surface) then
    return surface_record and surface_record.spawn or nil
  end

  if surface_record and surface_record.planet_spawn then
    local metadata = surface_record.planet_spawn
    if metadata.state == "ready" then
      return surface_record.spawn
    end
    add_waiter(metadata, player, reason, anchor)
    enqueue(record, surface_record)
    return nil
  end

  if mark_existing_primary(record, surface, surface_record) then
    return surface_record.spawn
  end

  if not anchor then return nil end
  surface_record = surface_record or Teams.ensure_surface(record, surface)
  surface_record.spawn = nil
  local planet = planet_for(surface)
  surface_record.planet_spawn = {
    state = "generating",
    planet_name = planet and planet.name or surface.name,
    preserve_native = true,
    anchor = copy_position(anchor),
    attempt = 0,
    created_tick = game.tick,
    waiting_players = {}
  }
  add_waiter(surface_record.planet_spawn, player, reason, anchor)
  choose_candidate(record, surface, surface_record.planet_spawn)
  enqueue(record, surface_record)
  return nil
end

local function generated(surface, position)
  return surface.is_chunk_generated({
    x = math.floor(position.x / CHUNK_SIZE),
    y = math.floor(position.y / CHUNK_SIZE)
  })
end

local function in_vulcanus_territory(surface, metadata)
  if metadata.planet_name ~= "vulcanus" then return false end
  local chunk = {
    x = math.floor(metadata.candidate.x / CHUNK_SIZE),
    y = math.floor(metadata.candidate.y / CHUNK_SIZE)
  }
  local ok, territory = pcall(function()
    return surface.get_territory_for_chunk(chunk)
  end)
  return ok and territory ~= nil
end

local function clear_immediate_hostiles(surface, position, planet_name)
  -- Segmented units (demolishers), resources, cliffs, tiles, decoratives, and
  -- unknown-planet entities are deliberately outside this native-preserving
  -- safety pass.
  if planet_name ~= "nauvis" and planet_name ~= "gleba" then return end
  for _, entity in pairs(surface.find_entities_filtered({
    position = position,
    radius = safety_radius(),
    type = {"unit", "unit-spawner", "turret"}
  })) do
    if entity.valid
      and (entity.force == game.forces.enemy or Teams.get_by_enemy_force(entity.force)) then
      entity.destroy()
    end
  end
end

local function same_team(player, record)
  local current = Teams.get_for_player(player)
  return current and current.id == record.id
end

local function route_waiters(record, surface, metadata, spawn)
  for player_index, waiter in pairs(metadata.waiting_players or {}) do
    local player = game.players[player_index]
    if player and player.valid and player.connected and same_team(player, record) then
      local physical_surface, physical_position = PlanetSpawns.physical_surface(player)
      local route = waiter.reason == "team-join" or waiter.reason == "respawn"
      if waiter.reason == "arrival" and physical_surface
        and physical_surface.index == surface.index and waiter.anchor then
        local allowed = safety_radius() * 2
        route = distance_squared(physical_position, waiter.anchor) <= allowed * allowed
      end
      if route then
        if player.teleport(spawn, surface) then
          player.print({"sceatorio.planet-spawn-ready", metadata.planet_name})
        else
          player.print({"sceatorio.teleport-failed"})
        end
      else
        player.print({"sceatorio.planet-spawn-recorded", metadata.planet_name})
      end
    end
  end
  metadata.waiting_players = nil
end

local function set_cargo_hold(cargo_pod, held)
  local ok = pcall(function() cargo_pod.disabled_by_script = held end)
  return ok
end

local function route_cargo_pods(surface, metadata, spawn)
  for _, reservation in pairs(metadata.cargo_pods or {}) do
    local cargo_pod = reservation.entity
    if cargo_pod and cargo_pod.valid then
      if spawn and reservation.ground_destination then
        local destination = {
          type = defines.cargo_destination.surface,
          surface = surface,
          position = spawn,
          land_at_exact_position = true
        }
        if reservation.transform_launch_products ~= nil then
          destination.transform_launch_products = reservation.transform_launch_products
        end
        pcall(function() cargo_pod.cargo_pod_destination = destination end)
      end
      if reservation.held then set_cargo_hold(cargo_pod, false) end
    end
  end
  metadata.cargo_pods = nil
end

local function finalize(record, surface, surface_record)
  local metadata = surface_record.planet_spawn
  if not metadata.candidate then
    choose_candidate(record, surface, metadata)
    return false
  end
  if not generated(surface, metadata.candidate) then return false end
  if in_vulcanus_territory(surface, metadata) then
    metadata.candidate = nil
    choose_candidate(record, surface, metadata)
    return false
  end

  local character_name = "character"
  for player_index in pairs(metadata.waiting_players or {}) do
    local player = game.players[player_index]
    if player and player.valid and player.character and player.character.valid then
      character_name = player.character.name
      break
    end
  end
  local spawn = surface.find_non_colliding_position(
    character_name,
    metadata.candidate,
    safety_radius(),
    1
  )
  if not spawn or not sufficiently_separated(record, surface, spawn) then
    metadata.candidate = nil
    choose_candidate(record, surface, metadata)
    return false
  end

  clear_immediate_hostiles(surface, spawn, metadata.planet_name)
  surface_record.spawn = copy_position(spawn)
  surface_record.terrain_ready = true
  metadata.state = "ready"
  metadata.ready_tick = game.tick
  metadata.candidate = nil
  metadata.queued = false
  metadata.anchor = nil
  local force = Teams.get_force(record)
  if force and force.valid then force.set_spawn_position(spawn, surface) end
  route_cargo_pods(surface, metadata, spawn)
  route_waiters(record, surface, metadata, spawn)
  return true
end

local function process_entry(entry)
  local record = Teams.get(entry.team_id)
  local surface = game.surfaces[entry.surface_index]
  if not (record and surface and surface.valid) then return true end
  local surface_record = Teams.get_surface(record, surface)
  if not (surface_record and surface_record.planet_spawn) then return true end
  if surface_record.planet_spawn.state == "ready" then return true end
  return finalize(record, surface, surface_record)
end

function PlanetSpawns.tick()
  if not enabled() then return end
  local root = State.get()
  local processed = 0
  while processed < PROCESS_BUDGET and #root.planet_spawn_queue > 0 do
    if root.planet_spawn_cursor > #root.planet_spawn_queue then
      root.planet_spawn_cursor = 1
    end
    local index = root.planet_spawn_cursor
    local complete = process_entry(root.planet_spawn_queue[index])
    if complete then
      table.remove(root.planet_spawn_queue, index)
    else
      root.planet_spawn_cursor = index + 1
    end
    processed = processed + 1
  end
end

local function ensure_physical_arrival(player, reason)
  local record = Teams.get_for_player(player)
  if not record then return nil end
  local surface, position = PlanetSpawns.physical_surface(player)
  if not surface then return nil end
  State.get().player_character_surfaces[player.index] = surface.index
  return PlanetSpawns.request_spawn(record, surface, position, player, reason)
end

function PlanetSpawns.on_player_joined(event)
  local player = game.players[event.player_index]
  if player and player.valid then ensure_physical_arrival(player, "arrival") end
end

function PlanetSpawns.on_player_changed_force(event)
  local player = game.players[event.player_index]
  if player and player.valid then ensure_physical_arrival(player, "arrival") end
end

function PlanetSpawns.on_player_changed_surface(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  local surface = PlanetSpawns.physical_surface(player)
  if not surface then return end
  local root = State.get()
  if root.player_character_surfaces[player.index] == surface.index then return end
  root.player_character_surfaces[player.index] = surface.index
  ensure_physical_arrival(player, "arrival")
end

function PlanetSpawns.on_player_respawned(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  local spawn = ensure_physical_arrival(player, "respawn")
  local surface = PlanetSpawns.physical_surface(player)
  if spawn and surface then player.teleport(spawn, surface) end
end

function PlanetSpawns.on_cargo_pod_finished_descending(event)
  local player = event.player_index and game.players[event.player_index] or nil
  if player and player.valid then
    ensure_physical_arrival(player, "arrival")
    return
  end
  local cargo_pod = event.cargo_pod
  if not (cargo_pod and cargo_pod.valid) then return end
  -- Cargo events without a player are deliberately not attributed to a team;
  -- cargo ownership can be ambiguous on shared or scripted modded deliveries.
end

local function destination_surface(destination)
  if not destination or destination.type ~= defines.cargo_destination.surface then
    return nil
  end
  if type(destination.surface) == "number" or type(destination.surface) == "string" then
    return game.surfaces[destination.surface]
  end
  local surface = destination.surface
  return surface and surface.valid and surface or nil
end

function PlanetSpawns.on_cargo_pod_started_ascending(event)
  local player = event.player_index and game.players[event.player_index] or nil
  local cargo_pod = event.cargo_pod
  if not (player and player.valid and cargo_pod and cargo_pod.valid) then return end
  local record = Teams.get_for_player(player)
  if not record then return end
  local ok, destination = pcall(function() return cargo_pod.cargo_pod_destination end)
  if not ok then return end
  local surface = destination_surface(destination)
  if not PlanetSpawns.is_supported(surface) then return end

  local existing = Teams.get_surface(record, surface)
  if existing and existing.planet_spawn and existing.planet_spawn.state == "ready" then
    -- A later trip keeps its explicit destination. Stable spawn reuse is for
    -- joins and respawns, not a reason to hijack normal same-team travel.
    return
  end
  local anchor = destination.position or {x = 0, y = 0}
  PlanetSpawns.request_spawn(record, surface, anchor, nil, "cargo-prearrival")
  local surface_record = Teams.get_surface(record, surface)
  local metadata = surface_record and surface_record.planet_spawn or nil
  if not (metadata and metadata.state ~= "ready") then return end

  metadata.cargo_pods = metadata.cargo_pods or {}
  local cargo_key = cargo_pod.unit_number or ("player-" .. player.index)
  local held = false
  local read_ok, already_disabled = pcall(function() return cargo_pod.disabled_by_script end)
  if read_ok and not already_disabled then held = set_cargo_hold(cargo_pod, true) end
  metadata.cargo_pods[cargo_key] = {
    entity = cargo_pod,
    held = held,
    ground_destination = true,
    transform_launch_products = destination.transform_launch_products
  }
  player.print({"sceatorio.planet-spawn-preparing"})
end

local function release_pending_cargo()
  Teams.for_each(function(record)
    for _, surface_record in pairs(record.surfaces or {}) do
      local metadata = surface_record.planet_spawn
      if metadata and metadata.cargo_pods then route_cargo_pods(nil, metadata, nil) end
    end
  end)
end

function PlanetSpawns.initialize()
  local root = State.get()
  root.player_character_surfaces = root.player_character_surfaces or {}
  root.planet_spawn_queue = root.planet_spawn_queue or {}
  root.planet_spawn_cursor = root.planet_spawn_cursor or 1

  Teams.for_each(function(record)
    for surface_index, surface_record in pairs(record.surfaces or {}) do
      local metadata = surface_record.planet_spawn
      if metadata and metadata.state ~= "ready" then
        local surface = game.surfaces[surface_index]
        if surface and surface.valid and PlanetSpawns.is_supported(surface) then
          enqueue(record, surface_record)
        end
      end
    end
  end)
  for _, player in pairs(game.players) do
    local surface = PlanetSpawns.physical_surface(player)
    if surface then root.player_character_surfaces[player.index] = surface.index end
  end
end

function PlanetSpawns.on_setting_changed(event)
  if string.sub(event.setting, 1, #"sceatorio-planet-spawn") ~= "sceatorio-planet-spawn" then
    return
  end
  if enabled() then
    PlanetSpawns.initialize()
  else
    -- Fail open: a runtime setting change must never strand a rider in a pod.
    release_pending_cargo()
  end
end

function PlanetSpawns.on_surface_deleted(event)
  local root = State.get()
  Teams.for_each(function(record)
    local surface_record = record.surfaces and record.surfaces[event.surface_index] or nil
    local metadata = surface_record and surface_record.planet_spawn or nil
    if metadata and metadata.cargo_pods then route_cargo_pods(nil, metadata, nil) end
  end)
  for index = #root.planet_spawn_queue, 1, -1 do
    if root.planet_spawn_queue[index].surface_index == event.surface_index then
      table.remove(root.planet_spawn_queue, index)
    end
  end
  root.planet_spawn_cursor = 1
  for player_index, surface_index in pairs(root.player_character_surfaces) do
    if surface_index == event.surface_index then
      root.player_character_surfaces[player_index] = nil
    end
  end
end

function PlanetSpawns.on_forces_merged(event)
  local surviving = Teams.get_by_force(event.destination)
  if not surviving then return end
  for surface_index, surface_record in pairs(surviving.surfaces or {}) do
    local metadata = surface_record.planet_spawn
    local surface = game.surfaces[surface_index]
    if metadata and metadata.state == "ready" then
      if metadata.cargo_pods then
        route_cargo_pods(surface, metadata, surface_record.spawn)
      end
      if metadata.waiting_players and surface and surface.valid then
        route_waiters(surviving, surface, metadata, surface_record.spawn)
      end
    elseif metadata and metadata.state ~= "ready" and surface and surface.valid then
      enqueue(surviving, surface_record)
    end
  end
end

return PlanetSpawns
