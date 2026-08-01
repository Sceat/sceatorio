local State = require("src.core.state")
local Teams = require("src.game.teams")

local RobotPolicy = {}

local PORT_SCAN_BUDGET = 16
local CELL_SCAN_BUDGET = 12
local ITEM_TRANSFER_BUDGET = 100
local SNAPSHOT_TTL = 30 * 60
local WARNING_INTERVAL = 60 * 60
local VAULT_SLOTS = 500
local VALID_MODES = {["disabled"] = true, ["warn"] = true, ["enforce"] = true}

local function setting(name, fallback)
  local value = settings.global[name]
  return value and value.value or fallback
end

local function mode()
  local value = setting("sceatorio-robot-policy-mode", "warn")
  return VALID_MODES[value] and value or "warn"
end

local function logistic_cap()
  return setting("sceatorio-logistic-robot-cap", 500)
end

local function construction_cap()
  return setting("sceatorio-construction-robot-cap", 5000)
end

local function policy_root()
  local policy = State.get().robot_policy
  policy.ports = policy.ports or {}
  policy.port_order = policy.port_order or {}
  policy.port_slots = policy.port_slots or {}
  policy.port_cursor = policy.port_cursor or 1
  policy.port_epoch = policy.port_epoch or 1
  policy.seen_networks = policy.seen_networks or {}
  policy.migration_queue = policy.migration_queue or {}
  policy.migration_cursor = policy.migration_cursor or 1
  policy.network_snapshots = policy.network_snapshots or {}
  policy.snapshot_order = policy.snapshot_order or {}
  policy.snapshot_slots = policy.snapshot_slots or {}
  policy.snapshot_cursor = policy.snapshot_cursor or 1
  policy.force_totals = policy.force_totals or {}
  policy.force_alerts = policy.force_alerts or {}
  policy.warning_ticks = policy.warning_ticks or {}
  policy.enforcement = policy.enforcement or {}
  policy.enforcement_order = policy.enforcement_order or {}
  policy.enforcement_slots = policy.enforcement_slots or {}
  policy.enforcement_cursor = policy.enforcement_cursor or 1
  policy.vaults = policy.vaults or {}
  return policy
end

local function network_key(force_index, surface_index, network_id)
  return table.concat({force_index, surface_index, network_id}, ":")
end

local function register_port(entity)
  if not (entity and entity.valid and entity.type == "roboport" and entity.unit_number) then
    return false
  end
  if not Teams.get_by_force(entity.force) then return false end
  local policy = policy_root()
  local unit_number = entity.unit_number
  if policy.ports[unit_number] then
    policy.ports[unit_number].entity = entity
    return true
  end
  policy.ports[unit_number] = {
    entity = entity,
    force_index = entity.force.index,
    surface_index = entity.surface.index
  }
  local slot = #policy.port_order + 1
  policy.port_order[slot] = unit_number
  policy.port_slots[unit_number] = slot
  return true
end

local function unregister_port(entity)
  if not (entity and entity.unit_number) then return end
  local policy = policy_root()
  local unit_number = entity.unit_number
  local slot = policy.port_slots[unit_number]
  if slot then policy.port_order[slot] = 0 end
  policy.port_slots[unit_number] = nil
  policy.ports[unit_number] = nil
end

local function vault_for(force_index, surface_index)
  local policy = policy_root()
  policy.vaults[force_index] = policy.vaults[force_index] or {}
  local vault = policy.vaults[force_index][surface_index]
  if not vault then
    vault = {
      inventory = game.create_inventory(VAULT_SLOTS),
      logistic = 0,
      construction = 0,
      created_tick = game.tick
    }
    policy.vaults[force_index][surface_index] = vault
  elseif not (vault.inventory and vault.inventory.valid) then
    vault.inventory = game.create_inventory(VAULT_SLOTS)
  end
  return vault
end

