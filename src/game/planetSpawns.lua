local State = require("src.core.state")
local Teams = require("src.game.teams")
local SurfacePolicy = require("src.game.surfacePolicy")

local PlanetSpawns = {}

local CHUNK_SIZE = 32
local CANDIDATES_PER_RING = 8
local CANDIDATE_BUDGET = 8
local MAX_CANDIDATE_ATTEMPTS = 64
local PROCESS_BUDGET = 2
-- Match Oarc's temporary Vulcanus workaround exactly: a six-chunk warning
-- radius, event-tracked segmented entities, and one entity checked per tick.
local VULCANUS_DEMOLISHER_SAFE_RADIUS = 6 * CHUNK_SIZE
local VULCANUS_POLICY_VERSION = 1
local DEMOLISHER_NAMES = {
  ["big-demolisher"] = true,
  ["medium-demolisher"] = true,
  ["small-demolisher"] = true
}

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

local function generation_chunk_radius()
  return math.ceil(safety_radius() / CHUNK_SIZE) + 1
end

local function copy_position(position)
  return {x = position.x, y = position.y}
end

function PlanetSpawns.is_supported(surface)
  return enabled()
    and SurfacePolicy.is_real_planet(surface)
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

local function demolisher_tracker()
  local root = State.get()
  root.demolisher_tracker = root.demolisher_tracker or {}
  root.demolisher_tracker.demolishers = root.demolisher_tracker.demolishers or {}
  return root.demolisher_tracker
end

function PlanetSpawns.on_segment_entity_created(event)
  local entity = event.entity
  if not (entity and entity.valid and entity.type == "segmented-unit") then return end
  if not (DEMOLISHER_NAMES[entity.name] and entity.unit_number) then return end
  local tracker = demolisher_tracker()
  if tracker.demolishers[entity.unit_number] == nil then
    tracker.demolishers[entity.unit_number] = entity
  end
end

-- Oarc's workaround intentionally checks a single tracked demolisher each
-- tick. Destroying the segment entity removes the demolisher and grants its
-- territory without rewriting tiles, resources, or territory data.
function PlanetSpawns.on_tick()
  if not enabled() then return end
  local tracker = demolisher_tracker()
  local index, next_demolisher = next(tracker.demolishers, tracker.index)
  if next_demolisher == nil then
    tracker.index = nil
    return
  end

  if next_demolisher.valid then
    local closest_spawn = Teams.find_nearest(
      next_demolisher.surface,
      next_demolisher.position
    )
    if closest_spawn.team == nil then return end
    if closest_spawn.distance < VULCANUS_DEMOLISHER_SAFE_RADIUS then
      next_demolisher.destroy()
      tracker.demolishers[index] = nil
      tracker.index = nil
    else
      tracker.index = index
    end
  else
    tracker.demolishers[index] = nil
    tracker.index = nil
  end
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
    if metadata.attempt >= MAX_CANDIDATE_ATTEMPTS then return false end
    local candidate = candidate_for(metadata.anchor, record.id, metadata.attempt)
    metadata.attempt = metadata.attempt + 1
    if sufficiently_separated(record, surface, candidate) then
      metadata.candidate = candidate
      surface.request_to_generate_chunks(candidate, generation_chunk_radius())
      return true
    end
  end
  return false
end

