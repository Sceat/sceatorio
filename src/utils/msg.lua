function say(msg)
	for _,p in pairs(game.players) do
		if p.online then
			p.print("-> "..msg)
		end
	end
end