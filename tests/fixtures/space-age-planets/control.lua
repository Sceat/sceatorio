local PLANETS = {"nauvis", "vulcanus", "fulgora", "gleba", "aquilo"}
local loaded_from_save = false
local checkpoint_created_this_process = false

local function fail(reason)
  error("SCEATORIO_PLANET_FIXTURE_FAIL: " .. reason)
end

local function native_snapshot(surface)
  local area = {{-48, -48}, {48, 48}}
  local tiles = {}
  for x = -48, 44, 4 do
    for y = -48, 44, 4 do
      local name = surface.get_tile(x, y).name
      tiles[name] = (tiles[name] or 0) + 1
    end
  end
  return {
    tiles = tiles,
    resources = surface.count_entities_filtered({area = area, type = "resource"}),
    cliffs = surface.count_entities_filtered({area = area, type = "cliff"}),
    decoratives = #surface.find_decoratives_filtered({area = area})
  }
end

local function same_counts(first, second)
  if first.resources ~= second.resources or first.cliffs ~= second.cliffs
    or first.decoratives ~= second.decoratives then
    return false
  end
  for name, count in pairs(first.tiles) do
    if second.tiles[name] ~= count then return false end
  end
  for name, count in pairs(second.tiles) do
    if first.tiles[name] ~= count then return false end
  end
  return true
end

local function register_team(name, display_name, nauvis_spawn)
  local force = game.create_force(name)
  force.set_spawn_position(nauvis_spawn, game.surfaces.nauvis)
  local result = remote.call(
    "sceatorio_teams",
    "register_force",
    force.name,
    nil,
    display_name
  )
  if not result.ok then fail(result.error or "team registration failed") end
  return force, game.forces[result.enemy_force_name]
end

local function create_existing_hostile(surface, force)
  for _, name in ipairs({
    "gleba-spawner",
    "gleba-spawner-small",
    "small-worm-turret",
    "small-wriggler-pentapod",
    "small-strafer-pentapod",
    "small-stomper-pentapod",
    "small-biter"
  }) do
    for x = -60, 92, 4 do
      for y = -60, 92, 4 do
        local position = {x = x, y = y}
        if x * x + y * y > 20 * 20
          and surface.can_place_entity({name = name, position = position, force = force}) then
          local entity = surface.create_entity({
            name = name,
            position = position,
            force = force
          })
          if entity and entity.valid then return entity, {x = x, y = y} end
        end
      end
    end
  end
  fail("could not place existing generated-chunk hostile outside the safe radius")
end

local function status(force_name, surface_name)
  local result = remote.call(
    "sceatorio_dev_tools",
    "planet_spawn_status",
    force_name,
    surface_name
  )
  if not result.ok then fail(result.error or "planet status failed") end
  return result
end

local function same_position(first, second)
  return first and second and first.x == second.x and first.y == second.y
end

script.on_init(function()
  storage.planet_fixture = {phase = "create", native = {}, surfaces = {}}
end)

script.on_load(function()
  loaded_from_save = true
end)

