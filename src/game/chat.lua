require('src.utils.msg')

function forwardMsg(e)
	local player = game.players[e.player_index]
	local msg = e.message
	for _,force in pairs(game.forces) do
		if (force ~= nil) then
			if ((force.name ~= enemy) and (force.name ~= neutral) and (force.name ~= player) and (force ~= player.force)) then
				local c = player.color
				force.print(player.name..": "..msg, {r=c.r,g=c.g,b=c.b,a=1})
			end
		end
	end
end

function onSearchStart(e)
	callOnPlayer(function(p)
		p.print{"player-started-research",e.research.force.name, e.research.localised_name}
	end)
end