local function vault_total(force_index)
  local total = 0
  for _, vault in pairs(policy_root().vaults[force_index] or {}) do
    if vault.inventory and vault.inventory.valid then
      total = total + vault.inventory.get_item_count()
    end
  end
  return total
end

local function force_summary(force_index)
  local totals = policy_root().force_totals[force_index] or {}
  local summary = {
    logistic = totals.logistic or 0,
    available_logistic = totals.available_logistic or 0,
    construction = totals.construction or 0,
    available_construction = totals.available_construction or 0,
    networks = totals.networks or 0,
    alerts = policy_root().force_alerts[force_index] or 0,
    quarantined = vault_total(force_index)
  }
  return summary
end

local function summary_caption(summary)
  return {
    "sceatorio.robot-policy-summary",
    summary.logistic,
    logistic_cap() == 0 and "unlimited" or logistic_cap(),
    summary.construction,
    construction_cap() == 0 and "unlimited" or construction_cap(),
    summary.quarantined
  }
end

function RobotPolicy.update_gui(player)
  if not (player and player.valid) then return end
  local button = player.gui.top.sceatorio_robot_policy_status
  local record = Teams.get_for_player(player)
  if mode() == "disabled" or not record then
    if button then button.visible = false end
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

local function update_force_gui(force)
  if not (force and force.valid) then return end
  for _, player in pairs(force.connected_players) do RobotPolicy.update_gui(player) end
end

local function refresh_alerts(force_index)
  local policy = policy_root()
  local totals = policy.force_totals[force_index] or {}
  local alerts = 0
  if logistic_cap() > 0 and (totals.logistic or 0) > logistic_cap() then
    alerts = alerts + 1
  end
  if construction_cap() > 0
    and (totals.construction or 0) > construction_cap() then
    alerts = alerts + 1
  end
  policy.force_alerts[force_index] = alerts
end

local function add_snapshot_totals(snapshot, multiplier)
  local policy = policy_root()
  local force_index = snapshot.force_index
  local totals = policy.force_totals[force_index]
  if not totals then
    totals = {
      logistic = 0,
      available_logistic = 0,
      construction = 0,
      available_construction = 0,
      networks = 0
    }
    policy.force_totals[force_index] = totals
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
  refresh_alerts(force_index)
end

local function remove_snapshot(key)
  local policy = policy_root()
  local old = policy.network_snapshots[key]
  if not old then return end
  add_snapshot_totals(old, -1)
  policy.network_snapshots[key] = nil
  local slot = policy.snapshot_slots[key]
  if slot then policy.snapshot_order[slot] = false end
  policy.snapshot_slots[key] = nil
end

local function store_snapshot(key, snapshot)
  local policy = policy_root()
  local old = policy.network_snapshots[key]
  if old then add_snapshot_totals(old, -1) end
  policy.network_snapshots[key] = snapshot
  add_snapshot_totals(snapshot, 1)
  if not policy.snapshot_slots[key] then
    local slot = #policy.snapshot_order + 1
    policy.snapshot_order[slot] = key
    policy.snapshot_slots[key] = slot
  end
end

local function warn_over_cap(force, surface, key, kind, total, cap, available)
  local policy = policy_root()
  local warning_key = key .. ":" .. kind
  local last_tick = policy.warning_ticks[warning_key] or -WARNING_INTERVAL
  if game.tick - last_tick < WARNING_INTERVAL then return end
  policy.warning_ticks[warning_key] = game.tick
  local kind_caption = kind == "logistic"
    and {"sceatorio.robot-kind-logistic"}
    or {"sceatorio.robot-kind-construction"}
  force.print({
    "sceatorio.robot-cap-warning",
    kind_caption,
    surface.localised_name or surface.name,
    total,
    cap,
    available,
    mode()
  })
end

