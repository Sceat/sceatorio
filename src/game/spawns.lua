require("src.utils.compute")

MIN_SPAWN_DIST = 50
MAX_SPAWN_DIST = 60

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

function onCreate(e)
	local player = game.players[e.player_index]
	local surface = player.surface
	game.create_force(player.name)
	player.force = player.name
	local spawn = FindUngeneratedCoordinates(MIN_SPAWN_DIST,MAX_SPAWN_DIST,surface)

	player.force.set_spawn_position(spawn, surface)

	surface.request_to_generate_chunks(spawn, 4)
	surface.force_generate_chunk_requests()

	local baseArea = getAreaAroundPos(spawn, BASE_SIZE)
	local safeZoneArea = getAreaAroundPos(spawn, SAFE_ZONE)
	local reducedZoneArea = getAreaAroundPos(spawn, WARN_ZONE)
	
	clearAliens(surface, safeZoneArea)
	reduceAliens(surface, reducedZoneArea)

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

	player.teleport(spawn, surface)
	-- tp to safe location
	-- give item
end