local State = require("src.core.state")

local Telemetry = {}

local MAX_SCAN_RESULTS = 5000
local MAX_INVENTORY_TYPES = 100
local MAX_ENTITY_REFS = 2000
local ENTITY_REF_SCHEMA_VERSION = 2

-- Prototype shape bounds. The binding constraint is the 48 KiB gateway
-- response datagram (AiConstants.MAX_DATAGRAM_BYTES), not these counts: a
-- fully saturated pipe connection encodes to roughly 410 bytes, so 32 total
-- connections plus 16 boxes plus two 32-entry category lists is about 18 KiB
-- of new payload in the worst case. Vanilla never comes close - the widest
-- fluid entities are the oil refinery (5 boxes, 1 connection each) and the
-- storage tank (1 box, 4 connections), both well under 2 KiB.
local MAX_FLUID_BOXES = 16
local MAX_PIPE_CONNECTIONS = 8
local MAX_PIPE_CONNECTIONS_TOTAL = 32
local MAX_CONNECTION_CATEGORIES = 4
local MAX_PROTOTYPE_CATEGORIES = 32
local MAX_MODULE_EFFECTS = 16

-- PipeConnectionDefinition.positions holds the four cardinal connection points
-- of one connection, in engine order, so a client can pick the tile for the
-- direction it intends to place the entity in without guessing.
local FLUID_BOX_POSITION_ORDER = {"north", "east", "south", "west"}

local STATUS_NAME = {}
for name, value in pairs(defines.entity_status) do
  STATUS_NAME[value] = name
end

local TRAIN_STATE_NAME = {}
for name, value in pairs(defines.train_state) do
  TRAIN_STATE_NAME[value] = name
end

local ALERT_TYPE_NAME = {}
for name, value in pairs(defines.alert_type) do
  ALERT_TYPE_NAME[value] = name
end

local INVENTORY_NAME = {}
for name, value in pairs(defines.inventory) do
  if type(value) == "number" and not INVENTORY_NAME[value] then
    INVENTORY_NAME[value] = name
  end
end

local function finite(value)
  return type(value) == "number"
    and value == value
    and value > -math.huge
    and value < math.huge
end

local function valid_string(value, maximum)
  return type(value) == "string" and #value > 0 and #value <= maximum
end

local function parse_offset(cursor, maximum)
  if cursor == nil then return 0 end
  if type(cursor) ~= "string" then return nil end
  local offset = tonumber(string.match(cursor, "^offset:(%d+)$"))
  if not offset or offset > (maximum or MAX_SCAN_RESULTS) then return nil end
  return offset
end

local function page_parameters(context, pagination, maximum)
  if pagination ~= nil and type(pagination) ~= "table" then
    return nil, nil, "INVALID_PAGINATION", "pagination must be an object"
  end
  local offset = parse_offset(pagination and pagination.cursor, maximum)
  if offset == nil then
    return nil, nil, "INVALID_CURSOR", "pagination cursor is invalid"
  end
  local limit = pagination and pagination.limit or 100
  if not finite(limit) or limit ~= math.floor(limit) or limit < 1 then
    return nil, nil, "INVALID_PAGE_SIZE", "page size must be a positive integer"
  end
  limit = math.min(limit, context.max_page_size or 100, 200)
  return offset, limit
end

