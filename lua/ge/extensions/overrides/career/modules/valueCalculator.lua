-- BCM Override: career/modules/valueCalculator
-- Fixes vanilla crash: getPartValue uses part.year which doesn't exist on inventory parts.
-- Vanilla valueCalculator with nil-safety guards.

local M = {}

M.dependencies = {'career_career'}

local lossPerKmRelative = 0.0000050
local scrapValueRelative = 0.5

-- vehicle damage related variables
local repairTimePerPart = 60
local brokenPartsThreshold = 3
local minimumCarValue = 500
local minimumCarValueRelativeToNew = 0.05

local function getPartNamesFromTree(Tree)
  local partNames = {}
  for _, part in ipairs(Tree) do
    if part.children then
      local result = getPartNamesFromTree(part.children)
      if result then
        for _, partName in ipairs(result) do
          table.insert(partNames, partName)
        end
      end
    else
      table.insert(partNames, part.chosenPartName)
    end
  end
  return partNames
end

local function getVehicleMileageById(inventoryId)
  local vehicles = career_modules_inventory.getVehicles()
  if not vehicles or not vehicles[inventoryId] then return 0 end
  return vehicles[inventoryId].mileage or 0
end

local function getDepreciation(year, power)
  local powerFactor = 1.0 + (power - 300) * (4.04 - 1.0) / (808 - 300)
  local depreciation = 1
  local isSlowCar = power < 275

  for i = 1, year do
    if i == 1 then
      depreciation = depreciation * (1 - 0.05 * (1 / powerFactor))
    elseif i == 2 then
      depreciation = depreciation * (1 - 0.10 * (1 / powerFactor))
    elseif i <= 6 then
      depreciation = depreciation * (1 - 0.03 * math.exp(-0.15 * (i - 2)) * (1 / powerFactor))
    elseif i <= 12 then
      depreciation = depreciation * (1 - 0.05 * math.exp(-0.15 * (i - 2)) * (1 / powerFactor))
    elseif i <= 20 then
      depreciation = depreciation * (1 + 0.01 * math.exp(0.03 * (i - 12)) * (1.15 * powerFactor))
    elseif i <= 30 then
      depreciation = depreciation * (1 + 0.015 * math.exp(0.01 * (i - 20)) * (1.2 * powerFactor))
    else
      depreciation = depreciation * (1 - 0.01 * math.exp(-0.05 * (i - 30)) * (1 / powerFactor))
    end

    if isSlowCar then
      depreciation = depreciation * 0.975
    end
  end

  return depreciation
end

local function getValueByAge(value, age, power)
  if power == nil then power = 300 end
  if value == nil or type(value) ~= "number" then value = 10000 end
  return value * getDepreciation(age, power)
end

local function getAdjustedVehicleBaseValue(value, vehicleCondition)
  local valueByAge = getValueByAge(value, vehicleCondition.age)
  local scrapValue = valueByAge * scrapValueRelative
  local valueLossFromMileage = valueByAge * (vehicleCondition.mileage or 0) / 1000 * lossPerKmRelative
  local valueTemp = math.max(0, valueByAge - valueLossFromMileage)
  valueTemp = math.max(valueTemp, scrapValue)
  return valueTemp
end

local function getPartDifference(originalParts, newParts, changedSlots)
  local addedParts = {}
  local removedParts = {}
  if not originalParts then return addedParts, removedParts end
  for slotName, oldPart in pairs(originalParts) do
    if newParts then
      local newPart = newParts[slotName]
      if newPart ~= oldPart.name then
        if oldPart.name ~= "" then
          removedParts[slotName] = oldPart.name
        end
        if newPart ~= "" then
          addedParts[slotName] = newPart
        end
      end
    end
  end

  for slotName, newPart in pairs(newParts or {}) do
    local oldPart = originalParts[slotName]
    if newPart ~= "" then
      if not oldPart then
        addedParts[slotName] = newPart
      end
      if changedSlots and changedSlots[slotName] and oldPart and newPart == oldPart.name then
        addedParts[slotName] = newPart
        removedParts[slotName] = originalParts[slotName]
      end
    end
  end

  return addedParts, removedParts
end

local function getDepreciatedPartValue(value, mileage)
  mileage = mileage and mileage / 1609.344 or 0
  if mileage < 50 then
    return value
  end

  local quickCut = 0.75
  local milesOver50 = mileage - 50
  local thousands = milesOver50 / 1500
  local slowFactor = math.pow(0.99, thousands)

  local rawValue = value * quickCut * slowFactor
  local minFraction = 0.10
  local minValue = value * minFraction

  local result = math.max(rawValue, minValue)
  if career_modules_hardcore and career_modules_hardcore.isHardcoreMode and career_modules_hardcore.isHardcoreMode() then
    result = result * 0.66
  end
  return result
end

