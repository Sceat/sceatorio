local State = require("src.core.state")
local Teams = require("src.game.teams")

local RobotPolicy = {}

-- Network totals and recipe changes have no dedicated Factorio 2.1 events.
-- Both registries therefore use small, constant round-robin budgets each tick;
-- no update scales with the number of ports, networks, robots, or machines.
local POLICY_LAYOUT_VERSION = 3
local PORT_SCAN_BUDGET = 2
local MACHINE_SCAN_BUDGET = 8
local MACHINE_REEVALUATION_BUDGET = 32
local WARNING_INTERVAL = 60 * 60
local VALID_MODES = {["disabled"] = true, ["warn"] = true, ["enforce"] = true}
local CRAFTING_MACHINE_TYPES = {
  ["assembling-machine"] = true,
  furnace = true,
  ["rocket-silo"] = true
}

local reevaluate_force
local update_force_gui
local robot_recipe_categories
local candidate_machine_prototypes

local function setting(name, fallback)
  local configured = settings.global[name]
  return configured and configured.value or fallback
end

local function mode()
  local configured = setting("sceatorio-robot-policy-mode", "enforce")
  return VALID_MODES[configured] and configured or "enforce"
end

local function logistic_cap()
  return setting("sceatorio-logistic-robot-cap", 500)
end

local function construction_cap()
  return setting("sceatorio-construction-robot-cap", 5000)
end

local function new_policy()
  return {
    layout_version = POLICY_LAYOUT_VERSION,
    ports = {},
    port_order = {},
    port_slots = {},
    port_cursor = 1,
    network_port_counts = {},
    network_snapshots = {},
    snapshot_order = {},
    snapshot_slots = {},
    network_inspected_tick = {},
    machines = {},
    machine_order = {},
    machine_slots = {},
    machine_cursor = 1,
    machine_by_force = {},
    robot_machine_order_by_force = {},
    robot_machine_slots_by_force = {},
    force_machine_counts = {},
    force_paused_counts = {},
    force_totals = {},
    force_states = {},
    force_alerts = {},
    warning_ticks = {},
    reevaluation_force_order = {},
    reevaluation_force_slots = {},
    reevaluation_cursors = {},
    reevaluation_force_cursor = 1
  }
end

local function policy_root()
  local root = State.get()
  local policy = root.robot_policy
  if not policy or policy.layout_version ~= POLICY_LAYOUT_VERSION then
    -- Sceatorio's new registries intentionally start with fresh saves. This is
    -- a storage-layout reset, never an existing-world entity scan.
    policy = new_policy()
    root.robot_policy = policy
  end
  return policy
end

local function dense_add(order, slots, key)
  if slots[key] then return end
  local slot = #order + 1
  order[slot] = key
  slots[key] = slot
end

local function dense_remove(order, slots, key)
  local slot = slots[key]
  if not slot then return end
  local last_slot = #order
  local last_key = order[last_slot]
  if slot ~= last_slot then
    order[slot] = last_key
    slots[last_key] = slot
  end
  order[last_slot] = nil
  slots[key] = nil
end

local function network_key(force_index, surface_index, network_id)
  return table.concat({force_index, surface_index, network_id}, ":")
end

local function empty_totals()
  return {
    logistic = 0,
    available_logistic = 0,
    construction = 0,
    available_construction = 0,
    networks = 0
  }
end

local function add_snapshot_totals(snapshot, multiplier)
  local policy = policy_root()
  local totals = policy.force_totals[snapshot.force_index]
  if not totals then
    totals = empty_totals()
    policy.force_totals[snapshot.force_index] = totals
  end
  totals.logistic = math.max(0, totals.logistic + snapshot.logistic * multiplier)
  totals.available_logistic = math.max(
    0,
    totals.available_logistic + snapshot.available_logistic * multiplier
  )
  totals.construction = math.max(
    0,
    totals.construction + snapshot.construction * multiplier
  )
  totals.available_construction = math.max(
    0,
    totals.available_construction + snapshot.available_construction * multiplier
  )
  totals.networks = math.max(0, totals.networks + multiplier)
end

local function threshold_reached(total, cap)
  return cap > 0 and total >= cap
end

