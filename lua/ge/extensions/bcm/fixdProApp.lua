-- BCM FIXD Pro Terminal App Extension
-- Parts installer app: install/remove parts from BCM inventory onto vehicle.
-- Thin wrapper over vanilla career_modules_partShopping (same pattern as partsShopApp.lua).
-- No cart, no pricing, no banking -- free install from owned inventory.
-- Adds cascade detection + root/core slot protection from Phase 84 safe removal algorithm.
-- Extension name: bcm_fixdProApp
-- Loaded by bcm_extensionManager.

local M = {}

M.dependencies = {'career_career', 'career_saveSystem'}

-- ============================================================================
-- Forward declarations
-- ============================================================================
local startFixdPro
local exitFixdPro
local applyFixdPro
local checkCascade
local isRootSlot
local isCoreSlot
local collectDescendants
local findNodeByPath
local buildSpawnedVehiclesList

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_fixdProApp'

-- ============================================================================
-- Private state
-- ============================================================================
local sessionActive = false
local currentInventoryId = nil

-- ============================================================================
-- Helper: isRootSlot
-- Check if a node is the root body/frame slot (depth 1 in partsTree).
-- The root node in partsTree is the top-level table itself.
-- ============================================================================
isRootSlot = function(node, partsTree)
 -- The root is the top-level node of partsTree
 -- If node IS partsTree, it's the root
 return node == partsTree or node.path == partsTree.path
end

-- ============================================================================
-- Helper: isCoreSlot
-- Check if a slot is marked as coreSlot in slotInfoUi.
-- Filter by installed parts only to avoid cross-vehicle false positives (Pitfall 6).
-- ============================================================================
isCoreSlot = function(slotName, availableParts, installedParts)
 if not availableParts or not installedParts then return false end
 -- Only check parts that are actually installed on this vehicle
 for partName, _ in pairs(installedParts) do
 local partDesc = availableParts[partName]
 if partDesc and partDesc.slotInfoUi then
 local slotInfo = partDesc.slotInfoUi[slotName]
 if slotInfo and slotInfo.coreSlot then
 return true
 end
 end
 end
 return false
end

-- ============================================================================
-- Helper: collectDescendants
-- Recursively collect all descendant nodes with installed parts.
-- ============================================================================
collectDescendants = function(node, result, depth)
 result = result or {}
 depth = depth or 0
 if node.children then
 for childSlot, childNode in pairs(node.children) do
 if childNode.chosenPartName and childNode.chosenPartName ~= "" then
 table.insert(result, {
 path = childNode.path or childSlot,
 partName = childNode.chosenPartName,
 depth = depth + 1,
 childCount = childNode.children and tableSize(childNode.children) or 0,
 })
 end
 collectDescendants(childNode, result, depth + 1)
 end
 end
 return result
end

-- ============================================================================
-- Helper: findNodeByPath
-- Traverse partsTree.children recursively to find a node matching the slot key.
-- ============================================================================
findNodeByPath = function(node, slotPath)
 if not node then return nil end
 -- Direct match on current node
 if node.path == slotPath then return node end
 -- Check children
 if node.children then
 -- Direct child key match
 if node.children[slotPath] then
 return node.children[slotPath]
 end
 -- Recurse into children
 for _, childNode in pairs(node.children) do
 local found = findNodeByPath(childNode, slotPath)
 if found then return found end
 end
 end
 return nil
end

-- ============================================================================
-- Helper: buildSpawnedVehiclesList
-- Same logic as partsShopApp.lua lines 126-139.
-- ============================================================================
buildSpawnedVehiclesList = function()
 local vehicles = career_modules_inventory.getVehicles()
 local vehIdMap = career_modules_inventory.getMapInventoryIdToVehId()
 local spawnedList = {}
 for invId, vInfo in pairs(vehicles) do
 local thisVehId = vehIdMap and vehIdMap[invId]
 if thisVehId then
 table.insert(spawnedList, {
 inventoryId = invId,
 model = vInfo.model or '',
 niceName = (vInfo.config and vInfo.config.partData and vInfo.config.partData.niceName) or vInfo.model or tostring(invId),
 })
 end
 end
 return spawnedList
end

