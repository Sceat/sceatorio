local Teams = require("src.game.teams")
local Spawns = require("src.game.spawns")
local PlanetSpawns = require("src.game.planetSpawns")
local Message = require("src.utils.msg")

local Admin = {}

local SETTING_PREFIX = "sceatorio-"
local MAX_SETTING_KEYS = 100

local function command_player(event)
  if not event.player_index then return nil, true end
  local player = game.players[event.player_index]
  return player, player and player.admin
end

local function reply(event, text)
  if event.player_index then
    local player = game.players[event.player_index]
    if player and player.valid then player.print(text) end
  else
    rcon.print(text)
  end
end

local function delete_chunks_in_range(surface, center, range)
  local center_chunk = {
    x = math.floor(center.x / 32),
    y = math.floor(center.y / 32)
  }
  for x = -range, range do
    for y = -range, range do
      surface.delete_chunk({x = center_chunk.x + x, y = center_chunk.y + y})
    end
  end
end

local function equalize_all(event)
  local admin, allowed = command_player(event)
  if not allowed then return end
  local removed = 0
  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered({type = {"turret", "unit-spawner"}})) do
      local team = Teams.get_by_enemy_force(entity.force)
      if team then
        local nearest = Spawns.find_nearest(surface, entity.position)
        if nearest.enemy_force and nearest.enemy_force.index ~= entity.force.index then
          entity.destroy()
          removed = removed + 1
        end
      end
    end
  end
  local text = "Equalization removed " .. removed .. " misplaced enemy structures."
  if admin then admin.print(text) else Message.say(text) end
end

local function eradicate_team(record)
  local force = Teams.get_force(record)
  local enemy_force = Teams.get_enemy_force(record)
  if not (force and enemy_force) then return false end

  local spawns = {}
  for surface_index, surface_record in pairs(record.surfaces or {}) do
    local surface = game.surfaces[surface_index]
    if surface and surface_record.spawn then
      spawns[#spawns + 1] = {surface = surface, position = surface_record.spawn}
    end
  end

  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered({force = {force, enemy_force}})) do
      entity.destroy()
    end
  end
  force.reset()
  enemy_force.reset()
  enemy_force.kill_all_units()
  Teams.remove(record)
  game.merge_forces(force, game.forces.player)
  game.merge_forces(enemy_force, game.forces.enemy)

  for _, spawn in ipairs(spawns) do
    delete_chunks_in_range(spawn.surface, spawn.position, 11)
  end
  return true
end

local function eradicate(event)
  local admin, allowed = command_player(event)
  if not allowed then return end
  if not event.parameter or event.parameter == "" then
    if admin then admin.print("Player name is required.") end
    return
  end
  local player = game.get_player(event.parameter)
  if not player then
    if admin then admin.print("Player '" .. event.parameter .. "' was not found.") end
    return
  end

  local record = Teams.get_for_player(player)
  if not record then
    if admin then admin.print("That player does not belong to a Sceatorio team.") end
    return
  end
  if player.connected then game.kick_player(player) end
  if #player.force.players > 1 then
    game.remove_offline_players({player})
    return
  end

  local name = player.name
  game.remove_offline_players({player})
  if eradicate_team(record) then
    Message.say(name .. " and their isolated spawn were eradicated.")
  end
end