local function warn_at_threshold(force_index, kind, total, cap, available)
  if not threshold_reached(total, cap) then return end
  local policy = policy_root()
  local warning_key = force_index .. ":" .. kind
  local last_tick = policy.warning_ticks[warning_key] or -WARNING_INTERVAL
  if game.tick - last_tick < WARNING_INTERVAL then return end
  policy.warning_ticks[warning_key] = game.tick
  local force = game.forces[force_index]
  if not (force and force.valid) then return end
  local kind_caption = kind == "logistic"
    and {"sceatorio.robot-kind-logistic"}
    or {"sceatorio.robot-kind-construction"}
  force.print({
    "sceatorio.robot-cap-warning",
    kind_caption,
    total,
    cap,
    available,
    mode()
  })
end

local function refresh_force_state(force_index, issue_warning)
  local policy = policy_root()
  local totals = policy.force_totals[force_index] or empty_totals()
  local previous = policy.force_states[force_index] or {
    logistic = false,
    construction = false
  }
  local current = {
    logistic = threshold_reached(totals.logistic, logistic_cap()),
    construction = threshold_reached(totals.construction, construction_cap())
  }
  if mode() ~= "enforce" then
    current.logistic = false
    current.construction = false
  end
  policy.force_states[force_index] = current

  local alerts = 0
  if threshold_reached(totals.logistic, logistic_cap()) then alerts = alerts + 1 end
  if threshold_reached(totals.construction, construction_cap()) then
    alerts = alerts + 1
  end
  local alerts_changed = policy.force_alerts[force_index] ~= alerts
  policy.force_alerts[force_index] = alerts

  if issue_warning and mode() ~= "disabled" then
    warn_at_threshold(
      force_index,
      "logistic",
      totals.logistic,
      logistic_cap(),
      totals.available_logistic
    )
    warn_at_threshold(
      force_index,
      "construction",
      totals.construction,
      construction_cap(),
      totals.available_construction
    )
  end

  local state_changed = previous.logistic ~= current.logistic
    or previous.construction ~= current.construction
  if state_changed and reevaluate_force then reevaluate_force(force_index) end
  if (state_changed or alerts_changed) and update_force_gui then
    update_force_gui(game.forces[force_index])
  end
end

local function remove_snapshot(key, defer_refresh)
  local policy = policy_root()
  local snapshot = policy.network_snapshots[key]
  if not snapshot then return end
  add_snapshot_totals(snapshot, -1)
  policy.network_snapshots[key] = nil
  policy.network_inspected_tick[key] = nil
  dense_remove(policy.snapshot_order, policy.snapshot_slots, key)
  if not defer_refresh then refresh_force_state(snapshot.force_index, false) end
end

local function store_snapshot(key, snapshot)
  local policy = policy_root()
  local old = policy.network_snapshots[key]
  if old then add_snapshot_totals(old, -1) end
  policy.network_snapshots[key] = snapshot
  add_snapshot_totals(snapshot, 1)
  dense_add(policy.snapshot_order, policy.snapshot_slots, key)
  refresh_force_state(snapshot.force_index, true)
end

local function product_robot_kinds(products)
  local makes_logistic = false
  local makes_construction = false
  for _, product in pairs(products or {}) do
    if (not product.type or product.type == "item") and product.name then
      local item = prototypes.item[product.name]
      local placed = item and item.place_result or nil
      if (placed and placed.type == "logistic-robot")
        or product.name == "logistic-robot" then
        makes_logistic = true
      elseif (placed and placed.type == "construction-robot")
        or product.name == "construction-robot" then
        makes_construction = true
      end
    end
  end
  return makes_logistic, makes_construction
end

local function ensure_robot_recipe_categories()
  if robot_recipe_categories then return end
  robot_recipe_categories = {}
  candidate_machine_prototypes = {}
  for _, recipe in pairs(prototypes.recipe) do
    local makes_logistic, makes_construction = product_robot_kinds(recipe.products)
    if makes_logistic or makes_construction then
      for _, category in pairs(recipe.categories or {}) do
        robot_recipe_categories[category] = true
      end
    end
  end
end

local function prototype_can_produce_robot(entity)
  ensure_robot_recipe_categories()
  local prototype = entity.prototype
  local name = prototype.name
  local cached = candidate_machine_prototypes[name]
  if cached ~= nil then return cached end
  local eligible = false
  for category in pairs(prototype.crafting_categories or {}) do
    if robot_recipe_categories[category] then
      eligible = true
      break
    end
  end
  candidate_machine_prototypes[name] = eligible
  return eligible