local function enqueue_enforcement(key, network, snapshot)
  local policy = policy_root()
  local task = policy.enforcement[key]
  if not task then
    task = {key = key}
    policy.enforcement[key] = task
    local slot = #policy.enforcement_order + 1
    policy.enforcement_order[slot] = key
    policy.enforcement_slots[key] = slot
  end
  task.network = network
  task.force_index = snapshot.force_index
  task.surface_index = snapshot.surface_index
  task.snapshot_key = key
  task.cell_cursor = 1
  task.vault_full = false
  local summary = force_summary(snapshot.force_index)
  task.logistic_remaining = math.min(
    math.max(0, summary.logistic - logistic_cap()),
    snapshot.available_logistic
  )
  task.construction_remaining = math.min(
    math.max(0, summary.construction - construction_cap()),
    snapshot.available_construction
  )
  if logistic_cap() == 0 then task.logistic_remaining = 0 end
  if construction_cap() == 0 then task.construction_remaining = 0 end
end

local function inspect_network(network, surface)
  if not (network and network.valid and surface and surface.valid) then return end
  local force = network.force
  if not (force and force.valid and Teams.get_by_force(force)) then return end

  local key = network_key(force.index, surface.index, network.network_id)
  local logistics = network.all_logistic_robots
  local construction = network.all_construction_robots
  local available_logistics = network.available_logistic_robots
  local available_construction = network.available_construction_robots
  local logistics_limit = logistic_cap()
  local construction_limit = construction_cap()
  local snapshot = {
    force_index = force.index,
    surface_index = surface.index,
    network_id = network.network_id,
    logistic = logistics,
    available_logistic = available_logistics,
    construction = construction,
    available_construction = available_construction,
    last_tick = game.tick
  }
  store_snapshot(key, snapshot)
  local summary = force_summary(force.index)
  snapshot.over_logistic = logistics_limit > 0 and summary.logistic > logistics_limit
  snapshot.over_construction = construction_limit > 0
    and summary.construction > construction_limit

  if snapshot.over_logistic then
    warn_over_cap(
      force,
      surface,
      key,
      "logistic",
      summary.logistic,
      logistics_limit,
      summary.available_logistic
    )
  end
  if snapshot.over_construction then
    warn_over_cap(
      force,
      surface,
      key,
      "construction",
      summary.construction,
      construction_limit,
      summary.available_construction
    )
  end
  if mode() == "enforce" and (snapshot.over_logistic or snapshot.over_construction) then
    enqueue_enforcement(key, network, snapshot)
  end
  update_force_gui(force)
end

local function seed_existing_networks()
  local policy = policy_root()
  if policy.migration_seeded then return end
  policy.migration_queue = {}
  policy.migration_cursor = 1
  Teams.for_each(function(record)
    local force = Teams.get_force(record)
    if not (force and force.valid) then return end
    for surface_name, networks in pairs(force.logistic_networks) do
      local surface = game.surfaces[surface_name]
      if surface and surface.valid then
        for _, network in ipairs(networks) do
          policy.migration_queue[#policy.migration_queue + 1] = {
            network = network,
            surface_index = surface.index,
            cell_cursor = 1,
            found_fixed = false
          }
        end
      end
    end
  end)
  policy.migration_seeded = true
  policy.migration_complete = #policy.migration_queue == 0
end

local function process_migration()
  local policy = policy_root()
  if policy.migration_complete then return end
  local entry = policy.migration_queue[policy.migration_cursor]
  if not entry then
    policy.migration_queue = {}
    policy.migration_cursor = 1
    policy.migration_complete = true
    return
  end
  local network = entry.network
  local surface = game.surfaces[entry.surface_index]
  if not (network and network.valid and surface and surface.valid) then
    policy.migration_cursor = policy.migration_cursor + 1
    return
  end

  local cells = network.cells
  local processed = 0
  while processed < CELL_SCAN_BUDGET and entry.cell_cursor <= #cells do
    local cell = cells[entry.cell_cursor]
    entry.cell_cursor = entry.cell_cursor + 1
    processed = processed + 1
    if cell and cell.valid and not cell.mobile then
      local owner = cell.owner
      if register_port(owner) then entry.found_fixed = true end
    end
  end
  if entry.cell_cursor > #cells then
    if entry.found_fixed then inspect_network(network, surface) end
    policy.migration_cursor = policy.migration_cursor + 1
  end
