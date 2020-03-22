require('src.utils.msg')

script.on_event(defines.events.on_entity_died, function(event)
	if event.entity.type == 'player' then
		if event.cause ~= nil and event.cause.type == 'player' then
			say((event.entity.associated_player.name or 'undefined').." was humiliated by "..(event.cause.player.name or 'a wild coronavirus'))
		else
			say((event.entity.associated_player.name or 'undefined').." was humiliated by "..(event.cause.name or 'donald trump'))
		end
	end
end)