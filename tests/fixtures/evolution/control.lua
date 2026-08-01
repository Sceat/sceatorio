local SECONDARY_SURFACE_NAME = "evolution-fixture-secondary"
local WORM_RAW = 0.1
local SPAWNER_RAW = 0.3
local POLLUTION_RAW_PER_UNIT = 0.002
local MINIMUM_CONSUMED_POLLUTION = 1
local EPSILON = 0.0000001
local loaded_from_save = false
local checkpoint_created_this_process = false
local EvolutionMath = require("__Sceatorio__/src/game/evolution_math")
local State = require("__Sceatorio__/src/core/state")

local function fail(reason)
  error("SCEATORIO_EVOLUTION_FAIL: " .. reason)
end

local function approximately(first, second)
  return math.abs(first - second) <= EPSILON
end

local function factor_from_raw(raw)
  return raw / (1 + raw)
end

local function assert_factor(force, surface, expected, label)
  local actual = force.get_evolution_factor(surface)
  if not approximately(actual, expected) then
    fail(string.format("%s expected %.9f, found %.9f", label, expected, actual))
  end
end

local function register_team(name, label)
  local force = game.create_force(name)
  local result = remote.call("sceatorio_teams", "register_force", force.name, nil, label)
  if not result.ok then fail(result.error or ("could not register " .. name)) end
  local enemy = game.forces[result.enemy_force_name]
  if not (enemy and enemy.valid) then fail("paired enemy is missing for " .. name) end
  return force, enemy
end

local function create_victim(surface, name, force, anchor)
  local position = surface.find_non_colliding_position(name, anchor, 96, 1)
  if not position then fail("no valid position for " .. name) end
  local entity = surface.create_entity({name = name, position = position, force = force})
  if not (entity and entity.valid) then fail("could not create " .. name) end
  return entity
end

local function kill(surface, name, victim_force, killer_force, anchor)
  local entity = create_victim(surface, name, victim_force, anchor)
  if not entity.die(killer_force) then fail(name .. " did not die") end
end

local function set_evolution_enabled(value)
  local result = remote.call("sceatorio_dev_tools", "set_evolution_enabled", value)
  if not (result.ok and result.enabled == value) then
    fail(result.error or "could not change team evolution policy")
  end
end

local function assert_all(fixture, suffix)
  local nauvis = game.surfaces.nauvis
  local secondary = game.surfaces[fixture.secondary_surface_index]
  local first_enemy = game.forces[fixture.first_enemy_name]
  local second_enemy = game.forces[fixture.second_enemy_name]
  local third_enemy = fixture.third_enemy_name and game.forces[fixture.third_enemy_name] or nil
  if not (secondary and first_enemy and second_enemy) then
    fail("saved evolution objects are missing " .. suffix)
  end
  assert_factor(first_enemy, secondary, fixture.first_secondary_factor, "first secondary " .. suffix)
  assert_factor(first_enemy, nauvis, fixture.first_nauvis_factor, "first nauvis " .. suffix)
  assert_factor(second_enemy, nauvis, fixture.second_nauvis_factor, "second nauvis " .. suffix)
  assert_factor(second_enemy, secondary, 0, "second secondary " .. suffix)
  if third_enemy then
    assert_factor(third_enemy, nauvis, fixture.third_nauvis_factor, "third nauvis " .. suffix)
  end
end

local function advance_pollution_expectation(fixture, units)
  local raw = units * POLLUTION_RAW_PER_UNIT
  fixture.first_nauvis_raw = fixture.first_nauvis_raw + raw
  fixture.second_nauvis_raw = fixture.second_nauvis_raw + raw
  if fixture.third_enemy_name then
    fixture.third_nauvis_raw = fixture.third_nauvis_raw + raw
  end
  fixture.first_nauvis_factor = factor_from_raw(fixture.first_nauvis_raw)
  fixture.second_nauvis_factor = factor_from_raw(fixture.second_nauvis_raw)
  fixture.third_nauvis_factor = factor_from_raw(fixture.third_nauvis_raw)
end

local function biter_spawner_output(surface)
  local statistics = surface.pollution_statistics
  if not (statistics and statistics.valid) then
    fail("surface pollution statistics are unavailable")
  end
  local count = statistics.output_counts["biter-spawner"] or 0
  if type(count) ~= "number" or count < 0 or count ~= count then
    fail("biter-spawner pollution output is invalid")
  end
  return count
end

