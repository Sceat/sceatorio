local State = require("src.core.state")
local Teams = require("src.game.teams")

local Security = {}

local WARNING_INTERVAL = 5 * 60
local DISCOVERY_LIMIT_MULTIPLIER = 4
local DEFAULT_AUDIT_BUDGET = 64
local DEFAULT_MIGRATION_CHUNKS = 2
local DEFERRED_BUILD_AUDIT_BUDGET = 8
local MAX_PENDING_BUILD_AUDITS = 4096
local MAX_LOCAL_CHILD_POLES = 16
local MAX_LOCAL_POLE_SCAN = 256
local MAX_LOCAL_SUPPLIED_ENTITIES = 256

-- Chunk iterators are runtime-only LuaObjects. Durable progress is kept as a
-- count and replayed within the same per-tick budget after a save reload.
local chunk_migration_iterators = {}

local function setting(name, fallback)
  local value = settings.global[name]
  if not value then return fallback end
  return value.value
end

local function isolation_enabled()
  return setting("sceatorio-electricity-isolation", true)
end

local function ensure_security_root()
  local root = State.get()
  root.security = root.security or {}
  local security = root.security
  security.warning_tick_by_player = security.warning_tick_by_player or {}
  security.warning_tick_by_team = security.warning_tick_by_team or {}
  security.stats = security.stats or {
    wires_removed = 0,
    builds_rejected = 0
  }
  security.deferred_build_audits = security.deferred_build_audits or {
    head = 1,
    tail = 0,
    count = 0,
    entries = {}
  }
  local deferred = security.deferred_build_audits
  deferred.head = deferred.head or 1
  deferred.tail = deferred.tail or 0
  deferred.count = deferred.count or 0
  deferred.entries = deferred.entries or {}
  security.pole_registry = security.pole_registry or {
    next_slot = 1,
    cursor = 0,
    entity_by_slot = {},
    unit_by_slot = {},
    slot_by_unit = {}
  }
  local registry = security.pole_registry
  if not registry.entity_by_slot then
    -- Early 2.0.0 development saves stored only unit numbers. Electric poles
    -- are not guaranteed to carry get-by-unit-number, so rebuild them through
    -- the bounded chunk migration instead of silently dropping audits.
    registry.next_slot = 1
    registry.cursor = 0
    registry.entity_by_slot = {}
    registry.unit_by_slot = {}
    registry.slot_by_unit = {}
  end
  registry.next_slot = registry.next_slot or 1
  registry.cursor = registry.cursor or 0
  registry.entity_by_slot = registry.entity_by_slot or {}
  registry.unit_by_slot = registry.unit_by_slot or {}
  registry.slot_by_unit = registry.slot_by_unit or {}
  security.chunk_migration = security.chunk_migration or {by_surface = {}}
  security.chunk_migration.by_surface = security.chunk_migration.by_surface or {}
  return security
end

local function ensure_team_security(record)
  record.security = record.security or {}
  record.security.power_share_intents = record.security.power_share_intents or {}
  return record.security
end

local function power_sharing_allowed(first, second)
  if not (first and second) then return true end
  if first.id == second.id then return true end
  if setting("sceatorio-electricity-sharing-policy", "mutual") ~= "mutual" then
    return false
  end
  local first_security = ensure_team_security(first)
  local second_security = ensure_team_security(second)
  return first_security.power_share_intents[second.id] == true
    and second_security.power_share_intents[first.id] == true
end

local function is_platform_surface(surface)
  return surface and surface.valid and surface.platform ~= nil
end

local function team_for_entity(entity)
  if not (entity and entity.valid and entity.force and entity.force.valid) then return nil end
  if is_platform_surface(entity.surface) then return nil end
  -- Enemy, neutral, lobby, and third-party system forces are deliberately outside
  -- the team-to-team isolation policy.
  return Teams.get_by_force(entity.force)
end

local function is_connector_entity(entity)
  if not (entity and entity.valid) then return false end
  if entity.type == "electric-pole" or entity.type == "power-switch" then return true end
  return entity.type == "entity-ghost"
    and (entity.ghost_type == "electric-pole" or entity.ghost_type == "power-switch")
