function protectForce(playerForce, protect)
	for _,force in pairs(game.forces) do
		force.set_cease_fire(playerForce, protect)
	end
	for _,build in pairs(game.surfaces['nauvis'].find_entities_filtered{force=playerForce.name}) do
		build.destructible = not protect
	end
end

function protectPlayer(event)
	protectForce(game.players[event.player_index].force, true)
end

function unProtectPlayer(event)
	protectForce(game.players[event.player_index].force, false)
end