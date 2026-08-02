local State = require("src.core.state")

local Blueprints = {}

-- Entity and tile counts are shape bounds; the binding constraint is the 48 KiB
-- gateway request datagram (AiConstants.MAX_DATAGRAM_BYTES). A measured plain
-- entity costs ~98 JSON bytes and a tile ~58, so the historical 512/2048 pair
-- needed 172 KiB and could never reach Factorio at all. MAX_LAYOUT_BYTES is the
-- real guarantee: 44 KiB of canonical layout JSON leaves over 2 KiB of headroom
-- for the largest possible request envelope inside one datagram.
local MAX_ENTITIES = 400
local MAX_TILES = 512
local MAX_LAYOUT_BYTES = 44 * 1024
-- Records saved before the authoring bound tightened stay readable: migration
-- must never delete a blueprint that was legal when it was stored, so the
-- persistence ceiling keeps the historical maximum and the per-player byte
-- budget remains the bound that actually protects the save file.
local MAX_STORED_ENTITIES = 512
local MAX_BLUEPRINTS_PER_PLAYER = 100
local MAX_BLUEPRINT_BYTES_PER_PLAYER = 512 * 1024
-- A book stores no layout at all: it is an ordered list of IDs of blueprints
-- this same player already saved. That is why it pays into neither the 100
-- record count nor the 512 KiB byte budget -- charging a book against them
-- would let a grouping evict the very blueprints it points at. Its own two
-- caps are what bound it: at most 20 books, each naming at most 50 members, so
-- the whole book collection of one player cannot exceed a few KiB.
local MAX_BOOKS_PER_PLAYER = 20
local MAX_BOOK_MEMBERS = 50
local BOOK_ID_PREFIX = "book:"
local BLUEPRINT_INBOX_SCHEMA_VERSION = 4
local MAX_ISSUES = 100

local MAX_MODULE_KINDS = 8
local MAX_MODULE_COUNT = 100
local MAX_FILTERS = 32
local MAX_REQUEST_FILTERS = 40
local MAX_SECTIONS = 8
local MAX_SECTION_FILTERS = 40
local MAX_DECIDER_CONDITIONS = 16
local MAX_DECIDER_OUTPUTS = 16
local INT32_MIN = -2147483648
local INT32_MAX = 2147483647

local function ai_root()
  local root = State.get()
  root.ai = root.ai or {}
  root.ai.blueprint_inbox = root.ai.blueprint_inbox or {}
  root.ai.next_blueprint_id = root.ai.next_blueprint_id or 1
  return root.ai
end