local function page_array(values, offset, limit)
  local result = {}
  local last = math.min(#values, offset + limit)
  for index = offset + 1, last do
    result[#result + 1] = values[index]
  end
  return result, last < #values and ("offset:" .. last) or nil, #values
end

local function sorted_keys(dictionary)
  local keys = {}
  for key in pairs(dictionary or {}) do
    if type(key) == "string" then keys[#keys + 1] = key end
  end
  table.sort(keys)
  return keys
end

local function bounded_names(dictionaries, include)
  local names = {}
  local seen = {}
  local examined = 0
  local truncated = false
  for _, dictionary in ipairs(dictionaries) do
    for name, value in pairs(dictionary or {}) do
      if examined >= MAX_SCAN_RESULTS then
        truncated = true
        break
      end
      examined = examined + 1
      if type(name) == "string" and not seen[name]
        and (not include or include(name, value)) then
        seen[name] = true
        names[#names + 1] = name
      end
    end
    if truncated then break end
  end
  table.sort(names)
  return names, truncated, examined
end

local function copy_position(position)
  return {x = position.x, y = position.y}
end

-- Prototype-stage MapPosition and Vector values may arrive in either the named
-- or the array form, so normalise both before they reach a client.
local function copy_vector(vector)
  if type(vector) ~= "table" then return nil end
  local x = vector.x or vector[1]
  local y = vector.y or vector[2]
  if not finite(x) or not finite(y) then return nil end
  return {x = x, y = y}
end

local function safe_value(callback)
  local ok, value, second = pcall(callback)
  if not ok then return nil, nil end
  return value, second
end

local function entity_id(entity)
  return entity.unit_number and ("entity:" .. entity.unit_number) or nil
end

local function ai_enabled()
  local setting = settings.global["sceatorio-ai-enabled"]
  return setting and setting.value or false
end

local function append_entity_ref(refs, unit, entity)
  if refs.by_unit[unit] == nil then
    if refs.count >= MAX_ENTITY_REFS then
      local removed = refs.slots[refs.head]
      refs.slots[refs.head] = nil
      refs.head = (refs.head % MAX_ENTITY_REFS) + 1
      refs.count = refs.count - 1
      if removed ~= nil then refs.by_unit[removed] = nil end
    end
    refs.tail = (refs.tail % MAX_ENTITY_REFS) + 1
    refs.slots[refs.tail] = unit
    refs.count = refs.count + 1
  end
  refs.by_unit[unit] = entity
end

local function migrate_entity_refs(refs)
  if refs.schema_version == ENTITY_REF_SCHEMA_VERSION
    and type(refs.by_unit) == "table"
    and type(refs.slots) == "table"
    and type(refs.head) == "number"
    and type(refs.tail) == "number"
    and type(refs.count) == "number" then return refs end

  local old_by_unit = type(refs.by_unit) == "table" and refs.by_unit or {}
  local units = {}
  local seen = {}
  if type(refs.order) == "table" then
    for _, unit in ipairs(refs.order) do
      if type(unit) == "number" and not seen[unit] then
        seen[unit] = true
        units[#units + 1] = unit
      end
    end
  end
  if #units == 0 then
    for unit in pairs(old_by_unit) do
      if type(unit) == "number" then units[#units + 1] = unit end
    end
    table.sort(units)
  end

  refs.schema_version = ENTITY_REF_SCHEMA_VERSION
  refs.by_unit = {}
  refs.slots = {}
  refs.head = 1
  refs.tail = 0
  refs.count = 0
  refs.order = nil
  for _, unit in ipairs(units) do
    local entity = old_by_unit[unit]
    if entity and entity.valid then append_entity_ref(refs, unit, entity) end
  end
  return refs
end

local function entity_ref_root()
  local root = State.get()
  root.ai = root.ai or {}
  root.ai.entity_refs = root.ai.entity_refs or {
    schema_version = ENTITY_REF_SCHEMA_VERSION,
    by_unit = {},
    slots = {},
    head = 1,
    tail = 0,
    count = 0
  }
  return migrate_entity_refs(root.ai.entity_refs)
end

function Telemetry.index_entity(entity)
  if not ai_enabled() or not (entity and entity.valid and entity.unit_number) then return end
  local refs = entity_ref_root()
  local unit = entity.unit_number
  append_entity_ref(refs, unit, entity)
end

function Telemetry.on_entity_removed(entity)
  if not ai_enabled() or not (entity and entity.unit_number) then return end
  local state = State.get()
  local refs = state and state.ai and state.ai.entity_refs or nil
  if not refs then return end
  refs = migrate_entity_refs(refs)
  refs.by_unit[entity.unit_number] = nil
end

local function resolve_entity(context, id)
  if not context.surface then
    return nil, "SURFACE_REQUIRED", "entity resolution requires an authorized scoped surface"
  end
  if not valid_string(id, 200) then
    return nil, "INVALID_ENTITY_ID", "entity ID is invalid"
  end
  local unit_number = tonumber(string.match(id, "^entity:(%d+)$"))
  if not unit_number then
    return nil, "INVALID_ENTITY_ID", "entity ID must be an opaque Sceatorio entity ID"
  end
  local refs = entity_ref_root()
  local entity = refs.by_unit[unit_number]
  if not (entity and entity.valid) then
    entity = game.get_entity_by_unit_number(unit_number)
  end
  if not (entity and entity.valid) then
    refs.by_unit[unit_number] = nil
    return nil, "ENTITY_NOT_FOUND", "entity no longer exists"
  end
  if entity.force.index ~= context.force.index then
    return nil, "FORCE_SCOPE_MISMATCH", "entity belongs to another force"
  end
  if entity.surface.index ~= context.surface.index then
    return nil, "SURFACE_SCOPE_MISMATCH", "entity belongs to another surface"
  end
  Telemetry.index_entity(entity)
  return entity
end

function Telemetry.resolve_entity(context, id)
  return resolve_entity(context, id)
end

local function status_name(status)
  return STATUS_NAME[status] or (status and tostring(status)) or nil
end

local function entity_summary(entity)
  local recipe, recipe_quality = safe_value(function() return entity.get_recipe() end)
  local electric_id = entity.electric_network_id
  local logistic = safe_value(function() return entity.logistic_network end)
  return {
    entityId = entity_id(entity),
    name = entity.name,
    type = entity.type,
    quality = entity.quality and entity.quality.name or "normal",
    position = copy_position(entity.position),
    direction = entity.direction,
    status = status_name(entity.status),
    health = entity.health,
    maxHealth = entity.max_health,
    active = entity.active,
    energyJ = entity.energy,
    recipe = recipe and recipe.name or nil,
    recipeQuality = recipe_quality and recipe_quality.name or nil,
    electricNetworkId = electric_id and ("electric:" .. electric_id) or nil,
    logisticNetworkId = logistic and logistic.valid and ("logistic:" .. logistic.network_id) or nil
  }
end

local PRECISION = {
  ["5s"] = defines.flow_precision_index.five_seconds,
  ["1m"] = defines.flow_precision_index.one_minute,
  ["10m"] = defines.flow_precision_index.ten_minutes,
  ["1h"] = defines.flow_precision_index.one_hour,
  ["10h"] = defines.flow_precision_index.ten_hours,
  ["50h"] = defines.flow_precision_index.fifty_hours,
  ["250h"] = defines.flow_precision_index.two_hundred_fifty_hours
}

local function production_statistics(force, surface, statistic)
  if statistic == "item" then return force.get_item_production_statistics(surface) end
  if statistic == "fluid" then return force.get_fluid_production_statistics(surface) end
  if statistic == "kill" then return force.get_kill_count_statistics(surface) end
  if statistic == "build" then return force.get_entity_build_count_statistics(surface) end
  return nil
end

function Telemetry.production(context, payload)
  if type(payload) ~= "table" or not context.surface then
    return nil, "INVALID_REQUEST", "production request requires an authorized surface"
  end
  local stats = production_statistics(context.force, context.surface, payload.statistic)
  if not stats then
    return nil, "INVALID_STATISTIC", "statistic must be item, fluid, kill, or build"
  end
  if payload.direction ~= "input" and payload.direction ~= "output" and payload.direction ~= "both" then
    return nil, "INVALID_DIRECTION", "direction must be input, output, or both"
  end
  local precision = PRECISION[payload.window]
  if payload.window ~= "total" and precision == nil then
    return nil, "INVALID_WINDOW", "statistics window is invalid"
  end
  local names, truncated, examined
  if payload.names ~= nil then
    names = {}
    if type(payload.names) ~= "table" or #payload.names > 100 then
      return nil, "INVALID_NAMES", "names must contain at most 100 prototype IDs"
    end
    local seen = {}
    for _, name in ipairs(payload.names) do
      if not valid_string(name, 200) then
        return nil, "INVALID_NAMES", "statistics names must be prototype IDs"
      end
      if not seen[name] then seen[name] = true names[#names + 1] = name end
    end
    table.sort(names)
    truncated = false
    examined = #names
  else
    local dictionaries = {}
    if payload.direction ~= "output" then
      dictionaries[#dictionaries + 1] = stats.input_counts
    end
    if payload.direction ~= "input" then
      dictionaries[#dictionaries + 1] = stats.output_counts
    end
    names, truncated, examined = bounded_names(dictionaries)
  end
  local offset, limit, code, message = page_parameters(context, payload.pagination)
  if not offset then return nil, code, message end
  local page, next_cursor, total = page_array(names, offset, limit)
  local entries = {}
  for _, name in ipairs(page) do
    local row = {name = name}
    if payload.direction ~= "output" then
      row.input = payload.window == "total"
        and stats.get_input_count(name)
        or stats.get_flow_count({name = name, category = "input", precision_index = precision})
    end
    if payload.direction ~= "input" then
      row.output = payload.window == "total"
        and stats.get_output_count(name)
        or stats.get_flow_count({name = name, category = "output", precision_index = precision})
    end
    entries[#entries + 1] = row
  end
  return {
    surfaceId = context.surface_id,
    statistic = payload.statistic,
    direction = payload.direction,
    window = payload.window,
    unit = payload.window == "total" and "count" or "per-minute",
    entries = entries,
    nextCursor = next_cursor,
    total = total,
    examined = examined,
    truncated = truncated
  }
end

function Telemetry.electric_network(context, payload)
  if type(payload) ~= "table" or not context.surface then
    return nil, "INVALID_REQUEST", "electric network request requires an authorized surface"
  end
  local entity, code, message = resolve_entity(context, payload.anchorEntityId)
  if not entity then return nil, code, message end
  local sub_network = entity.electric_network
  local network = sub_network and sub_network.valid and sub_network.parent_network or nil
  if not (network and network.valid) then
    return nil, "ELECTRIC_NETWORK_NOT_FOUND", "anchor entity is not connected to an electric network"
  end
  local network_id = entity.electric_network_id
  local opaque_id = network_id and ("electric:" .. network_id) or nil
  if payload.networkId ~= nil and payload.networkId ~= opaque_id then
    return nil, "ELECTRIC_NETWORK_MISMATCH", "anchor entity is connected to a different electric network"
  end
  local flow = network.flow_last_tick
  local names, truncated, examined = bounded_names({
    network.statistics.input_counts,
    network.statistics.output_counts,
    network.statistics.storage_counts
  })
  local offset, limit, page_code, page_message = page_parameters(context, payload.pagination)
  if not offset then return nil, page_code, page_message end
  local page, next_cursor, total = page_array(names, offset, limit)
  local entities = {}
  for _, name in ipairs(page) do
    entities[#entities + 1] = {
      name = name,
      productionJPerTick = network.statistics.get_flow_count({
        name = name,
        category = "input",
        precision_index = defines.flow_precision_index.five_seconds
      }),
      consumptionJPerTick = network.statistics.get_flow_count({
        name = name,
        category = "output",
        precision_index = defines.flow_precision_index.five_seconds
      }),
      storageJ = network.statistics.get_flow_count({
        name = name,
        category = "storage",
        precision_index = defines.flow_precision_index.five_seconds
      })
    }
  end
  return {
    surfaceId = context.surface_id,
    networkId = opaque_id,
    anchorEntityId = entity_id(entity),
    maximumProductionW = flow.maximum_production * 60,
    maximumConsumptionW = flow.maximum_consumption * 60,
    transferW = flow.total_transfer * 60,
    consumptionSatisfaction = flow.consumption_satisfaction,
    productionUtilization = flow.production_satisfaction,
    accumulatorEnergyJ = flow.accumulator_energy,
    accumulatorCapacityJ = flow.accumulator_capacity,
    entities = entities,
    nextCursor = next_cursor,
    total = total,
    examined = examined,
    truncated = truncated
  }
end

local function technology_summary(technology)
  local prerequisites = {}
  for _, prerequisite in pairs(technology.prerequisites) do
    prerequisites[#prerequisites + 1] = prerequisite.name
  end
  table.sort(prerequisites)
  return {
    name = technology.name,
    level = technology.level,
    researched = technology.researched,
    enabled = technology.enabled,
    visibleWhenDisabled = technology.visible_when_disabled,
    prerequisites = prerequisites,
    unitCount = technology.research_unit_count,
    unitEnergy = technology.research_unit_energy
  }
end

function Telemetry.research(context, payload)
  if type(payload) ~= "table" then return nil, "INVALID_REQUEST", "research payload must be an object" end
  local names, truncated, examined = bounded_names(
    {context.force.technologies},
    function(_, technology) return payload.includeCompleted or not technology.researched end
  )
  local offset, limit, code, message = page_parameters(context, payload.pagination)
  if not offset then return nil, code, message end
  local page, next_cursor, total = page_array(names, offset, limit)
  local technologies = {}
  for _, name in ipairs(page) do
    technologies[#technologies + 1] = technology_summary(context.force.technologies[name])
  end
  local queue = {}
  for index, technology in ipairs(context.force.research_queue or {}) do
    if index > 50 then break end
    queue[#queue + 1] = technology.name
  end
  local current = context.force.current_research
  return {
    current = current and {
      name = current.name,
      level = current.level,
      progress = context.force.research_progress
    } or nil,
    queue = queue,
    researchEnabled = context.force.research_enabled,
    technologies = technologies,
    nextCursor = next_cursor,
    total = total,
    examined = examined,
    truncated = truncated
  }
end

local function copy_ingredient(ingredient)
  return {
    type = ingredient.type,
    name = ingredient.name,
    amount = ingredient.amount,
    minimumTemperature = ingredient.minimum_temperature,
    maximumTemperature = ingredient.maximum_temperature,
    catalystAmount = ingredient.catalyst_amount
  }
end

local function copy_product(product)
  return {
    type = product.type,
    name = product.name,
    amount = product.amount,
    amountMin = product.amount_min,
    amountMax = product.amount_max,
    probability = product.probability,
    temperature = product.temperature,
    catalystAmount = product.catalyst_amount
  }
end

function Telemetry.recipe(context, payload)
  if type(payload) ~= "table" or not valid_string(payload.name, 200) then
    return nil, "INVALID_RECIPE", "recipe name is invalid"
  end
  local recipe = context.force.recipes[payload.name]
  if not (recipe and recipe.valid) then return nil, "RECIPE_NOT_FOUND", "recipe does not exist" end
  local ingredients = {}
  for _, ingredient in ipairs(recipe.ingredients) do ingredients[#ingredients + 1] = copy_ingredient(ingredient) end
  local products = {}
  for _, product in ipairs(recipe.products) do products[#products + 1] = copy_product(product) end
  local categories = {}
  for _, category in pairs(recipe.categories) do categories[#categories + 1] = category end
  table.sort(categories)
  return {
    name = recipe.name,
    enabled = recipe.enabled,
    hidden = recipe.hidden,
    energySeconds = recipe.energy,
    categories = categories,
    ingredients = ingredients,
    products = products,
    productivityBonus = recipe.productivity_bonus,
    maximumProductivity = recipe.prototype.maximum_productivity
  }
end

local function prototype_common(prototype, prototype_type, name)
  return {
    type = prototype_type,
    name = name,
    order = prototype.order,
    valid = prototype.valid
  }
end

local function plain_place_items(prototype)
  local result = {}
  for _, item in ipairs(prototype.items_to_place_this or {}) do
    result[#result + 1] = {name = item.name, count = item.count}
  end
  return result
end

local function pipe_connection(connection)
  local positions = {}
  for index, position in ipairs(connection.positions or {}) do
    if index > #FLUID_BOX_POSITION_ORDER then break end
    local point = copy_vector(position)
    -- A hole would silently shift the remaining cardinal points onto the wrong
    -- tiles, so one unreadable point drops the whole list instead.
    if not point then
      positions = {}
      break
    end
    positions[#positions + 1] = point
  end
  local categories = {}
  for index, category in ipairs(connection.connection_category or {}) do
    if index > MAX_CONNECTION_CATEGORIES then break end
    categories[#categories + 1] = category
  end
  return {
    connectionType = connection.connection_type,
    flowDirection = connection.flow_direction,
    direction = connection.direction,
    positions = positions,
    connectionCategories = categories,
    maxUndergroundDistance = connection.max_underground_distance,
    -- Present only on connections that carry an alternate layout; without them
    -- a client would compute the primary tile for an entity using the alt one.
    altDirection = connection.alt_direction,
    altPosition = copy_vector(connection.alt_position)
  }
end

-- Fluidbox prototypes and their pipe connections are engine-ordered arrays, so
-- the response order is deterministic without sorting.
local function fluid_boxes(prototype)
  local boxes = {}
  local truncated = false
  local connection_budget = MAX_PIPE_CONNECTIONS_TOTAL
  for index, box in ipairs(prototype.fluidbox_prototypes or {}) do
    if index > MAX_FLUID_BOXES then
      truncated = true
      break
    end
    local connections = {}
    for connection_index, connection in ipairs(box.pipe_connections or {}) do
      if connection_index > MAX_PIPE_CONNECTIONS or connection_budget <= 0 then
        truncated = true
        break
      end
      connection_budget = connection_budget - 1
      connections[#connections + 1] = pipe_connection(connection)
    end
    local filter = box.filter
    boxes[#boxes + 1] = {
      index = box.index,
      productionType = box.production_type,
      filter = filter and filter.name or nil,
      minimumTemperature = box.minimum_temperature,
      maximumTemperature = box.maximum_temperature,
      volume = safe_value(function() return box.get_volume("normal") end),
      connections = connections
    }
  end
  return boxes, truncated
end

local function inserter_geometry(prototype)
  local pickup = copy_vector(prototype.inserter_pickup_position)
  local drop = copy_vector(prototype.inserter_drop_position)
  if not pickup and not drop then return nil end
  return {
    pickupPosition = pickup,
    dropPosition = drop,
    chasesBeltItems = prototype.inserter_chases_belt_items,
    bulk = prototype.bulk,
    stackSizeBonus = prototype.inserter_stack_size_bonus,
    usesStackSizeBonus = prototype.uses_inserter_stack_size_bonus,
    maxBeltStackSize = prototype.inserter_max_belt_stack_size,
    filterCount = prototype.filter_count,
    rotationSpeedPerTick = safe_value(function() return prototype.get_inserter_rotation_speed("normal") end),
    extensionSpeedPerTick = safe_value(function() return prototype.get_inserter_extension_speed("normal") end)
  }
end

-- Sorted so a set-valued prototype member (allowed module categories, crafting
-- categories) reaches the client in a stable order.
local function bounded_categories(dictionary, maximum)
  if type(dictionary) ~= "table" then return nil, nil end
  local keys = sorted_keys(dictionary)
  local result = {}
  for index, key in ipairs(keys) do
    if index > maximum then break end
    result[#result + 1] = key
  end
  return result, #keys > maximum
end

-- The blueprint validator reads prototype.allowed_effects and blocks a module
-- whose positive effect is not truthy there, so the same dictionary is the
-- fact a client needs before it lays out a modded machine. An effect missing
-- from this list is disallowed, exactly as the validator treats it.
local function module_effects(prototype)
  local allowed = prototype.allowed_effects
  if type(allowed) ~= "table" then return nil, nil end
  local names, truncated = bounded_categories(allowed, MAX_MODULE_EFFECTS)
  local effects = {}
  for _, name in ipairs(names) do
    effects[#effects + 1] = {name = name, allowed = allowed[name] and true or false}
  end
  return effects, truncated
end

function Telemetry.prototype(context, payload)
  if type(payload) ~= "table" or not valid_string(payload.name, 200) then
    return nil, "INVALID_PROTOTYPE", "prototype request is invalid"
  end
  local collection = prototypes[payload.type]
  local prototype = collection and collection[payload.name]
  if not prototype then return nil, "PROTOTYPE_NOT_FOUND", "prototype does not exist" end
  local result = prototype_common(prototype, payload.type, payload.name)
  if payload.type == "entity" then
    result.entityType = prototype.type
    result.tileWidth = prototype.tile_width
    result.tileHeight = prototype.tile_height
    result.beltSpeedTilesPerTick = safe_value(function() return prototype.belt_speed end)
    result.maxUndergroundDistance = safe_value(function() return prototype.max_underground_distance end)
    result.craftingSpeed = safe_value(function() return prototype.crafting_speed end)
    result.energyUsageW = prototype.get_max_energy_usage("normal")
    result.energyProductionW = prototype.get_max_energy_production("normal")
    result.fluidCapacity = prototype.get_fluid_capacity("normal")
    result.placeItems = plain_place_items(prototype)
    result.fluidBoxes, result.fluidBoxesTruncated = safe_value(function() return fluid_boxes(prototype) end)
    if result.fluidBoxes and #result.fluidBoxes > 0 then
      result.fluidBoxPositionOrder = {}
      for _, cardinal in ipairs(FLUID_BOX_POSITION_ORDER) do
        result.fluidBoxPositionOrder[#result.fluidBoxPositionOrder + 1] = cardinal
      end
    end
    result.inserter = safe_value(function() return inserter_geometry(prototype) end)
    result.moduleInventorySize = safe_value(function() return prototype.module_inventory_size end)
    result.allowedModuleCategories, result.allowedModuleCategoriesTruncated = safe_value(function()
      return bounded_categories(prototype.allowed_module_categories, MAX_PROTOTYPE_CATEGORIES)
    end)
    result.allowedEffects, result.allowedEffectsTruncated = safe_value(function()
      return module_effects(prototype)
    end)
    result.craftingCategories, result.craftingCategoriesTruncated = safe_value(function()
      return bounded_categories(prototype.crafting_categories, MAX_PROTOTYPE_CATEGORIES)
    end)
  elseif payload.type == "item" then
    result.stackSize = prototype.stack_size
    result.weight = prototype.weight
    result.fuelValueJ = prototype.fuel_value
    result.placeResult = prototype.place_result and prototype.place_result.name or nil
  elseif payload.type == "fluid" then
    result.defaultTemperature = prototype.default_temperature
    result.maxTemperature = prototype.max_temperature
    result.heatCapacityJ = prototype.heat_capacity
    result.fuelValueJ = prototype.fuel_value
  elseif payload.type == "recipe" then
    return Telemetry.recipe(context, payload)
  elseif payload.type == "technology" then
    local technology = context.force.technologies[payload.name]
    if not technology then return nil, "PROTOTYPE_NOT_FOUND", "technology does not exist for this force" end
    return technology_summary(technology)
  elseif payload.type == "tile" then
    result.walkingSpeedModifier = prototype.walking_speed_modifier
    result.vehicleFrictionModifier = prototype.vehicle_friction_modifier
    result.weight = prototype.weight
    result.blueprintable = prototype.can_be_part_of_blueprint
  elseif payload.type == "quality" then
    result.level = prototype.level
    result.next = prototype.next and prototype.next.name or nil
    result.defaultMultiplier = prototype.default_multiplier
  else
    return nil, "INVALID_PROTOTYPE_TYPE", "prototype type is not supported"
  end
  return result
end

local TRANSPORT_TYPES = {
  ["transport-belt"] = true,
  ["underground-belt"] = true,
  splitter = true,
  loader = true,
  ["loader-1x1"] = true,
  inserter = true,
  pipe = true,
  ["pipe-to-ground"] = true,
  pump = true,
  ["offshore-pump"] = true,
  ["cargo-wagon"] = true,
  ["fluid-wagon"] = true
}

local function unlocked_item_outputs(force)
  local unlocked = {}
  local examined = 0
  local truncated = false
  for _, recipe in pairs(force.recipes) do
    if examined >= MAX_SCAN_RESULTS then
      truncated = true
      break
    end
    examined = examined + 1
    if recipe.enabled then
      for _, product in ipairs(recipe.products) do
        if product.type == "item" then unlocked[product.name] = true end
      end
    end
  end
  return unlocked, truncated, examined
end

local function first_place_item(prototype)
  local item = prototype.items_to_place_this and prototype.items_to_place_this[1] or nil
  return item and item.name or nil
end

local function inventory_size(prototype, inventory_index, quality)
  local ok, value = pcall(function() return prototype.get_inventory_size(inventory_index, quality) end)
  return ok and value or nil
end

function Telemetry.transport_capacities(context, payload)
  if type(payload) ~= "table" then return nil, "INVALID_REQUEST", "transport payload must be an object" end
  local quality = payload.quality or "normal"
  if not prototypes.quality[quality] then return nil, "UNKNOWN_QUALITY", "quality prototype does not exist" end
  local unlocked, recipe_scan_truncated, recipes_examined = unlocked_item_outputs(context.force)
  local names, prototype_scan_truncated, prototypes_examined = bounded_names(
    {prototypes.entity},
    function(_, prototype)
      if not TRANSPORT_TYPES[prototype.type] then return false end
      local item = first_place_item(prototype)
      return payload.includeLocked or item == nil or unlocked[item] or recipe_scan_truncated
    end
  )
  local offset, limit, code, message = page_parameters(context, payload.pagination)
  if not offset then return nil, code, message end
  local page, next_cursor, total = page_array(names, offset, limit)
  local capacities = {}
  for _, name in ipairs(page) do
    local prototype = prototypes.entity[name]
    local place_item = first_place_item(prototype)
    local is_unlocked = place_item == nil or unlocked[place_item] == true
    local unlock_known = is_unlocked or not recipe_scan_truncated
    local entry = {
      name = name,
      type = prototype.type,
      quality = quality,
      unlocked = is_unlocked,
      unlockKnown = unlock_known,
      placeItem = place_item,
      beltSpeedTilesPerTick = safe_value(function() return prototype.belt_speed end),
      maxUndergroundDistance = safe_value(function() return prototype.max_underground_distance end),
      fluidCapacity = prototype.get_fluid_capacity(quality),
      pumpingSpeedPerTick = (prototype.type == "pump" or prototype.type == "offshore-pump")
        and prototype.get_pumping_speed(quality) or nil,
      inserterRotationPerTick = prototype.type == "inserter"
        and prototype.get_inserter_rotation_speed(quality) or nil,
      inserterExtensionPerTick = prototype.type == "inserter"
        and prototype.get_inserter_extension_speed(quality) or nil,
      cargoInventorySlots = prototype.type == "cargo-wagon"
        and inventory_size(prototype, defines.inventory.cargo_wagon, quality) or nil
    }
    if entry.beltSpeedTilesPerTick then
      entry.beltItemsPerSecond = entry.beltSpeedTilesPerTick * 480
    end
    capacities[#capacities + 1] = entry
  end
  return {
    capacities = capacities,
    nextCursor = next_cursor,
    total = total,
    recipesExamined = recipes_examined,
    prototypesExamined = prototypes_examined,
    truncated = recipe_scan_truncated or prototype_scan_truncated
  }
end

function Telemetry.unlocked_technologies(context, payload)
  if type(payload) ~= "table" then return nil, "INVALID_REQUEST", "technology payload must be an object" end
  local names, truncated, examined = bounded_names(
    {context.force.technologies},
    function(_, technology) return technology.researched end
  )
  local offset, limit, code, message = page_parameters(context, payload.pagination)
  if not offset then return nil, code, message end
  local page, next_cursor, total = page_array(names, offset, limit)
  return {
    technologies = page,
    nextCursor = next_cursor,
    total = total,
    examined = examined,
    truncated = truncated
  }
end

local function valid_area(area)
  if type(area) ~= "table" or type(area.leftTop) ~= "table" or type(area.rightBottom) ~= "table" then
    return nil
  end
  local left, right = area.leftTop, area.rightBottom
  if not finite(left.x) or not finite(left.y) or not finite(right.x) or not finite(right.y) then return nil end
  local width, height = right.x - left.x, right.y - left.y
  if width <= 0 or height <= 0 or width > 1024 or height > 1024 then return nil end
  return {{left.x, left.y}, {right.x, right.y}}
end

local function requested_statuses(statuses)
  if statuses == nil then return nil end
  if type(statuses) ~= "table" or #statuses > 50 then return false end
  local result = {}
  for _, status in ipairs(statuses) do
    if not valid_string(status, 200) then return false end
    result[status] = true
  end
  return result
end

function Telemetry.query_entities(context, payload)
  if type(payload) ~= "table" or not context.surface then
    return nil, "INVALID_REQUEST", "entity query requires an authorized surface"
  end
  local area = valid_area(payload.area)
  if not area then return nil, "INVALID_AREA", "area must be finite and no larger than 1024 by 1024 tiles" end
  if payload.names ~= nil and (type(payload.names) ~= "table" or #payload.names > 100) then
    return nil, "INVALID_NAMES", "entity names must contain at most 100 entries"
  end
  if payload.types ~= nil and (type(payload.types) ~= "table" or #payload.types > 50) then
    return nil, "INVALID_TYPES", "entity types must contain at most 50 entries"
  end
  local statuses = requested_statuses(payload.statuses)
  if statuses == false then return nil, "INVALID_STATUSES", "entity statuses are invalid" end
  local offset, limit, code, message = page_parameters(context, payload.pagination)
  if not offset then return nil, code, message end
  local scan_limit = MAX_SCAN_RESULTS
  local filter = {area = area, force = context.force, limit = scan_limit}
  if payload.names ~= nil then filter.name = payload.names end
  if payload.types ~= nil then filter.type = payload.types end
  local found = context.surface.find_entities_filtered(filter)
  local entities = {}
  for _, entity in ipairs(found) do
    local opaque_id = entity_id(entity)
    local name = status_name(entity.status)
    if opaque_id then Telemetry.index_entity(entity) end
    if opaque_id and (not statuses or statuses[name]) then entities[#entities + 1] = entity end
  end
  table.sort(entities, function(first, second) return first.unit_number < second.unit_number end)
  local summaries = {}
  local last = math.min(#entities, offset + limit)
  for index = offset + 1, last do summaries[#summaries + 1] = entity_summary(entities[index]) end
  local truncated = #found >= scan_limit
  return {
    surfaceId = context.surface_id,
    entities = summaries,
    nextCursor = last < #entities and ("offset:" .. last) or nil,
    scanned = #found,
    truncated = truncated,
    truncationReason = truncated and "candidate-limit-reached" or nil
  }
end

local function inventory_contents(entity)
  local inventories = {}
  local seen = {}
  for index, name in pairs(INVENTORY_NAME) do
    if not seen[index] then
      seen[index] = true
      local ok, inventory = pcall(function() return entity.get_inventory(index) end)
      if ok and inventory and inventory.valid and not inventory.is_empty() then
        local contents = inventory.get_contents()
        local items = {}
        for item_index, item in ipairs(contents) do
          if item_index > MAX_INVENTORY_TYPES then break end
          items[#items + 1] = {name = item.name, quality = item.quality, count = item.count}
        end
        inventories[#inventories + 1] = {
          name = name,
          size = #inventory,
          itemTypes = items,
          truncated = #contents > MAX_INVENTORY_TYPES
        }
      end
    end
  end
  table.sort(inventories, function(first, second) return first.name < second.name end)
  return inventories
end

local function fluid_contents(entity)
  local result = {}
  local count = 0
  for name, amount in pairs(entity.get_fluid_contents()) do
    count = count + 1
    if count <= MAX_INVENTORY_TYPES then result[#result + 1] = {name = name, amount = amount} end
  end
  table.sort(result, function(first, second) return first.name < second.name end)
  return result, count > MAX_INVENTORY_TYPES
end

function Telemetry.inspect_entity(context, payload)
  if type(payload) ~= "table" then return nil, "INVALID_REQUEST", "entity inspection payload must be an object" end
  local entity, code, message = resolve_entity(context, payload.entityId)
  if not entity then return nil, code, message end
  local result = entity_summary(entity)
  result.inventories = inventory_contents(entity)
  result.fluids, result.fluidsTruncated = fluid_contents(entity)
  result.craftingProgress = safe_value(function() return entity.crafting_progress end)
  result.productsFinished = safe_value(function() return entity.products_finished end)
  result.powerProductionW = safe_value(function() return entity.power_production end)
  result.powerUsageW = safe_value(function() return entity.power_usage end)
  result.pollutionBonus = entity.pollution_bonus
  return result
end

local function resolve_logistic_network(context, payload)
  if payload.networkId ~= nil then
    local id = type(payload.networkId) == "string" and tonumber(string.match(payload.networkId, "^logistic:(%d+)$")) or nil
    if not id then return nil, "INVALID_LOGISTIC_NETWORK_ID", "logistic network ID is invalid" end
    for _, network in pairs(context.force.logistic_networks[context.surface.name] or {}) do
      if network.valid and network.network_id == id then return network end
    end
    return nil, "LOGISTIC_NETWORK_NOT_FOUND", "logistic network does not exist on this surface"
  end
  if type(payload.anchorPosition) ~= "table"
    or not finite(payload.anchorPosition.x) or not finite(payload.anchorPosition.y) then
    return nil, "INVALID_ANCHOR", "anchor position is invalid"
  end
  local network = context.force.find_logistic_network_by_position(payload.anchorPosition, context.surface)
  if not network then return nil, "LOGISTIC_NETWORK_NOT_FOUND", "no logistic network covers this position" end
  return network
end

function Telemetry.logistic_network(context, payload)
  if type(payload) ~= "table" or not context.surface then
    return nil, "INVALID_REQUEST", "logistic network request requires an authorized surface"
  end
  local network, code, message = resolve_logistic_network(context, payload)
  if not network then return nil, code, message end
  local contents = payload.includeContents == false and {} or network.get_contents()
  table.sort(contents, function(first, second)
    if first.name == second.name then return first.quality < second.quality end
    return first.name < second.name
  end)
  local offset, limit, page_code, page_message = page_parameters(context, payload.pagination)
  if not offset then return nil, page_code, page_message end
  local page, next_cursor, total = page_array(contents, offset, limit)
  local item_types = {}
  for _, item in ipairs(page) do
    item_types[#item_types + 1] = {name = item.name, quality = item.quality, count = item.count}
  end
  local cells = {}
  for index, cell in ipairs(network.cells) do
    if index > 50 then break end
    local owner = cell.owner
    cells[#cells + 1] = {
      ownerEntityId = owner and owner.valid and entity_id(owner) or nil,
      position = owner and owner.valid and copy_position(owner.position) or nil,
      logisticRadius = cell.logistic_radius,
      constructionRadius = cell.construction_radius,
      charging = cell.charging_robot_count,
      waitingToCharge = cell.to_charge_robot_count
    }
  end
  return {
    surfaceId = context.surface_id,
    networkId = "logistic:" .. network.network_id,
    customName = network.custom_name,
    logisticRobots = network.all_logistic_robots,
    availableLogisticRobots = network.available_logistic_robots,
    constructionRobots = network.all_construction_robots,
    availableConstructionRobots = network.available_construction_robots,
    robotLimit = network.robot_limit,
    cells = cells,
    cellsTruncated = #network.cells > 50,
    contents = item_types,
    nextCursor = next_cursor,
    totalItemTypes = total
  }
end

local function train_station_name(train)
  return train.station and train.station.valid and train.station.backer_name or nil
end

local function train_schedule(train)
  local schedule = train.schedule
  if not schedule then return nil end
  local stations = {}
  for index, record in ipairs(schedule.records) do
    if index > 50 then break end
    stations[#stations + 1] = {
      station = record.station,
      temporary = record.temporary,
      allowsUnloading = record.allows_unloading
    }
  end
  return {current = schedule.current, records = stations, truncated = #schedule.records > 50}
end

local function canonical_surface_id(context, surface)
  return surface and context.surface_ids_by_index
    and context.surface_ids_by_index[surface.index]
    or nil
end

function Telemetry.trains(context, payload)
  if type(payload) ~= "table" then return nil, "INVALID_REQUEST", "train payload must be an object" end
  local filter = {force = context.force}
  if context.surface then filter.surface = context.surface end
  local trains = game.train_manager.get_trains(filter)
  local state_filter
  if payload.states ~= nil then
    if type(payload.states) ~= "table" or #payload.states > 30 then return nil, "INVALID_STATES", "train states are invalid" end
    state_filter = {}
    for _, state in ipairs(payload.states) do state_filter[state] = true end
  end
  local filtered = {}
  local examined = 0
  for _, train in ipairs(trains) do
    if examined >= MAX_SCAN_RESULTS then break end
    examined = examined + 1
    local state = TRAIN_STATE_NAME[train.state] or tostring(train.state)
    local station = train_station_name(train)
    local train_surface = train.front_stock and train.front_stock.valid and train.front_stock.surface or nil
    if canonical_surface_id(context, train_surface)
      and (not state_filter or state_filter[state])
      and (payload.stationName == nil or station == payload.stationName) then
      filtered[#filtered + 1] = train
    end
  end
  table.sort(filtered, function(first, second) return first.id < second.id end)
  local offset, limit, code, message = page_parameters(context, payload.pagination)
  if not offset then return nil, code, message end
  local page, next_cursor, total = page_array(filtered, offset, limit)
  local result = {}
  for _, train in ipairs(page) do
    local surface = train.front_stock and train.front_stock.valid and train.front_stock.surface or nil
    result[#result + 1] = {
      trainId = "train:" .. train.id,
      state = TRAIN_STATE_NAME[train.state] or tostring(train.state),
      manualMode = train.manual_mode,
      speed = train.speed,
      weight = train.weight,
      hasPath = train.has_path,
      station = train_station_name(train),
      surfaceId = canonical_surface_id(context, surface),
      carriageCount = #train.carriages,
      locomotiveCount = #train.locomotives.front_movers + #train.locomotives.back_movers,
      cargoWagonCount = #train.cargo_wagons,
      fluidWagonCount = #train.fluid_wagons,
      schedule = train_schedule(train)
    }
  end
  return {
    trains = result,
    nextCursor = next_cursor,
    total = total,
    examined = examined,
    truncated = #trains > examined
  }
end

function Telemetry.alerts(context, payload)
  if type(payload) ~= "table" then return nil, "INVALID_REQUEST", "Alert payload must be an object" end
  if not (context.player and context.player.valid) then
    return {alerts = {}, nextCursor = nil, total = 0, playerUnavailable = true}
  end
  local requested_types
  if payload.types ~= nil then
    if type(payload.types) ~= "table" or #payload.types > 50 then
      return nil, "INVALID_ALERT_TYPES", "Alert types must contain at most 50 names"
    end
    requested_types = {}
    for _, name in ipairs(payload.types) do
      if type(name) ~= "string" or #name < 1 or #name > 200 then
        return nil, "INVALID_ALERT_TYPES", "Alert type name is invalid"
      end
      requested_types[name] = true
    end
  end
  local native_filter = {}
  if context.surface then native_filter.surface = context.surface end
  local all = context.player.get_alerts(native_filter)
  local rows = {}
  local examined = 0
  local truncated = false
  for surface_index, by_type in pairs(all) do
    local surface_id = context.surface_ids_by_index[surface_index]
    if surface_id and (not context.surface_id or context.surface_id == surface_id) then
      for alert_type, alerts in pairs(by_type) do
        local type_name = ALERT_TYPE_NAME[alert_type] or tostring(alert_type)
        if not requested_types or requested_types[type_name] then
          for _, alert in ipairs(alerts) do
            if examined >= MAX_SCAN_RESULTS or #rows >= MAX_SCAN_RESULTS then
              truncated = true
              break
            end
            examined = examined + 1
            if payload.sinceTick == nil or alert.tick >= payload.sinceTick then
              local target = alert.target
              local icon = alert.icon
              rows[#rows + 1] = {
                tick = alert.tick,
                type = type_name,
                surfaceId = surface_id,
                position = alert.position and copy_position(alert.position) or nil,
                targetEntityId = target and target.valid and entity_id(target) or nil,
                prototype = alert.prototype and alert.prototype.name or nil,
                icon = icon and {
                  type = icon.type or "item",
                  name = icon.name,
                  quality = icon.quality
                } or nil,
                hasCustomMessage = alert.message ~= nil
              }
            end
          end
        end
        if truncated then break end
      end
    end
    if truncated then break end
  end
  table.sort(rows, function(first, second)
    if first.tick == second.tick then return first.type < second.type end
    return first.tick < second.tick
  end)
  local offset, limit, code, message = page_parameters(context, payload.pagination)
  if not offset then return nil, code, message end
  local page, next_cursor, total = page_array(rows, offset, limit)
  return {
    alerts = page,
    nextCursor = next_cursor,
    total = total,
    examined = examined,
    truncated = truncated
  }
end

local function chunk_area(x, y)
  return {{x * 32, y * 32}, {(x + 1) * 32, (y + 1) * 32}}
end

local function visible_resources(surface, area)
  local counts = {}
  local found = surface.find_entities_filtered({area = area, type = "resource", limit = 200})
  for _, resource in ipairs(found) do
    counts[resource.name] = (counts[resource.name] or 0) + (resource.amount or 0)
  end
  local result = {}
  for _, name in ipairs(sorted_keys(counts)) do result[#result + 1] = {name = name, amount = counts[name]} end
  return result, #found >= 200
end

local function visible_enemies(force, surface, area)
  local counts = {}
  local entities = surface.find_entities_filtered({
    area = area,
    type = {"unit", "unit-spawner", "turret"},
    limit = 200
  })
  for _, entity in ipairs(entities) do
    if force.is_enemy(entity.force) then counts[entity.name] = (counts[entity.name] or 0) + 1 end
  end
  local result = {}
  for _, name in ipairs(sorted_keys(counts)) do result[#result + 1] = {name = name, count = counts[name]} end
  return result, #entities >= 200
end

function Telemetry.charted_chunks(context, payload)
  if type(payload) ~= "table" or not context.surface then
    return nil, "INVALID_REQUEST", "charted chunks request requires an authorized surface"
  end
  local area = valid_area(payload.area)
  if not area then return nil, "INVALID_AREA", "charted chunk area must be finite and no larger than 1024 by 1024 tiles" end
  local left_x, left_y = math.floor(area[1][1] / 32), math.floor(area[1][2] / 32)
  local right_x = math.ceil(area[2][1] / 32) - 1
  local right_y = math.ceil(area[2][2] / 32) - 1
  local coordinates = {}
  for y = left_y, right_y do
    for x = left_x, right_x do coordinates[#coordinates + 1] = {x = x, y = y} end
  end
  local offset, limit, code, message = page_parameters(context, payload.pagination, 2048)
  if not offset then return nil, code, message end
  local page, next_cursor, total = page_array(coordinates, offset, limit)
  local chunks = {}
  for _, position in ipairs(page) do
    local charted = context.force.is_chunk_charted(context.surface, position)
    local visible = charted and context.force.is_chunk_visible(context.surface, position) or false
    local result = {position = position, charted = charted, visible = visible}
    if visible then
      local bounds = chunk_area(position.x, position.y)
      if payload.includeKnownResources ~= false then
        result.knownResources, result.resourcesTruncated = visible_resources(context.surface, bounds)
      end
      if payload.includeVisibleEnemies == true then
        result.visibleEnemies, result.enemiesTruncated = visible_enemies(context.force, context.surface, bounds)
      end
    elseif charted and payload.includeKnownResources ~= false then
      result.knownResources = {}
      result.resourceDetail = "withheld-unless-currently-visible"
    end
    chunks[#chunks + 1] = result
  end
  return {surfaceId = context.surface_id, chunks = chunks, nextCursor = next_cursor, total = total}
end

return Telemetry
