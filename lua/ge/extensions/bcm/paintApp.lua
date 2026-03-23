-- BCM Paint App Extension
-- Paint tier gate and painting bridge for Vue: tier-gated paint data, live preview, apply/close.
-- Extension name: bcm_paintApp
-- Loaded by bcm_extensionManager after bcm_garages.

local M = {}

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
local getCurrentGarageTier
local startPaint
local previewAllSlotPaints
local previewPartPaint
local applyPaint
local closePaint

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_paintApp'

-- Session tracking for cleanup on unexpected exit (ESC, etc.)
local paintSessionActive = false
local paintSessionInventoryId = nil

-- Curated 16-color palette for T0/T1
local T0_PALETTE = {
 { name = "Arctic White", baseColor = {0.95, 0.95, 0.95, 1} },
 { name = "Bone", baseColor = {0.85, 0.82, 0.75, 1} },
 { name = "Silver", baseColor = {0.65, 0.65, 0.65, 1} },
 { name = "Anthracite", baseColor = {0.20, 0.20, 0.20, 1} },
 { name = "Pitch Black", baseColor = {0.04, 0.04, 0.04, 1} },
 { name = "Candy Red", baseColor = {0.80, 0.04, 0.04, 1} },
 { name = "Brick Red", baseColor = {0.50, 0.08, 0.05, 1} },
 { name = "Navy Blue", baseColor = {0.04, 0.10, 0.40, 1} },
 { name = "Cobalt Blue", baseColor = {0.08, 0.22, 0.75, 1} },
 { name = "Forest Green", baseColor = {0.05, 0.28, 0.08, 1} },
 { name = "Olive Drab", baseColor = {0.28, 0.29, 0.07, 1} },
 { name = "Sunflower Yellow", baseColor = {0.90, 0.78, 0.04, 1} },
 { name = "Pumpkin Orange", baseColor = {0.80, 0.30, 0.02, 1} },
 { name = "Grape Purple", baseColor = {0.28, 0.04, 0.45, 1} },
 { name = "Hot Pink", baseColor = {0.85, 0.08, 0.45, 1} },
 { name = "Brown", baseColor = {0.30, 0.15, 0.05, 1} },
}

-- Fixed T0 finish (low-gloss, cheap paint look)
local T0_FINISH = {
 metallic = 0,
 roughness = 0.25,
 clearcoat = 0.3,
 clearcoatRoughness = 0.8,
}

-- Paint class data for T2 (matches vanilla painting.lua colorClassData)
local COLOR_CLASSES = {
 semiGloss = { metallic = 0, roughness = 0.13 },
 gloss = { metallic = 0, roughness = 0 },
 semiMetallic = { metallic = 0.5, roughness = 0.5 },
 metallic = { metallic = 1, roughness = 0.5 },
 matte = { metallic = 0, roughness = 0.7 },
 chrome = { metallic = 1, roughness = 0 },
}

-- Slot painting prices (T0/T1 base price in dollars)
local SLOT_PRICE_BASE = 250

-- Per-part painting price (T1/T2 in dollars)
local PART_PRICE = 50

-- T2 vanilla pricing per class (in dollars, matching vanilla basePrices)
local T2_SLOT_PRICES = {
 factory = 600,
 semiGloss = 1000,
 gloss = 1500,
 semiMetallic = 1500,
 metallic = 2500,
 matte = 1800,
 chrome = 3400,
 custom = 4000,
}

-- ============================================================================
-- Helper functions
-- ============================================================================

-- Returns the garage tier for the given computerId, or 0 if not at an owned garage
getCurrentGarageTier = function(computerId)
 if not career_modules_garageManager or not bcm_properties then
 return 0
 end

 local garageId = career_modules_garageManager.computerIdToGarageId(computerId)
 if not garageId then
 return 0
 end

 local record = bcm_properties.getOwnedProperty(garageId)
 if not record then
 return 0
 end

 return record.tier or 0
end

