function say(msg)
	for _,p in pairs(game.players) do
		if p.connected then
			p.print("[RPG] "..msg)
		end
	end
end