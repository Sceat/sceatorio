local State = require("src.core.state")

local AiEvents = {}

local CAPACITY = 512
local EVENT_SCHEMA_VERSION = 2

local function enabled()
  local setting = settings.global["sceatorio-ai-enabled"]
  return setting and setting.value or false
end

local function event_root()
  local state = State.get()
  state.ai = state.ai or {}
  if not state.ai.events or state.ai.events.schema_version ~= EVENT_SCHEMA_VERSION then
    -- Event cursors are ephemeral. Replacing the old shared ring prevents one
    -- force's event volume from evicting every other force's retained events.
    state.ai.events = {
      schema_version = EVENT_SCHEMA_VERSION,
      capacity = CAPACITY,
      by_force = {}
    }
  end
  state.ai.events.by_force = state.ai.events.by_force or {}
  return state.ai.events
end

local function force_event_root(force_index, create)
  if type(force_index) ~= "number" then return nil end
  local events = event_root()
  local ring = events.by_force[force_index]
  if not ring and create then
    ring = {
      capacity = CAPACITY,
      next_id = 1,
      slots = {}
    }
    events.by_force[force_index] = ring
  end
  return ring
end

local function plain_position(position)
  return position and {x = position.x, y = position.y} or nil
end

function AiEvents.record(event_type, source, details)
  if not enabled() then return end
  local force = source and source.force or nil
  local surface = source and source.surface or nil
  local player_index = source and source.player_index or nil
  local entity = source and (source.created_entity or source.entity or source.destination) or nil
  if entity and entity.valid then
    force = entity.force
    surface = entity.surface
  end
  local force_index = force and force.valid and force.index or nil
  local events = force_event_root(force_index, true)
  if not events then return end
  local id = events.next_id
  events.next_id = id + 1
  events.slots[((id - 1) % events.capacity) + 1] = {
    id = id,
    type = event_type,
    tick = game.tick,
    surface_index = surface and surface.valid and surface.index or nil,
    player_index = player_index,
    entity = entity and entity.valid and {
      entityId = entity.unit_number and ("entity:" .. entity.unit_number) or nil,
      name = entity.name,
      type = entity.type,
      position = plain_position(entity.position)
    } or nil,
    details = details
  }
end

local function parse_cursor(cursor, first_id, latest_id)
  if cursor == nil then return first_id - 1 end
  if type(cursor) ~= "string" then return nil, "INVALID_CURSOR", "Event cursor is invalid" end
  local id = tonumber(string.match(cursor, "^event:(%d+)$"))
  if not id or id > latest_id then return nil, "INVALID_CURSOR", "Event cursor is invalid" end
  if id < first_id - 1 then
    return nil, "CURSOR_EXPIRED", "Event cursor is older than the bounded event ring"
  end
  return id
end

local function type_filter(types)
  if types == nil then return nil end
  if type(types) ~= "table" or #types > 50 then
    return false, "INVALID_EVENT_TYPES", "Event types must contain at most 50 names"
  end
  local result = {}
  for _, name in ipairs(types) do
    if type(name) ~= "string" or #name < 1 or #name > 200 then
      return false, "INVALID_EVENT_TYPES", "Event type name is invalid"
    end
    result[name] = true
  end
  return result
end

local function visible(context, entry)
  if entry.surface_index ~= nil
    and not context.surface_ids_by_index[entry.surface_index] then return false end
  return true
end

local function public_details(context, entry)
  local details = entry.details
  if type(details) ~= "table" then return nil end
  if entry.type == "player.surface-changed" then
    local previous_surface_id = details.previous_surface_index
      and context.surface_ids_by_index[details.previous_surface_index] or nil
    return previous_surface_id and {previousSurfaceId = previous_surface_id} or nil
  end
  if entry.type == "research.started" or entry.type == "research.finished" then
    return type(details.technology) == "string" and {technology = details.technology} or nil
  end
  return nil
end

local function public_entry(context, entry)
  return {
    cursor = "event:" .. entry.id,
    type = entry.type,
    tick = entry.tick,
    surfaceId = entry.surface_index and context.surface_ids_by_index[entry.surface_index] or nil,
    playerId = entry.player_index and ("player:" .. entry.player_index) or nil,
    entity = entry.entity,
    details = public_details(context, entry)
  }
end

function AiEvents.list(context, payload)
  if type(payload) ~= "table" then return nil, "INVALID_REQUEST", "Event payload must be an object" end
  local events = force_event_root(context.force.index, false) or {
    capacity = CAPACITY,
    next_id = 1,
    slots = {}
  }
  local latest_id = events.next_id - 1
  local first_id = math.max(1, events.next_id - events.capacity)
  local cursor, code, message = parse_cursor(payload.cursor, first_id, latest_id)
  if cursor == nil then return nil, code, message, {firstCursor = "event:" .. (first_id - 1)} end
  local filter, filter_code, filter_message = type_filter(payload.types)
  if filter == false then return nil, filter_code, filter_message end
  local limit = payload.limit or 100
  if type(limit) ~= "number" or limit ~= math.floor(limit) or limit < 1 then
    return nil, "INVALID_PAGE_SIZE", "Event page size must be a positive integer"
  end
  limit = math.min(limit, context.max_page_size or 100, 200)
  local result = {}
  local examined = cursor
  for id = cursor + 1, latest_id do
    local entry = events.slots[((id - 1) % events.capacity) + 1]
    examined = id
    if entry and entry.id == id and visible(context, entry)
      and (not filter or filter[entry.type]) then
      result[#result + 1] = public_entry(context, entry)
      if #result >= limit then break end
    end
  end
  return {
    events = result,
    cursor = "event:" .. examined,
    hasMore = examined < latest_id,
    oldestCursor = "event:" .. (first_id - 1),
    latestCursor = "event:" .. latest_id
  }
end

function AiEvents.latest_cursor(context)
  local events = context and context.force
    and force_event_root(context.force.index, false) or nil
  return "event:" .. (events and events.next_id - 1 or 0)
end

function AiEvents.has_new_events(context, cursor)
  if type(cursor) ~= "string" then return true end
  local id = tonumber(string.match(cursor, "^event:(%d+)$"))
  if not id then return true end
  local events = context and context.force
    and force_event_root(context.force.index, false) or nil
  return id < (events and events.next_id - 1 or 0)
end

return AiEvents
