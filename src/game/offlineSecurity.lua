local State = require("src.core.state")
local Teams = require("src.game.teams")

local OfflineSecurity = {}
local needs_presence_reconcile = false

-- Invalid references can only remain when another script destroys an entity
-- without raising a normal removal event. Object-destroyed registrations are
-- authoritative; this small sweep is a second, fixed-cost safety net.
local CLEANUP_BUDGET = 32

-- LuaEntityPrototype.is_building covers factories, belts, rails, poles,
-- turrets, roboports, and Space Age structures such as platform hubs,
-- collectors, cargo bays, and thrusters. These additional durable asset types
-- are player bases too, but are intentionally not classified as buildings by
-- the engine.
local DURABLE_ASSET_TYPES = {
  ["car"] = true,
  ["spider-vehicle"] = true,
  ["locomotive"] = true,
  ["cargo-wagon"] = true,
  ["fluid-wagon"] = true,
  ["artillery-wagon"] = true,
  ["land-mine"] = true
}

-- Kept explicit even though the positive classification below already rejects
-- these. This is the compatibility contract: characters, mobile robots,
-- natural resources, ghosts, and short-lived combat/effect entities are never
-- turned into persistent protected "base" objects.
local EXCLUDED_ENTITY_TYPES = {
  ["character"] = true,
  ["construction-robot"] = true,
  ["logistic-robot"] = true,
  ["combat-robot"] = true,
  ["unit"] = true,
  ["unit-spawner"] = true,
  ["resource"] = true,
  ["tree"] = true,
  ["cliff"] = true,
  ["entity-ghost"] = true,
  ["tile-ghost"] = true,
  ["item-entity"] = true,
  ["projectile"] = true,
  ["artillery-projectile"] = true,
  ["beam"] = true,
  ["stream"] = true,
  ["fire"] = true,
  ["sticker"] = true,
  ["smoke-with-trigger"] = true,
  ["explosion"] = true,
  ["corpse"] = true,
  ["character-corpse"] = true,
  ["particle-source"] = true,
  ["highlight-box"] = true,
  ["spider-leg"] = true,
  ["cargo-pod"] = true,
  ["asteroid"] = true,
  ["asteroid-chunk"] = true,
  ["rocket-silo-rocket"] = true
}

local function enabled()
  local value = settings.global["sceatorio-offline-defense-enabled"]
  return not value or value.value
end

local function registry()
  local root = State.get()
  root.offline_security = root.offline_security or {}
  local value = root.offline_security
  value.entries = value.entries or {}
  value.by_force = value.by_force or {}
  value.by_surface = value.by_surface or {}
  value.by_unit_number = value.by_unit_number or {}
  value.order = value.order or {}
  value.cursor = value.cursor or 1
  return value
end

local function add_index(index, key, registration_number)
  if key == nil then return end
  local bucket = index[key]
  if not bucket then
    bucket = {}
    index[key] = bucket
  end
  bucket[registration_number] = true
end

local function remove_index(index, key, registration_number)
  local bucket = key ~= nil and index[key] or nil
  if not bucket then return end
  bucket[registration_number] = nil
  if not next(bucket) then index[key] = nil end
end

local function remove_order_entry(value, entry)
  local index = entry.order_index
  if not index or value.order[index] ~= entry.registration_number then
    -- This path is only for compatibility with an interrupted/older registry.
    for candidate, registration_number in ipairs(value.order) do
      if registration_number == entry.registration_number then
        index = candidate
        break
      end
    end
  end
  if not index then return end
  local last_index = #value.order
  local replacement = value.order[last_index]
  value.order[index] = replacement
  value.order[last_index] = nil
  if replacement and replacement ~= entry.registration_number then
    local replacement_entry = value.entries[replacement]
    if replacement_entry then replacement_entry.order_index = index end
  end
  if value.cursor > #value.order then value.cursor = 1 end
end

local function restore_entry(entry)
  if not entry.protected then return end
  local entity = entry.entity
  if entity and entity.valid then
    entity.destructible = entry.restore_destructible
  end
  entry.protected = false
  entry.restore_destructible = nil
end

