-- BCM Vehicle Gallery App Extension
-- Provides consolidated vehicle data for the My Vehicles gallery window.
-- Gathers from inventory, properties, garageManager, dynoApp, and valueCalculator.
-- Extension name: bcm_vehicleGalleryApp

local M = {}

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
local getAllVehiclesForGallery
local getPerformanceClass
local getVehicleValue
local getVehiclePermissions
local computeMarketRangeDollars

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_vehicleGalleryApp'

-- ============================================================================
-- Helper functions
-- ============================================================================

-- Calculate performance class from peak HP
-- S: 500+, A: 300-499, B: 200-299, C: 100-199, D: 50-99, nil: <50 or no data
getPerformanceClass = function(peakHP)
  if not peakHP or peakHP <= 0 then return nil end
  if peakHP >= 500 then return "S" end
  if peakHP >= 300 then return "A" end
  if peakHP >= 200 then return "B" end
  if peakHP >= 100 then return "C" end
  if peakHP >= 50 then return "D" end
  return nil
end

-- Compute imprecise market range in dollars (shown to player instead of exact value)
computeMarketRangeDollars = function(valueDollars)
  if not valueDollars or valueDollars <= 0 then return nil end
  local roundTo
  if valueDollars < 5000 then roundTo = 250
  elseif valueDollars < 20000 then roundTo = 500
  elseif valueDollars < 100000 then roundTo = 1000
  else roundTo = 5000
  end
  local low = math.floor(valueDollars * 0.88 / roundTo) * roundTo
  local high = math.ceil(valueDollars * 1.12 / roundTo) * roundTo
  if high <= low then high = low + roundTo end
  return { low = math.max(0, low), high = high }
end

-- Get vehicle value safely using vanilla valueCalculator
getVehicleValue = function(inventoryId)
  if career_modules_valueCalculator and career_modules_valueCalculator.getInventoryVehicleValue then
    local ok, value = pcall(career_modules_valueCalculator.getInventoryVehicleValue, inventoryId)
    if ok and value then
      return value
    end
  end
  return nil
end

