local FIRST_PORT_POSITION = {x = 96, y = 96}
local SECOND_PORT_POSITION = {x = 256, y = 96}
local SOURCE_POSITION = {x = 104, y = 96}
local PRE_DISABLED_POSITION = {x = 108, y = 96}
local CLONE_POSITION = {x = 112, y = 96}
local loaded_from_save = false
local checkpoint_created_this_process = false

local function fail(reason)
  error("SCEATORIO_ROBOT_POLICY_FAIL: " .. reason)
end

local function require_entity(entity, label)
  if not (entity and entity.valid) then fail(label .. " entity is invalid") end
  return entity
end

local function robot_inventory(port)
  local inventory = port.get_inventory(defines.inventory.roboport_robot)
  if not (inventory and inventory.valid) then fail("roboport robot inventory is invalid") end
  return inventory
end

local function input_state(machine)
  local inventory = machine.get_inventory(defines.inventory.crafter_input)
  if not (inventory and inventory.valid) then fail("crafter input inventory is invalid") end
  return {
    frames = inventory.get_item_count("flying-robot-frame"),
    circuits = inventory.get_item_count("advanced-circuit"),
    progress = machine.crafting_progress,
    quality = machine.quality and machine.quality.name or "normal"
  }
end

local function same_input_state(first, second)
  return first.frames == second.frames
    and first.circuits == second.circuits
    and first.progress == second.progress
    and first.quality == second.quality
end

local function create_entity(surface, parameters)
  parameters.raise_built = true
  return require_entity(surface.create_entity(parameters), parameters.name)
end

script.on_init(function()
  storage.robot_policy_fixture = {phase = "create", deadline = game.tick + 1200}
end)

script.on_load(function()
  loaded_from_save = true
end)

script.on_event(defines.events.on_tick, function()
  local fixture = storage.robot_policy_fixture
  if not fixture then fail("fixture storage is missing") end
  if game.tick > fixture.deadline then fail("fixture timed out in phase " .. fixture.phase) end

  if fixture.phase == "create" then
    local force = game.create_force("robot-policy-fixture-team")
    local registration = remote.call(
      "sceatorio_teams",
      "register_force",
      force.name,
      nil,
      "Robot policy fixture team"
    )
    if not registration.ok then fail(registration.error or "team registration failed") end

    local surface = game.surfaces.nauvis
    surface.request_to_generate_chunks(FIRST_PORT_POSITION, 6)
    surface.force_generate_chunk_requests()

    local first_port = create_entity(surface, {
      name = "roboport",
      position = FIRST_PORT_POSITION,
      force = force
    })
    local second_port = create_entity(surface, {
      name = "roboport",
      position = SECOND_PORT_POSITION,
      force = force
    })
    robot_inventory(first_port).insert({name = "logistic-robot", count = 1})
    robot_inventory(second_port).insert({name = "logistic-robot", count = 1})

    local source = create_entity(surface, {
      name = "assembling-machine-3",
      position = SOURCE_POSITION,
      force = force
    })
    local pre_disabled = create_entity(surface, {
      name = "assembling-machine-3",
      position = PRE_DISABLED_POSITION,
      force = force
    })
    if not source.set_recipe("logistic-robot") then fail("source recipe was rejected") end
    if not pre_disabled.set_recipe("logistic-robot") then
      fail("pre-disabled recipe was rejected")
    end
    pre_disabled.disabled_by_script = true
    local input = source.get_inventory(defines.inventory.crafter_input)
    input.insert({name = "flying-robot-frame", count = 1})
    input.insert({name = "advanced-circuit", count = 2})
    source.crafting_progress = 0.375

    fixture.force_name = force.name
    fixture.first_port = first_port
    fixture.second_port = second_port
    fixture.source = source
    fixture.pre_disabled = pre_disabled
    fixture.phase = "await-force-wide-pause"
    return
  end

  local first_port = require_entity(fixture.first_port, "first roboport")
  local second_port = require_entity(fixture.second_port, "second roboport")
  local source = require_entity(fixture.source, "source machine")
  local pre_disabled = require_entity(fixture.pre_disabled, "pre-disabled machine")

  if fixture.phase == "await-force-wide-pause" then
    local first_network = first_port.logistic_network
    local second_network = second_port.logistic_network
    if not (first_network and second_network) then return end
    if first_network.network_id == second_network.network_id then
      fail("fixture roboports unexpectedly share one network")
    end
    if not source.disabled_by_script then return end
    if not pre_disabled.disabled_by_script then fail("pre-disabled machine was enabled") end
    if robot_inventory(first_port).get_item_count("logistic-robot") ~= 1
      or robot_inventory(second_port).get_item_count("logistic-robot") ~= 1 then
      fail("enforcement moved a robot item")
    end

    fixture.source_state = input_state(source)
    local clone = source.clone({
      position = CLONE_POSITION,
      surface = source.surface,
      force = source.force
    })
    fixture.clone = require_entity(clone, "paused clone")
    fixture.clone_state = input_state(clone)
    if not clone.disabled_by_script then fail("paused clone was not kept paused") end

    local removed = robot_inventory(second_port).remove({
      name = "logistic-robot",
      count = 1
    })
    if removed ~= 1 then fail("fixture could not lower the robot total") end
    fixture.phase = "await-exact-restore"
    return
  end

  if fixture.phase == "await-exact-restore" then
    local clone = require_entity(fixture.clone, "paused clone")
    if source.disabled_by_script or clone.disabled_by_script then return end
    if not pre_disabled.disabled_by_script then
      fail("exact prior true state was not restored")
    end
    if not same_input_state(fixture.source_state, input_state(source)) then
      fail("source contents, progress, or quality changed during pause/resume")
    end
    if not same_input_state(fixture.clone_state, input_state(clone)) then
      fail("clone contents, progress, or quality changed during pause/resume")
    end
    if robot_inventory(first_port).get_item_count("logistic-robot") ~= 1 then
      fail("remaining robot item moved during restoration")
    end

    robot_inventory(second_port).insert({name = "logistic-robot", count = 1})
    fixture.phase = "await-second-pause"
    return
  end

  if fixture.phase == "await-second-pause" then
    local clone = require_entity(fixture.clone, "paused clone")
    if not (source.disabled_by_script and clone.disabled_by_script) then return end
    if not clone.set_recipe("iron-gear-wheel") then fail("recipe-change setup failed") end
    fixture.phase = "await-recipe-restore"
    return
  end

  if fixture.phase == "await-recipe-restore" then
    local clone = require_entity(fixture.clone, "recipe-changed clone")
    if clone.disabled_by_script then return end
    if not source.disabled_by_script then
      fail("unrelated robot-production machine resumed above cap")
    end
    if robot_inventory(first_port).get_item_count("logistic-robot") ~= 1
      or robot_inventory(second_port).get_item_count("logistic-robot") ~= 1 then
      fail("manual overflow was altered")
    end
    fixture.phase = "await-reload"
    checkpoint_created_this_process = true
    game.server_save("robot-policy-checkpoint")
    log("SCEATORIO_ROBOT_POLICY_CHECKPOINT: server save requested")
    return
  end

  if fixture.phase == "await-reload" and loaded_from_save
    and not checkpoint_created_this_process then
    if not source.disabled_by_script then fail("policy pause did not survive reload") end
    if not pre_disabled.disabled_by_script then fail("prior true state did not survive reload") end
    log(
      "SCEATORIO_ROBOT_POLICY_PASS: split-network pause, clone restore, "
        .. "state preservation, recipe polling, and no robot movement verified"
    )
    fixture.phase = "passed"
  end
end)