end

local function get_network(entity)
  local ok, network = pcall(function() return entity.logistic_network end)
  return ok and network or nil
end

local function scan_registered_ports()
  local policy = policy_root()
  local length = #policy.port_order
  if length == 0 then return end
  local processed = 0
  while processed < PORT_SCAN_BUDGET do
    if policy.port_cursor > length then
      policy.port_cursor = 1
      policy.port_epoch = policy.port_epoch + 1
    end
    local unit_number = policy.port_order[policy.port_cursor]
    policy.port_cursor = policy.port_cursor + 1
    processed = processed + 1
    if unit_number and unit_number ~= 0 then
      local registered = policy.ports[unit_number]
      local entity = registered and registered.entity or nil
      if not (entity and entity.valid and entity.type == "roboport") then
        if registered then unregister_port(entity or {unit_number = unit_number}) end
      else
        local network = get_network(entity)
        if network and network.valid then
          local key = network_key(entity.force.index, entity.surface.index, network.network_id)
          if policy.seen_networks[key] ~= policy.port_epoch then
            policy.seen_networks[key] = policy.port_epoch
            inspect_network(network, entity.surface)
          end
        end
      end
    end
    if processed >= length then break end
  end
end

local function robot_kind(stack)
  local item = prototypes.item[stack.name]
  local placed = item and item.place_result or nil
  if not placed then return nil end
  if placed.type == "logistic-robot" then return "logistic" end
  if placed.type == "construction-robot" then return "construction" end
  return nil
end

local function transfer_stack(stack, requested, vault)
  if requested <= 0 then return 0 end
  local quality = stack.quality
  local identification = {name = stack.name, count = requested}
  if quality then identification.quality = quality.name end
  local inserted = vault.inventory.insert(identification)
  if inserted > 0 then stack.count = stack.count - inserted end
  return inserted
end

local function record_quarantine(task, kind, inserted)
  if inserted <= 0 then return end
  local snapshot = policy_root().network_snapshots[task.snapshot_key]
  if not snapshot then return end
  add_snapshot_totals(snapshot, -1)
  snapshot[kind] = math.max(0, snapshot[kind] - inserted)
  local available_key = "available_" .. kind
  snapshot[available_key] = math.max(0, snapshot[available_key] - inserted)
  snapshot.last_tick = game.tick
  add_snapshot_totals(snapshot, 1)
end

local function quarantine_from_port(entity, task, context)
  local inventory = entity.get_inventory(defines.inventory.roboport_robot)
  if not (inventory and inventory.valid) then return end
  local vault = vault_for(task.force_index, task.surface_index)
  for index = 1, #inventory do
    if context.item_budget <= 0 then return end
    local stack = inventory[index]
    if stack.valid_for_read then
      local kind = robot_kind(stack)
      local remaining = kind and task[kind .. "_remaining"] or 0
      if remaining > 0 then
        local requested = math.min(stack.count, remaining, context.item_budget)
        local inserted = transfer_stack(stack, requested, vault)
        record_quarantine(task, kind, inserted)
        task[kind .. "_remaining"] = remaining - inserted
        context.item_budget = context.item_budget - inserted
        vault[kind] = (vault[kind] or 0) + inserted
        vault.last_tick = game.tick
        if inserted < requested then
          task.vault_full = true
          return
        end
      end
    end
  end
end

local function finish_enforcement(key)
  local policy = policy_root()
  policy.enforcement[key] = nil
  local slot = policy.enforcement_slots[key]
  if slot then policy.enforcement_order[slot] = false end
  policy.enforcement_slots[key] = nil
end

