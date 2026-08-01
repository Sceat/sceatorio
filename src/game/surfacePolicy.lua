local SurfacePolicy = {}

-- Surface associations are engine-owned runtime properties. Read them through
-- one guarded policy so Base-only games, platforms, and mod-created surfaces
-- all take the same conservative path.
function SurfacePolicy.planet(surface)
  if not (surface and surface.valid) then return nil end
  local ok, planet = pcall(function() return surface.planet end)
  return ok and planet or nil
end

function SurfacePolicy.platform(surface)
  if not (surface and surface.valid) then return nil end
  local ok, platform = pcall(function() return surface.platform end)
  return ok and platform or nil
end

function SurfacePolicy.is_real_planet(surface)
  return surface ~= nil
    and surface.valid
    and SurfacePolicy.platform(surface) == nil
    and SurfacePolicy.planet(surface) ~= nil
end

-- Sceatorio partitions only the built-in conventional hostile ecosystems.
-- A similarly named custom surface has no LuaPlanet association and therefore
-- cannot be claimed by the per-team enemy geometry.
function SurfacePolicy.is_native_hostile_surface(surface)
  if not SurfacePolicy.is_real_planet(surface) then return false end
  local planet = SurfacePolicy.planet(surface)
  return planet.name == "nauvis" or planet.name == "gleba"
end

return SurfacePolicy
