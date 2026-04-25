-- BCM Dealership App Extension
-- Vue bridge for brand dealership sites: enumerates vehicle brands/models at runtime,
-- serves catalog data grouped by category, computes fixed 200% prices, and handles
-- the full purchase flow (debit, spawn, inventory, garage, delivery timer).
-- Extension name: bcm_dealershipApp

local M = {}

-- ============================================================================
-- Forward declarations (ALL local functions declared before any body)
-- ============================================================================
local getAvailableBrands
local requestBrandCatalog
local requestVehicleDetail
local requestDealershipCheckout
local confirmDealershipPurchase
local getLanguage
local buildVehiclePool
local groupByBrand
local categorizeModels
local onCareerModulesActivated
local onBCMPurchaseVehicleReady
local buildReceiptEmailBody
local formatCentsForEmail
local resolveGarageList
local sendInsuranceOptionsForCheckout
local getDealershipMult

-- ============================================================================
-- Pending context tables (mirrors marketplaceApp pattern)
-- ============================================================================

-- Pending vehicle deletion: waits for partConditions capture before removing from world.
local pendingPurchaseDelete = {}  -- { [inventoryId] = { vehId, insuranceId } }

-- Pending purchase context: keyed by vehicle object ID (vehId).
local pendingPurchaseContext = {}  -- { [vehId] = { ... all purchase data ... } }

-- Cached brand/model data (refreshed on onCareerModulesActivated)
local _cachedBrands = nil

local logTag = 'bcm_dealershipApp'

-- Fixed color palette for new vehicle delivery
local COLOR_PALETTE = {
  { r = 0.05, g = 0.05, b = 0.05, name = "Black"  },
  { r = 0.95, g = 0.95, b = 0.95, name = "White"  },
  { r = 0.75, g = 0.75, b = 0.75, name = "Silver" },
  { r = 0.75, g = 0.05, b = 0.05, name = "Red"    },
  { r = 0.05, g = 0.15, b = 0.70, name = "Blue"   },
  { r = 0.05, g = 0.45, b = 0.10, name = "Green"  },
  { r = 0.45, g = 0.45, b = 0.45, name = "Grey"   },
  { r = 0.80, g = 0.70, b = 0.50, name = "Beige"  },
  { r = 0.85, g = 0.35, b = 0.00, name = "Orange" },
  { r = 0.90, g = 0.85, b = 0.05, name = "Yellow" },
}

-- Per-class dealership price multiplier (replaces flat Truck x1.5)
-- Applied on top of the 200% base markup to correct for class-level demand.
local CLASS_DEALERSHIP_MULT = {
  Economy   = 1.0, Sedan   = 1.0, Coupe    = 1.0,
  Sports    = 1.0, Muscle  = 1.0, Supercar = 1.0,
  Luxury    = 1.0, Family  = 1.0, OffRoad  = 1.0,
  SUV       = 1.0, Pickup  = 1.2, Van      = 1.2,
  Special   = 1.3, HeavyDuty = 1.5,
}

-- Tax rates (matches marketplace)
local REGISTRATION_TAX_RATE = 0.025
local SALES_TAX_RATE = 0.07

-- Express delivery surcharge in cents
local EXPRESS_SURCHARGE_CENTS = 200000  -- $2,000

-- ============================================================================
-- Helpers
-- ============================================================================

-- Get BCM dealership price multiplier for a pool entry.
-- Calls classifyVehicle from listingGenerator if available; falls back to BeamNG Type.
getDealershipMult = function(entry)
  local lg = extensions.isExtensionLoaded("career_modules_bcm_listingGenerator") and career_modules_bcm_listingGenerator
  if lg and lg.classifyVehicle then
    local bcmClass = lg.classifyVehicle(entry)
    return CLASS_DEALERSHIP_MULT[bcmClass] or 1.0
  end
  -- Fallback: use BeamNG raw Type field
  if (entry.Type or "") == "Truck" then return 1.5 end
  return 1.0
end

getLanguage = function()
  if bcm_settings and bcm_settings.getSetting then
    return bcm_settings.getSetting('language') or 'en'
  end
  return 'en'
end

formatCentsForEmail = function(cents)
  local dollars = math.floor(cents / 100)
  local remainder = cents % 100
  return string.format("$%d.%02d", dollars, remainder)
end

-- Build the full vehicle pool from util_configListGenerator.
-- Returns array of pool entries; each entry has: model_key, key (configKey),
-- Brand, Name, Type, Value, Years, etc.
buildVehiclePool = function()
  if util_configListGenerator and util_configListGenerator.getEligibleVehicles then
    return util_configListGenerator.getEligibleVehicles() or {}
  end
  return {}
end