-- Get all permission data for a vehicle (mirrors vanilla inventory.getVehicleUiData)
getVehiclePermissions = function(inventoryId, vehicleInfo, currentGarageId)
  local perms = {}

  -- needsRepair (skip for vehicles still in delivery — no partConditions yet)
  if vehicleInfo.timeToAccess and vehicleInfo.timeToAccess > 0 then
    perms.needsRepair = false
  elseif career_modules_insurance_insurance and career_modules_insurance_insurance.inventoryVehNeedsRepair then
    local ok, result = pcall(career_modules_insurance_insurance.inventoryVehNeedsRepair, inventoryId)
    perms.needsRepair = ok and result or false
  else
    perms.needsRepair = false
  end

  -- Basic status from vehicleInfo
  perms.owned = vehicleInfo.owned ~= false
  perms.favorite = vehicleInfo.favorite or false
  perms.missingFile = vehicleInfo.missingFile or false
  perms.delayReason = vehicleInfo.delayReason
  perms.timeToAccess = vehicleInfo.timeToAccess

  -- Expedite repair cost
  if perms.delayReason == "repair" and career_modules_insurance_insurance then
    if career_modules_insurance_insurance.getQuickRepairExtraPrice then
      perms.quickRepairExtraPrice = career_modules_insurance_insurance.getQuickRepairExtraPrice()
    end
    if career_modules_insurance_insurance.getInvVehRepairTime then
      perms.initialRepairTime = career_modules_insurance_insurance.getInvVehRepairTime(inventoryId)
    end
    -- Calculate expedite cost from value and multiplier
    local vehValue = getVehicleValue(inventoryId) or 0
    local extraPrice = perms.quickRepairExtraPrice or 1
    perms.expediteRepairCost = math.floor(vehValue * extraPrice)
  end

  -- inStorage: vehicle not spawned = in storage
  local inventoryIdToVehId = career_modules_inventory.getMapInventoryIdToVehId and career_modules_inventory.getMapInventoryIdToVehId() or {}
  local vehId = inventoryIdToVehId[inventoryId]
  perms.inStorage = vehId == nil

  -- inGarage: vehicle is spawned and at the current garage
  perms.inGarage = false
  local inventoryIdsInGarage = {}
  if currentGarageId then
    inventoryIdsInGarage = career_modules_inventory.getInventoryIdsInClosestGarage and career_modules_inventory.getInventoryIdsInClosestGarage() or {}
    for _, gInvId in ipairs(inventoryIdsInGarage) do
      if gInvId == inventoryId then
        perms.inGarage = true
        break
      end
    end
  end

  -- atCurrentGarage: vehicle's location matches the current garage
  local vehicleLocation = vehicleInfo.location
  perms.atCurrentGarage = (currentGarageId and vehicleLocation == currentGarageId) or perms.inGarage

  -- otherVehicleInGarage: another vehicle is spawned in the current garage
  perms.otherVehicleInGarage = false
  for _, gInvId in ipairs(inventoryIdsInGarage) do
    if gInvId ~= inventoryId then
      perms.otherVehicleInGarage = true
      break
    end
  end

  -- License plate
  perms.licenseName = vehicleInfo.config and vehicleInfo.config.licenseName or ""

  -- Marketplace listing: check BCM player listings first, then vanilla
  perms.listedForSale = false
  if career_modules_bcm_marketplace and career_modules_bcm_marketplace.getPlayerListingByInventoryId then
    local playerListing = career_modules_bcm_marketplace.getPlayerListingByInventoryId(inventoryId)
    if playerListing then
      perms.listedForSale = true
    end
  end
  if not perms.listedForSale and career_modules_marketplace and career_modules_marketplace.findVehicleListing then
    perms.listedForSale = career_modules_marketplace.findVehicleListing(inventoryId) ~= nil
  end

  -- Permissions via permission system
  if career_modules_permissions and career_modules_permissions.getStatusForTag then
    perms.repairPermission = career_modules_permissions.getStatusForTag("vehicleRepair", {inventoryId = inventoryId})
    perms.sellPermission = career_modules_permissions.getStatusForTag("vehicleSelling", {inventoryId = inventoryId}) or {allow = true}
    perms.favoritePermission = career_modules_permissions.getStatusForTag("vehicleFavorite", {inventoryId = inventoryId})
    perms.storePermission = career_modules_permissions.getStatusForTag("vehicleStoring", {inventoryId = inventoryId})
    perms.licensePlateChangePermission = career_modules_permissions.getStatusForTag({"vehicleLicensePlate", "vehicleModification"}, {inventoryId = inventoryId})
    perms.returnLoanerPermission = career_modules_permissions.getStatusForTag("returnLoanedVehicle", {inventoryId = inventoryId})
  else
    local defaultPerm = {allow = true}
    perms.repairPermission = defaultPerm
    perms.sellPermission = defaultPerm
    perms.favoritePermission = defaultPerm
    perms.storePermission = defaultPerm
    perms.licensePlateChangePermission = defaultPerm
    perms.returnLoanerPermission = {allow = false}
  end

  return perms
end

-- ============================================================================
-- Main data gathering function
-- ============================================================================