local function drop_entry(registration_number, restore)
  local value = registry()
  local entry = value.entries[registration_number]
  if not entry then return end
  if restore then restore_entry(entry) end
  remove_index(value.by_force, entry.force_index, registration_number)
  remove_index(value.by_surface, entry.surface_index, registration_number)
  if entry.unit_number then value.by_unit_number[entry.unit_number] = nil end
  remove_order_entry(value, entry)
  value.entries[registration_number] = nil
end

local function physical_surface(surface)
  if not (surface and surface.valid) then return false end
  local planet_ok, planet = pcall(function() return surface.planet end)
  local platform_ok, platform = pcall(function() return surface.platform end)
  local canonical_nauvis = game.surfaces.nauvis
  return (planet_ok and planet ~= nil)
    or (platform_ok and platform ~= nil)
    or (canonical_nauvis and canonical_nauvis.index == surface.index)
end

local function eligible_entity(entity)
  if not (entity and entity.valid and entity.force and entity.force.valid) then
    return false
  end
  if EXCLUDED_ENTITY_TYPES[entity.type] or not physical_surface(entity.surface) then
    return false
  end
  if not Teams.get_by_force(entity.force) then return false end
  local prototype = entity.prototype
  return prototype and prototype.valid
    and (prototype.is_building or DURABLE_ASSET_TYPES[entity.type] == true)
end

local function has_connected_human(record)
  local force = Teams.get_force(record)
  return force and force.valid and #force.connected_players > 0
end

local function should_protect(record)
  return enabled() and not has_connected_human(record)
end

local function protect_entry(entry, restore_override, has_restore_override)
  local entity = entry.entity
  if not (entity and entity.valid) then return false end
  if not entry.protected then
    if has_restore_override then
      entry.restore_destructible = restore_override
    else
      entry.restore_destructible = entity.destructible
    end
    entry.protected = true
  end
  entity.destructible = false
  return true
end

local function set_record_status(record, offline_active)
  record.security = record.security or {}
  record.security.offline_active = offline_active
end

local function reindex_entry(entry, force_index, surface_index)
  local value = registry()
  if entry.force_index ~= force_index then
    remove_index(value.by_force, entry.force_index, entry.registration_number)
    entry.force_index = force_index
    add_index(value.by_force, force_index, entry.registration_number)
  end
  if entry.surface_index ~= surface_index then
    remove_index(value.by_surface, entry.surface_index, entry.registration_number)
    entry.surface_index = surface_index
    add_index(value.by_surface, surface_index, entry.registration_number)
  end
end

local function validate_entry(registration_number)
  local value = registry()
  local entry = value.entries[registration_number]
  if not entry then return nil end
  local entity = entry.entity
  if not (entity and entity.valid) then
    drop_entry(registration_number, false)
    return nil
  end
  if not eligible_entity(entity) then
    drop_entry(registration_number, true)
    return nil
  end

  local force_index = entity.force.index
  local surface_index = entity.surface.index
  if force_index ~= entry.force_index or surface_index ~= entry.surface_index then
    -- Never carry another team's offline state across a silent script transfer.
    restore_entry(entry)
    reindex_entry(entry, force_index, surface_index)
    local record = Teams.get_by_force(entity.force)
    if record and should_protect(record) then protect_entry(entry) end
  end
  return entry
end

local function apply_record(record, protect)
  local force = Teams.get_force(record)
  if not (force and force.valid) then return end
  local bucket = registry().by_force[force.index]
  if bucket then
    -- Presence changes must be immediate, so touching each durable asset is
    -- unavoidable. Walk the force index in place instead of allocating a
    -- second O(base-size) snapshot during the same critical tick. Capture the
    -- successor before validation because validation may remove the current
    -- stale registration from this bucket.
    local registration_number = next(bucket)
    while registration_number do
      local next_registration = next(bucket, registration_number)
      local entry = validate_entry(registration_number)
      if entry and entry.force_index == force.index then
        if protect then protect_entry(entry) else restore_entry(entry) end
      end
      registration_number = next_registration
    end
  end
  set_record_status(record, protect)
end

local function refresh_record(record)
  if record then apply_record(record, should_protect(record)) end
end

local function refresh_force(force)
  if not (force and force.valid) then return end
  refresh_record(Teams.get_by_force(force))
end