end

local function recipe_robot_kinds(machine)
  local ok, recipe = pcall(function() return machine.get_recipe() end)
  if not ok or not recipe then return false, false end
  return product_robot_kinds(recipe.products)
end

local function recipe_machine_lists(force_index)
  local policy = policy_root()
  policy.robot_machine_order_by_force[force_index] =
    policy.robot_machine_order_by_force[force_index] or {}
  policy.robot_machine_slots_by_force[force_index] =
    policy.robot_machine_slots_by_force[force_index] or {}
  return policy.robot_machine_order_by_force[force_index],
    policy.robot_machine_slots_by_force[force_index]
end

local function reset_pending_cursor(force_index)
  local policy = policy_root()
  if policy.reevaluation_force_slots[force_index] then
    policy.reevaluation_cursors[force_index] = 1
  end
end

local function remove_recipe_machine(record)
  if not record then return end
  local order, slots = recipe_machine_lists(record.force_index)
  dense_remove(order, slots, record.unit_number)
  record.makes_logistic_robot = false
  record.makes_construction_robot = false
  reset_pending_cursor(record.force_index)
end

local function refresh_recipe_machine(record)
  local machine = record and record.entity or nil
  if not (machine and machine.valid) then return false, false end
  local makes_logistic, makes_construction = recipe_robot_kinds(machine)
  local active = makes_logistic or makes_construction
  local order, slots = recipe_machine_lists(record.force_index)
  local listed = slots[record.unit_number] ~= nil
  if active and not listed then
    dense_add(order, slots, record.unit_number)
    reset_pending_cursor(record.force_index)
  elseif not active and listed then
    dense_remove(order, slots, record.unit_number)
    reset_pending_cursor(record.force_index)
  end
  record.makes_logistic_robot = makes_logistic
  record.makes_construction_robot = makes_construction
  return makes_logistic, makes_construction
end

local function machine_should_pause(record)
  local machine = record.entity
  if not (machine and machine.valid) then return false end
  local makes_logistic, makes_construction = refresh_recipe_machine(record)
  if mode() ~= "enforce" then return false end
  local force_state = policy_root().force_states[record.force_index] or {}
  return (makes_logistic and force_state.logistic == true)
    or (makes_construction and force_state.construction == true)
end

local function set_paused_count(force_index, delta)
  local policy = policy_root()
  policy.force_paused_counts[force_index] = math.max(
    0,
    (policy.force_paused_counts[force_index] or 0) + delta
  )
end

local function apply_machine_policy(record)
  local machine = record.entity
  if not (machine and machine.valid) then return false end
  if machine_should_pause(record) then
    if not record.paused then
      record.prior_disabled_by_script = machine.disabled_by_script == true
      record.paused = true
      set_paused_count(record.force_index, 1)
    end
    if not machine.disabled_by_script then machine.disabled_by_script = true end
  elseif record.paused then
    machine.disabled_by_script = record.prior_disabled_by_script == true
    record.prior_disabled_by_script = nil
    record.paused = false
    set_paused_count(record.force_index, -1)
  end
  return true
end

local function restore_machine(record)
  local machine = record and record.entity or nil
  if not record or not record.paused then return end
  if machine and machine.valid then
    machine.disabled_by_script = record.prior_disabled_by_script == true
  end
  record.prior_disabled_by_script = nil
  record.paused = false
  set_paused_count(record.force_index, -1)
end

local function add_machine_to_force(record, force_index)
  local policy = policy_root()
  policy.machine_by_force[force_index] = policy.machine_by_force[force_index] or {}
  if not policy.machine_by_force[force_index][record.unit_number] then
    policy.machine_by_force[force_index][record.unit_number] = true
    policy.force_machine_counts[force_index] =
      (policy.force_machine_counts[force_index] or 0) + 1
  end
end

local function remove_machine_from_force(record)
  local policy = policy_root()
  remove_recipe_machine(record)
  local bucket = policy.machine_by_force[record.force_index]
  if bucket and bucket[record.unit_number] then
    bucket[record.unit_number] = nil
    policy.force_machine_counts[record.force_index] = math.max(
      0,
      (policy.force_machine_counts[record.force_index] or 0) - 1
    )
  end