-- Gather all vehicle data for the gallery UI and send via guihook.
-- Called from Vue when the My Vehicles window opens or refreshes.
getAllVehiclesForGallery = function()
  if not career_modules_inventory then
    log('W', logTag, 'getAllVehiclesForGallery: career_modules_inventory not available')
    guihooks.trigger('BCMVehicleGalleryData', { garages = {}, activeVehicleId = nil, totalVehicles = 0, emptyGarages = {} })
    return
  end

  local allVehicles = career_modules_inventory.getVehicles()
  if not allVehicles then
    log('W', logTag, 'getAllVehiclesForGallery: no vehicles data')
    guihooks.trigger('BCMVehicleGalleryData', { garages = {}, activeVehicleId = nil, totalVehicles = 0, emptyGarages = {} })
    return
  end

  -- Defensive: ensure all vehicles have originalParts/changedSlots so valueCalculator
  -- doesn't crash when vanilla sendDataToUi or getVehicleUiData is called.
  for _, vehInfo in pairs(allVehicles) do
    if not vehInfo.originalParts then
      vehInfo.originalParts = {}
    end
    if not vehInfo.changedSlots then
      vehInfo.changedSlots = {}
    end
  end

  -- Get garage capacity data — prefer BCM capacity (supports upgrades) over vanilla
  -- Phase 102 fix: include mapName for Vue nicename display; track which garages
  -- are backup-free on OTHER maps so we can hide empty cross-map backups later.
  local garageCapacity = {}
  local currentMap = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  if bcm_garages and bcm_properties then
    local allProps = bcm_properties.getAllOwnedProperties() or {}
    for _, prop in ipairs(allProps) do
      local gId = tostring(prop.id)
      local def = bcm_garages.getGarageDefinition and bcm_garages.getGarageDefinition(prop.id)
      local mapName = def and (def.mapName or def.levelName) or nil
      local isBackup = prop.type == "backup" or (def and def.isBackupGarage == true)
      local mapDisplayName = mapName and bcm_garages.getMapDisplayName and bcm_garages.getMapDisplayName(mapName) or nil
      garageCapacity[gId] = {
        id = prop.id,
        name = bcm_garages.getGarageDisplayName(prop.id) or prop.name or gId,
        capacity = bcm_garages.getCurrentCapacity(prop.id) or 0,
        mapName = mapName,
        mapDisplayName = mapDisplayName,
        isBackup = isBackup == true,
        isOtherMap = mapName and currentMap and tostring(mapName) ~= tostring(currentMap),
      }
    end
  elseif career_modules_garageManager and career_modules_garageManager.getGarageCapacityData then
    garageCapacity = career_modules_garageManager.getGarageCapacityData() or {}
  end

  -- Get active (spawned) vehicle
  local activeVehicleId = nil
  if career_modules_inventory.getCurrentVehicle then
    local currentInvId = career_modules_inventory.getCurrentVehicle()
    if currentInvId then
      activeVehicleId = tostring(currentInvId)
    end
  end

  -- Get pending vehicle transfers
  local vehicleTransfers = {}
  if bcm_properties and bcm_properties.getVehicleTransfers then
    vehicleTransfers = bcm_properties.getVehicleTransfers() or {}
  end

  -- Get current garage ID (closest to player)
  local currentGarageId = nil
  if career_modules_inventory.getClosestGarage then
    local closestGarage = career_modules_inventory.getClosestGarage()
    currentGarageId = closestGarage and closestGarage.id
  end

  -- Get origin computer ID (for repair menu etc.)
  local originComputerId = nil
  if career_modules_computer and career_modules_computer.getComputerId then
    originComputerId = career_modules_computer.getComputerId()
  end

  -- Get player money
  local playerMoney = 0
  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue then
    playerMoney = career_modules_playerAttributes.getAttributeValue("money") or 0
  end

  -- Build garage-grouped vehicle data
  local garages = {}
  local totalVehicles = 0

  for inventoryId, vehicleInfo in pairs(allVehicles) do
    -- BCM: skip non-owned vehicles (loaners) — they are not player property
    if vehicleInfo.owned == false then goto continueGallery end

    local invIdStr = tostring(inventoryId)
    totalVehicles = totalVehicles + 1

    -- Determine which garage this vehicle is in
    local garageId = vehicleInfo.location or "unknown"

    -- Check if in transit
    local transfer = vehicleTransfers[invIdStr]
    local isInTransit = transfer ~= nil
    local transitEta = nil
    local transitDestination = nil
    if isInTransit and transfer then
      -- Use destination garage for grouping
      garageId = transfer.toGarageId or garageId
      transitDestination = transfer.toGarageId
      if transfer.completionTime then
        local now = os.time()
        local remaining = transfer.completionTime - now
        if remaining > 0 then
          transitEta = math.ceil(remaining / 60) -- minutes remaining
        else
          transitEta = 0
        end
      end
    end

    -- Get thumbnail
    local thumbnail = nil
    if career_modules_inventory.getVehicleThumbnail then
      thumbnail = career_modules_inventory.getVehicleThumbnail(inventoryId)
      if thumbnail and vehicleInfo.dirtyDate then
        thumbnail = thumbnail .. "?" .. tostring(vehicleInfo.dirtyDate)
      end
    end

    -- Get dyno data (latest run)
    local hasDynoData = false
    local peakHP = 0
    local peakTorque = 0
    local weightKg = 0
    if bcm_dynoApp and bcm_dynoApp.getLatestDynoRun then
      local latestRun = bcm_dynoApp.getLatestDynoRun(invIdStr)
      if latestRun then
        hasDynoData = true
        peakHP = latestRun.peakHP or 0
        peakTorque = latestRun.peakTorque or 0
        weightKg = latestRun.weightKg or 0
      end
    end

    -- Get base HP and weight from the vehicle's config info (info_{config}.json data)
    local configHP = 0
    local configWeightKg = 0
    local modelKey = vehicleInfo.model_key
    if modelKey and vehicleInfo.config and vehicleInfo.config.partConfigFilename then
      local _, configKey = path.splitWithoutExt(vehicleInfo.config.partConfigFilename)
      if configKey then
        local configData = core_vehicles and core_vehicles.getConfig(modelKey, configKey)
        if configData then
          if configData.Power then
            configHP = math.floor(configData.Power)
          end
          if configData.Weight then
            configWeightKg = math.floor(configData.Weight)
          end
        end
      end
    end

    -- Get vehicle value
    local vehicleValue = getVehicleValue(inventoryId)

    -- Get garage name
    local garageName = garageId
    if garageCapacity[tostring(garageId)] then
      garageName = garageCapacity[tostring(garageId)].name or garageId
    elseif career_modules_garageManager and career_modules_garageManager.garageIdToName then
      garageName = career_modules_garageManager.garageIdToName(garageId) or garageId
    end

    -- Get permissions and status data for this vehicle
    local perms = getVehiclePermissions(inventoryId, vehicleInfo, currentGarageId)

    -- Build vehicle entry
    local vehicleEntry = {
      inventoryId = invIdStr,
      niceName = vehicleInfo.niceName or "Unknown Vehicle",
      thumbnail = thumbnail,
      garageId = garageId,
      garageName = garageName,
      isActive = (invIdStr == activeVehicleId),
      isInTransit = isInTransit,
      transitEta = transitEta,
      transitDestination = transitDestination,
      hasDynoData = hasDynoData,
      peakHP = peakHP,
      peakTorque = peakTorque,
      weightKg = weightKg,
      configHP = configHP,
      configWeightKg = configWeightKg,
      performanceClass = getPerformanceClass(hasDynoData and peakHP or configHP),
      currentValue = vehicleValue,
      marketRange = computeMarketRangeDollars(vehicleValue),
      -- Permission/status fields for options menu
      needsRepair = perms.needsRepair,
      owned = perms.owned,
      favorite = perms.favorite,
      missingFile = perms.missingFile,
      delayReason = perms.delayReason,
      timeToAccess = perms.timeToAccess,
      expediteRepairCost = perms.expediteRepairCost,
      inStorage = perms.inStorage,
      inGarage = perms.inGarage,
      licenseName = perms.licenseName,
      listedForSale = perms.listedForSale,
      repairPermission = perms.repairPermission,
      sellPermission = perms.sellPermission,
      favoritePermission = perms.favoritePermission,
      storePermission = perms.storePermission,
      licensePlateChangePermission = perms.licensePlateChangePermission,
      returnLoanerPermission = perms.returnLoanerPermission,
      atCurrentGarage = perms.atCurrentGarage,
      otherVehicleInGarage = perms.otherVehicleInGarage,
    }

    -- Group by garage
    local garageKey = tostring(garageId)
    if not garages[garageKey] then
      local cap = garageCapacity[garageKey]
      garages[garageKey] = {
        id = garageId,
        name = garageName,
        mapName = cap and cap.mapName or nil,
        mapDisplayName = cap and cap.mapDisplayName or nil,
        capacity = cap and cap.capacity or 0,
        vehicleCount = 0,
        vehicles = {}
      }
    end

    garages[garageKey].vehicleCount = garages[garageKey].vehicleCount + 1
    table.insert(garages[garageKey].vehicles, vehicleEntry)
    ::continueGallery::
  end

  -- Collect empty garages (owned but no vehicles).
  -- Phase 102 fix: hide backup-free garages from OTHER maps when empty — they
  -- clutter My Vehicles with sections like "Portofino" when the player is in WCUSA
  -- and has never parked a car there. Show them only if they have vehicles.
  local emptyGarages = {}
  for garageIdStr, capData in pairs(garageCapacity) do
    if not garages[garageIdStr] then
      -- Skip empty backup garages on other maps
      if not (capData.isBackup and capData.isOtherMap) then
        table.insert(emptyGarages, {
          id = capData.id,
          name = capData.name,
          mapName = capData.mapName,
          mapDisplayName = capData.mapDisplayName,
          capacity = capData.capacity
        })
      end
    end
  end

  -- Send data to Vue
  local payload = {
    garages = garages,
    activeVehicleId = activeVehicleId,
    totalVehicles = totalVehicles,
    emptyGarages = emptyGarages,
    originComputerId = originComputerId,
    playerMoney = playerMoney,
    currentGarageId = currentGarageId,
    currentGarageTier = (currentGarageId and bcm_properties and bcm_properties.getOwnedProperty) and (function() local r = bcm_properties.getOwnedProperty(currentGarageId) return r and r.tier or 0 end)() or 0,
    currentGarageHasSpace = currentGarageId and bcm_garages and bcm_garages.getFreeSlots and (bcm_garages.getFreeSlots(currentGarageId) or 0) > 0 or false,
  }

  guihooks.trigger('BCMVehicleGalleryData', payload)
  log('I', logTag, 'getAllVehiclesForGallery: Sent ' .. tostring(totalVehicles) .. ' vehicles across ' .. tostring(tableSize(garages)) .. ' garages')
