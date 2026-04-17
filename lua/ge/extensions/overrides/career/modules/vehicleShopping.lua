-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career', 'util_configListGenerator'}

-- BCM forward declarations (lazy-initialized at call time so load order doesn't matter)
local bcm_properties_ref = nil
local bcm_garages_ref = nil

local function getBcmProperties()
  if not bcm_properties_ref then bcm_properties_ref = bcm_properties end
  return bcm_properties_ref
end

local function getBcmGarages()
  if not bcm_garages_ref then bcm_garages_ref = bcm_garages end
  return bcm_garages_ref
end

-- Find a garage with free capacity. Tries preferredGarageId first, then falls back
-- to any other owned garage. Returns garageId string or nil if no space anywhere.
local function findGarageWithCapacity(preferredGarageId)
  local garages = getBcmGarages()
  local props = getBcmProperties()
  if not garages or not props then return nil end

  -- Try preferred garage first
  if preferredGarageId then
    local freeSlots = garages.getFreeSlots(preferredGarageId)
    if freeSlots and freeSlots > 0 then return preferredGarageId end
  end

  -- Fall back to any other owned garage with space
  local ownedProps = props.getAllOwnedProperties()
  if not ownedProps then return nil end
  for _, propData in ipairs(ownedProps) do
    if propData.type == "garage" and propData.id ~= preferredGarageId then
      local freeSlots = garages.getFreeSlots(propData.id)
      if freeSlots and freeSlots > 0 then return propData.id end
    end
  end

  return nil -- no garage has capacity
end

-- Returns true when the player owns at least one BCM garage
local function playerHasBcmGarages()
  local props = getBcmProperties()
  if not props then return false end
  local ownedProps = props.getAllOwnedProperties()
  if not ownedProps then return false end
  for _, propData in ipairs(ownedProps) do
    if propData.type == "garage" then return true end
  end
  return false
end

local moduleVersion = 61

local vehicleShopDirtyDate

local vehicleDeliveryDelay = 60
local vehicleOfferTimeToLive = 10 * 60
local timeToRemoveSoldVehicle = 5 * 60
local dealershipTimeBetweenOffers = 1 * 60
local salesTax = 0.07
local customLicensePlatePrice = 300

local starterVehicleMileages = {bx = 165746239, etki = 285817342, covet = 80174611, miramar = 900000000}
local starterVehicleYears = {bx = 1990, etki = 1989, covet = 1989, miramar = 1982}

local vehiclesInShop = {}
local sellersInfos = {}
local currentSeller

local vehicleWatchlist = {}

local purchaseData

local tether
local tetherRange = 4 --meter

local function generateSoldVehicleValue(shopId)
  local vehicleInfo = M.getVehicleInfoByShopId(shopId)
  if not vehicleInfo then return end
  local value = vehicleInfo.Value * (0.9 + math.random() * 0.1)
  return round(value / 10) * 10
end

local function convertKeysToStrings(t)
  local unsoldVehicles = {}
  local soldVehicles = {}
  for k,v in ipairs(t) do
    if v.soldViewCounter and v.soldViewCounter > 0 then
      table.insert(soldVehicles, v)
    else
      table.insert(unsoldVehicles, v)
    end
  end
  return unsoldVehicles, soldVehicles
end

local privateSellersPreview = "/levels/west_coast_usa/facilities/privateSeller_dealership.jpg"
local function getUiDealershipsData(unsoldVehicles)
  local dealerships = freeroam_facilities.getFacilitiesByType("dealership")
  local vehicleCountPerDealership = {}
  for _, vehicle in ipairs(unsoldVehicles) do
    vehicleCountPerDealership[vehicle.sellerId] = (vehicleCountPerDealership[vehicle.sellerId] or 0) + 1
  end
  local data = {}
  for _, dealership in ipairs(dealerships) do
    table.insert(data, {
      id = dealership.id,
      name = dealership.name,
      description = dealership.description,
      vehicleCount = vehicleCountPerDealership[dealership.id] or 0,
      preview = dealership.preview,
      icon = "carDealer"
    })
  end
  table.sort(data, function(a,b) return a.name < b.name end)
  table.insert(data, {
    id = "private",
    name = "Private Sellers",
    vehicleCount = vehicleCountPerDealership["private"] or 0,
    preview = privateSellersPreview,
    icon = "personSolid"
  })
  return data
end

local function getShoppingData()
  local data = {}
  data.vehiclesInShop, data.soldVehicles = convertKeysToStrings(vehiclesInShop)
  data.uiDealershipsData = getUiDealershipsData(data.vehiclesInShop)
  data.currentSeller = currentSeller
  if currentSeller then
    local dealership = freeroam_facilities.getDealership(currentSeller)
    data.currentSellerNiceName = dealership.name
  end
  data.playerAttributes = career_modules_playerAttributes.getAllAttributes()
  data.inventoryHasFreeSlot = career_modules_inventory.hasFreeSlot()
  data.numberOfFreeSlots = career_modules_inventory.getNumberOfFreeSlots()

  data.tutorialPurchase = (not career_modules_linearTutorial.getTutorialFlag("purchasedFirstCar")) or nil

  data.disableShopping = false
  local reason = career_modules_permissions.getStatusForTag("vehicleShopping")
  if not reason.allow then
    data.disableShopping = true
  end
  if reason.permission ~= "allowed" then
    data.disableShoppingReason = reason.label or "not allowed (TODO)"
  end

  return data
end

local function normalizePopulations(configs, scalingFactor)
  local sum = 0
  for _, configInfo in ipairs(configs) do
    configInfo.adjustedPopulation = configInfo.Population or 1
    sum = sum + configInfo.adjustedPopulation
  end
  local average = sum / tableSize(configs)
  for _, configInfo in ipairs(configs) do
    local distanceFromAverage = configInfo.adjustedPopulation - average
    configInfo.adjustedPopulation = round(configInfo.adjustedPopulation - scalingFactor * distanceFromAverage)
  end
end

local function getRoundedPrice(value, priceRoundingType)
  if priceRoundingType == "prestige" then
    -- Always round up to a price ending in 495 or 995
    local thousands = math.floor(value / 1000)
    local candidate495 = thousands * 1000 + 495
    if value <= candidate495 then return candidate495 end
    local candidate995 = thousands * 1000 + 995
    if value <= candidate995 then return candidate995 end
    return (thousands + 1) * 1000 + 495
  elseif priceRoundingType == "private" then
    -- Always round up to the next multiple of 100
    return math.ceil(value / 100) * 100
  elseif priceRoundingType == "dealer" then
    -- Round up to nearest 20 (ends in 20, 40, 60, 80, 00)
    return math.ceil(value / 20) * 20
  else
    -- Always round up to the next multiple of 10
    return math.ceil(value / 10) * 10
  end
end

local function generateShopId()
  local shopId = 0
  while true do
    shopId = math.floor(math.random() * 1000000)
    for _, vehInfo in ipairs(vehiclesInShop) do
      if vehInfo.shopId == shopId then
        break
      end
    end
    return shopId
  end
end

local function getVehicleInfoByShopId(shopId)
  if not shopId then return nil end
  -- shopId may arrive as string from the UI bridge; normalize to number
  local numShopId = tonumber(shopId)
  if not numShopId then return nil end
  for _, vehInfo in ipairs(vehiclesInShop) do
    if vehInfo.shopId == numShopId then
      return vehInfo
    end
  end
  return nil
end

local function getEligibleVehiclesWithoutDealershipVehicles(eligibleVehicles, seller)
  local eligibleVehiclesWithoutDealershipVehicles = deepcopy(eligibleVehicles)
  local configsInDealership = {}
  for _, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.sellerId == seller.id then
      configsInDealership[vehicleInfo.model_key] = configsInDealership[vehicleInfo.model_key] or {}
      configsInDealership[vehicleInfo.model_key][vehicleInfo.key] = true
    end
  end

  for i = #eligibleVehiclesWithoutDealershipVehicles, 1, -1 do
    local vehicleInfo = eligibleVehiclesWithoutDealershipVehicles[i]
    if configsInDealership[vehicleInfo.model_key] and configsInDealership[vehicleInfo.model_key][vehicleInfo.key] then
      table.remove(eligibleVehiclesWithoutDealershipVehicles, i)
    end
  end
  return eligibleVehiclesWithoutDealershipVehicles
end

local function updateVehicleList(fromScratch)
  vehicleShopDirtyDate = os.date("!%Y-%m-%dT%H:%M:%SZ")

  local sellers = {}
  local onlyStarterVehicles = not career_career.hasBoughtStarterVehicle()

  if fromScratch then
    vehiclesInShop = {}
    vehicleWatchlist = {}
  end

  -- if there are already vehicles in the shop, don't generate starter vehicles
  if onlyStarterVehicles and not tableIsEmpty(vehiclesInShop) then
    return
  end

  -- get the dealerships from the level
  local facilities = deepcopy(freeroam_facilities.getFacilities(getCurrentLevelIdentifier()))
  for _, dealership in ipairs(facilities.dealerships) do
    if onlyStarterVehicles then
      if dealership.containsStarterVehicles then
        dealership.filter = {whiteList = {careerStarterVehicle = {true}}}
        dealership.subFilters = nil
        table.insert(sellers, dealership)
      end
    else
      dealership.filter = dealership.filter or {}
      table.insert(sellers, dealership)
    end
  end

  if not onlyStarterVehicles then
    for _, dealership in ipairs(facilities.privateSellers) do
      table.insert(sellers, dealership)
    end
  end
  table.sort(sellers, function(a,b) return a.id < b.id end)

  local currentTime = os.time()

  -- remove vehicles that have expired
  for i = #vehiclesInShop, 1, -1 do
    local vehicleInfo = vehiclesInShop[i]
    local offerTime = currentTime - vehicleInfo.generationTime
    if offerTime > vehicleInfo.offerTTL then -- vehicle offer has expired
      if vehicleWatchlist[vehicleInfo.shopId] then
        if type(vehicleWatchlist[vehicleInfo.shopId]) ~= "number" then
          vehicleWatchlist[vehicleInfo.shopId] = currentTime + timeToRemoveSoldVehicle -- time to remove the vehicle from the watchlist
          if not vehicleInfo.soldFor then
            vehicleInfo.soldFor = generateSoldVehicleValue(vehicleInfo.shopId)
          end
        end
        vehicleInfo.soldViewCounter = vehicleInfo.soldViewCounter or 0
        vehicleInfo.soldViewCounter = vehicleInfo.soldViewCounter + 1
        if currentTime > vehicleWatchlist[vehicleInfo.shopId] then
          vehicleWatchlist[vehicleInfo.shopId] = nil -- remove the vehicle from the watchlist
          table.remove(vehiclesInShop, i)
        end
      else
        table.remove(vehiclesInShop, i)
      end
    end
  end

  local eligibleVehicles = util_configListGenerator.getEligibleVehicles()
  normalizePopulations(eligibleVehicles, 0.4)

  for _, seller in ipairs(sellers) do
    if not sellersInfos[seller.id] then
      sellersInfos[seller.id] = {
        lastGenerationTime = 0,
      }
    end
    if fromScratch then
      sellersInfos[seller.id].lastGenerationTime = 0
    end

    local randomVehicleInfos = {}
    if onlyStarterVehicles then
      -- generate the starter vehicles
      local eligibleVehiclesStarter = util_configListGenerator.getEligibleVehicles(onlyStarterVehicles)
      randomVehicleInfos = util_configListGenerator.getRandomVehicleInfos(seller, 3, eligibleVehiclesStarter, "adjustedPopulation")
    else
      -- vehicleGenerationMultiplier lowers the time between offers
      local adjustedTimeBetweenOffers = dealershipTimeBetweenOffers / (seller.vehicleGenerationMultiplier or 1)
      local maxVehicles = math.floor(vehicleOfferTimeToLive / adjustedTimeBetweenOffers)  -- Higher cap for lower time between offers
      local numberOfVehiclesToGenerate = math.min(math.floor((currentTime - sellersInfos[seller.id].lastGenerationTime) / adjustedTimeBetweenOffers), maxVehicles)
      log("I", "Career", "Generating " .. numberOfVehiclesToGenerate .. " vehicles for " .. seller.id)

      -- generate the vehicles without duplicating vehicles that are already in the dealership
      local eligibleVehiclesWithoutDealershipVehicles = getEligibleVehiclesWithoutDealershipVehicles(eligibleVehicles, seller)
      local newRandomVehicleInfos = util_configListGenerator.getRandomVehicleInfos(seller, numberOfVehiclesToGenerate, eligibleVehiclesWithoutDealershipVehicles, "adjustedPopulation")
      arrayConcat(randomVehicleInfos, newRandomVehicleInfos)

      -- generate the remaining vehicles without a duplicate check
      local numberOfMissingVehicles = numberOfVehiclesToGenerate - tableSize(newRandomVehicleInfos)
      if numberOfMissingVehicles > 0 then
        log("I", "Career", "Generating " .. numberOfMissingVehicles .. " more vehicles without duplicate check for " .. seller.id)
        for i = 1, numberOfMissingVehicles do
          local newRandomVehicleInfos = util_configListGenerator.getRandomVehicleInfos(seller, 1, eligibleVehicles, "adjustedPopulation")
          arrayConcat(randomVehicleInfos, newRandomVehicleInfos)
        end
      end
    end

    for i, randomVehicleInfo in ipairs(randomVehicleInfos) do
      -- Distribute generation times evenly between lastGenerationTime and currentTime
      randomVehicleInfo.generationTime = currentTime - ((i-1) * dealershipTimeBetweenOffers)
      randomVehicleInfo.offerTTL = onlyStarterVehicles and math.huge or vehicleOfferTimeToLive

      randomVehicleInfo.sellerId = seller.id
      randomVehicleInfo.sellerName = seller.name
      local filter = randomVehicleInfo.filter
      local years = randomVehicleInfo.Years or randomVehicleInfo.aggregates.Years

      if not onlyStarterVehicles then
        -- get a random year between the min and max year of the filter and the years of the vehicle
        local minYear = (years and years.min) or 2023
        if filter.whiteList and filter.whiteList.Years and filter.whiteList.Years.min then
          minYear = math.max(minYear, filter.whiteList.Years.min)
        end
        local maxYear = (years and years.max) or 2023
        if filter.whiteList and filter.whiteList.Years and filter.whiteList.Years.max then
          maxYear = math.min(maxYear, filter.whiteList.Years.max)
        end
        randomVehicleInfo.year = math.random(minYear, maxYear)

        -- get a random mileage between the min and max mileage of the filter
        if filter.whiteList and filter.whiteList.Mileage then
          randomVehicleInfo.Mileage = randomGauss3()/3 * (filter.whiteList.Mileage.max - filter.whiteList.Mileage.min) + filter.whiteList.Mileage.min
        else
          randomVehicleInfo.Mileage = 0
        end
      else
        -- values for the starter vehicles
        randomVehicleInfo.year = starterVehicleYears[randomVehicleInfo.model_key] or (years and math.random(years.min, years.max) or 2023)
        randomVehicleInfo.Mileage = starterVehicleMileages[randomVehicleInfo.model_key] or 100000000
      end

      randomVehicleInfo.Value = career_modules_valueCalculator.getAdjustedVehicleBaseValue(randomVehicleInfo.Value, {mileage = randomVehicleInfo.Mileage, age = 2023 - randomVehicleInfo.year})
      randomVehicleInfo.shopId = generateShopId()

      -- compute taxes and fees
      randomVehicleInfo.fees = seller.fees or 0

      if seller.id == "private" then
        local parkingSpots = gameplay_parking.getParkingSpots().byName
        local parkingSpotNames = tableKeys(parkingSpots)

        -- get a random parking spot on the map
        -- TODO needs some error handling when there are no parking spots
        local parkingSpotName, parkingSpot
        if randomVehicleInfo.BoundingBox and randomVehicleInfo.BoundingBox[2] then
          repeat
            parkingSpotName = parkingSpotNames[math.random(tableSize(parkingSpotNames))]
            parkingSpot = parkingSpots[parkingSpotName]
          until not parkingSpot.customFields.tags.notprivatesale and parkingSpot:boxFits(randomVehicleInfo.BoundingBox[2][1], randomVehicleInfo.BoundingBox[2][2], randomVehicleInfo.BoundingBox[2][3])
        end

        if not parkingSpotName then
          repeat
            parkingSpotName = parkingSpotNames[math.random(tableSize(parkingSpotNames))]
            parkingSpot = parkingSpots[parkingSpotName]
          until not parkingSpot.customFields.tags.notprivatesale
        end

        randomVehicleInfo.parkingSpotName = parkingSpotName
        randomVehicleInfo.pos = parkingSpot.pos
        randomVehicleInfo.negotiationPersonality = career_modules_marketplace.generatePersonality(false)
        randomVehicleInfo.sellerName = randomVehicleInfo.negotiationPersonality.name
      else
        local dealership = freeroam_facilities.getDealership(seller.id)
        randomVehicleInfo.pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
        local personalityKey = seller.id  -- Use dealership ID as personality key
        randomVehicleInfo.negotiationPersonality = career_modules_marketplace.generatePersonality(false, {personalityKey})
      end

      local vehicleInsuranceClass = career_modules_insurance_insurance.getInsuranceClassFromVehicleShoppingData(randomVehicleInfo)
      if vehicleInsuranceClass then
        randomVehicleInfo.insuranceClass = vehicleInsuranceClass
      end

      randomVehicleInfo.negotiationPossible = not onlyStarterVehicles
      randomVehicleInfo.marketValue = randomVehicleInfo.Value
      -- Apply markup to create asking price
      randomVehicleInfo.Value = getRoundedPrice(randomVehicleInfo.Value * (randomVehicleInfo.negotiationPersonality.priceMultiplier or 1), seller.priceRoundingType)
      table.insert(vehiclesInShop, randomVehicleInfo)
    end
    if not tableIsEmpty(randomVehicleInfos) then
      sellersInfos[seller.id].lastGenerationTime = currentTime
    end
  end

  log("I", "Career", "Vehicles in shop: " .. tableSize(vehiclesInShop))
end

local function moveVehicleToDealership(vehObj, dealershipId)
  local dealership = freeroam_facilities.getDealership(dealershipId)
  local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(dealership)
  local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehObj:getID(), parkingSpots)
  parkingSpot:moveResetVehicleTo(vehObj:getID(), nil, nil, nil, nil, true)
