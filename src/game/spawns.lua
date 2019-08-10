require("src.utils.compute")

MIN_SPAWN_DIST = 5000
MAX_SPAWN_DIST = 9000

MIN_PLAYER_DIST = 3000

function findNewSpawn()
	local existingSpawns = {}
	table.insert(existingSpawns, {x=0,y=0}) -- inserting main spawn
	for _,force in pairs(game.forces) do
		if force.name == 'enemy' then continue end
		local teamSpawn = force.get_spawn_position('nauvis')
		table.insert(existingSpawns, teamSpawn)
	end
end

script.on_event(defines.events.on_player_created, function(event)
	-- spawn and save spawn
end)

script.on_event(defines.events.on_player_joined_game, function(event)
	
end)