local function begin_spawner_consumption(fixture, phase, anchor)
  local nauvis = game.surfaces.nauvis
  local spawner = create_victim(nauvis, "biter-spawner", game.forces.enemy, anchor)
  fixture.pollution_output_start = biter_spawner_output(nauvis)
  fixture.pollution_spawner = spawner
  nauvis.pollute(spawner.position, 1000, "stone-furnace")
  fixture.phase = phase
  fixture.next_tick = 0
end

local function finish_spawner_consumption(fixture)
  local nauvis = game.surfaces.nauvis
  local current = biter_spawner_output(nauvis)
  local consumed = current - fixture.pollution_output_start
  if consumed < MINIMUM_CONSUMED_POLLUTION then return nil end
  local spawner = fixture.pollution_spawner
  if not (spawner and spawner.valid) then
    fail("controlled pollution-consuming spawner disappeared")
  end
  spawner.destroy()
  fixture.pollution_spawner = nil
  fixture.pollution_output_start = nil
  return consumed
end

local function assert_disabled_time_accounting()
  local ledger = {
    connected_ticks = 0,
    raw_time = 0,
    connected_since = 0,
    connected_progression_enabled = true,
    connected_time_coefficient = 0.5
  }
  local ticks_per_minute = 60

  -- The interval ending at disable is still enabled time.
  EvolutionMath.sync_connected_time(
    ledger, 60, true, false, 0.75, ticks_per_minute
  )
  if ledger.connected_ticks ~= 60 or not approximately(ledger.raw_time, 0.5) then
    fail("connected-time interval before disable was not accounted")
  end

  -- Diagnostics continue while disabled, without raw evolution.
  EvolutionMath.sync_connected_time(
    ledger, 120, true, false, 1, ticks_per_minute
  )
  if ledger.connected_ticks ~= 120 or not approximately(ledger.raw_time, 0.5) then
    fail("disabled connected-time diagnostics did not advance cleanly")
  end

  -- Re-enabling applies the new policy only to the next interval, so the
  -- disabled interval ending here is not back-charged.
  EvolutionMath.sync_connected_time(
    ledger, 180, true, true, 1, ticks_per_minute
  )
  if ledger.connected_ticks ~= 180 or not approximately(ledger.raw_time, 0.5) then
    fail("disabled connected time was back-charged on re-enable")
  end
  EvolutionMath.sync_connected_time(
    ledger, 240, true, true, 1, ticks_per_minute
  )
  if ledger.connected_ticks ~= 240 or not approximately(ledger.raw_time, 1.5) then
    fail("connected-time evolution did not resume after re-enable")
  end
end

local function assert_pollution_interval_accounting()
  local ledger = {
    raw_pollution = 0,
    pollution_units = 0,
    pollution_cursor = 0,
    pollution_progression_enabled = true,
    pollution_coefficient = 0.002
  }
  local maximum = 1e300

  -- The prior coefficient/policy owns the interval ending at disable.
  EvolutionMath.sync_pollution(
    ledger, {units = 10, affects_evolution = true}, false, 0.004, maximum
  )
  if ledger.pollution_units ~= 10 or not approximately(ledger.raw_pollution, 0.02) then
    fail("pollution interval before disable used the new policy or coefficient")
  end

  EvolutionMath.sync_pollution(
    ledger, {units = 20, affects_evolution = true}, false, 0.008, maximum
  )
  EvolutionMath.sync_pollution(
    ledger, {units = 30, affects_evolution = true}, true, 0.008, maximum
  )
  if ledger.pollution_units ~= 30 or not approximately(ledger.raw_pollution, 0.02) then
    fail("disabled pollution was charged before or during re-enable")
  end

  EvolutionMath.sync_pollution(
    ledger, {units = 40, affects_evolution = true}, true, 0.008, maximum
  )
  if ledger.pollution_units ~= 40 or not approximately(ledger.raw_pollution, 0.1) then
    fail("pollution evolution did not resume with the current coefficient")
  end
end

local function assert_pollution_semantics_migration()
  local fixture_record_id = 999999
  local ledger = {
    raw_pollution = 0.25,
    pollution_units = 125,
    pollution_cursor = 125,
    pollution_progression_enabled = true,
    pollution_coefficient = 0.002
  }
  local root = {
    teams_by_id = {
      [fixture_record_id] = {surfaces = {[1] = {evolution = ledger}}}
    }
  }
  State.migrate_pollution_statistics_semantics(root, 4)

  if ledger.raw_pollution ~= 0.25 then fail("migration subtracted credited evolution") end
  if ledger.pollution_cursor ~= nil or ledger.pollution_units ~= 0
    or ledger.pollution_progression_enabled ~= nil
    or ledger.pollution_coefficient ~= nil then
    fail("migration did not rebaseline incompatible pollution statistics")
  end
