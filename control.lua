require("src.game.offlineSecurity")
require("src.game.chat")
require("src.game.spawns")
require("src.game.evo")
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

script.on_nth_tick(60*30, function(e)
	for _,player in pairs(game.connected_players) do
		updatePlayerList(player)
	end
end)

script.on_nth_tick(60*10, function(e)
	playerChart()
end)

script.on_nth_tick(60*60, function(e)
	local forces = {}
	for _,player in pairs(game.connected_players) do
		if(player.force.name ~= 'lobby') and (player.force.name ~= 'player') then
			forces[player.force] = true
		end
	end
	for force in pairs(forces) do
		evolveTeamEnemies(force)
	end
end)

script.on_nth_tick(60, function(e)
	if global.tp ~= nil then
		for _,t in pairs(global.tp) do
			if(t.player == nil) or (t.player.connected == false) then
				global.tp[_]=nil
			else
				t.time = t.time-1
				t.time_chunk = t.time_chunk-1
				if(t.time_chunk < 1) then
					spawnAlone(t.player, t.spawn)
					t.time_chunk = 10
				end
				if(t.time < 1 and t.player.connected) then
					say('teleporting '..(t.player.name)..' to his spawn')
					t.player.teleport(t.spawn,game.surfaces.nauvis)
					global.tp[_]=nil
				end
			end
		end
	end
end)

script.on_event(defines.events.on_gui_click, function(e)
	PlayerListGuiClick(e)
	onButtonClick(e)
end)