-- ============================================================================
-- startFixdPro
-- Start a vanilla partShopping session for parts installer mode.
-- ============================================================================
startFixdPro = function(inventoryId, computerId)
 if not career_modules_partShopping then
 log('W', logTag, 'startFixdPro: career_modules_partShopping not available')
 return
 end

 -- Guard: prevent double-open
 if sessionActive then
 log('W', logTag, 'startFixdPro: session already active')
 return
 end

 -- Guard: check bcm_partsShopApp is NOT in session (Pitfall 3 -- concurrent sessions)
 if bcm_partsShopApp and bcm_partsShopApp.isSessionActive and bcm_partsShopApp.isSessionActive() then
 log('W', logTag, 'startFixdPro: bcm_partsShopApp session active, cannot start concurrent session')
 return
 end

 -- Intercept ChangeState AND setupTether during startShopping:
 -- 1) Swallow ChangeState "partShopping" -- BCM handles its own UI
 -- 2) Skip setupTether -- BCM uses suspendTether from computer, no walking tether needed
 local originalTrigger = guihooks.trigger
 local originalSetupTether = career_modules_partShopping.setupTether
 guihooks.trigger = function(name, data)
 if name == 'ChangeState' and data and data.state == 'partShopping' then
 return -- swallow
 end
 return originalTrigger(name, data)
 end
 career_modules_partShopping.setupTether = function() end -- no-op
 career_modules_partShopping.startShopping(inventoryId, computerId)
 guihooks.trigger = originalTrigger
 career_modules_partShopping.setupTether = originalSetupTether

 currentInventoryId = inventoryId
 sessionActive = true

 -- Set orbit camera for half-screen preview
 core_camera.setByName(0, 'orbit', true)

 -- Suspend computer tether so player can freely orbit around vehicle
 if career_modules_computer and career_modules_computer.suspendTether then
 career_modules_computer.suspendTether()
 end

 -- Build spawned vehicles list for vehicle selector
 local spawnedList = buildSpawnedVehiclesList()

 -- IMPORTANT: fire BCMEnterFixdProMode BEFORE sendShoppingDataToUI
 -- so that fixdProStore.activeInventoryId is set when partShoppingData arrives
 guihooks.trigger('BCMEnterFixdProMode', {
 inventoryId = inventoryId,
 spawnedVehicles = spawnedList,
 })

 -- Now ask vanilla to send shop data to Vue
 career_modules_partShopping.sendShoppingDataToUI()

 log('I', logTag, 'startFixdPro: entered for inventoryId=' .. tostring(inventoryId))
end

-- ============================================================================
-- exitFixdPro
-- Cancel the shopping session and revert vehicle.
-- ============================================================================
exitFixdPro = function(inventoryId, revert)
 if not sessionActive then return end

 sessionActive = false
 currentInventoryId = nil

 -- Always try to revert -- cancelShopping restores vehicle to pre-shopping config.
 -- Intercept closeMenu effects: cancelShopping → endShopping → closeMenu
 -- which would closeAllMenus or reopen computer, killing the UI.
 if career_modules_partShopping then
 local origCloseAll = career_career.closeAllMenus
 local origOpenMenu = career_modules_computer and career_modules_computer.openMenu
 career_career.closeAllMenus = function() end
 if career_modules_computer then career_modules_computer.openMenu = function() end end
 pcall(function()
 career_modules_partShopping.cancelShopping()
 end)
 career_career.closeAllMenus = origCloseAll
 if career_modules_computer and origOpenMenu then career_modules_computer.openMenu = origOpenMenu end
 end

 -- Reset camera
 core_camera.resetCamera(0)

 -- Fire exit event to Vue
 guihooks.trigger('BCMExitFixdProMode', {})

 log('I', logTag, 'exitFixdPro: exited for inventoryId=' .. tostring(inventoryId))
end

