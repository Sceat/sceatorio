local State = require("src.core.state")
local Teams = require("src.game.teams")
local EvolutionMath = require("src.game.evolution_math")

local Evolution = {}

local TICKS_PER_MINUTE = 60 * 60
local DEFAULT_TIME_PER_MINUTE = 0.00005
local DEFAULT_WORM_PER_KILL = 0.001
local DEFAULT_SPAWNER_PER_KILL = 0.007
local DEFAULT_POLLUTION_PER_UNIT = 0.0000009
local MAX_POLLUTION_UNITS = 1e300

local function setting(name, fallback)
  local prototype = settings.global[name]
  if not prototype then return fallback end
  return prototype.value
end

local function enabled()
  return setting("sceatorio-evolution-enabled", true)
end

local function coefficient(name, fallback)
  local value = setting(name, fallback)
  if type(value) ~= "number" or value < 0 or value ~= value or value == math.huge then
    return fallback
  end
  return value
end

local function ledger_for(record, surface)
  local surface_record = Teams.ensure_surface(record, surface)
  if not surface_record then return nil end
  local ledger = surface_record.evolution
  ledger.baseline_raw = ledger.baseline_raw or 0
  ledger.raw_time = ledger.raw_time or 0
  ledger.raw_worm = ledger.raw_worm or 0
  ledger.raw_spawner = ledger.raw_spawner or 0
  ledger.raw_pollution = ledger.raw_pollution or 0
  ledger.connected_ticks = ledger.connected_ticks or 0
  ledger.worm_kills = ledger.worm_kills or 0
  ledger.spawner_kills = ledger.spawner_kills or 0
  ledger.pollution_units = ledger.pollution_units or 0
  return ledger
end

local function raw_total(ledger)
  return ledger.baseline_raw + ledger.raw_time + ledger.raw_worm
    + ledger.raw_spawner + ledger.raw_pollution
end

local function finite_nonnegative(value)
  return type(value) == "number" and value >= 0
    and value == value and value ~= math.huge
end

-- Factorio records pollution consumed by enemy nests in the surface-global
-- output side of its flow statistics. Vanilla pollution evolution follows
-- that nest consumption, not gross factory emissions: trees and scrubbers can
-- intercept pollution before it reaches a nest. Filtering the cumulative
-- output counters through runtime entity prototypes is bounded by the number
-- of statistic keys and avoids every chunk/entity scan. Callers cache this
-- result so a surface is sampled only once per sync.
local function sample_pollution(surface)
  local total = 0
  local statistics = surface.pollution_statistics
  if statistics and statistics.valid then
    for prototype_name, count in pairs(statistics.output_counts) do
      local prototype = prototypes.entity[prototype_name]
      if prototype and prototype.type == "unit-spawner"
        and finite_nonnegative(count) then
        total = math.min(MAX_POLLUTION_UNITS, total + count)
      end
    end
  end
  local pollutant = surface.pollutant_type
  return {
    units = total,
    affects_evolution = pollutant ~= nil and pollutant.affects_evolution == true
  }
end

local function apply(record, surface, ledger)
  local enemy_force = Teams.get_enemy_force(record)
  if not (enemy_force and surface and surface.valid and ledger) then return end
  local raw = raw_total(ledger)
  local factor = EvolutionMath.factor_from_raw(raw) -- raw / (1 + raw)
  ledger.value = factor
  enemy_force.set_evolution_factor(factor, surface)
end

local function active_team_surfaces()
  local active = {}
  for _, player in pairs(game.connected_players) do
    local record = Teams.get_for_player(player)
    -- In Space Age, the viewed surface can move while the character remains
    -- on the physically occupied planet. Spectators/editor/god
    -- controllers have no character and therefore contribute no evolution.
    local character = player.character
    local surface = character and character.valid and character.surface or nil
    if record and surface and surface.valid then
      local team_surfaces = active[record.id]
      if not team_surfaces then
        team_surfaces = {}
        active[record.id] = team_surfaces
      end
      team_surfaces[surface.index] = true
    end
  end
  return active
end

function Evolution.sync_connected(tick)
  local active = active_team_surfaces()
  local progression_enabled = enabled()
  local time_coefficient = coefficient("sceatorio-evolution-time-per-minute", DEFAULT_TIME_PER_MINUTE)
  local pollution_coefficient = coefficient(
    "sceatorio-evolution-pollution-per-unit",
    DEFAULT_POLLUTION_PER_UNIT
  )
  local pollution_samples = {}

  for team_id, surface_indexes in pairs(active) do
    local record = Teams.get(team_id)
    if record then
      for surface_index in pairs(surface_indexes) do
        local surface = game.surfaces[surface_index]
        if surface then Teams.ensure_surface(record, surface) end
      end
    end
  end

  for _, record in pairs(State.get().teams_by_id) do
    for surface_index, surface_record in pairs(record.surfaces or {}) do
      local surface = game.surfaces[surface_index]
      local ledger = surface_record.evolution and ledger_for(record, surface) or nil
      if ledger then
        local pollution_sample = pollution_samples[surface_index]
        if not pollution_sample then
          pollution_sample = sample_pollution(surface)
          pollution_samples[surface_index] = pollution_sample
        end
        EvolutionMath.sync_pollution(
          ledger,
          pollution_sample,
          progression_enabled,
          pollution_coefficient,
          MAX_POLLUTION_UNITS
        )
        local team_active = active[record.id]
        EvolutionMath.sync_connected_time(
          ledger,
          tick,
          team_active and team_active[surface_index] == true,
          progression_enabled,
          time_coefficient,
          TICKS_PER_MINUTE
        )
        apply(record, surface, ledger)
      end
    end
  end
