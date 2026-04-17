-- BCM Garages Extension
-- Feature layer module: bridges bcm_properties (data layer) with vanilla garage facility system.
-- Responsibilities: JSON config loading, vanilla sync via addPurchasedGarage,
-- capacity/tier query APIs, starter garage grant, and dev discovery command.
-- Addresses: PROP-06 (vanilla sync).

local M = {}

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
local loadGarageConfig
local syncAllPurchasedGaragesWithVanilla
local syncGarageWithVanilla
local purchaseBcmGarage
local getCurrentCapacity
local getSlotUpgradePrice
local canUpgradeCapacity
local getGarageDefinition
local getAllDefinitions
local getGarageDisplayName
local getVehiclesInGarage
local getFreeSlots
local getGarageCount
local grantStarterGarageIfNeeded
local grantBackupGaragesIfNeeded
local isBackupGarage
local onCareerModulesActivated
local discoverAllGarages
local isPositionInOwnedGarage
local getOwnedGaragesOnCurrentMap
local getGaragesForMap
local isOvercapacity
local getMapDisplayName
local resolveTravelDestGarage

-- ============================================================================
-- Private state
-- ============================================================================

-- BCM garage definitions keyed by garageId, loaded from JSON at activation time
local bcmGarageConfig = {}

-- Guard flag — prevents double-loading
local configLoaded = false

-- ============================================================================
-- Config loading
-- ============================================================================

-- Load BCM garage definitions from the level-specific JSON config file.
-- Called once per career activation. Config is NOT loaded at extension load time.
loadGarageConfig = function()
  local levelName = getCurrentLevelIdentifier()
  if not levelName then
    log('W', 'bcm_garages', 'loadGarageConfig: getCurrentLevelIdentifier() returned nil — skipping config load')
    return
  end

  local configPath = "/levels/" .. levelName .. "/garages_" .. levelName .. ".json"
  local data = jsonReadFile(configPath)

  if not data then
    log('W', 'bcm_garages', 'loadGarageConfig: No garage config found at: ' .. configPath)
    return
  end

  -- data is expected to be an array of garage definition objects
  bcmGarageConfig = {}
  if type(data) == "table" then
    for _, garageDef in ipairs(data) do
      if garageDef and garageDef.id then
        bcmGarageConfig[garageDef.id] = garageDef
      end
    end
  end

  configLoaded = true

  local count = 0
  for _ in pairs(bcmGarageConfig) do
    count = count + 1
  end
  log('I', 'bcm_garages', 'loadGarageConfig: Loaded ' .. count .. ' garage definitions from ' .. configPath)
end

-- ============================================================================
-- Vanilla sync (PROP-06)
-- ============================================================================

-- Register a single BCM garage with vanilla's garageManager using check-first pattern.
-- The check prevents double side effects (welcome splash, duplicate recovery buttons).
syncGarageWithVanilla = function(garageId)
  if not career_modules_garageManager then
    log('D', 'bcm_garages', 'syncGarageWithVanilla: career_modules_garageManager not available, skipping sync for ' .. tostring(garageId))
    return
  end

  -- Check-first: only call addPurchasedGarage if not already registered
  if not career_modules_garageManager.isPurchasedGarage(garageId) then
    career_modules_garageManager.addPurchasedGarage(garageId)
    log('D', 'bcm_garages', 'syncGarageWithVanilla: Registered ' .. tostring(garageId) .. ' with vanilla garageManager')
  end
end

-- Sync all BCM-owned garages with vanilla on career load.
-- Idempotent: check-first pattern in syncGarageWithVanilla prevents double registration.
syncAllPurchasedGaragesWithVanilla = function()
  if not bcm_properties then
    log('W', 'bcm_garages', 'syncAllPurchasedGaragesWithVanilla: bcm_properties not available')
    return
  end

  local ownedProperties = bcm_properties.getAllOwnedProperties() or {}
  local syncCount = 0

  for _, property in ipairs(ownedProperties) do
    if property.type == "garage" or property.type == "backup" then
      syncGarageWithVanilla(property.id)
      syncCount = syncCount + 1
    end
  end

  -- Phase 102 (W-1): also sync type="rental" shells whose sourceMapName matches the
  -- current level. These are non-backup paid rentals (Plan 03 hybrid data model,
  -- Pitfall 6). Without this second pass, a rented non-backup garage would never
  -- register with vanilla on the target map and the player could not enter it on
  -- arrival. We do NOT count these toward the owned-garage count — property tax
  -- stays scoped to type=="garage" records only.
  local currentMap = nil
  if getCurrentLevelIdentifier then
    currentMap = getCurrentLevelIdentifier()
  end
  local rentalSyncCount = 0
  for _, property in ipairs(ownedProperties) do
    if property.type == "rental" then
      local belongsHere = true
      if currentMap and bcm_rentals and bcm_rentals.getActiveRental then
        local rental = bcm_rentals.getActiveRental(property.id)
        if rental and rental.sourceMapName and rental.sourceMapName ~= currentMap then
          belongsHere = false
        end
      end
      if belongsHere then
        syncGarageWithVanilla(property.id)
        rentalSyncCount = rentalSyncCount + 1
      end
    end
  end

  log('I', 'bcm_garages', 'syncAllPurchasedGaragesWithVanilla: Synced ' .. syncCount .. ' owned garages with vanilla (+ ' .. rentalSyncCount .. ' rental shells)')
