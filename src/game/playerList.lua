function style_element(element, style)
	for k,v in pairs(style) do
		element.style[k]=v
	end
end

function formattime_hours_mins(ticks)
		local seconds = ticks / 60
		local minutes = math.floor((seconds)/60)
		local hours   = math.floor((minutes)/60)
		local minutes = math.floor(minutes - 60*hours)
		return string.format("%dh:%02dm", hours, minutes)
	end

function create_player_list(player)
	local container = player.gui.top.sceatorio
	local player_list = container.add{type="flow", name="player_list", direction="vertical"}
	local online_list = player_list.add{type="frame", name="online_list",direction="vertical"}
	local offline_list = player_list.add{type="frame", name="offline_list",direction="vertical"}

	style_element(player_list, {
		horizontally_stretchable = true,
	})

	style_element(online_list, {
		horizontally_stretchable = true,
	})

	style_element(offline_list, {
		horizontally_stretchable = true,
	})

	tick_player_list(player)
end

function create_container(player)
	local container = player.gui.top.add{name="sceatorio",type="frame", direction="vertical"}
	local daytime = game.surfaces.nauvis.daytime
	local server_daytime = container.add{name="day_time",type="flow",direction="horizontal"}
	local server_daytime_label = server_daytime.add{type="label",caption="Day time: "}
	local server_daytime_progress = server_daytime.add{name="day_progress",type="progressbar", value=daytime}

	local toggle_list = container.add{name="toggle_players",type="button", caption="Show players"}

	style_element(container, {
		top_margin = 10,
		padding = 2
	})

	style_element(server_daytime, {
		padding = 0,
		vertical_align = "center"
	})

	style_element(toggle_list, {
		padding = 0
	})

end

function tick_player_list(player)
	local daytime = game.surfaces.nauvis.daytime
	local container = player.gui.top.sceatorio
	-- updating day time progress
	container.day_time.day_progress.value = daytime
	local player_list = container.player_list

	if(player_list == nil) then return end

	local online_list = player_list.online_list
	local offline_list = player_list.offline_list
	online_list.clear()
	offline_list.clear()

	for _,player in pairs(game.players) do
		local name = player.name
		local forcename = player.force.name
		local enemy_force = game.forces['enemy='..forcename]
		local difficulty = 'none'
		local time = formattime_hours_mins(player.online_time)
		if(enemy_force ~= nil) then
			local diff = enemy_force.evolution_factor * 100
			difficulty = string.format("%.f", diff > 100 and 100 or diff)
		end
		local capt = "["..forcename.."] "..name.." | Evolution "..difficulty.."% | "..time
		if(player.connected) then
			local label = online_list.add{name=(player.name.."_infos"),type="label", caption=capt}
			style_element(label, {
				font_color = player.color,
			})
		else
			local label = offline_list.add{name=(player.name.."_infos"),type="label", caption=capt}
			style_element(label, {
				font_color = {r=0.5,g=0.5,b=0.5},
			})
		end
	end
end

function toggle_player_list(player)
	if(player.gui.top.sceatorio.player_list == nil) then
		create_player_list(player)
	else
		player.gui.top.sceatorio.player_list.destroy()
	end
end