end

-- ============================================================================
-- Vehicle action functions (called from Vue, delegate to vanilla)
-- Replicate vanilla spawnVehicleAndTeleportToGarage logic using public APIs
-- ============================================================================

-- Retrieve: spawn + fade + teleport to garage parking (mirrors vanilla Retrieve button)
local function retrieveVehicle(inventoryId)
  local closestGarage = career_modules_inventory.getClosestGarage()
  if not closestGarage then
    log('W', logTag, 'retrieveVehicle: no closest garage')
    return
  end

  -- Remove existing physical instance if already spawned (prevents duplication)
  local existingVehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
  if existingVehId then
    career_modules_inventory.removeVehicleObject(inventoryId)
  end

  ui_fadeScreen.start(0.5)
  career_modules_inventory.spawnVehicle(inventoryId, nil, function()
    local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
    if not vehId then
      ui_fadeScreen.stop(0.5)
      return
    end
    local vehObj = be:getObjectByID(vehId)
    if not vehObj then
      ui_fadeScreen.stop(0.5)
      return
    end

    freeroam_facilities.teleportToGarage(closestGarage.id, vehObj, false)

    if career_modules_fuel and career_modules_fuel.minimumRefuelingCheck then
      career_modules_fuel.minimumRefuelingCheck(vehObj:getId())
    end

    career_modules_inventory.setVehicleDirty(inventoryId)
    ui_fadeScreen.stop(0.5)

    -- Refresh computer data so all modules (paint, tuning, CARamp, etc.) detect the new vehicle
    if career_modules_computer and career_modules_computer.refreshComputerData then
      career_modules_computer.refreshComputerData()
    end

    -- Refresh gallery so Vue sees the vehicle as spawned without reopening the computer
    getAllVehiclesForGallery()

    log('I', logTag, 'retrieveVehicle: spawned ' .. tostring(inventoryId) .. ' in garage ' .. closestGarage.id)
  end)
