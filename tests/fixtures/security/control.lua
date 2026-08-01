local POLE_A_POSITION = {x = 100, y = 100}
local POLE_B_POSITION = {x = 116, y = 100}
local SILENT_FOREIGN_CONSUMER_POSITION = {x = 142, y = 120}
local SILENT_CHILD_POLE_POSITION = {x = 146, y = 120}
local SILENT_ORIGIN_POSITION = {x = 150, y = 120}
local CHART_AREA = {{x = 0, y = 0}, {x = 32, y = 32}}
local CHART_QUEUE_CAPACITY = 4096
local RECOVERY_CHUNK = {x = 3, y = 3}

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
    if not (first_enemy.get_friend(second_force) and first_enemy.get_cease_fire(second_force)) then
      fail("paired enemy is not isolated from the other human team")
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
    -- LuaForce.chart and powered radars on playerless forces do not raise
    -- on_chunk_charted in 2.1.12. This still executes production copy_chart
    -- reconciliation for a newly registered team without exposing a remote
    -- map-reveal test hook. Incremental fanout needs a connected client test.
    first_force.chart(surface, CHART_AREA)
    local third = game.create_force("security-fixture-c")
    local result = remote.call(
      "sceatorio_teams",
      "register_force",
      third.name,
      nil,
      "Security fixture C"
    )
    if not result.ok then fail("new team registration/chart union failed") end
    fixture.third_enemy_force_name = result.enemy_force_name
    local status = remote.call("sceatorio_teams", "chart_status")
    if status.queue_depth ~= 0 or status.total_enqueued ~= 0
      or status.total_propagated ~= 0 then
      fail("chart-copy reconciliation recursively entered incremental fanout")
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
    if not (
      destination_enemy.get_friend(third_force)
      and destination_enemy.get_cease_fire(third_force)
      and destination_enemy.get_friend(game.forces[fixture.third_enemy_force_name])
    ) then
      fail("enemy isolation matrix was not rebuilt after force merge")
    end

    local surface = game.surfaces.nauvis
    if not surface.is_chunk_generated(RECOVERY_CHUNK) then
      fail("radar recovery target chunk was not generated")
    end
    if third_force.is_chunk_charted(surface, RECOVERY_CHUNK) then
      fail("radar recovery target was already shared before the stress case")
    end
    for index = 1, CHART_QUEUE_CAPACITY do
      local result = remote.call(
        "sceatorio_radars",
        "share_chunk",
        destination.name,
        surface.name,
        {x = 10000 + index, y = 10000}
      )
      if not result.ok or result.queued ~= 1 then
        fail("could not fill the bounded radar queue")
      end
    end
    local deferred = remote.call(
      "sceatorio_radars",
      "share_chunk",
      destination.name,
      surface.name,
      RECOVERY_CHUNK
    )
    if not deferred.ok or deferred.queued ~= 0 then
      fail("radar overflow target was not deferred")
    end
    local radar = remote.call("sceatorio_teams", "chart_status")
    if radar.queue_capacity ~= CHART_QUEUE_CAPACITY
      or radar.queue_depth ~= CHART_QUEUE_CAPACITY
      or radar.max_queue_depth > radar.queue_capacity
      or radar.total_deferred < 1
      or radar.catchup_surface_count ~= 1
      or not radar.backpressure_active then
      fail("radar queue did not enter bounded backpressure")
    end
    fixture.drain_deadline = event.tick + 900
    fixture.phase = "wait-for-version-catchup"
    return
  end

  if fixture.phase == "wait-for-version-catchup" then
    local status = remote.call("sceatorio_teams", "chart_status")
    if event.tick >= fixture.drain_deadline then
      fail("chart catch-up never exposed a generated uncharted chunk")
    end
    local surface = game.surfaces.nauvis
    local destination = game.forces["security-fixture-b"]
    local third_force = game.forces["security-fixture-c"]
    local canonical = game.forces["sceatorio-chart-union"]
    local position = status.last_catchup_chunk
    if status.total_catchup_scanned > 0
      and status.catchup_surface_count == 1
      and status.last_catchup_surface_index == surface.index
      and position
      and not destination.is_chunk_charted(surface, position)
      and not third_force.is_chunk_charted(surface, position)
      and not canonical.is_chunk_charted(surface, position) then
      local missing = CHART_QUEUE_CAPACITY - status.queue_depth
      for index = 1, missing do
        local result = remote.call(
          "sceatorio_radars",
          "share_chunk",
          destination.name,
          surface.name,
          {x = 20000 + index, y = 20000}
        )
        if not result.ok or result.queued ~= 1 then
          fail("could not refill the radar queue during catch-up")
        end
      end
      local deferred = remote.call(
        "sceatorio_radars",
        "share_chunk",
        destination.name,
        surface.name,
        position
      )
      if not deferred.ok or deferred.queued ~= 0 then
        fail("mid-pass radar discovery was not deferred")
      end
      local after = remote.call("sceatorio_teams", "chart_status")
      if after.queue_depth ~= CHART_QUEUE_CAPACITY
        or after.total_deferred <= status.total_deferred then
        fail("mid-pass overflow did not version the catch-up job")
      end
      fixture.restart_before = status.total_catchup_restarts
      fixture.phase = "wait-for-chart-drain"
    end
    return
  end

  if fixture.phase == "wait-for-chart-drain" then
    local status = remote.call("sceatorio_teams", "chart_status")
    local drained = status.queue_depth == 0 and status.pending_count == 0
      and status.suppression_count == 0 and status.catchup_surface_count == 0
      and not status.backpressure_active
    if not drained then
      if event.tick >= fixture.drain_deadline then
        fail("chart propagation did not drain")
      end
      return
    end
    if status.suppression_generations ~= 2 then
      fail("chart recursion guards are not limited to two tick generations")
    end
    if status.max_queue_depth > status.queue_capacity
      or status.total_deferred < 1
      or status.total_catchup_passes < 1
      or status.total_catchup_restarts <= fixture.restart_before
      or status.total_backpressure_recoveries < 1 then
      fail("chart backpressure telemetry did not report bounded recovery")
    end
    log(
      "SCEATORIO_SECURITY_PASS: force isolation, chart sync, force merge, and wire audit passed"
    )
    fixture.phase = "passed"
  end
end)