local function apply_settings(event)
  local _, allowed = command_player(event)
  if not allowed then
    reply(event, "SCEATORIO_SETTINGS_ERROR=Administrator permission is required.")
    return
  end

  -- helpers.json_to_table returns nil for malformed or empty input instead of
  -- raising, so the type check below is what makes a bad payload fail loudly.
  -- A JSON object always decodes to string keys; anything else is not an object.
  local parsed, desired = pcall(helpers.json_to_table, event.parameter or "")
  local names = {}
  if parsed and type(desired) == "table" then
    for name in pairs(desired) do
      if type(name) ~= "string" then
        names = nil
        break
      end
      names[#names + 1] = name
    end
  else
    names = nil
  end
  if not names then
    reply(event, "SCEATORIO_SETTINGS_ERROR=Expected one JSON object of setting names to values.")
    return
  end
  if #names == 0 or #names > MAX_SETTING_KEYS then
    reply(event, "SCEATORIO_SETTINGS_ERROR=Expected between 1 and " .. MAX_SETTING_KEYS .. " setting names.")
    return
  end
  table.sort(names)

  local rejected = {}
  local changed = 0
  local unchanged = 0
  for _, name in ipairs(names) do
    local value = desired[name]
    local setting = settings.global[name]
    local reason
    if name:sub(1, #SETTING_PREFIX) ~= SETTING_PREFIX then
      reason = "name_is_not_a_sceatorio_setting"
    elseif not setting then
      reason = "setting_does_not_exist"
    elseif type(value) ~= type(setting.value) then
      reason = "expected_" .. type(setting.value) .. "_got_" .. type(value)
    end

    if reason then
      rejected[#rejected + 1] = "SCEATORIO_SETTINGS_REJECTED name=" .. name .. " reason=" .. reason
    elseif setting.value == value then
      unchanged = unchanged + 1
    else
      settings.global[name] = {value = value}
      -- Factorio silently coerces out-of-domain values (a fractional number
      -- written to an integer setting is truncated), which would make a
      -- reconciler report "changed" on every pass forever. Report instead.
      local stored = settings.global[name].value
      if stored == value then
        changed = changed + 1
      else
        rejected[#rejected + 1] = "SCEATORIO_SETTINGS_REJECTED name=" .. name
          .. " reason=value_was_coerced_to_" .. tostring(stored)
      end
    end
  end

  reply(event, "SCEATORIO_SETTINGS_APPLIED changed=" .. changed .. " unchanged=" .. unchanged .. " rejected=" .. #rejected)
  for _, line in ipairs(rejected) do reply(event, line) end
end

local function regenerate_vulcanus_spawn(event)
  local _, allowed = command_player(event)
  if not allowed then
    reply(event, "SCEATORIO_VULCANUS_REGEN_ERROR=Administrator permission is required.")
    return
  end
  local name = event.parameter or ""
  if name == "" then
    reply(event, "SCEATORIO_VULCANUS_REGEN_ERROR=Player name is required.")
    return
  end
  local player = game.get_player(name)
  if not player then
    reply(event, "SCEATORIO_VULCANUS_REGEN_ERROR=Player was not found: " .. name)
    return
  end
  local record = Teams.get_for_player(player)
  if not record then
    reply(event, "SCEATORIO_VULCANUS_REGEN_ERROR=Player has no Sceatorio team: " .. name)
    return
  end
  local ok, status = PlanetSpawns.regenerate_vulcanus_spawn(record, player)
  if not ok then
    reply(event, "SCEATORIO_VULCANUS_REGEN_ERROR=" .. status)
    return
  end
  reply(event, "SCEATORIO_VULCANUS_REGEN_QUEUED player=" .. player.name .. " status=" .. status)
end

commands.add_command("equalize_all", "Remove enemy structures assigned outside their team territory.", equalize_all)
commands.add_command("eradicate", "Remove a player and, if empty, their isolated team spawn.", eradicate)
commands.add_command(
  "sceatorio-apply-settings",
  "Reconcile Sceatorio runtime-global settings from one JSON object (admin or RCON only).",
  apply_settings
)
commands.add_command(
  "sceatorio-regenerate-vulcanus-spawn",
  "Generate a fresh Vulcanus team spawn and route the named player there (admin or RCON only).",
  regenerate_vulcanus_spawn
)

Admin.equalize_all = equalize_all
Admin.eradicate = eradicate
Admin.apply_settings = apply_settings
Admin.regenerate_vulcanus_spawn = regenerate_vulcanus_spawn

return Admin
