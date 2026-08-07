local POLE_A_POSITION = {x = 100, y = 100}
local POLE_B_POSITION = {x = 116, y = 100}
local SILENT_FOREIGN_CONSUMER_POSITION = {x = 142, y = 120}
local SILENT_CHILD_POLE_POSITION = {x = 146, y = 120}
local SILENT_ORIGIN_POSITION = {x = 150, y = 120}
local DENSE_CLUSTER_CENTER = {x = 300, y = 300}
local DENSE_CONSUMER_POSITION = {x = 295.5, y = 295.5}
local DENSE_CLUSTER_RADIUS = 9
local DENSE_CLUSTER_MIN_ENTITIES = 290
local POLE_GRID_ORIGIN = {x = 500, y = 500}
local POLE_GRID_SPAN = 4
local POLE_GRID_CONSUMER_POSITION = {x = 505.5, y = 505.5}
local POLE_GRID_MIN_POLES = 20
local SHARED_CHUNK = {x = 3, y = 3}
local FAR_UNGENERATED_CHUNK = {x = 10000, y = 10000}

local function fail(reason)
  error("SCEATORIO_SECURITY_FAIL: " .. reason)
end

local function fixture_entity(entity)
  if not (entity and entity.valid) then fail("fixture entity became invalid") end
  return entity
end

local function force_count()
  local count = 0
  for _ in pairs(game.forces) do count = count + 1 end
  return count
end

script.on_init(function()
  storage.security_fixture = {phase = "create-forces"}
end)