end

local function getDeliveryDelay(distance)
  if distance < 500 then return 1 end
  return vehicleDeliveryDelay
end

local function getVisualValueFromMileage(mileage)
  mileage = clamp(mileage, 0, 2000000000)
  if mileage <= 10000000 then
    return 1
  elseif mileage <= 50000000 then
    return rescale(mileage, 10000000, 50000000, 1, 0.95)
  elseif mileage <= 100000000 then
    return rescale(mileage, 50000000, 100000000, 0.95, 0.925)
  elseif mileage <= 200000000 then
    return rescale(mileage, 100000000, 200000000, 0.925, 0.88)
  elseif mileage <= 500000000 then
    return rescale(mileage, 200000000, 500000000, 0.88, 0.825)
  elseif mileage <= 1000000000 then
    return rescale(mileage, 500000000, 1000000000, 0.825, 0.8)
  else
    return rescale(mileage, 1000000000, 2000000000, 0.8, 0.75)
  end
end

local spawnFollowUpActions

local function spawnVehicle(vehicleInfo, dealershipToMoveTo)
  local spawnOptions = {}
  spawnOptions.config = vehicleInfo.key
  spawnOptions.autoEnterVehicle = false
  local newVeh = core_vehicles.spawnNewVehicle(vehicleInfo.model_key, spawnOptions)
  if dealershipToMoveTo then moveVehicleToDealership(newVeh, dealershipToMoveTo) end
  core_vehicleBridge.executeAction(newVeh,'setIgnitionLevel', 0)

  newVeh:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f) obj:queueGameEngineLua('career_modules_vehicleShopping.onVehicleSpawnFinished(%d)')", vehicleInfo.Mileage, getVisualValueFromMileage(vehicleInfo.Mileage), newVeh:getID()))
  return newVeh
