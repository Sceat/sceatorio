local Message = {}

function Message.say(message)
  game.print("[Sceatorio] " .. message)
end

function Message.for_connected(callback)
  for _, player in pairs(game.connected_players) do
    callback(player)
  end
end

return Message