end

local function copper_connectors(entity)
  local connectors = {}
  if not (entity and entity.valid) then return connectors end

  local pole = entity.get_wire_connector(
    defines.wire_connector_id.pole_copper,
    false
  )
  if pole then connectors[#connectors + 1] = pole end

  for _, connector_id in ipairs({
    defines.wire_connector_id.power_switch_left_copper,
    defines.wire_connector_id.power_switch_right_copper
  }) do
    local connector = entity.get_wire_connector(connector_id, false)
    if connector then connectors[#connectors + 1] = connector end
  end
  return connectors
end

local function warn_player(player, message)
  if not (player and player.valid and player.connected) then return end
  local security = ensure_security_root()
  local previous = security.warning_tick_by_player[player.index] or -WARNING_INTERVAL
  if game.tick - previous < WARNING_INTERVAL then return end
  security.warning_tick_by_player[player.index] = game.tick
  player.print(message)
end

local function warn_team(record, message)
  if not record then return end
  local security = ensure_security_root()
  local previous = security.warning_tick_by_team[record.id] or -WARNING_INTERVAL
  if game.tick - previous < WARNING_INTERVAL then return end
  security.warning_tick_by_team[record.id] = game.tick
  local force = Teams.get_force(record)
  if not force then return end
  for _, player in pairs(force.connected_players) do
    player.print(message)
  end
end

local function sanitize_connector(connector, owner_team, actor)
  if not (connector and connector.valid and owner_team) then return 0 end
  local removed = 0
  -- connections is a snapshot, so disconnecting while iterating is safe.
  for _, connection in pairs(connector.connections) do
    local target = connection.target
    local owner = target and target.valid and target.owner or nil
    local other_team = team_for_entity(owner)
    if other_team
      and other_team.id ~= owner_team.id
      and not power_sharing_allowed(owner_team, other_team) then
      local origin = connection.origin or defines.wire_origin.player
      if connector.disconnect_from(target, origin) then
        removed = removed + 1
        local label = other_team.display_name or other_team.force_name
        local message = {"sceatorio.electricity-wire-removed", label}
        if actor then
          warn_player(actor, message)
        else
          warn_team(owner_team, message)
        end
      end
    end
  end
  if removed > 0 then
    local stats = ensure_security_root().stats
    stats.wires_removed = stats.wires_removed + removed
  end
  return removed
end

local function sanitize_entity_wires(entity, actor)
  local record = team_for_entity(entity)
  if not record then return 0 end
  local removed = 0
  for _, connector in ipairs(copper_connectors(entity)) do
    removed = removed + sanitize_connector(connector, record, actor)
  end
  return removed
end

local function register_connector_entity(entity)
  if not (is_connector_entity(entity) and entity.unit_number and team_for_entity(entity)) then
    return
  end
  local registry = ensure_security_root().pole_registry
  local unit_number = entity.unit_number
  if registry.slot_by_unit[unit_number] then return end
  local slot = registry.next_slot
  registry.next_slot = slot + 1
  registry.entity_by_slot[slot] = entity
  registry.unit_by_slot[slot] = unit_number
  registry.slot_by_unit[unit_number] = slot
end

local function remove_registry_slot(registry, slot)
  local last_slot = registry.next_slot - 1
  local removed_unit = registry.unit_by_slot[slot]
  if removed_unit then registry.slot_by_unit[removed_unit] = nil end

  if slot ~= last_slot then
    local moved_unit = registry.unit_by_slot[last_slot]
    registry.entity_by_slot[slot] = registry.entity_by_slot[last_slot]
    registry.unit_by_slot[slot] = moved_unit
    if moved_unit then registry.slot_by_unit[moved_unit] = slot end
  else
    registry.entity_by_slot[slot] = nil
    registry.unit_by_slot[slot] = nil
  end
  registry.entity_by_slot[last_slot] = nil
  registry.unit_by_slot[last_slot] = nil
  registry.next_slot = math.max(1, last_slot)
  registry.cursor = math.min(registry.cursor, registry.next_slot - 1)
end

local function network_ids_for(entity)
  local ids = {}
  if not (entity and entity.valid) then return ids end
  local networks = entity.electric_networks
  if not networks then return ids end
  for _, network in pairs(networks) do
    if network and network.valid then ids[network.id] = true end
  end
  return ids
end

local function connector_network_id(entity)
  if not (entity and entity.valid) then return nil end
  local connector = entity.get_wire_connector(
    defines.wire_connector_id.pole_copper,
    false
  )
  local network = connector and connector.valid and connector.electric_network or nil
  return network and network.valid and network.id or nil
end

local function unauthorized_entity_supplied_by_pole(pole, pole_team, limit)
  if not (pole and pole.valid and pole.type == "electric-pole") then return nil end
  local network_id = connector_network_id(pole)
  if not network_id then return nil end

  local radius = pole.prototype.get_supply_area_distance(pole.quality)
  local position = pole.position
  local area = {
    {position.x - radius, position.y - radius},
    {position.x + radius, position.y + radius}
  }
  -- Only other registered teams' entities can be cross-team conflicts. Counting
  -- neutral/enemy/own-force entities toward the bound refunded legitimate
  -- builds inside dense single-team bases (2.0.5 false-positive fix).
  local saturated = false
  for _, other_team in pairs(State.get().teams_by_id) do
    if other_team.id ~= pole_team.id
      and not power_sharing_allowed(pole_team, other_team) then
      local force = Teams.get_force(other_team)
      if force and force.valid then
        local query = {area = area, force = force}
        if limit then query.limit = limit + 1 end
        local entities = pole.surface.find_entities_filtered(query)
        if limit and #entities > limit then saturated = true end
        local count = limit and math.min(#entities, limit) or #entities
        for index = 1, count do
          local entity = entities[index]
          if entity.valid then
            local networks = network_ids_for(entity)
            if networks[network_id] then return entity, other_team, saturated end
          end
        end
      end
    end
  end
  return nil, nil, saturated
end

local function expanded_area(entity, distance)
  local box = entity.bounding_box
  return {
    {box.left_top.x - distance, box.left_top.y - distance},
    {box.right_bottom.x + distance, box.right_bottom.y + distance}
  }
end

local function unauthorized_pole_supplying_entity(entity, entity_team)
  if not entity.prototype.electric_energy_source_prototype then return nil end
  local network_ids = network_ids_for(entity)
  if not next(network_ids) then return nil end

  local poles = entity.surface.find_entities_filtered({
    area = expanded_area(entity, prototypes.max_electric_pole_supply_area_distance),
    type = "electric-pole"
  })
  for _, pole in pairs(poles) do
    local pole_team = team_for_entity(pole)
    if pole_team
      and pole_team.id ~= entity_team.id
      and not power_sharing_allowed(entity_team, pole_team) then
      local network_id = connector_network_id(pole)
      if network_id and network_ids[network_id] then return pole, pole_team end
    end
  end
  return nil
end

local function implicit_conflict(entity, record)
  if entity.type == "electric-pole" then
    return unauthorized_entity_supplied_by_pole(entity, record)
  end
  return unauthorized_pole_supplying_entity(entity, record)
end

local function copy_item(item)
  local quality = item.quality
  if type(quality) ~= "string" and quality then quality = quality.name end
  return {name = item.name, count = item.count, quality = quality or "normal"}
end

local function consumed_player_items(event)
  local items = {}
  -- on_built_entity.consumed_items is the exact 2.1 inventory consumed by this
  -- placement (including multi-item and quality-aware placements).
  if not (event.consumed_items and event.consumed_items.valid) then return items end
  for _, item in pairs(event.consumed_items.get_contents()) do
    items[#items + 1] = copy_item(item)
  end
  return items
end

local function consumed_robot_item(event, entity)
  local stack = event.stack
  local name
  local quality = entity.quality and entity.quality.name or "normal"
  if stack and stack.valid and stack.valid_for_read then
    name = stack.name
    quality = stack.quality and stack.quality.name or quality
  end

  local count = 1
  local place_items = entity.prototype.items_to_place_this or {}
  for _, item in pairs(place_items) do
    if not name or item.name == name then
      name = item.name
      count = item.count
      break
    end
  end
  if not name then return {} end
  return {{name = name, count = count, quality = quality}}
end

local function spill_remainder(surface, position, force, item, inserted)
  local remaining = item.count - inserted
  if remaining <= 0 then return end
  surface.spill_item_stack({
    position = position,
    stack = {name = item.name, count = remaining, quality = item.quality},
    enable_looted = true,
    force = force,
    allow_belts = false
  })
end

local function refund_player(player, surface, position, items)
  for _, item in ipairs(items) do
    local inserted = player.insert(item)
    spill_remainder(surface, position, player.force, item, inserted)
  end
end

local function refund_robot(robot, surface, position, force, items)
  local inventory = robot and robot.valid
    and robot.get_inventory(defines.inventory.robot_cargo)
    or nil
  for _, item in ipairs(items) do
    local inserted = inventory and inventory.valid and inventory.insert(item) or 0
    spill_remainder(surface, position, force, item, inserted)
  end
end

local function build_context(event, entity, mode)
  local context = {mode = mode, items = {}}
  if mode == "player" then
    context.player_index = event.player_index
    context.items = consumed_player_items(event)
  elseif mode == "robot" then
    context.robot = event.robot
    context.items = consumed_robot_item(event, entity)
  end
  return context
end

local function reject_build(entity, record, other_team, context)
  local surface = entity.surface
  local position = {x = entity.position.x, y = entity.position.y}
  local force = entity.force
  local player = context.mode == "player"
    and context.player_index
    and game.players[context.player_index]
    or nil
  local robot = context.mode == "robot" and context.robot or nil
  local items = context.items or {}

  local destroyed = entity.destroy({
    raise_destroy = true,
    player = player
  })
  if not destroyed then
    log("[Sceatorio] Could not reject an implicit cross-team electric connection at "
      .. surface.name .. " " .. position.x .. "," .. position.y)
    return false
  end

  if player then
    refund_player(player, surface, position, items)
  elseif context.mode == "robot" then
    refund_robot(robot, surface, position, force, items)
  elseif context.mode == "player" then
    for _, item in ipairs(items) do
      spill_remainder(surface, position, force, item, 0)
    end
  end
  ensure_security_root().stats.builds_rejected =
    ensure_security_root().stats.builds_rejected + 1

  local label = other_team
    and (other_team.display_name or other_team.force_name)
    or nil
  local message = label
    and {"sceatorio.electricity-build-rejected", label}
    or {"sceatorio.electricity-build-audit-saturated"}
  if player then
    warn_player(player, message)
  elseif context.mode == "robot" then
    local last_user = robot and robot.valid and robot.last_user or nil
    if last_user then warn_player(last_user, message) else warn_team(record, message) end
  else
    warn_team(record, label
      and {"sceatorio.electricity-script-build-rejected", label}
      or {"sceatorio.electricity-script-build-audit-saturated"})
  end
  return true
end

local function process_build(entity, context, reject_script)
  if not (entity and entity.valid) then return end
  if is_connector_entity(entity) then register_connector_entity(entity) end
  if not isolation_enabled() then return end

  local record = team_for_entity(entity)
  if not record then return end
  if is_connector_entity(entity) then sanitize_entity_wires(entity,
    context.mode == "player" and context.player_index
    and game.players[context.player_index]
    or nil)
  end
  if not entity.valid or entity.type == "entity-ghost" then return end

  local _, other_team = implicit_conflict(entity, record)
  if not other_team then return end
  -- A mod that raises a build event may access its returned LuaEntity after
  -- all event handlers finish. Destroy script/cloned entities on the next tick
  -- so isolation cannot turn an otherwise compatible raised build into a mod
  -- crash. Player and robot events have native temporary refund inventories and
  -- are rejected synchronously.
  if context.mode ~= "script" or reject_script then
    reject_build(entity, record, other_team, context)
  end
end

local function needs_deferred_build_audit(entity)
  if not (entity and entity.valid) or entity.type == "entity-ghost" then return false end
  return is_connector_entity(entity)
    or entity.prototype.electric_energy_source_prototype ~= nil
end

local function enqueue_deferred_build_audit(entity, context)
  if not needs_deferred_build_audit(entity) then return end
  local queue = ensure_security_root().deferred_build_audits
  if queue.count >= MAX_PENDING_BUILD_AUDITS then
    local record = team_for_entity(entity)
    if record then reject_build(entity, record, nil, context) end
    return
  end
  local tail = (queue.tail % MAX_PENDING_BUILD_AUDITS) + 1
  queue.tail = tail
  queue.entries[tail] = {
    entity = entity,
    context = context,
    ready_tick = game.tick + 1
  }
  queue.count = queue.count + 1
end

local function pop_deferred_build_audit(queue)
  if queue.count <= 0 then return nil end
  local entry = queue.entries[queue.head]
  queue.entries[queue.head] = nil
  queue.head = (queue.head % MAX_PENDING_BUILD_AUDITS) + 1
  queue.count = queue.count - 1
  if queue.count == 0 then
    queue.head = 1
    queue.tail = 0
  end
  return entry
end

local function audit_silent_child_poles(entity, context)
  if not (entity and entity.valid) then return end
  local record = team_for_entity(entity)
  if not record then return end

  process_build(entity, context, true)
  if not (entity and entity.valid) then return end

  local origin_networks = network_ids_for(entity)
  if not next(origin_networks) then return end
  local registry = ensure_security_root().pole_registry
  local poles = entity.surface.find_entities_filtered({
    area = expanded_area(entity, prototypes.max_electric_pole_supply_area_distance + 2),
    type = "electric-pole",
    force = entity.force,
    limit = MAX_LOCAL_POLE_SCAN + 1
  })
  if #poles > MAX_LOCAL_POLE_SCAN then
    reject_build(entity, record, nil, context)
    return
  end

  -- A composite entity may silently create its own pole after the visible
  -- player/robot event. Only poles the registry has never seen are unannounced
  -- children: already registered neighbours were sanitized at their own build
  -- and stay covered by the standing round-robin audit, so counting them toward
  -- the child bound refunded legitimate builds inside dense own-team pole grids
  -- (2.0.6 false-positive fix).
  local silent_children = {}
  for _, pole in ipairs(poles) do
    if pole.unit_number and not registry.slot_by_unit[pole.unit_number] then
      silent_children[#silent_children + 1] = pole
    end
  end
  if #silent_children > MAX_LOCAL_CHILD_POLES then
    reject_build(entity, record, nil, context)
    return
  end

  -- Register and disconnect the unannounced poles first, then detect a foreign
  -- consumer supplied by any of them inside the origin's network.
  for _, pole in ipairs(silent_children) do
    register_connector_entity(pole)
    sanitize_entity_wires(pole)
  end
  if not entity.valid then return end
  origin_networks = network_ids_for(entity)
  for _, pole in ipairs(silent_children) do
    local network_id = connector_network_id(pole)
    if network_id and origin_networks[network_id] then
      local _, other_team, saturated = unauthorized_entity_supplied_by_pole(
        pole,
        record,
        MAX_LOCAL_SUPPLIED_ENTITIES
      )
      if other_team then
        -- Removing only the visible parent is insufficient for a composite mod
        -- that leaves a silently created pole alive until its destroy callback.
        -- Remove the unannounced conflicting child first; this loop only ever
        -- walks silent children, so no previously registered pole and no
        -- foreign team's supplied entity is ever deleted here.
        if pole.valid then
          pole.destroy({raise_destroy = true})
        end
        reject_build(entity, record, other_team, context)
        return
      end
      if saturated then
        reject_build(entity, record, nil, context)
        return
      end
    end
  end
end

function Security.initialize()
  local security = ensure_security_root()
  for _, record in pairs(State.get().teams_by_id) do
    ensure_team_security(record)
  end
  for _, surface in pairs(game.surfaces) do
    if not is_platform_surface(surface) then
      security.chunk_migration.by_surface[surface.index] =
        security.chunk_migration.by_surface[surface.index]
        or {scanned_count = 0, complete = false}
    end
  end
end

function Security.on_player_built(event)
  local entity = event.entity
  local context = build_context(event, entity, "player")
  process_build(entity, context, false)
  enqueue_deferred_build_audit(entity, context)
end

function Security.on_robot_built(event)
  local entity = event.entity
  local context = build_context(event, entity, "robot")
  process_build(entity, context, false)
  enqueue_deferred_build_audit(entity, context)
end

function Security.on_script_built(event)
  local entity = event.entity
  local context = build_context(event, entity, "script")
  process_build(entity, context, false)
  enqueue_deferred_build_audit(entity, context)
end

function Security.on_entity_cloned(event)
  local entity = event.destination
  local context = build_context(event, entity, "script")
  process_build(entity, context, false)
  enqueue_deferred_build_audit(entity, context)
end

function Security.on_selected_entity_changed(event)
  if not isolation_enabled() then return end
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  for _, entity in pairs({event.last_entity, player.selected}) do
    if is_connector_entity(entity) then
      register_connector_entity(entity)
      sanitize_entity_wires(entity, player)
    end
  end
end

local function configured_audit_budget()
  local budget = setting("sceatorio-electricity-audit-budget", DEFAULT_AUDIT_BUDGET)
  if type(budget) ~= "number" then return DEFAULT_AUDIT_BUDGET end
  return math.max(1, math.floor(budget))
end

local function configured_migration_chunks()
  local budget = setting(
    "sceatorio-electricity-migration-chunks-per-audit",
    DEFAULT_MIGRATION_CHUNKS
  )
  if type(budget) ~= "number" then return DEFAULT_MIGRATION_CHUNKS end
  return math.max(1, math.floor(budget))
end

function Security.audit_poles(budget)
  if not isolation_enabled() then return 0 end
  local registry = ensure_security_root().pole_registry
  local processed = 0
  while processed < budget and registry.next_slot > 1 do
    local count = registry.next_slot - 1
    local slot = (registry.cursor % count) + 1
    registry.cursor = slot
    local entity = registry.entity_by_slot[slot]
    if not is_connector_entity(entity) then
      remove_registry_slot(registry, slot)
      registry.cursor = math.max(0, slot - 1)
    else
      sanitize_entity_wires(entity)
    end
    processed = processed + 1
  end
  return processed
end

local function scan_migration_chunk(surface, chunk)
  if not surface.is_chunk_generated(chunk) then return end
  local entities = surface.find_entities_filtered({
    area = chunk.area,
    type = {"electric-pole", "power-switch"}
  })
  for _, entity in pairs(entities) do
    if team_for_entity(entity) then
      register_connector_entity(entity)
      sanitize_entity_wires(entity)
    end
  end
end

local function migrate_surface_chunks(surface, progress, budget)
  local runtime = chunk_migration_iterators[surface.index]
  if not runtime then
    runtime = {
      iterator = surface.get_chunks(),
      skip_remaining = progress.scanned_count or 0
    }
    chunk_migration_iterators[surface.index] = runtime
  end

  local consumed = 0
  while consumed < budget do
    local chunk = runtime.iterator()
    if not chunk then
      progress.complete = true
      chunk_migration_iterators[surface.index] = nil
      return consumed, true
    end
    consumed = consumed + 1
    if runtime.skip_remaining > 0 then
      runtime.skip_remaining = runtime.skip_remaining - 1
    else
      progress.scanned_count = (progress.scanned_count or 0) + 1
      scan_migration_chunk(surface, chunk)
    end
  end
  return consumed, false
end

function Security.migrate_existing_poles(budget)
  if not isolation_enabled() then return 0 end
  local migration = ensure_security_root().chunk_migration
  local consumed = 0
  for surface_index, progress in pairs(migration.by_surface) do
    if consumed >= budget then break end
    local surface = game.surfaces[surface_index]
    if not (surface and surface.valid) then
      migration.by_surface[surface_index] = nil
      chunk_migration_iterators[surface_index] = nil
    elseif not progress.complete and not is_platform_surface(surface) then
      local used = migrate_surface_chunks(surface, progress, budget - consumed)
      consumed = consumed + used
    end
  end
  return consumed
end

local function audit_near_player(player, limit)
  if not (player and player.valid and player.connected) then return end
  if is_platform_surface(player.surface) then return end
  local radius = prototypes.max_electric_pole_connection_distance + 2
  local position = player.position
  local entities = player.surface.find_entities_filtered({
    area = {
      {position.x - radius, position.y - radius},
      {position.x + radius, position.y + radius}
    },
    type = {"electric-pole", "power-switch"},
    limit = limit
  })
  for _, entity in pairs(entities) do
    register_connector_entity(entity)
    sanitize_entity_wires(entity, player)
  end
end

function Security.on_player_cursor_stack_changed(event)
  if not isolation_enabled() then return end
  audit_near_player(
    game.players[event.player_index],
    configured_audit_budget() * DISCOVERY_LIMIT_MULTIPLIER
  )
end

function Security.on_tick(event)
  local queue = ensure_security_root().deferred_build_audits
  if not isolation_enabled() then
    queue.head = 1
    queue.tail = 0
    queue.count = 0
    queue.entries = {}
    return
  end

  for _ = 1, DEFERRED_BUILD_AUDIT_BUDGET do
    if queue.count <= 0 then return end
    local entry = queue.entries[queue.head]
    if entry and (entry.ready_tick or 0) > event.tick then return end
    entry = pop_deferred_build_audit(queue)
    if entry and entry.entity and entry.context then
      audit_silent_child_poles(entry.entity, entry.context)
    end
  end
end

function Security.tick()
  Security.audit_poles(configured_audit_budget())
  Security.migrate_existing_poles(configured_migration_chunks())
end

function Security.on_surface_created(event)
  local surface = game.surfaces[event.surface_index]
  if not (surface and surface.valid) or is_platform_surface(surface) then return end
  ensure_security_root().chunk_migration.by_surface[surface.index] = {
    scanned_count = 0,
    complete = false
  }
  chunk_migration_iterators[surface.index] = nil
end

function Security.on_surface_deleted(event)
  ensure_security_root().chunk_migration.by_surface[event.surface_index] = nil
  chunk_migration_iterators[event.surface_index] = nil
end

local function update_power_share(command)
  if not command.player_index then return end
  local player = game.players[command.player_index]
  local record = player and Teams.get_for_player(player) or nil
  if not record then
    if player then player.print({"sceatorio.power-share-no-team"}) end
    return
  end
  if not player.admin and record.owner_player_index ~= player.index then
    player.print({"sceatorio.power-share-not-owner"})
    return
  end

  local target_id, action = string.match(command.parameter or "", "^%s*(%d+)%s*(%a*)%s*$")
  local target = target_id and Teams.get(tonumber(target_id)) or nil
  if not target or target.id == record.id then
    player.print({"sceatorio.power-share-usage"})
    return
  end
  action = action ~= "" and string.lower(action) or "status"
  local team_security = ensure_team_security(record)
  if action == "on" then
    team_security.power_share_intents[target.id] = true
  elseif action == "off" then
    team_security.power_share_intents[target.id] = nil
  elseif action ~= "status" then
    player.print({"sceatorio.power-share-usage"})
    return
  end

  local active = power_sharing_allowed(record, target)
  player.print({
    active and "sceatorio.power-share-active" or "sceatorio.power-share-inactive",
    target.id,
    target.display_name or target.force_name
  })
end

commands.add_command(
  "sceatorio-power-share",
  {"sceatorio.power-share-command-help"},
  update_power_share
)

return Security
