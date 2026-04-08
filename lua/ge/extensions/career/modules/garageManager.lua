-- BCM Garage Manager
-- BCM garage system with purchase-based ownership
-- Replaces vanilla garageManager with purchase-based garage system
-- Save path: /career/bcm/purchasedGarages.json
-- BCM does NOT have hardcore mode — all hardcore references removed

local M = {}
M.dependencies = { 'career_career', 'career_saveSystem', 'freeroam_facilities' }

local purchasedGarages = {}
local discoveredGarages = {}
local garageToPurchase = nil
local saveFile = "purchasedGarages.json"

local garageSize = {}

local function savePurchasedGarages(currentSavePath)
 if not currentSavePath then
 local slot, path = career_saveSystem.getCurrentSaveSlot()
 currentSavePath = path
 if not currentSavePath then return end
 end

 local dirPath = currentSavePath .. "/career/bcm"
 if not FS:directoryExists(dirPath) then
 FS:directoryCreate(dirPath)
 end

 local data = {
 garages = purchasedGarages,
 discovered = discoveredGarages
 }
 career_saveSystem.jsonWriteFileSafe(dirPath .. "/" .. saveFile, data, true)
end

local function onSaveCurrentSaveSlot(currentSavePath)
 savePurchasedGarages(currentSavePath)
end

local function isPurchasedGarage(garageId)
 return purchasedGarages[garageId] or false
end

local function isDiscoveredGarage(garageId)
 return discoveredGarages[garageId] or false
end

local function reloadRecoveryPrompt()
 if core_recoveryPrompt and core_recoveryPrompt.setDefaultsForCareer then
 core_recoveryPrompt.setDefaultsForCareer()
 end
end

local function buildGarageSizes()
 local garages = freeroam_facilities.getFacilitiesByType("garage")
 if not garages then return end

 for _, garage in pairs(garages) do
 if purchasedGarages[garage.id] then
 garageSize[tostring(garage.id)] = math.ceil(garage.capacity) or 0
 end
 end
end

local function addPurchasedGarage(garageId)
 if not next(purchasedGarages) then
 log("I", "garageManager", "First garage purchased: " .. garageId)
 end
 purchasedGarages[garageId] = true
 discoveredGarages[garageId] = true
 reloadRecoveryPrompt()
 buildGarageSizes()
end

local function addDiscoveredGarage(garageId)
 if not discoveredGarages[garageId] then
 local garages = freeroam_facilities.getFacilitiesByType("garage")
 if garages then
 for _, garage in ipairs(garages) do
 if garage.id == garageId and garage.defaultPrice == 0 then
 purchasedGarages[garageId] = true
 break
 end
 end
 end
 discoveredGarages[garageId] = true
 reloadRecoveryPrompt()
 end
end

local function purchaseDefaultGarage()
 -- BCM override: if bcm_garages is active, it owns starter garage logic.
 -- grantStarterGarageIfNeeded() already calls addPurchasedGarage via syncGarageWithVanilla.
 if bcm_garages then
 log("I", "garageManager", "BCM active — skipping vanilla purchaseDefaultGarage")
 return
 end

 local garages = freeroam_facilities.getFacilitiesByType("garage")
 if not garages or #garages == 0 then return end
 for _, garage in ipairs(garages) do
 if garage.starterGarage then
 log("I", "garageManager", "Purchasing starter garage: " .. garage.id)
 addPurchasedGarage(garage.id)
 return
 end
 end
end

