require("src.game.spawns")

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

function delete_chunks_in_range(center, range)
  for x=-range, range do
    for y=-range, range do
      local chunk_position = {x=center.x+x, y=center.y+y}
      game.surfaces.nauvis.delete_chunk(chunk_position)
    end
  end
end

function eradicate(player)
  local force = player.force
  local player_name = player.name
  local spawn = force.get_spawn_position('nauvis')
  local nearest = findNearestForce(spawn, force.name)
  local enemy_force = game.forces['enemy='..force.name]
  if(enemy_force == nil) or (nearest.force == nil) then
    say('tried to eradicate '..force.name..' but no enemy force or nearest force has been found')
    return
  end
  say('deleting '..player.name..'..')
  game.remove_offline_players{player}

  say('reseting the force '..force.name)
  force.reset()
  say('reseting the force '..enemy_force.name)
  enemy_force.reset()
  enemy_force.kill_all_units()

  say('destroying all entities from '..force.name)
  for _,entity in pairs(game.surfaces.nauvis.find_entities_filtered{force=force}) do
    entity.destroy()
  end

  say('merging into the default force.')
  game.merge_forces(force, game.forces.player)

  say("scheduling chunk deletion in a 11x11 default area.. (let's hope it doesn't impact other players :/)")
  local chunk_x = (spawn.x - 16) / 32
  local chunk_y = (spawn.y - 16) / 32
  delete_chunks_in_range({x=chunk_x,y=chunk_y}, 11)

  say('reassigning ennemies..')
  for _,e in pairs(game.surfaces.nauvis.find_entities_filtered{force=enemy_force}) do
		local nearest = findNearestForce(e.position)
		if(nearest.force == nil) then
			say('no nearest force found for '..e.type..' at position '..e.position.x..','..e.position.y)
    elseif e.force.name ~= ('enemy='..nearest.force.name) then
			e.force = ('enemy='..nearest.force.name)
			say(e.name.." joined "..nearest.force.name)
		end
	end

  game.merge_forces(enemy_force, ('enemy='..nearest.force.name))

  say(player_name..' has been eradicated from the game')
end

commands.add_command('eradicate', 'remove a player from existence', function(e)
  local admin = game.players[e.player_index]
  if not admin.admin then return end
  local arg = e.parameter
  if arg == nil then
    admin.print('player name missing')
    return
  end
  local player = game.players[arg]
  if(player == nil) then
    admin.print('player ['..arg..'] not found')
    return
  end
  if player.connected then game.kick_player(player) end
  if #player.force.players > 1 then game.remove_offline_players{player}
  else eradicate(player) end
end)