local State = require("src.core.state")
local Teams = require("src.game.teams")

local Radars = {}

-- Preserve the small, familiar reveal footprints from the original scenario.
-- Areas are still applied one generated chunk at a time so charting can never
-- request terrain generation outside the world players have actually reached.
local PLAYER_RADIUS_TILES = 70
local RADAR_RADIUS_TILES = 112
local MAX_REMOTE_CHUNK_COORDINATE = 1000000
local CHUNK_SIZE = 32
local CHUNK_END_EPSILON = 0.001

local function state()
  local root = State.get()
  root.radar_sharing = root.radar_sharing or {
    passes = 0,
    source_players = 0,
    source_radars = 0,
    chunks_examined = 0,
    generated_chunks = 0,
    chart_writes = 0,
    remote_requests = 0,
    remote_rejections = 0
  }
  return root.radar_sharing
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

local function normalize_chunk_position(position)
  if type(position) ~= "table" then return nil end
  local x = position.x
  local y = position.y
  if x == nil then x = position[1] end
  if y == nil then y = position[2] end
  if type(x) ~= "number" or type(y) ~= "number"
    or x ~= x or y ~= y
    or x ~= math.floor(x) or y ~= math.floor(y)
    or math.abs(x) > MAX_REMOTE_CHUNK_COORDINATE
    or math.abs(y) > MAX_REMOTE_CHUNK_COORDINATE then
    return nil
  end
  return {x = x, y = y}
end

local function chunk_key(surface, position)
  return table.concat({surface.index, position.x, position.y}, ":")
end

local function chart_generated_chunk(surface, position, forces)
  if not surface.is_chunk_generated(position) then return 0, false end

  local area = {
    {x = position.x * CHUNK_SIZE, y = position.y * CHUNK_SIZE},
    {
      x = (position.x + 1) * CHUNK_SIZE - CHUNK_END_EPSILON,
      y = (position.y + 1) * CHUNK_SIZE - CHUNK_END_EPSILON
    }
  }
  local writes = 0
  for _, force in ipairs(forces) do
    -- A charted chunk can still be hidden by fog of war, and `force.chart`
    -- keeps it visible for only part of one sharing interval. Visibility must
    -- therefore NOT gate this refresh: skipping a still-visible chunk would
    -- push the real cadence to every other pass and blank a teammate's marker
    -- for a whole interval. Only work Factorio is already processing is
    -- skipped, so a pending request is never duplicated.
    if not force.is_chunk_requested_for_charting(surface, position) then
      force.chart(surface, area)
      writes = writes + 1
    end
  end
  return writes, true
end

local function share_generated_area(surface, center, radius, forces, seen, stats)
  local minimum_x = math.floor((center.x - radius) / CHUNK_SIZE)
  local minimum_y = math.floor((center.y - radius) / CHUNK_SIZE)
  local maximum_x = math.floor(
    (center.x + radius - CHUNK_END_EPSILON) / CHUNK_SIZE
  )
  local maximum_y = math.floor(
    (center.y + radius - CHUNK_END_EPSILON) / CHUNK_SIZE
  )

  for x = minimum_x, maximum_x do
    for y = minimum_y, maximum_y do
      local position = {x = x, y = y}
      local key = chunk_key(surface, position)
      if not seen[key] then
        seen[key] = true
        stats.chunks_examined = stats.chunks_examined + 1
        local writes, generated = chart_generated_chunk(surface, position, forces)
        if generated then stats.generated_chunks = stats.generated_chunks + 1 end
        stats.chart_writes = stats.chart_writes + writes
      end
    end
  end
end

function Radars.initialize()
  local root = State.get()
  -- The pre-2.0.3 event queue could retain a surface-wide catch-up pass in a
  -- save. It has no consumer in this implementation and must not survive a
  -- configuration change.
  root.chart_sync = nil
  Teams.cancel_pending_charting()
  state()
end