end

local function register_machine(entity, cloned_prior)
  if not (entity and entity.valid and entity.unit_number
    and CRAFTING_MACHINE_TYPES[entity.type]) then
    return false
  end
  if not prototype_can_produce_robot(entity) then return false end
  if not Teams.get_by_force(entity.force) then return false end
  local policy = policy_root()
  local unit_number = entity.unit_number
  local record = policy.machines[unit_number]
  if record then
    record.entity = entity
    return apply_machine_policy(record)
  end
  record = {
    unit_number = unit_number,
    entity = entity,
    force_index = entity.force.index,
    surface_index = entity.surface.index,
    paused = false
  }
  policy.machines[unit_number] = record
  dense_add(policy.machine_order, policy.machine_slots, unit_number)
  add_machine_to_force(record, record.force_index)
  if cloned_prior ~= nil then
    record.prior_disabled_by_script = cloned_prior == true
    record.paused = true
    set_paused_count(record.force_index, 1)
  end
  apply_machine_policy(record)
  return true
end

local function unregister_machine(entity_or_unit)
  local unit_number = entity_or_unit and entity_or_unit.unit_number or entity_or_unit
  if not unit_number then return end
  local policy = policy_root()
  local record = policy.machines[unit_number]
  if not record then return end
  restore_machine(record)
  remove_machine_from_force(record)
  policy.machines[unit_number] = nil
  dense_remove(policy.machine_order, policy.machine_slots, unit_number)
  if policy.machine_cursor > #policy.machine_order then policy.machine_cursor = 1 end
end

reevaluate_force = function(force_index)
  local policy = policy_root()
  dense_add(
    policy.reevaluation_force_order,
    policy.reevaluation_force_slots,
    force_index
  )
  policy.reevaluation_cursors[force_index] = 1
end

local function reindex_machine(record, entity)
  if record.force_index == entity.force.index
    and record.surface_index == entity.surface.index then
    return true
  end
  restore_machine(record)
  remove_machine_from_force(record)
  if not Teams.get_by_force(entity.force) then return false end
  record.force_index = entity.force.index
  record.surface_index = entity.surface.index
  add_machine_to_force(record, record.force_index)
  apply_machine_policy(record)
  return true
end

local function process_registered_machines()
  if mode() ~= "enforce" then return end
  local policy = policy_root()
  local length = #policy.machine_order
  if length == 0 then return end
  local processed = 0
  while processed < MACHINE_SCAN_BUDGET and processed < length do
    if policy.machine_cursor > #policy.machine_order then policy.machine_cursor = 1 end
    local unit_number = policy.machine_order[policy.machine_cursor]
    policy.machine_cursor = policy.machine_cursor + 1
    processed = processed + 1
    local record = policy.machines[unit_number]
    local machine = record and record.entity or nil
    if not (machine and machine.valid and CRAFTING_MACHINE_TYPES[machine.type]) then
      unregister_machine(unit_number)
    elseif not reindex_machine(record, machine) then
      unregister_machine(unit_number)
    else
      apply_machine_policy(record)
    end
  end
end

local function process_force_reevaluations()
  local policy = policy_root()
  local processed = 0
  while processed < MACHINE_REEVALUATION_BUDGET
    and #policy.reevaluation_force_order > 0 do
    if policy.reevaluation_force_cursor > #policy.reevaluation_force_order then
      policy.reevaluation_force_cursor = 1
    end
    local force_slot = policy.reevaluation_force_cursor
    local force_index = policy.reevaluation_force_order[force_slot]
    local order, slots = recipe_machine_lists(force_index)
    local cursor = policy.reevaluation_cursors[force_index] or 1
    -- Empty/stale force entries consume the same fixed budget as a machine,
    -- so a settings change across many teams cannot create an unbounded tick.
    processed = processed + 1
    if cursor > #order then
      dense_remove(
        policy.reevaluation_force_order,
        policy.reevaluation_force_slots,
        force_index
      )
      policy.reevaluation_cursors[force_index] = nil
      if force_slot > #policy.reevaluation_force_order then
        policy.reevaluation_force_cursor = 1
      end
    else
      local unit_number = order[cursor]
      local previous_slot = slots[unit_number]
      local record = policy.machines[unit_number]
      local machine = record and record.entity or nil
      if not (machine and machine.valid and CRAFTING_MACHINE_TYPES[machine.type]) then
        unregister_machine(unit_number)
      elseif not reindex_machine(record, machine) then
        unregister_machine(unit_number)
      else
        apply_machine_policy(record)
      end
      -- Recipe/force changes reset the cursor to one so a dense-array swap can
      -- never skip an unprocessed producer. Stable entries advance normally.
      if slots[unit_number] == previous_slot then
        policy.reevaluation_cursors[force_index] = cursor + 1
      end
      policy.reevaluation_force_cursor = force_slot + 1
    end
  end
