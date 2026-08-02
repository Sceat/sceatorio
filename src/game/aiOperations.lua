local Blueprints = require("src.game.aiBlueprints")
local AiControl = require("src.game.aiControl")
local AiEvents = require("src.game.aiEvents")
local Telemetry = require("src.game.aiTelemetry")

local Operations = {}

Operations.CAPABILITY_BY_OPERATION = {
  ["session.get"] = "session:read",
  ["statistics.production"] = "production:read",
  ["electric.network"] = "electricity:read",
  ["research.get"] = "research:read",
  ["prototype.recipe"] = "prototypes:read",
  ["prototype.get"] = "prototypes:read",
  ["prototype.transport-capacities"] = "prototypes:read",
  ["research.unlocked-technologies"] = "research:read",
  ["entity.query"] = "factory:read",
  ["entity.inspect"] = "factory:read",
  ["logistics.network"] = "logistics:read",
  ["train.list"] = "trains:read",
  ["alert.list"] = "alerts:read",
  ["map.charted-chunks"] = "map:read",
  ["circuit.port.read"] = "circuits:read",
  ["event.list"] = "events:read",
  ["event.wait"] = "events:read",
  ["blueprint.validate"] = "blueprints:validate",
  ["blueprint.analyze"] = "blueprints:validate",
  ["blueprint.save"] = "blueprints:write",
  ["blueprint.library.list"] = "blueprints:validate",
  ["blueprint.library.load"] = "blueprints:write",
  ["blueprint.library.delete"] = "blueprints:write",
  ["circuit.port.write"] = "control_ports:write",
  ["map.annotation.add"] = "annotations:write"
}

Operations.EXPENSIVE_OPERATION = {
  ["event.wait"] = true,
  ["statistics.production"] = true,
  ["electric.network"] = true,
  ["research.get"] = true,
  ["prototype.transport-capacities"] = true,
  ["research.unlocked-technologies"] = true,
  ["entity.query"] = true,
  ["logistics.network"] = true,
  ["train.list"] = true,
  ["alert.list"] = true,
  ["map.charted-chunks"] = true,
  ["blueprint.validate"] = true,
  ["blueprint.analyze"] = true,
  ["blueprint.save"] = true,
  ["circuit.port.write"] = true,
  ["map.annotation.add"] = true
}