end

-- ============================================================================
-- Purchase flow
-- ============================================================================

-- Purchase a BCM garage: creates ownership record via bcm_properties and registers with vanilla.
-- garageId: string matching a bcmGarageConfig key
-- Returns the property record on success, nil on failure.
purchaseBcmGarage = function(garageId)
  -- Guard: config must exist for this garage
  local definition = bcmGarageConfig[garageId]
  if not definition then
    log('W', 'bcm_garages', 'purchaseBcmGarage: No config found for garageId: ' .. tostring(garageId))
    return nil
  end

  -- Guard: must not already own it
  if bcm_properties and bcm_properties.isOwned(garageId) then
    log('W', 'bcm_garages', 'purchaseBcmGarage: Already owned: ' .. tostring(garageId))
    return nil
  end

  if not bcm_properties then
    log('E', 'bcm_garages', 'purchaseBcmGarage: bcm_properties not available')
    return nil
  end

  -- Create data record via the properties data layer
  local propType = definition.isBackupGarage and "backup" or "garage"
  local record = bcm_properties.purchaseProperty(garageId, propType, definition.baseCapacity)

  -- Register with vanilla so towing/recovery recognizes the garage
  syncGarageWithVanilla(garageId)

  log('I', 'bcm_garages', 'purchaseBcmGarage: Purchased garage: ' .. garageId .. ' (capacity=' .. tostring(definition.baseCapacity) .. ')')
  return record
end

-- ============================================================================
-- Query APIs
-- ============================================================================

-- Returns the current vehicle slot capacity for an owned garage.
getCurrentCapacity = function(garageId)
  if not bcm_properties then return 0 end
  local record = bcm_properties.getOwnedProperty(garageId)
  if not record then return 0 end
  return record.currentCapacity or 0
end

-- Returns the price to purchase one more capacity slot for an owned garage.
-- Formula: basePrice * multiplier ^ (currentCapacity - baseCapacity)
getSlotUpgradePrice = function(garageId)
  local definition = bcmGarageConfig[garageId]
  if not definition then return nil end

  if not bcm_properties then return nil end
  local record = bcm_properties.getOwnedProperty(garageId)
  if not record then return nil end

  local exponent = record.currentCapacity - definition.baseCapacity
  local price = definition.slotUpgradeBasePrice * (definition.slotUpgradeMultiplier ^ exponent)
  return math.floor(price)
end

-- Returns true if the garage can still have its capacity upgraded (below maxCapacity).
canUpgradeCapacity = function(garageId)
  if not bcm_properties then return false end
  if not bcm_properties.isOwned(garageId) then return false end

  local definition = bcmGarageConfig[garageId]
  if not definition then return false end

  local record = bcm_properties.getOwnedProperty(garageId)
  if not record then return false end

  return record.currentCapacity < definition.maxCapacity
end

-- Returns the garage definition table from config, or nil if not found.
getGarageDefinition = function(garageId)
  return bcmGarageConfig[garageId]
end

-- Returns the full bcmGarageConfig table (read-only intent — Lua does not enforce this).
getAllDefinitions = function()
  return bcmGarageConfig
end