local function fillGarages()
 if not career_modules_inventory then return end
 local vehicles = career_modules_inventory.getVehicles()
 if not vehicles then return end

 -- Build ordered list of BCM-owned garages
 local ownedGarages = {}
 if bcm_properties and bcm_properties.getAllOwnedProperties then
 local props = bcm_properties.getAllOwnedProperties()
 for _, prop in ipairs(props or {}) do
 if prop.type == "garage" then
 table.insert(ownedGarages, prop.id)
 end
 end
 end
 -- Fallback to purchasedGarages if BCM properties not ready
 if #ownedGarages == 0 and purchasedGarages then
 for garageId, owned in pairs(purchasedGarages) do
 if owned then table.insert(ownedGarages, garageId) end
 end
 end

 local fallbackGarage = ownedGarages[1] -- force-assign to first garage if all full

 for id, vehicle in pairs(vehicles) do
 if not vehicle.location then
 -- Try to find a garage with free space
 local assigned = nil
 for _, garageId in ipairs(ownedGarages) do
 local freeSlots = bcm_garages and bcm_garages.getFreeSlots and bcm_garages.getFreeSlots(garageId)
 if freeSlots and freeSlots > 0 then
 assigned = garageId
 break
 end
 end
 if not assigned then assigned = fallbackGarage end
 if assigned then
 vehicle.location = assigned
 vehicle.niceLocation = (bcm_garages and bcm_garages.getGarageDisplayName and bcm_garages.getGarageDisplayName(assigned)) or assigned
 log('I', 'garageManager', 'fillGarages: orphan vehicle ' .. tostring(id) .. ' assigned to ' .. tostring(assigned))
 else
 -- No BCM garages at all — use vanilla fallback
 local moveVehicle = career_modules_inventory.moveVehicleToGarage
 if moveVehicle then
 moveVehicle(id)
 else
 local garage = M.getNextAvailableSpace and M.getNextAvailableSpace()
 if garage then
 vehicle.location = garage
 vehicle.niceLocation = M.garageIdToName and M.garageIdToName(garage) or garage
 end
 end
 end
 end
 -- Ensure niceLocation is always set
 if vehicle.location and not vehicle.niceLocation then
 vehicle.niceLocation = (bcm_garages and bcm_garages.getGarageDisplayName and bcm_garages.getGarageDisplayName(vehicle.location)) or vehicle.location
 end
 end
end

local function loadPurchasedGarages()
 if not career_career.isActive() then return end
 local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
 if not currentSavePath then return end

 local filePath = currentSavePath .. "/career/bcm/" .. saveFile
 local data = jsonReadFile(filePath) or {}
 purchasedGarages = data.garages or {}
 discoveredGarages = data.discovered or {}

 reloadRecoveryPrompt()
 buildGarageSizes()
 fillGarages()
end

local function onCareerModulesActivated()
 -- This fires inside the startFreeroam callback, after modules load.
 -- onWorldReadyState(2) has already passed, so we initialize here.
 loadPurchasedGarages()
 buildGarageSizes()

 -- BCM override: AFTER loading vanilla state from disk, sync BCM-owned garages.
 -- This must happen here (not in bcm_garages.onCareerModulesActivated) because
 -- BCM extensions fire first and loadPurchasedGarages() would overwrite their additions.
 if bcm_garages then
 bcm_garages.syncAllPurchasedGaragesWithVanilla()
 bcm_garages.grantStarterGarageIfNeeded()
 log("I", "garageManager", "BCM garages synced after vanilla load")
 end
end

local function computerIdToGarageId(computerId)
 local computer = freeroam_facilities.getFacility("computer", computerId)
 if computer then
 return computer.garageId
 end
 return nil
end

-- getGaragePrice: accepts either a garage object OR (garageId, computerId)
local function getGaragePrice(garageOrId, computerId)
 -- Case 1: Called with a garage object
 if type(garageOrId) == "table" then
 local garage = garageOrId
 return garage.starterGarage and 0 or garage.defaultPrice
 end

 -- Case 2: Called with garageId string (and optional computerId)
 local garageId = garageOrId
 if not garageId and not computerId then
 return nil
 end
 if not garageId and computerId then
 garageId = computerIdToGarageId(computerId)
 end
 if not garageId then
 return nil
 end
 local garage = freeroam_facilities.getFacility("garage", garageId)
 if garage then
 local price = garage.starterGarage and 0 or garage.defaultPrice
 return tonumber(price) * 0.75
 end
 return nil
end