local function sorted_copy(set)
  local values = {}
  for value, enabled in pairs(set or {}) do
    if enabled then values[#values + 1] = value end
  end
  table.sort(values)
  return values
end

local function session(context)
  local surfaces = {}
  for surface_id, grant in pairs(context.binding.surfaces or {}) do
    local surface = game.get_surface(grant.surface_index)
    surfaces[#surfaces + 1] = {
      surfaceId = surface_id,
      name = surface and surface.valid and surface.name or grant.surface_name,
      kind = grant.kind,
      visibility = "force-chart"
    }
  end
  table.sort(surfaces, function(first, second) return first.surfaceId < second.surfaceId end)
  local assistance = context.force.technologies["sceatorio-ai-assistance"]
  return {
    protocol = "sceatorio.factorio-gateway/1",
    saveId = context.binding.save_id,
    bindingId = context.binding.id,
    playerId = context.binding.player_id,
    playerName = context.player and context.player.valid and context.player.name or "headless-dev-player",
    forceId = context.binding.force_id,
    forceName = context.force.name,
    teamId = context.binding.team_id,
    capabilities = sorted_copy(context.binding.capabilities),
    surfaces = surfaces,
    technologies = {
      aiAssistance = assistance and assistance.researched or false
    },
    preferences = {
      enabled = true,
      blueprintDelivery = context.allow_cursor and "allow-cursor" or "inbox-only"
    },
    uplink = {
      entityId = context.uplink and context.uplink.valid
        and context.uplink.unit_number
        and ("entity:" .. context.uplink.unit_number) or nil,
      surfaceId = context.uplink and context.uplink.valid
        and ("surface:" .. context.uplink.surface.index) or nil,
      powered = true
    },
    budgets = {
      maxPageSize = context.max_page_size,
      requestsPerMinute = context.requests_per_minute,
      expensiveRequestsPerMinute = context.expensive_requests_per_minute,
      globalRequestsPerMinute = context.global_requests_per_minute,
      globalExpensiveRequestsPerMinute = context.global_expensive_requests_per_minute,
      requestsRemaining = context.requests_remaining,
      expensiveRequestsRemaining = context.expensive_requests_remaining,
      globalRequestsRemaining = context.global_requests_remaining,
      globalExpensiveRequestsRemaining = context.global_expensive_requests_remaining,
      maxDatagramBytes = 48 * 1024
    }
  }
end

local function placement(context, payload)
  if payload.placementOrigin == nil then return nil end
  if not context.surface then
    return false, "SURFACE_REQUIRED", "placement validation requires an authorized surface"
  end
  local origin = payload.placementOrigin
  if type(origin) ~= "table" or type(origin.x) ~= "number" or type(origin.y) ~= "number"
    or origin.x ~= origin.x or origin.y ~= origin.y then
    return false, "INVALID_PLACEMENT_ORIGIN", "placement origin must contain finite x and y values"
  end
  return {surface = context.surface, origin = {x = origin.x, y = origin.y}}
end

function Operations.execute(operation, context, payload)
  payload = payload or {}
  if operation == "session.get" then return session(context) end
  if operation == "statistics.production" then return Telemetry.production(context, payload) end
  if operation == "electric.network" then return Telemetry.electric_network(context, payload) end
  if operation == "research.get" then return Telemetry.research(context, payload) end
  if operation == "prototype.recipe" then return Telemetry.recipe(context, payload) end
  if operation == "prototype.get" then return Telemetry.prototype(context, payload) end
  if operation == "prototype.transport-capacities" then return Telemetry.transport_capacities(context, payload) end
  if operation == "research.unlocked-technologies" then return Telemetry.unlocked_technologies(context, payload) end
  if operation == "entity.query" then return Telemetry.query_entities(context, payload) end
  if operation == "entity.inspect" then return Telemetry.inspect_entity(context, payload) end
  if operation == "logistics.network" then return Telemetry.logistic_network(context, payload) end
  if operation == "train.list" then return Telemetry.trains(context, payload) end
  if operation == "alert.list" then return Telemetry.alerts(context, payload) end
  if operation == "map.charted-chunks" then return Telemetry.charted_chunks(context, payload) end
  if operation == "circuit.port.read" then return AiControl.read_port(context, payload) end
  if operation == "event.list" or operation == "event.wait" then return AiEvents.list(context, payload) end
  if operation == "blueprint.validate" then
    if type(payload) ~= "table" then return nil, "INVALID_REQUEST", "blueprint payload must be an object" end
    local check, code, message = placement(context, payload)
    if check == false then return nil, code, message end
    return Blueprints.validate(payload.layout, context, check)
  end
  if operation == "blueprint.analyze" then
    if type(payload) ~= "table" then return nil, "INVALID_REQUEST", "blueprint payload must be an object" end
    return Blueprints.validate(payload.layout, context)
  end
  if operation == "blueprint.save" then
    if type(payload) ~= "table" then return nil, "INVALID_REQUEST", "blueprint payload must be an object" end
    return Blueprints.save(payload.layout, context, payload.delivery or "inbox")
  end
  if operation == "blueprint.library.list" then
    if type(payload) ~= "table" then return nil, "INVALID_REQUEST", "blueprint payload must be an object" end
    return Blueprints.list(context, payload.query, payload.pagination)
  end
  if operation == "blueprint.library.load" then
    if type(payload) ~= "table" then return nil, "INVALID_REQUEST", "blueprint payload must be an object" end
    return Blueprints.load(
      context,
      payload.blueprintId,
      payload.revision,
      payload.delivery or "inbox"
    )
  end
  -- Deleting one own record is a single table mutation, so it stays on the
  -- cheap budget with its library neighbours (list and load); the expensive
  -- budget guards the calls that walk the map or rebuild an item.
  if operation == "blueprint.library.delete" then
    if type(payload) ~= "table" then return nil, "INVALID_REQUEST", "blueprint payload must be an object" end
    return Blueprints.delete(context, payload.blueprintId)
  end
  if operation == "circuit.port.write" then return AiControl.write_port(context, payload) end
  if operation == "map.annotation.add" then return AiControl.add_annotation(context, payload) end
  return nil, "OPERATION_NOT_SUPPORTED", "Operation is not implemented by this Sceatorio build"
end

return Operations