local function mark_existing_primary(record, surface, surface_record)
  local planet = SurfacePolicy.planet(surface)
  if not (surface_record and surface_record.spawn) then return false end
  if not (surface_record.terrain_ready or (planet and planet.name == "nauvis")) then
    return false
  end
  surface_record.planet_spawn = {
    state = "ready",
    planet_name = planet and planet.name or surface.name,
    created_tick = game.tick,
    preserve_native = true,
    migrated_existing = true,
    vulcanus_policy_version = planet and planet.name == "vulcanus"
      and VULCANUS_POLICY_VERSION or nil
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
  local planet = SurfacePolicy.planet(surface)
  surface_record.planet_spawn = {
    state = "generating",
    planet_name = planet and planet.name or surface.name,
    preserve_native = true,
    anchor = copy_position(anchor),
    attempt = 0,
    created_tick = game.tick,
    waiting_players = {},
    vulcanus_policy_version = planet and planet.name == "vulcanus"
      and VULCANUS_POLICY_VERSION or nil
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

local function hostile_generation_area(position)
  local radius = generation_chunk_radius()
  local chunk_x = math.floor(position.x / CHUNK_SIZE)
  local chunk_y = math.floor(position.y / CHUNK_SIZE)
  return {
    {(chunk_x - radius) * CHUNK_SIZE, (chunk_y - radius) * CHUNK_SIZE},
    {(chunk_x + radius + 1) * CHUNK_SIZE, (chunk_y + radius + 1) * CHUNK_SIZE}
  }
end

local function reassign_existing_default_hostiles(surface, position, planet_name)
  if not SurfacePolicy.is_native_hostile_surface(surface) then return end
  -- If the arrival candidate was already generated, on_chunk_generated cannot
  -- classify its native enemies. Reconcile only the same bounded chunk square
  -- requested for the candidate, and only entities still owned by the built-in
  -- enemy force. Special factions and already paired team enemies are untouched.
  for _, entity in pairs(surface.find_entities_filtered({
    area = hostile_generation_area(position),
    force = game.forces.enemy,
    type = {"unit", "unit-spawner", "turret"}
  })) do
    if entity.valid then
      local nearest = Teams.find_nearest(surface, entity.position)
      if nearest.team and nearest.enemy_force then entity.force = nearest.enemy_force end
    end
  end
end

local function clear_immediate_hostiles(record, surface, position, planet_name)
  -- Segmented units (demolishers), resources, cliffs, tiles, decoratives, and
  -- unknown-planet entities are deliberately outside this native-preserving
  -- safety pass. Vulcanus demolishers use the separate Oarc tracker above.
  if not SurfacePolicy.is_native_hostile_surface(surface) then return end
  local own_enemy = Teams.get_enemy_force(record)
  for _, entity in pairs(surface.find_entities_filtered({
    position = position,
    radius = safety_radius(),
    type = {"unit", "unit-spawner", "turret"}
  })) do
    if entity.valid and (
      entity.force == game.forces.enemy
      or (own_enemy and entity.force.index == own_enemy.index)
    ) then
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
          if metadata.relocate_player_index == player.index then
            metadata.relocate_player_index = nil
            player.print({"sceatorio.planet-spawn-regenerated", metadata.planet_name})
          else
            player.print({"sceatorio.planet-spawn-ready", metadata.planet_name})
          end
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
  local ok, confirmed = pcall(function()
    cargo_pod.disabled_by_script = held
    return cargo_pod.disabled_by_script == held
  end)
  return ok and confirmed
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

local function notify_native_fallback(record, planet_name)
  local force = Teams.get_force(record)
  if force and force.valid then
    force.print({"sceatorio.planet-spawn-native-fallback", planet_name})
  end
end

local function use_native_fallback(record, surface, surface_record)
  local metadata = surface_record.planet_spawn
  if not metadata then return true end
  route_cargo_pods(nil, metadata, nil)
  if metadata.fallback_spawn then
    local fallback = copy_position(metadata.fallback_spawn)
    surface_record.spawn = fallback
    surface_record.terrain_ready = true
    metadata.state = "ready"
    metadata.candidate = nil
    metadata.anchor = nil
    metadata.fallback_spawn = nil
    metadata.queued = false
    local force = Teams.get_force(record)
    if force and force.valid then force.set_spawn_position(fallback, surface) end
    route_waiters(record, surface, metadata, fallback)
    notify_native_fallback(record, metadata.planet_name)
    return true
  end
  metadata.state = "native"
  metadata.candidate = nil
  metadata.anchor = nil
  metadata.queued = false
  metadata.waiting_players = nil
  notify_native_fallback(record, metadata.planet_name)
  return true
end

local function advance_candidate(record, surface, surface_record)
  local metadata = surface_record.planet_spawn
  metadata.candidate = nil
  if choose_candidate(record, surface, metadata) then return false end
  if metadata.attempt >= MAX_CANDIDATE_ATTEMPTS then
    return use_native_fallback(record, surface, surface_record)
  end
  return false
end

local function finalize(record, surface, surface_record)
  local metadata = surface_record.planet_spawn
  if metadata.attempt > MAX_CANDIDATE_ATTEMPTS then
    return use_native_fallback(record, surface, surface_record)
  end
  if not metadata.candidate then
    if not choose_candidate(record, surface, metadata)
      and metadata.attempt >= MAX_CANDIDATE_ATTEMPTS then
      return use_native_fallback(record, surface, surface_record)
    end
    return false
  end
  if not generated(surface, metadata.candidate) then return false end

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
    return advance_candidate(record, surface, surface_record)
  end

  reassign_existing_default_hostiles(surface, metadata.candidate, metadata.planet_name)
  clear_immediate_hostiles(record, surface, spawn, metadata.planet_name)
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
  if surface_record.planet_spawn.state == "native" then return true end
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

-- Administrator recovery path for a team that already received a Vulcanus
-- spawn under the former territory-rejection policy. It allocates a fresh
-- distant spawn, keeps the old one as a fail-open fallback, and records one
-- player for routing even when that player is offline during generation.
function PlanetSpawns.regenerate_vulcanus_spawn(record, player)
  if not enabled() then return false, "Planet spawns are disabled." end
  if not (record and player and player.valid) then return false, "Player or team is unavailable." end
  local surface = game.surfaces["vulcanus"]
  if not (surface and surface.valid and SurfacePolicy.is_real_planet(surface)) then
    return false, "The Vulcanus surface is unavailable."
  end
  local surface_record = Teams.get_surface(record, surface)
  local metadata = surface_record and surface_record.planet_spawn or nil
  if not (surface_record and surface_record.spawn and metadata and metadata.state == "ready") then
    if metadata and metadata.state == "generating" then
      metadata.relocate_player_index = player.index
      metadata.vulcanus_policy_version = VULCANUS_POLICY_VERSION
      add_waiter(metadata, player, "team-join", surface_record.spawn)
      enqueue(record, surface_record)
      return true, "already-generating"
    end
    return false, "That team has no ready Vulcanus spawn to regenerate."
  end

  local old_spawn = copy_position(surface_record.spawn)
  if metadata.cargo_pods then route_cargo_pods(surface, metadata, old_spawn) end
  surface_record.spawn = nil
  surface_record.terrain_ready = false
  surface_record.planet_spawn = {
    state = "generating",
    planet_name = "vulcanus",
    preserve_native = true,
    anchor = old_spawn,
    attempt = 1,
    created_tick = game.tick,
    waiting_players = {},
    vulcanus_policy_version = VULCANUS_POLICY_VERSION,
    relocate_player_index = player.index,
    fallback_spawn = old_spawn
  }
  add_waiter(surface_record.planet_spawn, player, "team-join", old_spawn)
  choose_candidate(record, surface, surface_record.planet_spawn)
  enqueue(record, surface_record)
  return true, "queued"
end

local function ensure_physical_arrival(player, reason)
  local record = Teams.get_for_player(player)
  if not record then return nil end
  local surface, position = PlanetSpawns.physical_surface(player)
  if not surface then return nil end
  State.get().player_character_surfaces[player.index] = surface.index
  return PlanetSpawns.request_spawn(record, surface, position, player, reason)
end

local function route_regenerated_vulcanus_spawn(player)
  local record = Teams.get_for_player(player)
  if not record then return end
  for surface_index, surface_record in pairs(record.surfaces or {}) do
    local metadata = surface_record.planet_spawn
    if metadata and metadata.planet_name == "vulcanus"
      and metadata.relocate_player_index == player.index then
      local surface = game.surfaces[surface_index]
      if surface and surface.valid and metadata.state == "ready" and surface_record.spawn then
        if player.teleport(surface_record.spawn, surface) then
          metadata.relocate_player_index = nil
          player.print({"sceatorio.planet-spawn-regenerated", metadata.planet_name})
        else
          player.print({"sceatorio.teleport-failed"})
        end
      elseif surface and surface.valid and metadata.state ~= "native" then
        add_waiter(metadata, player, "team-join", surface_record.spawn)
        enqueue(record, surface_record)
      end
    end
  end
end

function PlanetSpawns.on_player_joined(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  ensure_physical_arrival(player, "arrival")
  route_regenerated_vulcanus_spawn(player)
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
  if read_ok and not already_disabled and not held then
    -- CargoPod may ignore disabled_by_script writes. Fail open: keep its native
    -- destination, let descent finish, and let the authoritative arrival path
    -- record/route the physical character without claiming that the pod paused.
    player.print({"sceatorio.planet-spawn-cargo-native-fallback"})
  end
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
        if surface and surface.valid and PlanetSpawns.is_supported(surface)
          and metadata.state ~= "native" then
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

-- Explicit administrator diagnostic path. It deliberately delegates to the
-- same reservation/waiter state machine as physical arrivals instead of
-- fabricating surface or cargo events.
function PlanetSpawns.debug_route_player(player, surface)
  if not (player and player.valid and player.character and player.character.valid) then
    return false, "A physical character is required."
  end
  if not PlanetSpawns.is_supported(surface) then
    return false, "The selected surface does not use custom team spawns."
  end
  local record = Teams.get_for_player(player)
  if not record then return false, "Join a Sceatorio team first." end
  local force = Teams.get_force(record)
  local anchor = force and force.get_spawn_position(surface) or {x = 0, y = 0}
  local spawn = PlanetSpawns.request_spawn(
    record,
    surface,
    anchor,
    player,
    "team-join"
  )
  if spawn then
    return player.teleport(spawn, surface), "ready"
  end
  return true, "queued"
end

-- Planet surfaces are lazy in Space Age. The administrator test menu names a
-- LuaPlanet, creates only that selected surface, and then exercises the exact
-- production reservation/waiter path above. Platforms can never enter here.
function PlanetSpawns.debug_route_player_to_planet(player, planet)
  if not (player and player.valid and player.character and player.character.valid) then
    return false, "A physical character is required."
  end
  if not enabled() then return false, "Planet spawns are disabled." end
  if not (planet and planet.valid and type(planet.name) == "string") then
    return false, "The selected planet is unavailable."
  end
  local registered = game.planets[planet.name]
  if not (registered and registered.valid) then
    return false, "The selected planet is unavailable."
  end
  if not Teams.get_for_player(player) then return false, "Join a Sceatorio team first." end

  local surface_ok, surface = pcall(function() return registered.surface end)
  if not surface_ok then return false, "The selected planet surface is unavailable." end
  if not (surface and surface.valid) then
    local created_ok, created = pcall(function() return registered.create_surface() end)
    if not created_ok or not (created and created.valid) then
      return false, "The selected planet surface could not be created."
    end
    surface = created
  end
  return PlanetSpawns.debug_route_player(player, surface)
end

function PlanetSpawns.debug_return_to_nauvis(player)
  local surface = game.surfaces.nauvis
  if not (surface and surface.valid) then return false, "Nauvis is unavailable." end
  return PlanetSpawns.debug_route_player(player, surface)
end

return PlanetSpawns