-- Returns the display name for a garage.
-- Prefers the player's custom name; falls back to definition name; then garageId.
getGarageDisplayName = function(garageId)
  if bcm_properties then
    local record = bcm_properties.getOwnedProperty(garageId)
    if record and record.customName and record.customName ~= "" then
      return record.customName
    end
  end

  -- Try current map's loaded config first (fast path)
  local definition = bcmGarageConfig[garageId]
  if definition and definition.name then
    return definition.name
  end

  -- Cross-map fallback: search discovered maps' garage JSONs.
  -- This covers Italy garages when the player is on WCUSA etc.
  if bcm_multimapApp and bcm_multimapApp.getGaragesForMap
     and bcm_multimap and bcm_multimap.getDiscoveredMaps then
    for mapName in pairs(bcm_multimap.getDiscoveredMaps() or {}) do
      local defs = bcm_multimapApp.getGaragesForMap(mapName) or {}
      for _, g in ipairs(defs) do
        if g.id == garageId and g.name then return g.name end
      end
    end
  end

  return garageId
end

-- Returns an array of vehicleInventoryIds assigned to the given garage.
-- Reads vehicle.location directly from career inventory (single source of truth).
-- Excludes non-owned vehicles (loaners) — they don't occupy garage slots.
getVehiclesInGarage = function(garageId)
  local result = {}
  local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles()
  if not vehicles then return result end
  local garageIdStr = tostring(garageId)
  for invId, vehInfo in pairs(vehicles) do
    if vehInfo.owned ~= false and vehInfo.location and tostring(vehInfo.location) == garageIdStr then
      table.insert(result, tostring(invId))
    end
  end
  return result
end

