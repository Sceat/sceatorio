local EvolutionMath = {}

function EvolutionMath.factor_from_raw(raw)
  if type(raw) ~= "number" or raw <= 0 then return 0 end
  return raw / (1 + raw)
end

function EvolutionMath.raw_from_factor(factor)
  if type(factor) ~= "number" or factor <= 0 then return 0 end
  if factor >= 1 then return 999999999 end
  return factor / (1 - factor)
end

-- Account the elapsed interval under the policy that was active when the
-- interval began. Runtime-setting events arrive after Factorio changes the
-- setting, so using the new value for the preceding interval would either lose
-- enabled time on disable or back-charge disabled time on re-enable.
function EvolutionMath.sync_connected_time(
  ledger,
  tick,
  team_active,
  progression_enabled,
  coefficient,
  ticks_per_minute
)
  local previous_policy = ledger.connected_progression_enabled
  if previous_policy == nil then previous_policy = progression_enabled end
  local previous_coefficient = ledger.connected_time_coefficient
  if type(previous_coefficient) ~= "number" then previous_coefficient = coefficient end
  if ledger.connected_since then
    local elapsed = math.max(0, tick - ledger.connected_since)
    ledger.connected_ticks = ledger.connected_ticks + elapsed
    if previous_policy then
      ledger.raw_time = ledger.raw_time
        + (elapsed / ticks_per_minute) * previous_coefficient
    end
  end

  if team_active then
    ledger.connected_since = tick
    ledger.connected_progression_enabled = progression_enabled == true
    ledger.connected_time_coefficient = coefficient
  else
    ledger.connected_since = nil
    ledger.connected_progression_enabled = nil
    ledger.connected_time_coefficient = nil
  end
end

-- Cumulative unit-spawner pollution-consumption statistics are sampled, so
-- their positive delta belongs to the policy/coefficient recorded at the
-- previous sample. This gives runtime setting changes the same exact interval
-- boundary as connected time.
function EvolutionMath.sync_pollution(
  ledger,
  sample,
  progression_enabled,
  coefficient,
  maximum_units
)
  local current = sample.units
  local previous = ledger.pollution_cursor
  local previous_policy = ledger.pollution_progression_enabled
  if previous_policy == nil then previous_policy = progression_enabled end
  local previous_coefficient = ledger.pollution_coefficient
  if type(previous_coefficient) ~= "number" then previous_coefficient = coefficient end

  ledger.pollution_cursor = current
  ledger.pollution_progression_enabled = progression_enabled == true
  ledger.pollution_coefficient = coefficient

  -- A first observation or cleared/reset counter establishes a new baseline.
  if previous == nil or current < previous then return end
  local delta = current - previous
  if delta <= 0 then return end

  ledger.pollution_units = math.min(maximum_units, ledger.pollution_units + delta)
  if previous_policy and sample.affects_evolution then
    ledger.raw_pollution = math.min(
      maximum_units,
      ledger.raw_pollution + delta * previous_coefficient
    )
  end
end

return EvolutionMath
