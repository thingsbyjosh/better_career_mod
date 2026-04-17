-- BCM Properties Extension
-- Property data model: ownership records, tier state, vehicle assignments, and persistence.
-- Foundational data layer for all property/garage features in v1.6.
-- Every later phase (purchase UI, paint tier gating, mortgages, dyno) reads and writes through this module.

local M = {}

-- Forward declarations (ALL functions declared before any function body per Lua convention)
local loadData
local saveData
local onSaveCurrentSaveSlot
local onSaveCurrentSaveSlotAsyncStart
local onCareerModulesActivated
local onCareerActive
local isOwned
local isDiscovered
local getOwnedProperty
local getAllOwnedProperties
local purchaseProperty
local removeProperty
local upgradePropertyTier
local upgradePropertyCapacity
local renameProperty
local setHomeGarage
local getHomeGarageId
local assignVehicleToGarage
local discoverProperty
local getVehicleTransfers
local addVehicleTransfer
local removeVehicleTransfer
-- Phase 102 hybrid data model helpers (paidRentalMode flag + rental type discriminator)
local isPaidRental
local setPaidRentalMode
local clearPaidRentalMode
local getOwnedGarages
-- Save migration: type=garage → type=backup for backup garages
local migrateBackupGarageTypes

-- ============================================================================
-- Private state
-- ============================================================================

-- Owned properties: keyed by propertyId
-- Each record: { id, type, purchasedAt, purchasedGameDay, tier, currentCapacity, customName, isHome }
local ownedProperties = {}

-- Discovered (but not necessarily owned) properties: keyed by propertyId, value = true
local discoveredProperties = {}

-- The active home garage id (nil if none set)
local homeGarageId = nil

-- Pending vehicle transfers: vehicleInventoryId (string) -> { fromGarageId, toGarageId, startTime, completionTime }
local vehicleTransfers = {}

-- ============================================================================
-- Query functions
-- ============================================================================

-- Returns true if the player owns this property
isOwned = function(propertyId)
  return ownedProperties[propertyId] ~= nil
end

-- Returns true if the player has discovered (seen) this property
isDiscovered = function(propertyId)
  return discoveredProperties[propertyId] == true
end

-- Returns the owned property record or nil
getOwnedProperty = function(propertyId)
  return ownedProperties[propertyId]
end

-- Returns an array of all owned property records
getAllOwnedProperties = function()
  local result = {}
  for _, record in pairs(ownedProperties) do
    table.insert(result, record)
  end
  return result
end

-- Returns the current home garage id (may be nil)
getHomeGarageId = function()
  return homeGarageId
end


-- ============================================================================
-- Mutation functions
-- ============================================================================

-- Purchase a property and add it to owned records.
-- propertyId: string ID matching the garage/property definition
-- propertyType: "garage" or other future property types
-- baseCapacity: integer number of vehicle slots at purchase
-- Returns the new property record, or nil if already owned.
purchaseProperty = function(propertyId, propertyType, baseCapacity)
  if isOwned(propertyId) then
    log('W', 'bcm_properties', 'purchaseProperty: property already owned: ' .. tostring(propertyId))
    return nil
  end

  local gameDay = 0
  if bcm_timeSystem then
    gameDay = bcm_timeSystem.getGameTimeDays() or 0
  end

  local record = {
    id = propertyId,
    type = propertyType or "garage",
    purchasedAt = os.time(),
    purchasedGameDay = gameDay,
    tier = 0,
    currentCapacity = baseCapacity or 1,
    customName = nil,
    isHome = false,
    -- Phase 102: paidRentalMode is nil for normal owned garages and for non-backup rentals.
    -- When set (table with startDay/lastChargedDay/dailyRateCents), indicates this record
    -- is the auto-granted backup garage upgraded into paid-rental mode. See bcm/rentals.lua.
    paidRentalMode = nil,
  }

  ownedProperties[propertyId] = record
  discoveredProperties[propertyId] = true

  -- Auto-set as home garage if none exists and this is a garage type
  if not homeGarageId and record.type == "garage" then
    homeGarageId = propertyId
    record.isHome = true
    log('I', 'bcm_properties', 'Auto-set home garage: ' .. propertyId)
  end

  guihooks.trigger('BCMPropertyUpdate', { action = 'purchased', propertyId = propertyId })
  log('I', 'bcm_properties', 'Purchased property: ' .. propertyId .. ' (type=' .. record.type .. ', tier=0, capacity=' .. record.currentCapacity .. ')')

  return record
