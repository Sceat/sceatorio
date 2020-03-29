require("src.utils.compute")
require('src.utils.msg')

MIN_SPAWN_DIST = 50
MAX_SPAWN_DIST = 110

BASE_SIZE = 90
SAFE_ZONE = 220
WARN_ZONE = 400

WATER_MODIFIER = 3000

TILE_NAME = 'sand-1'

global.spawns = {}
table.insert(global.spawns, {x=0,y=0})

function clearAliens(surface, area)
    for _, entity in pairs(surface.find_entities_filtered{area = area, force = "enemy"}) do
        entity.destroy()
    end
end

function reduceAliens(surface, area)
    for _, entity in pairs(surface.find_entities_filtered{area = area, force = "enemy"}) do
        if (math.random(10,30) < 18) then
            entity.destroy()
        end
	end
end

START_IRON_AMOUNT = 1500
START_COPPER_AMOUNT = 1500
START_STONE_AMOUNT = 1000
START_COAL_AMOUNT = 1500
START_URANIUM_AMOUNT = 1000
START_OIL_AMOUNT = 300000

START_RESOURCE_STONE_POS_X = -55
START_RESOURCE_STONE_POS_Y = 25
START_RESOURCE_STONE_SIZE = 15

START_RESOURCE_COAL_POS_X = -30
START_RESOURCE_COAL_POS_Y = 25
START_RESOURCE_COAL_SIZE = 15

START_RESOURCE_COPPER_POS_X = -5
START_RESOURCE_COPPER_POS_Y = 25
START_RESOURCE_COPPER_SIZE = 15

START_RESOURCE_IRON_POS_X = 20
START_RESOURCE_IRON_POS_Y = 25
START_RESOURCE_IRON_SIZE = 15

START_RESOURCE_URANIUM_POS_X = 45
START_RESOURCE_URANIUM_POS_Y = 25
START_RESOURCE_URANIUM_SIZE = 15

-- Specify 2 oil spot locations for starting oil.
START_RESOURCE_OIL_NUM_PATCHES = 4
-- The first patch
START_RESOURCE_OIL_POS_X = 15
START_RESOURCE_OIL_POS_Y = 60
-- How far each patch is offset from the others and in which direction
-- Default (x=0, y=-4) means that patches spawn in a vertical row downwards.
START_RESOURCE_OIL_X_OFFSET = -5
START_RESOURCE_OIL_Y_OFFSET = 0

WATER_SPAWN_OFFSET_X = -10
WATER_SPAWN_OFFSET_Y = -50
WATER_SPAWN_LENGTH = 20

BASE_SPAWN = {x=0,y=0}
SPAWN_SIZE = 20

function onInit()
	local surface = game.surfaces['nauvis']
	local baseSpawnArea = getAreaAroundPos(BASE_SPAWN, SPAWN_SIZE)
	local safeZoneArea = getAreaAroundPos(BASE_SPAWN, SPAWN_SIZE*2)

	game.create_force('lobby')
	game.forces['lobby'].set_spawn_position(BASE_SPAWN, surface)

	surface.request_to_generate_chunks({0,0}, 4)
	createTerrain(surface, BASE_SPAWN, baseSpawnArea, SPAWN_SIZE, 'tutorial-grid')
	surface.destroy_decoratives(baseSpawnArea)
	waterBorder(surface, BASE_SPAWN, safeZoneArea, SPAWN_SIZE, WATER_MODIFIER)
	clearAliens(surface, getAreaAroundPos(BASE_SPAWN, 200))

	RemoveInCircle(surface, baseSpawnArea, "tree", BASE_SPAWN, SPAWN_SIZE+5)
	RemoveInCircle(surface, baseSpawnArea, "resource", BASE_SPAWN, SPAWN_SIZE+5)
	RemoveInCircle(surface, baseSpawnArea, "cliff", BASE_SPAWN, SPAWN_SIZE+5)
end

function showSpawnGui(player)
	if(player.gui.center.spawn_gui ~= nil) then
		player.gui.center.spawn_gui.destroy()
	end
	local widget = player.gui.center.add({type="frame",direction="vertical",name="spawn_gui"})
	widget.add({type="label",caption="Welcome young adventurer, your story start here"})
	widget.add({type="label",caption=" "})
	widget.add({type="label",caption="You can spawn alone"})
	widget.add({type="button",name="spawn_alone",caption="Create a new Empire"})
	widget.add({type="label",caption=" "})
	local widgetInner = widget.add({type="frame",direction="horizontal"})
	widgetInner.add({type="label",caption="or ask someone to join his Factory"})
	widgetInner.add({type="label",caption=" "})
	for _,p in pairs(game.connected_players) do
		if(p.force.name ~= 'lobby') then
			widgetInner.add({type="button",name=("joinMate="..(p.name)),caption=("team up with "..(p.name))})
		end
	end
end

function onCreate(e)
	local player = game.players[e.player_index]
	local surface = player.surface
	player.force = 'lobby'
	player.teleport(BASE_SPAWN, surface)
	say((player.name).." just spawned!")
	showSpawnGui(player)
end

