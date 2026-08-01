local ENTITY_COUNT = 10000
local GRID_WIDTH = 100
local ORIGINAL_FALSE_STRIDE = 10
local GRID_ORIGIN = {x = 384, y = 384}

local loaded_from_save = false
local checkpoint_created_this_process = false

local function fail(reason)
  error("SCEATORIO_OFFLINE_PERFORMANCE_FAIL: " .. reason)
end

local function require_entity(entity, label)
  if not (entity and entity.valid) then fail(label .. " entity is invalid") end
  return entity
end

local function position_for(index)
  local zero = index - 1
  return {
    x = GRID_ORIGIN.x + (zero % GRID_WIDTH),
    y = GRID_ORIGIN.y + math.floor(zero / GRID_WIDTH)
  }
end

local function transition(fixture, protected, label)
  local profiler = helpers.create_profiler()
  local result = remote.call(
    "sceatorio_dev_tools",
    "set_offline_protection",
    fixture.force_name,
    protected,
    false
  )
  profiler.stop()
  if not result.ok then fail(result.error or (label .. " transition failed")) end
  if result.status ~= nil then fail(label .. " unexpectedly allocated a status result") end
  log({
    "",
    "SCEATORIO_OFFLINE_PERFORMANCE_MEASURE: ",
    label,
    " entities=",
    ENTITY_COUNT,
    " tick=",
    game.tick,
    " wall=",
    profiler
  })
end

local function verify_protected(fixture, label)
  local protected = 0
  for index = 1, ENTITY_COUNT do
    local entity = require_entity(fixture.entities[index], label)
    if entity.destructible then
      fail(string.format("%s left entity %d destructible", label, index))
    end
    protected = protected + 1
  end
  if protected ~= ENTITY_COUNT then fail(label .. " count mismatch") end
end

local function verify_restored(fixture, label)
  local restored_true = 0
  local restored_false = 0
  for index = 1, ENTITY_COUNT do
    local entity = require_entity(fixture.entities[index], label)
    local expected = index % ORIGINAL_FALSE_STRIDE ~= 0
    if entity.destructible ~= expected then
      fail(string.format("%s restored entity %d to the wrong state", label, index))
    end
    if expected then restored_true = restored_true + 1
    else restored_false = restored_false + 1 end
  end
  if restored_true ~= 9000 or restored_false ~= 1000 then
    fail(string.format(
      "%s restored unexpected true/false counts %d/%d",
      label,
      restored_true,
      restored_false
    ))
  end
end

local function create_workload(fixture)
  local setup_profiler = helpers.create_profiler()
  local force = game.create_force("offline-performance-team")
  local registration = remote.call(
    "sceatorio_teams",
    "register_force",
    force.name,
    nil,
    "Offline performance team"
  )
  if not registration.ok then fail(registration.error or "team registration failed") end

  local surface = game.surfaces.nauvis
  local center = position_for(math.floor(ENTITY_COUNT / 2))
  surface.request_to_generate_chunks(center, 3)
  surface.force_generate_chunk_requests()

  local tiles = {}
  for index = 1, ENTITY_COUNT do
    tiles[index] = {name = "refined-concrete", position = position_for(index)}
  end
  surface.set_tiles(tiles, true, true, true, false)

  fixture.force_name = force.name
  fixture.entities = {}
  for index = 1, ENTITY_COUNT do
    local entity = require_entity(surface.create_entity({
      name = "stone-wall",
      position = position_for(index),
      force = force,
      create_build_effect_smoke = false
    }), "created wall")
    if index % ORIGINAL_FALSE_STRIDE == 0 then entity.destructible = false end
    fixture.entities[index] = entity
    script.raise_script_built({entity = entity})
    if entity.destructible then
      fail(string.format("registration did not immediately protect entity %d", index))
    end
  end
  setup_profiler.stop()
  log({
    "",
    "SCEATORIO_OFFLINE_PERFORMANCE_WORKLOAD: entities=",
    ENTITY_COUNT,
    " original_true=9000 original_false=1000 setup_wall=",
    setup_profiler
  })
end

script.on_init(function()
  storage.offline_performance_fixture = {
    phase = "create",
    deadline = game.tick + 18000
  }
end)

script.on_load(function()
  loaded_from_save = true
end)

script.on_event(defines.events.on_tick, function()
  local fixture = storage.offline_performance_fixture
  if not fixture then fail("fixture storage is missing") end
  if game.tick > fixture.deadline then fail("fixture timed out in phase " .. fixture.phase) end

  if fixture.phase == "create" then
    create_workload(fixture)
    verify_protected(fixture, "initial protection")

    transition(fixture, false, "unprotect-before-save")
    verify_restored(fixture, "unprotect-before-save")
    transition(fixture, true, "protect-before-save")
    verify_protected(fixture, "protect-before-save")

    fixture.phase = "await-reload"
    checkpoint_created_this_process = true
    game.server_save("offline-security-performance-checkpoint")
    log("SCEATORIO_OFFLINE_PERFORMANCE_CHECKPOINT: server save requested")
    return
  end

  if fixture.phase == "await-reload" and loaded_from_save
    and not checkpoint_created_this_process then
    -- Let Sceatorio's first-tick presence reconciliation finish regardless of
    -- cross-mod handler order, then inspect on the following tick.
    fixture.phase = "verify-reload"
    return
  end

  if fixture.phase == "verify-reload" then
    verify_protected(fixture, "reloaded protection")
    transition(fixture, false, "unprotect-after-reload")
    verify_restored(fixture, "unprotect-after-reload")
    transition(fixture, true, "protect-after-reload")
    verify_protected(fixture, "protect-after-reload")
    log(
      "SCEATORIO_OFFLINE_PERFORMANCE_PASS: entities=10000 original_true=9000 "
        .. "original_false=1000 immediate_roundtrips=2 save_reload=verified"
    )
    fixture.phase = "passed"
  end
end)
