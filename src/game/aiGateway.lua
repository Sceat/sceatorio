local State = require("src.core.state")
local AiConstants = require("src.core.aiConstants")
local Teams = require("src.game.teams")
local AiControl = require("src.game.aiControl")
local AiEvents = require("src.game.aiEvents")
local Operations = require("src.game.aiOperations")
local Telemetry = require("src.game.aiTelemetry")

local Gateway = {}

local PROTOCOL = AiConstants.PROTOCOL
local MAX_DATAGRAM_BYTES = AiConstants.MAX_DATAGRAM_BYTES
local TICKS_PER_MINUTE = 60 * 60
local GUI_NAME = "sceatorio_ai_uplink"
local PAIRING_CODE_LIFETIME_TICKS = 5 * 60 * 60
local MAX_PENDING_EVENT_WAITS = 256
local MAX_WAITS_PER_SLICE = 16
local WAIT_SLICE_TICKS = 6
local MAX_RETAINED_BINDINGS_PER_PLAYER = 16
local BINDING_RETENTION_TICKS = 10 * 60 * 60
local COMPLETED_REQUEST_TTL_TICKS = 10 * 60 * 60
local MAX_COMPLETED_REQUESTS_PER_PLAYER = 64
local MAX_COMPLETED_REQUEST_BYTES_PER_PLAYER = 512 * 1024
local PAIRING_REPLAY_TTL_TICKS = PAIRING_CODE_LIFETIME_TICKS
local MAX_PAIRING_REPLAYS = 64
local MAX_PAIRING_REPLAY_BYTES = 512 * 1024
local MAX_INGRESS_PACKETS = 64
local MAX_INGRESS_PACKETS_PER_TICK = 4
local PAIRING_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

local SUPPORTED_CAPABILITIES = AiConstants.CAPABILITY_SET
local pending_pairings = {}
local pairing_code_by_player = {}
local pending_event_waits = {}
local pending_event_wait_queue = {slots = {}, head = 1, tail = 0, count = 0}
local pending_event_wait_count = 0
local pairing_replays = {}
local pairing_replay_order = {}
local pairing_replay_bytes = 0

local function global_value(name, fallback)
  local setting = settings.global[name]
  return setting and setting.value or fallback
end

local function player_value(player, name, fallback)
  if not (player and player.valid) then return fallback end
  local values = settings.get_player_settings(player)
  local setting = values and values[name]
  return setting and setting.value or fallback
end

local function root()
  local state = State.get()
  state.ai = state.ai or {}
  local ai = state.ai
  ai.schema_version = 1
  ai.bindings = ai.bindings or {}
  ai.binding_ids_by_player = ai.binding_ids_by_player or {}
  ai.next_binding_id = ai.next_binding_id or 1
  ai.quota = ai.quota or {}
  ai.global_quota = ai.global_quota or {
    window_tick = -TICKS_PER_MINUTE,
    requests = 0,
    expensive = 0
  }
  ai.completed_requests_by_player = ai.completed_requests_by_player or {}
  ai.udp = ai.udp or {next_retry_tick = 0, failure_logged = false}
  ai.ingress = ai.ingress or {
    slots = {},
    head = 1,
    tail = 0,
    count = 0,
    dropped = 0
  }
  return ai
end

local function clear_ingress()
  local ingress = root().ingress
  ingress.slots = {}
  ingress.head = 1
  ingress.tail = 0
  ingress.count = 0
end

local function enqueue_ingress(event)
  local ingress = root().ingress
  if ingress.count >= MAX_INGRESS_PACKETS then
    ingress.dropped = (ingress.dropped or 0) + 1
    return false
  end
  ingress.tail = ingress.tail + 1
  ingress.slots[ingress.tail] = {
    source_port = event.source_port,
    payload = event.payload
  }
  ingress.count = ingress.count + 1
  return true
end

local function dequeue_ingress()
  local ingress = root().ingress
  if ingress.count <= 0 then return nil end
  local packet = ingress.slots[ingress.head]
  ingress.slots[ingress.head] = nil
  ingress.head = ingress.head + 1
  ingress.count = ingress.count - 1
  if ingress.count == 0 then
    ingress.slots = {}
    ingress.head = 1
    ingress.tail = 0
  end
  return packet
end

local function uuid(seed, salt)
  local generator = game.create_random_generator((seed + salt * 7919) % 4294967295)
  local function hex4() return string.format("%04x", generator(0, 65535)) end
  local first = hex4() .. hex4()
  local second = hex4()
  local third = "4" .. string.sub(hex4(), 2)
  local fourth = string.format("%04x", 32768 + generator(0, 16383))
  return first .. "-" .. second .. "-" .. third .. "-" .. fourth .. "-" .. hex4() .. hex4() .. hex4()
end

local function ensure_save_id()
  local ai = root()
  if ai.save_id then return ai.save_id end
  local seed = game.default_map_gen_settings.seed or 0
  ai.save_id = "save:" .. uuid(seed, 1)
  return ai.save_id
end

local function parse_capabilities(value)
  local result = {}
  if type(value) ~= "string" then return result end
  for token in string.gmatch(value, "[^,%s]+") do
    if SUPPORTED_CAPABILITIES[token] then result[token] = true end
  end
  return result
end

local function allowed_capabilities()
  return parse_capabilities(global_value(
    "sceatorio-ai-allowed-capabilities",
    AiConstants.DEFAULT_CAPABILITIES_CSV
  ))
end

local function requested_capabilities(player)
  return parse_capabilities(player_value(
    player,
    "sceatorio-ai-requested-capabilities",
    AiConstants.DEFAULT_CAPABILITIES_CSV
  ))
end

local function force_technology(force, name)
  local technology = force and force.valid and force.technologies[name] or nil
  return technology and technology.researched or false
end

local function effective_capabilities(force, player, dev_virtual)
  if not force_technology(force, AiConstants.TECHNOLOGY) then return {} end
  local allowed = allowed_capabilities()
  local requested = dev_virtual and SUPPORTED_CAPABILITIES or requested_capabilities(player)
  local capabilities = {}
  for capability in pairs(SUPPORTED_CAPABILITIES) do
    if allowed[capability] and requested[capability] then capabilities[capability] = true end
  end
  return capabilities
end

local function physical_player_surface(player)
  local character = player and player.valid and player.character or nil
  if character and character.valid then return character.surface end
  return nil
end

local function surface_kind(surface, primary_index)
  local ok, platform = pcall(function() return surface.platform end)
  if ok and platform then return "space-platform" end
  return surface.index == primary_index and "primary" or "team-secondary"
end

local function binding_surfaces(team, primary_surface, physical_surface)
  local surfaces = {}
  local function include(surface)
    if surface and surface.valid then
      local id = "surface:" .. surface.index
      surfaces[id] = {
        surface_index = surface.index,
        surface_name = surface.name,
        kind = surface_kind(surface, primary_surface.index)
      }
    end
  end
  include(primary_surface)
  include(physical_surface)
  if team and team.surfaces then
    for surface_index in pairs(team.surfaces) do include(game.get_surface(surface_index)) end
  end
  return surfaces
end

