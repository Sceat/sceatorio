local State = require("src.core.state")

local Teams = {}

local RESERVED_FORCES = {
  enemy = true,
  neutral = true,
  player = true,
  lobby = true,
  ["sceatorio-chart-union"] = true
}

local LEGACY_ENEMY_PREFIX = "enemy="
local MAX_FORCES = 64

local function starts_with(value, prefix)
  return string.sub(value, 1, #prefix) == prefix
end

local function force_count()
  local count = 0
  for _ in pairs(game.forces) do
    count = count + 1
  end
  return count
end

local function get_force(index, name)
  local force = index and game.forces[index] or nil
  if force and force.valid then
    return force
  end
  force = name and game.forces[name] or nil
  if force and force.valid then
    return force
  end
  return nil
end

local function lowest_valid_player(force, excluded_player_index)
  if not (force and force.valid) then return nil end
  local selected
  for _, player in pairs(force.players) do
    if player.valid and player.index ~= excluded_player_index
      and (not selected or player.index < selected.index) then
      selected = player
    end
  end
  return selected
end

local function set_mutual_relation(first, second, friendly)
  if not (first and first.valid and second and second.valid) then
    return
  end
  if first.index == second.index then return end
  first.set_cease_fire(second, friendly)
  first.set_friend(second, friendly)
  second.set_cease_fire(first, friendly)
  second.set_friend(first, friendly)
end

local function initial_evolution(enemy_force, surface)
  local factor = 0
  if enemy_force and enemy_force.valid and surface and surface.valid then
    factor = enemy_force.get_evolution_factor(surface)
  end
  if factor < 0 then factor = 0 end
  if factor >= 1 then factor = 0.999999999 end
  local raw = factor / (1 - factor)
  return {
    baseline_raw = raw,
    raw_time = 0,
    raw_worm = 0,
    raw_spawner = 0,
    raw_pollution = 0,
    connected_ticks = 0,
    worm_kills = 0,
    spawner_kills = 0,
    pollution_units = 0,
    pollution_cursor = nil,
    pollution_progression_enabled = nil,
    pollution_coefficient = nil,
    connected_since = nil,
    connected_progression_enabled = nil,
    connected_time_coefficient = nil,
    value = factor
  }
end

local function index_record(root, record)
  root.team_id_by_force_index[record.force_index] = record.id
  root.team_id_by_enemy_force_index[record.enemy_force_index] = record.id
end

local function reserve_record_id()
  local root = State.get()
  local id = root.next_team_id
  -- Numeric ids are storage identities, but the built-in force names derived
  -- from them must also be free. A third-party/system force is allowed to use
  -- any name and must never be adopted or overwritten by Sceatorio.
  while root.teams_by_id[id]
    or game.forces["sceatorio-team-" .. id]
    or game.forces["sceatorio-enemy-" .. id] do
    id = id + 1
  end
  root.next_team_id = id + 1
  return id
end

local function make_record(id, force, enemy_force, owner_player_index, display_name)
  local root = State.get()
  local record = {
    id = id,
    force_index = force.index,
    force_name = force.name,
    enemy_force_index = enemy_force.index,
    enemy_force_name = enemy_force.name,
    owner_player_index = owner_player_index,
    display_name = display_name or force.name,
    surfaces = {}
  }
  root.teams_by_id[id] = record
  index_record(root, record)
  return record
end

local function configure_enemy_matrix()
  local root = State.get()
  local default_enemy = game.forces.enemy
  for _, owner in pairs(root.teams_by_id) do
    local owner_team = get_force(owner.force_index, owner.force_name)
    local owner_enemy = get_force(owner.enemy_force_index, owner.enemy_force_name)
    if owner_team and owner_enemy then
      owner_enemy.ai_controllable = true
      -- A paired enemy is hostile only to its owning human team. Human-team
      -- diplomacy is deliberately left to vanilla/admin/social decisions.
      set_mutual_relation(owner_team, owner_enemy, false)
      set_mutual_relation(owner_enemy, default_enemy, true)
      for _, other in pairs(root.teams_by_id) do
        if other.id ~= owner.id then
          set_mutual_relation(
            owner_enemy,
            get_force(other.force_index, other.force_name),
            true
          )
          set_mutual_relation(
            owner_enemy,
            get_force(other.enemy_force_index, other.enemy_force_name),
            true
          )
        end
      end
    end
  end
end

function Teams.ensure_lobby()
  local lobby = game.forces.lobby
  if not lobby then
    lobby = game.create_force("lobby")
  end
  State.get().lobby_force_index = lobby.index
  return lobby
end

function Teams.can_create()
  return force_count() + 2 <= MAX_FORCES
end

function Teams.create(player, display_name)
  if not Teams.can_create() then
    return nil, "The 64-force engine limit leaves no room for another isolated team."
  end

  local id = reserve_record_id()
  local team_force = game.create_force("sceatorio-team-" .. id)
  local enemy_force = game.create_force("sceatorio-enemy-" .. id)
  enemy_force.ai_controllable = true

  local record = make_record(
    id,
    team_force,
    enemy_force,
    player and player.valid and player.index or nil,
    display_name or (player and player.valid and (player.name .. "'s team"))
      or ("Team " .. id)
  )
  configure_enemy_matrix()
  return record
end

function Teams.get(team_id)
  return team_id and State.get().teams_by_id[team_id] or nil
end

function Teams.get_by_force(force)
  if not (force and force.valid) then return nil end
  local id = State.get().team_id_by_force_index[force.index]
  return id and Teams.get(id) or nil
end

function Teams.get_by_enemy_force(force)
  if not (force and force.valid) then return nil end
  local id = State.get().team_id_by_enemy_force_index[force.index]
  return id and Teams.get(id) or nil
end

function Teams.get_for_player(player)
  if not (player and player.valid) then return nil end
  return Teams.get_by_force(player.force)
end

function Teams.get_force(record)
  if not record then return nil end
  return get_force(record.force_index, record.force_name)
end

function Teams.get_enemy_force(record)
  if not record then return nil end
  return get_force(record.enemy_force_index, record.enemy_force_name)
end

-- Ownership grants only management authority; it is not the team's identity.
-- Keep it deterministic and repair stale player indexes without recreating or
-- renaming either force in the pair.
function Teams.ensure_owner(record, excluded_player_index)
  if not record then return nil end
  local force = Teams.get_force(record)
  local owner = record.owner_player_index and game.players[record.owner_player_index] or nil
  if owner and owner.valid and owner.index ~= excluded_player_index
    and force and owner.force.index == force.index then
    return owner
  end
  owner = lowest_valid_player(force, excluded_player_index)
  record.owner_player_index = owner and owner.index or nil
  return owner
end

function Teams.on_player_changed_force(event)
  -- Factorio 2.1 supplies the old force after the player has moved.
  local old_record = Teams.get_by_force(event.force)
  if old_record then Teams.ensure_owner(old_record, event.player_index) end
  local player = game.players[event.player_index]
  local destination_record = player and player.valid and Teams.get_for_player(player) or nil
  if destination_record then Teams.ensure_owner(destination_record) end
end

function Teams.on_player_removed(event)
  for _, record in pairs(State.get().teams_by_id) do
    if record.owner_player_index == event.player_index
      or (record.owner_player_index and not game.players[record.owner_player_index]) then
      Teams.ensure_owner(record, event.player_index)
    end
  end
end

function Teams.for_each(callback)
  for _, record in pairs(State.get().teams_by_id) do
    callback(record)
  end
end

function Teams.ensure_surface(record, surface, spawn)
  if not (record and surface and surface.valid) then return nil end
  record.surfaces = record.surfaces or {}
  local surface_record = record.surfaces[surface.index]
  if not surface_record then
    local enemy_force = Teams.get_enemy_force(record)
    surface_record = {
      surface_index = surface.index,
      surface_name = surface.name,
      spawn = spawn and {x = spawn.x, y = spawn.y} or nil,
      evolution = initial_evolution(enemy_force, surface)
    }
    record.surfaces[surface.index] = surface_record
  elseif spawn then
    surface_record.spawn = {x = spawn.x, y = spawn.y}
  end
  surface_record.evolution = surface_record.evolution or initial_evolution(Teams.get_enemy_force(record), surface)
  return surface_record
end

function Teams.get_surface(record, surface)
  if not (record and record.surfaces and surface) then return nil end
  local index = type(surface) == "number" and surface or surface.index
  return record.surfaces[index]
end

function Teams.find_nearest(surface, position, ignore_team_id)
  if not (surface and surface.valid and position) then
    return {team = nil, force = nil, enemy_force = nil, distance = nil}
  end

  local nearest
  local nearest_surface
  local nearest_squared
  for _, record in pairs(State.get().teams_by_id) do
    local surface_record = Teams.get_surface(record, surface)
    local reservation = surface_record and (
      surface_record.spawn
      or (surface_record.planet_spawn and surface_record.planet_spawn.candidate)
    ) or nil
    if record.id ~= ignore_team_id and reservation then
      local dx = position.x - reservation.x
      local dy = position.y - reservation.y
      local squared = dx * dx + dy * dy
      if not nearest_squared or squared < nearest_squared
        or (squared == nearest_squared and record.id < nearest.id) then
        nearest = record
        nearest_surface = surface_record
        nearest_squared = squared
      end
    end
  end

  return {
    team = nearest,
    surface_record = nearest_surface,
    force = Teams.get_force(nearest),
    enemy_force = Teams.get_enemy_force(nearest),
    distance = nearest_squared and math.sqrt(nearest_squared) or nil
  }
end

local function legacy_enemy_for(force)
  return game.forces[LEGACY_ENEMY_PREFIX .. force.name]
end

local function is_legacy_player_force(force)
  if not (force and force.valid) or RESERVED_FORCES[force.name] then return false end
  if starts_with(force.name, LEGACY_ENEMY_PREFIX) then return false end
  if legacy_enemy_for(force) then return true end
  for _, player in pairs(force.players) do
    if player.valid and player.name == force.name then return true end
  end
  return false
end

function Teams.register_force(force, owner_player_index, display_name)
  if not (force and force.valid) then return nil, "The force is invalid." end
  if RESERVED_FORCES[force.name] or starts_with(force.name, LEGACY_ENEMY_PREFIX)
    or starts_with(force.name, "sceatorio-enemy-") then
    return nil, "Reserved and enemy forces cannot be registered as teams."
  end

  local root = State.get()
  local existing_id = root.team_id_by_force_index[force.index]
  if existing_id then return Teams.get(existing_id) end
  if root.team_id_by_enemy_force_index[force.index] then
    return nil, "A paired enemy force cannot also be registered as a team."
  end

  local enemy_force = legacy_enemy_for(force)
  if enemy_force and (
    root.team_id_by_force_index[enemy_force.index]
    or root.team_id_by_enemy_force_index[enemy_force.index]
  ) then
    return nil, "The legacy enemy force is already assigned to another team."
  end

  if not enemy_force then
    if force_count() + 1 > MAX_FORCES then
      return nil, "The 64-force engine limit leaves no room for a paired enemy."
    end
  end

  local id = reserve_record_id()
  if not enemy_force then
    local enemy_name = "sceatorio-enemy-" .. id
    enemy_force = game.create_force(enemy_name)
  end
  enemy_force.ai_controllable = true

  local owner = owner_player_index and game.players[owner_player_index] or nil
  if not (owner and owner.valid and owner.force.index == force.index) then
    owner = lowest_valid_player(force)
  end
  local record = make_record(
    id,
    force,
    enemy_force,
    owner and owner.index or nil,
    display_name or (owner and (owner.name .. "'s team")) or force.name
  )
  configure_enemy_matrix()

  for _, surface in pairs(game.surfaces) do
    local has_member = false
    for _, player in pairs(force.players) do
      local character = player.valid and player.character or nil
      if character and character.valid
        and character.surface.index == surface.index then
        has_member = true
        break
      end
    end
    if has_member or surface.name == "nauvis" then
      Teams.ensure_surface(record, surface, force.get_spawn_position(surface))
    end
  end
  return record
end

local function reconcile_records()
  local root = State.get()
  root.team_id_by_force_index = {}
  root.team_id_by_enemy_force_index = {}
  local highest_id = 0

  for id, record in pairs(root.teams_by_id) do
    record.id = record.id or id
    highest_id = math.max(highest_id, record.id)
    record.surfaces = record.surfaces or {}
    local force = get_force(record.force_index, record.force_name)
    local enemy_force = get_force(record.enemy_force_index, record.enemy_force_name)
    if force and enemy_force then
      record.force_index = force.index
      record.force_name = force.name
      record.enemy_force_index = enemy_force.index
      record.enemy_force_name = enemy_force.name
      index_record(root, record)
    else
      log("[Sceatorio] Team " .. id .. " references a missing force and was left inactive")
    end
  end
  root.next_team_id = math.max(root.next_team_id, highest_id + 1)
  for _, record in pairs(root.teams_by_id) do
    Teams.ensure_owner(record)
  end
  configure_enemy_matrix()
end

function Teams.initialize()
  Teams.ensure_lobby()
  reconcile_records()

  for _, player in pairs(game.players) do
    local force = player.force
    if is_legacy_player_force(force) then
      local _, reason = Teams.register_force(force)
      if reason then
        log("[Sceatorio] Could not migrate team force " .. force.name .. ": " .. reason)
      end
    end
  end
end

function Teams.on_force_created(event)
  local force = event.force
  if not (force and force.valid) or RESERVED_FORCES[force.name] then return end
  -- Creation alone never proves that a force represents a human team. Mods use
  -- forces for scripted systems, and pairing one here consumes two force slots
  -- and subjects unrelated entities to team policy. Explicit Sceatorio creation
  -- is indexed by Teams.create; old player-named forces migrate in initialize.
end

function Teams.on_surface_deleted(event)
  for _, record in pairs(State.get().teams_by_id) do
    if record.surfaces then
      record.surfaces[event.surface_index] = nil
    end
  end
end

local function copy_position(position)
  return position and {x = position.x, y = position.y} or nil
end

local function spawn_is_ready(surface_record)
  if not (surface_record and surface_record.spawn) then return false end
  local metadata = surface_record.planet_spawn
  return not metadata or metadata.state == "ready"
end

local function merge_keyed(target, source)
  if not source then return target end
  target = target or {}
  for key, value in pairs(source) do
    if target[key] == nil then target[key] = value end
  end
  return target
end

local function merge_surface_records(destination, source)
  if not destination then return source end
  if not source then return destination end

  local destination_metadata = destination.planet_spawn
  local source_metadata = source.planet_spawn
  if spawn_is_ready(destination) and not destination_metadata then
    destination_metadata = {state = "ready", migrated_existing = true}
  end
  if spawn_is_ready(source) and not source_metadata then
    source_metadata = {state = "ready", migrated_existing = true}
  end
  local use_source = not spawn_is_ready(destination) and spawn_is_ready(source)
  if not use_source and not spawn_is_ready(destination) and not spawn_is_ready(source)
    and source_metadata and destination_metadata then
    use_source = (source_metadata.created_tick or math.huge)
      < (destination_metadata.created_tick or math.huge)
  end

  local chosen = use_source and source_metadata or destination_metadata
  local other = use_source and destination_metadata or source_metadata
  if chosen and other then
    chosen.waiting_players = merge_keyed(chosen.waiting_players, other.waiting_players)
    chosen.cargo_pods = merge_keyed(chosen.cargo_pods, other.cargo_pods)
  elseif not chosen then
    chosen = other
  end
  destination.planet_spawn = chosen
  if use_source then
    destination.spawn = copy_position(source.spawn)
    destination.terrain_ready = source.terrain_ready
  end
  -- The destination team's evolution ledger remains authoritative. A force
  -- merge must not add the absorbed team's counters a second time.
  destination.evolution = destination.evolution or source.evolution
  return destination
end

local function absorb_team(root, destination, source)
  destination.surfaces = destination.surfaces or {}
  for surface_index, source_surface in pairs(source.surfaces or {}) do
    destination.surfaces[surface_index] = merge_surface_records(
      destination.surfaces[surface_index],
      source_surface
    )
  end
  root.team_id_by_enemy_force_index[source.enemy_force_index] = nil
  root.teams_by_id[source.id] = nil
end

local function merge_force_if_distinct(source, destination)
  if source and source.valid and destination and destination.valid
    and source.index ~= destination.index then
    game.merge_forces(source, destination)
  end
end

local function replace_enemy_force(root, record)
  if not record then return nil end
  local name = "sceatorio-enemy-" .. record.id
  local enemy_force = game.forces[name]
  if enemy_force and root.team_id_by_enemy_force_index[enemy_force.index] ~= record.id then
    local suffix = 1
    repeat
      name = "sceatorio-enemy-" .. record.id .. "-replacement-" .. suffix
      enemy_force = game.forces[name]
      suffix = suffix + 1
    until not enemy_force
  end
  enemy_force = enemy_force or game.create_force(name)
  enemy_force.ai_controllable = true
  record.enemy_force_index = enemy_force.index
  record.enemy_force_name = enemy_force.name
  root.team_id_by_enemy_force_index[enemy_force.index] = record.id
  return enemy_force
end

function Teams.on_forces_merged(event)
  local root = State.get()
  local team_id = root.team_id_by_force_index[event.source_index]
  local destination_team_id = root.team_id_by_force_index[event.destination.index]
  local enemy_team_id = root.team_id_by_enemy_force_index[event.source_index]
  local destination_enemy_team_id = root.team_id_by_enemy_force_index[event.destination.index]
  root.team_id_by_force_index[event.source_index] = nil
  root.team_id_by_enemy_force_index[event.source_index] = nil

  if team_id then
    local record = root.teams_by_id[team_id]
    local destination_record = root.teams_by_id[destination_team_id]
    if record and destination_record and destination_record.id ~= record.id then
      -- The force that survives in the engine also survives in storage. Its
      -- ready spawn wins ties; otherwise the earliest valid reservation wins.
      local source_enemy = Teams.get_enemy_force(record)
      local destination_enemy = Teams.get_enemy_force(destination_record)
      absorb_team(root, destination_record, record)
      root.team_id_by_force_index[event.destination.index] = destination_record.id
      -- Absorbing the paired enemy too prevents a permanently orphaned force
      -- and keeps exactly one evolution ledger/enemy family for the survivor.
      merge_force_if_distinct(source_enemy, destination_enemy)
    elseif record then
      if destination_team_id == record.id then
        record.force_index = event.destination.index
        record.force_name = event.destination.name
        root.team_id_by_force_index[event.destination.index] = team_id
      else
        -- Never turn a reserved or third-party destination into a Sceatorio
        -- team merely because an admin/mod merged a team force into it.
        local orphan_enemy = Teams.get_enemy_force(record)
        Teams.remove(record)
        merge_force_if_distinct(orphan_enemy, game.forces.enemy)
      end
    end
  elseif enemy_team_id then
    local record = root.teams_by_id[enemy_team_id]
    if record then
      if destination_enemy_team_id == enemy_team_id then
        record.enemy_force_index = event.destination.index
        record.enemy_force_name = event.destination.name
        root.team_id_by_enemy_force_index[event.destination.index] = enemy_team_id
      else
        -- A paired enemy merged into the default/foreign/other team's enemy
        -- must not make that destination shared. Recreate the isolated pair.
        replace_enemy_force(root, record)
      end
    end
  end
  for _, record in pairs(root.teams_by_id) do
    Teams.ensure_owner(record)
  end
  configure_enemy_matrix()
end

function Teams.remove(record)
  if not record then return end
  local root = State.get()
  root.team_id_by_force_index[record.force_index] = nil
  root.team_id_by_enemy_force_index[record.enemy_force_index] = nil
  root.teams_by_id[record.id] = nil
end

return Teams