end

-- Remove property from owned (sell flow).
-- If the sold property was home, reassign home to first remaining property.
removeProperty = function(propertyId)
  if not isOwned(propertyId) then
    log('W', 'bcm_properties', 'removeProperty: property not owned: ' .. tostring(propertyId))
    return false
  end

  ownedProperties[propertyId] = nil

  -- If this was the home garage, pick a new one
  if homeGarageId == propertyId then
    homeGarageId = nil
    for id, record in pairs(ownedProperties) do
      if record.type == "garage" then
        homeGarageId = id
        record.isHome = true
        log('I', 'bcm_properties', 'Home garage reassigned to: ' .. id)
        break
      end
    end
  end

  guihooks.trigger('BCMPropertyUpdate', { action = 'sold', propertyId = propertyId })
  log('I', 'bcm_properties', 'Removed property: ' .. tostring(propertyId))
  return true
end

-- Upgrade a property's tier (T0 -> T1 -> T2 max).
-- Returns the new tier value, or nil if guard fails.
upgradePropertyTier = function(propertyId)
  if not isOwned(propertyId) then
    log('W', 'bcm_properties', 'upgradePropertyTier: property not owned: ' .. tostring(propertyId))
    return nil
  end

  local record = ownedProperties[propertyId]
  if record.tier >= 2 then
    log('W', 'bcm_properties', 'upgradePropertyTier: already at max tier (T2) for: ' .. tostring(propertyId))
    return nil
  end

  record.tier = record.tier + 1
  guihooks.trigger('BCMPropertyUpdate', { action = 'tierUpgraded', propertyId = propertyId, tier = record.tier })
  log('I', 'bcm_properties', 'Tier upgraded: ' .. propertyId .. ' -> T' .. record.tier)

  return record.tier
end

-- Upgrade a property's capacity by 1 slot.
-- Caller (bcm_garages.lua) is responsible for checking against maxCapacity from config.
-- Returns the new capacity, or nil if guard fails.
upgradePropertyCapacity = function(propertyId)
  if not isOwned(propertyId) then
    log('W', 'bcm_properties', 'upgradePropertyCapacity: property not owned: ' .. tostring(propertyId))
    return nil
  end

  local record = ownedProperties[propertyId]
  record.currentCapacity = record.currentCapacity + 1
  guihooks.trigger('BCMPropertyUpdate', { action = 'capacityUpgraded', propertyId = propertyId, currentCapacity = record.currentCapacity })
  log('I', 'bcm_properties', 'Capacity upgraded: ' .. propertyId .. ' -> ' .. record.currentCapacity .. ' slots')

  return record.currentCapacity
end

-- Rename a property. Pass nil or "" to revert to default name.
renameProperty = function(propertyId, newName)
  if not isOwned(propertyId) then
    log('W', 'bcm_properties', 'renameProperty: property not owned: ' .. tostring(propertyId))
    return
  end

  local record = ownedProperties[propertyId]
  if newName == nil or newName == "" then
    record.customName = nil
  else
    record.customName = newName
  end

  guihooks.trigger('BCMPropertyUpdate', { action = 'renamed', propertyId = propertyId, customName = record.customName })
  log('D', 'bcm_properties', 'Property renamed: ' .. propertyId .. ' -> ' .. tostring(record.customName))
end

-- Set the active home garage. Clears the previous home flag.
setHomeGarage = function(garageId)
  if not isOwned(garageId) then
    log('W', 'bcm_properties', 'setHomeGarage: property not owned: ' .. tostring(garageId))
    return
  end

  -- Clear all home flags
  for _, record in pairs(ownedProperties) do
    record.isHome = false
  end

  ownedProperties[garageId].isHome = true
  homeGarageId = garageId

  guihooks.trigger('BCMPropertyUpdate', { action = 'homeSet', propertyId = garageId })
  log('I', 'bcm_properties', 'Home garage set: ' .. garageId)
end