end

local function onVehicleSpawnFinished(vehId)
  local inventoryId = career_modules_inventory.addVehicle(vehId)

  if spawnFollowUpActions then
    if spawnFollowUpActions.delayAccess then
      career_modules_inventory.delayVehicleAccess(inventoryId, spawnFollowUpActions.delayAccess, "bought")
    end
    if spawnFollowUpActions.licensePlateText then
      career_modules_inventory.setLicensePlateText(inventoryId, spawnFollowUpActions.licensePlateText)
    end
    -- BCM: set vehicle.location directly (single source of truth)
    if spawnFollowUpActions.bcmTargetGarageId and inventoryId then
      local vehicles = career_modules_inventory.getVehicles()
      if vehicles and vehicles[inventoryId] then
        vehicles[inventoryId].location = spawnFollowUpActions.bcmTargetGarageId
        local garages = getBcmGarages()
        local displayName = garages and garages.getGarageDisplayName and garages.getGarageDisplayName(spawnFollowUpActions.bcmTargetGarageId)
        vehicles[inventoryId].niceLocation = displayName or spawnFollowUpActions.bcmTargetGarageId
      end
      log('I', 'Career', 'BCM: Set vehicle.location inv=' .. tostring(inventoryId) .. ' -> garage=' .. tostring(spawnFollowUpActions.bcmTargetGarageId))
    end
    spawnFollowUpActions = nil
  end
