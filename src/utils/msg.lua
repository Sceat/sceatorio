function say(msg)
	for _,p in pair(game.players) do
		if p.online then
			p.print("-> "..msg)
		end
	end
end