local function register_entity(entity, restore_override, has_restore_override)
  if not eligible_entity(entity) then return false end
  local value = registry()
  local existing_registration = entity.unit_number
    and value.by_unit_number[entity.unit_number] or nil
  local existing = existing_registration and value.entries[existing_registration] or nil
  if existing then
    existing.entity = entity
    reindex_entry(existing, entity.force.index, entity.surface.index)
    local existing_record = Teams.get_by_force(entity.force)
    if existing_record and should_protect(existing_record) then
      protect_entry(existing, restore_override, has_restore_override)
    elseif existing.protected then
      restore_entry(existing)
    elseif has_restore_override then
      entity.destructible = restore_override
    end
    return true
  end

  local registration_number, useful_id = script.register_on_object_destroyed(entity)
  local entry = value.entries[registration_number]
  if not entry then
    entry = {
      registration_number = registration_number,
      entity = entity,
      unit_number = entity.unit_number or (useful_id ~= 0 and useful_id or nil),
      force_index = entity.force.index,
      surface_index = entity.surface.index,
      protected = false,
      order_index = #value.order + 1
    }
    value.entries[registration_number] = entry
    value.order[entry.order_index] = registration_number
    add_index(value.by_force, entry.force_index, registration_number)
    add_index(value.by_surface, entry.surface_index, registration_number)
    if entry.unit_number then
      value.by_unit_number[entry.unit_number] = registration_number
    end
  else
    entry.entity = entity
    reindex_entry(entry, entity.force.index, entity.surface.index)
  end

  local record = Teams.get_by_force(entity.force)
  if record and should_protect(record) then
    protect_entry(entry, restore_override, has_restore_override)
  elseif has_restore_override then
    -- A clone carries the source's temporary `destructible = false` value.
    -- An online destination must receive the source's logical prior state.
    entity.destructible = restore_override
  elseif entry.protected then
    restore_entry(entry)
  end
  return true
end

local function registration_for_entity(entity)
  if not (entity and entity.valid and entity.unit_number) then return nil end
  return registry().by_unit_number[entity.unit_number]
end

local function rebuild_indexes()
  local value = registry()
  local entries = value.entries
  value.by_force = {}
  value.by_surface = {}
  value.by_unit_number = {}
  value.order = {}
  value.cursor = 1
  for registration_number, entry in pairs(entries) do
    entry.registration_number = registration_number
    local entity = entry.entity
    if entity and entity.valid and eligible_entity(entity) then
      entry.force_index = entity.force.index
      entry.surface_index = entity.surface.index
      entry.unit_number = entity.unit_number or entry.unit_number
      entry.order_index = #value.order + 1
      value.order[entry.order_index] = registration_number
      add_index(value.by_force, entry.force_index, registration_number)
      add_index(value.by_surface, entry.surface_index, registration_number)
      if entry.unit_number then
        value.by_unit_number[entry.unit_number] = registration_number
      end
    else
      if entry.protected then restore_entry(entry) end
      entries[registration_number] = nil
    end
  end
end