function askToJoin(player, playerAsking)
	local widget = player.gui.center.add({type="frame",direction="vertical",name="askToJoin"})
	widget.add({type="label",caption=((playerAsking.name.." wants to join you"))})
	local widgetInner = widget.add({type="frame",direction="horizontal"})
	widgetInner.add({type="button",caption="accept",name=("acceptJoinRequest="..(playerAsking.name))})
	widgetInner.add({type="button",caption="refuse",name=("refuseJoinRequest="..(playerAsking.name))})
end

function joinMate(player, playerToJoin)
	player.force = playerToJoin.name
	player.teleport(player.force.get_spawn_position(player.surface), player.surface)
	say((player.name).." joined "..(playerToJoin.name).."'s team!")
end

function setAlly(f1, f2)
	f1.set_cease_fire(f2, true)
	f1.set_friend(f2, true)
	f2.set_cease_fire(f1, true)
	f2.set_friend(f1, true)
end

function distance ( x1, y1, x2, y2 )
  local dx = x1 - x2
  local dy = y1 - y2
  return math.sqrt ( dx * dx + dy * dy )
end

function findNearestForce(position)
	local surface = game.surfaces.nauvis
	local min_distance = nil
	local nearest_force = nil
	for _,force in pairs(game.forces) do
		if(force.name ~= 'enemy') and (force.name ~= "neutral") and (force.name ~= "lobby") and (force.name ~= "player") then
			local f1keys = {}
			for k, v in string.gmatch(force.name, "(%w+)=(%w+)") do
				f1keys[k]=v
			end
			if(f1keys.enemy == nil) then
				local spawn = force.get_spawn_position(surface)
				local dist = distance(position.x,position.y,spawn.x,spawn.y)
				if(min_distance == nil) or (min_distance > dist) then
					min_distance = dist
					nearest_force = force
				end
			end
		end
	end
	return {force=nearest_force,dist=min_distance}
end

function onChunkGen(e)
	for _,entity in pairs(game.surfaces.nauvis.find_entities_filtered({force='enemy',area=e.area})) do
		local nearest = findNearestForce(entity.position)
		if(nearest.force ~= nil) then
			entity.force = ('enemy='..(nearest.force.name))
			if(nearest.dist < 220) then
				entity.destroy()
			elseif (nearest.dist < 500) and (math.random(0,100) <= 70) then
				entity.destroy()
			end
		end
	end
end

function createPlayerEnemyForce(player)
	local force_name = ('enemy='..(player.name))
	game.create_force(force_name)
	local force = game.forces[force_name]
	force.ai_controllable = true

	local enemyForce = game.forces.enemy
	setAlly(force, enemyForce)

	for _,f1 in pairs(game.forces) do
		for _,f2 in pairs(game.forces) do
			if(f1.name ~= f2.name) then
				local f1keys = {}
				local f2keys = {}
				for k, v in string.gmatch(f1.name, "(%w+)=(%w+)") do
					f1keys[k]=v
				end
				for k, v in string.gmatch(f2.name, "(%w+)=(%w+)") do
					f2keys[k]=v
				end
				if(f1keys.enemy ~= nil) and (f2keys.enemy ~= nil) then
					setAlly(f1,f2)
				end
			end
		end
	end
end

function tablelength(T)
  local count = 0
  for _ in pairs(T) do count = count + 1 end
  return count
end

function generatePlayerSpawn(player)
	local surface = player.surface
	local spawn = FindUngeneratedCoordinates(MIN_SPAWN_DIST,MAX_SPAWN_DIST,surface)
	if (spawn.x == 0) then
		say("there is no more place to create a spawn for "..player.name.." ! join someone or get lost.")
		return false
	elseif tablelength(game.forces) > 62 then
		say("there can't be more than 30 players due to the factorio force amount limitation! "..player.name.." has to join a team")
		return false
	else
		say((player.name).." just created a new Empire! creating terrain.. (wait a few sec)")
		game.create_force(player.name)
		player.force = player.name
		createPlayerEnemyForce(player)
		player.force.set_spawn_position(spawn, surface)
		surface.request_to_generate_chunks(spawn, 3)
		if global.tp == nil then
			global.tp = {}
		end
		table.insert(global.tp, {player=player,spawn=spawn,time=5,time_chunk=2})
		player.print('you will be teleported to your spawn in 5s')
	end
	return true
end

