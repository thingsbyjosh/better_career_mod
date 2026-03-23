-- BCM Properties Extension
-- Property data model: ownership records, tier state, vehicle assignments, and persistence.
-- Foundational data layer for all property/garage features in v1.6.
-- Every later phase (purchase UI, paint tier gating, mortgages, dyno) reads and writes through this module.

local M = {}

-- Forward declarations (ALL functions declared before any function body per Lua convention)
local loadData
local saveData
local onSaveCurrentSaveSlot
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
 isHome = false
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
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

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
-- Public API (M table exports)
-- ============================================================================

-- Lifecycle
M.onCareerModulesActivated = onCareerModulesActivated
M.onCareerActive = onCareerActive
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

-- Query
M.isOwned = isOwned
M.isDiscovered = isDiscovered
M.getOwnedProperty = getOwnedProperty
M.getAllOwnedProperties = getAllOwnedProperties
M.getHomeGarageId = getHomeGarageId

-- Mutation
M.purchaseProperty = purchaseProperty
M.removeProperty = removeProperty
M.upgradePropertyTier = upgradePropertyTier
M.upgradePropertyCapacity = upgradePropertyCapacity
M.renameProperty = renameProperty
M.setHomeGarage = setHomeGarage
M.assignVehicleToGarage = assignVehicleToGarage
M.discoverProperty = discoverProperty

-- Vehicle transfers
M.getVehicleTransfers = getVehicleTransfers
M.addVehicleTransfer = addVehicleTransfer
M.removeVehicleTransfer = removeVehicleTransfer

return M