end

local function release_port_network(record, defer_refresh)
  local key = record.network_key
  if not key then return end
  local policy = policy_root()
  local remaining = math.max(0, (policy.network_port_counts[key] or 0) - 1)
  if remaining == 0 then
    policy.network_port_counts[key] = nil
    remove_snapshot(key, defer_refresh)
  else
    policy.network_port_counts[key] = remaining
  end
  record.network_key = nil
end

local function bind_port_network(record, key)
  if record.network_key == key then return end
  release_port_network(record, false)
  record.network_key = key
  if key then
    local policy = policy_root()
    policy.network_port_counts[key] = (policy.network_port_counts[key] or 0) + 1
  end
end

local function register_port(entity)
  if not (entity and entity.valid and entity.type == "roboport"
    and entity.unit_number) then
    return false
  end
  if not Teams.get_by_force(entity.force) then return false end
  local policy = policy_root()
  local unit_number = entity.unit_number
  local record = policy.ports[unit_number]
  if record then
    record.entity = entity
    return true
  end
  record = {
    unit_number = unit_number,
    entity = entity,
    force_index = entity.force.index,
    surface_index = entity.surface.index
  }
  policy.ports[unit_number] = record
  dense_add(policy.port_order, policy.port_slots, unit_number)
  return true
end

local function unregister_port(entity_or_unit)
  local unit_number = entity_or_unit and entity_or_unit.unit_number or entity_or_unit
  if not unit_number then return end
  local policy = policy_root()
  local record = policy.ports[unit_number]
  if not record then return end
  release_port_network(record, false)
  policy.ports[unit_number] = nil
  dense_remove(policy.port_order, policy.port_slots, unit_number)
  if policy.port_cursor > #policy.port_order then policy.port_cursor = 1 end
end

local function get_network(entity)
  local ok, network = pcall(function() return entity.logistic_network end)
  return ok and network or nil
end

local function inspect_registered_port(record)
  local entity = record.entity
  if not (entity and entity.valid and entity.type == "roboport") then return false end
  if not Teams.get_by_force(entity.force) then return false end
  if record.force_index ~= entity.force.index
    or record.surface_index ~= entity.surface.index then
    release_port_network(record, false)
    record.force_index = entity.force.index
    record.surface_index = entity.surface.index
  end
  local network = get_network(entity)
  if not (network and network.valid) then
    bind_port_network(record, nil)
    return true
  end
  local key = network_key(entity.force.index, entity.surface.index, network.network_id)
  bind_port_network(record, key)
  local policy = policy_root()
  if policy.network_inspected_tick[key] == game.tick then return true end
  policy.network_inspected_tick[key] = game.tick
  store_snapshot(key, {
    force_index = entity.force.index,
    surface_index = entity.surface.index,
    network_id = network.network_id,
    logistic = network.all_logistic_robots,
    available_logistic = network.available_logistic_robots,
    construction = network.all_construction_robots,
    available_construction = network.available_construction_robots,
    last_tick = game.tick
  })
  return true
end

local function scan_registered_ports()
  local policy = policy_root()
  local length = #policy.port_order
  if length == 0 then return end
  local processed = 0
  while processed < PORT_SCAN_BUDGET and processed < length do
    if policy.port_cursor > #policy.port_order then policy.port_cursor = 1 end
    local unit_number = policy.port_order[policy.port_cursor]
    policy.port_cursor = policy.port_cursor + 1
    processed = processed + 1
    local record = policy.ports[unit_number]
    if not record or not inspect_registered_port(record) then unregister_port(unit_number) end
  end
end

