require("src.game.offlineSecurity")
require("src.game.chat")
require("src.game.spawns")
require("src.game.radars")
require("src.game.playerList")

script.on_init(function()
	onInit()
end)

script.on_event(defines.events.on_chunk_generated, function(e)
	onChunkGen(e)
end)

script.on_event(defines.events.on_player_died, function(e)
	onDeathMsg(e)
end)

script.on_event(defines.events.on_player_left_game, function(e)
	protectPlayer(e)
end)

script.on_event(defines.events.on_player_joined_game, function(e)
	CreatePlayerListGui(e)
	unProtectPlayer(e)
	local player = game.players[e.player_index]
	player.force.chart(player.surface,{{x = -200, y = -200}, {x = 200, y = 200}})
	if(player.force.name == 'lobby') then
		showSpawnGui(player)
	end
end)

script.on_event(defines.events.on_player_created, function(e)
	onCreate(e)
end)

script.on_event(defines.events.on_console_chat, function(e)
    forwardMsg(e)
end)

script.on_event(defines.events.on_research_started, function(e)
	onSearchStart(e)
end)

script.on_event(defines.events.on_tick, function(e)
  if(e.tick % 1800 == 0) then -- every 30s
    for _,player in pairs(game.connected_players) do
        updatePlayerList(player)
    end
	end
	if(e.tick % 600 == 0) then -- every 10s
		playerChart()
	end
	on_tick(e)
end)

script.on_event(defines.events.on_gui_click, function(e)
	PlayerListGuiClick(e)
	onButtonClick(e)
end)