-- Compatibility shim: sets vehicle.location directly instead of using vehicleAssignments.
-- Kept because this function is called by garageManagerApp (transfer), loans, and realEstateApp.
assignVehicleToGarage = function(vehicleInventoryId, garageId)
  local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles()
  if not vehicles then return end
  local invId = tonumber(vehicleInventoryId) or vehicleInventoryId
  if vehicles[invId] then
    vehicles[invId].location = garageId
    vehicles[invId].niceLocation = (bcm_garages and bcm_garages.getGarageDisplayName and bcm_garages.getGarageDisplayName(garageId)) or garageId
    -- Mark dirty so vanilla persists the updated location to disk on next save.
    -- Without this, vehicles/<id>.json is only rewritten when other fields change,
    -- so our location update would stay in-memory and revert on reload.
    if career_modules_inventory.setVehicleDirty then
      career_modules_inventory.setVehicleDirty(invId)
    end
    log('I', 'bcm_properties', 'assignVehicleToGarage shim: inv=' .. tostring(invId) .. ' -> garage=' .. tostring(garageId))
  end
  guihooks.trigger('BCMPropertyUpdate', { action = 'vehicleAssigned', vehicleInventoryId = tostring(vehicleInventoryId), garageId = garageId })
end

-- Mark a property as discovered (seen on the map) without purchasing it.
discoverProperty = function(propertyId)
  discoveredProperties[propertyId] = true
  guihooks.trigger('BCMPropertyUpdate', { action = 'discovered', propertyId = propertyId })
  log('D', 'bcm_properties', 'Property discovered: ' .. propertyId)
end

-- ============================================================================
-- Phase 102: paidRentalMode helpers (hybrid data model — Pitfall 6 resolution)
-- ============================================================================
-- Two orthogonal concepts coexist:
--   (1) type = "rental"       — a non-backup garage the player pays to rent
--   (2) paidRentalMode flag   — an owned (type="garage") backup garage upgraded
--                               into paid-rental mode, unlocking extra caps
-- bcm/rentals.lua is the sole writer; other modules read via isPaidRental().

isPaidRental = function(propertyId)
  if not propertyId then return false end
  local rec = ownedProperties[propertyId]
  if not rec then return false end
  return rec.paidRentalMode ~= nil
end

setPaidRentalMode = function(propertyId, modeData)
  if not propertyId then return false end
  local rec = ownedProperties[propertyId]
  if not rec then
    log('W', 'bcm_properties', 'setPaidRentalMode: record not found: ' .. tostring(propertyId))
    return false
  end
  -- modeData shape: { startDay, lastChargedDay, dailyRateCents }
  rec.paidRentalMode = modeData
  guihooks.trigger('BCMPropertyUpdate', { action = 'paidRentalModeSet', propertyId = propertyId })
  log('I', 'bcm_properties', 'paidRentalMode set on: ' .. tostring(propertyId))
  return true
end

clearPaidRentalMode = function(propertyId)
  if not propertyId then return false end
  local rec = ownedProperties[propertyId]
  if not rec then return false end
  rec.paidRentalMode = nil
  guihooks.trigger('BCMPropertyUpdate', { action = 'paidRentalModeCleared', propertyId = propertyId })
  log('I', 'bcm_properties', 'paidRentalMode cleared on: ' .. tostring(propertyId))
  return true
end

-- Save migration: converts type="garage" → type="backup" for garages whose JSON
-- definition has isBackupGarage=true. Runs once per load to handle saves created
-- before the backup type was introduced. Idempotent — already-migrated records
-- (type="backup") are skipped.
migrateBackupGarageTypes = function()
  if not ownedProperties then return end
  for _, prop in pairs(ownedProperties) do
    if prop.type == "garage" and prop.id then
      -- Check if this garage is actually a backup (isBackupGarage in JSON def)
      if bcm_garages and bcm_garages.isBackupGarage and bcm_garages.isBackupGarage(prop.id) then
        prop.type = "backup"
        log('I', 'bcm_properties', 'Migrated backup garage type: ' .. tostring(prop.id))
      end
    end
  end
end

-- Returns an array of records where type == "garage" (excludes type == "rental"
-- and type == "backup"). Use this helper anywhere the caller means "real owned
-- garages" — e.g. monthly property tax, home-garage assignment, garage-count
-- for sell guards.
getOwnedGarages = function()
  local garages = {}
  for _, rec in pairs(ownedProperties) do
    if rec.type == "garage" then
      table.insert(garages, rec)
    end
  end
  return garages
end

-- ============================================================================
-- Vehicle transfer data model
-- ============================================================================

-- Returns the vehicleTransfers table (vehicleId -> transfer record)
getVehicleTransfers = function()
  return vehicleTransfers
end