local function force_summary(force_index)
  local policy = policy_root()
  local totals = policy.force_totals[force_index] or empty_totals()
  return {
    logistic = totals.logistic,
    available_logistic = totals.available_logistic,
    construction = totals.construction,
    available_construction = totals.available_construction,
    networks = totals.networks,
    alerts = policy.force_alerts[force_index] or 0,
    machines = policy.force_machine_counts[force_index] or 0,
    paused = policy.force_paused_counts[force_index] or 0
  }
end

local function displayed_cap(cap)
  return cap == 0 and "unlimited" or cap
end

local function summary_caption(summary)
  return {
    "sceatorio.robot-policy-summary",
    summary.logistic,
    displayed_cap(logistic_cap()),
    summary.construction,
    displayed_cap(construction_cap()),
    summary.networks,
    summary.paused,
    MACHINE_SCAN_BUDGET
  }
end

function RobotPolicy.update_gui(player)
  if not (player and player.valid) then return end
  local button = player.gui.top.sceatorio_robot_policy_status
  local record = Teams.get_for_player(player)
  if mode() == "disabled" or not record then
    if button then button.visible = false end
    local frame = player.gui.screen.sceatorio_robot_policy_frame
    if frame then frame.visible = false end
    return
  end
  local summary = force_summary(player.force.index)
  if not button then
    button = player.gui.top.add({
      type = "button",
      name = "sceatorio_robot_policy_status",
      caption = {"sceatorio.robot-policy-button", summary.alerts},
      tags = {sceatorio_action = "robot_policy_status"}
    })
  end
  button.visible = true
  button.caption = {"sceatorio.robot-policy-button", summary.alerts}
  button.tooltip = summary_caption(summary)
end

update_force_gui = function(force)
  if not (force and force.valid) then return end
  for _, player in pairs(force.connected_players) do RobotPolicy.update_gui(player) end
end

local function rebuild_indexes_and_totals()
  local policy = policy_root()
  policy.port_order = {}
  policy.port_slots = {}
  policy.port_cursor = 1
  policy.network_port_counts = {}
  for unit_number, record in pairs(policy.ports) do
    local entity = record.entity
    if entity and entity.valid and entity.type == "roboport"
      and Teams.get_by_force(entity.force) then
      record.unit_number = unit_number
      record.force_index = entity.force.index
      record.surface_index = entity.surface.index
      dense_add(policy.port_order, policy.port_slots, unit_number)
      if record.network_key then
        policy.network_port_counts[record.network_key] =
          (policy.network_port_counts[record.network_key] or 0) + 1
      end
    else
      policy.ports[unit_number] = nil
    end
  end

  policy.machine_order = {}
  policy.machine_slots = {}
  policy.machine_cursor = 1
  policy.machine_by_force = {}
  policy.robot_machine_order_by_force = {}
  policy.robot_machine_slots_by_force = {}
  policy.force_machine_counts = {}
  policy.force_paused_counts = {}
  policy.reevaluation_force_order = {}
  policy.reevaluation_force_slots = {}
  policy.reevaluation_cursors = {}
  policy.reevaluation_force_cursor = 1
  for unit_number, record in pairs(policy.machines) do
    local machine = record.entity
    if machine and machine.valid and CRAFTING_MACHINE_TYPES[machine.type]
      and prototype_can_produce_robot(machine)
      and Teams.get_by_force(machine.force) then
      record.unit_number = unit_number
      record.force_index = machine.force.index
      record.surface_index = machine.surface.index
      dense_add(policy.machine_order, policy.machine_slots, unit_number)
      add_machine_to_force(record, record.force_index)
      refresh_recipe_machine(record)
      if record.paused then set_paused_count(record.force_index, 1) end
    else
      restore_machine(record)
      policy.machines[unit_number] = nil
    end
  end

  policy.force_totals = {}
  policy.snapshot_order = {}
  policy.snapshot_slots = {}
  policy.network_inspected_tick = {}
  for key, snapshot in pairs(policy.network_snapshots) do
    if (policy.network_port_counts[key] or 0) > 0 then
      dense_add(policy.snapshot_order, policy.snapshot_slots, key)
      add_snapshot_totals(snapshot, 1)
    else
      policy.network_snapshots[key] = nil
    end
  end
  policy.force_states = {}
  policy.force_alerts = {}
  local force_indexes = {}
  for force_index in pairs(policy.force_totals) do force_indexes[force_index] = true end
  for force_index in pairs(policy.machine_by_force) do force_indexes[force_index] = true end
  for force_index in pairs(force_indexes) do
    refresh_force_state(force_index, false)
    -- Also repairs a save made between a recipe/count change and its bounded
    -- poll, even when the derived threshold boolean itself did not change.
    reevaluate_force(force_index)
  end