-- Group pool entries by brand, collecting distinct models per brand.
-- Returns { [brandName] = { [modelKey] = { modelData, configs = {...} } } }
groupByBrand = function(pool)
  local byBrand = {}
  for _, entry in ipairs(pool) do
    local modelKey = entry.model_key
    if modelKey then
      local modelData = core_vehicles and core_vehicles.getModel and core_vehicles.getModel(modelKey)
      local brandRaw = (modelData and modelData.Brand) or (entry.Brand) or "Unknown"
      local brand = string.lower(brandRaw)
      if brand ~= "unknown" and brand ~= "" then
        if not byBrand[brand] then
          byBrand[brand] = {}
        end
        if not byBrand[brand][modelKey] then
          -- Get value from modelData, fallback to pool entry
          local modelValue = (modelData and modelData.Value) or entry.Value or 0

          -- Preview path: try modelData.preview first, then construct from BeamNG convention
          local previewPath = nil
          if modelData then
            if modelData.preview and modelData.preview ~= "" then
              previewPath = modelData.preview
            end
            if not previewPath then
              -- BeamNG stores vehicle previews at /vehicles/{modelKey}/default.png
              previewPath = "/vehicles/" .. modelKey .. "/default.png"
            end
          end

          byBrand[brand][modelKey] = {
            key = modelKey,
            brand = brand,
            displayBrand = brandRaw,
            name = (modelData and modelData.Name) or entry.Name or modelKey,
            type = (modelData and modelData.Type) or entry.Type or "Car",
            value = modelValue,
            year = (entry.Years and entry.Years.min) or 2020,
            preview = previewPath,
            configs = {},
          }
        end
        -- Append this config with specs
        local configValue = entry.Value or byBrand[brand][modelKey].value or 0
        -- Get config-specific preview from core_vehicles model configs
        local cfgPreview = nil
        if modelData and modelData.configs then
          local cfgData = modelData.configs[entry.key]
          if cfgData and cfgData.preview then
            cfgPreview = cfgData.preview
          end
        end
        -- HP: entry.Power → entry.aggregates.Power.min → nil
        local cfgPower = entry.Power
        if not cfgPower and entry.aggregates and entry.aggregates.Power then
          cfgPower = entry.aggregates.Power.max or entry.aggregates.Power.min
        end
        -- Weight: entry.Weight → entry.aggregates.Weight.min → nil
        local cfgWeight = entry.Weight
        if not cfgWeight and entry.aggregates and entry.aggregates.Weight then
          cfgWeight = entry.aggregates.Weight.min or entry.aggregates.Weight.max
        end
        table.insert(byBrand[brand][modelKey].configs, {
          configKey = entry.key,
          name = entry.Name or "Base",
          value = configValue,
          preview = cfgPreview,
          power = cfgPower,
          weight = cfgWeight,
        })
        -- Use first config's preview as model preview if model preview is nil
        if cfgPreview and not byBrand[brand][modelKey].preview then
          byBrand[brand][modelKey].preview = cfgPreview
        end
      end
    end
  end
  return byBrand
end