-- ============================================================================
-- Paint mode entry
-- ============================================================================

-- Entry point for painting a vehicle
startPaint = function(inventoryId, computerId)
 if not career_modules_inventory then
 log('W', logTag, 'startPaint: career_modules_inventory not available')
 return
 end

 local tier = getCurrentGarageTier(computerId)

 -- Guard: vehicle must be spawned
 local vehIdMap = career_modules_inventory.getMapInventoryIdToVehId()
 local vehObjId = vehIdMap and vehIdMap[inventoryId]
 if not vehObjId then
 guihooks.trigger('BCMPaintError', { reason = 'vehicleNotSpawned' })
 log('W', logTag, 'startPaint: vehicle not spawned for inventoryId=' .. tostring(inventoryId))
 return
 end

 local garageId = career_modules_garageManager.computerIdToGarageId(computerId)

 -- Get current vehicle paint data
 local vehicleInfo = career_modules_inventory.getVehicles()[inventoryId]
 local currentPaints = {}
 local partConditions = {}

 if vehicleInfo then
 -- Read current paint slots from config
 if vehicleInfo.config and vehicleInfo.config.paints then
 currentPaints = deepcopy(vehicleInfo.config.paints)
 end

 -- Extract paintable parts from partConditions
 if vehicleInfo.partConditions then
 for partId, condition in pairs(vehicleInfo.partConditions) do
 if condition.visualState and condition.visualState.paint then
 partConditions[partId] = {
 paint = condition.visualState.paint,
 }
 end
 end
 end
 end

 -- Build nicename lookup for paintable parts
 -- Use jbeamIO.getAvailableParts (same source as vanilla partShopping)
 -- to get part descriptions like "Hood", "Front Left Door"
 local partNiceNames = {}
 local vehObj = be:getObjectByID(vehObjId)
 if vehObj then
 local vData = extensions.core_vehicle_manager.getVehicleData(vehObjId)
 if vData then
 -- Access jbeamIO through the correct extension path
 local jIO = extensions.jbeam_io or jbeamIO
 local availableParts = jIO and vData.ioCtx and jIO.getAvailableParts(vData.ioCtx)
 if availableParts then
 -- vdata.config.parts maps slotName → partName
 local configParts = (vData.vdata and vData.vdata.config and vData.vdata.config.parts) or {}
 for partPath, _ in pairs(partConditions) do
 -- Extract slot name from path: "/body/hood/" → "hood"
 local slotName = partPath:match('/([^/]+)/$')
 if slotName and configParts[slotName] then
 local partDesc = availableParts[configParts[slotName]]
 if type(partDesc) == 'table' and partDesc.description then
 partNiceNames[partPath] = partDesc.description
 end
 end
 end
 else
 log('W', logTag, 'startPaint: jbeamIO or ioCtx not available for nicenames')
 end
 end
 end

 -- Build slot prices based on tier
 local slotPrices = {}
 if tier >= 2 then
 slotPrices = T2_SLOT_PRICES
 else
 slotPrices = { base = SLOT_PRICE_BASE }
 end

 -- Get factory presets from vehicle model (vanilla pattern)
 local factoryPresets = {}
 local vehDetails = core_vehicles.getVehicleDetails(vehObjId)
 if vehDetails and vehDetails.model and vehDetails.model.paints then
 factoryPresets = vehDetails.model.paints
 end

 -- Build paint data for Vue
 local paintData = {
 tier = tier,
 garageId = garageId,
 inventoryId = inventoryId,
 vehObjId = vehObjId,
 currentPaints = currentPaints,
 partConditions = partConditions,
 t0Palette = T0_PALETTE,
 t0Finish = T0_FINISH,
 colorClasses = COLOR_CLASSES,
 slotPrices = slotPrices,
 partPrice = PART_PRICE,
 factoryPresets = factoryPresets,
 partNiceNames = partNiceNames,
 }

 -- Suspend computer tether so player can walk around vehicle
 if career_modules_computer and career_modules_computer.suspendTether then
 career_modules_computer.suspendTether()
 end

 -- Fire paint mode entry event to Vue
 guihooks.trigger('BCMEnterPaintMode', paintData)

 -- Set up orbit camera for paint viewing
 core_camera.setByName(0, "orbit", true)

 paintSessionActive = true
 paintSessionInventoryId = inventoryId

 log('I', logTag, 'startPaint: Entered paint mode for inventoryId=' .. tostring(inventoryId) .. ' at tier=' .. tier)