end

local function payForVehicle()
  local label = string.format("Bought a vehicle: %s", purchaseData.vehicleInfo.niceName)
  if purchaseData.tradeInVehicleInfo then
    label = label .. string.format(" and traded in vehicle id %d: %s", purchaseData.tradeInVehicleInfo.id, purchaseData.tradeInVehicleInfo.niceName)
  end
  career_modules_playerAttributes.addAttributes({money=-purchaseData.prices.finalPrice}, {tags={"vehicleBought","buying"},label=label})
  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  vehicleWatchlist[purchaseData.shopId] = nil
end

local deleteAddedVehicle
local function buyVehicleAndSendToGarage(options)
  if career_modules_playerAttributes.getAttributeValue("money") < purchaseData.prices.finalPrice then
    return
  end

  -- BCM capacity check: if player owns BCM garages, enforce capacity before purchasing
  if playerHasBcmGarages() then
    local currentGarageId = originComputerId and career_modules_garageManager and career_modules_garageManager.computerIdToGarageId(originComputerId) or nil
    local targetGarageId = findGarageWithCapacity(currentGarageId)
    if not targetGarageId then
      -- All garages full — block purchase
      guihooks.trigger('toastrMsg', {type = "error", title = "Garage Full", msg = "No garage capacity available. Upgrade or buy a new garage. / Sin espacio en garaje. Mejora o compra uno nuevo."})
      log('W', 'Career', 'BCM: Vehicle purchase blocked — all garages at capacity')
      return
    end
    -- Store target garage so onVehicleSpawnFinished can assign
    options.bcmTargetGarageId = targetGarageId
  end

  payForVehicle()

  local closestGarage = career_modules_inventory.getClosestGarage()
  local garagePos, _ = freeroam_facilities.getGaragePosRot(closestGarage)
  local delay = getDeliveryDelay(purchaseData.vehicleInfo.pos:distance(garagePos))
  spawnFollowUpActions = {delayAccess = delay, licensePlateText = options.licensePlateText, bcmTargetGarageId = options.bcmTargetGarageId}
  spawnVehicle(purchaseData.vehicleInfo)
  deleteAddedVehicle = true