end

-- Replace: remove other vehicles from garage, then spawn + teleport (mirrors vanilla Replace button)
local function replaceWithVehicle(inventoryId)
  local closestGarage = career_modules_inventory.getClosestGarage()
  if not closestGarage then return end

  -- Remove other vehicles from garage (same as vanilla removeVehiclesFromGarageExcept)
  local inventoryIdsInGarage = career_modules_inventory.getInventoryIdsInClosestGarage() or {}
  for _, gInvId in ipairs(inventoryIdsInGarage) do
    if gInvId ~= inventoryId then
      career_modules_inventory.removeVehicleObject(gInvId)
    end
  end

  ui_fadeScreen.start(0.5)
  career_modules_inventory.spawnVehicle(inventoryId, nil, function()
    local vehId = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
    if not vehId then
      ui_fadeScreen.stop(0.5)
      return
    end
    local vehObj = be:getObjectByID(vehId)
    if not vehObj then
      ui_fadeScreen.stop(0.5)
      return
    end

    freeroam_facilities.teleportToGarage(closestGarage.id, vehObj, false)

    if career_modules_fuel and career_modules_fuel.minimumRefuelingCheck then
      career_modules_fuel.minimumRefuelingCheck(vehObj:getId())
    end

    career_modules_inventory.setVehicleDirty(inventoryId)
    ui_fadeScreen.stop(0.5)

    -- Refresh computer data so all modules detect the new vehicle
    if career_modules_computer and career_modules_computer.refreshComputerData then
      career_modules_computer.refreshComputerData()
    end

    -- Refresh gallery
    getAllVehiclesForGallery()

    log('I', logTag, 'replaceWithVehicle: spawned ' .. tostring(inventoryId) .. ', replaced others in ' .. closestGarage.id)
  end)