local function warn_active_remainder(task)
  if task.logistic_remaining <= 0 and task.construction_remaining <= 0 then return end
  local warning_key = task.key .. ":active-remainder"
  local policy = policy_root()
  local last_tick = policy.warning_ticks[warning_key] or -WARNING_INTERVAL
  if game.tick - last_tick < WARNING_INTERVAL then return end
  policy.warning_ticks[warning_key] = game.tick
  local force = game.forces[task.force_index]
  if force and force.valid then
    force.print({
      "sceatorio.robot-active-remainder",
      task.logistic_remaining,
      task.construction_remaining
    })
  end
end

local function process_enforcement()
  local policy = policy_root()
  local length = #policy.enforcement_order
  if length == 0 then return end
  if policy.enforcement_cursor > length then policy.enforcement_cursor = 1 end
  local checked = 0
  while checked < length do
    local slot = policy.enforcement_cursor
    local key = policy.enforcement_order[slot]
    policy.enforcement_cursor = slot + 1
    checked = checked + 1
    local task = key and policy.enforcement[key] or nil
    if task then
      local network = task.network
      if not (network and network.valid) then
        finish_enforcement(key)
        return
      end
      if task.logistic_remaining <= 0 and task.construction_remaining <= 0 then
        finish_enforcement(key)
        return
      end
      local cells = network.cells
      local context = {item_budget = ITEM_TRANSFER_BUDGET}
      local processed = 0
      while processed < CELL_SCAN_BUDGET and task.cell_cursor <= #cells do
        local cell = cells[task.cell_cursor]
        task.cell_cursor = task.cell_cursor + 1
        processed = processed + 1
        if cell and cell.valid and not cell.mobile then
          local owner = cell.owner
          if register_port(owner) then quarantine_from_port(owner, task, context) end
        end
        if context.item_budget <= 0 then break end
      end
      if task.cell_cursor > #cells or task.vault_full then
        warn_active_remainder(task)
        finish_enforcement(key)
      elseif task.logistic_remaining <= 0 and task.construction_remaining <= 0 then
        finish_enforcement(key)
      end
      return
    end
  end
end

local function prune_one_snapshot()
  local policy = policy_root()
  local length = #policy.snapshot_order
  if length == 0 then return end
  if policy.snapshot_cursor > length then policy.snapshot_cursor = 1 end
  local key = policy.snapshot_order[policy.snapshot_cursor]
  policy.snapshot_cursor = policy.snapshot_cursor + 1
  if key then
    local snapshot = policy.network_snapshots[key]
    if snapshot and game.tick - snapshot.last_tick > SNAPSHOT_TTL then
      remove_snapshot(key)
    end
  end
end

local function rebuild_force_totals()
  local policy = policy_root()
  policy.force_totals = {}
  policy.force_alerts = {}
  for _, snapshot in pairs(policy.network_snapshots) do
    add_snapshot_totals(snapshot, 1)
  end
end

function RobotPolicy.initialize()
  policy_root()
  rebuild_force_totals()
  seed_existing_networks()
  for _, player in pairs(game.connected_players) do RobotPolicy.update_gui(player) end
end

function RobotPolicy.tick(event)
  if mode() == "disabled" then return end
  process_migration()
  scan_registered_ports()
  if mode() == "enforce" then process_enforcement() end
  prune_one_snapshot()
  if event.tick % (10 * 60) == 0 then
    for _, player in pairs(game.connected_players) do RobotPolicy.update_gui(player) end
  end
end

function RobotPolicy.on_entity_built(event)
  register_port(event.created_entity or event.entity or event.destination)
end

function RobotPolicy.on_entity_cloned(event)
  register_port(event.destination)
end

function RobotPolicy.on_entity_removed(event)
  unregister_port(event.entity)
end

function RobotPolicy.on_player_joined(event)
  RobotPolicy.update_gui(game.players[event.player_index])
end

