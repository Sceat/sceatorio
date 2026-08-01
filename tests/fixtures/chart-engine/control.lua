local FAR_CHUNK = {x = 100, y = 100}
local RADAR_POSITION = {x = 1024, y = 0}

local function fail(reason)
  error("SCEATORIO_CHART_ENGINE_FAIL: " .. reason)
end

local function count_state(surface, forces)
  local result = {known = 0, generated = 0, charted = {}, requested = {}, visible = {}}
  for _, force in ipairs(forces) do
    result.charted[force.name] = 0
    result.requested[force.name] = 0
    result.visible[force.name] = 0
  end
  for chunk in surface.get_chunks() do
    result.known = result.known + 1
    local position = {x = chunk.x, y = chunk.y}
    if surface.is_chunk_generated(position) then result.generated = result.generated + 1 end
    for _, force in ipairs(forces) do
      if force.is_chunk_charted(surface, position) then
        result.charted[force.name] = result.charted[force.name] + 1
      end
      if force.is_chunk_requested_for_charting(surface, position) then
        result.requested[force.name] = result.requested[force.name] + 1
      end
      if force.is_chunk_visible(surface, position) then
        result.visible[force.name] = result.visible[force.name] + 1
      end
    end
  end
  return result
end

local function print_state(label, value)
  local fields = {label, "known=" .. value.known, "generated=" .. value.generated}
  local names = {}
  for name in pairs(value.charted) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    fields[#fields + 1] = name .. ".charted=" .. value.charted[name]
    fields[#fields + 1] = name .. ".requested=" .. value.requested[name]
    fields[#fields + 1] = name .. ".visible=" .. value.visible[name]
  end
  log("SCEATORIO_CHART_ENGINE_COUNTS " .. table.concat(fields, " "))
end

local function assert_same_terrain(before, after, label)
  if before.generated ~= after.generated then
    fail(
      label .. " generated terrain: " .. before.generated .. "->" .. after.generated
    )
  end
end

local function assert_requests_are_generated(surface, forces)
  for chunk in surface.get_chunks() do
    local position = {x = chunk.x, y = chunk.y}
    for _, force in ipairs(forces) do
      if force.is_chunk_requested_for_charting(surface, position)
        and not surface.is_chunk_generated(position) then
        fail(
          force.name .. " requested ungenerated chunk "
            .. position.x .. ":" .. position.y
        )
      end
    end
  end
end

script.on_init(function()
  game.speed = 4
  storage.fixture = {
    phase = "setup",
    generated_events = 0,
    charted_events = 0
  }
end)

script.on_event(defines.events.on_chunk_generated, function()
  if storage.fixture then
    storage.fixture.generated_events = storage.fixture.generated_events + 1
  end
end)

script.on_event(defines.events.on_chunk_charted, function(event)
  local fixture = storage.fixture
  if not fixture then return end
  fixture.charted_events = fixture.charted_events + 1
  if fixture.charted_events <= 8 then
    log(
      "SCEATORIO_CHART_ENGINE_EVENT tick=" .. event.tick
        .. " force=" .. event.force.name
        .. " chunk=" .. event.position.x .. ":" .. event.position.y
    )
  end
end)

script.on_nth_tick(1, function(event)
  local fixture = storage.fixture
  local surface = game.surfaces.nauvis

  if fixture.phase == "setup" then
    surface.request_to_generate_chunks(RADAR_POSITION, 5)
    surface.force_generate_chunk_requests()

    local first = game.create_force("chart-engine-a")
    local second = game.create_force("chart-engine-b")
    local automatic = count_state(surface, {first, second})
    print_state("new-force", automatic)
    for _, force in ipairs({first, second}) do
      if automatic.requested[force.name] ~= 0 then
        fail("new force unexpectedly had pending chart work: " .. force.name)
      end
      force.cancel_charting(surface)
    end
    fixture.force_names = {first.name, second.name}
    fixture.clear_observe_tick = event.tick + 10
    fixture.phase = "observe-clear"
    return
  end

  if fixture.phase == "observe-clear" and event.tick >= fixture.clear_observe_tick then
    local first = game.forces[fixture.force_names[1]]
    local second = game.forces[fixture.force_names[2]]
    local after_clear = count_state(surface, {first, second})
    print_state("after-force-reset", after_clear)
    for _, force in ipairs({first, second}) do
      if after_clear.requested[force.name] ~= 0 then
        fail("force reset retained pending chart work for " .. force.name)
      end
    end

    local first_result = remote.call(
      "sceatorio_teams", "register_force", first.name, nil, "Chart A"
    )
    local second_result = remote.call(
      "sceatorio_teams", "register_force", second.name, nil, "Chart B"
    )
    if not (first_result.ok and second_result.ok) then fail("team registration failed") end

    local first_enemy = game.forces[first_result.enemy_force_name]
    local second_enemy = game.forces[second_result.enemy_force_name]
    local paired_enemies = count_state(surface, {first_enemy, second_enemy})
    print_state("production-enemy-cleanup", paired_enemies)
    for _, force in ipairs({first_enemy, second_enemy}) do
      if paired_enemies.requested[force.name] ~= 0 then
        fail("production left an origin request on " .. force.name)
      end
    end
    for _, force in ipairs({first, second}) do
      force.cancel_charting(surface)
    end

    -- Moving a force's spawn after cancellation must not seed another engine
    -- request; only a connected character at that position should discover it.
    first.set_spawn_position(RADAR_POSITION, surface)
    second.set_spawn_position(RADAR_POSITION, surface)
    local after_spawn_move = count_state(surface, {first, second})
    if after_spawn_move.requested[first.name] ~= 0
      or after_spawn_move.requested[second.name] ~= 0 then
      fail("set_spawn_position seeded new chart requests")
    end

    local radar = surface.create_entity({
      name = "radar",
      position = RADAR_POSITION,
      force = first,
      raise_built = true
    })
    if not (radar and radar.valid) then fail("could not create team radar") end
    fixture.baseline = count_state(surface, {first, second})
    fixture.baseline_generated_events = fixture.generated_events
    fixture.baseline_charted_events = fixture.charted_events
    fixture.status_before = remote.call("sceatorio_teams", "chart_status")
    print_state("baseline", fixture.baseline)
    fixture.phase = "wait-first-pass"
    return
  end

  local forces = {
    game.forces[fixture.force_names[1]],
    game.forces[fixture.force_names[2]]
  }

  if fixture.phase == "wait-first-pass" and event.tick >= 610 then
    fixture.after_first = count_state(surface, forces)
    print_state("after-first-pass", fixture.after_first)
    assert_same_terrain(fixture.baseline, fixture.after_first, "first radar pass")
    assert_requests_are_generated(surface, forces)
    local status = remote.call("sceatorio_teams", "chart_status")
    log(
      "SCEATORIO_CHART_ENGINE_FIRST passes=" .. status.passes
        .. " radars=" .. status.source_radars
        .. " examined=" .. status.chunks_examined
        .. " generated_guard_passes=" .. status.generated_chunks
        .. " writes=" .. status.chart_writes
    )
    if status.mode ~= "bounded-entity-scan"
      or status.passes - fixture.status_before.passes ~= 1
      or status.source_radars - fixture.status_before.source_radars ~= 1
      or status.chunks_examined - fixture.status_before.chunks_examined ~= 64
      or status.generated_chunks - fixture.status_before.generated_chunks ~= 64
      or status.chart_writes <= fixture.status_before.chart_writes
      or status.chart_writes - fixture.status_before.chart_writes > 128 then
      fail("first production pass telemetry was not exactly bounded")
    end
    fixture.first_writes = status.chart_writes
    -- A live server retires a chart request within a few ticks; a headless save
    -- with no connected client never processes the queue, so drain it by hand.
    -- Without this the in-flight guard alone would hide the cadence the second
    -- pass is here to prove.
    for _, force in ipairs(forces) do
      force.cancel_charting(surface)
    end
    fixture.drained = count_state(surface, forces)
    print_state("requests-drained", fixture.drained)
    fixture.phase = "wait-second-pass"
    return
  end

  if fixture.phase == "wait-second-pass" and event.tick >= 1210 then
    local after_second = count_state(surface, forces)
    print_state("after-second-pass", after_second)
    assert_same_terrain(fixture.after_first, after_second, "repeated radar pass")
    if after_second.known ~= fixture.after_first.known then
      fail("repeated radar pass expanded chart metadata")
    end
    assert_requests_are_generated(surface, forces)
    for _, force in ipairs(forces) do
      if after_second.requested[force.name] > 64 then
        fail("bounded pass requested an unexpected chunk count for " .. force.name)
      end
    end

    if surface.is_chunk_generated(FAR_CHUNK) then fail("far chunk unexpectedly generated") end
    local rejected = remote.call(
      "sceatorio_radars", "share_chunk", forces[1].name, surface.name, FAR_CHUNK
    )
    if rejected.ok or rejected.error ~= "chunk is not generated" then
      fail("remote wrapper accepted an ungenerated chunk")
    end
    local after_rejection = count_state(surface, forces)
    assert_same_terrain(after_second, after_rejection, "remote rejection")
    if after_rejection.known ~= after_second.known then
      fail("remote rejection expanded chart metadata")
    end

    local status = remote.call("sceatorio_teams", "chart_status")
    local second_writes = status.chart_writes - fixture.first_writes
    -- Cadence, not just bounds: the second pass covers the same source
    -- footprint and must chart it again. A no-op here is the 20-second bug,
    -- where a teammate's marker goes dark for a whole interval because the
    -- refresh only lands on every other pass.
    if second_writes <= 0 then
      fail("second production pass refreshed nothing for the same footprint")
    end
    if status.passes - fixture.status_before.passes ~= 2
      or status.source_radars - fixture.status_before.source_radars ~= 2
      or status.chunks_examined - fixture.status_before.chunks_examined ~= 128
      or status.generated_chunks - fixture.status_before.generated_chunks ~= 128
      or second_writes > 128
      or status.remote_rejections ~= 1 then
      fail("repeated production pass telemetry was not exactly bounded")
    end
    log(
      "SCEATORIO_CHART_ENGINE_STATUS generated=" .. after_rejection.generated
        .. " known=" .. after_rejection.known
        .. " generated_event_delta="
        .. (fixture.generated_events - fixture.baseline_generated_events)
        .. " charted_event_delta="
        .. (fixture.charted_events - fixture.baseline_charted_events)
        .. " passes=" .. status.passes
        .. " requested_per_force_max=64"
        .. " writes=" .. status.chart_writes
        .. " second_pass_writes=" .. second_writes
    )
    log("SCEATORIO_CHART_ENGINE_PASS")
    fixture.phase = "done"
  end
end)
