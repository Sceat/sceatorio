local State = require("src.core.state")

local Blueprints = {}

local MAX_ENTITIES = 512
local MAX_TILES = 2048
local MAX_BLUEPRINTS_PER_PLAYER = 100
local MAX_BLUEPRINT_BYTES_PER_PLAYER = 512 * 1024
local BLUEPRINT_INBOX_SCHEMA_VERSION = 2
local MAX_ISSUES = 100

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

-- Persist only the documented safe-layout subset. Validation deliberately
-- tolerates unknown JSON keys for forward compatibility; they must not become
-- an unbounded side channel into the save file.
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
    add_issue(errors, "INVALID_ENTITY_COUNT", "layout.entities", "layout must contain 1 to 512 entities")
    return {valid = false, errors = errors, warnings = warnings, summary = summary}
  end
  if layout.tiles ~= nil and (type(layout.tiles) ~= "table" or #layout.tiles > MAX_TILES) then
    add_issue(errors, "INVALID_TILE_COUNT", "layout.tiles", "layout may contain at most 2048 tiles")
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
      if is_nonempty_table(entity.items) then
        add_issue(errors, "ITEM_REQUESTS_UNSUPPORTED", path .. ".items", "item insert plans are not accepted by the v1 safe blueprint subset")
      end
      if is_nonempty_table(entity.settings) then
        add_issue(errors, "ENTITY_SETTINGS_UNSUPPORTED", path .. ".settings", "arbitrary entity settings are not accepted by the v1 safe blueprint subset")
      end
      if prototype then
        item_cost_for(prototype, build_cost)
        validate_recipe(entity, prototype, context.force, errors, path)
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
  return {valid = #errors == 0, errors = errors, warnings = warnings, summary = summary}
end

local DEFAULT_CONNECTOR = {
  red = function() return defines.wire_connector_id.circuit_red end,
  green = function() return defines.wire_connector_id.circuit_green end,
  copper = function() return defines.wire_connector_id.pole_copper end
}

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
    stack.label = layout.name
    stack.blueprint_description = layout.description or ""
    stack.set_blueprint_entities(blueprint_entities(layout))
    if #(layout.tiles or {}) > 0 then
      stack.set_blueprint_tiles(blueprint_tiles(layout))
    end
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
      or #canonical.entities > MAX_ENTITIES then return nil end
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

  inbox.schema_version = BLUEPRINT_INBOX_SCHEMA_VERSION
  inbox.order = order
  inbox.by_id = by_id
  inbox.bytes = bytes
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
      bytes = 0
    }
    root.blueprint_inbox[player_index] = inbox
  end
  if inbox.schema_version ~= BLUEPRINT_INBOX_SCHEMA_VERSION
    or type(inbox.order) ~= "table"
    or type(inbox.by_id) ~= "table"
    or type(inbox.bytes) ~= "number" then
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

function Blueprints.list(context, query, pagination)
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
  return {
    blueprints = items,
    nextCursor = last < #matches and ("offset:" .. last) or nil,
    total = #matches
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

return Blueprints