function spawnAlone(player, spawn)
	local surface = player.surface
	local baseArea = getAreaAroundPos(spawn, BASE_SIZE)
	local safeZoneArea = getAreaAroundPos(spawn, SAFE_ZONE)
	RemoveInCircle(surface, baseArea, "tree", spawn, BASE_SIZE+5)
	RemoveInCircle(surface, baseArea, "resource", spawn, BASE_SIZE+5)
	RemoveInCircle(surface, baseArea, "cliff", spawn, BASE_SIZE+5)
	surface.destroy_decoratives(baseArea)
	cropBorder(surface, spawn, baseArea, BASE_SIZE,TILE_NAME)
	waterBorder(surface, spawn, safeZoneArea, BASE_SIZE,WATER_MODIFIER)

	  -- Generate stone
    local stonePos = {x=spawn.x+START_RESOURCE_STONE_POS_X,
                  y=spawn.y+START_RESOURCE_STONE_POS_Y}

    -- Generate coal
    local coalPos = {x=spawn.x+START_RESOURCE_COAL_POS_X,
                  y=spawn.y+START_RESOURCE_COAL_POS_Y}

    -- Generate copper ore
    local copperOrePos = {x=spawn.x+START_RESOURCE_COPPER_POS_X,
                  y=spawn.y+START_RESOURCE_COPPER_POS_Y}

    -- Generate iron ore
    local ironOrePos = {x=spawn.x+START_RESOURCE_IRON_POS_X,
                  y=spawn.y+START_RESOURCE_IRON_POS_Y}

    -- Generate uranium
    local uraniumOrePos = {x=spawn.x+START_RESOURCE_URANIUM_POS_X,
                  y=spawn.y+START_RESOURCE_URANIUM_POS_Y}

    -- Tree generation is taken care of in chunk generation

    -- Generate oil patches
    oil_patch_x=spawn.x+START_RESOURCE_OIL_POS_X
    oil_patch_y=spawn.y+START_RESOURCE_OIL_POS_Y
    for i=1,START_RESOURCE_OIL_NUM_PATCHES do
        surface.create_entity({name="crude-oil", amount=START_OIL_AMOUNT,
                    position={oil_patch_x, oil_patch_y}})
        oil_patch_x=oil_patch_x+START_RESOURCE_OIL_X_OFFSET
        oil_patch_y=oil_patch_y+START_RESOURCE_OIL_Y_OFFSET
    end

	-- Generate Stone
	GenerateResourcePatch(surface, "stone", START_RESOURCE_STONE_SIZE, stonePos, START_STONE_AMOUNT)

	-- Generate Coal
	GenerateResourcePatch(surface, "coal", START_RESOURCE_COAL_SIZE, coalPos, START_COAL_AMOUNT)

	-- Generate Copper
	GenerateResourcePatch(surface, "copper-ore", START_RESOURCE_COPPER_SIZE, copperOrePos, START_COPPER_AMOUNT)

	-- Generate Iron
	GenerateResourcePatch(surface, "iron-ore", START_RESOURCE_IRON_SIZE, ironOrePos, START_IRON_AMOUNT)

	-- Generate Uranium
	GenerateResourcePatch(surface, "uranium-ore", START_RESOURCE_URANIUM_SIZE, uraniumOrePos, START_URANIUM_AMOUNT)

	CreateWaterStrip(surface, {x=spawn.x+WATER_SPAWN_OFFSET_X, y=spawn.y+WATER_SPAWN_OFFSET_Y}, WATER_SPAWN_LENGTH)
	CreateWaterStrip(surface, {x=spawn.x+WATER_SPAWN_OFFSET_X, y=spawn.y+WATER_SPAWN_OFFSET_Y+1}, WATER_SPAWN_LENGTH)
	CreateWaterStrip(surface, {x=spawn.x+WATER_SPAWN_OFFSET_X, y=spawn.y+WATER_SPAWN_OFFSET_Y+2}, WATER_SPAWN_LENGTH)
	CreateWaterStrip(surface, {x=spawn.x+WATER_SPAWN_OFFSET_X, y=spawn.y+WATER_SPAWN_OFFSET_Y+3}, WATER_SPAWN_LENGTH)
	CreateWaterStrip(surface, {x=spawn.x+WATER_SPAWN_OFFSET_X, y=spawn.y+WATER_SPAWN_OFFSET_Y+4}, WATER_SPAWN_LENGTH)
end

function onButtonClick(event)
	local player = game.players[event.element.player_index]
	local name = event.element.name
	if (name == "spawn_alone") then
		local could_find_a_spawn = generatePlayerSpawn(player)
		if(could_find_a_spawn) then
			player.gui.center.spawn_gui.destroy()
		end
	else
		local splitted = {}
		for k, v in string.gmatch(name, "(%w+)=(%w+)") do
			splitted[k]=v
		end
		if(splitted.acceptJoinRequest ~= nil) then
			local playerJoining = game.players[splitted.acceptJoinRequest]
			player.gui.center.askToJoin.destroy()
			joinMate(playerJoining, player)
			say((playerJoining.name).." joined "..(player.name))
		elseif(splitted.refuseJoinRequest ~= nill) then
			local playerJoining = game.players[splitted.refuseJoinRequest]
			player.gui.center.askToJoin.destroy()
			if(playerJoining.connected) then
				playerJoining.print((player.name).." refused to let you join")
				showSpawnGui(playerJoining)
			end
		elseif(splitted.joinMate ~= nil) then
			local playerToJoin = game.players[splitted.joinMate]
			if(playerToJoin ~= nil and playerToJoin.connected) then
				say((player.name).." wants to join "..(event.element.caption))
				askToJoin(playerToJoin, player)
				player.gui.center.spawn_gui.destroy()
			else
				player.print((playerToJoin.name).." is offline")
			end
		end
	end
end