end

function RobotPolicy.initialize()
  robot_recipe_categories = nil
  candidate_machine_prototypes = nil
  ensure_robot_recipe_categories()
  policy_root()
  rebuild_indexes_and_totals()
  for _, player in pairs(game.connected_players) do RobotPolicy.update_gui(player) end
end

function RobotPolicy.tick(event)
  if mode() == "disabled" then return end
  if event.tick % (10 * 60) == 0 then
    for _, player in pairs(game.connected_players) do RobotPolicy.update_gui(player) end
  end
end

function RobotPolicy.on_tick()
  if mode() ~= "disabled" then scan_registered_ports() end
  process_force_reevaluations()
  process_registered_machines()
end

local function built_entity(event)
  return event.created_entity or event.entity or event.destination
end

function RobotPolicy.on_entity_built(event)
  local entity = built_entity(event)
  if register_port(entity) and mode() ~= "disabled" then
    inspect_registered_port(policy_root().ports[entity.unit_number])
  end
  register_machine(entity)
end

function RobotPolicy.on_entity_cloned(event)
  local source_record = event.source and event.source.unit_number
    and policy_root().machines[event.source.unit_number] or nil
  local cloned_prior = nil
  if source_record and source_record.paused then
    cloned_prior = source_record.prior_disabled_by_script == true
  end
  if register_port(event.destination) and mode() ~= "disabled" then
    inspect_registered_port(policy_root().ports[event.destination.unit_number])
  end
  register_machine(event.destination, cloned_prior)
end

function RobotPolicy.on_entity_removed(event)
  local entity = event.entity or event.destination
  unregister_port(entity)
  unregister_machine(entity)
end

function RobotPolicy.on_entity_settings_pasted(event)
  local destination = event.destination or event.entity
  if not destination then return end
  register_machine(destination)
  local record = destination.unit_number and policy_root().machines[destination.unit_number]
  if record then apply_machine_policy(record) end
end

function RobotPolicy.on_player_joined(event)
  RobotPolicy.update_gui(game.players[event.player_index])
end

function RobotPolicy.on_setting_changed(event)
  if event.setting ~= "sceatorio-robot-policy-mode"
    and event.setting ~= "sceatorio-logistic-robot-cap"
    and event.setting ~= "sceatorio-construction-robot-cap" then
    return
  end
  local policy = policy_root()
  policy.warning_ticks = {}
  local force_indexes = {}
  for force_index in pairs(policy.force_totals) do force_indexes[force_index] = true end
  for force_index in pairs(policy.machine_by_force) do force_indexes[force_index] = true end
  for force_index in pairs(force_indexes) do
    refresh_force_state(force_index, true)
    reevaluate_force(force_index)
  end
  for _, player in pairs(game.connected_players) do RobotPolicy.update_gui(player) end
end