end

local function ends_with(value, suffix)
  return string.sub(value, -#suffix) == suffix
end

function Evolution.on_entity_died(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end

  local victim_team = Teams.get_by_enemy_force(entity.force)
  if not victim_team then return end

  local killer_force = event.force
  if not killer_force and event.cause and event.cause.valid then
    killer_force = event.cause.force
  end
  local killer_team = Teams.get_by_force(killer_force)
  if not killer_team or killer_team.id ~= victim_team.id then return end

  local is_spawner = entity.type == "unit-spawner"
  local is_worm = entity.type == "turret" and ends_with(entity.name, "-worm-turret")
  if not (is_spawner or is_worm) then return end

  local ledger = ledger_for(victim_team, entity.surface)
  if not ledger then return end
  if is_spawner then
    ledger.spawner_kills = ledger.spawner_kills + 1
    if enabled() then
      ledger.raw_spawner = ledger.raw_spawner + coefficient(
        "sceatorio-evolution-spawner-per-kill",
        DEFAULT_SPAWNER_PER_KILL
      )
    end
  else
    ledger.worm_kills = ledger.worm_kills + 1
    if enabled() then
      ledger.raw_worm = ledger.raw_worm + coefficient(
        "sceatorio-evolution-worm-per-kill",
        DEFAULT_WORM_PER_KILL
      )
    end
  end
  apply(victim_team, entity.surface, ledger)
end

function Evolution.get_factor(record, surface)
  local surface_record = Teams.get_surface(record, surface)
  local ledger = surface_record and surface_record.evolution or nil
  return ledger and (ledger.value or EvolutionMath.factor_from_raw(raw_total(ledger))) or nil
end

function Evolution.configure_vanilla()
  local root = State.get()
  root.vanilla_evolution = root.vanilla_evolution or {}
  local state = root.vanilla_evolution
  local evolution_settings = game.map_settings.enemy_evolution
  local policy = setting("sceatorio-vanilla-evolution-policy", "disable")

  if not state.disabled_by_mod then
    state.previously_enabled = evolution_settings.enabled
    state.disabled_by_mod = true
  end
  state.previously_time_factor = state.previously_time_factor or evolution_settings.time_factor
  state.previously_destroy_factor = state.previously_destroy_factor or evolution_settings.destroy_factor
  state.previously_pollution_factor = state.previously_pollution_factor
    or evolution_settings.pollution_factor
  -- Engine evolution is global across forces on a surface. It must stay off so
  -- it cannot double-count the custom per-team time/kill/pollution ledgers.
  -- The preserve policy retains the configured component coefficients for
  -- compatibility, but never enables the shared engine accumulator.
  evolution_settings.enabled = false
  if policy == "preserve" then
    evolution_settings.time_factor = state.previously_time_factor
    evolution_settings.destroy_factor = state.previously_destroy_factor
    evolution_settings.pollution_factor = state.previously_pollution_factor
  else
    evolution_settings.time_factor = 0
    evolution_settings.destroy_factor = 0
    evolution_settings.pollution_factor = 0
  end

  local signature = table.concat({
    tostring(evolution_settings.enabled),
    tostring(evolution_settings.time_factor),
    tostring(evolution_settings.destroy_factor),
    tostring(evolution_settings.pollution_factor),
    policy
  }, ":")
  if state.last_logged_signature ~= signature then
    log(string.format(
      "[Sceatorio] vanilla evolution policy=%s enabled=%s time=%g destroy=%g pollution=%g; team evolution remains mod-owned",
      policy,
      tostring(evolution_settings.enabled),
      evolution_settings.time_factor,
      evolution_settings.destroy_factor,
      evolution_settings.pollution_factor
    ))
    state.last_logged_signature = signature
  end
end

function Evolution.on_setting_changed(event)
  if string.sub(event.setting, 1, #"sceatorio-evolution-") == "sceatorio-evolution-"
    or event.setting == "sceatorio-vanilla-evolution-policy" then
    Evolution.sync_connected(event.tick)
    Evolution.configure_vanilla()
  end
end

return Evolution
