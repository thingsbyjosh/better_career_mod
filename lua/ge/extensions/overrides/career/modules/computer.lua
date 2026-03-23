-- BCM Override of career/modules/computer.lua
-- Only change: getComputerUIData returns garageId from the computer facility

local M = {}

M.dependencies = {"career_career"}

local computerTetherRangeSphere = 4 --meter
local computerTetherRangeBox = 1 --meter
local tether

local computerFunctions
local computerId
local computerFacilityName
local computerGarageId
local menuData = {}

local function openMenu(computerFacility, resetActiveVehicleIndex, activityElement)
 computerFunctions = {general = {}, vehicleSpecific = {}}
 computerId = computerFacility.id
 computerFacilityName = computerFacility.name
 computerGarageId = computerFacility.garageId -- BCM: store garageId

 menuData = {vehiclesInGarage = {}, resetActiveVehicleIndex = resetActiveVehicleIndex}
 local inventoryIds = career_modules_inventory.getInventoryIdsInClosestGarage()

 for _, inventoryId in ipairs(inventoryIds) do
 -- BCM: skip non-owned vehicles (loaners) — they should not appear in garage
 local vehicleInfo = career_modules_inventory.getVehicles()[inventoryId]
 if vehicleInfo and vehicleInfo.owned == false then goto continueVeh end

 local vehicleData = {}
 vehicleData.inventoryId = inventoryId
 vehicleData.needsRepair = career_modules_insurance_insurance.inventoryVehNeedsRepair(inventoryId) or nil
 vehicleData.vehicleName = vehicleInfo and vehicleInfo.niceName
 vehicleData.dirtyDate = vehicleInfo and vehicleInfo.dirtyDate
 table.insert(menuData.vehiclesInGarage, vehicleData)

 computerFunctions.vehicleSpecific[inventoryId] = {}
 ::continueVeh::
 end

 menuData.computerFacility = computerFacility
 if not career_modules_linearTutorial.getTutorialFlag("partShoppingComplete") then
 menuData.tutorialPartShoppingActive = true
 elseif not career_modules_linearTutorial.getTutorialFlag("tuningComplete") then
 menuData.tutorialTuningActive = true
 end

 extensions.hook("onComputerAddFunctions", menuData, computerFunctions)

 local door = computerFacility.doors[1]
 tether = nil
 if door then
 tether = career_modules_tether.startDoorTether(door, computerTetherRangeBox, M.closeMenu)
 end
 if not tether then
 local computerPos = freeroam_facilities.getAverageDoorPositionForFacility(computerFacility)
 tether = career_modules_tether.startSphereTether(computerPos, computerTetherRangeSphere, M.closeMenu)
 end

 guihooks.trigger('ChangeState', {state = 'computer'})
 extensions.hook("onComputerMenuOpened")
end

-- BCM: Re-scan garage vehicles and re-fire the hook so all modules (paint,
-- tuning, parts, CARamp, insurance, etc.) register their functions for any
-- newly-spawned vehicle. Called from vehicleGalleryApp after retrieve/replace.
local function refreshComputerData()
 if not computerId then return end -- computer not open

 -- Rebuild vehiclesInGarage from current garage state
 menuData.vehiclesInGarage = {}
 computerFunctions.vehicleSpecific = {}

 local inventoryIds = career_modules_inventory.getInventoryIdsInClosestGarage()
 for _, inventoryId in ipairs(inventoryIds) do
 -- BCM: skip non-owned vehicles (loaners)
 local vehicleInfo = career_modules_inventory.getVehicles()[inventoryId]
 if vehicleInfo and vehicleInfo.owned == false then goto continueRefresh end

 local vehicleData = {}
 vehicleData.inventoryId = inventoryId
 vehicleData.needsRepair = career_modules_insurance_insurance.inventoryVehNeedsRepair(inventoryId) or nil
 vehicleData.vehicleName = vehicleInfo and vehicleInfo.niceName
 vehicleData.dirtyDate = vehicleInfo and vehicleInfo.dirtyDate
 table.insert(menuData.vehiclesInGarage, vehicleData)

 computerFunctions.vehicleSpecific[inventoryId] = {}
 ::continueRefresh::
 end

 -- Re-fire so all extensions register their buttons for the new vehicle list
 extensions.hook("onComputerAddFunctions", menuData, computerFunctions)

 -- Tell Vue to re-fetch computer data
 guihooks.trigger('BCMRefreshComputerData')
end

local function computerButtonCallback(buttonId, inventoryId)
 local functionData
 if inventoryId then
 functionData = computerFunctions.vehicleSpecific[inventoryId][buttonId]
 else
 functionData = computerFunctions.general[buttonId]
 end

 functionData.callback(computerId)
end

local function getComputerUIData()
 local data = {}
 local invVehicles = career_modules_inventory.getVehicles()

 local computerFunctionsForUI = deepcopy(computerFunctions)
 computerFunctionsForUI.vehicleSpecific = {}

 -- convert keys of the table to string, because js doesnt support number keys
 for inventoryId, computerFunction in pairs(computerFunctions.vehicleSpecific) do
 if invVehicles and invVehicles[inventoryId] then
 computerFunctionsForUI.vehicleSpecific[tostring(inventoryId)] = computerFunction
 end
 end

 local vehiclesForUI = {}
 for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
 local invId = vehicleData.inventoryId
 if invVehicles and invVehicles[invId] then
 local vd = deepcopy(vehicleData)
 local thumb = career_modules_inventory.getVehicleThumbnail(invId)
 if thumb then
 vd.thumbnail = thumb .. "?" .. (vd.dirtyDate or "")
 end
 vd.inventoryId = tostring(invId)
 table.insert(vehiclesForUI, vd)
 end
 end

 data.computerFunctions = computerFunctionsForUI
 data.vehicles = vehiclesForUI
 data.facilityName = computerFacilityName
 data.resetActiveVehicleIndex = menuData.resetActiveVehicleIndex
 data.computerId = computerId
 data.garageId = computerGarageId -- BCM: include garageId in UI data
 return data
end

local function onMenuClosed()
 if tether then tether.remove = true tether = nil end
end

local function closeMenu()
 career_career.closeAllMenus()
end

-- BCM: Suspend tether for paint mode (allows player to walk around vehicle)
local function suspendTether()
 if tether then
 tether.remove = true
 tether = nil
 end
end

local function openComputerMenuById(compId)
 local computer = freeroam_facilities.getFacility("computer", compId)
 career_modules_computer.openMenu(computer)
end

M.reasons = {
 tutorialActive = {
 type = "text",
 label = "Disabled during tutorial."
 },
 needsRepair = {
 type = "needsRepair",
 label = "The vehicle needs to be repaired first."
 }
}

local function getComputerId()
 return computerId
end

M.openMenu = openMenu
M.openComputerMenuById = openComputerMenuById
M.onMenuClosed = onMenuClosed
M.closeMenu = closeMenu
M.getComputerUIData = getComputerUIData
M.computerButtonCallback = computerButtonCallback
M.getComputerId = getComputerId
M.suspendTether = suspendTether
M.refreshComputerData = refreshComputerData

return M