local function add_issue(target, code, path, message)
  if #target >= MAX_ISSUES then return end
  target[#target + 1] = {code = code, path = path, message = message}
end

local function finite(value)
  return type(value) == "number"
    and value == value
    and value > -math.huge
    and value < math.huge
end

local function integer(value, minimum, maximum)
  return finite(value)
    and value == math.floor(value)
    and value >= minimum
    and value <= maximum
end

local function valid_string(value, maximum)
  return type(value) == "string" and #value > 0 and #value <= maximum
end

local function clone_plain(value, depth)
  if type(value) ~= "table" then return value end
  if depth > 12 then return nil end
  local result = {}
  for key, child in pairs(value) do
    if type(key) == "string" or type(key) == "number" then
      result[key] = clone_plain(child, depth + 1)
    end
  end
  return result
end

-- The documented safe-layout whitelist. Every persisted key is declared here
-- once and copied field by field; `copy_shape` never walks a table it was not
-- told about, so unknown JSON keys are dropped instead of becoming an unbounded
-- side channel into the save file. Validation still tolerates unknown keys for
-- forward compatibility. Adding a field means adding it here, to the matching
-- validator, and to the blueprint emitter.
local SIGNAL_SHAPE = {scalars = {"type", "name", "quality"}}

local CONDITION_SHAPE = {
  scalars = {"comparator", "constant"},
  objects = {firstSignal = SIGNAL_SHAPE, secondSignal = SIGNAL_SHAPE}
}

local ARITHMETIC_SHAPE = {
  scalars = {"operation", "firstConstant", "secondConstant"},
  objects = {
    firstSignal = SIGNAL_SHAPE,
    secondSignal = SIGNAL_SHAPE,
    outputSignal = SIGNAL_SHAPE
  }
}

local DECIDER_SHAPE = {
  arrays = {
    conditions = {
      max = MAX_DECIDER_CONDITIONS,
      shape = {
        scalars = {"comparator", "constant", "compareType"},
        objects = {firstSignal = SIGNAL_SHAPE, secondSignal = SIGNAL_SHAPE}
      }
    },
    outputs = {
      max = MAX_DECIDER_OUTPUTS,
      shape = {
        scalars = {"constant", "copyCountFromInput"},
        objects = {signal = SIGNAL_SHAPE}
      }
    }
  }
}

local SECTION_SHAPE = {
  scalars = {"active"},
  arrays = {
    filters = {
      max = MAX_SECTION_FILTERS,
      shape = {scalars = {"type", "name", "quality", "count"}}
    }
  }
}

local CONTROL_SHAPE = {
  scalars = {
    "circuitEnabled",
    "connectToLogisticNetwork",
    "readContents",
    "readMode",
    "readIngredients",
    "readWorking",
    "setRecipe",
    "setFilters",
    "setStackSize",
    "setRequests"
  },
  objects = {
    enabledCondition = CONDITION_SHAPE,
    logisticCondition = CONDITION_SHAPE,
    workingSignal = SIGNAL_SHAPE,
    stackSizeSignal = SIGNAL_SHAPE,
    arithmetic = ARITHMETIC_SHAPE,
    decider = DECIDER_SHAPE
  },
  arrays = {sections = {max = MAX_SECTIONS, shape = SECTION_SHAPE}}
}

local ENTITY_EXTRA_SHAPE = {
  scalars = {"filterMode", "inputPriority", "outputPriority", "requestFromBuffers"},
  counts = {items = {max = MAX_MODULE_KINDS}},
  objects = {control = CONTROL_SHAPE},
  arrays = {
    filters = {max = MAX_FILTERS, shape = {scalars = {"name", "quality"}}},
    requestFilters = {
      max = MAX_REQUEST_FILTERS,
      shape = {scalars = {"name", "quality", "min", "max"}}
    }
  }
}

local function copy_shape(source, shape)
  if type(source) ~= "table" then return nil end
  local result = {}
  local present = false
  for _, key in ipairs(shape.scalars or {}) do
    local value = source[key]
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then
      result[key] = value
      present = true
    end
  end
  for key, nested in pairs(shape.objects or {}) do
    local child = copy_shape(source[key], nested)
    if child ~= nil then
      result[key] = child
      present = true
    end
  end
  for key, spec in pairs(shape.arrays or {}) do
    local list = source[key]
    if type(list) == "table" then
      local copied = {}
      for index, item in ipairs(list) do
        if index > spec.max then break end
        copied[#copied + 1] = copy_shape(item, spec.shape) or {}
      end
      if #copied > 0 then
        result[key] = copied
        present = true
      end
    end
  end
  for key, spec in pairs(shape.counts or {}) do
    local map = source[key]
    if type(map) == "table" then
      local copied = {}
      local kinds = 0
      for name, count in pairs(map) do
        if type(name) == "string" and type(count) == "number" and kinds < spec.max then
          copied[name] = count
          kinds = kinds + 1
        end
      end
      if kinds > 0 then
        result[key] = copied
        present = true
      end
    end
  end
  if not present then return nil end
  return result
end

local function canonical_layout(layout)
  local canonical = {
    name = layout.name,
    entities = {}
  }
  if layout.description ~= nil then canonical.description = layout.description end
  for _, source in ipairs(layout.entities) do
    local entity = {
      entityNumber = source.entityNumber,
      prototype = source.prototype,
      position = {x = source.position.x, y = source.position.y}
    }
    if source.direction ~= nil then entity.direction = source.direction end
    if source.quality ~= nil then entity.quality = source.quality end
    if source.recipe ~= nil then entity.recipe = source.recipe end
    if type(source.connections) == "table" and #source.connections > 0 then
      entity.connections = {}
      for _, source_connection in ipairs(source.connections) do
        local connection = {
          toEntityNumber = source_connection.toEntityNumber,
          wire = source_connection.wire
        }
        if source_connection.fromConnectorId ~= nil then
          connection.fromConnectorId = source_connection.fromConnectorId
        end
        if source_connection.toConnectorId ~= nil then
          connection.toConnectorId = source_connection.toConnectorId
        end
        entity.connections[#entity.connections + 1] = connection
      end
    end
    local extras = copy_shape(source, ENTITY_EXTRA_SHAPE)
    if extras then
      for key, value in pairs(extras) do entity[key] = value end
    end
    canonical.entities[#canonical.entities + 1] = entity
  end
  if type(layout.tiles) == "table" and #layout.tiles > 0 then
    canonical.tiles = {}
    for _, source in ipairs(layout.tiles) do
      canonical.tiles[#canonical.tiles + 1] = {
        prototype = source.prototype,
        position = {x = source.position.x, y = source.position.y}
      }
    end
  end
  if type(layout.expectedOutputs) == "table" and #layout.expectedOutputs > 0 then
    canonical.expectedOutputs = {}
    for _, source in ipairs(layout.expectedOutputs) do
      canonical.expectedOutputs[#canonical.expectedOutputs + 1] = {
        type = source.type,
        name = source.name,
        perSecond = source.perSecond
      }
    end
  end
  return canonical
end

local function position_of(value)
  if type(value) ~= "table" or not finite(value.x) or not finite(value.y) then
    return nil
  end
  return {x = value.x, y = value.y}
end

local function is_nonempty_table(value)
  return type(value) == "table" and next(value) ~= nil
end

local function item_cost_for(prototype, build_cost)
  local items = prototype.items_to_place_this
  local first = items and items[1] or nil
  if not first then return end
  build_cost[first.name] = (build_cost[first.name] or 0) + first.count
end

local function validate_recipe(entity, prototype, force, errors, path)
  if entity.recipe == nil then return end
  if not valid_string(entity.recipe, 200) then
    add_issue(errors, "INVALID_RECIPE", path .. ".recipe", "recipe must be a valid prototype name")
    return
  end
  local recipe = force.recipes[entity.recipe]
  if not (recipe and recipe.valid) then
    add_issue(errors, "UNKNOWN_RECIPE", path .. ".recipe", "recipe does not exist for this force")
    return
  end
  if not recipe.enabled then
    add_issue(errors, "LOCKED_RECIPE", path .. ".recipe", "recipe has not been unlocked by this force")
  end
  local categories = prototype.crafting_categories
  local supported = false
  if categories then
    for _, category in pairs(recipe.categories) do
      if categories[category] then
        supported = true
        break
      end
    end
  end
  if not supported then
    add_issue(errors, "RECIPE_CATEGORY_MISMATCH", path .. ".recipe", "entity cannot craft this recipe category")
  end
end

local function validate_connections(entity, known_numbers, errors, path)
  if entity.connections == nil then return end
  if type(entity.connections) ~= "table" or #entity.connections > 64 then
    add_issue(errors, "INVALID_CONNECTIONS", path .. ".connections", "connections must contain at most 64 entries")
    return
  end
  for index, connection in ipairs(entity.connections) do
    local connection_path = path .. ".connections[" .. index .. "]"
    if type(connection) ~= "table" then
      add_issue(errors, "INVALID_CONNECTION", connection_path, "connection must be an object")
    else
      if not integer(connection.toEntityNumber, 1, 4294967295)
        or not known_numbers[connection.toEntityNumber] then
        add_issue(errors, "DANGLING_CONNECTION", connection_path .. ".toEntityNumber", "target entity is not in this layout")
      end
      if connection.wire ~= "red" and connection.wire ~= "green" and connection.wire ~= "copper" then
        add_issue(errors, "INVALID_WIRE", connection_path .. ".wire", "wire must be red, green, or copper")
      end
      if connection.fromConnectorId ~= nil
        and not integer(connection.fromConnectorId, 0, 8) then
        add_issue(errors, "INVALID_CONNECTOR", connection_path .. ".fromConnectorId", "connector ID is outside the Factorio 2.1 range")
      end
      if connection.toConnectorId ~= nil
        and not integer(connection.toConnectorId, 0, 8) then
        add_issue(errors, "INVALID_CONNECTOR", connection_path .. ".toConnectorId", "connector ID is outside the Factorio 2.1 range")
      end
    end
  end
end

-- Module slots live in a different inventory per machine family. Factorio 2.1
-- collapsed every crafting machine onto defines.inventory.crafter_modules; an
-- entity family absent from this table is rejected rather than guessed at.
local MODULE_INVENTORY = {
  ["assembling-machine"] = "crafter_modules",
  ["furnace"] = "crafter_modules",
  ["rocket-silo"] = "crafter_modules",
  ["lab"] = "lab_modules",
  ["mining-drill"] = "mining_drill_modules",
  ["beacon"] = "beacon_modules",
  ["agricultural-tower"] = "agricultural_tower_modules"
}

local FILTER_KIND = {
  ["inserter"] = "slots",
  ["loader"] = "slots",
  ["loader-1x1"] = "slots",
  ["mining-drill"] = "drill",
  ["splitter"] = "single",
  ["lane-splitter"] = "single"
}

local FILTER_MODES = {
  ["inserter"] = {whitelist = true, blacklist = true},
  ["loader"] = {none = true, whitelist = true, blacklist = true},
  ["loader-1x1"] = {none = true, whitelist = true, blacklist = true},
  ["mining-drill"] = {whitelist = true, blacklist = true}
}

local SPLITTER_TYPES = {["splitter"] = true, ["lane-splitter"] = true}
local SPLITTER_PRIORITIES = {left = true, right = true, none = true}

local REQUEST_FILTER_TYPES = {
  ["logistic-container"] = true,
  ["infinity-container"] = true,
  ["roboport"] = true,
  ["cargo-landing-pad"] = true,
  ["space-platform-hub"] = true
}
local REQUESTING_LOGISTIC_MODES = {requester = true, buffer = true}

local CONTROL_KIND = {
  ["inserter"] = "inserter",
  ["transport-belt"] = "belt",
  ["mining-drill"] = "drill",
  ["assembling-machine"] = "crafter",
  ["rocket-silo"] = "crafter",
  ["furnace"] = "furnace",
  ["logistic-container"] = "logistic-container",
  ["infinity-container"] = "logistic-container",
  ["arithmetic-combinator"] = "arithmetic",
  ["decider-combinator"] = "decider",
  ["constant-combinator"] = "constant",
  ["pump"] = "generic",
  ["offshore-pump"] = "generic",
  ["power-switch"] = "generic",
  ["lamp"] = "generic",
  ["train-stop"] = "generic"
}

local ON_OFF_FIELDS = {
  enabledCondition = true,
  circuitEnabled = true,
  logisticCondition = true,
  connectToLogisticNetwork = true
}

local function on_off_fields_with(extra)
  local fields = {}
  for key in pairs(ON_OFF_FIELDS) do fields[key] = true end
  for _, key in ipairs(extra) do fields[key] = true end
  return fields
end

local CONTROL_FIELDS = {
  ["inserter"] = on_off_fields_with({
    "readContents", "readMode", "setFilters", "setStackSize", "stackSizeSignal"
  }),
  ["belt"] = on_off_fields_with({"readContents", "readMode"}),
  ["drill"] = on_off_fields_with({"readContents", "readMode"}),
  ["crafter"] = on_off_fields_with({
    "readContents", "readIngredients", "readWorking", "workingSignal", "setRecipe"
  }),
  ["furnace"] = on_off_fields_with({
    "readContents", "readIngredients", "readWorking", "workingSignal"
  }),
  ["logistic-container"] = {
    enabledCondition = true,
    circuitEnabled = true,
    readContents = true,
    setRequests = true
  },
  ["arithmetic"] = {arithmetic = true},
  ["decider"] = {decider = true},
  ["constant"] = {sections = true},
  ["generic"] = ON_OFF_FIELDS
}

local READ_MODES = {
  ["inserter"] = {pulse = "pulse", hold = "hold"},
  ["belt"] = {pulse = "pulse", hold = "hold", ["entire-belt-hold"] = "entire_belt_hold"},
  ["drill"] = {["this-miner"] = "this_miner", ["entire-patch"] = "entire_patch"}
}

-- Factorio runs Lua 5.2, which has no \u{} escape; the three Unicode
-- comparators Factorio also accepts are spelled as raw UTF-8 bytes.
local COMPARATORS = {
  ["="] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true,
  ["!="] = true,
  ["\226\137\165"] = true, -- U+2265 greater than or equal to
  ["\226\137\164"] = true, -- U+2264 less than or equal to
  ["\226\137\160"] = true  -- U+2260 not equal to
}

local OPERATIONS = {
  ["*"] = true, ["/"] = true, ["+"] = true, ["-"] = true, ["%"] = true,
  ["^"] = true, ["<<"] = true, [">>"] = true,
  ["AND"] = true, ["OR"] = true, ["XOR"] = true
}

local COMPARE_TYPES = {["and"] = true, ["or"] = true}

local SIGNAL_REGISTRY = {
  item = function() return prototypes.item end,
  fluid = function() return prototypes.fluid end,
  virtual = function() return prototypes.virtual_signal end
}

local function validate_quality(quality, errors, path)
  if quality == nil then return end
  if not valid_string(quality, 200) or not prototypes.quality[quality] then
    add_issue(errors, "UNKNOWN_QUALITY", path, "quality prototype does not exist")
  end
end

local function validate_signal(signal, errors, path)
  if signal == nil then return end
  if type(signal) ~= "table" then
    add_issue(errors, "INVALID_SIGNAL", path, "signal must be an object")
    return
  end
  local registry = SIGNAL_REGISTRY[signal.type]
  if not registry then
    add_issue(errors, "INVALID_SIGNAL_TYPE", path .. ".type", "signal type must be item, fluid, or virtual")
    return
  end
  if not valid_string(signal.name, 200) or not registry()[signal.name] then
    add_issue(errors, "UNKNOWN_SIGNAL", path .. ".name", "signal prototype does not exist")
  end
  validate_quality(signal.quality, errors, path .. ".quality")
end

local function validate_condition(condition, errors, path)
  if condition == nil then return end
  if type(condition) ~= "table" then
    add_issue(errors, "INVALID_CONDITION", path, "condition must be an object")
    return
  end
  if condition.comparator ~= nil and not COMPARATORS[condition.comparator] then
    add_issue(errors, "INVALID_COMPARATOR", path .. ".comparator", "comparator must be one of =, >, <, >=, <=, !=")
  end
  if condition.constant ~= nil and not integer(condition.constant, INT32_MIN, INT32_MAX) then
    add_issue(errors, "INVALID_CONSTANT", path .. ".constant", "constant must be a 32-bit signed integer")
  end
  validate_signal(condition.firstSignal, errors, path .. ".firstSignal")
  validate_signal(condition.secondSignal, errors, path .. ".secondSignal")
end

local function validate_boolean(value, errors, path)
  if value ~= nil and type(value) ~= "boolean" then
    add_issue(errors, "INVALID_CONTROL_FIELD", path, "field must be a boolean")
  end
end

local function validate_items(entity, prototype, build_cost, errors, path)
  if entity.items == nil then return end
  local items_path = path .. ".items"
  if type(entity.items) ~= "table" then
    add_issue(errors, "INVALID_ITEM_REQUESTS", items_path, "items must map item prototype names to positive counts")
    return
  end
  local kinds = 0
  local total = 0
  for name, count in pairs(entity.items) do
    kinds = kinds + 1
    local item_path = items_path .. "." .. tostring(name)
    if type(name) ~= "string" or #name < 1 or #name > 200
      or not integer(count, 1, MAX_MODULE_COUNT) then
      add_issue(errors, "INVALID_ITEM_REQUEST", item_path, "each item request must map a prototype name to a count from 1 through 100")
    else
      total = total + count
      local item = prototypes.item[name]
      if not item then
        add_issue(errors, "UNKNOWN_ITEM", item_path, "item prototype does not exist")
      elseif item.type ~= "module" then
        add_issue(errors, "ITEM_IS_NOT_A_MODULE", item_path, "only module items can be requested into a blueprint entity")
      else
        build_cost[name] = (build_cost[name] or 0) + count
        local categories = prototype.allowed_module_categories
        if categories and not categories[item.category] then
          add_issue(errors, "MODULE_CATEGORY_NOT_ALLOWED", item_path, "entity does not accept this module category")
        end
        -- Only a POSITIVE disallowed effect blocks a module. Factorio 2.1 gives
        -- speed-module a quality effect of -0.01 while beacons set
        -- allowed_effects.quality = false, and the engine still accepts speed
        -- modules in beacons; it is the productivity gain of a productivity
        -- module that a beacon refuses.
        local allowed = prototype.allowed_effects
        if allowed then
          for effect, value in pairs(item.module_effects or {}) do
            if value > 0 and not allowed[effect] then
              add_issue(errors, "MODULE_EFFECT_NOT_ALLOWED", item_path, "entity does not allow the " .. effect .. " module effect")
            end
          end
        end
      end
    end
  end
  if kinds > MAX_MODULE_KINDS then
    add_issue(errors, "TOO_MANY_ITEM_REQUESTS", items_path, "at most 8 distinct module prototypes may be requested per entity")
  end
  local slots = prototype.module_inventory_size or 0
  if slots < 1 or not MODULE_INVENTORY[prototype.type] then
    add_issue(errors, "ENTITY_ACCEPTS_NO_MODULES", items_path, "entity prototype has no module slots this blueprint format can fill")
  elseif total > slots then
    add_issue(errors, "TOO_MANY_MODULES", items_path, "requested modules exceed the module slots of this entity")
  end
end

local function validate_filters(entity, prototype, errors, path)
  local kind = FILTER_KIND[prototype.type]
  if entity.filters ~= nil then
    local filters_path = path .. ".filters"
    if not kind then
      add_issue(errors, "FILTERS_NOT_SUPPORTED", filters_path, "this entity prototype does not accept blueprint item filters")
    elseif type(entity.filters) ~= "table" or #entity.filters < 1 then
      add_issue(errors, "INVALID_FILTERS", filters_path, "filters must be a non-empty array of item references")
    else
      local maximum = MAX_FILTERS
      if kind == "single" then
        maximum = 1
      elseif type(prototype.filter_count) == "number" and prototype.filter_count > 0 then
        maximum = math.min(MAX_FILTERS, prototype.filter_count)
      end
      if #entity.filters > maximum then
        add_issue(errors, "TOO_MANY_FILTERS", filters_path, "entity accepts at most " .. maximum .. " filter slots")
      end
      for index, filter in ipairs(entity.filters) do
        local filter_path = filters_path .. "[" .. index .. "]"
        if type(filter) ~= "table" or not valid_string(filter.name, 200) then
          add_issue(errors, "INVALID_FILTER", filter_path, "each filter must name an item prototype")
        elseif not prototypes.item[filter.name] then
          add_issue(errors, "UNKNOWN_ITEM", filter_path .. ".name", "item prototype does not exist")
        else
          validate_quality(filter.quality, errors, filter_path .. ".quality")
        end
      end
    end
  end
  if entity.filterMode ~= nil then
    local modes = FILTER_MODES[prototype.type]
    if not modes or not modes[entity.filterMode] then
      add_issue(errors, "INVALID_FILTER_MODE", path .. ".filterMode", "this entity prototype does not accept this filter mode")
    end
  end
  for _, key in ipairs({"inputPriority", "outputPriority"}) do
    if entity[key] ~= nil then
      if not SPLITTER_TYPES[prototype.type] then
        add_issue(errors, "PRIORITY_NOT_SUPPORTED", path .. "." .. key, "only splitters accept lane priorities")
      elseif not SPLITTER_PRIORITIES[entity[key]] then
        add_issue(errors, "INVALID_PRIORITY", path .. "." .. key, "priority must be left, right, or none")
      end
    end
  end
end

local function validate_request_filters(entity, prototype, errors, path)
  if entity.requestFromBuffers ~= nil and entity.requestFilters == nil then
    add_issue(errors, "REQUEST_FILTERS_REQUIRED", path .. ".requestFromBuffers", "requestFromBuffers requires requestFilters")
  end
  if entity.requestFilters == nil then return end
  local filters_path = path .. ".requestFilters"
  if not REQUEST_FILTER_TYPES[prototype.type] then
    add_issue(errors, "REQUEST_FILTERS_NOT_SUPPORTED", filters_path, "this entity prototype does not accept logistic request filters")
    return
  end
  if prototype.type == "logistic-container"
    and not REQUESTING_LOGISTIC_MODES[prototype.logistic_mode] then
    add_issue(errors, "REQUEST_FILTERS_NOT_SUPPORTED", filters_path, "only requester and buffer chests accept logistic request filters")
    return
  end
  validate_boolean(entity.requestFromBuffers, errors, path .. ".requestFromBuffers")
  if type(entity.requestFilters) ~= "table" or #entity.requestFilters < 1 then
    add_issue(errors, "INVALID_REQUEST_FILTERS", filters_path, "requestFilters must be a non-empty array")
    return
  end
  if #entity.requestFilters > MAX_REQUEST_FILTERS then
    add_issue(errors, "TOO_MANY_REQUEST_FILTERS", filters_path, "at most 40 logistic request filters are accepted per entity")
    return
  end
  for index, filter in ipairs(entity.requestFilters) do
    local filter_path = filters_path .. "[" .. index .. "]"
    if type(filter) ~= "table" or not valid_string(filter.name, 200) then
      add_issue(errors, "INVALID_REQUEST_FILTER", filter_path, "each request filter must name an item prototype")
    elseif not prototypes.item[filter.name] then
      add_issue(errors, "UNKNOWN_ITEM", filter_path .. ".name", "item prototype does not exist")
    else
      validate_quality(filter.quality, errors, filter_path .. ".quality")
      if filter.min ~= nil and not integer(filter.min, 0, INT32_MAX) then
        add_issue(errors, "INVALID_REQUEST_COUNT", filter_path .. ".min", "min must be a non-negative 32-bit integer")
      end
      if filter.max ~= nil then
        if not integer(filter.max, 0, INT32_MAX) then
          add_issue(errors, "INVALID_REQUEST_COUNT", filter_path .. ".max", "max must be a non-negative 32-bit integer")
        elseif filter.min ~= nil and integer(filter.min, 0, INT32_MAX) and filter.max < filter.min then
          add_issue(errors, "INVALID_REQUEST_COUNT", filter_path .. ".max", "max must be at least min")
        end
      end
    end
  end
end

local function validate_arithmetic(parameters, errors, path)
  if type(parameters) ~= "table" then
    add_issue(errors, "INVALID_ARITHMETIC", path, "arithmetic must be an object")
    return
  end
  if parameters.operation ~= nil and not OPERATIONS[parameters.operation] then
    add_issue(errors, "INVALID_OPERATION", path .. ".operation", "operation must be one of *, /, +, -, %, ^, <<, >>, AND, OR, XOR")
  end
  for _, key in ipairs({"firstConstant", "secondConstant"}) do
    if parameters[key] ~= nil and not integer(parameters[key], INT32_MIN, INT32_MAX) then
      add_issue(errors, "INVALID_CONSTANT", path .. "." .. key, "constant must be a 32-bit signed integer")
    end
  end
  validate_signal(parameters.firstSignal, errors, path .. ".firstSignal")
  validate_signal(parameters.secondSignal, errors, path .. ".secondSignal")
  if parameters.outputSignal == nil then
    add_issue(errors, "MISSING_OUTPUT_SIGNAL", path .. ".outputSignal", "an arithmetic combinator needs an output signal")
  else
    validate_signal(parameters.outputSignal, errors, path .. ".outputSignal")
  end
end

local function validate_decider(parameters, errors, path)
  if type(parameters) ~= "table" then
    add_issue(errors, "INVALID_DECIDER", path, "decider must be an object")
    return
  end
  local conditions = parameters.conditions
  if type(conditions) ~= "table" or #conditions < 1 or #conditions > MAX_DECIDER_CONDITIONS then
    add_issue(errors, "INVALID_DECIDER_CONDITIONS", path .. ".conditions", "a decider combinator needs 1 to 16 conditions")
  else
    for index, condition in ipairs(conditions) do
      local condition_path = path .. ".conditions[" .. index .. "]"
      validate_condition(condition, errors, condition_path)
      if type(condition) == "table" and condition.compareType ~= nil
        and not COMPARE_TYPES[condition.compareType] then
        add_issue(errors, "INVALID_COMPARE_TYPE", condition_path .. ".compareType", "compareType must be and or or")
      end
    end
  end
  local outputs = parameters.outputs
  if type(outputs) ~= "table" or #outputs < 1 or #outputs > MAX_DECIDER_OUTPUTS then
    add_issue(errors, "INVALID_DECIDER_OUTPUTS", path .. ".outputs", "a decider combinator needs 1 to 16 outputs")
  else
    for index, output in ipairs(outputs) do
      local output_path = path .. ".outputs[" .. index .. "]"
      if type(output) ~= "table" or output.signal == nil then
        add_issue(errors, "INVALID_DECIDER_OUTPUT", output_path, "each decider output needs a signal")
      else
        validate_signal(output.signal, errors, output_path .. ".signal")
        validate_boolean(output.copyCountFromInput, errors, output_path .. ".copyCountFromInput")
        if output.constant ~= nil and not integer(output.constant, INT32_MIN, INT32_MAX) then
          add_issue(errors, "INVALID_CONSTANT", output_path .. ".constant", "constant must be a 32-bit signed integer")
        end
      end
    end
  end
end

local function validate_sections(sections, errors, path)
  if type(sections) ~= "table" or #sections < 1 or #sections > MAX_SECTIONS then
    add_issue(errors, "INVALID_SECTIONS", path, "sections must contain 1 to 8 entries")
    return
  end
  for index, section in ipairs(sections) do
    local section_path = path .. "[" .. index .. "]"
    if type(section) ~= "table" then
      add_issue(errors, "INVALID_SECTION", section_path, "section must be an object")
    else
      validate_boolean(section.active, errors, section_path .. ".active")
      local filters = section.filters
      if type(filters) ~= "table" or #filters < 1 or #filters > MAX_SECTION_FILTERS then
        add_issue(errors, "INVALID_SECTION_FILTERS", section_path .. ".filters", "each section needs 1 to 40 signal filters")
      else
        for filter_index, filter in ipairs(filters) do
          local filter_path = section_path .. ".filters[" .. filter_index .. "]"
          validate_signal(filter, errors, filter_path)
          if type(filter) == "table" and filter.count ~= nil
            and not integer(filter.count, INT32_MIN, INT32_MAX) then
            add_issue(errors, "INVALID_CONSTANT", filter_path .. ".count", "count must be a 32-bit signed integer")
          end
        end
      end
    end
  end
end

local function validate_control(entity, prototype, errors, path)
  if entity.control == nil then return end
  local control_path = path .. ".control"
  if type(entity.control) ~= "table" then
    add_issue(errors, "INVALID_CONTROL", control_path, "control must be an object")
    return
  end
  local kind = CONTROL_KIND[prototype.type]
  if not kind then
    add_issue(errors, "CONTROL_NOT_SUPPORTED", control_path, "this entity prototype has no control behavior this blueprint format can express")
    return
  end
  local allowed = CONTROL_FIELDS[kind]
  for _, key in ipairs(CONTROL_SHAPE.scalars) do
    if entity.control[key] ~= nil and not allowed[key] then
      add_issue(errors, "CONTROL_FIELD_NOT_SUPPORTED", control_path .. "." .. key, "this entity prototype does not support this control field")
    end
  end
  for key in pairs(CONTROL_SHAPE.objects) do
    if entity.control[key] ~= nil and not allowed[key] then
      add_issue(errors, "CONTROL_FIELD_NOT_SUPPORTED", control_path .. "." .. key, "this entity prototype does not support this control field")
    end
  end
  if entity.control.sections ~= nil and not allowed.sections then
    add_issue(errors, "CONTROL_FIELD_NOT_SUPPORTED", control_path .. ".sections", "this entity prototype does not support signal sections")
  end

  for _, key in ipairs({
    "circuitEnabled", "connectToLogisticNetwork", "readContents", "readIngredients",
    "readWorking", "setRecipe", "setFilters", "setStackSize", "setRequests"
  }) do
    if allowed[key] then validate_boolean(entity.control[key], errors, control_path .. "." .. key) end
  end
  if allowed.enabledCondition then
    validate_condition(entity.control.enabledCondition, errors, control_path .. ".enabledCondition")
  end
  if allowed.logisticCondition then
    validate_condition(entity.control.logisticCondition, errors, control_path .. ".logisticCondition")
  end
  if allowed.workingSignal then
    validate_signal(entity.control.workingSignal, errors, control_path .. ".workingSignal")
  end
  if allowed.stackSizeSignal then
    validate_signal(entity.control.stackSizeSignal, errors, control_path .. ".stackSizeSignal")
  end
  if allowed.readMode and entity.control.readMode ~= nil
    and not READ_MODES[kind][entity.control.readMode] then
    add_issue(errors, "INVALID_READ_MODE", control_path .. ".readMode", "this entity prototype does not support this read mode")
  end
  if allowed.arithmetic and entity.control.arithmetic ~= nil then
    validate_arithmetic(entity.control.arithmetic, errors, control_path .. ".arithmetic")
  end
  if allowed.decider and entity.control.decider ~= nil then
    validate_decider(entity.control.decider, errors, control_path .. ".decider")
  end
  if allowed.sections and entity.control.sections ~= nil then
    validate_sections(entity.control.sections, errors, control_path .. ".sections")
  end
end

function Blueprints.validate(layout, context, placement)
  local errors = {}
  local warnings = {}
  local build_cost = {}
  local summary = {
    entityCount = 0,
    tileCount = 0,
    buildCost = build_cost,
    expectedOutputs = {},
    footprint = {leftTop = {x = 0, y = 0}, rightBottom = {x = 0, y = 0}, width = 0, height = 0}
  }

  if type(layout) ~= "table" then
    add_issue(errors, "INVALID_LAYOUT", "layout", "layout must be an object")
    return {valid = false, errors = errors, warnings = warnings, summary = summary}
  end
  if not valid_string(layout.name, 100) then
    add_issue(errors, "INVALID_NAME", "layout.name", "name must contain 1 to 100 bytes")
  end
  if layout.description ~= nil
    and (type(layout.description) ~= "string" or #layout.description > 1000) then
    add_issue(errors, "INVALID_DESCRIPTION", "layout.description", "description may contain at most 1000 bytes")
  end
  if type(layout.entities) ~= "table" or #layout.entities < 1 or #layout.entities > MAX_ENTITIES then
    add_issue(errors, "INVALID_ENTITY_COUNT", "layout.entities", "layout must contain 1 to " .. MAX_ENTITIES .. " entities")
    return {valid = false, errors = errors, warnings = warnings, summary = summary}
  end
  if layout.tiles ~= nil and (type(layout.tiles) ~= "table" or #layout.tiles > MAX_TILES) then
    add_issue(errors, "INVALID_TILE_COUNT", "layout.tiles", "layout may contain at most " .. MAX_TILES .. " tiles")
  end

  local known_numbers = {}
  for index, entity in ipairs(layout.entities) do
    local path = "layout.entities[" .. index .. "]"
    if type(entity) ~= "table" or not integer(entity.entityNumber, 1, 4294967295) then
      add_issue(errors, "INVALID_ENTITY_NUMBER", path .. ".entityNumber", "entityNumber must be a positive integer")
    elseif known_numbers[entity.entityNumber] then
      add_issue(errors, "DUPLICATE_ENTITY_NUMBER", path .. ".entityNumber", "entityNumber must be unique")
    else
      known_numbers[entity.entityNumber] = true
    end
  end

  local min_x, min_y, max_x, max_y
  for index, entity in ipairs(layout.entities) do
    local path = "layout.entities[" .. index .. "]"
    if type(entity) ~= "table" then
      add_issue(errors, "INVALID_ENTITY", path, "entity must be an object")
    else
      local prototype = valid_string(entity.prototype, 200) and prototypes.entity[entity.prototype] or nil
      if not prototype then
        add_issue(errors, "UNKNOWN_ENTITY", path .. ".prototype", "entity prototype does not exist")
      end
      local position = position_of(entity.position)
      if not position then
        add_issue(errors, "INVALID_POSITION", path .. ".position", "position must contain finite x and y values")
      else
        min_x = not min_x and position.x or math.min(min_x, position.x)
        min_y = not min_y and position.y or math.min(min_y, position.y)
        max_x = not max_x and position.x or math.max(max_x, position.x)
        max_y = not max_y and position.y or math.max(max_y, position.y)
      end
      if entity.direction ~= nil and not integer(entity.direction, 0, 15) then
        add_issue(errors, "INVALID_DIRECTION", path .. ".direction", "direction must be an integer from 0 through 15")
      end
      if entity.quality ~= nil and not prototypes.quality[entity.quality] then
        add_issue(errors, "UNKNOWN_QUALITY", path .. ".quality", "quality prototype does not exist")
      end
      if is_nonempty_table(entity.settings) then
        add_issue(errors, "ENTITY_SETTINGS_UNSUPPORTED", path .. ".settings", "arbitrary entity settings are not accepted; use control, filters, requestFilters, or items")
      end
      if prototype then
        item_cost_for(prototype, build_cost)
        validate_recipe(entity, prototype, context.force, errors, path)
        validate_items(entity, prototype, build_cost, errors, path)
        validate_filters(entity, prototype, errors, path)
        validate_request_filters(entity, prototype, errors, path)
        validate_control(entity, prototype, errors, path)
      end
      validate_connections(entity, known_numbers, errors, path)

      if placement and placement.surface and position and prototype then
        local absolute = {
          x = placement.origin.x + position.x,
          y = placement.origin.y + position.y
        }
        local can_place = placement.surface.can_place_entity({
          name = entity.prototype,
          position = absolute,
          direction = entity.direction or defines.direction.north,
          force = context.force,
          build_check_type = defines.build_check_type.blueprint_ghost
        })
        if not can_place then
          add_issue(errors, "PLACEMENT_COLLISION", path .. ".position", "entity collides at the requested placement origin")
        end
      end
    end
  end

  if type(layout.tiles) == "table" then
    for index, tile in ipairs(layout.tiles) do
      local path = "layout.tiles[" .. index .. "]"
      local tile_prototype = type(tile) == "table"
        and valid_string(tile.prototype, 200)
        and prototypes.tile[tile.prototype]
        or nil
      if not tile_prototype then
        add_issue(errors, "UNKNOWN_TILE", path .. ".prototype", "tile prototype does not exist")
      elseif not tile_prototype.can_be_part_of_blueprint then
        add_issue(errors, "TILE_NOT_BLUEPRINTABLE", path .. ".prototype", "tile cannot be included in a blueprint")
      end
      if type(tile) ~= "table" or not position_of(tile.position) then
        add_issue(errors, "INVALID_POSITION", path .. ".position", "position must contain finite x and y values")
      end
    end
  end

  if type(layout.expectedOutputs) == "table" then
    for index, output in ipairs(layout.expectedOutputs) do
      local path = "layout.expectedOutputs[" .. index .. "]"
      if type(output) ~= "table"
        or (output.type ~= "item" and output.type ~= "fluid")
        or not valid_string(output.name, 200)
        or not finite(output.perSecond)
        or output.perSecond <= 0 then
        add_issue(errors, "INVALID_EXPECTED_OUTPUT", path, "expected output must name an item or fluid with a positive per-second value")
      elseif output.type == "item" and not prototypes.item[output.name] then
        add_issue(errors, "UNKNOWN_ITEM", path .. ".name", "expected item prototype does not exist")
      elseif output.type == "fluid" and not prototypes.fluid[output.name] then
        add_issue(errors, "UNKNOWN_FLUID", path .. ".name", "expected fluid prototype does not exist")
      else
        summary.expectedOutputs[#summary.expectedOutputs + 1] = clone_plain(output, 0)
      end
    end
  end

  summary.entityCount = #layout.entities
  summary.tileCount = type(layout.tiles) == "table" and #layout.tiles or 0
  if min_x then
    summary.footprint = {
      leftTop = {x = min_x, y = min_y},
      rightBottom = {x = max_x, y = max_y},
      width = max_x - min_x,
      height = max_y - min_y
    }
  end
  if summary.tileCount > 0 and placement then
    add_issue(warnings, "TILE_COLLISIONS_NOT_SIMULATED", "layout.tiles", "entity placement was checked; tile replacement is validated by prototype only")
  end

  -- Count bounds alone cannot keep a request inside the 48 KiB gateway
  -- datagram once entities carry modules, filters and control behavior, so the
  -- encoded canonical layout is the authoritative size gate.
  if #errors == 0 then
    local encoded_ok, encoded = pcall(function()
      return helpers.table_to_json(canonical_layout(layout))
    end)
    if not encoded_ok or type(encoded) ~= "string" then
      add_issue(errors, "INVALID_LAYOUT", "layout", "layout could not be encoded")
    else
      summary.layoutBytes = #encoded
      if #encoded > MAX_LAYOUT_BYTES then
        add_issue(errors, "LAYOUT_TOO_LARGE", "layout", "the canonical layout encodes to " .. #encoded .. " bytes; the gateway datagram allows " .. MAX_LAYOUT_BYTES)
      end
    end
  end
  return {valid = #errors == 0, errors = errors, warnings = warnings, summary = summary}
end

local DEFAULT_CONNECTOR = {
  red = function() return defines.wire_connector_id.circuit_red end,
  green = function() return defines.wire_connector_id.circuit_green end,
  copper = function() return defines.wire_connector_id.pole_copper end
}

local function signal_id(signal)
  if type(signal) ~= "table" then return nil end
  return {type = signal.type, name = signal.name, quality = signal.quality}
end

local function circuit_condition(condition)
  if type(condition) ~= "table" then return nil end
  return {
    first_signal = signal_id(condition.firstSignal),
    second_signal = signal_id(condition.secondSignal),
    comparator = condition.comparator,
    constant = condition.constant
  }
end

-- Module requests are laid out over consecutive module slots in a deterministic
-- prototype-name order, because the resulting blueprint item is game state that
-- every peer must build identically.
local function insert_plans(source, prototype_type)
  local inventory = defines.inventory[MODULE_INVENTORY[prototype_type] or ""]
  if not inventory then return nil end
  local names = {}
  for name in pairs(source.items) do names[#names + 1] = name end
  table.sort(names)
  local plans = {}
  local stack = 0
  for _, name in ipairs(names) do
    local positions = {}
    for _ = 1, source.items[name] do
      positions[#positions + 1] = {inventory = inventory, stack = stack}
      stack = stack + 1
    end
    plans[#plans + 1] = {id = {name = name}, items = {in_inventory = positions}}
  end
  return plans
end

local function item_filters(source)
  local filters = {}
  for index, filter in ipairs(source.filters) do
    filters[#filters + 1] = {
      index = index,
      name = filter.name,
      quality = filter.quality,
      comparator = filter.quality ~= nil and "=" or nil
    }
  end
  return filters
end

local function slot_filters(source)
  local filters = {}
  for index, filter in ipairs(source.filters) do
    filters[#filters + 1] = {index = index, name = filter.name}
  end
  return filters
end

local function single_filter(filter)
  if filter.quality == nil then return filter.name end
  return {name = filter.name, quality = filter.quality, comparator = "="}
end

local function request_sections(source)
  local filters = {}
  for index, filter in ipairs(source.requestFilters) do
    filters[#filters + 1] = {
      index = index,
      name = filter.name,
      quality = filter.quality or "normal",
      comparator = "=",
      count = filter.min or 0,
      max_count = filter.max
    }
  end
  return {
    request_from_buffers = source.requestFromBuffers,
    sections = {{index = 1, filters = filters}}
  }
end

local function logistic_sections(sections)
  local emitted = {}
  for index, section in ipairs(sections) do
    local filters = {}
    for filter_index, filter in ipairs(section.filters or {}) do
      filters[#filters + 1] = {
        index = filter_index,
        type = filter.type,
        name = filter.name,
        quality = filter.quality or "normal",
        comparator = "=",
        count = filter.count or 0
      }
    end
    emitted[#emitted + 1] = {index = index, filters = filters, active = section.active}
  end
  return {sections = emitted}
end

local function apply_on_off(control, behavior)
  if control.enabledCondition ~= nil then
    behavior.circuit_condition = circuit_condition(control.enabledCondition)
    behavior.circuit_enabled = control.circuitEnabled ~= false
  elseif control.circuitEnabled ~= nil then
    behavior.circuit_enabled = control.circuitEnabled
  end
  if control.logisticCondition ~= nil then
    behavior.logistic_condition = circuit_condition(control.logisticCondition)
    behavior.connect_to_logistic_network = control.connectToLogisticNetwork ~= false
  elseif control.connectToLogisticNetwork ~= nil then
    behavior.connect_to_logistic_network = control.connectToLogisticNetwork
  end
  return behavior
end

local function control_behavior(kind, control)
  if kind == "arithmetic" then
    local parameters = control.arithmetic
    if type(parameters) ~= "table" then return nil end
    return {
      arithmetic_conditions = {
        first_signal = signal_id(parameters.firstSignal),
        second_signal = signal_id(parameters.secondSignal),
        first_constant = parameters.firstConstant,
        second_constant = parameters.secondConstant,
        operation = parameters.operation or "*",
        output_signal = signal_id(parameters.outputSignal)
      }
    }
  end
  if kind == "decider" then
    local parameters = control.decider
    if type(parameters) ~= "table" then return nil end
    local conditions = {}
    for _, condition in ipairs(parameters.conditions or {}) do
      local emitted = circuit_condition(condition)
      emitted.compare_type = condition.compareType
      conditions[#conditions + 1] = emitted
    end
    local outputs = {}
    for _, output in ipairs(parameters.outputs or {}) do
      outputs[#outputs + 1] = {
        signal = signal_id(output.signal),
        copy_count_from_input = output.copyCountFromInput,
        constant = output.constant
      }
    end
    return {
      decider_conditions = {conditions = conditions, outputs = outputs, else_outputs = {}}
    }
  end
  if kind == "constant" then
    if type(control.sections) ~= "table" then return nil end
    return {sections = logistic_sections(control.sections)}
  end
  if kind == "logistic-container" then
    local behavior = {}
    if control.enabledCondition ~= nil then
      behavior.circuit_condition = circuit_condition(control.enabledCondition)
      behavior.circuit_condition_enabled = control.circuitEnabled ~= false
    elseif control.circuitEnabled ~= nil then
      behavior.circuit_condition_enabled = control.circuitEnabled
    end
    behavior.read_contents = control.readContents
    behavior.set_requests = control.setRequests
    if next(behavior) == nil then return nil end
    return behavior
  end

  local behavior = apply_on_off(control, {})
  if kind == "inserter" then
    behavior.circuit_read_hand_contents = control.readContents
    if control.readMode ~= nil then
      behavior.circuit_hand_read_mode =
        defines.control_behavior.inserter.hand_read_mode[READ_MODES.inserter[control.readMode]]
    end
    behavior.circuit_set_filters = control.setFilters
    behavior.circuit_set_stack_size = control.setStackSize
    behavior.stack_control_input_signal = signal_id(control.stackSizeSignal)
  elseif kind == "belt" then
    behavior.circuit_read_hand_contents = control.readContents == true
    behavior.circuit_contents_read_mode =
      defines.control_behavior.transport_belt.content_read_mode[READ_MODES.belt[control.readMode or "pulse"]]
  elseif kind == "drill" then
    behavior.circuit_read_resources = control.readContents == true
    behavior.circuit_resource_read_mode =
      defines.control_behavior.mining_drill.resource_read_mode[READ_MODES.drill[control.readMode or "this-miner"]]
  elseif kind == "crafter" or kind == "furnace" then
    behavior.read_contents = control.readContents
    behavior.read_ingredients = control.readIngredients
    behavior.read_working = control.readWorking
    behavior.working_signal = signal_id(control.workingSignal)
    if kind == "crafter" then behavior.set_recipe = control.setRecipe end
  end
  if next(behavior) == nil then return nil end
  return behavior
end

local function apply_extras(entity, source)
  local prototype = prototypes.entity[source.prototype]
  local prototype_type = prototype and prototype.type or nil
  if not prototype_type then return end

  if type(source.items) == "table" and next(source.items) ~= nil then
    entity.items = insert_plans(source, prototype_type)
  end

  local filter_kind = FILTER_KIND[prototype_type]
  local has_filters = type(source.filters) == "table" and #source.filters > 0
  if filter_kind == "single" and has_filters then
    entity.filter = single_filter(source.filters[1])
  elseif filter_kind == "drill" and has_filters then
    entity.filter = {filters = slot_filters(source), mode = source.filterMode}
  elseif filter_kind == "slots" then
    if has_filters then
      entity.filters = item_filters(source)
      if prototype_type == "inserter" then entity.use_filters = true end
    end
    if source.filterMode ~= nil then entity.filter_mode = source.filterMode end
  end
  if source.inputPriority ~= nil then entity.input_priority = source.inputPriority end
  if source.outputPriority ~= nil then entity.output_priority = source.outputPriority end

  if type(source.requestFilters) == "table" and #source.requestFilters > 0 then
    entity.request_filters = request_sections(source)
  end

  if type(source.control) == "table" then
    local kind = CONTROL_KIND[prototype_type]
    if kind then
      entity.control_behavior = control_behavior(kind, source.control)
    end
  end
end

local function blueprint_entities(layout)
  local entities = {}
  for _, source in ipairs(layout.entities) do
    local entity = {
      entity_number = source.entityNumber,
      name = source.prototype,
      position = {x = source.position.x, y = source.position.y}
    }
    if source.direction ~= nil then entity.direction = source.direction end
    if source.quality ~= nil then entity.quality = source.quality end
    if source.recipe ~= nil then
      entity.recipe = source.recipe
      if source.quality ~= nil then entity.recipe_quality = source.quality end
    end
    apply_extras(entity, source)
    if type(source.connections) == "table" and #source.connections > 0 then
      entity.wires = {}
      for _, connection in ipairs(source.connections) do
        local connector = DEFAULT_CONNECTOR[connection.wire]
        local from_id = connection.fromConnectorId or connector()
        local to_id = connection.toConnectorId or connector()
        entity.wires[#entity.wires + 1] = {
          source.entityNumber,
          from_id,
          connection.toEntityNumber,
          to_id
        }
      end
    end
    entities[#entities + 1] = entity
  end
  return entities
end

local function blueprint_tiles(layout)
  local tiles = {}
  for _, source in ipairs(layout.tiles or {}) do
    tiles[#tiles + 1] = {
      name = source.prototype,
      position = {x = source.position.x, y = source.position.y}
    }
  end
  return tiles
end

local function deliver_to_clipboard(player, layout)
  if not (player and player.valid and player.connected) then
    return nil, "PLAYER_NOT_CONNECTED", "Cursor delivery requires the paired player to be connected"
  end
  local inventory = game.create_inventory(1)
  local ok, reason = pcall(function()
    local stack = inventory[1]
    stack.set_stack({name = "blueprint", count = 1})
    -- Contents first: Factorio refuses a label or description on an empty
    -- blueprint, which silently broke every described cursor delivery.
    stack.set_blueprint_entities(blueprint_entities(layout))
    if #(layout.tiles or {}) > 0 then
      stack.set_blueprint_tiles(blueprint_tiles(layout))
    end
    stack.label = layout.name
    stack.blueprint_description = layout.description or ""
    player.add_to_clipboard(stack)
  end)
  inventory.destroy()
  if not ok then
    log("[Sceatorio] AI blueprint delivery failed: " .. tostring(reason))
    return nil, "BLUEPRINT_DELIVERY_FAILED", "Factorio rejected the generated blueprint item"
  end
  return true
end

local function canonical_record(id, source)
  if type(source) ~= "table" or type(source.revisions) ~= "table" then return nil end
  local revisions = {}
  local bytes = 0
  for _, source_revision in ipairs(source.revisions) do
    if type(source_revision) ~= "table" or type(source_revision.layout) ~= "table" then
      return nil
    end
    local canonical_ok, canonical = pcall(canonical_layout, source_revision.layout)
    if not canonical_ok or not valid_string(canonical.name, 100)
      or type(canonical.entities) ~= "table"
      or #canonical.entities < 1
      or #canonical.entities > MAX_STORED_ENTITIES then return nil end
    local encoded_ok, encoded = pcall(helpers.table_to_json, canonical)
    if not encoded_ok or type(encoded) ~= "string" then return nil end
    bytes = bytes + #encoded
    revisions[#revisions + 1] = {
      revision = source_revision.revision,
      layout = canonical
    }
  end
  if #revisions == 0 then return nil end
  local latest = revisions[#revisions].layout
  return {
    id = id,
    name = latest.name,
    bytes = bytes,
    created_tick = source.created_tick,
    updated_tick = source.updated_tick,
    revisions = revisions
  }
end

-- A stored book is rebuilt the same way a stored blueprint is: field by field,
-- with every bound re-applied, so a save edited by hand or written by an older
-- Sceatorio can only ever shrink into something legal. A member that no longer
-- names a live record of this player is dropped instead of kept as a tombstone
-- -- a book is a list of live references, and an empty page a player cannot use
-- is worse than a shorter book.
local function canonical_book(id, source, known_ids)
  if type(source) ~= "table" or not valid_string(source.name, 100) then return nil end
  local members = {}
  local seen = {}
  for _, member in ipairs(type(source.members) == "table" and source.members or {}) do
    if #members >= MAX_BOOK_MEMBERS then break end
    if type(member) == "string" and known_ids[member] and not seen[member] then
      seen[member] = true
      members[#members + 1] = member
    end
  end
  local description = nil
  if type(source.description) == "string"
    and #source.description > 0
    and #source.description <= 1000 then
    description = source.description
  end
  return {
    id = id,
    name = source.name,
    description = description,
    members = members,
    created_tick = source.created_tick,
    updated_tick = source.updated_tick
  }
end

-- The one place a blueprint leaving the inbox is reflected in the books that
-- referenced it, called by both paths that unmake a record: the owner's own
-- delete and the budget eviction. Bounded by the two book caps, so this walks
-- at most 20 books of at most 50 members.
local function forget_member(inbox, blueprint_id)
  if type(inbox.book_order) ~= "table" or type(inbox.books) ~= "table" then return end
  for _, book_id in ipairs(inbox.book_order) do
    local book = inbox.books[book_id]
    if type(book) == "table" and type(book.members) == "table" then
      for index = #book.members, 1, -1 do
        if book.members[index] == blueprint_id then
          table.remove(book.members, index)
          book.updated_tick = game.tick
        end
      end
    end
  end
end

local function migrate_inbox(inbox)
  local by_id = {}
  local order = {}
  local bytes = 0
  local seen = {}
  for _, id in ipairs(type(inbox.order) == "table" and inbox.order or {}) do
    if type(id) == "string" and not seen[id] then
      seen[id] = true
      local record = canonical_record(id, type(inbox.by_id) == "table" and inbox.by_id[id] or nil)
      if record then
        by_id[id] = record
        order[#order + 1] = id
        bytes = bytes + record.bytes
      end
    end
  end

  local first = 1
  while (#order - first + 1) > MAX_BLUEPRINTS_PER_PLAYER
    or bytes > MAX_BLUEPRINT_BYTES_PER_PLAYER do
    local id = order[first]
    local record = by_id[id]
    if record then bytes = math.max(0, bytes - record.bytes) end
    by_id[id] = nil
    first = first + 1
  end
  if first > 1 then
    local retained = {}
    for index = first, #order do retained[#retained + 1] = order[index] end
    order = retained
  end

  -- Books are rebuilt last, against the records that actually survived this
  -- migration, so an evicted blueprint can never leave a dangling reference
  -- behind. An inbox written before books existed simply has none of these
  -- fields and keeps every blueprint it had.
  local books = {}
  local book_order = {}
  local seen_books = {}
  for _, id in ipairs(type(inbox.book_order) == "table" and inbox.book_order or {}) do
    if type(id) == "string" and not seen_books[id] then
      seen_books[id] = true
      local book = canonical_book(id, type(inbox.books) == "table" and inbox.books[id] or nil, by_id)
      if book then
        books[id] = book
        book_order[#book_order + 1] = id
      end
    end
  end
  local first_book = 1
  while (#book_order - first_book + 1) > MAX_BOOKS_PER_PLAYER do
    books[book_order[first_book]] = nil
    first_book = first_book + 1
  end
  if first_book > 1 then
    local retained_books = {}
    for index = first_book, #book_order do retained_books[#retained_books + 1] = book_order[index] end
    book_order = retained_books
  end

  inbox.schema_version = BLUEPRINT_INBOX_SCHEMA_VERSION
  inbox.order = order
  inbox.by_id = by_id
  inbox.bytes = bytes
  inbox.books = books
  inbox.book_order = book_order
  return inbox
end

local function player_inbox(player_index)
  local root = ai_root()
  local inbox = root.blueprint_inbox[player_index]
  if not inbox then
    inbox = {
      schema_version = BLUEPRINT_INBOX_SCHEMA_VERSION,
      order = {},
      by_id = {},
      bytes = 0,
      books = {},
      book_order = {}
    }
    root.blueprint_inbox[player_index] = inbox
  end
  if inbox.schema_version ~= BLUEPRINT_INBOX_SCHEMA_VERSION
    or type(inbox.order) ~= "table"
    or type(inbox.by_id) ~= "table"
    or type(inbox.bytes) ~= "number"
    or type(inbox.books) ~= "table"
    or type(inbox.book_order) ~= "table" then
    migrate_inbox(inbox)
  end
  return inbox
end

local function evict_oldest_until_fit(inbox, additional_bytes)
  local evicted = {}
  while #inbox.order > 0 and (
    #inbox.order >= MAX_BLUEPRINTS_PER_PLAYER
      or inbox.bytes + additional_bytes > MAX_BLUEPRINT_BYTES_PER_PLAYER
  ) do
    local id = table.remove(inbox.order, 1)
    local record = inbox.by_id[id]
    if record then
      inbox.bytes = math.max(0, inbox.bytes - record.bytes)
      inbox.by_id[id] = nil
    end
    forget_member(inbox, id)
    evicted[#evicted + 1] = id
  end
  return evicted
end

local function parse_cursor(cursor)
  if cursor == nil then return 0 end
  if type(cursor) ~= "string" then return nil end
  local value = tonumber(string.match(cursor, "^offset:(%d+)$"))
  if not value or value > MAX_BLUEPRINTS_PER_PLAYER then return nil end
  return value
end

function Blueprints.save(layout, context, delivery)
  local validation = Blueprints.validate(layout, context)
  if not validation.valid then
    return nil, "BLUEPRINT_INVALID", "Blueprint validation failed", validation
  end
  if delivery == "cursor" and not context.allow_cursor then
    return nil, "PLAYER_PREFERENCE_DENIED", "This player allows inbox delivery only"
  end
  local canonical = canonical_layout(layout)
  local encoded = helpers.table_to_json(canonical)
  local layout_bytes = #encoded
  if layout_bytes > MAX_BLUEPRINT_BYTES_PER_PLAYER then
    return nil, "BLUEPRINT_TOO_LARGE", "The canonical blueprint exceeds the per-player byte budget"
  end
  local inbox = player_inbox(context.player_index)
  local root = ai_root()
  local id = "blueprint:" .. context.player_index .. ":" .. root.next_blueprint_id
  if delivery == "cursor" then
    local delivered, code, message = deliver_to_clipboard(context.player, canonical)
    if not delivered then return nil, code, message end
  end
  local evicted = evict_oldest_until_fit(inbox, layout_bytes)
  local record = {
    id = id,
    name = canonical.name,
    bytes = layout_bytes,
    created_tick = game.tick,
    updated_tick = game.tick,
    revisions = {{revision = 1, layout = canonical}}
  }
  root.next_blueprint_id = root.next_blueprint_id + 1
  inbox.by_id[id] = record
  inbox.order[#inbox.order + 1] = id
  inbox.bytes = inbox.bytes + layout_bytes
  return {
    blueprintId = id,
    revision = 1,
    delivery = delivery,
    inboxCount = #inbox.order,
    evictedBlueprintIds = evicted,
    evictedCount = #evicted,
    validation = validation
  }
end

function Blueprints.list(context, query, pagination, include_books)
  local offset = parse_cursor(pagination and pagination.cursor)
  if offset == nil then
    return nil, "INVALID_CURSOR", "Blueprint inbox cursor is invalid"
  end
  local limit = pagination and pagination.limit or 100
  limit = math.max(1, math.min(200, limit))
  local inbox = player_inbox(context.player_index)
  local lowered = type(query) == "string" and string.lower(query) or nil
  local matches = {}
  for _, id in ipairs(inbox.order) do
    local record = inbox.by_id[id]
    if record and (not lowered or string.find(string.lower(record.name), lowered, 1, true)) then
      matches[#matches + 1] = record
    end
  end
  local items = {}
  local last = math.min(#matches, offset + limit)
  for index = offset + 1, last do
    local record = matches[index]
    items[#items + 1] = {
      blueprintId = record.id,
      name = record.name,
      latestRevision = record.revisions[#record.revisions].revision,
      createdTick = record.created_tick,
      updatedTick = record.updated_tick
    }
  end
  -- Books are summaries only and are never paginated: one player owns at most
  -- 20 of them, so the whole collection is a few hundred bytes and always fits
  -- the response datagram. Member lists live behind blueprint.book.get, where
  -- exactly one book's 50 members are the bound.
  local books = nil
  local book_total = nil
  if include_books ~= false then
    books = {}
    for _, id in ipairs(inbox.book_order) do
      local book = inbox.books[id]
      if book and (not lowered or string.find(string.lower(book.name), lowered, 1, true)) then
        books[#books + 1] = {
          bookId = book.id,
          name = book.name,
          description = book.description,
          memberCount = #book.members,
          createdTick = book.created_tick,
          updatedTick = book.updated_tick
        }
      end
    end
    book_total = #books
  end
  return {
    blueprints = items,
    nextCursor = last < #matches and ("offset:" .. last) or nil,
    total = #matches,
    books = books,
    bookTotal = book_total
  }
end

-- The only removal a player or their assistant can ask for, and the only place
-- besides eviction that unmakes a record. It keeps every invariant
-- evict_oldest_until_fit leans on: the id leaves by_id and order together, and
-- the running byte total loses exactly what that record contributed. The inbox
-- is fetched by the caller's own player index, so no request can reach another
-- player's records.
function Blueprints.delete(context, blueprint_id)
  if type(blueprint_id) ~= "string" then
    return nil, "INVALID_BLUEPRINT_ID", "Blueprint ID must be a string"
  end
  local inbox = player_inbox(context.player_index)
  local record = inbox.by_id[blueprint_id]
  if not record then
    return nil, "BLUEPRINT_NOT_FOUND", "Blueprint is not in this player's AI inbox"
  end
  inbox.by_id[blueprint_id] = nil
  for index = #inbox.order, 1, -1 do
    if inbox.order[index] == blueprint_id then table.remove(inbox.order, index) end
  end
  local bytes = type(record.bytes) == "number" and record.bytes or 0
  inbox.bytes = math.max(0, inbox.bytes - bytes)
  -- Books hold references, so a deleted blueprint leaves every book that named
  -- it; the books themselves survive, because deleting one blueprint is not a
  -- request to unmake a grouping.
  forget_member(inbox, blueprint_id)
  return {
    blueprintId = blueprint_id,
    name = record.name,
    remainingCount = #inbox.order
  }
end

function Blueprints.load(context, blueprint_id, revision, delivery)
  if type(blueprint_id) ~= "string" then
    return nil, "INVALID_BLUEPRINT_ID", "Blueprint ID must be a string"
  end
  if delivery == "cursor" and not context.allow_cursor then
    return nil, "PLAYER_PREFERENCE_DENIED", "This player allows inbox delivery only"
  end
  local record = player_inbox(context.player_index).by_id[blueprint_id]
  if not record then
    return nil, "BLUEPRINT_NOT_FOUND", "Blueprint is not in this player's AI inbox"
  end
  local selected
  if revision == nil then
    selected = record.revisions[#record.revisions]
  else
    for _, candidate in ipairs(record.revisions) do
      if candidate.revision == revision then selected = candidate break end
    end
  end
  if not selected then
    return nil, "BLUEPRINT_REVISION_NOT_FOUND", "Blueprint revision does not exist"
  end
  if delivery == "cursor" then
    local delivered, code, message = deliver_to_clipboard(context.player, selected.layout)
    if not delivered then return nil, code, message end
  end
  return {
    blueprintId = record.id,
    revision = selected.revision,
    delivery = delivery,
    layout = clone_plain(selected.layout, 0)
  }
end

-- Everything below owns blueprint books. A book is built by reference: the
-- assistant saves each blueprint the way it always has, then names the IDs it
-- wants grouped. Nothing here accepts a layout, which is what keeps a book far
-- inside the 48 KiB gateway datagram no matter how large its members are.

function Blueprints.is_book_id(value)
  return type(value) == "string" and string.sub(value, 1, #BOOK_ID_PREFIX) == BOOK_ID_PREFIX
end

-- Factorio 2.1 exposes a blueprint book's pages as an ordinary inventory on the
-- item stack itself, and that inventory is dynamic: inserting a plain blueprint
-- item grows the book by one page. Each page is then written by the single
-- emitter this module already owns -- deliver_to_clipboard -- through a sink
-- that lands the finished stack in that page instead of a clipboard queue, so a
-- page and a delivered blueprint can never drift apart.
local function page_sink(page)
  return {
    valid = true,
    connected = true,
    add_to_clipboard = function(source) page.set_stack(source) end
  }
end

local function deliver_book(player, book, layouts)
  if not (player and player.valid and player.connected) then
    return nil, "PLAYER_NOT_CONNECTED", "Book delivery requires the paired player to be connected"
  end
  local inventory = game.create_inventory(1)
  local ok, reason = pcall(function()
    local stack = inventory[1]
    stack.set_stack({name = "blueprint-book", count = 1})
    local pages = stack.get_inventory(defines.inventory.item_main)
    if not (pages and pages.valid) then error("blueprint book exposes no page inventory") end
    for index, layout in ipairs(layouts) do
      if pages.insert({name = "blueprint", count = 1}) < 1 then
        error("blueprint book refused page " .. index)
      end
      local page = pages[index]
      if not (page and page.valid_for_read) then
        error("blueprint book page " .. index .. " is not readable")
      end
      local written, code, message = deliver_to_clipboard(page_sink(page), layout)
      if not written then error(tostring(message or code)) end
    end
    -- Cosmetic and guarded on purpose: a book whose label the running engine
    -- refuses is still a usable book, so naming it must never fail the delivery.
    pcall(function() stack.label = book.name end)
    pcall(function() stack.blueprint_description = book.description or "" end)
    player.add_to_clipboard(stack)
  end)
  inventory.destroy()
  if not ok then
    log("[Sceatorio] AI blueprint book delivery failed: " .. tostring(reason))
    return nil, "BLUEPRINT_BOOK_DELIVERY_FAILED", "Factorio rejected the generated blueprint book item"
  end
  return true
end

-- Every book-returning call answers with the same view, so an assistant sees
-- what it just did without a second round trip. A member whose record is gone
-- is skipped here as well as pruned at delete time: the view can only ever
-- describe blueprints this player still owns.
local function book_view(inbox, book)
  local members = {}
  for _, member_id in ipairs(book.members) do
    local record = inbox.by_id[member_id]
    if record then
      members[#members + 1] = {blueprintId = member_id, name = record.name}
    end
  end
  return {
    bookId = book.id,
    name = book.name,
    description = book.description,
    members = members,
    memberCount = #members,
    createdTick = book.created_tick,
    updatedTick = book.updated_tick
  }
end

-- Wholesale or not at all: a member list that names one blueprint this player
-- does not own, or names the same blueprint twice, is rejected before anything
-- is written. A book never half-applies an edit.
local function collect_members(inbox, blueprint_ids, taken)
  if type(blueprint_ids) ~= "table" then
    return nil, "INVALID_BOOK_MEMBERS", "blueprintIds must be an array of saved blueprint IDs"
  end
  local members = {}
  local seen = {}
  for _, id in ipairs(blueprint_ids) do
    if #members >= MAX_BOOK_MEMBERS then
      return nil, "INVALID_BOOK_MEMBERS", "a blueprint book holds at most " .. MAX_BOOK_MEMBERS .. " blueprints"
    end
    if type(id) ~= "string" then
      return nil, "INVALID_BLUEPRINT_ID", "every blueprint ID must be a string"
    end
    if seen[id] or (taken and taken[id]) then
      return nil, "DUPLICATE_BOOK_MEMBER", "a blueprint may appear in a book only once"
    end
    if not inbox.by_id[id] then
      return nil, "BLUEPRINT_NOT_FOUND", "one blueprint ID is not in this player's AI inbox"
    end
    seen[id] = true
    members[#members + 1] = id
  end
  if #members < 1 then
    return nil, "INVALID_BOOK_MEMBERS", "a blueprint book needs at least one blueprint ID"
  end
  return members
end

local function member_set(book)
  local set = {}
  local count = 0
  for _, id in ipairs(book.members) do
    set[id] = true
    count = count + 1
  end
  return set, count
end

function Blueprints.create_book(context, name, blueprint_ids, description)
  if not valid_string(name, 100) then
    return nil, "INVALID_BOOK_NAME", "Book name must contain 1 to 100 bytes"
  end
  if description ~= nil and (type(description) ~= "string" or #description > 1000) then
    return nil, "INVALID_BOOK_DESCRIPTION", "Book description may contain at most 1000 bytes"
  end
  local inbox = player_inbox(context.player_index)
  local members, code, message = collect_members(inbox, blueprint_ids, nil)
  if not members then return nil, code, message end
  -- Books are refused, never evicted: a grouping the player curated is cheap to
  -- keep and impossible to reconstruct, so a full shelf is an error the
  -- assistant can act on instead of a silent loss.
  if #inbox.book_order >= MAX_BOOKS_PER_PLAYER then
    return nil, "BLUEPRINT_BOOK_LIMIT_REACHED", "This player already holds " .. MAX_BOOKS_PER_PLAYER .. " blueprint books; delete one first"
  end
  local root = ai_root()
  -- One counter for both kinds, so a book ID can never collide with a
  -- blueprint ID and the prefix alone tells the two records apart.
  local id = BOOK_ID_PREFIX .. context.player_index .. ":" .. root.next_blueprint_id
  root.next_blueprint_id = root.next_blueprint_id + 1
  local book = {
    id = id,
    name = name,
    description = (type(description) == "string" and #description > 0) and description or nil,
    members = members,
    created_tick = game.tick,
    updated_tick = game.tick
  }
  inbox.books[id] = book
  inbox.book_order[#inbox.book_order + 1] = id
  local view = book_view(inbox, book)
  view.bookCount = #inbox.book_order
  return view
end

function Blueprints.load_book(context, book_id, delivery)
  if type(book_id) ~= "string" then
    return nil, "INVALID_BOOK_ID", "Book ID must be a string"
  end
  if delivery == "cursor" and not context.allow_cursor then
    return nil, "PLAYER_PREFERENCE_DENIED", "This player allows inbox delivery only"
  end
  local inbox = player_inbox(context.player_index)
  local book = inbox.books[book_id]
  if not book then
    return nil, "BLUEPRINT_BOOK_NOT_FOUND", "Blueprint book is not in this player's AI inbox"
  end
  if delivery == "cursor" then
    local layouts = {}
    for _, member_id in ipairs(book.members) do
      local record = inbox.by_id[member_id]
      if record then layouts[#layouts + 1] = record.revisions[#record.revisions].layout end
    end
    local delivered, code, message = deliver_book(context.player, book, layouts)
    if not delivered then return nil, code, message end
  end
  local view = book_view(inbox, book)
  view.delivery = delivery
  return view
end

-- The four edits a book supports, each player-scoped, each all-or-nothing, each
-- answering with the resulting member list. Ordering is explicit everywhere:
-- add takes an insertion position and reorder takes the complete new order,
-- which is the smallest pair that expresses every rearrangement without a
-- second "move" verb.
function Blueprints.update_book(context, payload)
  if type(payload) ~= "table" then
    return nil, "INVALID_REQUEST", "book update payload must be an object"
  end
  if type(payload.bookId) ~= "string" then
    return nil, "INVALID_BOOK_ID", "Book ID must be a string"
  end
  local inbox = player_inbox(context.player_index)
  local book = inbox.books[payload.bookId]
  if not book then
    return nil, "BLUEPRINT_BOOK_NOT_FOUND", "Blueprint book is not in this player's AI inbox"
  end
  local operation = payload.operation
  if operation == "rename" then
    if payload.name == nil and payload.description == nil then
      return nil, "INVALID_BOOK_UPDATE", "rename needs a name, a description, or both"
    end
    if payload.name ~= nil and not valid_string(payload.name, 100) then
      return nil, "INVALID_BOOK_NAME", "Book name must contain 1 to 100 bytes"
    end
    if payload.description ~= nil
      and (type(payload.description) ~= "string" or #payload.description > 1000) then
      return nil, "INVALID_BOOK_DESCRIPTION", "Book description may contain at most 1000 bytes"
    end
    if payload.name ~= nil then book.name = payload.name end
    if payload.description ~= nil then
      book.description = #payload.description > 0 and payload.description or nil
    end
  elseif operation == "add" then
    local taken = member_set(book)
    local additions, code, message = collect_members(inbox, payload.blueprintIds, taken)
    if not additions then return nil, code, message end
    if #book.members + #additions > MAX_BOOK_MEMBERS then
      return nil, "BOOK_MEMBER_LIMIT_REACHED", "a blueprint book holds at most " .. MAX_BOOK_MEMBERS .. " blueprints"
    end
    local position = #book.members + 1
    if payload.position ~= nil then
      if not integer(payload.position, 1, #book.members + 1) then
        return nil, "INVALID_BOOK_POSITION", "position must be between 1 and the current member count plus one"
      end
      position = payload.position
    end
    for offset, id in ipairs(additions) do
      table.insert(book.members, position + offset - 1, id)
    end
  elseif operation == "remove" then
    if type(payload.blueprintIds) ~= "table" then
      return nil, "INVALID_BOOK_MEMBERS", "blueprintIds must be an array of member blueprint IDs"
    end
    local present = member_set(book)
    local removals = {}
    local count = 0
    for _, id in ipairs(payload.blueprintIds) do
      if count >= MAX_BOOK_MEMBERS then
        return nil, "INVALID_BOOK_MEMBERS", "a blueprint book holds at most " .. MAX_BOOK_MEMBERS .. " blueprints"
      end
      if type(id) ~= "string" or removals[id] then
        return nil, "DUPLICATE_BOOK_MEMBER", "each member may be removed only once"
      end
      if not present[id] then
        return nil, "BOOK_MEMBER_NOT_FOUND", "one blueprint ID is not a member of this book"
      end
      removals[id] = true
      count = count + 1
    end
    if count < 1 then
      return nil, "INVALID_BOOK_MEMBERS", "removing needs at least one member blueprint ID"
    end
    for index = #book.members, 1, -1 do
      if removals[book.members[index]] then table.remove(book.members, index) end
    end
  elseif operation == "reorder" then
    if type(payload.blueprintIds) ~= "table" then
      return nil, "INVALID_BOOK_MEMBERS", "blueprintIds must list this book's current members"
    end
    local present, member_count = member_set(book)
    local ordered = {}
    local seen = {}
    for _, id in ipairs(payload.blueprintIds) do
      if type(id) ~= "string" or seen[id] or not present[id] then
        return nil, "BOOK_ORDER_MISMATCH", "reorder must list exactly this book's current members, once each"
      end
      seen[id] = true
      ordered[#ordered + 1] = id
    end
    if #ordered ~= member_count then
      return nil, "BOOK_ORDER_MISMATCH", "reorder must list exactly this book's current members, once each"
    end
    book.members = ordered
  else
    return nil, "INVALID_BOOK_OPERATION", "operation must be rename, add, remove, or reorder"
  end
  book.updated_tick = game.tick
  return book_view(inbox, book)
end

-- Deleting a book unmakes the grouping and nothing else: every blueprint it
-- named stays in the inbox, keeps its ID, and stays loadable.
function Blueprints.delete_book(context, book_id)
  if type(book_id) ~= "string" then
    return nil, "INVALID_BOOK_ID", "Book ID must be a string"
  end
  local inbox = player_inbox(context.player_index)
  local book = inbox.books[book_id]
  if not book then
    return nil, "BLUEPRINT_BOOK_NOT_FOUND", "Blueprint book is not in this player's AI inbox"
  end
  inbox.books[book_id] = nil
  for index = #inbox.book_order, 1, -1 do
    if inbox.book_order[index] == book_id then table.remove(inbox.book_order, index) end
  end
  return {
    bookId = book_id,
    name = book.name,
    releasedMemberCount = #book.members,
    remainingBookCount = #inbox.book_order
  }
end

return Blueprints
