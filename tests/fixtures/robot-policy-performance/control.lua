local LOGISTIC_CAP = 500
local CONSTRUCTION_CAP = 5000
local PORT_COUNT = 64
local PORT_GRID_WIDTH = 8
local PORT_SPACING = 64
local CANDIDATE_MACHINE_COUNT = 1024
local LOGISTIC_MACHINE_COUNT = 256
local CONSTRUCTION_MACHINE_COUNT = 256
local MEASURED_ROUNDTRIPS = 2
local SETTLE_TICKS = 600
local MAX_TRANSITION_TICKS = 64

local loaded_from_save = false
local checkpoint_created_this_process = false
local transition_profiler

local function fail(reason)
  error("SCEATORIO_ROBOT_PERFORMANCE_FAIL: " .. reason)
end

local function require_entity(entity, label)
  if not (entity and entity.valid) then fail(label .. " entity is invalid") end
  return entity
end

local function create_entity(surface, parameters)
  parameters.raise_built = true
  return require_entity(surface.create_entity(parameters), parameters.name)
end

local function robot_inventory(port)
  local inventory = port.get_inventory(defines.inventory.roboport_robot)
  if not (inventory and inventory.valid) then fail("roboport robot inventory is invalid") end
  return inventory
end

local function port_position(index)
  local zero = index - 1
  return {
    x = (zero % PORT_GRID_WIDTH) * PORT_SPACING,
    y = math.floor(zero / PORT_GRID_WIDTH) * PORT_SPACING
  }
end

local function machine_position(index)
  local zero = index - 1
  return {
    x = 600 + (zero % 32) * 4,
    y = math.floor(zero / 32) * 4
  }
end

