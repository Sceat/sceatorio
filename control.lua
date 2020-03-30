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

unit_names = {
	["behemoth-biter"] = "a Gigantic green Biter",
	["behemoth-spitter"] = "a Gigantic green Spitter",
	["big-biter"] = "the Great blue Biter",
	["big-spitter"] = "the Great blue Spitter",
	["medium-biter"] = "an Average Biter",
	["medium-spitter"] = "an Average Spitter",
	["small-biter"] = "a ridiculous insect",
	["small-spitter"] = "a ridiculous spitting insect"
}

script.on_event(defines.events.on_player_died, function(e)
	local player = game.players[e.player_index]
	if(e.cause ~= nil) then
		local unit_name = unit_names[e.cause.name]
		if(unit_name ~= nil) then
			say(player.name.." was murdered by "..unit_name)
		else
			say(player.name.." has been wiped out from this planet")
		end
	else
		say(player.name.."'s corpse was reduced to atoms.. rip")
	end
end)

script.on_event(defines.events.on_player_left_game, function(e)
	protectPlayer(e)
end)

script.on_event(defines.events.on_player_joined_game, function(e)
	unProtectPlayer(e)
	local player = game.players[e.player_index]
	create_container(player)
	player.force.chart(player.surface,{{x = -200, y = -200}, {x = 200, y = 200}})
	if(player.force.name == 'lobby') then
		showSpawnGui(player)
	end
end)

commands.add_command('equalize_all', '', function(e)
	if not game.players[e.player_index].admin then return end
	say('equalizing entities')
	for _,e in pairs(game.surfaces.nauvis.find_entities_filtered{type={"unit","turret","unit-spawner"}}) do
		local nearest = findNearestForce(e.position)
		if(nearest.force == nil) then
			say('no nearest force found for '..e.type..' at position '..e.position.x..','..e.position.y)
		else
			say('nearest force is '..nearest.force.name)
			if e.force.name ~= ('enemy='..nearest.force.name) then
				say(e.name.." from "..e.force.name.."'s clan is inside enemy="..nearest.force.name.."'s clan territory and has been destroyed")
				e.destroy()
			end
		end
	end
end)


-- preventing biters from another team from expending to another team territory
script.on_event(defines.events.on_build_base_arrived, function(e)
	local positon = nil
	local force = nil
	if e.group ~= nil then
		position = e.group.position
		force = e.group.force
	elseif e.unit ~= nil then
		position = e.unit.position
		force = e.unit.force
	else return end
	local nearest = findNearestForce(position)
	if(nearest.force == nil) then return end
	if(force.name ~= ('enemy='..nearest.force.name)) then
		if(e.unit ~= nil) then e.unit.destroy()
		else
			for _,entity in ipairs(e.group) do
				entity.destroy()
			end
		end
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

script.on_nth_tick(60*10, function(e)
	playerChart()
	for _,player in pairs(game.connected_players) do
		tick_player_list(player)
	end
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

script.on_event(defines.events.on_gui_click, function(event)
	if not (event and event.element and event.element.valid) then return end
	if(event.element.name == 'toggle_players') then
		toggle_player_list(game.players[event.player_index])
	else
		onButtonClick(event)
	end
end)