-- Record a pending vehicle transfer.
-- vehicleId: string inventory ID
-- transferData: { fromGarageId, toGarageId, startTime, completionTime }
addVehicleTransfer = function(vehicleId, transferData)
  vehicleTransfers[tostring(vehicleId)] = transferData
  guihooks.trigger('BCMPropertyUpdate', { action = 'transferStarted', vehicleId = tostring(vehicleId) })
  log('I', 'bcm_properties', 'Vehicle transfer recorded: ' .. tostring(vehicleId) .. ' from ' .. tostring(transferData.fromGarageId) .. ' to ' .. tostring(transferData.toGarageId))
end

-- Remove a completed (or cancelled) vehicle transfer record.
removeVehicleTransfer = function(vehicleId)
  vehicleTransfers[tostring(vehicleId)] = nil
  guihooks.trigger('BCMPropertyUpdate', { action = 'transferComplete', vehicleId = tostring(vehicleId) })
  log('I', 'bcm_properties', 'Vehicle transfer removed: ' .. tostring(vehicleId))
end

-- ============================================================================
-- Persistence
-- ============================================================================

-- Save property data to the current save slot.
saveData = function(currentSavePath)
  if not career_saveSystem then
    log('W', 'bcm_properties', 'career_saveSystem not available, cannot save property data')
    return
  end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  local data = {
    ownedProperties = ownedProperties,
    discoveredProperties = discoveredProperties,
    homeGarageId = homeGarageId,
    vehicleTransfers = vehicleTransfers
  }

  local dataPath = bcmDir .. "/properties.json"
  career_saveSystem.jsonWriteFileSafe(dataPath, data, true)

  local count = 0
  for _ in pairs(ownedProperties) do count = count + 1 end
  log('I', 'bcm_properties', 'Saved property data: ' .. count .. ' owned properties')
end

-- Load property data from the current save slot.
loadData = function()
  if not career_career or not career_career.isActive() then
    return
  end

  if not career_saveSystem then
    log('W', 'bcm_properties', 'career_saveSystem not available, cannot load property data')
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('W', 'bcm_properties', 'No save slot active, cannot load property data')
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    log('W', 'bcm_properties', 'No autosave found for slot: ' .. tostring(currentSaveSlot))
    return
  end

  local dataPath = autosavePath .. "/career/bcm/properties.json"
  local data = jsonReadFile(dataPath)

  -- Reset state before populating
  ownedProperties = {}
  discoveredProperties = {}
  homeGarageId = nil
  vehicleTransfers = {}

  if data then
    ownedProperties = data.ownedProperties or {}
    discoveredProperties = data.discoveredProperties or {}
    homeGarageId = data.homeGarageId or nil
    vehicleTransfers = data.vehicleTransfers or {}

    local count = 0
    for _ in pairs(ownedProperties) do count = count + 1 end
    log('I', 'bcm_properties', 'Loaded property data: ' .. count .. ' owned properties, homeGarage=' .. tostring(homeGarageId))
  else
    log('I', 'bcm_properties', 'No saved property data found — starting fresh')
  end

  -- Migrate old saves: type="garage" + isBackupGarage → type="backup"
  migrateBackupGarageTypes()
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

-- Re-derive vehicle location from physical position BEFORE vanilla's save runs.
-- onSaveCurrentSaveSlotAsyncStart fires in the "preparation" phase of the save
-- pipeline (before the main onSaveCurrentSaveSlot hook), which is where we
-- need to be so that marking a vehicle dirty here gets picked up by vanilla's
-- saveVehiclesData writer. Doing this in onSaveCurrentSaveSlot would race with
-- vanilla's save — whichever runs first wins, and load order isn't guaranteed.
onSaveCurrentSaveSlotAsyncStart = function()
  if not (career_modules_inventory
     and career_modules_inventory.getVehicles
     and career_modules_inventory.getClosestGarage
     and career_modules_inventory.getMapInventoryIdToVehId) then return end
  local vehicles = career_modules_inventory.getVehicles()
  local invIdToVehId = career_modules_inventory.getMapInventoryIdToVehId() or {}
  for invId, vehId in pairs(invIdToVehId) do
    local veh = vehicles and vehicles[invId] and getObjectByID and getObjectByID(vehId)
    if veh and veh.getPosition then
      local ok, garage = pcall(career_modules_inventory.getClosestGarage, veh:getPosition())
      if ok and garage and garage.id and vehicles[invId] then
        if vehicles[invId].location ~= garage.id then
          vehicles[invId].location = garage.id
          if career_modules_inventory.setVehicleDirty then
            career_modules_inventory.setVehicleDirty(invId)
          end
        end
      end
    end
  end
end

-- Called by the BeamNG save system when a save slot is written.
onSaveCurrentSaveSlot = function(currentSavePath)
  saveData(currentSavePath)
