-- BCM Override: career_modules_delivery_tutorial
-- Neutralizes the vanilla delivery tutorial gate per BCM v2.0 tiered access model.
-- Basic delivery (parcels, vans) is available from day 1 without completing the tutorial.
-- Heavy delivery (trucks, trailers) is gated by CDL license, not tutorial.
-- This override is registered automatically by bcm_overrideManager via the
-- /overrides/ directory scan. It replaces career_modules_delivery_tutorial.

local M = {}

-- Forward declarations
local isCargoDeliveryTutorialActive
local isVehicleDeliveryTutorialActive
local isMaterialsDeliveryTutorialActive
local getTutorialInfo
local onPlayerAttributesChanged
local onCareerActivated
local onCareerProgressPageGetTasklistData

-- Module references (lazy binding)
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dVehicleTasks, dTasklist, dParcelMods, dVehOfferManager, dTutorial

onCareerActivated = function()
 dParcelManager = career_modules_delivery_parcelManager
 dCargoScreen = career_modules_delivery_cargoScreen
 dGeneral = career_modules_delivery_general
 dGenerator = career_modules_delivery_generator
 dProgress = career_modules_delivery_progress
 dVehicleTasks = career_modules_delivery_vehicleTasks
 dTasklist = career_modules_delivery_tasklist
 dParcelMods = career_modules_delivery_parcelMods
 dVehOfferManager = career_modules_delivery_vehicleOfferManager
 dTutorial = career_modules_delivery_tutorial
end

-- All tutorial gates return false — tutorials are bypassed
isCargoDeliveryTutorialActive = function()
 return false
end

isVehicleDeliveryTutorialActive = function()
 return false
end

isMaterialsDeliveryTutorialActive = function()
 return false
end

-- Tutorial info reports everything as unlocked and inactive
getTutorialInfo = function()
 local tutorialInfo = {
 parcel = {
 unlocked = true,
 isActive = false,
 tasks = {},
 },
 vehicle = {
 unlocked = true,
 isActive = false,
 tasks = {},
 },
 }
 onCareerProgressPageGetTasklistData(tutorialInfo.parcel, "delivery-introduction")
 onCareerProgressPageGetTasklistData(tutorialInfo.vehicle, "vehicle-delivery-introduction")
 return tutorialInfo
end

-- Attribute change handler — kept for compatibility but cache is unused since tutorials are disabled
onPlayerAttributesChanged = function(change, reason)
 -- No-op: tutorial status cache not needed when tutorials are always inactive
end

-- Tasklist data — shows tutorials as completed
onCareerProgressPageGetTasklistData = function(tasklistData, tasklistId)
 if tasklistId == "delivery-introduction" then
 tasklistData.headerLabel = "Delivery Introduction"
 tasklistData.tasks = {
 {
 label = "Cargo Delivery Tutorial Completed",
 description = "You have completed the cargo delivery tutorial. You can now start delivering cargo and earn money and XP.",
 done = true
 },
 }
 end
 if tasklistId == "vehicle-delivery-introduction" then
 tasklistData.headerLabel = "Vehicle Delivery Introduction"
 tasklistData.tasks = {
 {
 label = "Vehicle Delivery Tutorial Completed",
 description = "You have completed the vehicle delivery tutorial. You can now start delivering vehicles and earn money and XP.",
 done = true
 },
 }
 end
 if tasklistId == "materials-introduction" then
 tasklistData.headerLabel = "Materials Introduction"
 tasklistData.tasks = {
 {
 label = "Materials Delivery Tutorial Completed",
 description = "You have completed the materials delivery tutorial. You can now start delivering materials and earn money and XP.",
 done = true
 },
 }
 end
end

-- Export module table
M.onCareerActivated = onCareerActivated
M.isCargoDeliveryTutorialActive = isCargoDeliveryTutorialActive
M.isVehicleDeliveryTutorialActive = isVehicleDeliveryTutorialActive
M.isMaterialsDeliveryTutorialActive = isMaterialsDeliveryTutorialActive
M.getTutorialInfo = getTutorialInfo
M.onPlayerAttributesChanged = onPlayerAttributesChanged
M.onCareerProgressPageGetTasklistData = onCareerProgressPageGetTasklistData

return M