-- Assign a BeamNG vehicle type string to a user-friendly category.
-- Rules from plan:
--   "Car" + <200hp → "Sedans", 200-400hp → "Sports", 400+hp → "Performance"
--   (We approximate hp from type since we don't enumerate engine specs here)
--   "Truck" → "Trucks", "SUV" → "SUVs", "Van" → "Vans", default → "Other"
categorizeModels = function(modelsByKey)
  local categories = {}
  for modelKey, modelData in pairs(modelsByKey) do
    local bngType = modelData.type or "Car"
    local category
    if bngType == "Truck" then
      category = "Trucks"
    elseif bngType == "SUV" then
      category = "SUVs"
    elseif bngType == "Van" then
      category = "Vans"
    elseif bngType == "Car" then
      -- Use value as proxy for performance tier (lower value = economy/sedan)
      -- Under ~$25k = Sedan, $25k-$60k = Sports, over $60k = Performance
      local val = modelData.value or 0
      if val >= 60000 then
        category = "Performance"
      elseif val >= 25000 then
        category = "Sports"
      else
        category = "Sedans"
      end
    else
      category = "Other"
    end

    if not categories[category] then
      categories[category] = {}
    end

    -- Compute price range across all configs (200% markup)
    local minValue = nil
    local maxValue = nil
    for _, cfg in ipairs(modelData.configs) do
      local v = cfg.value or 0
      if v > 0 then
        if not minValue or v < minValue then minValue = v end
        if not maxValue or v > maxValue then maxValue = v end
      end
    end
    if not minValue then minValue = modelData.value or 5000 end
    if not maxValue then maxValue = minValue end
    if minValue <= 0 then minValue = 5000 end
    if maxValue <= 0 then maxValue = minValue end

    local minPriceCents = math.floor(minValue * 100 * 2)
    local maxPriceCents = math.floor(maxValue * 100 * 2)

    -- Best preview: first config preview → model preview → fallback
    local bestPreview = modelData.preview
    for _, cfg in ipairs(modelData.configs) do
      if cfg.preview then bestPreview = cfg.preview break end
    end
    if not bestPreview then
      bestPreview = "/vehicles/" .. modelKey .. "/default.png"
    end

    table.insert(categories[category], {
      modelKey = modelKey,
      displayName = modelData.name,
      configCount = #modelData.configs,
      minPriceCents = minPriceCents,
      maxPriceCents = maxPriceCents,
      basePrice = minPriceCents,
      type = modelData.type,
      year = modelData.year,
      preview = bestPreview,
    })
  end
  return categories
end

-- Enumerate garages for checkout (shared with marketplace pattern)
resolveGarageList = function(selectedGarageId)
  local garageList = {}
  local autoSelectedGarageId = selectedGarageId
  if bcm_properties and bcm_properties.getAllOwnedProperties then
    local props = bcm_properties.getAllOwnedProperties()
    for _, propData in ipairs(props or {}) do
      if propData.type == "garage" then
        local freeSlots = bcm_garages and bcm_garages.getFreeSlots and bcm_garages.getFreeSlots(propData.id) or 0
        local capacity = bcm_garages and bcm_garages.getCurrentCapacity and bcm_garages.getCurrentCapacity(propData.id) or 0
        local usedSlots = capacity - freeSlots
        table.insert(garageList, {
          id = propData.id,
          name = (bcm_garages and bcm_garages.getGarageDisplayName and bcm_garages.getGarageDisplayName(propData.id)) or propData.name or propData.id,
          freeSlots = freeSlots,
          totalSlots = capacity,
          usedSlots = usedSlots,
          hasSpace = freeSlots > 0,
        })
        if not autoSelectedGarageId and freeSlots > 0 then
          autoSelectedGarageId = propData.id
        end
      end
    end
  end
  return garageList, autoSelectedGarageId
end

buildReceiptEmailBody = function(data, lang)
  if lang == 'es' then
    return "Gracias por tu compra.\n\n" ..
           "Vehiculo: " .. (data.vehicleTitle or "") .. "\n" ..
           "Precio: " .. formatCentsForEmail(data.priceCents) .. "\n" ..
           "Tasa de matriculacion: " .. formatCentsForEmail(data.registrationTaxCents) .. "\n" ..
           "Impuesto de ventas: " .. formatCentsForEmail(data.salesTaxCents) .. "\n" ..
           (data.expressCents and data.expressCents > 0 and ("Entrega express: " .. formatCentsForEmail(data.expressCents) .. "\n") or "") ..
           "Total: " .. formatCentsForEmail(data.totalCents) .. "\n\n" ..
           "Tu vehiculo ha sido enviado a: " .. (data.garageName or "") .. "\n\n" ..
           (data.brandName or "Concesionario Oficial") .. " — Calidad garantizada."
  else
    return "Thank you for your purchase.\n\n" ..
           "Vehicle: " .. (data.vehicleTitle or "") .. "\n" ..
           "Price: " .. formatCentsForEmail(data.priceCents) .. "\n" ..
           "Registration tax: " .. formatCentsForEmail(data.registrationTaxCents) .. "\n" ..
           "Sales tax: " .. formatCentsForEmail(data.salesTaxCents) .. "\n" ..
           (data.expressCents and data.expressCents > 0 and ("Express delivery: " .. formatCentsForEmail(data.expressCents) .. "\n") or "") ..
           "Total: " .. formatCentsForEmail(data.totalCents) .. "\n\n" ..
           "Your vehicle has been delivered to: " .. (data.garageName or "") .. "\n\n" ..
           (data.brandName or "Official Dealership") .. " — Built to last."
  end
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Enumerate all brands that have 3+ distinct models.
-- Sends BCMDealershipBrands event with { brands } array.
getAvailableBrands = function()
  local pool = buildVehiclePool()
  if #pool == 0 then
    guihooks.trigger('BCMDealershipBrands', { brands = {} })
    return
  end

  local byBrand = groupByBrand(pool)
  local result = {}

  for brand, modelsByKey in pairs(byBrand) do
    -- Count distinct models (NOT configs)
    local modelCount = 0
    for _ in pairs(modelsByKey) do
      modelCount = modelCount + 1
    end

    if modelCount >= 3 then
      -- Get display name from first model's displayBrand (preserves original casing)
      local displayName = brand
      for _, m in pairs(modelsByKey) do
        if m.displayBrand then displayName = m.displayBrand break end
      end
      table.insert(result, {
        brandKey = brand,
        displayName = displayName,
        modelCount = modelCount,
      })
    end
  end

  -- Sort alphabetically for consistent ordering
  table.sort(result, function(a, b) return a.brandKey < b.brandKey end)

  _cachedBrands = result
  log('I', logTag, 'getAvailableBrands: found ' .. #result .. ' qualifying brands')
  guihooks.trigger('BCMDealershipBrands', { brands = result })
end

-- Serve full catalog for a brand, grouped by category.
-- brandKey: brand display name (e.g. "Gavril")
requestBrandCatalog = function(brandKey)
  if not brandKey then
    guihooks.trigger('BCMDealershipCatalog', { error = "missing_brand" })
    return
  end
  brandKey = string.lower(brandKey)

  local pool = buildVehiclePool()
  local byBrand = groupByBrand(pool)
  local modelsByKey = byBrand[brandKey]

  if not modelsByKey then
    guihooks.trigger('BCMDealershipCatalog', { brand = brandKey, categories = {} })
    log('W', logTag, 'requestBrandCatalog: no models found for brand: ' .. tostring(brandKey))
    return
  end

  local categories = categorizeModels(modelsByKey)

  -- Sort models within each category by displayName
  for _, catModels in pairs(categories) do
    table.sort(catModels, function(a, b) return (a.displayName or "") < (b.displayName or "") end)
  end

  log('I', logTag, 'requestBrandCatalog: ' .. tostring(brandKey) .. ' -> ' .. tostring(#pool) .. ' pool entries')
  guihooks.trigger('BCMDealershipCatalog', {
    brand = brandKey,
    categories = categories,
  })
end

-- Serve full detail for a single model: all configs with 200% prices, specs, color options.
requestVehicleDetail = function(brandKey, modelKey)
  if not modelKey then
    guihooks.trigger('BCMDealershipDetail', { error = "missing_model" })
    return
  end
  if brandKey then brandKey = string.lower(brandKey) end

  local modelData = core_vehicles and core_vehicles.getModel and core_vehicles.getModel(modelKey)
  if not modelData then
    guihooks.trigger('BCMDealershipDetail', { error = "model_not_found" })
    return
  end

  -- Gather all configs for this model from the pool
  local pool = buildVehiclePool()
  local configs = {}
  local firstConfigPreview = nil
  for _, entry in ipairs(pool) do
    if entry.model_key == modelKey then
      local configValue = entry.Value or modelData.Value or 0
      if configValue <= 0 then configValue = modelData.Value or 5000 end
      -- Get config-specific preview
      local cfgPreview = nil
      if modelData.configs and modelData.configs[entry.key] then
        cfgPreview = modelData.configs[entry.key].preview
      end
      if cfgPreview and not firstConfigPreview then
        firstConfigPreview = cfgPreview
      end
      -- HP and weight per config
      local cfgPower = entry.Power
      if not cfgPower and entry.aggregates and entry.aggregates.Power then
        cfgPower = entry.aggregates.Power.max or entry.aggregates.Power.min
      end
      local cfgWeight = entry.Weight
      if not cfgWeight and entry.aggregates and entry.aggregates.Weight then
        cfgWeight = entry.aggregates.Weight.min or entry.aggregates.Weight.max
      end
      table.insert(configs, {
        configKey = entry.key,
        name = entry.Name or "Base",
        value = configValue,
        priceCents = math.floor(configValue * 100 * 2 * getDealershipMult(entry)),  -- 200% base, per-class multiplier
        years = entry.Years,
        preview = cfgPreview,
        power = cfgPower,
        weight = cfgWeight,
      })
    end
  end

  if #configs == 0 then
    guihooks.trigger('BCMDealershipDetail', { error = "no_configs" })
    return
  end

  -- Sort configs by price
  table.sort(configs, function(a, b) return (a.priceCents or 0) < (b.priceCents or 0) end)

  -- Build color list from palette
  local colorOptions = {}
  for i, c in ipairs(COLOR_PALETTE) do
    table.insert(colorOptions, { index = i - 1, name = c.name, r = c.r, g = c.g, b = c.b })
  end

  -- Preview path: try first config preview (most reliable), then modelData.preview, then fallback
  local detailPreview = firstConfigPreview
  if not detailPreview and modelData.preview and modelData.preview ~= "" then
    detailPreview = modelData.preview
  end
  if not detailPreview then
    detailPreview = "/vehicles/" .. modelKey .. "/default.png"
  end

  guihooks.trigger('BCMDealershipDetail', {
    brandKey = brandKey,
    modelKey = modelKey,
    displayName = modelData.Name or modelKey,
    brand = modelData.Brand or brandKey,
    type = modelData.Type or "Car",
    year = modelData.Year or 2020,
    value = modelData.Value or 0,
    preview = detailPreview,
    configs = configs,
    colorOptions = colorOptions,
    basePrice = configs[1] and configs[1].priceCents or 0,
  })
end

-- Compute and send checkout data (price breakdown, taxes, garages, balance).
-- deliveryType: "standard" | "express"
requestDealershipCheckout = function(modelKey, configKey, colorIndex, deliveryType)
  if not modelKey or not configKey then
    guihooks.trigger('BCMDealershipCheckout', { error = "missing_params" })
    return
  end

  -- Resolve config value from vehicle pool
  local pool = buildVehiclePool()
  local configValue = 0
  local entryType = "Car"
  local modelData = core_vehicles and core_vehicles.getModel and core_vehicles.getModel(modelKey)

  for _, entry in ipairs(pool) do
    if entry.model_key == modelKey and entry.key == configKey then
      configValue = entry.Value or 0
      entryType = entry.Type or "Car"
      break
    end
  end

  -- Fallback chain: model value → weight-based estimate
  if configValue <= 0 then
    configValue = (modelData and modelData.Value) or 0
  end
  if configValue <= 0 then
    configValue = 5000  -- $5k floor
  end

  local dealerMult = getDealershipMult({ Type = entryType, Value = configValue })
  local priceCents = math.floor(configValue * 100 * 2 * dealerMult)  -- 200% base, per-class multiplier

  -- Express surcharge
  local expressCents = 0
  if deliveryType == "express" then
    expressCents = EXPRESS_SURCHARGE_CENTS
  end

  -- Taxes
  local registrationTaxCents = math.floor(priceCents * REGISTRATION_TAX_RATE)
  local salesTaxCents = math.floor(priceCents * SALES_TAX_RATE)

  -- Insurance options (filtered by vehicle insurance class — same as vanilla)
  local insuranceOptions = {}
  table.insert(insuranceOptions, { id = -1, name = "No insurance", premium = 0 })

  -- Determine applicable insurance class from vehicle config
  -- NOTE: configList.configs keys use format "modelKey_configKey", not bare configKey.
  -- We search by config.key field to handle the format mismatch.
  local applicableClassId = nil
  if configKey and career_modules_insurance_insurance then
    local configList = core_vehicles and core_vehicles.getConfigList and core_vehicles.getConfigList()
    if configList and configList.configs then
      local configData = nil
      for _, cfg in pairs(configList.configs) do
        if cfg.key == configKey then configData = cfg break end
      end
      if configData then
        local ok, insuranceClass = pcall(career_modules_insurance_insurance.getInsuranceClassFromVehicleShoppingData, configData)
        if ok and insuranceClass then
          applicableClassId = insuranceClass.id
        end
      else
        log("W", logTag, "requestDealershipCheckout: no configList entry for configKey='" .. tostring(configKey) .. "'")
      end
    end
  end

  if career_modules_insurance_insurance then
    for id = 1, 20 do
      local ok, card = pcall(function()
        local raw = career_modules_insurance_insurance.getInsuranceDataById(id)
        if not raw then return nil end
        -- Filter: skip insurances that don't match the vehicle's class
        if applicableClassId and raw.class and raw.class ~= applicableClassId then
          return nil
        end
        return { id = id, name = raw.name or ("Policy " .. tostring(id)), premium = 0 }
      end)
      if ok and card then
        table.insert(insuranceOptions, card)
      end
    end
  end

  -- Garage list
  local garageList, autoSelectedGarageId = resolveGarageList(nil)

  -- Player balance
  local balanceCents = 0
  local personalAccount = bcm_banking and bcm_banking.getPersonalAccount and bcm_banking.getPersonalAccount()
  if personalAccount then
    balanceCents = personalAccount.balance or 0
  end

  local totalCents = priceCents + registrationTaxCents + salesTaxCents + expressCents

  local colorName = "Black"
  local ci = tonumber(colorIndex) or 0
  if ci >= 0 and ci < #COLOR_PALETTE then
    colorName = COLOR_PALETTE[ci + 1].name
  end

  guihooks.trigger('BCMDealershipCheckout', {
    modelKey = modelKey,
    configKey = configKey,
    colorIndex = ci,
    colorName = colorName,
    deliveryType = deliveryType or "standard",
    vehicleTitle = (modelData and modelData.Name) or modelKey,
    vehicleBrand = (modelData and modelData.Brand) or "",
    preview = (modelData and modelData.configs and modelData.configs[configKey] and modelData.configs[configKey].preview) or (modelData and modelData.preview and modelData.preview ~= "" and modelData.preview) or (modelKey and ("/vehicles/" .. modelKey .. "/default.png")) or nil,
    priceCents = priceCents,
    expressCents = expressCents,
    registrationTaxCents = registrationTaxCents,
    salesTaxCents = salesTaxCents,
    totalCents = totalCents,
    balanceCents = balanceCents,
    canAfford = balanceCents >= totalCents,
    garageList = garageList,
    selectedGarageId = autoSelectedGarageId,
    hasGarageSpace = autoSelectedGarageId ~= nil,
    insuranceOptions = insuranceOptions,
    selectedInsuranceId = -1,
  })
end

-- Full purchase flow: debit → spawn (0km/perfect) → initConditions → addVehicle → garage → delivery timer → notify.
-- source = "dealership" tag on BCMPurchaseResult event for store filtering.
confirmDealershipPurchase = function(modelKey, configKey, colorIndex, garageId, deliveryType, insuranceId)
  if not modelKey or not configKey then
    guihooks.trigger('BCMPurchaseResult', { success = false, error = "missing_params", source = "dealership" })
    return
  end

  -- Resolve config value
  local pool = buildVehiclePool()
  local configValue = 0
  local entryType2 = "Car"
  local modelData = core_vehicles and core_vehicles.getModel and core_vehicles.getModel(modelKey)

  for _, entry in ipairs(pool) do
    if entry.model_key == modelKey and entry.key == configKey then
      configValue = entry.Value or 0
      entryType2 = entry.Type or "Car"
      break
    end
  end

  if configValue <= 0 then
    configValue = (modelData and modelData.Value) or 0
  end
  if configValue <= 0 then configValue = 5000 end

  local dealerMult = getDealershipMult({ Type = entryType2, Value = configValue })
  local priceCents = math.floor(configValue * 100 * 2 * dealerMult)  -- 200% base, per-class multiplier

  -- Express surcharge
  local expressCents = 0
  if deliveryType == "express" then
    expressCents = EXPRESS_SURCHARGE_CENTS
  end

  -- Taxes
  local registrationTaxCents = math.floor(priceCents * REGISTRATION_TAX_RATE)
  local salesTaxCents = math.floor(priceCents * SALES_TAX_RATE)

  -- Insurance premium
  local insurancePremiumCents = 0
  local insId = tonumber(insuranceId) or -1
  if insId >= 0 and career_modules_insurance_insurance then
    pcall(function()
      local vehValueDollars = math.floor(priceCents / 100)
      local premium = career_modules_insurance_insurance.calculateAddVehiclePrice(insId, vehValueDollars)
      insurancePremiumCents = premium and math.floor(premium * 100) or 0
    end)
  end

  local totalCents = priceCents + registrationTaxCents + salesTaxCents + expressCents + insurancePremiumCents

  -- Check funds
  local personalAccount = bcm_banking and bcm_banking.getPersonalAccount and bcm_banking.getPersonalAccount()
  if not personalAccount or personalAccount.balance < totalCents then
    guihooks.trigger('BCMPurchaseResult', {
      success = false,
      error = "insufficient_funds",
      requiredCents = totalCents,
      balanceCents = personalAccount and personalAccount.balance or 0,
      source = "dealership",
    })
    return
  end

  -- Resolve and validate garage
  local targetGarageId = garageId
  if not targetGarageId or targetGarageId == "" then
    if bcm_properties and bcm_properties.getAllOwnedProperties then
      local props = bcm_properties.getAllOwnedProperties()
      for _, propData in ipairs(props or {}) do
        if propData.type == "garage" then
          local freeSlots = bcm_garages and bcm_garages.getFreeSlots and bcm_garages.getFreeSlots(propData.id)
          if freeSlots and freeSlots > 0 then
            targetGarageId = propData.id
            break
          end
        end
      end
    end
  end

  if not targetGarageId then
    guihooks.trigger('BCMPurchaseResult', {
      success = false,
      error = "no_garage_space",
      source = "dealership",
    })
    return
  end

  -- Race condition guard: garage still has space?
  local freeCheck = bcm_garages and bcm_garages.getFreeSlots and bcm_garages.getFreeSlots(targetGarageId)
  if not freeCheck or freeCheck <= 0 then
    guihooks.trigger('BCMPurchaseResult', {
      success = false,
      error = "no_garage_space",
      source = "dealership",
    })
    return
  end

  -- Debit BEFORE spawn (prevents race conditions)
  local brandName = (modelData and modelData.Brand) or "Dealership"
  local vehicleName = (modelData and modelData.Name) or modelKey
  local transactionDesc = brandName .. " Dealership: " .. vehicleName
  local removedOk = bcm_banking.removeFunds(personalAccount.id, totalCents, "vehicle_purchase", transactionDesc)
  if not removedOk then
    guihooks.trigger('BCMPurchaseResult', { success = false, error = "insufficient_funds", source = "dealership" })
    return
  end

  -- Spawn vehicle (with config, no auto-enter)
  local spawnOpts = { config = configKey, autoEnterVehicle = false }
  local prevVehId = be:getPlayerVehicleID(0)
  local newVeh = core_vehicles.spawnNewVehicle(modelKey, spawnOpts)

  if not newVeh then
    bcm_banking.addFunds(personalAccount.id, totalCents, "refund", transactionDesc .. ": spawn failed")
    guihooks.trigger('BCMPurchaseResult', { success = false, error = "spawn_failed", source = "dealership" })
    return
  end

  local vehId = newVeh:getID()
  core_vehicleBridge.executeAction(newVeh, 'setIgnitionLevel', 0)

  -- Restore player focus
  if prevVehId and prevVehId > 0 then
    be:enterVehicle(0, be:getObjectByID(prevVehId))
  end

  -- Resolve color from palette
  local ci = tonumber(colorIndex) or 0
  if ci < 0 or ci >= #COLOR_PALETTE then ci = 0 end
  local colorData = COLOR_PALETTE[ci + 1]

  -- Store purchase context for async callback
  pendingPurchaseContext[vehId] = {
    modelKey = modelKey,
    configKey = configKey,
    colorIndex = ci,
    colorData = colorData,
    targetGarageId = targetGarageId,
    deliveryType = deliveryType or "standard",
    selectedInsuranceId = insId,
    priceCents = priceCents,
    expressCents = expressCents,
    registrationTaxCents = registrationTaxCents,
    salesTaxCents = salesTaxCents,
    insurancePremiumCents = insurancePremiumCents,
    totalCents = totalCents,
    personalAccountId = personalAccount.id,
    brandName = brandName,
    vehicleName = vehicleName,
    transactionDesc = transactionDesc,
  }

  -- New vehicle: 0 mileage, visualValue = 1.0 (perfect condition, brand new)
  local mileageMeters = 0
  local visualValue = 1.0
  log('I', logTag, 'initConditions: vehId=' .. tostring(vehId) .. ' mileage=0m visual=1.0 (brand new)')

  newVeh:queueLuaCommand(string.format(
    "partCondition.initConditions(nil, %d, nil, %f) obj:queueGameEngineLua('bcm_dealershipApp.onBCMPurchaseVehicleReady(%d)')",
    mileageMeters, visualValue, vehId
  ))
end

-- Called asynchronously after partCondition.initConditions completes.
onBCMPurchaseVehicleReady = function(vehId)
  local ctx = pendingPurchaseContext[vehId]
  pendingPurchaseContext[vehId] = nil

  if not ctx then
    log('E', logTag, 'onBCMPurchaseVehicleReady: no context for vehId=' .. tostring(vehId))
    return
  end

  -- Now safe to addVehicle (partConditions are captured)
  local inventoryId = nil
  if career_modules_inventory and career_modules_inventory.addVehicle then
    inventoryId = career_modules_inventory.addVehicle(vehId)
  end

  if not inventoryId then
    log('E', logTag, 'onBCMPurchaseVehicleReady: addVehicle failed for vehId=' .. tostring(vehId))
    bcm_banking.addFunds(ctx.personalAccountId, ctx.totalCents, "refund", ctx.transactionDesc .. ": addVehicle failed")
    guihooks.trigger('BCMPurchaseResult', { success = false, error = "spawn_failed", source = "dealership" })
    return
  end

  -- Set metadata on inventory vehicle
  local vehicles = career_modules_inventory.getVehicles()
  if vehicles and vehicles[inventoryId] then
    vehicles[inventoryId].year = 2024  -- brand new model year
    vehicles[inventoryId].bcmPurchasePriceCents = ctx.totalCents
    vehicles[inventoryId].bcmListingPriceCents = ctx.priceCents
    vehicles[inventoryId].bcmSource = "dealership"
  end

  -- Assign vehicle to garage (same flow as marketplace — triggers BCMPropertyUpdate)
  if ctx.targetGarageId and ctx.targetGarageId ~= "" then
    if bcm_properties and bcm_properties.assignVehicleToGarage then
      bcm_properties.assignVehicleToGarage(inventoryId, ctx.targetGarageId)
    else
      -- Fallback: direct location set if bcm_properties not available
      if vehicles and vehicles[inventoryId] then
        vehicles[inventoryId].location = ctx.targetGarageId
        vehicles[inventoryId].niceLocation = (bcm_garages and bcm_garages.getGarageDisplayName and bcm_garages.getGarageDisplayName(ctx.targetGarageId)) or ctx.targetGarageId
      end
    end
    log('I', logTag, 'assignVehicleToGarage: inv=' .. tostring(inventoryId) .. ' -> garage=' .. tostring(ctx.targetGarageId))
  end

  -- Defer vehicle deletion until partConditions captured
  pendingPurchaseDelete[inventoryId] = {
    vehId = vehId,
    insuranceId = ctx.selectedInsuranceId,
    colorData = ctx.colorData,
  }

  -- Resolve garage display name
  local garageName = ctx.targetGarageId
  if bcm_garages and bcm_garages.getGarageDisplayName then
    garageName = bcm_garages.getGarageDisplayName(ctx.targetGarageId) or ctx.targetGarageId
  end

  -- Delivery timer
  local deliveryDelaySecs = 0
  if ctx.deliveryType ~= "express" then
    deliveryDelaySecs = math.random(60, 300)
    pcall(function()
      if career_modules_inventory.delayVehicleAccess then
        career_modules_inventory.delayVehicleAccess(inventoryId, deliveryDelaySecs, "bought")
      elseif career_modules_inventory.getVehicles then
        local delayVehicles = career_modules_inventory.getVehicles()
        if delayVehicles[inventoryId] then
          delayVehicles[inventoryId].timeToAccess = deliveryDelaySecs
        end
      end
    end)
    log('I', logTag, 'Standard delivery: ' .. deliveryDelaySecs .. 's for inv=' .. tostring(inventoryId))
  else
    log('I', logTag, 'Express delivery: immediate access for inv=' .. tostring(inventoryId))
  end

  -- Post-purchase notification
  if bcm_notifications and bcm_notifications.send then
    bcm_notifications.send({
      titleKey = "notif.purchaseComplete",
      bodyKey = "notif.purchaseCompleteBody",
      type = "success",
      duration = 6000,
    })
  end

  -- Fire BCMPurchaseResult (source = "dealership" so store can distinguish)
  guihooks.trigger('BCMPurchaseResult', {
    success = true,
    source = "dealership",
    inventoryId = inventoryId,
    garageId = ctx.targetGarageId,
    targetGarageName = garageName,
    garageName = garageName,
    vehicleTitle = ctx.brandName .. " " .. ctx.vehicleName,
    vehicleName = ctx.vehicleName,
    brandName = ctx.brandName,
    priceCents = ctx.priceCents,
    expressCents = ctx.expressCents,
    registrationTaxCents = ctx.registrationTaxCents,
    salesTaxCents = ctx.salesTaxCents,
    totalCents = ctx.totalCents,
    deliveryDelaySecs = deliveryDelaySecs,
    deliveryType = ctx.deliveryType,
    purchaseGameDay = 0,  -- no game day needed for dealership
  })

  -- Email receipt
  if bcm_email and bcm_email.deliver then
    local lang = getLanguage()
    local vehicleTitle = ctx.brandName .. " " .. ctx.vehicleName
    local subject = lang == 'es'
      and ("Confirmacion de compra: " .. vehicleTitle)
      or ("Purchase confirmation: " .. vehicleTitle)
    local body = buildReceiptEmailBody({
      vehicleTitle = vehicleTitle,
      priceCents = ctx.priceCents,
      registrationTaxCents = ctx.registrationTaxCents,
      salesTaxCents = ctx.salesTaxCents,
      expressCents = ctx.expressCents,
      totalCents = ctx.totalCents,
      garageName = garageName,
      brandName = ctx.brandName,
    }, lang)
    local fromEmail = string.lower(ctx.brandName):gsub("%s+", "") .. "-motors.com"
    bcm_email.deliver({
      folder = "inbox",
      from_display = ctx.brandName .. " Official Dealership",
      from_email = "noreply@" .. fromEmail,
      subject = subject,
      body = body,
      is_spam = false,
    })
  end

  log('I', logTag, 'Dealership vehicle purchased (async): inv=' .. tostring(inventoryId) .. ' -> ' .. tostring(ctx.targetGarageId))
end

-- ============================================================================
-- Deferred vehicle deletion callback (vanilla pattern — matches marketplaceApp)
-- ============================================================================

local function onAddedVehiclePartsToInventory(inventoryId, newParts)
  local info = pendingPurchaseDelete[inventoryId]
  if not info then return end
  pendingPurchaseDelete[inventoryId] = nil

  local vehicle = career_modules_inventory.getVehicles()[inventoryId]
  if vehicle then
    vehicle.originalParts = {}
    if newParts then
      for _, part in pairs(newParts) do
        if part.containingSlot and part.name then
          vehicle.originalParts[part.containingSlot] = { name = part.name, value = part.value }
        end
      end
    end
    vehicle.changedSlots = {}
  end

  -- Fire vanilla hook (initialises insurance for this vehicle)
  extensions.hook("onVehicleAddedToInventory", {
    inventoryId = inventoryId,
    purchaseData = { insuranceId = info.insuranceId or -1 },
  })
  log('I', logTag, 'Fired onVehicleAddedToInventory hook for inv=' .. tostring(inventoryId))

  -- Force save so insurance.json stays in sync with inventory.
  -- Without this, an autosave between addVehicle (sync) and this callback (async)
  -- can persist the vehicle in inventory but NOT in insurance → repairScreen crash.
  if career_saveSystem and career_saveSystem.saveCurrent then
    career_saveSystem.saveCurrent()
  end

  -- Remove physical vehicle from world
  if career_modules_inventory and career_modules_inventory.removeVehicleObject then
    career_modules_inventory.removeVehicleObject(inventoryId)
  else
    local obj = be:getObjectByID(info.vehId)
    if obj then obj:delete() end
  end
  log('I', logTag, 'Deferred delete complete for inv=' .. tostring(inventoryId) .. ' vehId=' .. tostring(info.vehId))
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

onCareerModulesActivated = function()
  -- Pre-enumerate brands and cache for quick access
  local pool = buildVehiclePool()
  if #pool > 0 then
    getAvailableBrands()
    log('I', logTag, 'Dealership app activated — brands enumerated')
  else
    log('W', logTag, 'Dealership app activated — vehicle pool empty (career may not be loaded yet)')
  end

  -- Repair broken saves: inventory vehicles missing from insurance module.
  -- This can happen when a BCM purchase's async onAddedVehiclePartsToInventory
  -- callback hadn't fired before an autosave captured the inventory but not insurance.
  pcall(function()
    local insuranceModule = career_modules_insurance_insurance
    if not insuranceModule or not insuranceModule.getInvVehs then return end
    local invVehs = insuranceModule.getInvVehs()
    local allVehicles = career_modules_inventory and career_modules_inventory.getVehicles()
    if not allVehicles then return end

    local repaired = 0
    for invId, vehData in pairs(allVehicles) do
      if vehData.owned and not invVehs[invId] then
        -- Vehicle exists in inventory but not in insurance — register it now
        extensions.hook("onVehicleAddedToInventory", {
          inventoryId = invId,
          purchaseData = { insuranceId = -1 },  -- no insurance (user can pick one later)
        })
        repaired = repaired + 1
        log('W', logTag, 'Repaired missing insurance entry for inv=' .. tostring(invId) .. ' (' .. tostring(vehData.niceName) .. ')')
      end
    end
    if repaired > 0 then
      log('I', logTag, 'Insurance repair: fixed ' .. repaired .. ' vehicle(s) missing from insurance module')
      if career_saveSystem and career_saveSystem.saveCurrent then
        career_saveSystem.saveCurrent()
      end
    end
  end)
end

-- ============================================================================
-- Vanilla insurance popup bridge (mirrors marketplaceApp pattern)
-- Sends filtered insurance cards to ChooseInsuranceMain.vue popup.
-- ============================================================================

sendInsuranceOptionsForCheckout = function(vehValueDollars, vehName, currentInsuranceId, vehicleConfigKey)
  local vehInfo = { Name = vehName or "Vehicle", Value = vehValueDollars or 0 }
  local cards = {}

  -- "No insurance" card (always first)
  table.insert(cards, {
    id = -1,
    name = "No insurance",
    perks = {
      { id = "noInsurance", intro = "Full repair cost", value = 0, valueType = "boolean" },
      { id = "noInsurance", intro = "No coverage", value = 0, valueType = "boolean" },
      { id = "noInsurance", intro = "Not recommended", value = 0, valueType = "boolean" },
    },
    addVehiclePrice = 0,
    amountDue = 0,
    carsInsuredCount = 0,
    groupDiscountData = { currentTierData = { id = 0, discount = 0 } },
    paperworkFees = 0,
  })

  if career_modules_insurance_insurance then
    -- Determine applicable insurance class from vehicle config
    local applicableClassId = nil
    if vehicleConfigKey then
      -- NOTE: configList.configs keys use format "modelKey_configKey", not bare configKey.
      -- We search by config.key field to handle the format mismatch.
      local configList = core_vehicles and core_vehicles.getConfigList and core_vehicles.getConfigList()
      if configList and configList.configs then
        local configData = nil
        for _, cfg in pairs(configList.configs) do
          if cfg.key == vehicleConfigKey then configData = cfg break end
        end
        if configData then
          local ok, insuranceClass = pcall(career_modules_insurance_insurance.getInsuranceClassFromVehicleShoppingData, configData)
          if ok and insuranceClass then
            applicableClassId = insuranceClass.id
            log("I", logTag, "Insurance class for config '" .. tostring(vehicleConfigKey) .. "': " .. tostring(applicableClassId))
          end
        else
          log("W", logTag, "sendInsuranceOptionsForCheckout: no configList entry for configKey='" .. tostring(vehicleConfigKey) .. "'")
        end
      end
    end

    for id = 1, 20 do
      local ok, card = pcall(function()
        local raw = career_modules_insurance_insurance.getInsuranceDataById(id)
        if not raw then return nil end

        -- Filter: skip insurances that don't match the vehicle's class
        if applicableClassId and raw.class and raw.class ~= applicableClassId then
          return nil
        end

        local premium = career_modules_insurance_insurance.calculateAddVehiclePrice(id, vehValueDollars) or 0

        local baseDeductiblePrice = 0
        if raw.coverageOptions and raw.coverageOptions.deductible and raw.coverageOptions.deductible.choices then
          local choice = raw.coverageOptions.deductible.choices[2]
          if choice then baseDeductiblePrice = choice.value or 0 end
        end

        local perksArray = {}
        if raw.perks then
          for perkId, perkData in pairs(raw.perks) do
            local p = deepcopy(perkData)
            p.id = perkId
            table.insert(perksArray, p)
          end
        end

        return {
          id = raw.id,
          name = raw.name,
          slogan = raw.slogan,
          color = raw.color or "#666",
          image = raw.image and ("gameplay/insurance/providers/" .. raw.image .. ".png") or nil,
          perks = perksArray,
          paperworkFees = raw.paperworkFees or 0,
          addVehiclePrice = premium,
          amountDue = premium,
          vehicleName = vehInfo.Name,
          vehicleValue = vehInfo.Value,
          baseDeductibledData = { price = baseDeductiblePrice },
          futurePremiumDetails = career_modules_insurance_insurance.calculateInsurancePremium(id, nil, nil, vehValueDollars) or { totalPriceWithDriverScore = 0 },
          carsInsuredCount = 0,
          groupDiscountData = { currentTierData = { id = 0, discount = 0 } },
        }
      end)
      if ok and card then
        table.insert(cards, card)
      end
    end
  end

  table.sort(cards, function(a, b) return (a.id or 0) < (b.id or 0) end)

  local driverScore = 0
  pcall(function() driverScore = career_modules_insurance_insurance.getDriverScore() or 0 end)

  guihooks.trigger('chooseInsuranceData', {
    applicableInsurancesData = cards,
    purchaseData = {},
    vehicleInfo = vehInfo,
    driverScoreData = { score = driverScore, tier = {} },
    defaultInsuranceId = currentInsuranceId,
    currentInsuranceId = nil,
  })
end

-- ============================================================================
-- Module exports
-- ============================================================================

M.getAvailableBrands          = getAvailableBrands
M.requestBrandCatalog         = requestBrandCatalog
M.requestVehicleDetail        = requestVehicleDetail
M.requestDealershipCheckout   = requestDealershipCheckout
M.confirmDealershipPurchase   = confirmDealershipPurchase
M.onBCMPurchaseVehicleReady   = onBCMPurchaseVehicleReady
M.onCareerModulesActivated    = onCareerModulesActivated
M.onAddedVehiclePartsToInventory = onAddedVehiclePartsToInventory
M.sendInsuranceOptionsForCheckout = sendInsuranceOptionsForCheckout

return M