function OfflineSecurity.initialize()
  needs_presence_reconcile = false
  rebuild_indexes()
  local known_forces = {}
  Teams.for_each(function(record)
    known_forces[record.force_index] = true
    refresh_record(record)
  end)
  -- A removed/unregistered force must never retain script-applied protection.
  local unknown_registrations = {}
  for force_index, bucket in pairs(registry().by_force) do
    if not known_forces[force_index] then
      for registration_number in pairs(bucket) do
        unknown_registrations[#unknown_registrations + 1] = registration_number
      end
    end
  end
  for _, registration_number in ipairs(unknown_registrations) do
    drop_entry(registration_number, true)
  end
end

function OfflineSecurity.on_load()
  -- `game` is unavailable during on_load. The first ordinary tick reconciles
  -- presence before gameplay advances: a server may have saved with connected
  -- humans and restarted with none, without persisting a leave event.
  needs_presence_reconcile = true
end

function OfflineSecurity.on_tick()
  if not needs_presence_reconcile then return end
  needs_presence_reconcile = false
  Teams.for_each(refresh_record)
end

function OfflineSecurity.on_player_left(event)
  local player = game.players[event.player_index]
  if player and player.valid then refresh_force(player.force) end
end

function OfflineSecurity.on_player_joined(event)
  local player = game.players[event.player_index]
  if player and player.valid then refresh_force(player.force) end
end

function OfflineSecurity.on_player_changed_force(event)
  refresh_force(event.force)
  local player = game.players[event.player_index]
  if player and player.valid then refresh_force(player.force) end
end

function OfflineSecurity.on_entity_built(event)
  register_entity(event.entity or event.created_entity or event.destination)
end

function OfflineSecurity.on_entity_cloned(event)
  local source_registration = registration_for_entity(event.source)
  local source_entry = source_registration
    and registry().entries[source_registration]
    or nil
  if source_entry and source_entry.protected then
    register_entity(event.destination, source_entry.restore_destructible, true)
  else
    register_entity(event.destination)
  end
end

function OfflineSecurity.on_entity_removed(event)
  local registration_number = registration_for_entity(
    event.entity or event.destination
  )
  if registration_number then drop_entry(registration_number, false) end
end

function OfflineSecurity.on_object_destroyed(event)
  drop_entry(event.registration_number, false)
end

function OfflineSecurity.on_setting_changed(event)
  if event.setting ~= "sceatorio-offline-defense-enabled" then return end
  if not enabled() then
    OfflineSecurity.restore_all()
    return
  end
  Teams.for_each(refresh_record)
end

function OfflineSecurity.restore_all()
  local value = registry()
  for _, registration_number in ipairs(value.order) do
    local entry = value.entries[registration_number]
    if entry then restore_entry(entry) end
  end
  Teams.for_each(function(record) set_record_status(record, false) end)
end

-- Explicit core transition shared by connection handling and the default-off
-- diagnostic harness. Player-facing code never calls this to override presence.
function OfflineSecurity.set_force_protected(force, protected)
  local record = Teams.get_by_force(force)
  if not record then return false end
  apply_record(record, protected and enabled())
  return true
end

function OfflineSecurity.status(force)
  local record = Teams.get_by_force(force)
  if not record then return nil end
  local total = 0
  local protected = 0
  local bucket = registry().by_force[force.index]
  local registrations = {}
  for registration_number in pairs(bucket or {}) do
    registrations[#registrations + 1] = registration_number
  end
  for _, registration_number in ipairs(registrations) do
    local entry = validate_entry(registration_number)
    if entry and entry.force_index == force.index then
      total = total + 1
      if entry.protected then protected = protected + 1 end
    end
  end
  return {
    enabled = enabled(),
    offline = not has_connected_human(record),
    active = record.security and record.security.offline_active or false,
    registered = total,
    protected = protected
  }
end

function OfflineSecurity.tick()
  local value = registry()
  local processed = 0
  while processed < CLEANUP_BUDGET and #value.order > 0 do
    if value.cursor > #value.order then value.cursor = 1 end
    local index = value.cursor
    local registration_number = value.order[index]
    local before = #value.order
    validate_entry(registration_number)
    if #value.order == before then value.cursor = index + 1 end
    processed = processed + 1
  end
end

function OfflineSecurity.on_surface_deleted(event)
  local bucket = registry().by_surface[event.surface_index]
  if not bucket then return end
  local registrations = {}
  for registration_number in pairs(bucket) do
    registrations[#registrations + 1] = registration_number
  end
  for _, registration_number in ipairs(registrations) do
    -- Entities on a deleted/cleared surface no longer exist; there is no state
    -- to restore and retaining their LuaObjects would only leak registry slots.
    drop_entry(registration_number, false)
  end
end

function OfflineSecurity.on_forces_merged(event)
  local value = registry()
  local source_bucket = value.by_force[event.source_index]
  local destination_record = Teams.get_by_force(event.destination)
  if source_bucket then
    local registrations = {}
    for registration_number in pairs(source_bucket) do
      registrations[#registrations + 1] = registration_number
    end
    for _, registration_number in ipairs(registrations) do
      local entry = value.entries[registration_number]
      if entry then
        restore_entry(entry)
        if destination_record and entry.entity and entry.entity.valid then
          reindex_entry(entry, event.destination.index, entry.entity.surface.index)
        else
          drop_entry(registration_number, true)
        end
      end
    end
  end
  if destination_record then refresh_record(destination_record) end
end

return OfflineSecurity