script.on_event(defines.events.on_tick, function()
  local fixture = storage.planet_fixture
  if not fixture then fail("fixture storage is missing") end

  if fixture.phase == "create" then
    local first, first_enemy = register_team(
      "planet-fixture-alpha",
      "Planet alpha",
      {x = 0, y = 0}
    )
    local second, second_enemy = register_team(
      "planet-fixture-beta",
      "Planet beta",
      {x = 2048, y = 0}
    )
    fixture.first_force = first.name
    fixture.second_force = second.name
    fixture.first_enemy_force = first_enemy.name
    fixture.second_enemy_force = second_enemy.name

    for _, planet_name in ipairs(PLANETS) do
      local planet = game.planets[planet_name]
      if not (planet and planet.valid) then fail("missing planet " .. planet_name) end
      local surface = planet.surface or planet.create_surface()
      if not (surface and surface.valid and surface.planet == planet) then
        fail("invalid associated surface for " .. planet_name)
      end
      surface.request_to_generate_chunks({x = 0, y = 0}, 3)
      surface.force_generate_chunk_requests()
      fixture.surfaces[planet_name] = surface.index
      fixture.native[planet_name] = native_snapshot(surface)

      if planet_name == "gleba" then
        -- These chunks already exist before either reservation, so no future
        -- on_chunk_generated event can classify their hostiles.
        fixture.default_gleba_hostile, fixture.default_gleba_hostile_position = create_existing_hostile(
          surface,
          game.forces.enemy
        )
        fixture.other_team_gleba_hostile = create_existing_hostile(
          surface,
          second_enemy
        )
      end

      for _, force_name in ipairs({first.name, second.name}) do
        local result = remote.call(
          "sceatorio_dev_tools",
          "reserve_planet_spawn",
          force_name,
          surface.name,
          {x = 0, y = 0}
        )
        if not result.ok or not result.supported then
          fail("reservation rejected for " .. force_name .. " on " .. planet_name)
        end
      end
    end

    first.unlock_space_platforms()
    local platform = first.create_space_platform({
      name = "Planet fixture platform",
      planet = "nauvis",
      starter_pack = {name = "space-platform-starter-pack", quality = "normal"}
    })
    if platform and platform.valid then platform.apply_starter_pack(true) end
    local platform_surface = platform and platform.valid and platform.surface or nil
    if not (platform_surface and platform_surface.valid) then
      fail("could not create a real platform surface")
    end
    fixture.platform_index = platform_surface.index
    local rejected = remote.call(
      "sceatorio_dev_tools",
      "reserve_planet_spawn",
      first.name,
      platform_surface.name,
      {x = 0, y = 0}
    )
    if rejected.ok or rejected.supported ~= false then
      fail("platform surface was accepted as a planet")
    end
    fixture.phase = "await-ready"
    return
  end

  if fixture.phase == "await-ready" then
    for _, planet_name in ipairs(PLANETS) do
      local surface = game.surfaces[fixture.surfaces[planet_name]]
      local first = status(fixture.first_force, surface.name)
      local second = status(fixture.second_force, surface.name)
      if first.state ~= "ready" or second.state ~= "ready" then return end
      if not (first.spawn and second.spawn and first.preserve_native
        and second.preserve_native) then
        fail("ready metadata is incomplete on " .. planet_name)
      end
      local dx = first.spawn.x - second.spawn.x
      local dy = first.spawn.y - second.spawn.y
      if dx * dx + dy * dy < 128 * 128 then
        fail("team spawns are not separated on " .. planet_name)
      end
      local stable = remote.call(
        "sceatorio_dev_tools",
        "reserve_planet_spawn",
        fixture.first_force,
        surface.name,
        {x = 99999, y = 99999}
      )
      if not stable.ok or stable.state ~= "ready"
        or not same_position(stable.spawn, first.spawn) then
        fail("stable spawn changed on " .. planet_name)
      end
      if not same_counts(fixture.native[planet_name], native_snapshot(surface)) then
        fail("native tiles/resources/cliffs/decoratives changed on " .. planet_name)
      end
      if planet_name == "gleba" then
        local default_hostile = fixture.default_gleba_hostile
        local other_hostile = fixture.other_team_gleba_hostile
        local hostile_position = fixture.default_gleba_hostile_position
        local actual_enemy = default_hostile and default_hostile.valid
          and default_hostile.force.name or "invalid"
        if not (default_hostile and default_hostile.valid)
          or (actual_enemy ~= fixture.first_enemy_force
            and actual_enemy ~= fixture.second_enemy_force) then
          fail(string.format(
            "existing generated-chunk %s missed paired-enemy assignment (actual=%s initial=%.1f,%.1f current=%.1f,%.1f)",
            default_hostile and default_hostile.valid and default_hostile.name or "invalid",
            actual_enemy,
            hostile_position.x,
            hostile_position.y,
            default_hostile and default_hostile.valid and default_hostile.position.x or -1,
            default_hostile and default_hostile.valid and default_hostile.position.y or -1
          ))
        end
        if not (other_hostile and other_hostile.valid)
          or other_hostile.force.name ~= fixture.second_enemy_force then
          fail("another team's paired hostile was changed during finalization")
        end
      end
    end

    fixture.phase = "await-reload"
    checkpoint_created_this_process = true
    game.server_save("space-age-planets-checkpoint")
    log("SCEATORIO_PLANET_CHECKPOINT: server save requested")
    return
  end

  if fixture.phase == "await-reload" and loaded_from_save
    and not checkpoint_created_this_process then
    for _, planet_name in ipairs(PLANETS) do
      local surface = game.surfaces[fixture.surfaces[planet_name]]
      local first = status(fixture.first_force, surface.name)
      local second = status(fixture.second_force, surface.name)
      if first.state ~= "ready" or second.state ~= "ready"
        or not first.spawn or not second.spawn then
        fail("stable records did not survive reload on " .. planet_name)
      end
    end
    local platform_surface = game.surfaces[fixture.platform_index]
    local platform_status = remote.call(
      "sceatorio_dev_tools",
      "planet_spawn_status",
      fixture.first_force,
      platform_surface.name
    )
    if not platform_status.ok or platform_status.supported ~= false then
      fail("platform exclusion did not survive reload")
    end
    log(
      "SCEATORIO_PLANET_PASS: five planets, two teams, separation, stability, "
        .. "native preservation, platform exclusion, and reload verified"
    )
    fixture.phase = "passed"
  end
end)
