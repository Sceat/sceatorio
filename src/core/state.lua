local State = {}

local SCHEMA_VERSION = 5

local function new_root()
  return {
    schema_version = SCHEMA_VERSION,
    next_team_id = 1,
    next_join_token = 1,
    teams_by_id = {},
    team_id_by_force_index = {},
    team_id_by_enemy_force_index = {},
    scheduled_gui = {},
    pending_teleports = {},
    join_requests = {},
    player_character_surfaces = {},
    planet_spawn_queue = {},
    planet_spawn_cursor = 1,
    demolisher_tracker = {demolishers = {}, index = nil},
    player_list_collapsed = {},
    player_list_pages = {},
    player_list_cursor = 1,
    robot_policy = {},
    offline_security = {},
    warnings = {}
  }
end

local function migrate_legacy_root(root)
  if storage.scheduledGuiShow and not next(root.scheduled_gui) then
    root.scheduled_gui = storage.scheduledGuiShow
  end

  if storage.tp and not next(root.pending_teleports) then
    for _, legacy in pairs(storage.tp) do
      local player = legacy.player
      if player and player.valid then
        root.pending_teleports[player.index] = {
          player_index = player.index,
          surface_index = player.surface.index,
          spawn = legacy.spawn,
          due_tick = game.tick + math.max(0, legacy.time or 0) * 60,
          terrain_ready = false
        }
      end
    end
  end

  storage.scheduledGuiShow = nil
  storage.tp = nil
  storage.spawns = nil
end

function State.migrate_pollution_statistics_semantics(root, previous_schema)
  if previous_schema >= 5 then return end
  for _, record in pairs(root.teams_by_id) do
    for _, surface_record in pairs(record.surfaces or {}) do
      local ledger = surface_record.evolution
      if ledger then
        -- Schema 4 sampled gross pollution production. Schema 5 samples only
        -- pollution consumed by unit spawners, so the two cumulative cursors
        -- cannot be compared. Rebaseline diagnostics and interval policy while
        -- preserving raw_pollution: evolution already credited never goes
        -- backwards during the semantic upgrade.
        ledger.pollution_cursor = nil
        ledger.pollution_units = 0
        ledger.pollution_progression_enabled = nil
        ledger.pollution_coefficient = nil
      end
    end
  end
end

function State.initialize()
  local root = storage.sceatorio
  if not root then
    root = new_root()
    storage.sceatorio = root
  end
  local previous_schema = tonumber(root.schema_version) or 0

  root.teams_by_id = root.teams_by_id or {}
  root.team_id_by_force_index = root.team_id_by_force_index or {}
  root.team_id_by_enemy_force_index = root.team_id_by_enemy_force_index or {}
  root.scheduled_gui = root.scheduled_gui or {}
  root.pending_teleports = root.pending_teleports or {}
  root.join_requests = root.join_requests or {}
  root.player_character_surfaces = root.player_character_surfaces or {}
  root.planet_spawn_queue = root.planet_spawn_queue or {}
  root.planet_spawn_cursor = root.planet_spawn_cursor or 1
  root.demolisher_tracker = root.demolisher_tracker or {}
  root.demolisher_tracker.demolishers = root.demolisher_tracker.demolishers or {}
  root.player_list_collapsed = root.player_list_collapsed or {}
  root.player_list_pages = root.player_list_pages or {}
  root.player_list_cursor = root.player_list_cursor or 1
  root.robot_policy = root.robot_policy or {}
  root.offline_security = root.offline_security or {}
  root.warnings = root.warnings or {}
  root.next_team_id = root.next_team_id or 1
  root.next_join_token = root.next_join_token or 1

  migrate_legacy_root(root)
  State.migrate_pollution_statistics_semantics(root, previous_schema)
  root.schema_version = SCHEMA_VERSION
  return root
end

function State.get()
  return storage.sceatorio
end

return State