function RobotPolicy.on_surface_deleted(event)
  local policy = policy_root()
  local ports = {}
  for unit_number, record in pairs(policy.ports) do
    if record.surface_index == event.surface_index then ports[#ports + 1] = unit_number end
  end
  for _, unit_number in ipairs(ports) do unregister_port(unit_number) end
  local machines = {}
  for unit_number, record in pairs(policy.machines) do
    if record.surface_index == event.surface_index then machines[#machines + 1] = unit_number end
  end
  for _, unit_number in ipairs(machines) do unregister_machine(unit_number) end
end

function RobotPolicy.on_forces_merged(event)
  local policy = policy_root()
  local source_index = event.source_index
  local destination = event.destination
  local destination_is_team = Teams.get_by_force(destination) ~= nil

  local source_snapshots = {}
  for key, snapshot in pairs(policy.network_snapshots) do
    if snapshot.force_index == source_index then source_snapshots[#source_snapshots + 1] = key end
  end
  for _, key in ipairs(source_snapshots) do remove_snapshot(key, true) end

  local source_ports = {}
  for unit_number, record in pairs(policy.ports) do
    if record.force_index == source_index then source_ports[#source_ports + 1] = unit_number end
  end
  for _, unit_number in ipairs(source_ports) do
    local record = policy.ports[unit_number]
    local entity = record and record.entity or nil
    release_port_network(record, true)
    if destination_is_team and entity and entity.valid then
      record.force_index = destination.index
      record.surface_index = entity.surface.index
      if mode() ~= "disabled" then inspect_registered_port(record) end
    else
      unregister_port(unit_number)
    end
  end

  local source_machines = {}
  for unit_number, record in pairs(policy.machines) do
    if record.force_index == source_index then source_machines[#source_machines + 1] = unit_number end
  end
  for _, unit_number in ipairs(source_machines) do
    local record = policy.machines[unit_number]
    local machine = record and record.entity or nil
    restore_machine(record)
    remove_machine_from_force(record)
    if destination_is_team and machine and machine.valid then
      record.force_index = destination.index
      record.surface_index = machine.surface.index
      add_machine_to_force(record, destination.index)
      apply_machine_policy(record)
    else
      unregister_machine(unit_number)
    end
  end
  policy.force_totals[source_index] = nil
  policy.force_states[source_index] = nil
  policy.force_alerts[source_index] = nil
  policy.machine_by_force[source_index] = nil
  policy.force_machine_counts[source_index] = nil
  policy.force_paused_counts[source_index] = nil
  if destination_is_team then refresh_force_state(destination.index, false) end
end

local function show_status_frame(player)
  local summary = force_summary(player.force.index)
  local frame = player.gui.screen.sceatorio_robot_policy_frame
  if not frame then
    frame = player.gui.screen.add({
      type = "frame",
      direction = "vertical",
      name = "sceatorio_robot_policy_frame",
      caption = {"sceatorio.robot-policy-title"}
    })
    frame.auto_center = true
    frame.add({
      type = "label",
      name = "sceatorio_robot_policy_summary",
      caption = summary_caption(summary)
    })
    frame.add({
      type = "button",
      name = "sceatorio_robot_policy_close",
      caption = {"sceatorio.close"},
      tags = {sceatorio_action = "robot_policy_close"}
    })
  else
    frame.sceatorio_robot_policy_summary.caption = summary_caption(summary)
  end
  frame.visible = true
  player.opened = frame
end

function RobotPolicy.show_status(player)
  if not (player and player.valid) then return false end
  show_status_frame(player)
  return true
end

function RobotPolicy.on_gui_click(event)
  local element = event.element
  if not (element and element.valid) then return false end
  local action = (element.tags or {}).sceatorio_action
  local player = game.players[event.player_index]
  if action == "robot_policy_status" then
    show_status_frame(player)
    return true
  elseif action == "robot_policy_close" then
    local frame = player.gui.screen.sceatorio_robot_policy_frame
    if frame then frame.visible = false end
    return true
  end
  return false
end

local function command_output(command, message)
  local player = command.player_index and game.players[command.player_index] or nil
  if player then player.print(message) else rcon.print(message) end
end

local function status_command(command)
  local player = command.player_index and game.players[command.player_index] or nil
  local requested = command.parameter and tonumber(command.parameter) or nil
  local force = requested and game.forces[requested] or (player and player.force or nil)
  if player and requested and not player.admin then
    player.print({"sceatorio.admin-only"})
    return
  end
  if not (force and force.valid) then
    command_output(command, "Sceatorio robot policy: provide a valid force index.")
    return
  end
  local summary = force_summary(force.index)
  command_output(command, string.format(
    "Sceatorio robots [%s, mode=%s]: logistic %d/%s (%d available), construction %d/%s (%d available), fixed networks %d, registered machines %d, policy-paused %d, recipe detection %d machines/tick.",
    force.name,
    mode(),
    summary.logistic,
    logistic_cap() == 0 and "unlimited" or tostring(logistic_cap()),
    summary.available_logistic,
    summary.construction,
    construction_cap() == 0 and "unlimited" or tostring(construction_cap()),
    summary.available_construction,
    summary.networks,
    summary.machines,
    summary.paused,
    MACHINE_SCAN_BUDGET
  ))
end

commands.add_command(
  "sceatorio-robot-status",
  {"sceatorio.robot-status-help"},
  status_command
)

return RobotPolicy
