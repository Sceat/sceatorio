require('src.utils.msg')

function forwardMsg(e)
	local player = game.players[e.player_index]
	local msg = e.message
    for _,force in pairs(game.forces) do
        if (force ~= nil) then
            if ((force.name ~= enemy) and
                (force.name ~= neutral) and
                (force.name ~= player) and
                (force ~= player.force)) then
                force.print(player.name..": "..msg)
            end
        end
    end
end

function onDeathMsg(e)
	callOnPlayer(function(p)
		if(game.players[e.player_index] ~= p) then
			p.print{"player-died-by",game.players[e.player_index].name, e.cause.localised_name}
		end
	end)
end

function onSearchStart(e)
	callOnPlayer(function(p)
		p.print{"player-started-research",e.research.force.name, e.research.localised_name}
	end)
end

function onSearchEnd(e)
	say(e.research.force.name.." finished a research")
end
