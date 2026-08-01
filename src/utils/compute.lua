local Compute = {}

local CHUNK_SIZE = 32

function Compute.area_around(position, distance)
  return {
    left_top = {x = position.x - distance, y = position.y - distance},
    right_bottom = {x = position.x + distance, y = position.y + distance}
  }
end

local function chunk_area_is_ungenerated(chunk_position, chunk_distance, surface)
  for x = -chunk_distance, chunk_distance do
    for y = -chunk_distance, chunk_distance do
      if surface.is_chunk_generated({
        x = chunk_position.x + x,
        y = chunk_position.y + y
      }) then
        return false
      end
    end
  end
  return true
end

local function random_sign()
  return math.random(0, 1) == 1 and 1 or -1
end

function Compute.find_ungenerated_coordinates(minimum_chunks, maximum_chunks, surface)
  local minimum_squared = minimum_chunks * minimum_chunks
  local maximum_squared = maximum_chunks * maximum_chunks

  for _ = 1, 1000 do
    local chunk = {
      x = math.random(0, maximum_chunks) * random_sign(),
      y = math.random(0, maximum_chunks) * random_sign()
    }
    local squared = chunk.x * chunk.x + chunk.y * chunk.y
    if squared >= minimum_squared
      and squared <= maximum_squared
      and chunk_area_is_ungenerated(chunk, 10, surface) then
      return {
        x = chunk.x * CHUNK_SIZE + CHUNK_SIZE / 2,
        y = chunk.y * CHUNK_SIZE + CHUNK_SIZE / 2
      }
    end
  end
  return nil
end

function Compute.remove_in_circle(surface, area, entity_type, center, radius)
  local radius_squared = radius * radius
  for _, entity in pairs(surface.find_entities_filtered({area = area, type = entity_type})) do
    if entity.valid and entity.position then
      local dx = center.x - entity.position.x
      local dy = center.y - entity.position.y
      if dx * dx + dy * dy < radius_squared then
        entity.destroy()
      end
    end
  end
end

function Compute.crop_border(surface, center, area, radius, tile_name)
  local tiles = {}
  for x = area.left_top.x, area.right_bottom.x do
    for y = area.left_top.y, area.right_bottom.y do
      local maximum_axis = math.floor(math.max(math.abs(center.x - x), math.abs(center.y - y)))
      local diagonal = math.floor(math.abs(center.x - x) + math.abs(center.y - y))
      local distance = math.max(maximum_axis * 1.1, diagonal * 0.707 * 1.1)
      if distance < radius + 2 then
        tiles[#tiles + 1] = {name = tile_name, position = {x, y}}
      end
      if distance < radius and distance > radius - 10 and prototypes.entity["tree-03"] then
        surface.create_entity({name = "tree-03", position = {x, y}})
      end
    end
  end
  surface.set_tiles(tiles)
end

function Compute.water_border(surface, center, area, radius, modifier)
  local radius_squared = radius * radius
  local outer_squared = radius_squared + modifier
  if outer_squared <= 0 then
    surface.set_tiles({})
    return
  end
  -- The predicate cannot match outside this radius. Preserve the original
  -- unit-step coordinate sequence while intersecting the caller's area with
  -- that compact square, so large safety areas do not cause empty work.
  local outer_radius = math.ceil(math.sqrt(outer_squared))
  local function clamp_axis(first, last, minimum, maximum)
    local clamped_first = first + math.max(0, math.ceil(minimum - first))
    local clamped_last = first + math.min(last - first, math.floor(maximum - first))
    return clamped_first, clamped_last
  end
  local minimum_x, maximum_x = clamp_axis(
    area.left_top.x,
    area.right_bottom.x,
    center.x - outer_radius,
    center.x + outer_radius
  )
  local minimum_y, maximum_y = clamp_axis(
    area.left_top.y,
    area.right_bottom.y,
    center.y - outer_radius,
    center.y + outer_radius
  )
  local tiles = {}
  for x = minimum_x, maximum_x do
    for y = minimum_y, maximum_y do
      local dx = center.x - x
      local dy = center.y - y
      local squared = math.floor(dx * dx + dy * dy)
      if squared > radius_squared and squared < radius_squared + modifier then
        tiles[#tiles + 1] = {name = "water", position = {x, y}}
      end
    end
  end
  surface.set_tiles(tiles)
end

function Compute.create_terrain(surface, center, area, radius, tile_name)
  local tiles = {}
  for x = area.left_top.x, area.right_bottom.x do
    for y = area.left_top.y, area.right_bottom.y do
      local maximum_axis = math.floor(math.max(math.abs(center.x - x), math.abs(center.y - y)))
      local diagonal = math.floor(math.abs(center.x - x) + math.abs(center.y - y))
      local distance = math.max(maximum_axis * 1.1, diagonal * 0.707 * 1.1)
      if distance < radius + 2 then
        tiles[#tiles + 1] = {name = tile_name, position = {x, y}}
      end
    end
  end
  surface.set_tiles(tiles)
end

function Compute.generate_resource_patch(surface, resource_name, diameter, position, amount)
  if diameter <= 0 then return end
  for y = 0, diameter do
    for x = 0, diameter do
      surface.create_entity({
        name = resource_name,
        amount = amount,
        position = {position.x + x, position.y + y}
      })
    end
  end
end

function Compute.create_water_strip(surface, left_position, length)
  local tiles = {}
  for offset = 0, length do
    tiles[#tiles + 1] = {
      name = "water",
      position = {left_position.x + offset, left_position.y}
    }
  end
  surface.set_tiles(tiles)
end

return Compute