end

-- ============================================================================
-- Live preview
-- ============================================================================

-- Preview all 3 slot paints at once (live, before committing)
-- Receives the full 3-paint array from Vue, matching vanilla setPaints pattern
previewAllSlotPaints = function(inventoryId, allPaints)
 inventoryId = tonumber(inventoryId) or inventoryId
 if not career_modules_inventory then
 log('W', logTag, 'previewAllSlotPaints: career_modules_inventory not available')
 return
 end

 local vehIdMap = career_modules_inventory.getMapInventoryIdToVehId()
 local vehObjId = vehIdMap and vehIdMap[inventoryId]
 if not vehObjId then
 log('W', logTag, 'previewAllSlotPaints: no vehObjId for inventoryId=' .. tostring(inventoryId))
 return
 end

 -- Fill missing slots (vanilla pattern: copy from previous slot)
 for i = 1, 3 do
 if not allPaints[i] then
 allPaints[i] = allPaints[i - 1]
 end
 end

 -- Apply via core_vehicle_colors (same as vanilla setPaints)
 local cvc = extensions.core_vehicle_colors or core_vehicle_colors
 if cvc and cvc.setVehiclePaint then
 cvc.setVehiclePaint(1, allPaints[1], vehObjId)
 cvc.setVehiclePaint(2, allPaints[2], vehObjId)
 cvc.setVehiclePaint(3, allPaints[3], vehObjId)
 else
 log('W', logTag, 'previewAllSlotPaints: core_vehicle_colors NOT available!')
 end

 -- Also update part paints (vanilla pattern for visual refresh)
 local vehObj = be:getObjectByID(vehObjId)
 if vehObj then
 vehObj:queueLuaCommand(string.format("partCondition.setAllPartPaints(%s, 0)", serialize(allPaints)))
 end

 log('D', logTag, 'previewAllSlotPaints: Previewed all 3 slots for inventoryId=' .. tostring(inventoryId))
end

-- Preview a per-part paint change (T1/T2, live before committing)
-- paintObject is a single paint, we wrap it into 3-slot array for setPartPaints
previewPartPaint = function(inventoryId, partIdentifier, paintObject)
 inventoryId = tonumber(inventoryId) or inventoryId
 if not career_modules_inventory then return end

 local vehIdMap = career_modules_inventory.getMapInventoryIdToVehId()
 local vehObjId = vehIdMap and vehIdMap[inventoryId]
 if not vehObjId then return end

 local vehObj = be:getObjectByID(vehObjId)
 if not vehObj then return end

 -- setPartPaints expects an array of 3 paints (slots 1-3), fill all with same color
 local paintsArray = { paintObject, paintObject, paintObject }
 vehObj:queueLuaCommand(string.format("partCondition.setPartPaints(%q, %s, 0)", partIdentifier, serialize(paintsArray)))

 log('D', logTag, 'previewPartPaint: Previewed part ' .. tostring(partIdentifier) .. ' for inventoryId=' .. tostring(inventoryId))
end

-- ============================================================================
-- Apply paint
-- ============================================================================

