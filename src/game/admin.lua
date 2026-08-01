local Teams = require("src.game.teams")
local Spawns = require("src.game.spawns")
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

  local parsed, desired = pcall(helpers.json_to_table, event.parameter or "")
  if not (parsed and type(desired) == "table") then
    reply(event, "SCEATORIO_SETTINGS_ERROR=Expected one JSON object of setting names to values.")
    return
  end

  local names = {}
  local rejected = {}
  local keys = 0
  for name in pairs(desired) do
    keys = keys + 1
    if type(name) == "string" then
      names[#names + 1] = name
    else
      rejected[#rejected + 1] = "SCEATORIO_SETTINGS_REJECTED name=" .. tostring(name) .. " reason=name_is_not_a_string"
    end
  end
  if keys == 0 or keys > MAX_SETTING_KEYS then
    reply(event, "SCEATORIO_SETTINGS_ERROR=Expected between 1 and " .. MAX_SETTING_KEYS .. " setting names.")
    return
  end
  table.sort(names)

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
      changed = changed + 1
    end
  end

  table.sort(rejected)
  reply(event, "SCEATORIO_SETTINGS_APPLIED changed=" .. changed .. " unchanged=" .. unchanged .. " rejected=" .. #rejected)
  for _, line in ipairs(rejected) do reply(event, line) end
end

commands.add_command("equalize_all", "Remove enemy structures assigned outside their team territory.", equalize_all)
commands.add_command("eradicate", "Remove a player and, if empty, their isolated team spawn.", eradicate)
commands.add_command(
  "sceatorio-apply-settings",
  "Reconcile Sceatorio runtime-global settings from one JSON object (admin or RCON only).",
  apply_settings
)

Admin.equalize_all = equalize_all
Admin.eradicate = eradicate
Admin.apply_settings = apply_settings

return Admin
