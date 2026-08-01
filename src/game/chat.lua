local State = require("src.core.state")
local Teams = require("src.game.teams")

local Chat = {}

function Chat.forward(event)
  -- Dedicated-server console chat has no player index and is already server-wide.
  if not event.player_index then return end
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  local color = {r = player.color.r, g = player.color.g, b = player.color.b, a = 1}
  local message = player.name .. ": " .. event.message

  local delivered = {}
  for _, record in pairs(State.get().teams_by_id) do
    local force = Teams.get_force(record)
    if force and force.index ~= player.force.index and not delivered[force.index] then
      force.print(message, color)
      delivered[force.index] = true
    end
  end
  local lobby = game.forces.lobby
  if lobby and lobby.index ~= player.force.index then
    lobby.print(message, color)
  end
end

function Chat.on_research_started(event)
  local research = event.research
  if not (research and research.valid and research.force and research.force.valid) then return end
  local record = Teams.get_by_force(research.force)
  local starter = record and record.display_name or research.force.name
  for _, player in pairs(game.connected_players) do
    if player.force.index ~= research.force.index then
      player.print({
        "player-started-research",
        research.localised_name,
        starter
      })
    end
  end
end

return Chat