local function showPurchaseGaragePrompt(garageId)
 if not career_career.isActive() then return end

 -- BCM: redirect to real estate website for BCM-defined garages
 if bcm_garages and bcm_garages.getGarageDefinition(garageId) then
 -- Open the computer menu first so computerFunctions is initialised;
 -- without this, the ChangeState→'computer' causes getComputerUIData()
 -- to crash because openMenu was never called.
 local computers = freeroam_facilities.getFacilitiesByType("computer")
 if computers then
 for _, computer in pairs(computers) do
 if computer.garageId == garageId then
 career_modules_computer.openMenu(computer, false)
 break
 end
 end
 end
 guihooks.trigger('BCMOpenXPWithIE', {
 url = 'http://belascorealty.com/listings?id=' .. garageId,
 restricted = true
 })
 return
 end

 garageToPurchase = freeroam_facilities.getFacility("garage", garageId)
 if not garageToPurchase then return end
 if getGaragePrice(garageToPurchase) == 0 then
 addPurchasedGarage(garageToPurchase.id)
 local computers = freeroam_facilities.getFacilitiesByType("computer")
 if computers then
 for _, computer in pairs(computers) do
 if computer.garageId == garageId then
 if career_modules_computer then
 career_modules_computer.openComputerMenuById(computer.id)
 end
 break
 end
 end
 end
 career_saveSystem.saveCurrent()
 return
 end
 guihooks.trigger('ChangeState', {state = 'purchase-garage'})
end

local function requestGarageData()
 local garage = garageToPurchase
 if garage then
 if translateLanguage then
 local translated = translateLanguage(garage.name, garage.name, true)
 if translated then garage.name = translated end
 end
 local garageData = {
 name = garage.name,
 price = getGaragePrice(garage),
 capacity = math.ceil(garage.capacity)
 }
 return garageData
 end
 return nil
end

local function canPay()
 if career_modules_cheats and career_modules_cheats.isCheatsMode and career_modules_cheats.isCheatsMode() then
 return true
 end
 if not garageToPurchase then return false end
 if not career_modules_playerAttributes then return false end
 local price = { money = { amount = getGaragePrice(garageToPurchase), canBeNegative = false } }
 for currency, info in pairs(price) do
 if not info.canBeNegative and career_modules_playerAttributes.getAttributeValue(currency) < info.amount then
 return false
 end
 end
 return true
end

local function buyGarage()
 if garageToPurchase then
 local price = { money = { amount = getGaragePrice(garageToPurchase), canBeNegative = false } }
 if career_modules_payment then
 local success = career_modules_payment.pay(price, { label = "Purchased " .. garageToPurchase.name })
 if success then
 addPurchasedGarage(garageToPurchase.id)
 career_saveSystem.saveCurrent()
 end
 end
 garageToPurchase = nil
 end
end

local function cancelGaragePurchase()
 guihooks.trigger('ChangeState', {state = 'play'})
 garageToPurchase = nil
end

local function getStoredLocations()
 if not career_modules_inventory then return {} end
 local vehicles = career_modules_inventory.getVehicles()
 if not vehicles then return {} end
 local storedLocation = {}
 for id, vehicle in pairs(vehicles) do
 if vehicle.location then
 if not storedLocation[vehicle.location] then
 storedLocation[vehicle.location] = {}
 end
 table.insert(storedLocation[vehicle.location], id)
 end
 end
 return storedLocation
end

local function getGarageCapacityData()
 buildGarageSizes()
 local storedLocation = getStoredLocations()
 local data = {}

 for garageId, owned in pairs(purchasedGarages) do
 if owned then
 local garage = freeroam_facilities.getFacility("garage", garageId)
 local capacity = garageSize[tostring(garageId)]
 if not capacity and garage and garage.capacity then
 capacity = math.ceil(garage.capacity)
 end
 local vehiclesInGarage = storedLocation[garageId]
 local count = vehiclesInGarage and #vehiclesInGarage or 0

 data[tostring(garageId)] = {
 id = garageId,
 name = garage and garage.name or tostring(garageId),
 capacity = capacity or 0,
 count = count
 }
 end
 end

 return data