end

local function buyVehicleAndSpawnInParkingSpot(options)
  if career_modules_playerAttributes.getAttributeValue("money") < purchaseData.prices.finalPrice then
    return
  end

  -- BCM capacity check: if player owns BCM garages, enforce capacity before purchasing
  if playerHasBcmGarages() then
    local currentGarageId = originComputerId and career_modules_garageManager and career_modules_garageManager.computerIdToGarageId(originComputerId) or nil
    local targetGarageId = findGarageWithCapacity(currentGarageId)
    if not targetGarageId then
      guihooks.trigger('toastrMsg', {type = "error", title = "Garage Full", msg = "No garage capacity available. Upgrade or buy a new garage. / Sin espacio en garaje. Mejora o compra uno nuevo."})
      log('W', 'Career', 'BCM: Vehicle purchase blocked — all garages at capacity')
      return
    end
    options.bcmTargetGarageId = targetGarageId
  end

  payForVehicle()
  spawnFollowUpActions = {licensePlateText = options.licensePlateText, bcmTargetGarageId = options.bcmTargetGarageId}
  local newVehObj = spawnVehicle(purchaseData.vehicleInfo, purchaseData.vehicleInfo.sellerId)
  if gameplay_walk.isWalking() then
    gameplay_walk.setRot(newVehObj:getPosition() - getPlayerVehicle(0):getPosition())
  end
end

local function navigateToPos(pos)
  -- TODO this should better take vec3s directly
  core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))
  guihooks.trigger('ChangeState', {state = 'play', params = {}})
end

-- TODO At this point, the part conditions of the previous vehicle should have already been saved. for example when entering the garage
local originComputerId
local function openShop(seller, _originComputerId, screenTag)
  currentSeller = seller
  originComputerId = _originComputerId

  if not career_modules_inspectVehicle.getSpawnedVehicleInfo() then
    updateVehicleList()
  end

  local sellerInfos = {}
  for id, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.pos then
      if vehicleInfo.sellerId ~= "private" then
        local sellerInfo = sellerInfos[vehicleInfo.sellerId]
        if sellerInfo then
          vehicleInfo.distance = sellerInfo.distance
          vehicleInfo.quickTravelPrice = sellerInfo.quicktravelPrice
        else
          local quicktravelPrice, distance = career_modules_quickTravel.getPriceForQuickTravel(vehicleInfo.pos)
          sellerInfos[vehicleInfo.sellerId] = {distance = distance, quicktravelPrice = quicktravelPrice}
          vehicleInfo.distance = distance
          vehicleInfo.quickTravelPrice = quicktravelPrice
        end
      else
        local quicktravelPrice, distance = career_modules_quickTravel.getPriceForQuickTravel(vehicleInfo.pos)
        vehicleInfo.distance = distance
        vehicleInfo.quickTravelPrice = quicktravelPrice
      end
    else
      vehicleInfo.distance = 0
    end
  end

  local computer
  if currentSeller then
    local tetherPos = freeroam_facilities.getAverageDoorPositionForFacility(freeroam_facilities.getFacility("dealership",currentSeller))
    tether = career_modules_tether.startSphereTether(tetherPos, tetherRange, M.endShopping)
  elseif originComputerId then
    computer = freeroam_facilities.getFacility("computer", originComputerId)
    tether = career_modules_tether.startDoorTether(computer.doors[1], nil, M.endShopping)
  end

  guihooks.trigger('ChangeState', {state = 'vehicleShopping', params =
  {
    screenTag = screenTag,
    buyingAvailable = (not computer or computer.functions.vehicleShop) and "true" or "false",
    marketplaceAvailable = (career_career.hasBoughtStarterVehicle() and not currentSeller) and "true" or "false"
  }})
  extensions.hook("onVehicleShoppingMenuOpened", {seller = currentSeller})
end

local function endShopping()
  career_career.closeAllMenus()
  extensions.hook("onVehicleShoppingMenuClosed", {})
end

local function cancelShopping()
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
end

local function onShoppingMenuClosed()
  if tether then tether.remove = true tether = nil end
end

local function getVehiclesInShop()
  return vehiclesInShop
end

local removeNonUsedPlayerVehicles
local function removeUnusedPlayerVehicles()
  for inventoryId, vehId in pairs(career_modules_inventory.getMapInventoryIdToVehId()) do
    if inventoryId ~= career_modules_inventory.getCurrentVehicle() then
      career_modules_inventory.removeVehicleObject(inventoryId)
    end
  end
end

local function buySpawnedVehicle(buyVehicleOptions)
  if career_modules_playerAttributes.getAttributeValue("money") >= purchaseData.prices.finalPrice then
    local vehObj = getObjectByID(purchaseData.vehId)
    payForVehicle()
    local newInventoryId = career_modules_inventory.addVehicle(vehObj:getID())
    if buyVehicleOptions.licensePlateText then
      career_modules_inventory.setLicensePlateText(newInventoryId, buyVehicleOptions.licensePlateText)
    end
    removeNonUsedPlayerVehicles = true
    if be:getPlayerVehicleID(0) == vehObj:getID() then
      career_modules_inventory.enterVehicle(newInventoryId)
    end
  end
end