-- Returns the number of free vehicle slots in a garage.
-- Clamped to 0 (Phase 102 Pitfall 5): a soft-lockout overflow (vehicles > capacity)
-- must report zero free slots, not a negative, so downstream "can I store one more?"
-- checks behave correctly. Use isOvercapacity() to detect overflow explicitly.
getFreeSlots = function(garageId)
  local capacity = getCurrentCapacity(garageId)
  local vehicles = getVehiclesInGarage(garageId)
  return math.max(0, capacity - #vehicles)
end

-- Returns true if the given owned garage has more vehicles stored than its current
-- capacity (Phase 102 soft-lockout signal). The UI layer uses this to render the
-- "storage locked — free a slot" banner when rental eviction overflows the backup.
isOvercapacity = function(garageId)
  if not garageId then return false end
  local capacity = getCurrentCapacity(garageId)
  if capacity <= 0 then return false end
  local vehicles = getVehiclesInGarage(garageId)
  return #vehicles > capacity
end

-- ============================================================================
-- Cross-map garage definition feed (Phase 102 — Pitfall 3 mitigation)
-- ============================================================================
-- Reads the target map's garages_<mapName>.json directly without touching the
-- bcmGarageConfig global state. Mirrors bcm/multimapApp.lua getGaragesForMap so
-- every cross-map consumer (Belasco Realty filter, rentals module, destination
-- picker) sees the same shape. NEVER call loadGarageConfig here — that helper is
-- hardcoded to getCurrentLevelIdentifier() and would clobber the in-memory config.
getGaragesForMap = function(mapName)
  local garages = {}
  if not mapName then return garages end
  local path = "/levels/" .. mapName .. "/garages_" .. mapName .. ".json"
  local ok, data = pcall(jsonReadFile, path)
  if not ok or not data then return garages end
  for _, g in ipairs(data) do
    if g and g.id then
      table.insert(garages, {
        id = g.id,
        name = g.name or g.id,
        basePrice = g.basePrice,
        baseCapacity = g.baseCapacity,
        maxCapacity = g.maxCapacity,
        tier = g.tier,
        isBackupGarage = g.isBackupGarage == true,
        isStarterGarage = g.isStarterGarage == true,
        mapName = mapName,
      })
    end
  end
  return garages
end

-- Check if a world position is inside any owned garage area.
-- Uses zoneVertices (2D point-in-polygon) if available, else center + 200m radius fallback.
-- Returns garageId if inside, nil otherwise.
isPositionInOwnedGarage = function(pos)
  if not bcm_properties or not pos then return nil end
  local ownedProperties = bcm_properties.getAllOwnedProperties() or {}
  local px = pos.x or pos[1] or 0
  local py = pos.y or pos[2] or 0

  for _, property in ipairs(ownedProperties) do
    if property.type == "garage" or property.type == "backup" then
      local def = bcmGarageConfig[property.id]
      if def then
        -- Try zone polygon (2D point-in-polygon, ignore Z)
        local verts = def.zoneVertices
        if verts and #verts >= 3 then
          local inside = false
          local n = #verts
          local j = n
          for i = 1, n do
            local xi = verts[i][1] or 0
            local yi = verts[i][2] or 0
            local xj = verts[j][1] or 0
            local yj = verts[j][2] or 0
            if ((yi > py) ~= (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then
              inside = not inside
            end
            j = i
          end
          if inside then return property.id end
        elseif def.center then
          -- Fallback: 200m radius from center
          local cx = def.center[1] or 0
          local cy = def.center[2] or 0
          local dx = px - cx
          local dy = py - cy
          if (dx * dx + dy * dy) < (200 * 200) then
            return property.id
          end
        end
      end
    end
  end
  return nil
end

-- Returns the count of BCM-owned garages (type == "garage").
getGarageCount = function()
  if not bcm_properties then return 0 end
  local ownedProperties = bcm_properties.getAllOwnedProperties() or {}
  local count = 0
  for _, property in ipairs(ownedProperties) do
    if property.type == "garage" then
      count = count + 1
    end
  end
  return count
end

-- ============================================================================
-- Starter garage
-- ============================================================================

-- Grant the starter garage if the player has no BCM garages yet.
-- Idempotent: returns immediately if the player already owns any garage.
-- This converts the starter garage system into a BCM-owned garage on first career load.
grantStarterGarageIfNeeded = function()
  if getGarageCount() > 0 then
    log('D', 'bcm_garages', 'grantStarterGarageIfNeeded: Player already has garages — skipping')
    return
  end

  -- Find the garage marked as starter in config
  local starterId = nil
  for garageId, definition in pairs(bcmGarageConfig) do
    if definition.isStarterGarage == true then
      starterId = garageId
      break
    end
  end

  if starterId then
    purchaseBcmGarage(starterId)
    log('I', 'bcm_garages', 'grantStarterGarageIfNeeded: Starter garage granted: ' .. starterId)
  else
    log('W', 'bcm_garages', 'grantStarterGarageIfNeeded: No starter garage found in config')
  end
end

-- ============================================================================
-- Backup garages
-- ============================================================================

-- Auto-grant backup garages on the current map. Backup garages are free temporary
-- lodging that gives the player a spawn point and computer access on maps without
-- owned garages. Tuning, parts orders, and vehicle sales are blocked (Phase 102
-- adds paid rental with full features).
grantBackupGaragesIfNeeded = function()
  -- Guard early: if the properties module is unavailable the entire loop is
  -- meaningless because purchaseBcmGarage will also bail out silently. Log a
  -- warning and return rather than iterating and emitting misleading "auto-granted"
  -- messages for purchases that never actually happened.
  if not bcm_properties then
    log('W', 'bcm_garages', 'grantBackupGaragesIfNeeded: bcm_properties not available, skipping')
    return
  end
  for garageId, definition in pairs(bcmGarageConfig) do
    if definition.isBackupGarage == true and not bcm_properties.isOwned(garageId) then
      -- Use purchaseBcmGarage which creates ownership + syncs with vanilla
      purchaseBcmGarage(garageId)
      log('I', 'bcm_garages', 'Backup garage auto-granted: ' .. garageId)
    end
  end
end

-- Returns true if the garage definition has isBackupGarage flag set.
-- Used by UI to block tuning/parts/sales in backup garages.
isBackupGarage = function(garageId)
  local definition = bcmGarageConfig[garageId]
  if not definition then return false end
  return definition.isBackupGarage == true
end

-- ============================================================================
-- Per-map owned garages query
-- ============================================================================

-- Returns an array of {id, displayName, isStarterGarage, isBackupGarage} entries for
-- every BCM garage that is (a) owned by the player and (b) physically located
-- on the given level. Filtering is done via the garage definition's `mapName`
-- field (every BCM garage JSON carries it), with a file-path fallback if a
-- hypothetical future config omits mapName. Sorted alphabetically by display
-- name. Keeps the selector UI (Plan 03) and the recoveryPrompt taxi override
-- on the same source of truth so "owned here" always means the same thing.
-- Parameters:
--   levelId  string|nil  Optional level id. Defaults to the current level.
-- Returns:
--   array    May be empty — never nil — even in bootstrap edge cases.
getOwnedGaragesOnCurrentMap = function(levelId)
  levelId = levelId or (getCurrentLevelIdentifier and getCurrentLevelIdentifier()) or nil
  if not levelId or levelId == "" then
    log('W', 'bcm_garages', 'getOwnedGaragesOnCurrentMap: no level identifier available')
    return {}
  end

  local result = {}
  local defs = bcmGarageConfig or {}
  if not bcm_properties or not bcm_properties.getAllOwnedProperties then
    return result
  end

  local owned = bcm_properties.getAllOwnedProperties() or {}
  local ownedSet = {}    -- id → 'owned' | 'rental' | 'backup'
  for _, p in ipairs(owned) do
    if p and p.id then
      if p.type == "garage" then
        ownedSet[p.id] = 'owned'
      elseif p.type == "rental" then
        ownedSet[p.id] = 'rental'
      elseif p.type == "backup" then
        ownedSet[p.id] = 'backup'
      end
    end
  end
  -- Also include garages with active paid rentals (paidRentalMode on backup garages).
  -- These are type="garage" and already in ownedSet, but upgrade their mode.
  if bcm_rentals and bcm_rentals.getAllActiveRentals then
    for garageId, rental in pairs(bcm_rentals.getAllActiveRentals()) do
      if rental.sourceMapName and tostring(rental.sourceMapName) == levelIdStr then
        if not ownedSet[garageId] then
          ownedSet[garageId] = 'paidRental'
        elseif ownedSet[garageId] == 'owned' then
          -- backup garage with paidRentalMode — upgrade to paidRental for priority
          local isPaid = bcm_properties.isPaidRental and bcm_properties.isPaidRental(garageId)
          if isPaid then
            ownedSet[garageId] = 'paidRental'
          end
        end
      end
    end
  end

  local levelIdStr = tostring(levelId)
  for id, def in pairs(defs) do
    if ownedSet[id] and def then
      local belongsHere = false
      -- mapName is the canonical field for map affiliation in BCM garage definitions.
      -- levelName is accepted as a legacy alias. If neither is present the garage is
      -- excluded rather than guessing from a path-prefix, which could match cross-map.
      if def.mapName and tostring(def.mapName) == levelIdStr then
        belongsHere = true
      elseif def.levelName and tostring(def.levelName) == levelIdStr then
        belongsHere = true
      end
      if belongsHere then
        local mode = ownedSet[id] -- 'owned' | 'paidRental' | 'rental' | 'backup'
        table.insert(result, {
          id = id,
          displayName = def.name or id,
          isStarterGarage = def.isStarterGarage == true,
          isBackupGarage = def.isBackupGarage == true,
          mode = mode,
        })
      end
    end
  end

  -- Priority: owned > paidRental > rental > backup. Within same priority, alphabetical.
  local modePriority = { owned = 1, paidRental = 2, rental = 3, backup = 4 }
  table.sort(result, function(a, b)
    local pa = modePriority[a.mode] or 9
    local pb = modePriority[b.mode] or 9
    if pa ~= pb then return pa < pb end
    return (a.displayName or "") < (b.displayName or "")
  end)
  return result
end

-- ============================================================================
-- Map display name (canonical — reads from BeamNG core_levels info.json)
-- ============================================================================

getMapDisplayName = function(mapId)
  if not mapId then return '' end
  if core_levels and core_levels.getLevelByName then
    local level = core_levels.getLevelByName(mapId)
    if level and level.title then
      -- level.title is often a translation key ("levels.west_coast_usa.info.title").
      -- Resolve it via translateLanguage; if it returns the key unchanged, use levelName.
      local resolved = translateLanguage(level.title, level.title, true)
      if resolved and resolved ~= '' and not resolved:find('%.info%.title') then
        return resolved
      end
      -- Fallback to levelName which is usually the human-readable name
      if level.levelName and level.levelName ~= '' then return level.levelName end
    end
  end
  -- Fallback: title-case the id
  return tostring(mapId):gsub('_', ' '):gsub('(%a)([%w]*)', function(a, b) return a:upper() .. b end)
end

-- ============================================================================
-- Travel spawn garage resolver
-- ============================================================================

-- Resolve the best garage on a target map to land a traveling vehicle at.
-- Priority: paidRental > owned > backup. Returns garageId or nil if nothing found.
-- Used by transit journal after safeTeleport to update the vehicle's location.
resolveTravelDestGarage = function(mapName)
  if not mapName then return nil end
  if not bcm_properties or not bcm_properties.getAllOwnedProperties then return nil end

  local ownedOnMap, paidOnMap, backupOnMap = nil, nil, nil
  local props = bcm_properties.getAllOwnedProperties() or {}

  for _, prop in ipairs(props) do
    local def = bcmGarageConfig[prop.id]
    -- Cross-map lookup fallback when the dest map's config isn't loaded yet
    local gMapName = def and (def.mapName or def.levelName) or nil
    if not gMapName and bcm_multimapApp and bcm_multimapApp.getGaragesForMap then
      for _, g in ipairs(bcm_multimapApp.getGaragesForMap(mapName) or {}) do
        if g.id == prop.id then gMapName = mapName; break end
      end
    end

    if gMapName and tostring(gMapName) == tostring(mapName) then
      if prop.type == 'garage' then
        -- paidRentalMode on an owned garage → paid rental upgrade
        if prop.paidRentalMode and not paidOnMap then paidOnMap = prop.id end
        if not ownedOnMap then ownedOnMap = prop.id end
      elseif prop.type == 'rental' then
        if not paidOnMap then paidOnMap = prop.id end
      elseif prop.type == 'backup' then
        -- paidRentalMode on a backup → paid rental upgrade of the backup
        if prop.paidRentalMode and not paidOnMap then paidOnMap = prop.id end
        if not backupOnMap then backupOnMap = prop.id end
      end
    end
  end

  return paidOnMap or ownedOnMap or backupOnMap
end

-- ============================================================================
-- Dev command
-- ============================================================================

-- Mark all BCM garages as discovered (for testing/dev purposes).
-- Does NOT purchase them — only marks them as seen.
discoverAllGarages = function()
  if not bcm_properties then
    log('W', 'bcm_garages', 'discoverAllGarages: bcm_properties not available')
    return
  end

  local count = 0
  for garageId in pairs(bcmGarageConfig) do
    bcm_properties.discoverProperty(garageId)
    count = count + 1
  end

  log('I', 'bcm_garages', 'discoverAllGarages: Discovered ' .. count .. ' garages')
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

-- Called when BCM career modules are fully activated (career loaded).
-- Only loads config and marks garage names here. Sync and grant are called by
-- garageManager.onCareerModulesActivated AFTER it loads purchasedGarages from disk,
-- to avoid the race condition where loadPurchasedGarages() overwrites BCM additions.
onCareerModulesActivated = function()
  -- Reset config for fresh load
  bcmGarageConfig = {}
  configLoaded = false

  -- 1. Load garage definitions from JSON (level-specific)
  loadGarageConfig()

  -- Steps 2-3 (sync, grant) are called by garageManager after loadPurchasedGarages()
  -- because they depend on bcm_properties data being loaded from disk first.
  log('I', 'bcm_garages', 'Garages config loaded (sync deferred to garageManager)')
end

-- ============================================================================
-- Public API (M table exports)
-- ============================================================================

-- Lifecycle (public)
M.onCareerModulesActivated = onCareerModulesActivated

-- Purchase flow
M.purchaseBcmGarage = purchaseBcmGarage

-- Capacity and tier queries
M.getCurrentCapacity = getCurrentCapacity
M.getSlotUpgradePrice = getSlotUpgradePrice
M.canUpgradeCapacity = canUpgradeCapacity

-- Definition queries
M.getGarageDefinition = getGarageDefinition
M.getAllDefinitions = getAllDefinitions
M.getGarageDisplayName = getGarageDisplayName

-- Vehicle and slot queries
M.getVehiclesInGarage = getVehiclesInGarage
M.getFreeSlots = getFreeSlots
M.getGarageCount = getGarageCount
M.isPositionInOwnedGarage = isPositionInOwnedGarage
M.getOwnedGaragesOnCurrentMap = getOwnedGaragesOnCurrentMap
M.getGaragesForMap = getGaragesForMap
M.isOvercapacity = isOvercapacity
M.getMapDisplayName = getMapDisplayName
M.resolveTravelDestGarage = resolveTravelDestGarage

-- Starter, backup, and dev
M.grantStarterGarageIfNeeded = grantStarterGarageIfNeeded
M.grantBackupGaragesIfNeeded = grantBackupGaragesIfNeeded
M.isBackupGarage = isBackupGarage
M.discoverAllGarages = discoverAllGarages

-- Called by garageManager after loadPurchasedGarages to avoid race condition
-- (BCM extensions fire before career modules in extensions.hook)
M.syncAllPurchasedGaragesWithVanilla = syncAllPurchasedGaragesWithVanilla

-- Internal functions are NOT exported:
-- loadGarageConfig, syncGarageWithVanilla

return M

