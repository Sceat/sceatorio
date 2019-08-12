CHUNK_SIZE = 32

function distanceSqrt( x1, y1, x2, y2 )
	return (x2-x1)^2 + (y2-y1)^2
end

-- Get an area given a position and distance.
-- Square length = 2x distance
function getAreaAroundPos(pos, dist)

    return {left_top=
                    {x=pos.x-dist,
                     y=pos.y-dist},
            right_bottom=
                    {x=pos.x+dist,
                     y=pos.y+dist}}
end

-- Check for ungenerated chunks around a specific chunk
-- +/- chunkDist in x and y directions
function IsChunkAreaUngenerated(chunkPos, chunkDist, surface)
    for x=-chunkDist, chunkDist do
        for y=-chunkDist, chunkDist do
            local checkPos = {x=chunkPos.x+x,
                             y=chunkPos.y+y}
            if (surface.is_chunk_generated(checkPos)) then
                return false
            end
        end
    end
    return true
end

function RandomNegPos()
    if (math.random(0,1) == 1) then
        return 1
    else
        return -1
    end
end

-- Find random coordinates within a given distance away
-- maxTries is the recursion limit basically.
function FindUngeneratedCoordinates(minDistChunks, maxDistChunks, surface)
    local position = {x=0,y=0}
    local chunkPos = {x=0,y=0}

    local maxTries = 100
    local tryCounter = 0

    local minDistSqr = minDistChunks^2
    local maxDistSqr = maxDistChunks^2

    while(true) do
        chunkPos.x = math.random(0,maxDistChunks) * RandomNegPos()
        chunkPos.y = math.random(0,maxDistChunks) * RandomNegPos()

        local distSqrd = chunkPos.x^2 + chunkPos.y^2

        -- Enforce a max number of tries
        tryCounter = tryCounter + 1
        if (tryCounter > maxTries) then
            break
 
        -- Check that the distance is within the min,max specified
        elseif ((distSqrd < minDistSqr) or (distSqrd > maxDistSqr)) then
            -- Keep searching!
        
        -- Check there are no generated chunks in a 10x10 area.
        elseif IsChunkAreaUngenerated(chunkPos, 6, surface) then
            position.x = (chunkPos.x*CHUNK_SIZE) + (CHUNK_SIZE/2)
            position.y = (chunkPos.y*CHUNK_SIZE) + (CHUNK_SIZE/2)
            break -- SUCCESS
        end       
    end

    return position
end

function RemoveInCircle(surface, area, type, pos, dist)
    for key, entity in pairs(surface.find_entities_filtered({area=area, type= type})) do
        if entity.valid and entity and entity.position then
            if ((pos.x - entity.position.x)^2 + (pos.y - entity.position.y)^2 < dist^2) then
                entity.destroy()
            end
        end
    end
end

-- COPIED FROM jvmguy!
-- Enforce a square of land, with a tree border
-- this is equivalent to the CreateCropCircle code
function cropBorder(surface, centerPos, chunkArea, tileRadius,tile)

    local dirtTiles = {}
    for i=chunkArea.left_top.x,chunkArea.right_bottom.x,1 do
        for j=chunkArea.left_top.y,chunkArea.right_bottom.y,1 do

            local distVar1 = math.floor(math.max(math.abs(centerPos.x - i), math.abs(centerPos.y - j)))
            local distVar2 = math.floor(math.abs(centerPos.x - i) + math.abs(centerPos.y - j))
            local distVar = math.max(distVar1*1.1, distVar2 * 0.707*1.1);

            -- Fill in all unexpected water in a circle
            if (distVar < tileRadius+2) then
                table.insert(dirtTiles, {name = tile, position ={i,j}})
            end

            -- Create a tree ring
            if ((distVar < tileRadius) and 
                (distVar > tileRadius-10)) then
                surface.create_entity({name="tree-snow-a", amount=1, position={i, j}})
            end
        end
    end    
    surface.set_tiles(dirtTiles)
end

-- Add a circle of water
function waterBorder(surface, centerPos, chunkArea, tileRadius,modifier)

    local tileRadSqr = tileRadius^2

    local waterTiles = {}
    for i=chunkArea.left_top.x,chunkArea.right_bottom.x,1 do
        for j=chunkArea.left_top.y,chunkArea.right_bottom.y,1 do

            -- This ( X^2 + Y^2 ) is used to calculate if something
            -- is inside a circle area.
            local distVar = math.floor((centerPos.x - i)^2 + (centerPos.y - j)^2)

            -- Create a circle of water
            if ((distVar < tileRadSqr+modifier) and 
                (distVar > tileRadSqr)) then
                table.insert(waterTiles, {name = "water", position ={i,j}})
            end
        end
    end

    surface.set_tiles(waterTiles)
end

-- Function to generate a resource patch, of a certain size/amount at a pos.
function GenerateResourcePatch(surface, resourceName, diameter, pos, amount)
    local midPoint = math.floor(diameter/2)
    if (diameter == 0) then
        return
    end
    for y=0, diameter do
        for x=0, diameter do
            surface.create_entity({name=resourceName, amount=amount,
                position={pos.x+x, pos.y+y}})
        end
    end
end

function CreateWaterStrip(surface, leftPos, length)
    local waterTiles = {}
    for i=0,length,1 do
        table.insert(waterTiles, {name = "water", position={leftPos.x+i,leftPos.y}})
    end
    surface.set_tiles(waterTiles)
end 