local function sendPurchaseDataToUi()
  local vehicleShopInfo = deepcopy(getVehicleInfoByShopId(purchaseData.shopId))
  if not vehicleShopInfo then
    log("E", "Career", "sendPurchaseDataToUi: Vehicle not found for shopId: " .. tostring(purchaseData.shopId))
    return
  end
  vehicleShopInfo.shopId = purchaseData.shopId
  vehicleShopInfo.niceName = vehicleShopInfo.Brand .. " " .. vehicleShopInfo.Name
  vehicleShopInfo.deliveryDelay = getDeliveryDelay(vehicleShopInfo.distance)
  purchaseData.vehicleInfo = vehicleShopInfo
  --purchaseData.vehicleInfo.Value = 1000

  local tradeInValue = purchaseData.tradeInVehicleInfo and purchaseData.tradeInVehicleInfo.Value or 0
  local taxes = math.max((vehicleShopInfo.Value + vehicleShopInfo.fees - tradeInValue) * salesTax, 0)
  local finalPrice = vehicleShopInfo.Value + vehicleShopInfo.fees + taxes - tradeInValue
  purchaseData.prices = {fees = vehicleShopInfo.fees, taxes = taxes, finalPrice = finalPrice, customLicensePlate = customLicensePlatePrice}
  local spawnedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
  purchaseData.vehId = spawnedVehicleInfo and spawnedVehicleInfo.vehId

  if not purchaseData.insuranceId then
    -- Always try to assign default insurance — never leave uninsured
    local defaultIns = nil
    if vehicleShopInfo.insuranceClass and vehicleShopInfo.insuranceClass.id then
      pcall(function()
        defaultIns = career_modules_insurance_insurance.getDefaultInsuranceForClassId(vehicleShopInfo.insuranceClass.id)
      end)
    end
    -- Fallback: try class 1 (basic) if specific class lookup failed
    if not defaultIns then
      pcall(function()
        defaultIns = career_modules_insurance_insurance.getDefaultInsuranceForClassId(1)
      end)
    end
    purchaseData.insuranceId = defaultIns and defaultIns.id or -1
  end

  purchaseData.insuranceOptions = {
    insuranceId = purchaseData.insuranceId,
    shopId = purchaseData.shopId,
  }
  -- -1 means no insurance picked
  if purchaseData.insuranceId >= 0 then
    local insuranceInfo = career_modules_insurance_insurance.getInsuranceDataById(purchaseData.insuranceId)
    purchaseData.insuranceOptions.spendingReason = string.format("Insurance Policy: \"%s\"", insuranceInfo.name)
    purchaseData.insuranceOptions.priceMoney = career_modules_insurance_insurance.calculateAddVehiclePrice(purchaseData.insuranceId, purchaseData.vehicleInfo.Value)
  end

  local data = {
    vehicleInfo = purchaseData.vehicleInfo,
    playerMoney = career_modules_playerAttributes.getAttributeValue("money"),
    inventoryHasFreeSlot = career_modules_inventory.hasFreeSlot(),
    purchaseType = purchaseData.purchaseType,
    forceTradeIn = not career_modules_linearTutorial.getTutorialFlag("purchasedFirstCar") or nil,
    tradeInVehicleInfo = purchaseData.tradeInVehicleInfo,
    prices = purchaseData.prices,
    alreadyDidTestDrive = career_modules_inspectVehicle.getDidTestDrive(),
    insuranceOptions = purchaseData.insuranceOptions,
  }

  local atDealership = (purchaseData.purchaseType == "instant" and currentSeller) or (purchaseData.purchaseType == "inspect" and vehicleShopInfo.sellerId ~= "private")

  -- allow trade in only when at a dealership
  if atDealership then
    data.tradeInEnabled = true
  end

  -- allow location selection in all cases except when on the computer
  if (atDealership or vehicleShopInfo.sellerId == "private") then
    data.locationSelectionEnabled = true
  end

  if not career_career.hasBoughtStarterVehicle() then
    data.forceNoDelivery = true
  end

  guihooks.trigger("vehiclePurchaseData", data)
end

local function onClientStartMission()
  vehiclesInShop = {}
end

local function onAddedVehiclePartsToInventory(inventoryId, newParts)
  -- BCM guard: only handle vehicles from vanilla shopping flow.
  -- Without this, BCM purchases also trigger this handler with stale purchaseData,
  -- which fires onVehicleAddedToInventory with insuranceId=-1 and overwrites BCM's insurance.
  if not purchaseData or not purchaseData.vehicleInfo then return end

  -- Update the vehicle parts with the actual parts that are installed (they differ from the pc file)
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]

  -- set the year of the vehicle
  vehicle.year = purchaseData and purchaseData.vehicleInfo.year or 1990

  vehicle.originalParts = {}
  local allSlotsInVehicle = {main = true}

  for partName, part in pairs(newParts) do
    part.year = vehicle.year
    --vehicle.config.parts[part.containingSlot] = part.name -- TODO removed with parts refactor. check if needed
    vehicle.originalParts[part.containingSlot] = {name = part.name, value = part.value}

    if part.description.slotInfoUi then
      for slot, _ in pairs(part.description.slotInfoUi) do
        allSlotsInVehicle[slot] = true
      end
    end
    -- Also check if we do the same for part shopping or part inventory or vehicle shopping
  end

  -- TODO removed with parts refactor. check if this is needed. depends on if there are slots in the data missing that contain a default part or if there are slots with some weird name like "none"

  -- remove old leftover slots that dont exist anymore
  --[[ local slotsToRemove = {}
  for slot, partName in pairs(vehicle.config.parts) do
    if not allSlotsInVehicle[slot] then
      slotsToRemove[slot] = true
    end
  end
  for slot, _ in pairs(slotsToRemove) do
    vehicle.config.parts[slot] = nil
  end

  -- every part that is now in "vehicle.config.parts", but not in "vehicle.originalParts" is either a part that no longer exists in the game or it is just some way to denote an empty slot (like "none")
  -- in both cases we change the slot to a unified ""
  for slot, partName in pairs(vehicle.config.parts) do
    if not vehicle.originalParts[slot] then
      vehicle.config.parts[slot] = ""
    end
  end ]]

  vehicle.changedSlots = {}

  if deleteAddedVehicle then
    career_modules_inventory.removeVehicleObject(inventoryId)
    deleteAddedVehicle = nil
  end

  endShopping()

  -- Ensure purchaseData.insuranceId is never nil.
  -- Try to assign real insurance (getDefaultInsuranceForClassId is safe here
  -- because plInsurancesData is initialized by loadInsurancesData at career start).
  -- Fallback to -1 (uninsured) if insurance module isn't ready.
  if purchaseData and purchaseData.insuranceId == nil then
    local ok, defaultIns = pcall(function()
      return career_modules_insurance_insurance.getDefaultInsuranceForClassId(1)
    end)
    purchaseData.insuranceId = (ok and defaultIns and defaultIns.id) or -1
  end

  extensions.hook("onVehicleAddedToInventory", {inventoryId = inventoryId, vehicleInfo = purchaseData and purchaseData.vehicleInfo, purchaseData = purchaseData})

  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end
