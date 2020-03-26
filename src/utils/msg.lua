function say(msg)
	game.surfaces.nauvis.print("[sceatorio] "..msg)
end

function callOnPlayer(fn)
	for _,p in pairs(game.players) do
		if p.connected then
			fn(p)
		end
	end
end