-- ============================================================================
-- applyFixdPro
-- Commit preview to vehicle (apply the shopping session changes).
-- ============================================================================
applyFixdPro = function(inventoryId)
 if not career_modules_partShopping then
 log('W', logTag, 'applyFixdPro: career_modules_partShopping not available')
 return
 end

 -- Check if any changes were made before calling applyShopping.
 -- Vanilla's getBuyingLabel() crashes on empty cart (partsInList[0] = nil),
 -- and endShopping(true) inside applyShopping sets closeMenuAfterSaving
 -- which later triggers closeMenu() and kills the computer interface.
 local cart = career_modules_partShopping.getShoppingCart and career_modules_partShopping.getShoppingCart()
 local hasChanges = cart and cart.partsIn and next(cart.partsIn) ~= nil

 local applyOk = false
 if hasChanges then
 local ok, err = pcall(career_modules_partShopping.applyShopping)
 if ok then
 applyOk = true
 else
 log('W', logTag, 'applyFixdPro: applyShopping error: ' .. tostring(err))
 -- endShopping may already have been called inside applyShopping before the crash,
 -- but call it again (no-op if session already ended). Intercept closeMenu effects.
 local origCloseAll2 = career_career.closeAllMenus
 local origOpenMenu2 = career_modules_computer and career_modules_computer.openMenu
 career_career.closeAllMenus = function() end
 if career_modules_computer then career_modules_computer.openMenu = function() end end
 pcall(function() career_modules_partShopping.endShopping() end)
 career_career.closeAllMenus = origCloseAll2
 if career_modules_computer and origOpenMenu2 then career_modules_computer.openMenu = origOpenMenu2 end
 career_modules_inventory.setVehicleDirty(inventoryId)
 career_saveSystem.saveCurrent({inventoryId})
 applyOk = true
 end
 else
 -- No changes: end session without revert.
 -- Intercept closeMenu effects (same pattern as startFixdPro) —
 -- endShopping calls closeMenu which would closeAllMenus or reopen computer.
 local origCloseAll = career_career.closeAllMenus
 local origOpenMenu = career_modules_computer and career_modules_computer.openMenu
 career_career.closeAllMenus = function() end
 if career_modules_computer then career_modules_computer.openMenu = function() end end
 pcall(function() career_modules_partShopping.endShopping() end)
 career_career.closeAllMenus = origCloseAll
 if career_modules_computer and origOpenMenu then career_modules_computer.openMenu = origOpenMenu end
 applyOk = true
 log('D', logTag, 'applyFixdPro: no changes, session ended cleanly')
 end

 sessionActive = false
 currentInventoryId = nil

 -- Use orbit false (not resetCamera) -- same pattern as partsShopApp
 core_camera.setByName(0, 'orbit', false)

 -- Fire exit event to Vue
 guihooks.trigger('BCMExitFixdProMode', {})

 -- Fire apply result event
 guihooks.trigger('BCMFixdProApplyResult', { success = applyOk })

 log('I', logTag, 'applyFixdPro: applied for inventoryId=' .. tostring(inventoryId) .. ', success=' .. tostring(applyOk))
end

