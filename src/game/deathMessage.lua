local Message = require("src.utils.msg")

local DeathMessage = {}

local UNIT_NAMES = {
  ["behemoth-biter"] = "a gigantic green biter",
  ["behemoth-spitter"] = "a gigantic green spitter",
  ["big-biter"] = "a great blue biter",
  ["big-spitter"] = "a great blue spitter",
  ["medium-biter"] = "an average biter",
  ["medium-spitter"] = "an average spitter",
  ["small-biter"] = "a small biter",
  ["small-spitter"] = "a small spitter"
}

function DeathMessage.on_player_died(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  if event.cause and event.cause.valid then
    local cause = UNIT_NAMES[event.cause.name] or event.cause.localised_name
    game.print({"sceatorio.player-killed", player.name, cause})
  else
    Message.say(player.name .. " did not survive.")
  end
end

return DeathMessage