end

local function onEnterVehicleFinished()
  if removeNonUsedPlayerVehicles then
   --removeUnusedPlayerVehicles()
   removeNonUsedPlayerVehicles = nil
  end
end

local function startInspectionWorkitem(job, vehicleInfo, teleportToVehicle)
  ui_fadeScreen.start(0.5)
  job.sleep(1.0)
  guihooks.trigger("ChangeState","play")
  career_modules_inspectVehicle.startInspection(vehicleInfo, teleportToVehicle)
  job.sleep(0.5)
  ui_fadeScreen.stop(0.5)
  job.sleep(1.0)

  --notify other extensions
  extensions.hook("onVehicleShoppingVehicleShown", {vehicleInfo = vehicleInfo})
end

local function showVehicle(shopId)
  local vehicleInfo = getVehicleInfoByShopId(shopId)
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo)
end

local function quickTravelToVehicle(shopId)
  if not shopId then
    log("E", "Career", "quickTravelToVehicle: shopId is nil")
    return
  end
  local vehicleInfo = getVehicleInfoByShopId(shopId)
  if not vehicleInfo then
    log("E", "Career", "quickTravelToVehicle: Vehicle not found for shopId: " .. tostring(shopId))
    return
  end
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, true)
end

local function openPurchaseMenu(purchaseType, shopId, insuranceId)
  vehicleWatchlist[shopId] = "unsold"
  guihooks.trigger('ChangeState', {state = 'vehiclePurchase', params = {}})
  purchaseData = {shopId = shopId, purchaseType = purchaseType, insuranceId = insuranceId}
  extensions.hook("onVehicleShoppingPurchaseMenuOpened", {purchaseType = purchaseType, shopId = shopId})
end

local function updateInsuranceSelection(insuranceId)
  if purchaseData then
    purchaseData.insuranceId = insuranceId
    sendPurchaseDataToUi()
  end
end

local function buyFromPurchaseMenu(purchaseType, options)
  if not purchaseData then
    log("E", "Career", "buyFromPurchaseMenu: purchaseData is nil")
    return
  end
  if not purchaseData.vehicleInfo then
    log("E", "Career", "buyFromPurchaseMenu: purchaseData.vehicleInfo is nil")
    return
  end
  if purchaseData.tradeInVehicleInfo then
    career_modules_inventory.removeVehicle(purchaseData.tradeInVehicleInfo.id)
  end

  local buyVehicleOptions = {licensePlateText = options.licensePlateText}
  if purchaseType == "inspect" then
    if options.makeDelivery then
      deleteAddedVehicle = true
    end
    career_modules_inspectVehicle.buySpawnedVehicle(buyVehicleOptions)
  elseif purchaseType == "instant" then
    career_modules_inspectVehicle.showVehicle(nil)
    if options.makeDelivery then
      buyVehicleAndSendToGarage(buyVehicleOptions)
    else
      buyVehicleAndSpawnInParkingSpot(buyVehicleOptions)
    end
  end
  if buyVehicleOptions.licensePlateText then
    career_modules_playerAttributes.addAttributes({money=-purchaseData.prices.customLicensePlate}, {tags={"buying"}, label=string.format("Bought custom license plate for new vehicle")})
  end

  -- store insurance ID in purchaseData to be applied when vehicle is added to inventory
  if options.insuranceId then
    purchaseData.insuranceId = options.insuranceId
  end

  -- remove the vehicle from the shop
  for i, vehInfo in ipairs(vehiclesInShop) do
    if vehInfo.shopId == purchaseData.vehicleInfo.shopId then
      table.remove(vehiclesInShop, i)
      break
    end
  end
end

local function cancelPurchase(purchaseType)
  if purchaseType == "inspect" then
    career_career.closeAllMenus()
  elseif purchaseType == "instant" then
    openShop(currentSeller, originComputerId)
  end
end

local function removeTradeInVehicle()
  purchaseData.tradeInVehicleInfo = nil
  sendPurchaseDataToUi()
end

local function openInventoryMenuForTradeIn()
  career_modules_inventory.openMenu(
    {{
      callback = function(inventoryId)
        local vehicle = career_modules_inventory.getVehicles()[inventoryId]
        if vehicle then
          purchaseData.tradeInVehicleInfo = {id = inventoryId, niceName = vehicle.niceName, Value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId), takesNoInventorySpace = vehicle.takesNoInventorySpace}
          guihooks.trigger('UINavigation', 'back', 1)
        end
      end,
      buttonText = "Trade-In",
      repairRequired = true,
      ownedRequired = true,
    }}, "Trade-In",
    {
      repairEnabled = false,
      sellEnabled = false,
      favoriteEnabled = false,
      storingEnabled = false,
      returnLoanerEnabled = false
    }
  )
end