end

-- Deliver: transfer a vehicle from another garage to the current one ($50 = 5000 cents)
-- Implemented directly because vanilla inventory may not export deliverVehicle.
-- skipSpaceCheck: when true, skip garage capacity check (used by deliverAndReplace)
local function deliverVehicle(inventoryId, skipSpaceCheck)
  local vehicles = career_modules_inventory.getVehicles()
  local vehicleInfo = vehicles and vehicles[inventoryId]
  if not vehicleInfo then
    log('W', logTag, 'deliverVehicle: vehicle not found: ' .. tostring(inventoryId))
    return
  end

  local closestGarage = career_modules_inventory.getClosestGarage()
  if not closestGarage then
    log('W', logTag, 'deliverVehicle: no closest garage')
    return
  end

  -- Check garage has space (unless replacing)
  if not skipSpaceCheck then
    local freeSlots = bcm_garages and bcm_garages.getFreeSlots and bcm_garages.getFreeSlots(closestGarage.id) or 0
    if freeSlots <= 0 then
      log('W', logTag, 'deliverVehicle: no space in garage ' .. closestGarage.id)
      ui_message("No space available in this garage.", nil, "vehicleInventory")
      return
    end
  end

  -- Charge delivery fee ($50 = 5000 cents)
  if career_modules_payment and career_modules_payment.pay then
    local price = {money = {amount = 5000, canBeNegative = true}}
    career_modules_payment.pay(price, {label = "Vehicle delivery to garage", tags = {"delivery"}})
  end

  -- Remember origin garage before moving
  local originGarageId = vehicleInfo.location

  -- Move vehicle location to current garage
  vehicleInfo.location = closestGarage.id
  if career_modules_garageManager and career_modules_garageManager.garageIdToName then
    vehicleInfo.niceLocation = career_modules_garageManager.garageIdToName(closestGarage.id)
  end

  -- Set delivery delay (120 seconds) — vanilla onUpdate loop decrements timeToAccess each frame
  vehicleInfo.timeToAccess = 120
  vehicleInfo.delayReason = "delivery"

  if career_modules_inventory.setVehicleDirty then
    career_modules_inventory.setVehicleDirty(inventoryId)
  end

  log('I', logTag, 'deliverVehicle: delivering inv=' .. tostring(inventoryId) .. ' from ' .. tostring(originGarageId) .. ' to ' .. closestGarage.id)
  getAllVehiclesForGallery()
end

-- Deliver and replace: swap the delivered vehicle with one already at the current garage.
-- Moves the replaced vehicle back to the origin garage of the delivered vehicle.
local function deliverAndReplaceVehicle(inventoryId)
  local allVehicles = career_modules_inventory.getVehicles()
  local vehicleInfo = allVehicles and allVehicles[inventoryId]
  if not vehicleInfo then return end

  local closestGarage = career_modules_inventory.getClosestGarage()
  if not closestGarage then return end

  -- Remember origin garage so we can swap the replaced vehicle there
  local originGarageId = vehicleInfo.location

  -- Despawn other vehicles in garage and move them to the origin garage (swap)
  local inventoryIdsInGarage = career_modules_inventory.getInventoryIdsInClosestGarage() or {}
  for _, gInvId in ipairs(inventoryIdsInGarage) do
    if gInvId ~= inventoryId then
      career_modules_inventory.removeVehicleObject(gInvId)
      -- Swap: move replaced vehicle to the delivering vehicle's origin garage
      if originGarageId and allVehicles[gInvId] then
        allVehicles[gInvId].location = originGarageId
        if career_modules_garageManager and career_modules_garageManager.garageIdToName then
          allVehicles[gInvId].niceLocation = career_modules_garageManager.garageIdToName(originGarageId)
        end
        if career_modules_inventory.setVehicleDirty then
          career_modules_inventory.setVehicleDirty(gInvId)
        end
        log('I', logTag, 'deliverAndReplace: swapped inv=' .. tostring(gInvId) .. ' to ' .. tostring(originGarageId))
      end
    end
  end

  -- Refresh computer data so desktop icons update (vehicle was despawned)
  if career_modules_computer and career_modules_computer.refreshComputerData then
    career_modules_computer.refreshComputerData()
  end

  -- Deliver (skip space check — we just freed a slot)
  deliverVehicle(inventoryId, true)
