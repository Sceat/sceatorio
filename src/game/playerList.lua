function formattime_hours_mins(ticks)

	local seconds = ticks / 60

	local minutes = math.floor((seconds)/60)

	local hours   = math.floor((minutes)/60)

	local minutes = math.floor(minutes - 60*hours)

	return string.format("%dh:%02dm", hours, minutes)

  end

  -- Shorter way to add a label with a style

function AddLabel(guiIn, name, message, style)

    guiIn.add{name = name, type = "label",

                    caption=message}

    ApplyStyle(guiIn[name], style)

end

function UpdateLabel(guiIn,name,message,style)

    guiIn[name].caption = message

    -- ApplyStyle(guiIn[name], style)
end



-- Shorter way to add a spacer

function AddSpacer(guiIn, name)

    guiIn.add{name = name, type = "label",

                    caption=" "}

    ApplyStyle(guiIn[name], my_spacer_style)

end



-- Shorter way to add a spacer with a decorative line

function AddSpacerLine(guiIn, name)

    guiIn.add{name = name, type = "label",

                    caption="~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"}

    ApplyStyle(guiIn[name], my_spacer_style)

end

--------------------------------------------------------------------------------
-- GUI Label Styles -- by oarc
--------------------------------------------------------------------------------

my_fixed_width_style = {

    minimal_width = 450,

    maximal_width = 450

}

my_label_style = {

    -- minimal_width = 450,

    -- maximal_width = 50,

    single_line = false,

    font_color = {r=1,g=1,b=1},

    top_padding = 0,

    bottom_padding = 0

}

my_note_style = {

    -- minimal_width = 450,

    single_line = false,

    font = "default-small-semibold",

    font_color = {r=1,g=0.5,b=0.5},

    top_padding = 0,

    bottom_padding = 0

}

my_warning_style = {

    -- minimal_width = 450,

    -- maximal_width = 450,

    single_line = false,

    font_color = {r=1,g=0.1,b=0.1},

    top_padding = 0,

    bottom_padding = 0

}

my_spacer_style = {

    minimal_height = 10,

    font_color = {r=0,g=0,b=0},

    top_padding = 0,

    bottom_padding = 0

}

my_small_button_style = {

    font = "default-small-semibold"

}

my_player_list_fixed_width_style = {

    minimal_width = 200,

    maximal_width = 400,

    maximal_height = 200

}

my_player_list_admin_style = {

    font = "default-semibold",

    font_color = {r=1,g=0.5,b=0.5},

    minimal_width = 200,

    top_padding = 0,

    bottom_padding = 0,

    single_line = false,

}

my_player_list_style = {

    font = "default-semibold",

    minimal_width = 200,

    top_padding = 0,

    bottom_padding = 0,

    single_line = false,

}

my_player_list_offline_style = {

    -- font = "default-semibold",

    font_color = {r=0.5,g=0.5,b=0.5},

    minimal_width = 200,

    top_padding = 0,

    bottom_padding = 0,

    single_line = false,

}

my_player_list_style_spacer = {

    minimal_height = 20,

}

my_color_red = {r=1,g=0.1,b=0.1}



my_longer_label_style = {

    maximal_width = 600,

    single_line = false,

    font_color = {r=1,g=1,b=1},

    top_padding = 0,

    bottom_padding = 0

}

my_longer_warning_style = {

    maximal_width = 600,

    single_line = false,

    font_color = {r=1,g=0.1,b=0.1},

    top_padding = 0,

    bottom_padding = 0

}

--------------------------------------------------------------------------------
-- Player List GUI - oarc version made realtime
--------------------------------------------------------------------------------

function ApplyStyle (guiIn, styleIn)

    for k,v in pairs(styleIn) do

        guiIn.style[k]=v

    end

end

function CreatePlayerListGui(event)

	local player = game.players[event.player_index]

	if player.gui.top.playerList == nil then

		player.gui.top.add{name="playerList", type="button", caption="Player List"}

	end

  end

  local function drawPlayerListGui(player, frame, scrollFrame)
	  ApplyStyle(scrollFrame, my_player_list_fixed_width_style)
	  scrollFrame.horizontal_scroll_policy = "never"
	  for _,player in pairs(game.connected_players) do
		  local caption_str = player.name.." ["..player.force.name.."]".." ("..formattime_hours_mins(player.online_time)..")"
		  if (player.admin) then
			  AddLabel(scrollFrame, player.name.."_plist", caption_str, my_player_list_admin_style)
		  else
			  AddLabel(scrollFrame, player.name.."_plist", caption_str, my_player_list_style)
		  end
	  end

	  -- List offline players
	  for _,player in pairs(game.players) do
		  if (not player.connected) then
			  local caption_str = player.name.." ["..player.force.name.."]".." ("..formattime_hours_mins(player.online_time)..")"
			  local text = scrollFrame.add{type="label", caption=caption_str, name=player.name.."_plist"}
			  ApplyStyle(text, my_player_list_offline_style)
		  end
	  end
	  local spacer = scrollFrame.add{type="label", caption="     ", name="plist_spacer_plist"}
	  ApplyStyle(spacer, my_player_list_style_spacer)
  end

  function updatePlayerList(player)
	  local frame = player.gui.left["playerList-panel"]
	  if(frame) then
		  local scrollframe = frame['playerList-panel-scroll']
		  scrollframe.clear()
		  for _,player in pairs(game.players) do
			  if(player.connected) then
				  local caption_str = player.name.." ["..player.force.name.."]".." ("..formattime_hours_mins(player.online_time)..")"
				  if (player.admin) then
					  AddLabel(scrollframe, player.name.."_plist", caption_str, my_player_list_admin_style)
				  else
					  AddLabel(scrollframe, player.name.."_plist", caption_str, my_player_list_style)
				  end
			  else
				  local caption_str = player.name.." ["..player.force.name.."]".." ("..formattime_hours_mins(player.online_time)..")"
				  local text = scrollframe.add{type="label", caption=caption_str.."(offline)", name=player.name.."_plist"}
				  ApplyStyle(text, my_player_list_offline_style)
			  end
		  end
	  end
  end

  local function ExpandPlayerListGui(player)
	  local frame = player.gui.left["playerList-panel"]
	  if (frame) then
		  frame.destroy()
	  else
		  local frame = player.gui.left.add{type="frame", name="playerList-panel", caption="Online:"}
		  local scrollFrame = frame.add{type="scroll-pane", name="playerList-panel-scroll", direction = "vertical"}
		  drawPlayerListGui(player,frame,scrollFrame)
	  end
  end



  function PlayerListGuiClick(event)

	  if not (event and event.element and event.element.valid) then return end

	  local player = game.players[event.element.player_index]

	  local name = event.element.name



	  if (name == "playerList") then

		  ExpandPlayerListGui(player)

      end

  end