script.on_nth_tick(1, function(event)
  local fixture = storage.security_fixture
  if not fixture then fail("missing fixture state") end

  if fixture.phase == "create-forces" then
    local initial_force_count = force_count()
    local system = game.create_force("sceatorio-team-1")
    local first = game.create_force("security-fixture-a")
    local second = game.create_force("security-fixture-b")
    if force_count() ~= initial_force_count + 3 then
      fail("unexpected force creation side effect")
    end
    if game.forces["sceatorio-enemy-1"] then
      fail("on_force_created adopted an empty third-party force")
    end

    local first_result = remote.call(
      "sceatorio_teams",
      "register_force",
      first.name,
      nil,
      "Security fixture A"
    )
    local second_result = remote.call(
      "sceatorio_teams",
      "register_force",
      second.name,
      nil,
      "Security fixture B"
    )
    if not (first_result.ok and second_result.ok) then
      fail("explicit team registration failed")
    end
    if first_result.id == 1 or first_result.enemy_force_name == "sceatorio-enemy-1" then
      fail("internal-looking third-party force name was overwritten")
    end
    local surface = game.surfaces.nauvis
    first.set_spawn_position(POLE_A_POSITION, surface)
    second.set_spawn_position(POLE_B_POSITION, surface)
    surface.request_to_generate_chunks(SILENT_ORIGIN_POSITION, 2)
    surface.request_to_generate_chunks(DENSE_CLUSTER_CENTER, 2)
    surface.request_to_generate_chunks(POLE_GRID_ORIGIN, 2)
    surface.force_generate_chunk_requests()
    fixture.system_force_name = system.name
    fixture.first_enemy_force_name = first_result.enemy_force_name
    fixture.second_enemy_force_name = second_result.enemy_force_name
    fixture.first_team_id = first_result.id
    fixture.second_team_id = second_result.id
    fixture.phase = "wait-for-sceatorio"
    return
  end

  if fixture.phase == "wait-for-sceatorio" and event.tick >= 2 then
    if not (
      game.forces[fixture.first_enemy_force_name]
      and game.forces[fixture.second_enemy_force_name]
    ) then
      fail("explicitly registered teams did not receive paired enemies")
    end
    if game.forces["sceatorio-enemy-1"] then
      fail("allocator reused a third-party force's reserved numeric identity")
    end

    local surface = game.surfaces.nauvis
    local first_force = game.forces["security-fixture-a"]
    local second_force = game.forces["security-fixture-b"]
    local first_enemy = game.forces[fixture.first_enemy_force_name]
    local second_enemy = game.forces[fixture.second_enemy_force_name]
    if first_force.get_friend(second_force) or first_force.get_cease_fire(second_force) then
      fail("team registration changed human-team diplomacy")
    end
    if first_enemy.get_friend(first_force) or first_enemy.get_cease_fire(first_force) then
      fail("paired enemy is not hostile to its owner")
    end
    if first_enemy.get_friend(second_force) or first_enemy.get_cease_fire(second_force) then
      fail("paired enemy is not hostile to the other human team")
    end
    if not (first_enemy.get_friend(second_enemy) and first_enemy.get_friend(game.forces.enemy)) then
      fail("paired enemy families are not mutually isolated")
    end

    local first = surface.create_entity({
      name = "substation",
      position = POLE_A_POSITION,
      force = first_force,
      raise_built = true
    })
    local second = surface.create_entity({
      name = "substation",
      position = POLE_B_POSITION,
      force = second_force,
      raise_built = true
    })
    if not (first and first.valid and second and second.valid) then
      fail("could not create fixture substations")
    end
    local foreign_consumer = surface.create_entity({
      name = "assembling-machine-1",
      position = SILENT_FOREIGN_CONSUMER_POSITION,
      force = first_force
    })
    local origin = surface.create_entity({
      name = "assembling-machine-1",
      position = SILENT_ORIGIN_POSITION,
      force = second_force,
      raise_built = true
    })
    if not (foreign_consumer and foreign_consumer.valid and origin and origin.valid) then
      fail("could not create silent-child compatibility fixture entities")
    end
    if origin.name ~= "assembling-machine-1" then
      fail("deferred origin was invalid before the creating script resumed")
    end
    -- This emulates Cargo Oil Rig creating an unannounced same-force child pole
    -- after the visible parent build event. The pole supplies both the visible
    -- origin and a pre-existing entity belonging to the other team.
    local silent_child = surface.create_entity({
      name = "substation",
      position = SILENT_CHILD_POLE_POSITION,
      force = second_force
    })
    if not (silent_child and silent_child.valid) then
      fail("could not create silent composite child pole")
    end

    fixture.first = first
    fixture.second = second
    fixture.silent_foreign_consumer = foreign_consumer
    fixture.silent_origin = origin
    fixture.silent_child = silent_child
    local third = game.create_force("security-fixture-c")
    local result = remote.call(
      "sceatorio_teams",
      "register_force",
      third.name,
      nil,
      "Security fixture C"
    )
    if not result.ok then fail("new team registration failed") end
    fixture.third_enemy_force_name = result.enemy_force_name
    local status = remote.call("sceatorio_teams", "chart_status")
    if status.mode ~= "bounded-entity-scan" then
      fail("bounded chart-sharing mode was not active")
    end
    fixture.silent_child_reject_tick = event.tick + 3
    fixture.phase = "verify-silent-child-reject"
    return
  end

  if fixture.phase == "verify-silent-child-reject"
    and event.tick >= fixture.silent_child_reject_tick then
    if fixture.silent_origin.valid then
      fail("deferred audit retained a parent with a conflicting silent child pole")
    end
    if fixture.silent_child.valid then
      fail("deferred audit retained the unannounced conflicting child pole")
    end
    fixture_entity(fixture.silent_foreign_consumer)
    fixture.phase = "dense-single-team"
    return
  end

  -- A legitimate pole inside one team's own dense base must survive the deferred
  -- audit: only another team's entities may count toward the saturation bound.
  if fixture.phase == "dense-single-team" then
    local surface = game.surfaces.nauvis
    local force = game.forces["security-fixture-a"]
    local center = DENSE_CLUSTER_CENTER
    local low = DENSE_CLUSTER_RADIUS
    local high = DENSE_CLUSTER_RADIUS - 1
    local tiles = {}
    for x = center.x - low - 1, center.x + low do
      for y = center.y - low - 1, center.y + low do
        tiles[#tiles + 1] = {name = "grass-1", position = {x, y}}
      end
    end
    surface.set_tiles(tiles)
    local area = {
      {center.x - low - 1, center.y - low - 1},
      {center.x + low + 1, center.y + low + 1}
    }
    for _, entity in pairs(surface.find_entities_filtered({area = area})) do
      if entity.valid then entity.destroy() end
    end

    local created = 0
    for x = center.x - low, center.x + high do
      for y = center.y - low, center.y + high do
        -- Leave the two-by-two substation and three-by-three machine footprints free.
        local reserved = (
          x >= center.x - 1 and x <= center.x
          and y >= center.y - 1 and y <= center.y
        ) or (
          x >= DENSE_CONSUMER_POSITION.x - 2 and x <= DENSE_CONSUMER_POSITION.x + 1
          and y >= DENSE_CONSUMER_POSITION.y - 2 and y <= DENSE_CONSUMER_POSITION.y + 1
        )
        if not reserved then
          local belt = surface.create_entity({
            name = "transport-belt",
            position = {x + 0.5, y + 0.5},
            force = force,
            direction = defines.direction.north
          })
          if belt and belt.valid then created = created + 1 end
        end
      end
    end
    if created < DENSE_CLUSTER_MIN_ENTITIES then
      fail("could not build the dense single-team cluster")
    end

    local dense_pole = surface.create_entity({
      name = "substation",
      position = center,
      force = force,
      raise_built = true
    })
    if not (dense_pole and dense_pole.valid) then
      fail("could not create the dense single-team substation")
    end
    -- The deferred audit reaches the saturation bound through a supplied
    -- consumer, so the legitimate build under test is powered by that pole.
    local dense_consumer = surface.create_entity({
      name = "assembling-machine-1",
      position = DENSE_CONSUMER_POSITION,
      force = force,
      raise_built = true
    })
    if not (dense_consumer and dense_consumer.valid) then
      fail("could not create the dense single-team consumer")
    end
    fixture.dense_pole = dense_pole
    fixture.dense_consumer = dense_consumer
    fixture.dense_verify_tick = event.tick + 3
    fixture.phase = "verify-dense-single-team"
    return
  end

  if fixture.phase == "verify-dense-single-team"
    and event.tick >= fixture.dense_verify_tick then
    if not (fixture.dense_pole and fixture.dense_pole.valid) then
      fail("deferred audit refunded a legitimate pole inside a dense single-team area")
    end
    if not (fixture.dense_consumer and fixture.dense_consumer.valid) then
      fail("deferred audit refunded a legitimate build inside a dense single-team area")
    end
    fixture.phase = "registered-pole-grid"
    return
  end

  -- A normal mid-game own-team pole grid: every pole here went through the mod's
  -- build path, so all of them are registered. Only poles the registry has never
  -- seen are unannounced composite children, so a dense registered grid must not
  -- push the deferred audit over its silent-child bound.
  if fixture.phase == "registered-pole-grid" then
    local surface = game.surfaces.nauvis
    local force = game.forces["security-fixture-a"]
    local origin = POLE_GRID_ORIGIN
    local low = -2
    local high = POLE_GRID_SPAN * 2 + 3
    local tiles = {}
    for x = origin.x + low, origin.x + high do
      for y = origin.y + low, origin.y + high do
        tiles[#tiles + 1] = {name = "grass-1", position = {x, y}}
      end
    end
    surface.set_tiles(tiles)
    local area = {
      {origin.x + low, origin.y + low},
      {origin.x + high + 1, origin.y + high + 1}
    }
    for _, entity in pairs(surface.find_entities_filtered({area = area})) do
      if entity.valid then entity.destroy() end
    end

    local consumer_position = POLE_GRID_CONSUMER_POSITION
    local poles = {}
    for column = 0, POLE_GRID_SPAN do
      for row = 0, POLE_GRID_SPAN do
        local position = {x = origin.x + 2 * column + 0.5, y = origin.y + 2 * row + 0.5}
        -- Leave the three-by-three machine footprint free.
        local reserved = math.abs(position.x - consumer_position.x) < 2
          and math.abs(position.y - consumer_position.y) < 2
        if not reserved then
          -- raise_built takes each pole through the mod's normal build path, so
          -- the security pole registry records it exactly like a player build.
          local pole = surface.create_entity({
            name = "small-electric-pole",
            position = position,
            force = force,
            raise_built = true
          })
          if not (pole and pole.valid) then
            fail("could not build the registered own-team pole grid")
          end
          poles[#poles + 1] = pole
        end
      end
    end
    if #poles < POLE_GRID_MIN_POLES then
      fail("registered own-team pole grid was too small to exceed the child bound")
    end

    local consumer = surface.create_entity({
      name = "assembling-machine-1",
      position = consumer_position,
      force = force,
      raise_built = true
    })
    if not (consumer and consumer.valid) then
      fail("could not build the consumer inside the registered pole grid")
    end
    -- Without power the deferred audit returns before its bound, so an unpowered
    -- consumer would make this case pass vacuously.
    if not consumer.electric_network_id then
      fail("registered-grid consumer was not supplied by the surrounding poles")
    end
    fixture.grid_poles = poles
    fixture.grid_consumer = consumer
    fixture.grid_verify_tick = event.tick + 8
    fixture.phase = "verify-registered-pole-grid"
    return
  end

  if fixture.phase == "verify-registered-pole-grid"
    and event.tick >= fixture.grid_verify_tick then
    for _, pole in pairs(fixture.grid_poles) do
      if not (pole and pole.valid) then
        fail("deferred audit refunded a registered own-team pole inside a dense pole grid")
      end
    end
    if not (fixture.grid_consumer and fixture.grid_consumer.valid) then
      fail("deferred audit refunded a legitimate build inside a dense registered pole grid")
    end
    fixture.phase = "connect"
    return
  end

  if fixture.phase == "connect" then
    local first = fixture_entity(fixture.first)
    local second = fixture_entity(fixture.second)
    local first_connector = first.get_wire_connector(
      defines.wire_connector_id.pole_copper,
      false
    )
    local second_connector = second.get_wire_connector(
      defines.wire_connector_id.pole_copper,
      false
    )
    if not first_connector.connect_to(
      second_connector,
      true,
      defines.wire_origin.player
    ) then
      fail("could not create cross-team manual copper link")
    end
    if not first_connector.is_connected_to(
      second_connector,
      defines.wire_origin.player
    ) then
      fail("manual copper link was not established")
    end
    fixture.wire_verify_tick = event.tick + 40
    fixture.phase = "verify"
    return
  end

  if fixture.phase == "verify" and event.tick >= fixture.wire_verify_tick then
    local first = fixture_entity(fixture.first)
    local second = fixture_entity(fixture.second)
    local first_connector = first.get_wire_connector(
      defines.wire_connector_id.pole_copper,
      false
    )
    local second_connector = second.get_wire_connector(
      defines.wire_connector_id.pole_copper,
      false
    )
    if first_connector.is_connected_to(
      second_connector,
      defines.wire_origin.player
    ) then
      fail("bounded audit did not remove manual cross-team copper link")
    end
    fixture.before_merge_force_count = force_count()
    game.merge_forces(
      game.forces["security-fixture-a"],
      game.forces["security-fixture-b"]
    )
    fixture.merge_verify_tick = event.tick + 2
    fixture.phase = "verify-force-merge"
    return
  end

  if fixture.phase == "verify-force-merge" and event.tick >= fixture.merge_verify_tick then
    if game.forces["security-fixture-a"] then
      fail("merged human source force remained present")
    end
    if game.forces[fixture.first_enemy_force_name] then
      fail("merged team's paired enemy became orphaned")
    end
    if force_count() ~= fixture.before_merge_force_count - 2 then
      fail("team merge did not remove exactly one team/enemy pair")
    end

    local destination = game.forces["security-fixture-b"]
    local result = remote.call(
      "sceatorio_teams",
      "register_force",
      destination.name,
      nil,
      "Must remain idempotent"
    )
    if not result.ok or result.id ~= fixture.second_team_id
      or result.enemy_force_name ~= fixture.second_enemy_force_name then
      fail("merged destination lost or duplicated its team identity")
    end
    local destination_enemy = game.forces[result.enemy_force_name]
    local third_force = game.forces["security-fixture-c"]
    if destination_enemy.get_friend(destination)
      or destination_enemy.get_cease_fire(destination) then
      fail("merged destination's paired enemy is no longer hostile to its owner")
    end
    if destination_enemy.get_friend(third_force)
      or destination_enemy.get_cease_fire(third_force)
      or not destination_enemy.get_friend(game.forces[fixture.third_enemy_force_name]) then
      fail("enemy hostility matrix was not rebuilt after force merge")
    end

    local surface = game.surfaces.nauvis
    if not surface.is_chunk_generated(SHARED_CHUNK) then
      fail("shared chart target chunk was not generated")
    end
    destination.clear_chart(surface)
    third_force.clear_chart(surface)

    local uncharted = remote.call(
      "sceatorio_radars",
      "share_chunk",
      destination.name,
      surface.name,
      SHARED_CHUNK
    )
    if uncharted.ok or uncharted.error ~= "source team has not charted this chunk" then
      fail("source team has not charted check did not fail closed")
    end

    if surface.is_chunk_generated(FAR_UNGENERATED_CHUNK) then
      fail("far chart fixture chunk was unexpectedly generated")
    end
    local ungenerated = remote.call(
      "sceatorio_radars",
      "share_chunk",
      destination.name,
      surface.name,
      FAR_UNGENERATED_CHUNK
    )
    if ungenerated.ok or ungenerated.error ~= "chunk is not generated" then
      fail("chunk is not generated check did not fail closed")
    end
    if surface.is_chunk_generated(FAR_UNGENERATED_CHUNK) then
      fail("rejected chart request generated terrain")
    end

    log(
      "SCEATORIO_SECURITY_PASS: force isolation, generated-only chart rejection, force merge, and wire audit passed"
    )
    fixture.phase = "passed"
    return
  end
end)