end

-- Store vehicle: despawn and refresh computer so desktop icons update
local function storeVehicle(inventoryId)
  career_modules_inventory.removeVehicleObject(inventoryId)

  if career_modules_computer and career_modules_computer.refreshComputerData then
    career_modules_computer.refreshComputerData()
  end

  getAllVehiclesForGallery()
  log('I', logTag, 'storeVehicle: stored inv=' .. tostring(inventoryId))
end

-- Open repair screen (delegates to vanilla repair screen with originComputerId)
local function openRepairScreen(inventoryId, originComputerId)
  if not career_modules_insurance_repairScreen then return end
  -- Build vehicle data matching what vanilla passes (getVehicleUiData format)
  local vehData = career_modules_inventory.getVehicleUiData(inventoryId)
  if vehData then
    career_modules_insurance_repairScreen.openRepairMenu(vehData, originComputerId)
  end
end

-- Open performance index screen
local function openPerformanceIndex(inventoryId, originComputerId)
  if career_modules_vehiclePerformance and career_modules_vehiclePerformance.openMenu then
    career_modules_vehiclePerformance.openMenu({inventoryId = inventoryId, computerId = originComputerId})
  end
end

-- Sell data helper — delegates to marketplaceApp (Phase 50)
local function getVehicleSellData(inventoryId)
  if bcm_marketplaceApp and bcm_marketplaceApp.getVehicleSellData then
    return bcm_marketplaceApp.getVehicleSellData(inventoryId)
  end
end

-- ============================================================================
-- Lifecycle: patch vehicles missing 'year' to prevent valueCalculator crash
-- (vanilla valueCalculator.lua does arithmetic on vehicle.year without nil guard)
-- ============================================================================

local function onCareerModulesActivated()
  if not career_modules_inventory or not career_modules_inventory.getVehicles then return end
  local vehicles = career_modules_inventory.getVehicles()
  if not vehicles then return end
  local patched = 0
  for invId, veh in pairs(vehicles) do
    local touched = false
    if not veh.year then
      veh.year = 2023
      touched = true
    end
    if not veh.changedSlots then
      veh.changedSlots = {}
      touched = true
    end
    if not veh.originalParts then
      veh.originalParts = {}
      touched = true
    end
    if touched then patched = patched + 1 end
  end
  if patched > 0 then
    log('I', logTag, 'Patched ' .. patched .. ' vehicle(s) missing year/changedSlots/originalParts fields')
  end
end

-- ============================================================================
-- Public API
-- ============================================================================

M.getVehicleSellData = getVehicleSellData
M.getAllVehiclesForGallery = getAllVehiclesForGallery
M.retrieveVehicle = retrieveVehicle
M.replaceWithVehicle = replaceWithVehicle
M.deliverVehicle = deliverVehicle
M.deliverAndReplaceVehicle = deliverAndReplaceVehicle
M.storeVehicle = storeVehicle
M.openRepairScreen = openRepairScreen
M.openPerformanceIndex = openPerformanceIndex
M.onCareerModulesActivated = onCareerModulesActivated

-- Patch newly added vehicles (e.g. career starter Miramar) that bypass vehicleShopping
-- and therefore never get changedSlots/originalParts initialized.
-- Vanilla insurance.lua crashes on repair if these are nil.
M.onVehicleAdded = function(inventoryId)
  if not career_modules_inventory or not career_modules_inventory.getVehicles then return end
  local veh = career_modules_inventory.getVehicles()[inventoryId]
  if not veh then return end
  local patched = false
  if not veh.changedSlots then veh.changedSlots = {}; patched = true end
  if not veh.originalParts then veh.originalParts = {}; patched = true end
  if not veh.year then veh.year = 2023; patched = true end
  if patched then
    log('I', logTag, 'onVehicleAdded: patched missing fields for inventoryId=' .. tostring(inventoryId))
  end
end

return M