-- Apply paint changes and deduct payment
-- partPaints is a table of { [partId] = paintObject } for per-part custom paints
applyPaint = function(inventoryId, paints, partPaints, totalCostCents)
 inventoryId = tonumber(inventoryId) or inventoryId
 if not career_modules_inventory or not bcm_banking then
 log('W', logTag, 'applyPaint: missing dependencies')
 return
 end

 -- Deduct payment
 local account = bcm_banking.getPersonalAccount()
 if not account then
 guihooks.trigger('BCMPaintResult', { success = false, reason = 'noAccount' })
 return
 end

 if totalCostCents > 0 then
 if (account.balance or 0) < totalCostCents then
 guihooks.trigger('BCMPaintResult', { success = false, reason = 'insufficientFunds' })
 return
 end
 bcm_banking.removeFunds(account.id, totalCostCents, 'paint', 'Vehicle Paint')
 end

 -- Fill missing slots (vanilla pattern)
 if tableSize(paints) < 3 then
 for i = tableSize(paints) + 1, 3 do
 paints[i] = paints[i - 1]
 end
 end

 -- Collect ALL per-part paints: merge new changes with existing custom paints from prior sessions
 local allPartPaints = {}
 local vehicleInfo = career_modules_inventory.getVehicles()[inventoryId]
 if vehicleInfo and vehicleInfo.partConditions then
 for partPath, partCondition in pairs(vehicleInfo.partConditions) do
 if partCondition.visualState and partCondition.visualState.paint and partCondition.visualState.paint.originalPaints then
 local existingPaints = partCondition.visualState.paint.originalPaints
 -- Check if this part had a custom paint (different from global slot paints)
 local currentGlobal = vehicleInfo.config and vehicleInfo.config.paints
 if existingPaints[1] and currentGlobal and currentGlobal[1] then
 local existBC = existingPaints[1].baseColor
 local globalBC = currentGlobal[1].baseColor
 if existBC and globalBC then
 local isDifferent = false
 for c = 1, 4 do
 if existBC[c] ~= globalBC[c] then isDifferent = true break end
 end
 if isDifferent then
 allPartPaints[partPath] = existingPaints[1]
 end
 end
 end
 end
 end
 end

 -- Override with new per-part changes from this session
 if partPaints and type(partPaints) == 'table' then
 for partId, paintObj in pairs(partPaints) do
 allPartPaints[partId] = paintObj
 end
 end

 -- Apply visual paint to vehicle (vanilla pattern)
 local vehIdMap = career_modules_inventory.getMapInventoryIdToVehId()
 local vehObjId = vehIdMap and vehIdMap[inventoryId]
 if vehObjId then
 local cvc = extensions.core_vehicle_colors or core_vehicle_colors
 if cvc and cvc.setVehiclePaint then
 cvc.setVehiclePaint(1, paints[1], vehObjId)
 cvc.setVehiclePaint(2, paints[2], vehObjId)
 cvc.setVehiclePaint(3, paints[3], vehObjId)
 end
 local vehObj = be:getObjectByID(vehObjId)
 if vehObj then
 vehObj:queueLuaCommand(string.format("partCondition.setAllPartPaints(%s, 0)", serialize(paints)))

 -- Re-apply ALL per-part paints (existing + new)
 for partId, paintObj in pairs(allPartPaints) do
 local paintsArray = { paintObj, paintObj, paintObj }
 vehObj:queueLuaCommand(string.format("partCondition.setPartPaints(%q, %s, 0)", partId, serialize(paintsArray)))
 end
 end
 end

 -- Build a clean paint object (avoid any metatable/serialization artifacts from Vue)
 local cleanPaint = {
 baseColor = {paints[1].baseColor[1], paints[1].baseColor[2], paints[1].baseColor[3], paints[1].baseColor[4] or 1},
 metallic = paints[1].metallic or 0,
 roughness = paints[1].roughness or 0.25,
 clearcoat = paints[1].clearcoat or 0.3,
 clearcoatRoughness = paints[1].clearcoatRoughness or 0.8,
 }
 local cleanPaints = {cleanPaint, cleanPaint, cleanPaint}

 -- Step 1: Update config.paints in memory
 vehicleInfo.config.paints = {cleanPaint, cleanPaint, cleanPaint}

 -- Step 2: Sync partConditions — exactly like the console command that worked
 local updatedCount = 0
 for partPath, partCondition in pairs(vehicleInfo.partConditions) do
 if partCondition.visualState and partCondition.visualState.paint then
 if allPartPaints[partPath] then
 local pp = allPartPaints[partPath]
 local cleanPartPaint = {
 baseColor = {pp.baseColor[1], pp.baseColor[2], pp.baseColor[3], pp.baseColor[4] or 1},
 metallic = pp.metallic or 0,
 roughness = pp.roughness or 0.25,
 clearcoat = pp.clearcoat or 0.3,
 clearcoatRoughness = pp.clearcoatRoughness or 0.8,
 }
 partCondition.visualState.paint.originalPaints = {cleanPartPaint, cleanPartPaint, cleanPartPaint}
 else
 partCondition.visualState.paint.originalPaints = {cleanPaint, cleanPaint, cleanPaint}
 end
 partCondition.visualState.paint.odometer = 0
 updatedCount = updatedCount + 1
 end
 end
 log('I', logTag, 'applyPaint: updated ' .. updatedCount .. ' partConditions with baseColor=' .. serialize(cleanPaint.baseColor))

 -- Step 3: Clear sessions BEFORE anything else
 paintSessionActive = false
 paintSessionInventoryId = nil

 -- Step 4: Notify Vue IMMEDIATELY (sets paintApplied flag, prevents onUnmounted revert)
 guihooks.trigger('BCMPaintResult', { success = true })

 -- Step 5: Spawn vehicle (reads updated config.paints + partConditions from memory)
 -- This is safe now because Vue's paintApplied flag prevents closePaint from being called
 career_modules_inventory.spawnVehicle(inventoryId, 2)

 -- Step 6: Mark dirty + save AFTER spawn
 career_modules_inventory.setVehicleDirty(inventoryId)
 career_saveSystem.saveCurrent({inventoryId})

 -- Step 7: Reset camera
 core_camera.resetCamera(0)

 log('I', logTag, 'applyPaint: paint[1]=' .. serialize(paints[1] and paints[1].baseColor or {}))

 local partCount = partPaints and tableSize(partPaints) or 0
 log('I', logTag, 'applyPaint: Applied paint for inventoryId=' .. tostring(inventoryId) .. ' cost=' .. tostring(totalCostCents) .. ' cents, partPaints=' .. tostring(partCount))