local function sorted_capabilities(capabilities)
  local values = {}
  for capability, enabled in pairs(capabilities or {}) do
    if enabled then values[#values + 1] = capability end
  end
  table.sort(values)
  return values
end

local function descriptor(binding)
  local surfaces = {}
  for surface_id, surface in pairs(binding.surfaces) do
    surfaces[#surfaces + 1] = {
      surfaceId = surface_id,
      forceId = binding.force_id,
      kind = surface.kind,
      visibility = "force-chart"
    }
  end
  table.sort(surfaces, function(first, second) return first.surfaceId < second.surfaceId end)
  return {
    protocol = PROTOCOL,
    bindingId = binding.id,
    saveId = binding.save_id,
    playerId = binding.player_id,
    forceId = binding.force_id,
    teamId = binding.team_id,
    capabilities = sorted_capabilities(binding.capabilities),
    surfaces = surfaces,
    preferences = {
      enabled = true,
      requestedCapabilities = sorted_capabilities(binding.capabilities),
      notifications = "important",
      blueprintDelivery = binding.allow_cursor and "allow-cursor" or "inbox-only"
    },
    issuedTick = binding.issued_tick,
    expiresTick = binding.expires_tick
  }
end

local function uplink_powered(entity, force)
  if not (entity and entity.valid and entity.name == AiConstants.UPLINK) then
    return false, "The paired AI Uplink no longer exists."
  end
  if entity.force.index ~= force.index then
    return false, "The paired AI Uplink belongs to another force."
  end
  local connected = entity.is_connected_to_electric_network()
  if not connected or entity.electric_network == nil or entity.energy <= 0 then
    return false, "The paired AI Uplink must be connected and receiving power."
  end
  return true
end

local function revoke_binding(binding, reason)
  if not binding or binding.revoked_tick then return end
  binding.revoked_tick = game.tick
  binding.revoked_reason = reason or "revoked"
end

local function revoke_player_bindings(player_index, reason)
  local ai = root()
  for _, id in ipairs(ai.binding_ids_by_player[player_index] or {}) do
    revoke_binding(ai.bindings[id], reason)
  end
end

local function create_binding_record(options)
  local ai = root()
  local seed = game.default_map_gen_settings.seed or 0
  local sequence = ai.next_binding_id
  ai.next_binding_id = sequence + 1
  local lifetime_hours = math.max(1, math.min(720, global_value("sceatorio-ai-binding-lifetime-hours", 24)))
  local binding = {
    id = "binding:" .. uuid(seed, sequence + 1000),
    save_id = ensure_save_id(),
    player_index = options.player_index,
    player_id = options.player_id,
    force_index = options.force.index,
    force_name = options.force.name,
    force_id = "force:" .. options.force.index,
    team_id = options.team_id,
    surfaces = options.surfaces,
    capabilities = options.capabilities,
    uplink_unit_number = options.uplink.unit_number,
    uplink_entity = options.uplink,
    issued_tick = game.tick,
    expires_tick = game.tick + math.floor(lifetime_hours * 60 * 60 * 60),
    allow_cursor = options.allow_cursor,
    dev_virtual = options.dev_virtual or false
  }
  ai.bindings[binding.id] = binding
  ai.binding_ids_by_player[binding.player_index] = ai.binding_ids_by_player[binding.player_index] or {}
  ai.binding_ids_by_player[binding.player_index][#ai.binding_ids_by_player[binding.player_index] + 1] = binding.id
  Telemetry.index_entity(options.uplink)
  return binding
end

local function player_pairing_options(player, uplink)
  if not global_value("sceatorio-ai-enabled", false) then
    return nil, "AI assistance is disabled by server policy."
  end
  if not player_value(player, "sceatorio-ai-assistance-enabled", false) then
    return nil, "Enable Sceatorio AI assistance in your per-player mod settings first."
  end
  local team = Teams.get_for_player(player)
  if not team then return nil, "Join or create a Sceatorio team before pairing an Uplink." end
  if not force_technology(player.force, AiConstants.TECHNOLOGY) then
    return nil, "Your force has not researched AI Assistance."
  end
  local powered, reason = uplink_powered(uplink, player.force)
  if not powered then return nil, reason end
  local capabilities = effective_capabilities(player.force, player, false)
  if not next(capabilities) then return nil, "No AI capabilities are enabled by both server and player policy." end
  return {
    player_index = player.index,
    player_id = "player:" .. player.index,
    force = player.force,
    team_id = "team:" .. team.id,
    surfaces = binding_surfaces(team, uplink.surface, physical_player_surface(player)),
    capabilities = capabilities,
    uplink = uplink,
    allow_cursor = player_value(player, "sceatorio-ai-blueprint-cursor-delivery", false)
  }
end

local function remove_pairing_code(code)
  local pending = pending_pairings[code]
  if not pending then return nil end
  pending_pairings[code] = nil
  if pairing_code_by_player[pending.player_key] == code then
    pairing_code_by_player[pending.player_key] = nil
  end
  return pending
end

local function remove_player_pairing_code(player_index)
  local code = pairing_code_by_player[tostring(player_index)]
  if code then remove_pairing_code(code) end
end

local function random_pairing_code(player_key)
  local seed = game.default_map_gen_settings.seed or 0
  local salt = game.tick * 131 + root().next_binding_id * 8191 + (tonumber(player_key) or 0) * 104729
  local generator = game.create_random_generator((seed + salt) % 4294967295)
  for _ = 1, 16 do
    local characters = {}
    for index = 1, 15 do
      if index == 6 or index == 11 then
        characters[#characters + 1] = "-"
      else
        local offset = generator(1, #PAIRING_ALPHABET)
        characters[#characters + 1] = string.sub(PAIRING_ALPHABET, offset, offset)
      end
    end
    local code = table.concat(characters)
    if not pending_pairings[code] then return code end
  end
  return nil
end

local function create_pairing_code(options)
  local player_key = tostring(options.player_index)
  local old_code = pairing_code_by_player[player_key]
  if old_code then remove_pairing_code(old_code) end
  local code = random_pairing_code(player_key)
  if not code then return nil, "Could not allocate a pairing code; try again next tick." end
  local pending = {
    code = code,
    player_key = player_key,
    player_index = options.player_index,
    player_id = options.player_id,
    force_index = options.force.index,
    force_name = options.force.name,
    team_id = options.team_id,
    primary_surface_index = options.primary_surface_index
      or (options.uplink and options.uplink.valid and options.uplink.surface.index),
    uplink = options.uplink,
    uplink_unit_number = options.uplink.unit_number,
    created_tick = game.tick,
    expires_tick = game.tick + PAIRING_CODE_LIFETIME_TICKS,
    dev_virtual = options.dev_virtual or false
  }
  pending_pairings[code] = pending
  pairing_code_by_player[player_key] = code
  return pending
end

function Gateway.create_player_pairing_code(player, uplink)
  local options, reason = player_pairing_options(player, uplink)
  if not options then return nil, reason end
  return create_pairing_code(options)
end

local function valid_uuid(value)
  return type(value) == "string" and string.match(
    value,
    "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
  ) ~= nil
end

local function valid_scope(scope)
  return type(scope) == "table"
    and type(scope.bindingId) == "string" and #scope.bindingId >= 16 and #scope.bindingId <= 256
    and type(scope.saveId) == "string" and #scope.saveId >= 1 and #scope.saveId <= 256
    and type(scope.playerId) == "string" and #scope.playerId >= 1 and #scope.playerId <= 256
    and type(scope.forceId) == "string" and #scope.forceId >= 1 and #scope.forceId <= 128
    and (scope.surfaceId == nil or (type(scope.surfaceId) == "string" and #scope.surfaceId >= 1 and #scope.surfaceId <= 128))
end

local function validate_request(request)
  if type(request) ~= "table" then return nil, "INVALID_REQUEST", "Gateway request must be a JSON object" end
  if request.protocol ~= PROTOCOL or request.kind ~= "request" then
    return nil, "PROTOCOL_MISMATCH", "Gateway protocol or message kind is invalid"
  end
  if not valid_uuid(request.id) then return nil, "INVALID_REQUEST_ID", "Request ID must be a UUID" end
  if type(request.operation) ~= "string" or #request.operation < 1 or #request.operation > 96
    or not string.match(request.operation, "^[a-z][a-z0-9_.%-]*$") then
    return nil, "INVALID_OPERATION", "Operation name is invalid"
  end
  if not valid_scope(request.scope) then return nil, "INVALID_SCOPE", "Gateway scope is invalid" end
  if type(request.payload) ~= "table" then return nil, "INVALID_PAYLOAD", "Gateway payload must be a JSON object" end
  if not Operations.CAPABILITY_BY_OPERATION[request.operation] then
    return nil, "OPERATION_NOT_SUPPORTED", "Operation is not implemented by this Sceatorio build"
  end
  return true
end

local function force_for_binding(binding)
  local force = game.forces[binding.force_index]
  if force and force.valid and force.name == binding.force_name then return force end
  return nil
end

local function binding_uplink(binding)
  local entity = binding.uplink_entity
  if entity and entity.valid then return entity end
  entity = game.get_entity_by_unit_number(binding.uplink_unit_number)
  if entity and entity.valid then
    binding.uplink_entity = entity
    Telemetry.index_entity(entity)
    return entity
  end
  return nil
end

local function selected_surface(binding, request, player, uplink)
  local surface_id = request.scope.surfaceId
  if surface_id then
    local grant = binding.surfaces[surface_id]
    if not grant then return nil, nil, "SURFACE_SCOPE_MISMATCH", "Requested surface is outside this binding" end
    local surface = game.get_surface(grant.surface_index)
    if not (surface and surface.valid and surface.name == grant.surface_name) then
      return nil, nil, "SURFACE_NOT_FOUND", "Authorized surface no longer exists"
    end
    return surface, surface_id
  end
  if request.payload.surfaceId ~= nil then
    return nil, nil, "SURFACE_SCOPE_MISMATCH", "Payload surface must match the scoped surface"
  end
  if request.operation == "statistics.production" then
    local candidate = physical_player_surface(player)
    if candidate then
      local candidate_id = "surface:" .. candidate.index
      if binding.surfaces[candidate_id] then return candidate, candidate_id end
    end
    candidate = uplink.surface
    local candidate_id = "surface:" .. candidate.index
    if binding.surfaces[candidate_id] then return candidate, candidate_id end
  end
  return nil, nil
end

local function consume_quota(binding, expensive)
  local ai = root()
  local window = game.tick - (game.tick % TICKS_PER_MINUTE)
  local quota = ai.quota[binding.player_id]
  if not quota or quota.window_tick ~= window then
    quota = {window_tick = window, requests = 0, expensive = 0}
    ai.quota[binding.player_id] = quota
  end
  local global_quota = ai.global_quota
  if not global_quota or global_quota.window_tick ~= window then
    global_quota = {window_tick = window, requests = 0, expensive = 0}
    ai.global_quota = global_quota
  end
  global_quota.expensive = global_quota.expensive or 0
  local request_limit = math.max(1, math.min(3600, global_value("sceatorio-ai-requests-per-minute", 120)))
  local expensive_limit = math.max(1, math.min(600, global_value("sceatorio-ai-expensive-requests-per-minute", 20)))
  local global_limit = math.max(
    1,
    math.min(36000, global_value("sceatorio-ai-global-requests-per-minute", 600))
  )
  local global_expensive_limit = math.max(
    1,
    math.min(36000, global_value("sceatorio-ai-global-expensive-requests-per-minute", 120))
  )
  if quota.requests >= request_limit then
    return nil, "RATE_LIMITED", "Per-player request quota is exhausted for this game minute"
  end
  if expensive and quota.expensive >= expensive_limit then
    return nil, "EXPENSIVE_RATE_LIMITED", "Per-player expensive request quota is exhausted for this game minute"
  end
  if global_quota.requests >= global_limit then
    return nil, "GLOBAL_RATE_LIMITED", "Save-wide request quota is exhausted for this game minute"
  end
  if expensive and global_quota.expensive >= global_expensive_limit then
    return nil,
      "GLOBAL_EXPENSIVE_RATE_LIMITED",
      "Save-wide expensive request quota is exhausted for this game minute"
  end
  quota.requests = quota.requests + 1
  if expensive then quota.expensive = quota.expensive + 1 end
  global_quota.requests = global_quota.requests + 1
  if expensive then global_quota.expensive = global_quota.expensive + 1 end
  return {
    request_limit = request_limit,
    expensive_limit = expensive_limit,
    global_limit = global_limit,
    global_expensive_limit = global_expensive_limit,
    requests_remaining = request_limit - quota.requests,
    expensive_remaining = expensive_limit - quota.expensive,
    global_remaining = global_limit - global_quota.requests,
    global_expensive_remaining = global_expensive_limit - global_quota.expensive
  }
end

local function authorize(request)
  if not global_value("sceatorio-ai-enabled", false) then
    return nil, "AI_DISABLED", "AI assistance is disabled by server policy"
  end
  local binding = root().bindings[request.scope.bindingId]
  if not binding then return nil, "BINDING_NOT_FOUND", "Pairing does not exist in this save" end
  if binding.revoked_tick then return nil, "TOKEN_REVOKED", "Pairing has been revoked" end
  if binding.expires_tick <= game.tick then return nil, "TOKEN_EXPIRED", "Pairing has expired" end
  if request.scope.saveId ~= ensure_save_id() or request.scope.saveId ~= binding.save_id then
    return nil, "SAVE_SCOPE_MISMATCH", "Request targets another save"
  end
  if request.scope.playerId ~= binding.player_id then
    return nil, "PLAYER_SCOPE_MISMATCH", "Request targets another player"
  end
  if request.scope.forceId ~= binding.force_id then
    return nil, "FORCE_SCOPE_MISMATCH", "Request targets another force"
  end
  local force = force_for_binding(binding)
  if not force then return nil, "FORCE_NOT_FOUND", "Paired force no longer exists" end
  local player = binding.player_index > 0 and game.get_player(binding.player_index) or nil
  if binding.dev_virtual then
    if not global_value("sceatorio-dev-tools-enabled", false) then
      return nil, "PLAYER_NOT_OPTED_IN", "Headless development pairing is disabled"
    end
  else
    if not (player and player.valid) or player.force.index ~= force.index then
      return nil, "PLAYER_SCOPE_MISMATCH", "Paired player is missing or belongs to another force"
    end
    if not player_value(player, "sceatorio-ai-assistance-enabled", false) then
      return nil, "PLAYER_NOT_OPTED_IN", "Paired player disabled AI assistance"
    end
  end
  if not force_technology(force, AiConstants.TECHNOLOGY) then
    return nil, "TECHNOLOGY_REQUIRED", "Force has not researched AI Assistance"
  end
  local capability = Operations.CAPABILITY_BY_OPERATION[request.operation]
  local current_capabilities = effective_capabilities(force, player, binding.dev_virtual)
  if not binding.capabilities[capability] or not current_capabilities[capability] then
    return nil, "INSUFFICIENT_CAPABILITY", "Pairing does not allow " .. capability
  end
  local uplink = binding_uplink(binding)
  local powered, power_reason = uplink_powered(uplink, force)
  if not powered then return nil, "UPLINK_UNPOWERED", power_reason end
  if request.scope.surfaceId ~= nil and request.payload.surfaceId ~= request.scope.surfaceId then
    return nil, "SURFACE_SCOPE_MISMATCH", "Payload surface does not match gateway scope"
  end
  local surface, surface_id, surface_code, surface_message = selected_surface(binding, request, player, uplink)
  if surface_code then return nil, surface_code, surface_message end
  local surface_ids_by_index = {}
  for id, grant in pairs(binding.surfaces) do surface_ids_by_index[grant.surface_index] = id end
  return {
    binding = binding,
    player = player,
    player_index = binding.player_index,
    force = force,
    uplink = uplink,
    surface = surface,
    surface_id = surface_id,
    surface_ids_by_index = surface_ids_by_index,
    allow_cursor = not binding.dev_virtual
      and binding.allow_cursor
      and player_value(player, "sceatorio-ai-blueprint-cursor-delivery", false),
    max_page_size = math.max(1, math.min(200, global_value("sceatorio-ai-max-page-size", 100)))
  }
end

local function attach_quota(context, request)
  local quota, code, message = consume_quota(
    context.binding,
    Operations.EXPENSIVE_OPERATION[request.operation] == true
  )
  if not quota then return nil, code, message end
  context.requests_per_minute = quota.request_limit
  context.expensive_requests_per_minute = quota.expensive_limit
  context.global_requests_per_minute = quota.global_limit
  context.global_expensive_requests_per_minute = quota.global_expensive_limit
  context.requests_remaining = quota.requests_remaining
  context.expensive_requests_remaining = quota.expensive_remaining
  context.global_requests_remaining = quota.global_remaining
  context.global_expensive_requests_remaining = quota.global_expensive_remaining
  return context
end

local function response(id, ok, result, error)
  return {
    protocol = PROTOCOL,
    kind = "response",
    id = id,
    ok = ok,
    tick = game.tick,
    worldRevision = game.tick,
    result = result,
    error = error
  }
end

local function public_error(code, message, retryable, details)
  return {code = code, message = message, retryable = retryable or false, details = details}
end

local function encode_response(value)
  local ok, encoded = pcall(helpers.table_to_json, value)
  if not ok then return nil, tostring(encoded) end
  return encoded
end

local function send_encoded(port, encoded)
  local ok, reason = pcall(function() helpers.send_udp(port, encoded, 0) end)
  if not ok then log("[Sceatorio] AI UDP response failed: " .. tostring(reason)) end
end

local function completed_request_key(binding, request_id)
  return binding.id .. "\n" .. request_id
end

local function remove_completed_request(bucket, key)
  local entry = bucket.entries[key]
  if not entry then return end
  bucket.entries[key] = nil
  bucket.count = math.max(0, (bucket.count or 1) - 1)
  bucket.bytes = math.max(0, (bucket.bytes or entry.bytes) - entry.bytes)
end

local function trim_completed_requests(bucket, reserve_count, reserve_bytes)
  bucket.entries = bucket.entries or {}
  bucket.order = bucket.order or {}
  bucket.count = bucket.count or 0
  bucket.bytes = bucket.bytes or 0
  while #bucket.order > 0 do
    local key = bucket.order[1]
    local entry = bucket.entries[key]
    local expired = entry and entry.completed_tick + COMPLETED_REQUEST_TTL_TICKS <= game.tick
    local over_budget = bucket.count + reserve_count > MAX_COMPLETED_REQUESTS_PER_PLAYER
      or bucket.bytes + reserve_bytes > MAX_COMPLETED_REQUEST_BYTES_PER_PLAYER
    if entry and not expired and not over_budget then break end
    table.remove(bucket.order, 1)
    if entry then remove_completed_request(bucket, key) end
  end
end

local function completed_request_replay(binding, request_id, request_bytes)
  local bucket = root().completed_requests_by_player[binding.player_id]
  if not bucket then return nil end
  trim_completed_requests(bucket, 0, 0)
  local entry = bucket.entries[completed_request_key(binding, request_id)]
  if not entry then return nil end
  if request_bytes == entry.request_bytes then return entry.response_bytes end
  return false
end

local function cache_completed_request(binding, request_id, request_bytes, response_bytes)
  local bytes = #request_bytes + #response_bytes
  if bytes > MAX_COMPLETED_REQUEST_BYTES_PER_PLAYER then return end
  local ai = root()
  local bucket = ai.completed_requests_by_player[binding.player_id]
  if not bucket then
    bucket = {entries = {}, order = {}, count = 0, bytes = 0}
    ai.completed_requests_by_player[binding.player_id] = bucket
  end
  local key = completed_request_key(binding, request_id)
  if bucket.entries[key] then return end
  trim_completed_requests(bucket, 1, bytes)
  if bucket.count + 1 > MAX_COMPLETED_REQUESTS_PER_PLAYER
    or bucket.bytes + bytes > MAX_COMPLETED_REQUEST_BYTES_PER_PLAYER then return end
  bucket.entries[key] = {
    request_bytes = request_bytes,
    response_bytes = response_bytes,
    completed_tick = game.tick,
    bytes = bytes
  }
  bucket.order[#bucket.order + 1] = key
  bucket.count = bucket.count + 1
  bucket.bytes = bucket.bytes + bytes
end

local function remove_pairing_replay(request_id)
  local replay = pairing_replays[request_id]
  if not replay then return end
  pairing_replays[request_id] = nil
  pairing_replay_bytes = math.max(0, pairing_replay_bytes - replay.bytes)
end

local function trim_pairing_replays(reserve_count, reserve_bytes)
  while #pairing_replay_order > 0 do
    local request_id = pairing_replay_order[1]
    local replay = pairing_replays[request_id]
    local expired = replay and replay.completed_tick + PAIRING_REPLAY_TTL_TICKS <= game.tick
    local over_budget = #pairing_replay_order + reserve_count > MAX_PAIRING_REPLAYS
      or pairing_replay_bytes + reserve_bytes > MAX_PAIRING_REPLAY_BYTES
    if replay and not expired and not over_budget then break end
    table.remove(pairing_replay_order, 1)
    if replay then remove_pairing_replay(request_id) end
  end
end

local function pairing_replay(request_id, request_bytes)
  trim_pairing_replays(0, 0)
  local replay = pairing_replays[request_id]
  if not replay then return nil end
  if request_bytes == replay.request_bytes then return replay.response_bytes end
  return false
end

local function cache_pairing_replay(request_id, request_bytes, response_bytes)
  local bytes = #request_bytes + #response_bytes
  if bytes > MAX_PAIRING_REPLAY_BYTES or pairing_replays[request_id] then return end
  trim_pairing_replays(1, bytes)
  if #pairing_replay_order + 1 > MAX_PAIRING_REPLAYS
    or pairing_replay_bytes + bytes > MAX_PAIRING_REPLAY_BYTES then return end
  pairing_replays[request_id] = {
    request_bytes = request_bytes,
    response_bytes = response_bytes,
    completed_tick = game.tick,
    bytes = bytes
  }
  pairing_replay_order[#pairing_replay_order + 1] = request_id
  pairing_replay_bytes = pairing_replay_bytes + bytes
end

local function clear_pairing_replays()
  pairing_replays = {}
  pairing_replay_order = {}
  pairing_replay_bytes = 0
end

local function send_error(port, id, code, message, retryable, details)
  if not valid_uuid(id) then return end
  local value = response(id, false, nil, public_error(code, message, retryable, details))
  local encoded, reason = encode_response(value)
  if not encoded then
    log("[Sceatorio] AI error response was not JSON-safe: " .. tostring(reason))
    return
  end
  if #encoded <= MAX_DATAGRAM_BYTES then
    send_encoded(port, encoded)
    return encoded
  end
end

local function pairing_response(id, ok, paired_descriptor, error)
  return {
    protocol = PROTOCOL,
    kind = "pairing.response",
    id = id,
    ok = ok,
    tick = game.tick,
    descriptor = paired_descriptor,
    error = error
  }
end

local function send_pairing_response(port, id, ok, paired_descriptor, code, message)
  if not valid_uuid(id) then return end
  local pairing_error
  if not ok then
    pairing_error = public_error(code or "PAIRING_FAILED", message or "Pairing failed")
  end
  local value = pairing_response(
    id,
    ok,
    paired_descriptor,
    pairing_error
  )
  local encoded, reason = encode_response(value)
  if not encoded then
    log("[Sceatorio] AI pairing response was not JSON-safe: " .. tostring(reason))
    return
  end
  if #encoded <= MAX_DATAGRAM_BYTES then
    send_encoded(port, encoded)
    return encoded
  end
end

local function complete_pairing_response(port, request, request_bytes, ok, paired_descriptor, code, message)
  local encoded = send_pairing_response(port, request.id, ok, paired_descriptor, code, message)
  if encoded and type(request_bytes) == "string" then
    cache_pairing_replay(request.id, request_bytes, encoded)
  end
end

local function valid_pairing_code(code)
  if type(code) ~= "string" or #code ~= 15
    or string.sub(code, 6, 6) ~= "-" or string.sub(code, 11, 11) ~= "-" then return false end
  for index = 1, #code do
    if index ~= 6 and index ~= 11 then
      local character = string.sub(code, index, index)
      if not string.find(PAIRING_ALPHABET, character, 1, true) then return false end
    end
  end
  return true
end

local function resolve_pending_uplink(pending)
  local uplink = pending.uplink
  if uplink and uplink.valid then return uplink end
  uplink = game.get_entity_by_unit_number(pending.uplink_unit_number)
  if uplink and uplink.valid then return uplink end
  return nil
end

local function materialize_pending_pairing(pending)
  if not global_value("sceatorio-ai-enabled", false) then
    return nil, "AI_DISABLED", "AI assistance is disabled by server policy"
  end
  local force = game.forces[pending.force_index]
  if not (force and force.valid and force.name == pending.force_name) then
    return nil, "FORCE_NOT_FOUND", "The pairing force no longer exists"
  end
  local uplink = resolve_pending_uplink(pending)
  local powered, power_reason = uplink_powered(uplink, force)
  if not powered then return nil, "UPLINK_UNPOWERED", power_reason end
  if pending.dev_virtual then
    if not global_value("sceatorio-dev-tools-enabled", false) then
      return nil, "PLAYER_NOT_OPTED_IN", "Headless development pairing is disabled"
    end
    if not force_technology(force, AiConstants.TECHNOLOGY) then
      return nil, "TECHNOLOGY_REQUIRED", "Force has not researched AI Assistance"
    end
    local surface = game.get_surface(pending.primary_surface_index) or uplink.surface
    local capabilities = effective_capabilities(force, nil, true)
    if not next(capabilities) then
      return nil, "INSUFFICIENT_CAPABILITY", "No AI capabilities are enabled by server policy"
    end
    return {
      player_index = pending.player_index,
      player_id = pending.player_id,
      force = force,
      team_id = pending.team_id,
      surfaces = binding_surfaces(nil, surface, nil),
      capabilities = capabilities,
      uplink = uplink,
      allow_cursor = false,
      dev_virtual = true
    }
  end
  local player = game.get_player(pending.player_index)
  if not (player and player.valid and player.force.index == force.index) then
    return nil, "PLAYER_SCOPE_MISMATCH", "The pairing player is missing or changed force"
  end
  local options, reason = player_pairing_options(player, uplink)
  if not options then return nil, "PAIRING_REQUIREMENTS_CHANGED", reason end
  if options.player_id ~= pending.player_id or options.team_id ~= pending.team_id then
    return nil, "PAIRING_REQUIREMENTS_CHANGED", "The player's team changed after the code was created"
  end
  options.primary_surface_index = uplink.surface.index
  options.surfaces = binding_surfaces(
    Teams.get_for_player(player),
    uplink.surface,
    physical_player_surface(player)
  )
  return options
end

local function handle_pairing_exchange(port, request, request_bytes)
  if valid_uuid(request.id) then
    local replay = pairing_replay(request.id, request_bytes)
    if replay == false then
      send_pairing_response(
        port,
        request.id,
        false,
        nil,
        "DUPLICATE_REQUEST_ID",
        "Pairing request ID was already used with a different request"
      )
      return
    elseif replay then
      send_encoded(port, replay)
      return
    end
  end
  if request.protocol ~= PROTOCOL or request.kind ~= "pairing.exchange"
    or not valid_uuid(request.id) or not valid_pairing_code(request.code) then
    complete_pairing_response(
      port,
      request,
      request_bytes,
      false,
      nil,
      "INVALID_PAIRING_REQUEST",
      "Pairing request is invalid"
    )
    return
  end
  local pending = remove_pairing_code(request.code)
  if not pending then
    complete_pairing_response(
      port,
      request,
      request_bytes,
      false,
      nil,
      "PAIRING_CODE_INVALID",
      "Pairing code is invalid or already consumed"
    )
    return
  end
  if pending.expires_tick <= game.tick then
    complete_pairing_response(
      port,
      request,
      request_bytes,
      false,
      nil,
      "PAIRING_CODE_EXPIRED",
      "Pairing code expired"
    )
    return
  end
  local options, code, message = materialize_pending_pairing(pending)
  if not options then
    complete_pairing_response(port, request, request_bytes, false, nil, code, message)
    return
  end
  revoke_player_bindings(options.player_index, "re-paired")
  local binding = create_binding_record(options)
  complete_pairing_response(port, request, request_bytes, true, descriptor(binding))
end

local function send_success(port, id, result)
  local value = response(id, true, result)
  local encoded, encode_reason = encode_response(value)
  if not encoded then
    log("[Sceatorio] AI operation returned non-JSON data: " .. tostring(encode_reason))
    return send_error(port, id, "NON_SERIALIZABLE_RESULT", "Operation result was not JSON-safe")
  end
  if #encoded > MAX_DATAGRAM_BYTES then
    return send_error(port, id, "RESPONSE_TOO_LARGE", "Use a smaller page size or narrower query")
  end
  send_encoded(port, encoded)
  return encoded
end

local function pending_wait_count()
  return pending_event_wait_count
end

local function enqueue_event_wait(id)
  local queue = pending_event_wait_queue
  queue.tail = (queue.tail % MAX_PENDING_EVENT_WAITS) + 1
  queue.slots[queue.tail] = id
  queue.count = queue.count + 1
end

local function dequeue_event_wait()
  local queue = pending_event_wait_queue
  if queue.count == 0 then return nil end
  local id = queue.slots[queue.head]
  queue.slots[queue.head] = nil
  queue.head = (queue.head % MAX_PENDING_EVENT_WAITS) + 1
  queue.count = queue.count - 1
  return id
end

local function remove_pending_event_wait(id)
  if not pending_event_waits[id] then return end
  pending_event_waits[id] = nil
  pending_event_wait_count = math.max(0, pending_event_wait_count - 1)
end

local function complete_request_error(port, context, request_id, request_bytes, code, message, retryable, details)
  local encoded = send_error(port, request_id, code, message, retryable, details)
  if encoded then cache_completed_request(context.binding, request_id, request_bytes, encoded) end
end

local function complete_request_success(port, context, request_id, request_bytes, result)
  local encoded = send_success(port, request_id, result)
  if encoded then cache_completed_request(context.binding, request_id, request_bytes, encoded) end
end

local function register_event_wait(port, request, request_bytes, context, initial_result)
  local timeout_ms = request.payload.timeoutMs or 10000
  if type(timeout_ms) ~= "number" or timeout_ms ~= math.floor(timeout_ms)
    or timeout_ms < 100 or timeout_ms > 25000 then
    return nil, "INVALID_WAIT_TIMEOUT", "Event wait timeout must be 100 through 25000 milliseconds"
  end
  if pending_event_waits[request.id] then
    return nil, "DUPLICATE_REQUEST_ID", "An event wait with this request ID is already pending"
  end
  if pending_wait_count() >= MAX_PENDING_EVENT_WAITS then
    return nil, "WAIT_BUDGET_EXCEEDED", "The bounded event-wait queue is full"
  end
  request.payload.cursor = initial_result.cursor
  pending_event_waits[request.id] = {
    port = port,
    id = request.id,
    context = context,
    request_bytes = request_bytes,
    payload = request.payload,
    deadline_tick = game.tick + math.max(1, math.ceil(timeout_ms * 60 / 1000))
  }
  pending_event_wait_count = pending_event_wait_count + 1
  enqueue_event_wait(request.id)
  return true
end

local function execute_request(port, request, request_bytes)
  local valid, code, message = validate_request(request)
  if not valid then send_error(port, request and request.id, code, message) return end
  if type(request_bytes) ~= "string" then
    request_bytes = encode_response(request)
    if not request_bytes then send_error(port, request.id, "INVALID_REQUEST", "Request was not JSON-safe") return end
  end
  local context, auth_code, auth_message = authorize(request)
  if not context then send_error(port, request.id, auth_code, auth_message) return end
  local replay = completed_request_replay(context.binding, request.id, request_bytes)
  if replay == false then
    send_error(
      port,
      request.id,
      "DUPLICATE_REQUEST_ID",
      "Request ID was already used with a different request"
    )
    return
  elseif replay then
    send_encoded(port, replay)
    return
  end
  local pending = pending_event_waits[request.id]
  if pending then
    if pending.context.binding.id == context.binding.id
      and request_bytes == pending.request_bytes then return end
    send_error(
      port,
      request.id,
      "DUPLICATE_REQUEST_ID",
      "Request ID is already pending with a different request"
    )
    return
  end
  local quota_context, quota_code, quota_message = attach_quota(context, request)
  if not quota_context then
    complete_request_error(
      port,
      context,
      request.id,
      request_bytes,
      quota_code,
      quota_message
    )
    return
  end
  context = quota_context
  local ok, result, operation_code, operation_message, details = pcall(
    Operations.execute,
    request.operation,
    context,
    request.payload
  )
  if not ok then
    log("[Sceatorio] AI operation " .. request.operation .. " failed: " .. tostring(result))
    complete_request_error(
      port,
      context,
      request.id,
      request_bytes,
      "INTERNAL_ERROR",
      "Factorio could not complete this operation"
    )
    return
  end
  if result == nil then
    complete_request_error(
      port,
      context,
      request.id,
      request_bytes,
      operation_code or "FACTORIO_ERROR",
      operation_message or "Operation failed",
      false,
      details
    )
    return
  end
  if request.operation == "event.wait" and #(result.events or {}) == 0 then
    local registered, wait_code, wait_message = register_event_wait(
      port,
      request,
      request_bytes,
      context,
      result
    )
    if not registered then
      complete_request_error(port, context, request.id, request_bytes, wait_code, wait_message)
    end
    return
  end
  complete_request_success(port, context, request.id, request_bytes, result)
end

local function wait_context_valid(context)
  local binding = context.binding
  if not global_value("sceatorio-ai-enabled", false) then return false end
  if binding.revoked_tick or binding.expires_tick <= game.tick then return false end
  local force = force_for_binding(binding)
  if not force or not force_technology(force, AiConstants.TECHNOLOGY) then return false end
  local current_capabilities = effective_capabilities(force, context.player, binding.dev_virtual)
  if not binding.capabilities["events:read"] or not current_capabilities["events:read"] then
    return false
  end
  if not binding.dev_virtual then
    local player = game.get_player(binding.player_index)
    if not (player and player.valid and player.force.index == force.index)
      or not player_value(player, "sceatorio-ai-assistance-enabled", false) then return false end
  elseif not global_value("sceatorio-dev-tools-enabled", false) then
    return false
  end
  local powered = uplink_powered(binding_uplink(binding), force)
  return powered == true
end

local function process_event_waits()
  if game.tick % WAIT_SLICE_TICKS ~= 0 then return end
  local scheduled = math.min(MAX_WAITS_PER_SLICE, pending_event_wait_queue.count)
  for _ = 1, MAX_WAITS_PER_SLICE do
    if scheduled <= 0 then break end
    scheduled = scheduled - 1
    local id = dequeue_event_wait()
    local pending = id and pending_event_waits[id] or nil
    if pending then
      if not wait_context_valid(pending.context) then
        remove_pending_event_wait(id)
        complete_request_error(
          pending.port,
          pending.context,
          id,
          pending.request_bytes,
          "WAIT_CANCELLED",
          "Pairing became unavailable while waiting"
        )
      elseif game.tick >= pending.deadline_tick
        or AiEvents.has_new_events(pending.context, pending.payload.cursor) then
        local ok, result, code, message, details = pcall(AiEvents.list, pending.context, pending.payload)
        if not ok then
          remove_pending_event_wait(id)
          log("[Sceatorio] AI event wait failed: " .. tostring(result))
          complete_request_error(
            pending.port,
            pending.context,
            id,
            pending.request_bytes,
            "INTERNAL_ERROR",
            "Factorio could not complete the event wait"
          )
        elseif result == nil then
          remove_pending_event_wait(id)
          complete_request_error(
            pending.port,
            pending.context,
            id,
            pending.request_bytes,
            code or "FACTORIO_ERROR",
            message or "Event wait failed",
            false,
            details
          )
        elseif #(result.events or {}) > 0 or game.tick >= pending.deadline_tick then
          remove_pending_event_wait(id)
          complete_request_success(
            pending.port,
            pending.context,
            id,
            pending.request_bytes,
            result
          )
        else
          pending.payload.cursor = result.cursor
        end
      end
      if pending_event_waits[id] then enqueue_event_wait(id) end
    end
  end
end

local function cancel_event_waits(message)
  for id, pending in pairs(pending_event_waits) do
    remove_pending_event_wait(id)
    complete_request_error(
      pending.port,
      pending.context,
      id,
      pending.request_bytes,
      "WAIT_CANCELLED",
      message
    )
  end
  pending_event_waits = {}
  pending_event_wait_queue = {slots = {}, head = 1, tail = 0, count = 0}
  pending_event_wait_count = 0
end

local function cleanup_pairing_codes()
  if game.tick % 60 ~= 0 then return end
  for code, pending in pairs(pending_pairings) do
    if pending.expires_tick <= game.tick then remove_pairing_code(code) end
  end
  trim_pairing_replays(0, 0)
end

local function binding_has_pending_wait(binding)
  for _, pending in pairs(pending_event_waits) do
    if pending.context.binding == binding then return true end
  end
  return false
end

local function compact_bindings()
  if game.tick % 600 ~= 0 then return end
  local ai = root()
  for player_index, ids in pairs(ai.binding_ids_by_player) do
    local records = {}
    for _, id in ipairs(ids) do
      local binding = ai.bindings[id]
      if binding then records[#records + 1] = binding end
    end
    table.sort(records, function(first, second) return first.issued_tick > second.issued_tick end)
    local retained, inactive_count = {}, 0
    for _, binding in ipairs(records) do
      local active = not binding.revoked_tick and binding.expires_tick > game.tick
      local inactive_since = binding.revoked_tick or binding.expires_tick
      local keep = active or binding_has_pending_wait(binding)
      if not active then
        inactive_count = inactive_count + 1
        if inactive_count <= MAX_RETAINED_BINDINGS_PER_PLAYER
          and game.tick - inactive_since <= BINDING_RETENTION_TICKS then keep = true end
      end
      if keep then
        retained[#retained + 1] = binding.id
      else
        ai.bindings[binding.id] = nil
      end
    end
    ai.binding_ids_by_player[player_index] = #retained > 0 and retained or nil
  end
  for player_id, quota in pairs(ai.quota) do
    if quota.window_tick + TICKS_PER_MINUTE < game.tick then ai.quota[player_id] = nil end
  end
  for player_id, bucket in pairs(ai.completed_requests_by_player) do
    trim_completed_requests(bucket, 0, 0)
    if bucket.count == 0 then ai.completed_requests_by_player[player_id] = nil end
  end
end

local function process_ingress()
  for _ = 1, MAX_INGRESS_PACKETS_PER_TICK do
    local event = dequeue_ingress()
    if not event then break end
    local ok, decoded = pcall(helpers.json_to_table, event.payload)
    if ok and type(decoded) == "table" then
      if decoded.kind == "pairing.exchange" then
        handle_pairing_exchange(event.source_port, decoded, event.payload)
      else
        execute_request(event.source_port, decoded, event.payload)
      end
    end
  end
end

function Gateway.poll()
  AiControl.tick()
  cleanup_pairing_codes()
  process_event_waits()
  compact_bindings()
  if not global_value("sceatorio-ai-enabled", false) then return end
  process_ingress()
  local udp = root().udp
  if game.tick < (udp.next_retry_tick or 0) then return end
  local ok, reason = pcall(function() helpers.recv_udp(0) end)
  if ok then
    udp.failure_logged = false
    udp.next_retry_tick = game.tick
  else
    udp.next_retry_tick = game.tick + 600
    if not udp.failure_logged then
      log("[Sceatorio] Lua UDP is unavailable; start Factorio with --enable-lua-udp: " .. tostring(reason))
      udp.failure_logged = true
    end
  end
end

function Gateway.on_udp_packet_received(event)
  if not global_value("sceatorio-ai-enabled", false) then return end
  if event.player_index ~= 0 or type(event.payload) ~= "string" then return end
  if #event.payload > MAX_DATAGRAM_BYTES then return end
  enqueue_ingress(event)
end

function Gateway.on_entity_built(event)
  if not global_value("sceatorio-ai-enabled", false) then return end
  AiEvents.record("entity.built", event)
end

function Gateway.on_entity_removed(event)
  if not global_value("sceatorio-ai-enabled", false) then return end
  local entity = event.entity
  if not entity then return end
  AiEvents.record("entity.removed", event)
  if entity.name == AiConstants.OUTPUT_PORT then AiControl.on_entity_removed(entity) end
  Telemetry.on_entity_removed(entity)
  if entity.name == AiConstants.UPLINK and entity.unit_number then
    for code, pending in pairs(pending_pairings) do
      if pending.uplink_unit_number == entity.unit_number then remove_pairing_code(code) end
    end
    for _, binding in pairs(root().bindings) do
      if binding.uplink_unit_number == entity.unit_number then revoke_binding(binding, "uplink-removed") end
    end
  end
end

function Gateway.on_player_changed_force(event)
  remove_player_pairing_code(event.player_index)
  revoke_player_bindings(event.player_index, "player-force-changed")
  local player = game.get_player(event.player_index)
  AiEvents.record("player.force-changed", {
    force = player and player.valid and player.force or nil,
    surface = physical_player_surface(player),
    player_index = event.player_index
  })
end

function Gateway.on_player_joined(event)
  local player = game.get_player(event.player_index)
  AiEvents.record("player.joined", {
    force = player and player.valid and player.force or nil,
    surface = physical_player_surface(player),
    player_index = event.player_index
  })
end

function Gateway.on_player_left(event)
  local player = game.get_player(event.player_index)
  AiEvents.record("player.left", {
    force = player and player.valid and player.force or nil,
    surface = physical_player_surface(player),
    player_index = event.player_index
  })
end

function Gateway.on_player_removed(event)
  remove_player_pairing_code(event.player_index)
  revoke_player_bindings(event.player_index, "player-removed")
  root().quota["player:" .. event.player_index] = nil
  root().completed_requests_by_player["player:" .. event.player_index] = nil
end

function Gateway.on_player_changed_surface(event)
  local player = game.get_player(event.player_index)
  AiEvents.record("player.surface-changed", {
    force = player and player.valid and player.force or nil,
    surface = physical_player_surface(player),
    player_index = event.player_index
  }, {previous_surface_index = event.surface_index})
end

function Gateway.on_research_started(event)
  local research = event.research
  AiEvents.record("research.started", {force = research and research.valid and research.force or nil}, {
    technology = research and research.valid and research.name or nil
  })
end

function Gateway.on_research_finished(event)
  local research = event.research
  AiEvents.record("research.finished", {force = research and research.valid and research.force or nil}, {
    technology = research and research.valid and research.name or nil
  })
end

function Gateway.on_surface_deleted(event)
  local id = "surface:" .. event.surface_index
  for _, binding in pairs(root().bindings) do
    binding.surfaces[id] = nil
    if binding.uplink_entity and binding.uplink_entity.valid
      and binding.uplink_entity.surface.index == event.surface_index then
      revoke_binding(binding, "uplink-surface-deleted")
    end
  end
end

function Gateway.on_forces_merged(event)
  local source = event.source
  if not source then return end
  for _, binding in pairs(root().bindings) do
    if binding.force_index == source.index then revoke_binding(binding, "force-merged") end
  end
end

function Gateway.on_setting_changed(event)
  if event.setting == "sceatorio-ai-assistance-enabled" and event.player_index then
    local player = game.get_player(event.player_index)
    if player and player.valid and not player_value(player, event.setting, false) then
      remove_player_pairing_code(event.player_index)
      revoke_player_bindings(event.player_index, "player-opted-out")
    end
  elseif event.setting == "sceatorio-ai-enabled"
    and not global_value("sceatorio-ai-enabled", false) then
    for code in pairs(pending_pairings) do remove_pairing_code(code) end
    for _, binding in pairs(root().bindings) do
      revoke_binding(binding, "server-policy-disabled")
    end
    cancel_event_waits("Server disabled AI assistance while waiting")
    clear_pairing_replays()
    clear_ingress()
  end
end

local function active_bindings(player, include_force)
  local values = {}
  for _, binding in pairs(root().bindings) do
    if not binding.revoked_tick and binding.expires_tick > game.tick
      and (binding.player_index == player.index
        or (include_force and binding.force_index == player.force.index)) then
      values[#values + 1] = binding
    end
  end
  table.sort(values, function(first, second) return first.issued_tick > second.issued_tick end)
  return values
end

local function destroy_gui(player)
  local frame = player.gui.screen[GUI_NAME]
  if frame and frame.valid then frame.destroy() end
end

local function render_gui(player, uplink, message)
  destroy_gui(player)
  local frame = player.gui.screen.add({
    type = "frame",
    name = GUI_NAME,
    caption = {"gui.sceatorio-ai-uplink-title"},
    direction = "vertical",
    tags = {uplink_unit_number = uplink.unit_number}
  })
  frame.auto_center = true
  local title = frame.add({type = "flow", direction = "horizontal"})
  title.drag_target = frame
  title.add({type = "label", caption = {"gui.sceatorio-ai-uplink-policy"}})
  local spacer = title.add({type = "empty-widget"})
  spacer.style.horizontally_stretchable = true
  title.add({
    type = "sprite-button",
    sprite = "utility/close",
    style = "frame_action_button",
    tags = {sceatorio_action = "ai_close"}
  })
  if message then frame.add({type = "label", caption = message}) end
  frame.add({
    type = "button",
    caption = {"gui.sceatorio-ai-create-pairing"},
    tags = {sceatorio_action = "ai_create_pairing", uplink_unit_number = uplink.unit_number}
  })
  local code = pairing_code_by_player[tostring(player.index)]
  local pending = code and pending_pairings[code] or nil
  if pending and pending.expires_tick > game.tick then
    frame.add({
      type = "label",
      caption = {"gui.sceatorio-ai-pairing-code-expires", pending.expires_tick}
    })
    local box = frame.add({type = "text-box", text = code})
    box.read_only = true
    box.style.width = 280
    box.style.height = 40
  end
  local bindings = active_bindings(player, player.admin)
  for _, binding in ipairs(bindings) do
    local row = frame.add({type = "flow", direction = "horizontal"})
    row.add({type = "label", caption = binding.id .. "  (tick " .. binding.expires_tick .. ")"})
    row.add({
      type = "button",
      caption = {"gui.sceatorio-ai-revoke"},
      tags = {sceatorio_action = "ai_revoke_binding", binding_id = binding.id}
    })
  end
end

function Gateway.on_gui_opened(event)
  local entity = event.entity
  if not (entity and entity.valid and entity.name == AiConstants.UPLINK) then return end
  local player = game.get_player(event.player_index)
  if player and player.valid then render_gui(player, entity) end
end

function Gateway.on_gui_closed(event)
  local player = game.get_player(event.player_index)
  if player and player.valid then destroy_gui(player) end
end

local function entity_for_gui(player, unit_number)
  if type(unit_number) ~= "number" then return nil end
  local entity = game.get_entity_by_unit_number(unit_number)
  if entity and entity.valid and entity.name == AiConstants.UPLINK
    and entity.force.index == player.force.index then return entity end
  local frame = player.gui.screen[GUI_NAME]
  if frame and frame.valid and frame.tags.uplink_unit_number == unit_number then
    local opened = player.opened
    if opened and opened.valid and opened.unit_number == unit_number then return opened end
  end
  return nil
end

function Gateway.on_gui_click(event)
  local element = event.element
  if not (element and element.valid) then return false end
  local tags = element.tags or {}
  local action = tags.sceatorio_action
  if not action or string.sub(action, 1, 3) ~= "ai_" then return false end
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return true end
  if action == "ai_close" then destroy_gui(player) return true end
  if action == "ai_revoke_binding" then
    local binding = root().bindings[tags.binding_id]
    if binding and (binding.player_index == player.index
      or (player.admin and binding.force_index == player.force.index)) then
      revoke_binding(binding, "gui-revoked")
    end
    local frame = player.gui.screen[GUI_NAME]
    local unit = frame and frame.valid and frame.tags.uplink_unit_number or nil
    local uplink = entity_for_gui(player, unit)
    if uplink then render_gui(player, uplink, {"gui.sceatorio-ai-revoked"}) end
    return true
  end
  if action == "ai_create_pairing" then
    local uplink = entity_for_gui(player, tags.uplink_unit_number)
    if not uplink then player.print("AI Uplink is no longer available.") return true end
    local pending, reason = Gateway.create_player_pairing_code(player, uplink)
    render_gui(
      player,
      uplink,
      pending and {"gui.sceatorio-ai-pairing-created"} or reason
    )
    return true
  end
  return true
end

local function dev_allowed(command)
  if not global_value("sceatorio-dev-tools-enabled", false) then return false, "Developer tools are disabled." end
  if not global_value("sceatorio-ai-enabled", false) then return false, "AI assistance server policy is disabled." end
  if command.player_index then
    local player = game.get_player(command.player_index)
    if not (player and player.valid and player.admin) then return false, "Administrator permission is required." end
  end
  return true
end

local function dev_print(command, value)
  if command.player_index then
    local player = game.get_player(command.player_index)
    if player and player.valid then player.print(value) end
  else
    rcon.print(value)
  end
end

local function create_dev_entities(force, surface)
  local ai = root()
  local existing = ai.dev_uplink
  if existing and existing.valid
    and ai.dev_input_port and ai.dev_input_port.valid
    and ai.dev_output_port and ai.dev_output_port.valid
    and ai.dev_roboport and ai.dev_roboport.valid then return existing end
  local base = surface.find_non_colliding_position("substation", {128, 128}, 256, 2) or {x = 128, y = 128}
  local interface = surface.create_entity({
    name = "electric-energy-interface",
    position = {x = base.x - 4, y = base.y},
    force = force,
    create_build_effect_smoke = false
  })
  local substation = surface.create_entity({
    name = "substation",
    position = base,
    force = force,
    create_build_effect_smoke = false
  })
  local uplink = surface.create_entity({
    name = AiConstants.UPLINK,
    position = {x = base.x + 5, y = base.y},
    force = force,
    create_build_effect_smoke = false
  })
  surface.create_entity({
    name = "steel-chest",
    position = {x = base.x + 13, y = base.y},
    force = force,
    create_build_effect_smoke = false
  })
  local input_port = surface.create_entity({
    name = AiConstants.INPUT_PORT,
    position = {x = base.x + 9, y = base.y},
    force = force,
    create_build_effect_smoke = false
  })
  local output_port = surface.create_entity({
    name = AiConstants.OUTPUT_PORT,
    position = {x = base.x + 11, y = base.y},
    force = force,
    create_build_effect_smoke = false
  })
  local roboport = surface.create_entity({
    name = "roboport",
    position = {x = base.x, y = base.y + 8},
    force = force,
    create_build_effect_smoke = false
  })
  if not (interface and interface.valid and substation and substation.valid and uplink and uplink.valid
    and input_port and input_port.valid and output_port and output_port.valid
    and roboport and roboport.valid) then
    return nil, "Could not create isolated development Uplink power fixtures."
  end
  interface.power_production = 10000000
  interface.power_usage = 0
  interface.energy = 10000000
  uplink.energy = 5000000
  force.chart(surface, {{base.x - 64, base.y - 64}, {base.x + 64, base.y + 64}})
  ai.dev_uplink = uplink
  ai.dev_input_port = input_port
  ai.dev_output_port = output_port
  ai.dev_roboport = roboport
  Telemetry.index_entity(interface)
  Telemetry.index_entity(substation)
  Telemetry.index_entity(uplink)
  Telemetry.index_entity(input_port)
  Telemetry.index_entity(output_port)
  Telemetry.index_entity(roboport)
  return uplink
end

local function dev_pairing_options(command)
  local allowed, reason = dev_allowed(command)
  if not allowed then return nil, reason end
  local force = game.forces.player
  local surface = game.get_surface("nauvis") or game.surfaces[1]
  force.technologies[AiConstants.TECHNOLOGY].researched = true
  local uplink, entity_reason = create_dev_entities(force, surface)
  if not uplink then return nil, entity_reason end
  local powered, power_reason = uplink_powered(uplink, force)
  if not powered then return nil, power_reason end
  return {
    player_index = 0,
    player_id = "dev-player:0",
    force = force,
    team_id = "dev-team:" .. force.index,
    surfaces = binding_surfaces(nil, surface, nil),
    capabilities = effective_capabilities(force, nil, true),
    uplink = uplink,
    primary_surface_index = surface.index,
    allow_cursor = false,
    dev_virtual = true
  }
end

local function create_dev_binding(command)
  local options, reason = dev_pairing_options(command)
  if not options then dev_print(command, "SCEATORIO_AI_DEV_ERROR=" .. reason) return end
  revoke_player_bindings(0, "dev-re-paired")
  local binding = create_binding_record(options)
  dev_print(command, "SCEATORIO_AI_BINDING_JSON=" .. helpers.table_to_json(descriptor(binding)))
end

local function create_dev_pairing_code(command)
  local options, reason = dev_pairing_options(command)
  if not options then dev_print(command, "SCEATORIO_AI_DEV_ERROR=" .. reason) return end
  local pending, pairing_reason = create_pairing_code(options)
  if not pending then dev_print(command, "SCEATORIO_AI_DEV_ERROR=" .. pairing_reason) return end
  dev_print(command, "SCEATORIO_AI_PAIRING_CODE=" .. pending.code)
  dev_print(command, "SCEATORIO_AI_PAIRING_EXPIRES_TICK=" .. pending.expires_tick)
end

local function revoke_dev_binding(command)
  local allowed, reason = dev_allowed(command)
  if not allowed then dev_print(command, "SCEATORIO_AI_DEV_ERROR=" .. reason) return end
  local id = command.parameter
  local binding = id and root().bindings[id] or nil
  if not (binding and binding.dev_virtual) then
    dev_print(command, "SCEATORIO_AI_DEV_ERROR=Development binding not found.")
    return
  end
  revoke_binding(binding, "dev-command-revoked")
  dev_print(command, "SCEATORIO_AI_REVOKED=" .. id)
end

local function expire_dev_pairing_code(command)
  local allowed, reason = dev_allowed(command)
  if not allowed then dev_print(command, "SCEATORIO_AI_DEV_ERROR=" .. reason) return end
  local pending = command.parameter and pending_pairings[command.parameter] or nil
  if not (pending and pending.dev_virtual) then
    dev_print(command, "SCEATORIO_AI_DEV_ERROR=Development pairing code not found.")
    return
  end
  pending.expires_tick = game.tick
  dev_print(command, "SCEATORIO_AI_PAIRING_EXPIRED=" .. pending.code)
end

local function set_dev_ai_policy(command)
  if not global_value("sceatorio-dev-tools-enabled", false) then
    dev_print(command, "SCEATORIO_AI_DEV_ERROR=Developer tools are disabled.")
    return
  end
  if command.player_index then
    local player = game.get_player(command.player_index)
    if not (player and player.valid and player.admin) then
      dev_print(command, "SCEATORIO_AI_DEV_ERROR=Administrator permission is required.")
      return
    end
  end
  local enabled
  if command.parameter == "on" then enabled = true
  elseif command.parameter == "off" then enabled = false
  else
    dev_print(command, "SCEATORIO_AI_DEV_ERROR=Expected 'on' or 'off'.")
    return
  end
  settings.global["sceatorio-ai-enabled"] = {value = enabled}
  dev_print(command, "SCEATORIO_AI_POLICY_ENABLED=" .. tostring(enabled))
end

function Gateway.initialize()
  root()
  ensure_save_id()
end

commands.add_command(
  "sceatorio-ai-dev-code",
  "Create a one-time localhost headless MCP pairing code (developer tools only).",
  create_dev_pairing_code
)

commands.add_command(
  "sceatorio-ai-dev-bind",
  "Create a localhost-only headless MCP test binding (developer tools only).",
  create_dev_binding
)

commands.add_command(
  "sceatorio-ai-dev-revoke",
  "Revoke a headless MCP test binding (developer tools only).",
  revoke_dev_binding
)

commands.add_command(
  "sceatorio-ai-dev-expire-code",
  "Expire one pending headless MCP pairing code (developer tools only).",
  expire_dev_pairing_code
)

commands.add_command(
  "sceatorio-ai-dev-policy",
  "Toggle AI server policy for fail-closed headless tests (developer tools only).",
  set_dev_ai_policy
)

return Gateway