local function onExtensionLoaded()
  if not (career_career and career_career.isActive()) then return false end

  -- load from saveslot
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not saveSlot or not savePath then return end

  local saveInfo = savePath and jsonReadFile(savePath .. "/info.json")
  local outdated = not saveInfo or saveInfo.version < moduleVersion

  local data = not outdated and jsonReadFile(savePath .. "/career/vehicleShop.json")
  if data then
    vehiclesInShop = data.vehiclesInShop or {}
    sellersInfos = data.sellersInfos or {}
    vehicleShopDirtyDate = data.dirtyDate
    vehicleWatchlist = data.vehicleWatchlist or {}

    for _, vehicleInfo in ipairs(vehiclesInShop) do
      vehicleInfo.pos = vec3(vehicleInfo.pos)
    end
  end
end

local function onSaveCurrentSaveSlot(currentSavePath, oldSaveDate)
  if vehicleShopDirtyDate and oldSaveDate >= vehicleShopDirtyDate then return end
  local data = {}
  data.vehiclesInShop = vehiclesInShop
  data.sellersInfos = sellersInfos
  data.dirtyDate = vehicleShopDirtyDate
  data.vehicleWatchlist = vehicleWatchlist
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/vehicleShop.json", data, true)
end

local function getCurrentSellerId()
  return currentSeller
end

local function onComputerAddFunctions(menuData, computerFunctions)
  local computerFunctionData = {
    id = "vehicleShop",
    label = "eBoy Motors",
    callback = function()
      -- BCM: Open phone to eBoy Motors marketplace instead of vanilla shopping
      if bcm_marketplaceApp then
        guihooks.trigger('BCMPhoneToggle', { action = 'open' })
        guihooks.trigger('BCMOpenApp', { id = 'marketplace' })
      else
        openShop(nil, menuData.computerFacility.id)
      end
    end,
    order = 10
  }
  -- tutorial active
  if menuData.tutorialPartShoppingActive or menuData.tutorialTuningActive then
    computerFunctionData.disabled = true
    computerFunctionData.reason = career_modules_computer.reasons.tutorialActive
  end
  -- generic gameplay reason
  local reason = career_modules_permissions.getStatusForTag("vehicleShopping")
  if not reason.allow then
    computerFunctionData.disabled = true
  end
  if reason.permission ~= "allowed" then
    computerFunctionData.reason = reason
  end

  computerFunctions.general[computerFunctionData.id] = computerFunctionData
end

local currentUiState
local function onUpdate()
  if tableIsEmpty(vehicleWatchlist) or (currentUiState and currentUiState ~= "play") then return end
  local currentTime = os.time()
  local inspectedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
  for shopId, status in pairs(vehicleWatchlist) do
    if status == "unsold" and (not inspectedVehicleInfo or inspectedVehicleInfo.shopId ~= shopId) then
      local vehicleInfo = getVehicleInfoByShopId(shopId)
      if vehicleInfo then
        local offerTime = currentTime - vehicleInfo.generationTime
        if offerTime > vehicleInfo.offerTTL then
          vehicleInfo.soldFor = generateSoldVehicleValue(shopId)
          vehicleWatchlist[shopId] = "sold"
          guihooks.trigger("toastrMsg", {type="info", title="A vehicle you were interested in has been sold.", msg = vehicleInfo.Name .. " for $" .. string.format("%.2f", vehicleInfo.soldFor)})
          break
        end
      end
    end
  end
end

local function onUiChangedState(toState)
  currentUiState = toState
end

M.openShop = openShop
M.showVehicle = showVehicle
M.navigateToPos = navigateToPos
M.buySpawnedVehicle = buySpawnedVehicle
M.quickTravelToVehicle = quickTravelToVehicle
M.updateVehicleList = updateVehicleList
M.getShoppingData = getShoppingData
M.sendPurchaseDataToUi = sendPurchaseDataToUi
M.getCurrentSellerId = getCurrentSellerId
M.getVisualValueFromMileage = getVisualValueFromMileage
M.getVehicleInfoByShopId = getVehicleInfoByShopId

M.openPurchaseMenu = openPurchaseMenu
M.updateInsuranceSelection = updateInsuranceSelection
M.buyFromPurchaseMenu = buyFromPurchaseMenu
M.openInventoryMenuForTradeIn = openInventoryMenuForTradeIn
M.removeTradeInVehicle = removeTradeInVehicle

M.endShopping = endShopping
M.cancelShopping = cancelShopping
M.cancelPurchase = cancelPurchase

M.getVehiclesInShop = getVehiclesInShop

M.onClientStartMission = onClientStartMission
M.onVehicleSpawnFinished = onVehicleSpawnFinished
M.onAddedVehiclePartsToInventory = onAddedVehiclePartsToInventory
M.onEnterVehicleFinished = onEnterVehicleFinished
M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onShoppingMenuClosed = onShoppingMenuClosed
M.onComputerAddFunctions = onComputerAddFunctions
M.onUpdate = onUpdate
M.onUiChangedState = onUiChangedState

M.getEligibleVehiclesWithoutDealershipVehicles = getEligibleVehiclesWithoutDealershipVehicles

-- BCM mock vehicle injection for test drives
-- Allows bcm_defects to register a temporary entry in vehiclesInShop so that
-- vanilla inspectVehicle.startInspection → spawnVehicle → getVehicleInfoByShopId
-- can find it.
local function registerMockVehicle(vehicleInfo)
  table.insert(vehiclesInShop, vehicleInfo)
  return vehicleInfo.shopId
end

local function unregisterMockVehicle(shopId)
  local numShopId = tonumber(shopId)
  if not numShopId then return false end
  for i, v in ipairs(vehiclesInShop) do
    if v.shopId == numShopId then
      table.remove(vehiclesInShop, i)
      return true
    end
  end
  return false
end

M.registerMockVehicle = registerMockVehicle
M.unregisterMockVehicle = unregisterMockVehicle

return M