-- Share only the bounded physical neighborhoods that the original scenario
-- exposed: connected characters and radars owned by registered human teams.
-- This deliberately does not consume on_chunk_charted and never scans every
-- generated chunk, so a chart write cannot feed back into another map sweep.
function Radars.share_discoveries(event)
  local forces = valid_team_forces()
  local stats = {
    chunks_examined = 0,
    generated_chunks = 0,
    chart_writes = 0
  }
  local seen = {}
  local source_players = 0
  local source_radars = 0

  for _, player in pairs(game.connected_players) do
    local record = Teams.get_for_player(player)
    local character = player.character
    if record and character and character.valid then
      local surface = character.surface
      if surface and surface.valid then
        source_players = source_players + 1
        share_generated_area(
          surface,
          character.position,
          PLAYER_RADIUS_TILES,
          forces,
          seen,
          stats
        )
      end
    end
  end

  for _, surface in pairs(game.surfaces) do
    if surface.valid then
      for _, radar in pairs(surface.find_entities_filtered({type = "radar"})) do
        if radar.valid and Teams.get_by_force(radar.force) then
          source_radars = source_radars + 1
          share_generated_area(
            surface,
            radar.position,
            RADAR_RADIUS_TILES,
            forces,
            seen,
            stats
          )
        end
      end
    end
  end

  local totals = state()
  totals.passes = totals.passes + 1
  totals.source_players = totals.source_players + source_players
  totals.source_radars = totals.source_radars + source_radars
  totals.chunks_examined = totals.chunks_examined + stats.chunks_examined
  totals.generated_chunks = totals.generated_chunks + stats.generated_chunks
  totals.chart_writes = totals.chart_writes + stats.chart_writes
  totals.last_tick = event and event.tick or game.tick

  return {
    source_players = source_players,
    source_radars = source_radars,
    chunks_examined = stats.chunks_examined,
    generated_chunks = stats.generated_chunks,
    chart_writes = stats.chart_writes
  }
end

-- Trusted mods can report a charted chunk because LuaForce.chart does not emit
-- on_chunk_charted in Factorio 2.1. The chunk must already exist and already be
-- charted by the registered source force; this call can therefore only copy a
-- real discovery, never create terrain or reveal an arbitrary generated area.
function Radars.share_chunk(force_name, surface_identifier, raw_position)
  local totals = state()
  totals.remote_requests = totals.remote_requests + 1
  local force = type(force_name) == "string" and game.forces[force_name] or nil
  local surface = (type(surface_identifier) == "string"
      or type(surface_identifier) == "number")
    and game.surfaces[surface_identifier] or nil
  local position = normalize_chunk_position(raw_position)

  if not (force and force.valid and Teams.get_by_force(force)
    and surface and surface.valid and position) then
    totals.remote_rejections = totals.remote_rejections + 1
    return {ok = false, error = "registered team, surface, and bounded integer chunk required"}
  end
  if not surface.is_chunk_generated(position) then
    totals.remote_rejections = totals.remote_rejections + 1
    return {ok = false, error = "chunk is not generated"}
  end
  if not force.is_chunk_charted(surface, position) then
    totals.remote_rejections = totals.remote_rejections + 1
    return {ok = false, error = "source team has not charted this chunk"}
  end

  local writes = chart_generated_chunk(surface, position, valid_team_forces())
  totals.generated_chunks = totals.generated_chunks + 1
  totals.chart_writes = totals.chart_writes + writes
  return {ok = true, queued = writes > 0 and 1 or 0, shared = writes}
end

function Radars.status()
  local totals = state()
  return {
    mode = "bounded-entity-scan",
    player_radius_tiles = PLAYER_RADIUS_TILES,
    radar_radius_tiles = RADAR_RADIUS_TILES,
    passes = totals.passes,
    source_players = totals.source_players,
    source_radars = totals.source_radars,
    chunks_examined = totals.chunks_examined,
    generated_chunks = totals.generated_chunks,
    chart_writes = totals.chart_writes,
    remote_requests = totals.remote_requests,
    remote_rejections = totals.remote_rejections,
    last_tick = totals.last_tick
  }
end

return Radars