end

-- Called when BCM career modules are fully activated (career loaded).
onCareerModulesActivated = function()
  loadData()
  log('I', 'bcm_properties', 'Properties module activated')
end

-- Called when career active state changes (e.g., player exits career).
onCareerActive = function(active)
  if not active then
    -- Reset in-memory state when career exits
    ownedProperties = {}
    discoveredProperties = {}
    homeGarageId = nil
    vehicleTransfers = {}
    log('I', 'bcm_properties', 'Properties module deactivated, state reset')
  end
end

-- ============================================================================
-- Phase 102 audit: getAllOwnedProperties consumers (verified 2026-04-15)
-- ============================================================================
-- Any new consumer that is NOT rental-aware MUST either filter by p.type == "garage"
-- or call getOwnedGarages() instead. Consumers iterating by id-only lookups (for
-- display-name resolution) are safe regardless of type.
--
-- SAFE (already filter by type == "garage"):
--   career/modules/garageManager.lua:117 fillGarages      — filters
--   overrides/career/modules/vehicleShopping.lua:37,53    — filters
--   bcm/dealershipApp.lua:276,689 resolveGarageList       — filters
--   bcm/garageManagerApp.lua:421 buildTransferTargets     — filters
--   bcm/garages.lua:110 syncAllPurchasedGaragesWithVanilla — filters
--   bcm/garages.lua:256 isPositionInOwnedGarage           — filters
--   bcm/garages.lua:300 getGarageCount                    — filters
--   bcm/garages.lua:403 getOwnedGaragesOnCurrentMap       — filters
--   bcm/loans.lua:1108 mortgage foreclosure vehicle hunt  — filters
--   bcm/loans.lua:1657 foreclosure relocate loop          — filters
--   bcm/marketplaceApp.lua:782,1150 garage list + fallback — filters
--   bcm/realEstateApp.lua:86,261,504 property tax + lists — filters
--
-- SAFE (id-only lookups, type-agnostic display-name resolution):
--   bcm/marketplaceApp.lua:1354 garage name-by-id lookup
--   bcm/marketplaceApp.lua:1464 garage name-by-id lookup
--   bcm/vehicleGalleryApp.lua:200 capacity map — includes rentals deliberately
--     (rentals ARE valid vehicle locations; vehicleGallery shows vehicles in them)
--
-- FLAGGED — audit revisit when rentals land in Plan 03:
--   bcm/garageManagerApp.lua:159 otherGarageCount (for sell guard)
--     Counts non-current owned records without filtering by type. When rentals
--     exist this will count a rental as "another garage" and could wrongly allow
--     selling the only real garage. Plan 03 MUST switch this to getOwnedGarages().
--   bcm/garageManagerApp.lua:616 importable vehicles source iteration
--     Iterates ALL properties as possible source garages. Rentals are valid
--     sources (they contain vehicles), so behavior is acceptable, but Plan 03/04
--     should audit the transfer delay + display name paths for rental sources.
-- ============================================================================

-- ============================================================================
-- Public API (M table exports)
-- ============================================================================

-- Lifecycle
M.onCareerModulesActivated = onCareerModulesActivated
M.onCareerActive = onCareerActive
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onSaveCurrentSaveSlotAsyncStart = onSaveCurrentSaveSlotAsyncStart

-- Query
M.isOwned = isOwned
M.isDiscovered = isDiscovered
M.getOwnedProperty = getOwnedProperty
M.getAllOwnedProperties = getAllOwnedProperties
M.getOwnedGarages = getOwnedGarages
M.getHomeGarageId = getHomeGarageId
M.isPaidRental = isPaidRental

-- Mutation
M.purchaseProperty = purchaseProperty
M.removeProperty = removeProperty
M.upgradePropertyTier = upgradePropertyTier
M.upgradePropertyCapacity = upgradePropertyCapacity
M.renameProperty = renameProperty
M.setHomeGarage = setHomeGarage
M.assignVehicleToGarage = assignVehicleToGarage
M.discoverProperty = discoverProperty
M.setPaidRentalMode = setPaidRentalMode
M.clearPaidRentalMode = clearPaidRentalMode
M.migrateBackupGarageTypes = migrateBackupGarageTypes

-- Vehicle transfers
M.getVehicleTransfers = getVehicleTransfers
M.addVehicleTransfer = addVehicleTransfer
M.removeVehicleTransfer = removeVehicleTransfer

return M
