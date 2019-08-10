require('src.utils.msg')

script.on_event(defines.events.on_entity_died, function(event)
	if event.entity.type == 'player' then
		if event.cause ~= nil and event.cause.type == 'player' then
			say((event.entity.player.name or 'undefined').." s'est fait peter la gueule par "..(event.cause.player.name or 'undefined'))
		else
			say((event.entity.player.name or 'undefined').." s'est fait peter la gueule par "..(event.cause.name or 'undefined'))
		end
	end
end)