function chart_entity_position(entity, force, radius)
	local x = entity.position.x
	local y = entity.position.y
	local area = {{x-radius,y-radius},{x+radius,y+radius}}
	force.chart('nauvis', area)
end

function get_all_radars()
	local surface = game.surfaces.nauvis
	local radars = {}
	for _,radar in pairs(game.surfaces.nauvis.find_entities_filtered{type="radar"}) do
		table.insert(radars, radar)
	end
	return radars
end

function get_all_connected_players_forces()
	local forces = {}
	for _,force in pairs(game.forces) do
		if(force.name ~= 'lobby') and (force.name ~= 'player') and (#force.connected_players ~= 0) then table.insert(forces, force) end
	end
	return forces
end

function chart_radars_and_players()
	local online_forces = get_all_connected_players_forces()
	local radars = get_all_radars()
	for _,force in pairs(online_forces) do
		for _,player in pairs(game.connected_players) do if player.force.name ~= force.name then chart_entity_position(player, force, 70)	end end
		for _,radar in pairs(radars) do	chart_entity_position(radar, force, 112)	end
	end
end

