local State = require("src.core.state")
local Teams = require("src.game.teams")

local Radars = {}

local CHUNKS_PER_TICK = 32
local MAX_PENDING_CHUNKS = 4096
local CATCHUP_CHUNKS_PER_TICK = 16
local CATCHUP_QUEUE_LOW_WATER = 1024
local BACKPRESSURE_WARNING_INTERVAL = 10 * 60 * 60
local SUPPRESSION_GENERATIONS = 2
local CHART_UNION_FORCE_NAME = "sceatorio-chart-union"
local bulk_copying = false
local catchup_iterators = {}

local function canonical_force(create)
  local force = game.forces[CHART_UNION_FORCE_NAME]
  if not (force and force.valid) and create then
    force = game.create_force(CHART_UNION_FORCE_NAME)
  end
  return force and force.valid and force or nil
end

local function valid_team_forces()
  local forces = {}
  Teams.for_each(function(record)
    local force = Teams.get_force(record)
    if force and force.valid then forces[#forces + 1] = force end
  end)
  table.sort(forces, function(first, second) return first.index < second.index end)
  return forces
end

local function queue_state()
  local root = State.get()
  root.chart_sync = root.chart_sync or {
    queue = {},
    head = 1,
    pending = {},
    suppression_current = {},
    suppression_previous = {},
    suppression_tick = -1,
    total_enqueued = 0,
    total_propagated = 0,
    total_suppressed = 0,
    catchup_queue = {},
    catchup_head = 1,
    catchup_by_surface = {},
    total_deferred = 0,
    total_catchup_scanned = 0,
    total_catchup_passes = 0,
    total_catchup_restarts = 0,
    max_queue_depth = 0,
    backpressure_active = false,
    last_backpressure_warning_tick = -BACKPRESSURE_WARNING_INTERVAL,
    total_backpressure_warnings = 0,
    total_backpressure_recoveries = 0
  }
  local sync = root.chart_sync
  sync.queue = sync.queue or {}
  sync.head = sync.head or 1
  sync.pending = sync.pending or {}
  if not sync.suppression_current then
    sync.suppression_current = {}
    sync.suppression_previous = {}
    sync.suppression_tick = -1
    -- Drop the early 120-tick guard layout instead of carrying its potentially
    -- large expiry queue into the bounded two-generation layout.
    sync.suppressed = nil
    sync.suppression_expiry = nil
    sync.suppression_head = nil
  end
  sync.suppression_previous = sync.suppression_previous or {}
  sync.suppression_tick = sync.suppression_tick or -1
  sync.total_enqueued = sync.total_enqueued or 0
  sync.total_propagated = sync.total_propagated or 0
  sync.total_suppressed = sync.total_suppressed or 0
  sync.catchup_queue = sync.catchup_queue or {}
  sync.catchup_head = sync.catchup_head or 1
  sync.catchup_by_surface = sync.catchup_by_surface or {}
  sync.total_deferred = sync.total_deferred or 0
  sync.total_catchup_scanned = sync.total_catchup_scanned or 0
  sync.total_catchup_passes = sync.total_catchup_passes or 0
  sync.total_catchup_restarts = sync.total_catchup_restarts or 0
  sync.max_queue_depth = sync.max_queue_depth or 0
  sync.backpressure_active = sync.backpressure_active or false
  sync.last_backpressure_warning_tick = sync.last_backpressure_warning_tick
    or -BACKPRESSURE_WARNING_INTERVAL
  sync.total_backpressure_warnings = sync.total_backpressure_warnings or 0
  sync.total_backpressure_recoveries = sync.total_backpressure_recoveries or 0
  return sync
end

local function queue_depth(sync)
  return math.max(0, #sync.queue - sync.head + 1)
end

-- Factorio's MapPosition accepts both {x = ..., y = ...} and the positional
-- {..., ...} form. Normalize at this module boundary before persisting or
-- doing arithmetic so callers can use either documented representation.
local function normalize_map_position(position)
  if type(position) ~= "table" then return nil end
  local x = position.x
  local y = position.y
  if x == nil then x = position[1] end
  if y == nil then y = position[2] end
  if type(x) ~= "number" or type(y) ~= "number"
    or x ~= x or y ~= y
    or x == math.huge or x == -math.huge
    or y == math.huge or y == -math.huge then
    return nil
  end
  return {x = x, y = y}
end

local function normalize_chart_area(area)
  if type(area) ~= "table" then return nil, nil end
  return normalize_map_position(area.left_top or area[1]),
    normalize_map_position(area.right_bottom or area[2])
end

local function chunk_key(surface_index, position)
  return table.concat({surface_index, position.x, position.y}, ":")
end

local function propagation_key(key, force_index)
  return key .. ":" .. force_index
end

local function rotate_suppressions(sync, tick)
  if sync.suppression_tick == tick then return end
  if sync.suppression_tick == tick - 1 then
    sync.suppression_previous = sync.suppression_current
  else
    sync.suppression_previous = {}
  end
  sync.suppression_current = {}
  sync.suppression_tick = tick
end

local function warn_backpressure(sync, tick)
  sync.backpressure_active = true
  if tick - sync.last_backpressure_warning_tick
    < BACKPRESSURE_WARNING_INTERVAL then
    return
  end
  sync.last_backpressure_warning_tick = tick
  sync.total_backpressure_warnings = sync.total_backpressure_warnings + 1
  log(
    "[Sceatorio] Radar chart queue reached its " .. MAX_PENDING_CHUNKS
      .. "-chunk cap; bounded background chart reconciliation is active."
  )
  game.print({"sceatorio.radar-backpressure-warning", MAX_PENDING_CHUNKS})
end

local function mark_surface_for_catchup(sync, surface_index, tick)
  local job = sync.catchup_by_surface[surface_index]
  if not job then
    job = {surface_index = surface_index, version = 0, passes = 0}
    sync.catchup_by_surface[surface_index] = job
    sync.catchup_queue[#sync.catchup_queue + 1] = surface_index
  end
  -- A discovery arriving while this surface is already being scanned makes
  -- the current pass stale. Completion will start one more full bounded pass.
  job.version = job.version + 1
  sync.total_deferred = sync.total_deferred + 1
  warn_backpressure(sync, tick)
end

local function enqueue(sync, event, schedule_catchup)
  local key = chunk_key(event.surface_index, event.position)
  if sync.pending[key] then return "duplicate" end
  local left_top, right_bottom = normalize_chart_area(event.area)
  if not (left_top and right_bottom) then return "invalid" end
  if queue_depth(sync) >= MAX_PENDING_CHUNKS then
    if schedule_catchup ~= false then
      mark_surface_for_catchup(sync, event.surface_index, event.tick or game.tick)
    end
    return "deferred"
  end
  sync.pending[key] = true
  sync.total_enqueued = sync.total_enqueued + 1
  sync.queue[#sync.queue + 1] = {
    key = key,
    source_force_index = event.force.index,
    surface_index = event.surface_index,
    position = {x = event.position.x, y = event.position.y},
    area = {
      {x = left_top.x, y = left_top.y},
      {x = right_bottom.x, y = right_bottom.y}
    }
  }
  sync.max_queue_depth = math.max(sync.max_queue_depth, queue_depth(sync))
  return "queued"
end

-- A dedicated playerless force is the persistent canonical union of team
-- discoveries. A full copy is safe only for a newly registered force whose
-- chart is still blank. Avoid relying on copy semantics between established
-- charts; incremental updates use the bounded queue below.
function Radars.synchronize_team_charts(destination_force)
  if not (destination_force and destination_force.valid
    and Teams.get_by_force(destination_force)) then
    return
  end
  local canonical = canonical_force()
  if not canonical or canonical.index == destination_force.index then return end

  bulk_copying = true
  local ok, reason = pcall(function()
    for _, surface in pairs(game.surfaces) do
      if surface.valid then
        destination_force.copy_chart(canonical, surface, surface)
      end
    end
  end)
  bulk_copying = false
  if not ok then error(reason) end
end

function Radars.initialize()
  queue_state()
  canonical_force(true)
  catchup_iterators = {}
end

function Radars.on_chunk_charted(event)
  if bulk_copying then return end
  local sync = queue_state()
  rotate_suppressions(sync, event.tick)
  local key = chunk_key(event.surface_index, event.position)
  local guard = propagation_key(key, event.force.index)
  if sync.suppression_current[guard] or sync.suppression_previous[guard] then
    sync.suppression_current[guard] = nil
    sync.suppression_previous[guard] = nil
    sync.total_suppressed = sync.total_suppressed + 1
    return
  end
  -- Only explicitly registered human-team charts can add discoveries. The
  -- canonical playerless force and unrelated system forces are never sources.
  if not Teams.get_by_force(event.force) then return end
  enqueue(sync, event, true)
end

-- LuaForce.chart updates chart data directly but does not emit
-- on_chunk_charted in 2.1.12. Route Sceatorio-owned chart calls through this
-- wrapper so they obey the same bounded global propagation as native radar and
-- player chart events.
function Radars.chart(force, surface, area)
  if not (force and force.valid and surface and surface.valid and area) then return 0 end
  if not Teams.get_by_force(force) then return 0 end

  local left_top, right_bottom = normalize_chart_area(area)
  if not (left_top and right_bottom) then return 0 end
  local chart_area = {
    {x = left_top.x, y = left_top.y},
    {x = right_bottom.x, y = right_bottom.y}
  }
  force.chart(surface, chart_area)
  local minimum_x = math.floor(left_top.x / 32)
  local minimum_y = math.floor(left_top.y / 32)
  local maximum_x = math.floor((right_bottom.x - 0.001) / 32)
  local maximum_y = math.floor((right_bottom.y - 0.001) / 32)
  local sync = queue_state()
  local queued = 0
  for x = minimum_x, maximum_x do
    for y = minimum_y, maximum_y do
      local result = enqueue(sync, {
        force = force,
        surface_index = surface.index,
        position = {x = x, y = y},
        area = {{x = x * 32, y = y * 32}, {x = (x + 1) * 32, y = (y + 1) * 32}},
        tick = game.tick
      }, true)
      if result == "queued" then queued = queued + 1 end
    end
  end
  return queued
end

-- Other mods that intentionally chart for a registered Sceatorio force must
-- use this single-chunk wrapper because LuaForce.chart does not raise
-- on_chunk_charted in Factorio 2.1.12. This is a mod-to-mod API, not a player,
-- command, RCON, or arbitrary-area interface.
function Radars.share_chunk(force_name, surface_identifier, position)
  local force = type(force_name) == "string" and game.forces[force_name] or nil
  local surface = (type(surface_identifier) == "string"
      or type(surface_identifier) == "number")
    and game.surfaces[surface_identifier] or nil
  local x = type(position) == "table" and position.x or nil
  local y = type(position) == "table" and position.y or nil
  if not (force and force.valid and Teams.get_by_force(force)
    and surface and surface.valid) then
    return {ok = false, error = "registered team force or surface not found"}
  end
  if type(x) ~= "number" or type(y) ~= "number"
    or x ~= x or y ~= y
    or x ~= math.floor(x) or y ~= math.floor(y)
    or math.abs(x) > 1000000 or math.abs(y) > 1000000 then
    return {ok = false, error = "bounded integer chunk position required"}
  end
  local queued = Radars.chart(force, surface, {
    {x * 32, y * 32},
    {(x + 1) * 32, (y + 1) * 32}
  })
  return {ok = true, queued = queued}
end

local function suppress_next(sync, key, force_index)
  local guard = propagation_key(key, force_index)
  sync.suppression_current[guard] = true
end

local function propagate(sync, entry, forces, canonical)
  local surface = game.surfaces[entry.surface_index]
  if not (surface and surface.valid) then return end
  if canonical and canonical.valid and canonical.index ~= entry.source_force_index then
    -- LuaForce.chart does not currently emit on_chunk_charted, but retain the
    -- same suppression guard as team destinations so an engine change cannot
    -- make the canonical write recursively re-enter the queue.
    suppress_next(sync, entry.key, canonical.index)
    canonical.chart(surface, entry.area)
  end
  for _, force in ipairs(forces) do
    if force.index ~= entry.source_force_index then
      suppress_next(sync, entry.key, force.index)
      force.chart(surface, entry.area)
      sync.total_propagated = sync.total_propagated + 1
    end
  end
end

local function compact_catchup(sync)
  if sync.catchup_head <= 64
    or sync.catchup_head <= #sync.catchup_queue / 2 then
    return
  end
  local remaining = {}
  for index = sync.catchup_head, #sync.catchup_queue do
    local surface_index = sync.catchup_queue[index]
    if sync.catchup_by_surface[surface_index] then
      remaining[#remaining + 1] = surface_index
    end
  end
  sync.catchup_queue = remaining
  sync.catchup_head = 1
end

local function retire_catchup_surface(sync, surface_index)
  sync.catchup_by_surface[surface_index] = nil
  catchup_iterators[surface_index] = nil
  sync.catchup_head = sync.catchup_head + 1
end

local function chart_source_for_chunk(surface, position, forces, canonical)
  local source
  local fully_shared = canonical and canonical.valid
    and canonical.is_chunk_charted(surface, position) or false
  if fully_shared then source = canonical end

  for _, force in ipairs(forces) do
    local charted = force.is_chunk_charted(surface, position)
    if charted and not source then source = force end
    if not charted then fully_shared = false end
  end
  return source, fully_shared
end

local function process_catchup(sync, forces, canonical)
  if queue_depth(sync) > CATCHUP_QUEUE_LOW_WATER then return end

  local scanned = 0
  while scanned < CATCHUP_CHUNKS_PER_TICK
    and queue_depth(sync) < MAX_PENDING_CHUNKS
    and sync.catchup_head <= #sync.catchup_queue do
    local surface_index = sync.catchup_queue[sync.catchup_head]
    local job = sync.catchup_by_surface[surface_index]
    local surface = game.surfaces[surface_index]
    if not job or not (surface and surface.valid) then
      retire_catchup_surface(sync, surface_index)
    else
      local runtime = catchup_iterators[surface_index]
      if not runtime then
        runtime = {
          iterator = surface.get_chunks(),
          version = job.version
        }
        catchup_iterators[surface_index] = runtime
      end

      local chunk = runtime.iterator()
      if not chunk then
        job.passes = job.passes + 1
        sync.total_catchup_passes = sync.total_catchup_passes + 1
        catchup_iterators[surface_index] = nil
        if job.version == runtime.version then
          retire_catchup_surface(sync, surface_index)
        else
          sync.total_catchup_restarts = sync.total_catchup_restarts + 1
        end
      else
        scanned = scanned + 1
        sync.total_catchup_scanned = sync.total_catchup_scanned + 1
        local position = {x = chunk.x, y = chunk.y}
        sync.last_catchup_surface_index = surface_index
        sync.last_catchup_chunk = position
        local source, fully_shared = chart_source_for_chunk(
          surface,
          position,
          forces,
          canonical
        )
        if source and not fully_shared then
          enqueue(sync, {
            force = source,
            surface_index = surface_index,
            position = position,
            area = {
              {x = chunk.x * 32, y = chunk.y * 32},
              {x = (chunk.x + 1) * 32, y = (chunk.y + 1) * 32}
            }
          }, false)
        end
      end
    end
  end
  compact_catchup(sync)
end

local function catchup_surface_count(sync)
  local count = 0
  for _ in pairs(sync.catchup_by_surface) do count = count + 1 end
  return count
end

local function report_recovery(sync)
  if not sync.backpressure_active or queue_depth(sync) > 0
    or next(sync.catchup_by_surface) then
    return
  end
  sync.backpressure_active = false
  sync.total_backpressure_recoveries = sync.total_backpressure_recoveries + 1
  log("[Sceatorio] Radar chart backlog reconciled; normal propagation resumed.")
  game.print({"sceatorio.radar-backpressure-recovered"})
end

local function compact(sync)
  if sync.head <= 256 or sync.head <= #sync.queue / 2 then return end
  local remaining = {}
  for index = sync.head, #sync.queue do
    remaining[#remaining + 1] = sync.queue[index]
  end
  sync.queue = remaining
  sync.head = 1
end

function Radars.tick(event)
  local sync = queue_state()
  rotate_suppressions(sync, event.tick)
  if queue_depth(sync) == 0 and not next(sync.catchup_by_surface) then
    report_recovery(sync)
    return
  end
  -- Build and sort this snapshot once for the whole drain/catch-up batch. Team
  -- lifecycle events are not interleaved within one Factorio event handler.
  -- The common idle tick returns above without enumerating any teams.
  local forces = valid_team_forces()
  local canonical = canonical_force()
  local processed = 0
  while processed < CHUNKS_PER_TICK and sync.head <= #sync.queue do
    local entry = sync.queue[sync.head]
    sync.head = sync.head + 1
    sync.pending[entry.key] = nil
    propagate(sync, entry, forces, canonical)
    processed = processed + 1
  end
  if sync.head > #sync.queue then
    sync.queue = {}
    sync.head = 1
  else
    compact(sync)
  end
  process_catchup(sync, forces, canonical)
  report_recovery(sync)
end

function Radars.on_surface_deleted(event)
  local sync = queue_state()
  local queue = {}
  local pending = {}
  for index = sync.head, #sync.queue do
    local entry = sync.queue[index]
    if entry.surface_index ~= event.surface_index then
      queue[#queue + 1] = entry
      pending[entry.key] = true
    end
  end
  sync.queue = queue
  sync.head = 1
  sync.pending = pending
  sync.catchup_by_surface[event.surface_index] = nil
  catchup_iterators[event.surface_index] = nil
  if sync.last_catchup_surface_index == event.surface_index then
    sync.last_catchup_surface_index = nil
    sync.last_catchup_chunk = nil
  end
  local catchup_queue = {}
  for index = sync.catchup_head, #sync.catchup_queue do
    local surface_index = sync.catchup_queue[index]
    if surface_index ~= event.surface_index
      and sync.catchup_by_surface[surface_index] then
      catchup_queue[#catchup_queue + 1] = surface_index
    end
  end
  sync.catchup_queue = catchup_queue
  sync.catchup_head = 1
  -- Suppression keys include a surface index, but clearing the small ephemeral
  -- guard wholesale is safer than retaining keys for an invalid surface.
  sync.suppression_current = {}
  sync.suppression_previous = {}
end

local function count_keys(values)
  local count = 0
  for _ in pairs(values) do count = count + 1 end
  return count
end

function Radars.status()
  local sync = queue_state()
  rotate_suppressions(sync, game.tick)
  return {
    queue_depth = queue_depth(sync),
    queue_capacity = MAX_PENDING_CHUNKS,
    max_queue_depth = sync.max_queue_depth,
    pending_count = count_keys(sync.pending),
    catchup_surface_count = catchup_surface_count(sync),
    backpressure_active = sync.backpressure_active,
    suppression_count = count_keys(sync.suppression_current)
      + count_keys(sync.suppression_previous),
    suppression_generations = SUPPRESSION_GENERATIONS,
    total_enqueued = sync.total_enqueued,
    total_deferred = sync.total_deferred,
    total_propagated = sync.total_propagated,
    total_suppressed = sync.total_suppressed,
    total_catchup_scanned = sync.total_catchup_scanned,
    total_catchup_passes = sync.total_catchup_passes,
    total_catchup_restarts = sync.total_catchup_restarts,
    last_catchup_surface_index = sync.last_catchup_surface_index,
    last_catchup_chunk = sync.last_catchup_chunk,
    total_backpressure_warnings = sync.total_backpressure_warnings,
    total_backpressure_recoveries = sync.total_backpressure_recoveries
  }
end

return Radars