local function append_paving(tiles, position, radius)
  for x = position.x - radius, position.x + radius do
    for y = position.y - radius, position.y + radius do
      tiles[#tiles + 1] = {name = "refined-concrete", position = {x = x, y = y}}
    end
  end
end

local function distribute_robot(ports, name, count)
  local quotient = math.floor(count / #ports)
  local remainder = count % #ports
  local inserted = 0
  for index, port in ipairs(ports) do
    local amount = quotient + (index <= remainder and 1 or 0)
    if amount > 0 then
      inserted = inserted + robot_inventory(port).insert({name = name, count = amount})
    end
  end
  if inserted ~= count then
    fail(string.format("inserted %d/%d %s", inserted, count, name))
  end
end

local function network_totals(ports)
  local logistic = 0
  local construction = 0
  local seen = {}
  for _, port in ipairs(ports) do
    local network = port.logistic_network
    if not (network and network.valid) then return nil, nil end
    if seen[network.network_id] then fail("fixture roboports unexpectedly share a network") end
    seen[network.network_id] = true
    logistic = logistic + network.all_logistic_robots
    construction = construction + network.all_construction_robots
  end
  return logistic, construction
end

local function disabled_counts(fixture)
  local logistic = 0
  local construction = 0
  local unrelated = 0
  for index, machine in ipairs(fixture.machines) do
    require_entity(machine, "candidate machine")
    if machine.disabled_by_script then
      if index <= LOGISTIC_MACHINE_COUNT then
        logistic = logistic + 1
      elseif index <= LOGISTIC_MACHINE_COUNT + CONSTRUCTION_MACHINE_COUNT then
        construction = construction + 1
      else
        unrelated = unrelated + 1
      end
    end
  end
  return logistic, construction, unrelated
end

local function start_transition_profiler()
  transition_profiler = helpers.create_profiler()
end

local function stop_transition_profiler(label, ticks, first_tick)
  if not transition_profiler then fail("transition profiler is missing") end
  transition_profiler.stop()
  log({
    "",
    "SCEATORIO_ROBOT_PERFORMANCE_MEASURE: ",
    label,
    " ticks=",
    ticks,
    " first=",
    first_tick or -1,
    " wall=",
    transition_profiler
  })
  transition_profiler = nil
end

local function add_threshold_robots(fixture)
  local inventory = robot_inventory(fixture.transition_port)
  if inventory.insert({name = "logistic-robot", count = 1}) ~= 1 then
    fail("could not add logistic threshold robot")
  end
  if inventory.insert({name = "construction-robot", count = 1}) ~= 1 then
    fail("could not add construction threshold robot")
  end
end

local function remove_threshold_robots(fixture)
  local inventory = robot_inventory(fixture.transition_port)
  if inventory.remove({name = "logistic-robot", count = 1}) ~= 1 then
    fail("could not remove logistic threshold robot")
  end
  if inventory.remove({name = "construction-robot", count = 1}) ~= 1 then
    fail("could not remove construction threshold robot")
  end
end

local function begin_pause(fixture, final_pause)
  add_threshold_robots(fixture)
  fixture.transition_start_tick = game.tick
  fixture.first_change_tick = nil
  fixture.final_pause = final_pause == true
  fixture.phase = "await-pause"
  start_transition_profiler()
end

local function begin_resume(fixture)
  remove_threshold_robots(fixture)
  fixture.transition_start_tick = game.tick
  fixture.first_change_tick = nil
  fixture.phase = "await-resume"
  start_transition_profiler()
end

local function create_workload(fixture)
  local force = game.create_force("robot-policy-performance-team")
  local registration = remote.call(
    "sceatorio_teams",
    "register_force",
    force.name,
    nil,
    "Robot policy performance team"
  )
  if not registration.ok then fail(registration.error or "team registration failed") end

  local surface = game.create_surface("sceatorio-robot-policy-performance", {
    seed = 424242,
    autoplace_controls = {},
    default_enable_all_autoplace_controls = false
  })
  surface.request_to_generate_chunks({x = 352, y = 224}, 17)
  surface.force_generate_chunk_requests()

  local tiles = {}
  for index = 1, PORT_COUNT do append_paving(tiles, port_position(index), 3) end
  for index = 1, CANDIDATE_MACHINE_COUNT do
    append_paving(tiles, machine_position(index), 2)
  end
  surface.set_tiles(tiles, true, true, true, false)

  fixture.ports = {}
  for index = 1, PORT_COUNT do
    fixture.ports[index] = create_entity(surface, {
      name = "roboport",
      position = port_position(index),
      force = force
    })
  end
  fixture.transition_port = fixture.ports[#fixture.ports]

  fixture.machines = {}
  for index = 1, CANDIDATE_MACHINE_COUNT do
    local machine = create_entity(surface, {
      name = "assembling-machine-3",
      position = machine_position(index),
      force = force
    })
    if index <= LOGISTIC_MACHINE_COUNT then
      if not machine.set_recipe("logistic-robot") then fail("logistic recipe rejected") end
    elseif index <= LOGISTIC_MACHINE_COUNT + CONSTRUCTION_MACHINE_COUNT then
      if not machine.set_recipe("construction-robot") then
        fail("construction recipe rejected")
      end
    elseif not machine.set_recipe("iron-gear-wheel") then
      fail("non-robot recipe rejected")
    end
    fixture.machines[index] = machine
  end

  distribute_robot(fixture.ports, "logistic-robot", LOGISTIC_CAP - 1)
  distribute_robot(fixture.ports, "construction-robot", CONSTRUCTION_CAP - 1)
  fixture.force_name = force.name
  fixture.settle_until = game.tick + SETTLE_TICKS
  fixture.phase = "await-below-cap"
  log(string.format(
    "SCEATORIO_ROBOT_PERFORMANCE_WORKLOAD: ports=%d networks=%d candidates=%d robot-producers=%d unrelated-candidates=%d logistic=%d construction=%d",
    PORT_COUNT,
    PORT_COUNT,
    CANDIDATE_MACHINE_COUNT,
    LOGISTIC_MACHINE_COUNT + CONSTRUCTION_MACHINE_COUNT,
    CANDIDATE_MACHINE_COUNT - LOGISTIC_MACHINE_COUNT - CONSTRUCTION_MACHINE_COUNT,
    LOGISTIC_CAP - 1,
    CONSTRUCTION_CAP - 1
  ))
end

script.on_init(function()
  storage.robot_policy_performance_fixture = {
    phase = "create",
    deadline = game.tick + 18000,
    roundtrip = 0,
    pause_latencies = {},
    resume_latencies = {}
  }
end)

script.on_load(function()
  loaded_from_save = true
end)

script.on_event(defines.events.on_tick, function()
  local fixture = storage.robot_policy_performance_fixture
  if not fixture then fail("fixture storage is missing") end
  if game.tick > fixture.deadline then fail("fixture timed out in phase " .. fixture.phase) end

  if fixture.phase == "create" then
    local setup_profiler = helpers.create_profiler()
    create_workload(fixture)
    setup_profiler.stop()
    log({"", "SCEATORIO_ROBOT_PERFORMANCE_MEASURE: setup wall=", setup_profiler})
    return
  end

  if fixture.phase == "await-below-cap" then
    if game.tick < fixture.settle_until or game.tick % 60 ~= 0 then return end
    local logistic, construction = network_totals(fixture.ports)
    if not logistic then return end
    if logistic ~= LOGISTIC_CAP - 1 or construction ~= CONSTRUCTION_CAP - 1 then
      fail(string.format("below-cap totals are %d/%d", logistic, construction))
    end
    local paused_logistic, paused_construction, unrelated = disabled_counts(fixture)
    if paused_logistic ~= 0 or paused_construction ~= 0 or unrelated ~= 0 then
      fail("a candidate machine was paused below cap")
    end
    begin_pause(fixture, false)
    return
  end

  if fixture.phase == "await-pause" then
    local elapsed = game.tick - fixture.transition_start_tick
    if elapsed > MAX_TRANSITION_TICKS then fail("pause exceeded bounded latency") end
    local logistic, construction, unrelated = disabled_counts(fixture)
    if unrelated ~= 0 then fail("non-robot candidates were paused") end
    if (logistic > 0 or construction > 0) and not fixture.first_change_tick then
      fixture.first_change_tick = game.tick
    end
    if logistic ~= LOGISTIC_MACHINE_COUNT
      or construction ~= CONSTRUCTION_MACHINE_COUNT then return end
    fixture.pause_latencies[#fixture.pause_latencies + 1] = elapsed
    stop_transition_profiler(
      fixture.final_pause and "final-pause" or "pause",
      elapsed,
      fixture.first_change_tick and fixture.first_change_tick - fixture.transition_start_tick
    )
    if fixture.final_pause then
      fixture.phase = "await-reload"
      fixture.checkpoint_tick = game.tick
      checkpoint_created_this_process = true
      game.server_save("robot-policy-performance-checkpoint")
      log("SCEATORIO_ROBOT_PERFORMANCE_CHECKPOINT: server save requested")
    else
      begin_resume(fixture)
    end
    return
  end

  if fixture.phase == "await-resume" then
    local elapsed = game.tick - fixture.transition_start_tick
    if elapsed > MAX_TRANSITION_TICKS then fail("resume exceeded bounded latency") end
    local logistic, construction, unrelated = disabled_counts(fixture)
    if unrelated ~= 0 then fail("non-robot candidates were paused during resume") end
    if (logistic < LOGISTIC_MACHINE_COUNT or construction < CONSTRUCTION_MACHINE_COUNT)
      and not fixture.first_change_tick then
      fixture.first_change_tick = game.tick
    end
    if logistic ~= 0 or construction ~= 0 then return end
    fixture.resume_latencies[#fixture.resume_latencies + 1] = elapsed
    stop_transition_profiler(
      "resume",
      elapsed,
      fixture.first_change_tick and fixture.first_change_tick - fixture.transition_start_tick
    )
    fixture.roundtrip = fixture.roundtrip + 1
    if fixture.roundtrip < MEASURED_ROUNDTRIPS then
      begin_pause(fixture, false)
    else
      begin_pause(fixture, true)
    end
    return
  end

  if fixture.phase == "await-reload" and loaded_from_save
    and not checkpoint_created_this_process then
    local logistic, construction = network_totals(fixture.ports)
    if not logistic then return end
    if logistic ~= LOGISTIC_CAP or construction ~= CONSTRUCTION_CAP then
      fail(string.format("reloaded cap totals are %d/%d", logistic, construction))
    end
    local paused_logistic, paused_construction, unrelated = disabled_counts(fixture)
    if paused_logistic ~= LOGISTIC_MACHINE_COUNT
      or paused_construction ~= CONSTRUCTION_MACHINE_COUNT
      or unrelated ~= 0 then
      return
    end
    log(string.format(
      "SCEATORIO_ROBOT_PERFORMANCE_PASS: pause_ticks=%s resume_ticks=%s ports=%d candidates=%d producers=%d caps=%d/%d",
      table.concat(fixture.pause_latencies, ","),
      table.concat(fixture.resume_latencies, ","),
      PORT_COUNT,
      CANDIDATE_MACHINE_COUNT,
      LOGISTIC_MACHINE_COUNT + CONSTRUCTION_MACHINE_COUNT,
      LOGISTIC_CAP,
      CONSTRUCTION_CAP
    ))
    fixture.phase = "passed"
  end
end)