function RobotPolicy.on_setting_changed(event)
  if string.sub(event.setting, 1, #"sceatorio-robot") ~= "sceatorio-robot"
    and event.setting ~= "sceatorio-logistic-robot-cap"
    and event.setting ~= "sceatorio-construction-robot-cap" then
    return
  end
  local policy = policy_root()
  policy.warning_ticks = {}
  rebuild_force_totals()
  if mode() ~= "enforce" then
    policy.enforcement = {}
    policy.enforcement_order = {}
    policy.enforcement_slots = {}
    policy.enforcement_cursor = 1
  end
  for _, player in pairs(game.connected_players) do RobotPolicy.update_gui(player) end
end

function RobotPolicy.on_surface_deleted(event)
  local policy = policy_root()
  for unit_number, registered in pairs(policy.ports) do
    if registered.surface_index == event.surface_index then
      unregister_port(registered.entity or {unit_number = unit_number})
    end
  end
  for key, snapshot in pairs(policy.network_snapshots) do
    if snapshot.surface_index == event.surface_index then remove_snapshot(key) end
  end
  for _, by_surface in pairs(policy.vaults) do
    local vault = by_surface[event.surface_index]
    if vault then vault.surface_deleted = true end
  end
end

function RobotPolicy.on_forces_merged(event)
  local policy = policy_root()
  for key, snapshot in pairs(policy.network_snapshots) do
    if snapshot.force_index == event.source_index then remove_snapshot(key) end
  end
  local source_vaults = policy.vaults[event.source_index]
  if not source_vaults then return end
  for surface_index, source in pairs(source_vaults) do
    if source.inventory and source.inventory.valid and not source.inventory.is_empty() then
      local destination = vault_for(event.destination.index, surface_index)
      destination.inventory.transfer_from_inventory(source.inventory)
      if not source.inventory.is_empty() then
        source.merged_into_force_index = event.destination.index
      end
    end
  end
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
  if player then
    player.print(message)
  else
    rcon.print(message)
  end
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
    "Sceatorio robots [%s, mode=%s]: logistic %d/%s (%d idle), construction %d/%s (%d idle), networks %d, alerts %d, recoverable %d.",
    force.name,
    mode(),
    summary.logistic,
    logistic_cap() == 0 and "unlimited" or tostring(logistic_cap()),
    summary.available_logistic,
    summary.construction,
    construction_cap() == 0 and "unlimited" or tostring(construction_cap()),
    summary.available_construction,
    summary.networks,
    summary.alerts,
    summary.quarantined
  ))
end

local function recover_inventory(player, inventory)
  local recovered = 0
  for index = 1, #inventory do
    local stack = inventory[index]
    if stack.valid_for_read then
      local identification = {name = stack.name, count = stack.count}
      if stack.quality then identification.quality = stack.quality.name end
      local inserted = player.insert(identification)
      if inserted > 0 then stack.count = stack.count - inserted end
      recovered = recovered + inserted
    end
  end
  return recovered
end

local function recover_command(command)
  local player = command.player_index and game.players[command.player_index] or nil
  if not (player and player.valid and player.admin) then
    command_output(command, {"sceatorio.robot-recover-admin"})
    return
  end
  local words = {}
  for word in string.gmatch(command.parameter or "", "%S+") do words[#words + 1] = word end
  local force_index = tonumber(words[1]) or player.force.index
  local surface_index = tonumber(words[2])
  local recovered = 0
  for stored_force_index, by_surface in pairs(policy_root().vaults) do
    if stored_force_index == force_index then
      for stored_surface_index, vault in pairs(by_surface) do
        if (not surface_index or stored_surface_index == surface_index)
          and vault.inventory and vault.inventory.valid then
          recovered = recovered + recover_inventory(player, vault.inventory)
        end
      end
    end
  end
  player.print({"sceatorio.robot-recovered", recovered})
  RobotPolicy.update_gui(player)
end

commands.add_command(
  "sceatorio-robot-status",
  {"sceatorio.robot-status-help"},
  status_command
)
commands.add_command(
  "sceatorio-robot-recover",
  {"sceatorio.robot-recover-help"},
  recover_command
)

return RobotPolicy
