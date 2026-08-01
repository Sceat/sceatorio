local State = require("src.core.state")
local Telemetry = require("src.game.aiTelemetry")

local AiControl = {}

local MAX_READ_SIGNALS = 128
local MAX_OUTPUT_PORTS = 256
local MIN_WRITE_INTERVAL_TICKS = 5 * 60
local OUTPUT_GROUP = "Sceatorio AI output"

local function control_root()
  local state = State.get()
  state.ai = state.ai or {}
  state.ai.control_outputs = state.ai.control_outputs or {}
  return state.ai.control_outputs
end

local function signal_plain(signal)
  local id = signal.signal
  return {
    type = id.type or "item",
    name = id.name,
    quality = id.quality,
    value = signal.count
  }
end

local function read_signals(entity)
  local ok, signals = pcall(function()
    return entity.get_signals(
      defines.wire_connector_id.combinator_output_red,
      defines.wire_connector_id.combinator_output_green
    )
  end)
  if not ok then
    ok, signals = pcall(function()
      return entity.get_signals(
        defines.wire_connector_id.circuit_red,
        defines.wire_connector_id.circuit_green
      )
    end)
  end
  if not ok then return nil, "CIRCUIT_READ_FAILED", "Factorio rejected the dedicated port connector" end
  signals = signals or {}
  table.sort(signals, function(first, second)
    local a, b = first.signal, second.signal
    local a_key = (a.type or "item") .. ":" .. (a.name or "") .. ":" .. (a.quality or "")
    local b_key = (b.type or "item") .. ":" .. (b.name or "") .. ":" .. (b.quality or "")
    return a_key < b_key
  end)
  local result = {}
  for index, signal in ipairs(signals) do
    if index > MAX_READ_SIGNALS then break end
    result[#result + 1] = signal_plain(signal)
  end
  return result, #signals > MAX_READ_SIGNALS
end

function AiControl.read_port(context, payload)
  if type(payload) ~= "table" then return nil, "INVALID_REQUEST", "Circuit payload must be an object" end
  local entity, code, message = Telemetry.resolve_entity(context, payload.portId)
  if not entity then return nil, code, message end
  if entity.name ~= "sceatorio-ai-input-port" then
    return nil, "NOT_AI_INPUT_PORT", "Circuit reads are restricted to the dedicated AI Input Port"
  end
  local signals, truncated_or_code, read_message = read_signals(entity)
  if not signals then return nil, truncated_or_code, read_message end
  return {
    portId = "entity:" .. entity.unit_number,
    surfaceId = context.surface_id,
    signals = signals,
    truncated = truncated_or_code,
    maxSignals = MAX_READ_SIGNALS
  }
end

local function valid_signal(signal)
  if type(signal) ~= "table" then return false end
  if signal.type ~= "item" and signal.type ~= "fluid" and signal.type ~= "virtual" then return false end
  if type(signal.name) ~= "string" or #signal.name < 1 or #signal.name > 200 then return false end
  if type(signal.value) ~= "number" or signal.value ~= math.floor(signal.value)
    or signal.value < -2147483648 or signal.value > 2147483647 then return false end
  if signal.quality ~= nil and not prototypes.quality[signal.quality] then return false end
  if signal.type == "item" and not prototypes.item[signal.name] then return false end
  if signal.type == "fluid" and not prototypes.fluid[signal.name] then return false end
  if signal.type == "virtual" and not prototypes.virtual_signal[signal.name] then return false end
  return true
end

local function output_section(behavior)
  for _, section in ipairs(behavior.sections) do
    if section.valid and section.is_manual and section.group == OUTPUT_GROUP then return section end
  end
  return behavior.add_section(OUTPUT_GROUP)
end

local function output_count(outputs)
  local count = 0
  for _ in pairs(outputs) do count = count + 1 end
  return count
end

function AiControl.write_port(context, payload)
  if type(payload) ~= "table" or type(payload.signals) ~= "table" or #payload.signals > 32 then
    return nil, "INVALID_SIGNALS", "Control output accepts at most 32 signals"
  end
  local entity, code, message = Telemetry.resolve_entity(context, payload.portId)
  if not entity then return nil, code, message end
  if entity.name ~= "sceatorio-ai-output-port" then
    return nil, "NOT_AI_OUTPUT_PORT", "Circuit writes are restricted to the dedicated AI Output Port"
  end
  local ttl = payload.ttlSeconds or 30
  if type(ttl) ~= "number" or ttl ~= math.floor(ttl) or ttl < 5 or ttl > 3600 then
    return nil, "INVALID_TTL", "Control output TTL must be 5 through 3600 seconds"
  end
  local outputs = control_root()
  local existing = outputs[entity.unit_number]
  if existing and game.tick - existing.last_change_tick < MIN_WRITE_INTERVAL_TICKS then
    return nil, "CONTROL_PORT_RATE_LIMITED", "This output port may change at most once every five seconds"
  end
  if not existing and output_count(outputs) >= MAX_OUTPUT_PORTS then
    return nil, "CONTROL_PORT_BUDGET_EXCEEDED", "The save-wide bounded AI output-port index is full"
  end
  local filters = {}
  local seen = {}
  for _, signal in ipairs(payload.signals) do
    if not valid_signal(signal) then return nil, "INVALID_SIGNAL", "Control output contains an invalid signal" end
    local quality = signal.quality or "normal"
    local key = signal.type .. ":" .. signal.name .. ":" .. quality
    if seen[key] then return nil, "DUPLICATE_SIGNAL", "Control output signal IDs must be unique" end
    seen[key] = true
    filters[#filters + 1] = {
      value = {type = signal.type, name = signal.name, quality = quality},
      min = signal.value
    }
  end
  local behavior = entity.get_or_create_control_behavior()
  local section = output_section(behavior)
  if not section then return nil, "CONTROL_PORT_UNAVAILABLE", "AI output section could not be created" end
  section.filters = filters
  section.active = true
  behavior.enabled = true
  local clear_tick = game.tick + ttl * 60
  entity.combinator_description = "AI output: changed tick " .. game.tick .. "; clears tick " .. clear_tick
  outputs[entity.unit_number] = {
    entity = entity,
    binding_id = context.binding.id,
    last_change_tick = game.tick,
    clear_tick = clear_tick,
    signal_count = #filters
  }
  return {
    portId = "entity:" .. entity.unit_number,
    signalCount = #filters,
    changedTick = game.tick,
    clearTick = clear_tick,
    minimumWriteIntervalSeconds = 5
  }
end

local function clear_output(record)
  local entity = record.entity
  if not (entity and entity.valid and entity.name == "sceatorio-ai-output-port") then return end
  local behavior = entity.get_control_behavior()
  if not (behavior and behavior.valid) then return end
  for _, section in ipairs(behavior.sections) do
    if section.valid and section.is_manual and section.group == OUTPUT_GROUP then
      section.filters = {}
      section.active = false
      break
    end
  end
  entity.combinator_description = "AI output expired and cleared at tick " .. game.tick
end

function AiControl.tick()
  if game.tick % 30 ~= 0 then return end
  local outputs = control_root()
  for unit_number, record in pairs(outputs) do
    if game.tick >= record.clear_tick or not (record.entity and record.entity.valid) then
      clear_output(record)
      outputs[unit_number] = nil
    end
  end
end

function AiControl.on_entity_removed(entity)
  if not (entity and entity.unit_number) then return end
  local state = State.get()
  local outputs = state and state.ai and state.ai.control_outputs or nil
  if outputs then outputs[entity.unit_number] = nil end
end

function AiControl.add_annotation(context, payload)
  if not (context.player and context.player.valid) then
    return nil, "PLAYER_REQUIRED", "Private annotations require a real paired player"
  end
  if type(payload) ~= "table" or type(payload.position) ~= "table"
    or type(payload.position.x) ~= "number" or type(payload.position.y) ~= "number"
    or type(payload.text) ~= "string" or #payload.text < 1 or #payload.text > 200 then
    return nil, "INVALID_ANNOTATION", "Annotation position or text is invalid"
  end
  local ttl = payload.ttlSeconds or 3600
  if type(ttl) ~= "number" or ttl ~= math.floor(ttl) or ttl < 10 or ttl > 86400 then
    return nil, "INVALID_TTL", "Annotation TTL must be 10 through 86400 seconds"
  end
  local object = rendering.draw_text({
    text = payload.text,
    surface = context.surface,
    target = payload.position,
    color = {r = 0.72, g = 0.43, b = 1, a = 1},
    players = {context.player.index},
    forces = {context.force},
    render_mode = "chart",
    time_to_live = ttl * 60,
    scale_with_zoom = true,
    use_rich_text = false
  })
  return {
    annotationId = "render:" .. object.id,
    surfaceId = context.surface_id,
    position = {x = payload.position.x, y = payload.position.y},
    createdTick = game.tick,
    expiresTick = game.tick + ttl * 60,
    visibility = "paired-player-only"
  }
end

return AiControl
