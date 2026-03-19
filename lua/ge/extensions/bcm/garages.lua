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
local onCareerModulesActivated
local discoverAllGarages

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
    if property.type == "garage" then
      syncGarageWithVanilla(property.id)
      syncCount = syncCount + 1
    end
  end

  log('I', 'bcm_garages', 'syncAllPurchasedGaragesWithVanilla: Synced ' .. syncCount .. ' owned garages with vanilla')
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
  local record = bcm_properties.purchaseProperty(garageId, "garage", definition.baseCapacity)

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

  local definition = bcmGarageConfig[garageId]
  if definition and definition.name then
    return definition.name
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
getFreeSlots = function(garageId)
  local capacity = getCurrentCapacity(garageId)
  local vehicles = getVehiclesInGarage(garageId)
  return capacity - #vehicles
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
-- Only loads config and marks RLS names here. Sync and grant are called by
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

-- Starter and dev
M.grantStarterGarageIfNeeded = grantStarterGarageIfNeeded
M.discoverAllGarages = discoverAllGarages

-- Called by garageManager after loadPurchasedGarages to avoid race condition
-- (BCM extensions fire before career modules in extensions.hook)
M.syncAllPurchasedGaragesWithVanilla = syncAllPurchasedGaragesWithVanilla

-- Internal functions are NOT exported:
-- loadGarageConfig, syncGarageWithVanilla

return M
