local NORMAL_POSITION = {x = 96, y = 96}
local ORIGINAL_FALSE_POSITION = {x = 100, y = 96}
local loaded_from_save = false
local checkpoint_created_this_process = false

local function fail(reason)
  error("SCEATORIO_OFFLINE_FAIL: " .. reason)
end

local function fixture_entity(entity, label)
  if not (entity and entity.valid) then fail(label .. " entity is invalid") end
  return entity
end

local function dev_transition(force_name, protected)
  local result = remote.call(
    "sceatorio_dev_tools",
    "set_offline_protection",
    force_name,
    protected
  )
  if not result.ok then fail(result.error or "development transition failed") end
  return result.status
end

local function damage_changes_health(entity)
  local before = entity.health
  entity.damage(25, game.forces.enemy, "physical")
  return entity.health < before
end

script.on_init(function()
  storage.offline_fixture = {phase = "create"}
end)

script.on_load(function()
  loaded_from_save = true
end)

script.on_event(defines.events.on_tick, function()
  local fixture = storage.offline_fixture
  if not fixture then fail("fixture storage is missing") end

  if fixture.phase == "create" then
    local force = game.create_force("offline-fixture-team")
    local registration = remote.call(
      "sceatorio_teams",
      "register_force",
      force.name,
      nil,
      "Offline fixture team"
    )
    if not registration.ok then fail(registration.error or "team registration failed") end

    local surface = game.surfaces.nauvis
    surface.request_to_generate_chunks(NORMAL_POSITION, 1)
    surface.force_generate_chunk_requests()

    local normal = surface.create_entity({
      name = "stone-wall",
      position = NORMAL_POSITION,
      force = force
    })
    local original_false = surface.create_entity({
      name = "stone-wall",
      position = ORIGINAL_FALSE_POSITION,
      force = force
    })
    fixture_entity(normal, "normal")
    fixture_entity(original_false, "original-false")
    original_false.destructible = false
    script.raise_script_built({entity = normal})
    script.raise_script_built({entity = original_false})

    fixture.force_name = force.name
    fixture.normal = normal
    fixture.original_false = original_false
    fixture.normal_full_health = normal.health
    fixture.phase = "online-damage"
    return
  end

  local normal = fixture_entity(fixture.normal, "normal")
  local original_false = fixture_entity(fixture.original_false, "original-false")

  if fixture.phase == "online-damage" then
    if normal.destructible then fail("offline build was not protected immediately") end
    local status = dev_transition(fixture.force_name, false)
    if not normal.destructible then fail("online transition did not restore true") end
    if original_false.destructible then fail("preexisting false state restored as true") end
    if not damage_changes_health(normal) then fail("online entity did not take damage") end
    normal.health = fixture.normal_full_health
    if status.protected ~= 0 then fail("online registry still reports protected assets") end
    fixture.phase = "offline-damage"
    return
  end

  if fixture.phase == "offline-damage" then
    local status = dev_transition(fixture.force_name, true)
    if normal.destructible then fail("offline transition left entity destructible") end
    local before = normal.health
    normal.damage(25, game.forces.enemy, "physical")
    if normal.health ~= before then fail("offline entity took damage") end
    if status.protected ~= 2 then fail("offline registry did not protect both assets") end
    fixture.phase = "restore-roundtrip"
    return
  end

  if fixture.phase == "restore-roundtrip" then
    dev_transition(fixture.force_name, false)
    if not normal.destructible then fail("return transition did not restore true") end
    if original_false.destructible then fail("return leaked invulnerability state") end
    if not damage_changes_health(normal) then fail("returned entity did not take damage") end
    normal.health = fixture.normal_full_health

    -- Persist an online/unprotected registry into a real engine autosave. The
    -- harness loads that checkpoint in a second process, which has zero
    -- connected humans and no persisted leave event.
    fixture.phase = "await-reload"
    checkpoint_created_this_process = true
    game.server_save("offline-security-checkpoint")
    log("SCEATORIO_OFFLINE_CHECKPOINT: server save requested")
    return
  end

  if fixture.phase == "await-reload" and loaded_from_save
    and not checkpoint_created_this_process then
    -- Dependent mods do not get to observe a guaranteed cross-mod handler
    -- order inside one on_tick dispatch. Verify on the following tick, after
    -- Sceatorio's first-tick reconciliation has completed.
    fixture.phase = "verify-reload"
    return
  end

  if fixture.phase == "verify-reload" then
    if normal.destructible then fail("first tick after load did not reconcile offline state") end
    if original_false.destructible then fail("reload changed original false state") end
    local status = remote.call(
      "sceatorio_dev_tools",
      "offline_status",
      fixture.force_name
    )
    if not status.ok or not status.status.active or status.status.protected ~= 2 then
      fail("reloaded registry status is not protected")
    end
    local before = normal.health
    normal.damage(25, game.forces.enemy, "physical")
    if normal.health ~= before then fail("reloaded offline entity took damage") end

    dev_transition(fixture.force_name, false)
    if not normal.destructible or original_false.destructible then
      fail("post-reload exact restoration failed")
    end
    if not damage_changes_health(normal) then fail("post-reload online damage failed") end
    log("SCEATORIO_OFFLINE_PASS: online/offline/save-load restoration verified")
    fixture.phase = "passed"
  end
end)