end

-- ============================================================================
-- Close paint mode
-- ============================================================================

-- Exit paint mode, reverting preview by respawning vehicle (vanilla pattern)
closePaint = function(inventoryId, revert)
 log('I', logTag, 'closePaint CALLED: inventoryId=' .. tostring(inventoryId) .. ' sessionActive=' .. tostring(paintSessionActive))
 inventoryId = tonumber(inventoryId) or inventoryId
 paintSessionActive = false
 paintSessionInventoryId = nil

 -- Respawn vehicle to revert any preview changes (vanilla painting.close pattern)
 if inventoryId and career_modules_inventory then
 log('I', logTag, 'closePaint: SPAWNING VEHICLE TO REVERT')
 career_modules_inventory.spawnVehicle(inventoryId, 2)
 end

 -- Reset camera
 core_camera.resetCamera(0)

 -- Fire exit event to Vue
 guihooks.trigger('BCMExitPaintMode', {})

 -- Close computer entirely (tether was suspended, player may have moved away)
 career_career.closeAllMenus()

 log('I', logTag, 'closePaint: Exited paint mode and closed computer')
end

-- ============================================================================
-- Public API (M table exports)
-- ============================================================================
-- Note: onComputerAddFunctions is NOT needed here — the painting.lua override
-- (overrides/career/modules/painting.lua) redirects the callback to
-- bcm_paintApp.startPaint directly. This avoids hook ordering issues.

M.startPaint = startPaint
M.previewAllSlotPaints = previewAllSlotPaints
M.previewPartPaint = previewPartPaint
M.applyPaint = applyPaint
M.closePaint = closePaint

return M