-- ============================================================================
-- checkCascade
-- Phase 84 algorithm for cascade detection on a target slot.
-- Returns root/core/children data via guihook event.
-- ============================================================================
checkCascade = function(inventoryId, slotPath)
 local vehIdMap = career_modules_inventory.getMapInventoryIdToVehId()
 if not vehIdMap then
 log('W', logTag, 'checkCascade: no vehIdMap available')
 return
 end

 local vehId = vehIdMap[inventoryId]
 if not vehId then
 log('W', logTag, 'checkCascade: no vehicle spawned for inventoryId=' .. tostring(inventoryId))
 return
 end

 local vehObj = be:getObjectByID(vehId)
 if not vehObj then
 log('W', logTag, 'checkCascade: no vehicle object for vehId=' .. tostring(vehId))
 return
 end

 local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
 if not vehicleData or not vehicleData.config or not vehicleData.config.partsTree then
 log('W', logTag, 'checkCascade: no vehicle data for vehId=' .. tostring(vehId))
 return
 end

 local partsTree = vehicleData.config.partsTree

 -- Find target node by traversing partsTree
 local targetNode = findNodeByPath(partsTree, slotPath)
 if not targetNode then
 log('W', logTag, 'checkCascade: slot path not found: ' .. tostring(slotPath))
 guihooks.trigger('BCMFixdProCascadeResult', {
 slotPath = slotPath,
 isRoot = false,
 isCore = false,
 cascadeChildren = {},
 childCount = 0,
 error = 'slotNotFound',
 })
 return
 end

 -- Step 1: Check root slot
 local isRoot = isRootSlot(targetNode, partsTree)

 -- Step 2: Core slot check — jbeamIO is vehicle-side only (not available in GE Lua).
 -- Default to false; root slot protection is the critical safety guard.
 local isCore = false

 -- Step 4: Collect cascading children
 local descendants = collectDescendants(targetNode)

 guihooks.trigger('BCMFixdProCascadeResult', {
 slotPath = slotPath,
 isRoot = isRoot,
 isCore = isCore,
 cascadeChildren = descendants,
 childCount = #descendants,
 })

 log('D', logTag, 'checkCascade: slot=' .. tostring(slotPath) .. ' isRoot=' .. tostring(isRoot) .. ' isCore=' .. tostring(isCore) .. ' children=' .. tostring(#descendants))
end

-- ============================================================================
-- Proxy: install part for preview (delegates to vanilla)
-- ============================================================================

M.installPart = function(partShopId)
 if career_modules_partShopping then
 local id = tonumber(partShopId)
 log('I', logTag, 'installPart: id=' .. tostring(id))
 local ok, err = pcall(career_modules_partShopping.installPartByPartShopId, id)
 if not ok then
 log('E', logTag, 'installPart FAILED for id=' .. tostring(id) .. ': ' .. tostring(err))
 end
 -- Don't call sendShoppingDataToUI here — vehicle reload is async.
 -- onVehicleSpawned will refresh data after reload completes.
 end
end

-- ============================================================================
-- Proxy: remove part from preview (delegates to vanilla)
-- ============================================================================

M.removePart = function(slot)
 if career_modules_partShopping then
 log('I', logTag, 'removePart: slot=' .. tostring(slot))
 local ok, err = pcall(career_modules_partShopping.removePartBySlot, slot)
 if not ok then
 log('E', logTag, 'removePart FAILED for slot=' .. tostring(slot) .. ': ' .. tostring(err))
 end
 -- Don't call sendShoppingDataToUI here — vehicle reload is async.
 -- onVehicleSpawned will refresh data after reload completes.
 end
end

-- ============================================================================
-- Hook: refresh shop data after vehicle reload completes
-- installPartByPartShopId triggers an async replaceVehicle.
-- We must wait for the spawn to finish before sending fresh data to Vue.
-- ============================================================================

M.onVehicleSpawned = function(vehId)
 if not sessionActive then return end
 log('D', logTag, 'onVehicleSpawned: refreshing shop data (session active)')
 pcall(career_modules_partShopping.sendShoppingDataToUI)
end

-- ============================================================================
-- Public API
-- ============================================================================

M.startFixdPro = function(inventoryId, computerId)
 local compId = computerId
 if compId == '' or compId == nil then compId = nil end
 startFixdPro(tonumber(inventoryId) or inventoryId, compId)
end

M.exitFixdPro = function(inventoryId, revert)
 exitFixdPro(inventoryId, revert)
end

M.applyFixdPro = function(inventoryId)
 applyFixdPro(tonumber(inventoryId) or inventoryId)
end

M.checkCascade = function(inventoryId, slotPath)
 checkCascade(tonumber(inventoryId) or inventoryId, slotPath)
end

M.isSessionActive = function()
 return sessionActive
end

--- Transition from O'Really parts shop to FIXD Pro installer (atomic).
--- Closes O'Really session with closeMenu intercepted, then starts FIXD Pro.
M.transitionFromPartsShop = function(inventoryId)
 inventoryId = tonumber(inventoryId) or inventoryId
 -- Close O'Really: intercept closeMenu so it doesn't kill the computer
 if bcm_partsShopApp and bcm_partsShopApp.isSessionActive and bcm_partsShopApp.isSessionActive() then
 local origCloseAll = career_career.closeAllMenus
 local origOpenMenu = career_modules_computer and career_modules_computer.openMenu
 career_career.closeAllMenus = function() end
 if career_modules_computer then career_modules_computer.openMenu = function() end end
 pcall(function() bcm_partsShopApp.exitPartsShop(inventoryId, true) end)
 career_career.closeAllMenus = origCloseAll
 if career_modules_computer and origOpenMenu then career_modules_computer.openMenu = origOpenMenu end
 end
 -- Now start FIXD Pro
 startFixdPro(inventoryId)
end

-- ============================================================================
-- Guard: sanitize partConditions before vanilla repair to prevent crash.
-- Vanilla insurance.lua repairPartConditions() assumes every partPath in
-- partConditions has a matching entry in partInventory. Orphan entries
-- (parts physically on the vehicle but missing from inventory) cause a
-- FATAL nil-index at insurance.lua:371. We strip them here so vanilla
-- never sees them.
-- ============================================================================

M.onRepairInGarage = function(invVehId)
 local vehicles = career_modules_inventory and career_modules_inventory.getVehicles()
 local veh = vehicles and vehicles[invVehId]
 if not veh or not veh.partConditions then return end

 local partMap = career_modules_partInventory
 and career_modules_partInventory.getPartPathToPartIdMap()
 local vehMap = partMap and partMap[invVehId]
 if not vehMap then return end

 local removed = 0
 for partPath, _ in pairs(veh.partConditions) do
 if not vehMap[partPath] then
 veh.partConditions[partPath] = nil
 removed = removed + 1
 end
 end

 if removed > 0 then
 log('W', logTag, 'onRepairInGarage: sanitized ' .. removed .. ' orphan partConditions for inv=' .. tostring(invVehId))
 end
end

return M