end

local function getPurchasedGarages()
 local result = {}
 for garageId, _ in pairs(purchasedGarages) do
 table.insert(result, garageId)
 end
 return result
end

local function isGarageSpace(garage)
 if not garageSize[garage] then
 buildGarageSizes()
 if not garageSize[garage] then return {false, 0} end
 end
 local storedLocation = getStoredLocations()

 local carsInGarage
 if not storedLocation[garage] or not next(storedLocation[garage] or {}) then
 carsInGarage = 0
 else
 carsInGarage = #storedLocation[garage]
 end
 return {(garageSize[garage] - carsInGarage) > 0, garageSize[garage] - carsInGarage}
end

local function getFreeSlots()
 local totalCapacity = 0
 for garage, owned in pairs(purchasedGarages) do
 if not owned then goto continue end
 local space = isGarageSpace(garage)
 if space[1] then
 totalCapacity = totalCapacity + space[2]
 end
 ::continue::
 end
 return totalCapacity
end

local function garageIdToName(garageId)
 local garage = freeroam_facilities.getFacility("garage", garageId)
 if garage then
 return garage.name
 end
 return nil
end

local function canSellGarage(computerId)
 local garageId = computerIdToGarageId(computerId)
 if not garageId then return false end
 local garage = freeroam_facilities.getFacility("garage", garageId)
 if not garage then return false end
 if garage.starterGarage then return {false, 0} end

 local space = isGarageSpace(garageId)
 local capacity = math.ceil(garage.capacity)
 return {space[2] == capacity, capacity - space[2]}
end

local function sellGarage(computerId, sellPrice)
 local garageId = computerIdToGarageId(computerId)
 if not garageId then return false end
 local garage = freeroam_facilities.getFacility("garage", garageId)
 if not garage then return false end
 if garage.starterGarage then return false end

 guihooks.trigger('ChangeState', {state = 'play'})
 purchasedGarages[garageId] = nil
 reloadRecoveryPrompt()
 buildGarageSizes()
 local soldMessage = "Sold " .. (garage.name or garageId)
 if career_modules_payment then
 career_modules_payment.reward({ money = { amount = sellPrice } }, { label = soldMessage }, true)
 end
end

local function getNextAvailableSpace()
 for garage, owned in pairs(purchasedGarages) do
 if not owned then goto continue end
 if isGarageSpace(garage)[1] then
 return garage
 end
 ::continue::
 end
 return nil
end

local function onWorldReadyState(state)
 if state == 2 and career_career.isActive() then
 buildGarageSizes()
 fillGarages()
 purchaseDefaultGarage()
 end
end

M.onWorldReadyState = onWorldReadyState

M.purchaseDefaultGarage = purchaseDefaultGarage

M.showPurchaseGaragePrompt = showPurchaseGaragePrompt
M.requestGarageData = requestGarageData
M.canPay = canPay
M.buyGarage = buyGarage
M.cancelGaragePurchase = cancelGaragePurchase
M.getGaragePrice = getGaragePrice
M.canSellGarage = canSellGarage
M.sellGarage = sellGarage

M.getFreeSlots = getFreeSlots
M.onCareerModulesActivated = onCareerModulesActivated
M.isPurchasedGarage = isPurchasedGarage
M.getPurchasedGarages = getPurchasedGarages
M.addPurchasedGarage = addPurchasedGarage
M.addDiscoveredGarage = addDiscoveredGarage
M.isDiscoveredGarage = isDiscoveredGarage
M.loadPurchasedGarages = loadPurchasedGarages
M.savePurchasedGarages = savePurchasedGarages
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.garageIdToName = garageIdToName
M.computerIdToGarageId = computerIdToGarageId

M.isGarageSpace = isGarageSpace
M.getNextAvailableSpace = getNextAvailableSpace
M.buildGarageSizes = buildGarageSizes
M.fillGarages = fillGarages
M.getStoredLocations = getStoredLocations
M.getGarageCapacityData = getGarageCapacityData

return M
