function playerChart()
	for _,force in pairs(game.forces) do
		if (force.name ~= "humans") and (force.name ~= "neutral") and (force.name ~= "lobby") and (force.name ~= "player") and (force.name ~= "enemy") then
			for _,force2 in pairs(game.forces) do
				if (force2.name ~= "humans") and (force2.name ~= "neutral") and (force.name ~= "lobby") and (force2.name ~= "player") and (force2.name ~= "enemy") and (force.name ~= force2.name) then
					for _,member in pairs(force2.players) do
						if member.connected then
							local x = math.floor(member.position.x)
							local y = math.floor(member.position.y)
							force.chart('nauvis', {{x-70,y-70},{x+70,y+70}})
						end
					end
				end
			end
		end
	end
end