end

script.on_init(function()
  assert_disabled_time_accounting()
  assert_pollution_interval_accounting()
  assert_pollution_semantics_migration()
  storage.evolution_fixture = {phase = "create", deadline = game.tick + 2400}
end)

script.on_load(function()
  loaded_from_save = true
end)

script.on_event(defines.events.on_tick, function()
  local fixture = storage.evolution_fixture
  if not fixture then fail("fixture storage is missing") end
  if game.tick > fixture.deadline then fail("fixture timed out in phase " .. fixture.phase) end

  if fixture.phase == "create" then
    local first, first_enemy = register_team("evolution-fixture-alpha", "Evolution alpha")
    local second, second_enemy = register_team("evolution-fixture-beta", "Evolution beta")
    local nauvis = game.surfaces.nauvis
    local secondary = game.create_surface(SECONDARY_SURFACE_NAME, {
      width = 256,
      height = 256,
      no_enemies_mode = true,
      property_expression_names = {
        ["tile:water:probability"] = -1000,
        ["tile:deepwater:probability"] = -1000
      }
    })
    secondary.request_to_generate_chunks({x = 0, y = 0}, 4)
    secondary.force_generate_chunk_requests()

    first_enemy.set_evolution_factor(0.25, secondary)
    assert_factor(first_enemy, secondary, 0.25, "engine setter/getter roundtrip")
    first_enemy.set_evolution_factor(0, secondary)

    local vanilla = game.map_settings.enemy_evolution
    if vanilla.enabled then fail("vanilla evolution was not disabled") end
    vanilla.time_factor = 1
    vanilla.destroy_factor = 1
    vanilla.pollution_factor = 1

    kill(secondary, "small-worm-turret", first_enemy, second, {x = -48, y = -48})
    kill(secondary, "small-worm-turret", game.forces.enemy, first, {x = -16, y = -48})
    assert_factor(first_enemy, secondary, 0, "rejected kill attribution")

    kill(secondary, "small-worm-turret", first_enemy, first, {x = 16, y = -48})
    kill(secondary, "biter-spawner", first_enemy, first, {x = 48, y = -48})
    kill(nauvis, "small-worm-turret", second_enemy, second, {x = 96, y = 96})

    fixture.first_force_name = first.name
    fixture.first_enemy_name = first_enemy.name
    fixture.second_force_name = second.name
    fixture.second_enemy_name = second_enemy.name
    fixture.secondary_surface_index = secondary.index
    fixture.first_secondary_factor = factor_from_raw(WORM_RAW + SPAWNER_RAW)
    fixture.first_nauvis_raw = 0
    fixture.second_nauvis_raw = WORM_RAW
    fixture.third_nauvis_raw = 0
    fixture.first_nauvis_factor = 0
    fixture.second_nauvis_factor = factor_from_raw(WORM_RAW)
    fixture.third_nauvis_factor = 0
    nauvis.pollution_statistics.clear()
    fixture.next_tick = game.tick + 65
    fixture.phase = "baseline"
    return
  end

  if game.tick < (fixture.next_tick or 0) then return end

  if fixture.phase == "baseline" then
    assert_all(fixture, "before pollution")
    -- Gross attributed emissions alone must not evolve enemies. Evolution is
    -- charged only after a unit spawner consumes pollution from the cloud.
    game.surfaces.nauvis.pollute({x = 0, y = 0}, 50, "stone-furnace")
    fixture.next_tick = game.tick + 65
    fixture.phase = "gross-emission"
    return
  end

  if fixture.phase == "gross-emission" then
    assert_all(fixture, "after gross emissions without nest consumption")
    local statistics = game.surfaces.nauvis.pollution_statistics
    if (statistics.input_counts["stone-furnace"] or 0) < 50 then
      fail("attributed gross pollution was absent from input statistics")
    end
    if biter_spawner_output(game.surfaces.nauvis) ~= 0 then
      fail("unexpected unit-spawner consumption before controlled nest creation")
    end
    begin_spawner_consumption(fixture, "wait-shared-consumption", {x = 0, y = 0})
    return
  end

  if fixture.phase == "wait-shared-consumption" then
    local consumed = finish_spawner_consumption(fixture)
    if not consumed then return end
    advance_pollution_expectation(fixture, consumed)
    fixture.next_tick = game.tick + 65
    fixture.phase = "shared-pollution"
    return
  end

  if fixture.phase == "shared-pollution" then
    assert_all(fixture, "after shared unit-spawner pollution consumption")
    local third, third_enemy = register_team("evolution-fixture-gamma", "Evolution gamma")
    fixture.third_force_name = third.name
    fixture.third_enemy_name = third_enemy.name
    fixture.next_tick = game.tick + 65
    fixture.phase = "late-team-baseline"
    return
  end

  if fixture.phase == "late-team-baseline" then
    assert_all(fixture, "after late team baseline")
    set_evolution_enabled(false)
    begin_spawner_consumption(fixture, "wait-frozen-consumption", {x = 32, y = 0})
    return
  end

  if fixture.phase == "wait-frozen-consumption" then
    local consumed = finish_spawner_consumption(fixture)
    if not consumed then return end
    fixture.next_tick = game.tick + 65
    fixture.phase = "frozen"
    return
  end

  if fixture.phase == "frozen" then
    assert_all(fixture, "while evolution frozen")
    set_evolution_enabled(true)
    fixture.next_tick = game.tick + 65
    fixture.phase = "reenabled"
    return
  end

  if fixture.phase == "reenabled" then
    assert_all(fixture, "after re-enable without backcharge")
    begin_spawner_consumption(fixture, "wait-post-reenable-consumption", {x = 64, y = 0})
    return
  end

  if fixture.phase == "wait-post-reenable-consumption" then
    local consumed = finish_spawner_consumption(fixture)
    if not consumed then return end
    advance_pollution_expectation(fixture, consumed)
    fixture.next_tick = game.tick + 65
    fixture.phase = "post-reenable"
    return
  end

  if fixture.phase == "post-reenable" then
    assert_all(fixture, "after new enabled pollution")
    game.surfaces.nauvis.pollution_statistics.clear()
    fixture.next_tick = game.tick + 65
    fixture.phase = "reset-baseline"
    return
  end

  if fixture.phase == "reset-baseline" then
    assert_all(fixture, "after statistics reset")
    begin_spawner_consumption(fixture, "wait-post-reset-consumption", {x = 96, y = 0})
    return
  end

  if fixture.phase == "wait-post-reset-consumption" then
    local consumed = finish_spawner_consumption(fixture)
    if not consumed then return end
    advance_pollution_expectation(fixture, consumed)
    fixture.next_tick = game.tick + 65
    fixture.phase = "post-reset"
    return
  end

  if fixture.phase == "post-reset" then
    assert_all(fixture, "after reset continuation")
    if game.map_settings.enemy_evolution.enabled then
      fail("vanilla evolution policy drifted back on")
    end
    fixture.phase = "await-reload"
    checkpoint_created_this_process = true
    game.server_save("evolution-checkpoint")
    log("SCEATORIO_EVOLUTION_CHECKPOINT: server save requested")
    return
  end

  if fixture.phase == "await-reload" and loaded_from_save
    and not checkpoint_created_this_process then
    if game.map_settings.enemy_evolution.enabled then
      fail("disabled vanilla evolution did not survive reload")
    end
    assert_all(fixture, "after reload")
    begin_spawner_consumption(fixture, "wait-reload-consumption", {x = 128, y = 0})
    return
  end

  if fixture.phase == "wait-reload-consumption" then
    local consumed = finish_spawner_consumption(fixture)
    if not consumed then return end
    advance_pollution_expectation(fixture, consumed)
    fixture.next_tick = game.tick + 65
    fixture.phase = "reload-pollution"
    return
  end

  if fixture.phase == "reload-pollution" then
    assert_all(fixture, "after reload pollution continuation")
    local secondary = game.surfaces[fixture.secondary_surface_index]
    local first = game.forces[fixture.first_force_name]
    local first_enemy = game.forces[fixture.first_enemy_name]
    kill(secondary, "small-worm-turret", first_enemy, first, {x = 0, y = 48})
    fixture.first_secondary_factor = factor_from_raw(WORM_RAW + SPAWNER_RAW + WORM_RAW)
    assert_all(fixture, "after persisted kill continuation")
    log(
      "SCEATORIO_EVOLUTION_PASS: team/surface kills, surface-global unit-spawner "
        .. "pollution consumption, gross-emission rejection, freeze/re-enable, "
        .. "reset baseline, late team, and reload verified"
    )
    fixture.phase = "passed"
  end
end)