-- BCM fix: uses only mileage + value, NOT part.year (which doesn't exist on inventory parts)
local function getPartValue(part)
  local mileage = part.partCondition and part.partCondition.odometer or 0
  local baseValue = part.value or 0
  return getDepreciatedPartValue(baseValue, mileage)
end

local function getDamagedParts(vehInfo)
  local damagedParts = {
    partsToBeReplaced = {}
  }

  local function traversePartsTree(node)
    if not node.partPath then return end
    if not vehInfo.partConditions then return end

    local partCondition = vehInfo.partConditions[node.partPath]
    if not partCondition then return end

    if partCondition.integrityValue and partCondition.integrityValue == 0 then
      local part = career_modules_partInventory.getPart(vehInfo.id, node.path)
      if part then
        table.insert(damagedParts.partsToBeReplaced, part)
      end
    end

    if node.children then
      for childSlotName, childNode in pairs(node.children) do
        traversePartsTree(childNode)
      end
    end
  end

  if vehInfo.config and vehInfo.config.partsTree then
    traversePartsTree(vehInfo.config.partsTree)
  end

  return damagedParts
end

local function getRepairDetails(invVehInfo)
  local details = {
    price = 0,
    repairTime = 0,
    partsCountToBeReplaced = 0
  }

  local damagedParts = getDamagedParts(invVehInfo)
  for _, part in pairs(damagedParts.partsToBeReplaced) do
    local price = part.value or 700
    if career_modules_hardcore and career_modules_hardcore.isHardcoreMode and career_modules_hardcore.isHardcoreMode() then
      details.price = math.floor((details.price + price * 1.25) * 100) / 100
    else
      details.price = math.floor((details.price + price * 0.9) * 100) / 100
    end
    details.repairTime = details.repairTime + repairTimePerPart
    details.partsCountToBeReplaced = details.partsCountToBeReplaced + 1
  end

  return details
end

local function getTableSize(t)
  local count = 0
  if not t then return 0 end
  for _ in pairs(t) do
    count = count + 1
  end
  return count
end

local function getVehicleValue(configBaseValue, vehicle, ignoreDamage)
  local mileage = vehicle.mileage or 0

  local partInventory = career_modules_partInventory and career_modules_partInventory.getInventory and career_modules_partInventory.getInventory() or {}

  local newParts = {}
  for _, part in pairs(partInventory) do
    if part.location == vehicle.id then
      newParts[part.containingSlot] = part.name
    end
  end
  local originalParts = vehicle.originalParts
  local changedSlots = vehicle.changedSlots or {}
  local addedParts, removedParts = getPartDifference(originalParts, newParts, changedSlots)
  local sumPartValues = 0
  if originalParts then
    for slot, partName in pairs(originalParts) do
      local part = career_modules_partInventory.getPart(vehicle.id, slot)
      if part and not removedParts[slot] then
        sumPartValues = sumPartValues + getPartValue(part)
      end
    end
  end
  local vehicleYear = vehicle.year or 2023
  local adjustedBaseValue = getAdjustedVehicleBaseValue(configBaseValue, {mileage = mileage, age = 2023 - vehicleYear})
  if addedParts then
    for slot, partName in pairs(addedParts) do
      local part = career_modules_partInventory.getPart(vehicle.id, slot)
      if part then
        sumPartValues = sumPartValues + 0.90 * getPartValue(part)
        adjustedBaseValue = adjustedBaseValue + 0.90 * getPartValue(part)
      end
    end
  end

  if removedParts then
    for slot, partName in pairs(removedParts) do
      local origPart = originalParts and originalParts[slot]
      local partValue = origPart and origPart.value or 0
      local part = {value = partValue, partCondition = {odometer = mileage}}
      adjustedBaseValue = adjustedBaseValue - getPartValue(part)
    end
  end

  local repairDetails = getRepairDetails(vehicle)
  if ignoreDamage then
    repairDetails.price = 0
  end

  local value = math.max(adjustedBaseValue, sumPartValues)

  if (getTableSize(originalParts) / 2) < (getTableSize(removedParts)) then
    value = math.max(sumPartValues, 0)
  end
  return value - repairDetails.price
end

local function getInventoryVehicleValue(inventoryId, ignoreDamage)
  local vehicles = career_modules_inventory.getVehicles()
  if not vehicles then return 0 end
  local vehicle = vehicles[inventoryId]
  if not vehicle then return 0 end
  local value = math.max(getVehicleValue(vehicle.configBaseValue or 0, vehicle, ignoreDamage), 0)
  local meetReputation = career_modules_inventory.getMeetReputation and career_modules_inventory.getMeetReputation(inventoryId) or 0
  local accidents = career_modules_inventory.getAccidents and career_modules_inventory.getAccidents(inventoryId) or 0
  local accidentMultiplier = (career_modules_hardcore and career_modules_hardcore.isHardcoreMode and career_modules_hardcore.isHardcoreMode()) and 0.9 or 0.95
  return value * (1 + meetReputation * 0.01) * (accidentMultiplier ^ accidents)
end

local function getNumberOfBrokenParts(partConditions)
  if not partConditions then return 0 end
  local counter = 0
  for partPath, info in pairs(partConditions) do
    if info.integrityValue and info.integrityValue == 0 then
      counter = counter + 1
    end
  end
  return counter
end

local function partConditionsNeedRepair(partConditions)
  return getNumberOfBrokenParts(partConditions) >= brokenPartsThreshold
end

local function getBrokenPartsThreshold()
  return brokenPartsThreshold
end

M.getPartDifference = getPartDifference
M.getInventoryVehicleValue = getInventoryVehicleValue
M.getPartValue = getPartValue
M.getDepreciatedPartValue = getDepreciatedPartValue
M.getAdjustedVehicleBaseValue = getAdjustedVehicleBaseValue
M.getVehicleMileageById = getVehicleMileageById
M.getBrokenPartsThreshold = getBrokenPartsThreshold
M.getRepairDetails = getRepairDetails
M.getNumberOfBrokenParts = getNumberOfBrokenParts
M.partConditionsNeedRepair = partConditionsNeedRepair

return M
