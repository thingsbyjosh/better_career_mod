-- bcm/parkingProtector.lua
-- Prevents ambient vanilla parked cars from invading BCM garage/facility parking
-- spots by marking nearby city.sites.json spots with customFields.tags.ignoreOthers
-- at level load. Mutates the cached sites object in memory — no disk writes.

local M = {}

local logTag = "bcm_parkingProtector"

-- ============================================================================
-- Forward declarations (required by project convention)
-- ============================================================================

local collectGarageSpots
local collectSitesSpots
local collectBcmSpots
local protectSpots
local isCitySitesFile
local onWorldReadyState

-- ============================================================================
-- Constants
-- ============================================================================

local DEFAULT_SCL = vec3(2.5, 6, 3)
local RADIUS_MIN = 4
local RADIUS_MAX = 12
local RADIUS_PADDING = 2

-- ============================================================================
-- Stubs (filled in later tasks)
-- ============================================================================

collectGarageSpots = function(levelName)
  local spots = {}
  local path = "/levels/" .. levelName .. "/garages_" .. levelName .. ".json"
  local ok, data = pcall(jsonReadFile, path)
  if not ok or type(data) ~= "table" then
    log('D', logTag, 'collectGarageSpots: no garage config at ' .. path)
    return spots
  end
  for _, garage in ipairs(data) do
    if garage and garage.parkingSpots then
      for idx, ps in ipairs(garage.parkingSpots) do
        if ps.pos and #ps.pos == 3 then
          table.insert(spots, {
            pos = vec3(ps.pos[1], ps.pos[2], ps.pos[3]),
            scl = DEFAULT_SCL,
            source = "garage:" .. tostring(garage.id) .. ":" .. tostring(idx),
          })
        end
      end
    end
  end
  log('I', logTag, string.format('collectGarageSpots: %d spots for level=%s', #spots, levelName))
  return spots
end
collectSitesSpots = function(levelName)
  local spots = {}
  local levelDir = "/levels/" .. levelName .. "/"
  local files = FS:findFiles(levelDir, "*.sites.json", -1, false, true) or {}
  for _, filePath in ipairs(files) do
    if not isCitySitesFile(filePath) then
      local sites = gameplay_sites_sitesManager.loadSites(filePath)
      if sites and sites.parkingSpots and sites.parkingSpots.sorted then
        for _, ps in ipairs(sites.parkingSpots.sorted) do
          if ps.pos then
            local scl = ps.scl
            if not scl or type(scl) ~= "cdata" then scl = DEFAULT_SCL end
            table.insert(spots, {
              pos = ps.pos,
              scl = scl,
              source = "sites:" .. filePath .. ":" .. tostring(ps.name or "?"),
            })
          end
        end
      end
    end
  end
  log('I', logTag, string.format('collectSitesSpots: %d spots for level=%s (from %d files)', #spots, levelName, #files))
  return spots
end

collectBcmSpots = function(levelName)
  local spots = {}
  for _, s in ipairs(collectGarageSpots(levelName)) do table.insert(spots, s) end
  for _, s in ipairs(collectSitesSpots(levelName)) do table.insert(spots, s) end
  return spots
end

protectSpots = function(levelName)
  local bcmSpots = collectBcmSpots(levelName)
  if #bcmSpots == 0 then
    log('D', logTag, 'protectSpots: no BCM spots for level=' .. levelName .. ', nothing to do')
    return
  end

  local citySites = gameplay_city and gameplay_city.getSites and gameplay_city.getSites()
  if not citySites or not citySites.parkingSpots or not citySites.parkingSpots.sorted then
    log('W', logTag, 'protectSpots: gameplay_city has no sites loaded for level=' .. levelName)
    return
  end

  local vanillaSpots = citySites.parkingSpots.sorted
  local blockedCount = 0
  local perBcmHits = {}  -- only populated if debugLevel > 0

  for _, bcmSpot in ipairs(bcmSpots) do
    local sclMax = math.max(bcmSpot.scl.x, bcmSpot.scl.y)
    local radius = math.min(RADIUS_MAX, math.max(RADIUS_MIN, sclMax + RADIUS_PADDING))
    local radiusSq = radius * radius
    local hits = 0

    for _, vanillaSpot in ipairs(vanillaSpots) do
      if vanillaSpot.pos and vanillaSpot.customFields and vanillaSpot.customFields.tags then
        local dx = bcmSpot.pos.x - vanillaSpot.pos.x
        local dy = bcmSpot.pos.y - vanillaSpot.pos.y
        local dz = bcmSpot.pos.z - vanillaSpot.pos.z
        if (dx * dx + dy * dy + dz * dz) < radiusSq then
          if not vanillaSpot.customFields.tags.ignoreOthers then
            vanillaSpot.customFields.tags.ignoreOthers = true
            blockedCount = blockedCount + 1
          end
          hits = hits + 1
        end
      end
    end

    if M.debugLevel > 0 then
      perBcmHits[bcmSpot.source] = { hits = hits, radius = radius }
    end
  end

  log('I', logTag, string.format(
    'Protected %d BCM spots, blocked %d vanilla city spots (level=%s, pool=%d)',
    #bcmSpots, blockedCount, levelName, #vanillaSpots
  ))

  if M.debugLevel > 0 then
    for src, info in pairs(perBcmHits) do
      log('D', logTag, string.format('  %s → %d hits (radius=%.1fm)', src, info.hits, info.radius))
    end
  end

  if blockedCount == 0 then
    log('W', logTag, 'Soft assert: bcmSpots > 0 but blockedCount == 0. Possible position drift or city.sites not loaded properly.')
  end
end

isCitySitesFile = function(path)
  return type(path) == "string" and path:match("/city%.sites%.json$") ~= nil
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

onWorldReadyState = function(state)
  if state ~= 2 then return end
  local levelName = getCurrentLevelIdentifier()
  if not levelName then
    log('W', logTag, 'onWorldReadyState: no level identifier, skipping')
    return
  end
  protectSpots(levelName)
end

M.dependencies = { "gameplay_city", "gameplay_sites_sitesManager" }
M.debugLevel = 0
M.onWorldReadyState = onWorldReadyState

return M
