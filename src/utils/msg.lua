function say(msg)
	for _,p in pairs(game.players) do
		if p.connected then
			p.print("[sceatorio] "..msg)
		end
	end
end

function callOnPlayer(fn)
	for _,p in pairs(game.players) do
		if p.connected then
			fn(p)
		end
	end
end