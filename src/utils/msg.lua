function say(msg)
	for _,p in pairs(game.players) do
		if p.connected then
			p.print("-> "..msg)
		end
	end
end