-- BCM Real Estate App Extension
-- Handles property purchase flow, sell system, property taxes, and Vue bridge.
-- Bridges between the belascorealty.com IE website and the BCM property/garage system.
-- Extension name: bcm_realEstateApp
-- Loaded by bcm_extensionManager after bcm_garages.

local M = {}

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
local sendDefinitionsToVue
local requestPurchase
local requestSell
local requestSellForced
local navigateToGarage
local getSellEstimate
local sendSellEstimateToUI
local collectMonthlyTaxes
local checkTaxSeizure
local getTaxRate
local getTaxDebt
local relocateVehicles
local onCareerModulesActivated
local onDayAdvanced
local onSaveCurrentSaveSlot
local loadTaxData
local saveTaxData
-- cross-map + rentals bridges
local sendCrossMapDefinitionsToVue
local sendActiveRentalsToVue
local requestStartRental
local requestCancelRental
local requestCrossMapPurchase
local sendGarageOffersForMap

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_realEstateApp'

-- Monthly property tax rates by tier (in cents)
-- T0 = $500/mo, T1 = $1,200/mo, T2 = $2,500/mo
local TAX_RATES = {
  [0] = 50000,
  [1] = 120000,
  [2] = 250000
}

-- Months of unpaid taxes before seizure
local SEIZURE_MONTHS = 12

-- Sell price range (percentage of base price)
local SELL_MIN_PERCENT = 50
local SELL_MAX_PERCENT = 80

-- ============================================================================
-- Private state
-- ============================================================================

-- Tax debt per garage: { [garageId] = amountCents }
local taxDebt = {}

-- Tax history per garage: { [garageId] = { lastChargedMonth = N, consecutiveUnpaid = N } }
local taxHistory = {}

-- Last processed month (to detect month changes)
local lastProcessedMonth = 0

-- Activated flag
local activated = false

-- ============================================================================
-- Definitions bridge (Vue <-> Lua)
-- ============================================================================

sendDefinitionsToVue = function()
  if not bcm_garages then
    log('W', logTag, 'sendDefinitionsToVue: bcm_garages not available')
    return
  end

  -- Get all garage definitions and convert to array. Backup garages are
  -- excluded from the Realty catalogue â€” they're not purchaseable property,
  -- they're the free-tier fallback lodging grant for maps where the player
  -- owns nothing, so surfacing them as "for sale" would be misleading.
  local allDefs = bcm_garages.getAllDefinitions() or {}
  local defsArray = {}
  for _, def in pairs(allDefs) do
    if not (def.isBackupGarage or def.type == "backup") then
      table.insert(defsArray, def)
    end
  end

  -- Get owned property IDs (garage type only)
  local ownedArray = {}
  if bcm_properties then
    local ownedProps = bcm_properties.getAllOwnedProperties() or {}
    for _, prop in ipairs(ownedProps) do
      if prop.type == "garage" then
        table.insert(ownedArray, prop.id)
      end
    end
  end

  -- Get player balance
  local balance = 0
  if bcm_banking then
    local account = bcm_banking.getPersonalAccount()
    if account then
      balance = account.balance or 0
    end
  end

  guihooks.trigger('BCMPropertyDefinitions', {
    definitions = defsArray,
    ownedIds = ownedArray,
    balance = balance
  })

  log('I', logTag, 'Sent ' .. #defsArray .. ' definitions to Vue (' .. #ownedArray .. ' owned, balance=' .. balance .. ')')
end

-- ============================================================================
-- Purchase flow
-- ============================================================================

requestPurchase = function(garageId)
  -- Guard: definition exists
  local def = bcm_garages and bcm_garages.getGarageDefinition(garageId)
  if not def then
    guihooks.trigger('BCMPropertyPurchaseResult', {
      success = false, reason = 'notFound', garageId = garageId
    })
    log('W', logTag, 'requestPurchase: No definition found for ' .. tostring(garageId))
    return
  end

  -- Guard: not already owned
  if bcm_properties and bcm_properties.isOwned(garageId) then
    guihooks.trigger('BCMPropertyPurchaseResult', {
      success = false, reason = 'alreadyOwned', garageId = garageId
    })
    log('W', logTag, 'requestPurchase: Already owned: ' .. tostring(garageId))
    return
  end

  -- Guard: sufficient funds
  local priceCents = (def.basePrice or 0) * 100
  if not bcm_banking then
    guihooks.trigger('BCMPropertyPurchaseResult', {
      success = false, reason = 'noAccount', garageId = garageId
    })
    return
  end

  local account = bcm_banking.getPersonalAccount()
  if not account then
    guihooks.trigger('BCMPropertyPurchaseResult', {
      success = false, reason = 'noAccount', garageId = garageId
    })
    return
  end

  if priceCents > 0 and (account.balance or 0) < priceCents then
    guihooks.trigger('BCMPropertyPurchaseResult', {
      success = false, reason = 'insufficientFunds', garageId = garageId
    })
    return
  end

  -- Execute: create ownership record + vanilla sync
  local record = bcm_garages.purchaseBcmGarage(garageId)
  if not record then
    guihooks.trigger('BCMPropertyPurchaseResult', {
      success = false, reason = 'purchaseFailed', garageId = garageId
    })
    return
  end

  -- Deduct funds (if price > 0)
  if priceCents > 0 then
    bcm_banking.removeFunds(
      account.id,
      priceCents,
      'property_purchase',
      'Belasco Realty - ' .. (def.name or garageId)
    )
  end

  -- Initialize tax tracking
  local currentMonth = 0
  if bcm_timeSystem then
    local dateInfo = bcm_timeSystem.getDateInfo()
    if dateInfo then
      currentMonth = dateInfo.month or 0
    end
  end
  taxHistory[garageId] = {
    lastChargedMonth = currentMonth,
    consecutiveUnpaid = 0
  }

  -- Save
  if career_saveSystem then
    career_saveSystem.saveCurrent()
  end

  -- Notification
  if bcm_notifications then
    bcm_notifications.send({
      titleKey = 'notif.propertyPurchased',
      bodyKey = 'notif.propertyPurchasedBody',
      params = { name = def.name or garageId },
      type = 'info',
      duration = 6000
    })
  end

  -- Email
  if bcm_email then
    local displayName = def.name or garageId
    local formattedPrice = bcm_banking.formatMoney(priceCents)

    bcm_email.deliver({
      folder = 'inbox',
      from_display = 'Belasco Realty',
      from_email = 'congratulations@belascorealty.com',
      subject = 'Your New Property: ' .. displayName,
      body = 'Dear Valued Customer,\n\n'
        .. 'Congratulations on your purchase of ' .. displayName .. '!\n\n'
        .. 'Purchase price: ' .. formattedPrice .. '\n'
        .. 'Vehicle capacity: ' .. tostring(def.baseCapacity) .. ' slots\n'
        .. 'Maximum capacity: ' .. tostring(def.maxCapacity) .. ' slots (with upgrades)\n\n'
        .. 'Your new property is now registered under your name. You may begin using it immediately.\n\n'
        .. 'We hope you enjoy your new investment. Remember, property taxes are due monthly.\n\n'
        .. 'Warm regards,\n'
        .. 'The Belasco Realty Team\n'
        .. '"Turning Life\'s Misfortunes Into Your Dream Property Since 2003"'
    })
  end

  -- Fire success result to Vue
  guihooks.trigger('BCMPropertyPurchaseResult', {
    success = true,
    garageId = garageId,
    garageName = def.name or garageId,
    price = priceCents
  })

  -- Also trigger property update for the property store
  guihooks.trigger('BCMPropertyUpdate', {
    action = 'purchased',
    propertyId = garageId
  })

  log('I', logTag, 'Purchase complete: ' .. garageId .. ' for ' .. tostring(priceCents) .. ' cents')
end

-- ============================================================================
-- Sell flow
-- ============================================================================

-- Attempt to relocate vehicles from a garage to other owned garages.
-- Returns true if all vehicles were relocated, false if some remain.
relocateVehicles = function(garageId)
  if not bcm_properties or not bcm_garages then return true end

  local vehicles = bcm_garages.getVehiclesInGarage(garageId) or {}
  if #vehicles == 0 then return true end

  -- Get all other owned garages
  local ownedProps = bcm_properties.getAllOwnedProperties() or {}
  for _, vehicle in ipairs(vehicles) do
    local relocated = false
    for _, prop in ipairs(ownedProps) do
      if prop.type == "garage" and prop.id ~= garageId then
        local freeSlots = bcm_garages.getFreeSlots(prop.id)
        if freeSlots > 0 then
          bcm_properties.assignVehicleToGarage(vehicle, prop.id)
          relocated = true
          break
        end
      end
    end
    if not relocated then
      return false
    end
  end

  return true
end

requestSell = function(garageId)
  -- Guard: property is owned
  if not bcm_properties or not bcm_properties.isOwned(garageId) then
    guihooks.trigger('BCMPropertySellResult', {
      success = false, reason = 'notOwned', garageId = garageId
    })
    return
  end

  -- Guard: not the starter garage
  local def = bcm_garages and bcm_garages.getGarageDefinition(garageId)
  if def and def.isStarterGarage then
    guihooks.trigger('BCMPropertySellResult', {
      success = false, reason = 'starterGarage', garageId = garageId
    })
    return
  end

  -- Try to relocate vehicles
  local allRelocated = relocateVehicles(garageId)
  if not allRelocated then
    local vehicles = bcm_garages.getVehiclesInGarage(garageId) or {}
    guihooks.trigger('BCMPropertySellResult', {
      success = false, reason = 'noVehicleSpace', garageId = garageId,
      vehicleCount = #vehicles
    })
    return
  end

  -- Calculate sell price
  local record = bcm_properties.getOwnedProperty(garageId)
  local basePrice = def and def.basePrice or 0
  local priceCents = basePrice * 100

  -- Time bonus: up to 10% for time owned
  local timeBonus = 0
  if record and bcm_timeSystem then
    local currentDay = bcm_timeSystem.getGameTimeDays() or 0
    local purchaseDay = record.purchasedGameDay or 0
    local monthsOwned = (currentDay - purchaseDay) / 30
    timeBonus = math.min(10, math.floor(monthsOwned))
  end

  -- Tier bonus: 5% per tier
  local tierBonus = 0
  if record and record.tier then
    tierBonus = record.tier * 5
  end

  -- Final percentage
  local basePercent = math.random(SELL_MIN_PERCENT, SELL_MAX_PERCENT) + timeBonus + tierBonus
  local finalPercent = math.min(95, basePercent)
  local grossSellPriceCents = math.floor(priceCents * finalPercent / 100)

  -- Check for active mortgage â€” auto-payoff from sale proceeds
  local mortgagePayoffCents = 0
  local activeMortgage = bcm_loans and bcm_loans.getMortgageForProperty and bcm_loans.getMortgageForProperty(garageId)
  if activeMortgage then
    local remaining = (activeMortgage.remainingCents or 0) + (activeMortgage.carryForwardCents or 0)
    if grossSellPriceCents < remaining then
      -- Sale proceeds don't cover mortgage â€” block sale
      guihooks.trigger('BCMPropertySellResult', {
        success = false, reason = 'mortgageExceedsSalePrice', garageId = garageId,
        mortgageRemaining = remaining,
        salePrice = grossSellPriceCents
      })
      return
    end
    -- Auto-pay mortgage from proceeds
    mortgagePayoffCents = remaining
    bcm_loans.earlyPayoff(activeMortgage.id)
    log('I', logTag, 'Auto-paid mortgage ' .. activeMortgage.id .. ' from sale proceeds: ' .. tostring(remaining) .. ' cents')
  end

  local sellPriceCents = grossSellPriceCents - mortgagePayoffCents

  -- Remove property record
  -- Remove from BCM properties
  if bcm_properties then
    bcm_properties.removeProperty(garageId)
  end

  -- Remove from vanilla purchased garages
  if career_modules_garageManager and career_modules_garageManager.removePurchasedGarage then
    career_modules_garageManager.removePurchasedGarage(garageId)
  end

  -- Add net funds (gross - mortgage payoff)
  if bcm_banking and sellPriceCents > 0 then
    local account = bcm_banking.getPersonalAccount()
    if account then
      bcm_banking.addFunds(
        account.id,
        sellPriceCents,
        'property_sale',
        'Property Sale - ' .. (def and def.name or garageId) .. (mortgagePayoffCents > 0 and ' (net after mortgage payoff)' or '')
      )
    end
  end

  -- Clear tax debt
  taxDebt[garageId] = nil
  taxHistory[garageId] = nil

  -- Save
  if career_saveSystem then
    career_saveSystem.saveCurrent()
  end

  -- Notify
  if bcm_notifications then
    bcm_notifications.send({
      title = 'Property Sold',
      message = (def and def.name or garageId) .. ' sold for ' .. (bcm_banking and bcm_banking.formatMoney(sellPriceCents) or tostring(sellPriceCents)),
      type = 'info',
      duration = 5000
    })
  end

  -- Fire result
  guihooks.trigger('BCMPropertySellResult', {
    success = true,
    garageId = garageId,
    sellPrice = sellPriceCents
  })

  guihooks.trigger('BCMPropertyUpdate', {
    action = 'sold',
    propertyId = garageId
  })

  log('I', logTag, 'Property sold: ' .. garageId .. ' for ' .. tostring(sellPriceCents) .. ' cents (' .. finalPercent .. '%)')
end

-- Force sell: sells vehicles first, then sells the garage
requestSellForced = function(garageId)
  -- For now, just proceed with the sell â€” vehicle handling is TBD
  requestSell(garageId)
end

-- ============================================================================
-- Navigation
-- ============================================================================

navigateToGarage = function(garageId)
  -- Set GPS waypoint to the garage before closing UI
  if freeroam_facilities then
    local garage = freeroam_facilities.getFacility("garage", garageId)
    if garage then
      local pos = freeroam_facilities.getAverageDoorPositionForFacility(garage)
      if pos and core_groundMarkers then
        core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))
        log('I', logTag, 'navigateToGarage: GPS waypoint set for ' .. tostring(garageId))
      end
    end
  end

  -- Close the computer UI and return to play
  guihooks.trigger('ChangeState', { state = '' })
  log('I', logTag, 'navigateToGarage: Closing computer UI for garage ' .. tostring(garageId))
end

-- ============================================================================
-- Sell estimate (for UI price preview without executing sell)
-- ============================================================================

getSellEstimate = function(garageId)
  local def = bcm_garages and bcm_garages.getGarageDefinition(garageId)
  if not def then return nil end
  local record = bcm_properties and bcm_properties.getOwnedProperty(garageId)
  if not record then return nil end
  local basePrice = def.basePrice or 0
  local priceCents = basePrice * 100

  -- Time bonus: up to 10% for time owned
  local timeBonus = 0
  if bcm_timeSystem then
    local currentDay = bcm_timeSystem.getGameTimeDays() or 0
    local purchaseDay = record.purchasedGameDay or 0
    local monthsOwned = (currentDay - purchaseDay) / 30
    timeBonus = math.min(10, math.floor(monthsOwned))
  end

  -- Tier bonus: 5% per tier
  local tierBonus = (record.tier or 0) * 5

  local minPercent = math.min(95, SELL_MIN_PERCENT + timeBonus + tierBonus)
  local maxPercent = math.min(95, SELL_MAX_PERCENT + timeBonus + tierBonus)

  return {
    minPrice = math.floor(priceCents * minPercent / 100),
    maxPrice = math.floor(priceCents * maxPercent / 100),
    garageName = def.name or garageId
  }
end

-- Send sell estimate to Vue via guihook (bridge lua proxy doesn't work for return values)
sendSellEstimateToUI = function(garageId)
  local estimate = getSellEstimate(garageId)
  if estimate then
    guihooks.trigger('BCMPropertySellEstimate', estimate)
  end
end

-- ============================================================================
-- Property tax engine
-- ============================================================================

getTaxRate = function(tier)
  return TAX_RATES[tier] or TAX_RATES[0]
end

getTaxDebt = function(garageId)
  return taxDebt[garageId] or 0
end

collectMonthlyTaxes = function()
  if not bcm_properties or not bcm_banking or not bcm_garages then return end

  local account = bcm_banking.getPersonalAccount()
  if not account then return end

  local ownedProps = bcm_properties.getAllOwnedProperties() or {}
  local totalCollected = 0
  local totalDebt = 0

  for _, prop in ipairs(ownedProps) do
    if prop.type == "garage" then
      local garageId = prop.id
      local tier = prop.tier or 0
      local rate = getTaxRate(tier)

      -- Try to deduct from bank
      if (account.balance or 0) >= rate then
        bcm_banking.removeFunds(
          account.id,
          rate,
          'property_tax',
          'Property Tax - ' .. (bcm_garages.getGarageDisplayName(garageId) or garageId)
        )
        totalCollected = totalCollected + rate

        -- Reset consecutive unpaid
        if taxHistory[garageId] then
          taxHistory[garageId].consecutiveUnpaid = 0
        end
      else
        -- Accumulate debt
        taxDebt[garageId] = (taxDebt[garageId] or 0) + rate
        totalDebt = totalDebt + rate

        -- Track consecutive unpaid months
        if not taxHistory[garageId] then
          taxHistory[garageId] = { lastChargedMonth = 0, consecutiveUnpaid = 0 }
        end
        taxHistory[garageId].consecutiveUnpaid = (taxHistory[garageId].consecutiveUnpaid or 0) + 1
      end

      -- Update last charged month
      if taxHistory[garageId] then
        local dateInfo = bcm_timeSystem and bcm_timeSystem.getDateInfo()
        if dateInfo then
          taxHistory[garageId].lastChargedMonth = dateInfo.month or 0
        end
      end
    end
  end

  if totalCollected > 0 then
    log('I', logTag, 'Monthly taxes collected: ' .. bcm_banking.formatMoney(totalCollected))
  end
  if totalDebt > 0 then
    log('W', logTag, 'Monthly tax debt accumulated: ' .. bcm_banking.formatMoney(totalDebt))
  end
end

checkTaxSeizure = function()
  if not bcm_properties or not bcm_garages then return end

  -- Iterate over garages with tax debt
  for garageId, debt in pairs(taxDebt) do
    if debt > 0 and taxHistory[garageId] then
      local consecutiveUnpaid = taxHistory[garageId].consecutiveUnpaid or 0

      if consecutiveUnpaid >= SEIZURE_MONTHS then
        -- Check if it's the starter garage (don't seize)
        local def = bcm_garages.getGarageDefinition(garageId)
        if def and def.isStarterGarage then
          log('I', logTag, 'Skipping seizure for starter garage: ' .. garageId)
          goto continue
        end

        -- Auto-relocate vehicles (best effort)
        relocateVehicles(garageId)

        -- Clear tax data
        taxDebt[garageId] = nil
        taxHistory[garageId] = nil

        -- Notify
        local displayName = bcm_garages.getGarageDisplayName(garageId)
        if bcm_notifications then
          bcm_notifications.send({
            titleKey = 'realestate.taxSeizureExecuted',
            bodyKey = 'realestate.taxSeizureExecuted',
            params = { name = displayName },
            type = 'warning',
            duration = 8000
          })
        end

        -- Email from tax authority
        if bcm_email then
          bcm_email.deliver({
            folder = 'inbox',
            from_display = 'Belasco County Tax Authority',
            from_email = 'enforcement@belascocounty.gov',
            subject = 'PROPERTY SEIZED: ' .. displayName,
            body = 'Dear Property Owner,\n\n'
              .. 'This notice confirms that your property "' .. displayName .. '" has been SEIZED by the Belasco County Tax Authority due to ' .. tostring(consecutiveUnpaid) .. ' months of unpaid property taxes.\n\n'
              .. 'Outstanding debt: ' .. (bcm_banking and bcm_banking.formatMoney(debt) or tostring(debt)) .. '\n\n'
              .. 'The property has been repossessed and will be listed for public auction. Any vehicles stored at this location have been relocated where possible.\n\n'
              .. 'This action is final and not subject to appeal.\n\n'
              .. 'Belasco County Tax Authority\n'
              .. '"We always collect."'
          })
        end

        -- Fire update event
        guihooks.trigger('BCMPropertyUpdate', {
          action = 'seized',
          propertyId = garageId
        })

        log('W', logTag, 'PROPERTY SEIZED for unpaid taxes: ' .. garageId .. ' (debt: ' .. tostring(debt) .. ', unpaid months: ' .. tostring(consecutiveUnpaid) .. ')')
      end

      ::continue::
    end
  end
end

-- ============================================================================
-- Day advancement hook
-- ============================================================================

onDayAdvanced = function(newDay)
  if not bcm_timeSystem then return end

  local dateInfo = bcm_timeSystem.getDateInfo()
  if not dateInfo then return end

  local currentMonth = dateInfo.month or 0

  -- Only collect taxes when the month changes
  if currentMonth ~= lastProcessedMonth and lastProcessedMonth > 0 then
    collectMonthlyTaxes()
    checkTaxSeizure()
    log('I', logTag, 'Month changed (' .. tostring(lastProcessedMonth) .. ' -> ' .. tostring(currentMonth) .. '), taxes processed')
  end

  lastProcessedMonth = currentMonth
end

-- ============================================================================
-- Persistence
-- ============================================================================

saveTaxData = function(currentSavePath)
  if not career_saveSystem then return end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  local data = {
    taxDebt = taxDebt,
    taxHistory = taxHistory,
    lastProcessedMonth = lastProcessedMonth
  }

  career_saveSystem.jsonWriteFileSafe(bcmDir .. "/propertyTaxes.json", data, true)
  log('D', logTag, 'Tax data saved')
end

loadTaxData = function()
  if not career_career or not career_career.isActive() then return end
  if not career_saveSystem then return end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then return end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then return end

  local dataPath = autosavePath .. "/career/bcm/propertyTaxes.json"
  local data = jsonReadFile(dataPath)

  taxDebt = {}
  taxHistory = {}
  lastProcessedMonth = 0

  if data then
    taxDebt = data.taxDebt or {}
    taxHistory = data.taxHistory or {}
    lastProcessedMonth = data.lastProcessedMonth or 0
    log('I', logTag, 'Tax data loaded')
  else
    log('I', logTag, 'No saved tax data found â€” starting fresh')
  end
end

-- ============================================================================
-- â€” Cross-map feed + rentals action bridges
-- ============================================================================

-- hotfix BUG #13 â€” debounce guard.
-- The Realty site triggers sendCrossMapDefinitionsToVue from several places
-- (store init, map filter change, rental start/cancel, purchase result,
-- onMounted). Opening the site therefore fired the function ~12 times in the
-- same frame, spamming guihooks with identical payloads. We coalesce: if the
-- last send happened less than 500ms (500 wall-clock ticks) ago, skip. On
-- cold start and after meaningful state changes the call still goes through.
local _lastCrossMapSendAt = 0

-- Build the complete Realty catalogue across every discovered map and push it
-- to Vue. The Realty site uses this to render listings from any map the player
-- has discovered â€” not just the currently-loaded one. Owned ids
-- and active rental ids are included so the Vue layer can render badges
-- ("OWNED", "RENTED") without extra round-trips.
sendCrossMapDefinitionsToVue = function()
  if not guihooks or not guihooks.trigger then return end
  -- Debounce: skip redundant calls fired within 500ms of each other.
  local now = (os and os.clock and os.clock() * 1000) or 0
  if _lastCrossMapSendAt > 0 and (now - _lastCrossMapSendAt) < 500 then
    return
  end
  _lastCrossMapSendAt = now

  local discoveredMaps = {}
  if bcm_multimap and bcm_multimap.getDiscoveredMaps then
    discoveredMaps = bcm_multimap.getDiscoveredMaps() or {}
  end
  -- Always include the current map as a safety fallback in case discovery
  -- hasn't registered it yet (bootstrap edge case at career activation).
  if bcm_multimap and bcm_multimap.getCurrentMap then
    local cur = bcm_multimap.getCurrentMap()
    if cur and cur ~= "" then discoveredMaps[cur] = true end
  end

  local allDefs = {}
  if bcm_garages and bcm_garages.getGaragesForMap then
    for mapName, _ in pairs(discoveredMaps) do
      local defs = bcm_garages.getGaragesForMap(mapName) or {}
      for _, def in ipairs(defs) do
        -- Exclude backup garages from the cross-map Realty feed (same rule as
        -- sendDefinitionsToVue above â€” backup is the free-tier fallback, not
        -- a purchaseable listing). getGaragesForMap doesn't surface the type
        -- field, so we gate on isBackupGarage.
        if not def.isBackupGarage then
          table.insert(allDefs, def)
        end
      end
    end
  end

  -- Owned garage ids (filter by type="garage" via the dedicated helper so
  -- type="rental" shells do not leak into the "owned" set â€” Pitfall 3).
  local ownedIds = {}
  if bcm_properties and bcm_properties.getOwnedGarages then
    for _, p in ipairs(bcm_properties.getOwnedGarages() or {}) do
      table.insert(ownedIds, p.id)
    end
  end

  -- Active rental ids (both type="rental" shells and paidRentalMode on backup
  -- garages end up here because bcm_rentals.getAllActiveRentals is the single
  -- source of truth for "is the player currently paying for this?").
  local activeRentalIds = {}
  if bcm_rentals and bcm_rentals.getAllActiveRentals then
    for id, _ in pairs(bcm_rentals.getAllActiveRentals() or {}) do
      table.insert(activeRentalIds, id)
    end
  end

  local balance = 0
  if bcm_banking and bcm_banking.getPersonalAccount then
    local acc = bcm_banking.getPersonalAccount()
    if acc then balance = acc.balance or 0 end
  end

  guihooks.trigger('BCMRealtyAllDefinitions', {
    definitions = allDefs,
    ownedIds = ownedIds,
    activeRentalIds = activeRentalIds,
    balance = balance,
  })

  log('I', logTag, 'sendCrossMapDefinitionsToVue: ' .. #allDefs .. ' defs across discovered maps')
end

-- Thin relay so the Vue Realty site can force a rental list refresh without
-- reaching into the bcm_rentals module directly.
sendActiveRentalsToVue = function()
  if bcm_rentals and bcm_rentals.sendRentalsToVue then
    bcm_rentals.sendRentalsToVue()
  end
end

-- Vue â†’ Lua entry for "Rent this garage" CTAs in the Realty Rentals tab and
-- the lodging warning on the destination picker. Resolves the garage's source
-- map cross-map, enumerates the player's driven vehicle + any coupled trailers
-- (vanilla core_trailerRespawn.getVehicleTrain) so both end up associated with
-- the rental, then delegates to bcm_rentals.startRental.
requestStartRental = function(garageId, mapNameHint, termDays)
  if not garageId then return false end
  if not bcm_rentals or not bcm_rentals.startRental then
    log('W', logTag, 'requestStartRental: bcm_rentals not available')
    return false
  end

  -- Resolve source map: prefer explicit hint from cross-map inline popup, fall back to scan.
  local sourceMap = mapNameHint or nil
  if not sourceMap and bcm_multimap and bcm_multimap.getDiscoveredMaps and bcm_garages and bcm_garages.getGaragesForMap then
    for mapName, _ in pairs(bcm_multimap.getDiscoveredMaps() or {}) do
      for _, g in ipairs(bcm_garages.getGaragesForMap(mapName) or {}) do
        if g.id == garageId then
          sourceMap = mapName
          break
        end
      end
      if sourceMap then break end
    end
  end
  if not sourceMap then
    log('W', logTag, 'requestStartRental: could not resolve source map for ' .. tostring(garageId))
    if guihooks and guihooks.trigger then
      guihooks.trigger('BCMRentalError', { action = 'start', garageId = garageId, reason = 'noSourceMap' })
    end
    return false
  end

  -- Associated vehicles: the currently driven vehicle + every coupled trailer.
  -- Vanilla API: core_trailerRespawn.getVehicleTrain(vehId) returns the full
  -- train (tractor + trailers) as an array of BeamNG vehicle ids â€” that is the
  -- canonical enumeration surface (vanilla has no getAttachedTrailers helper).
  -- We filter out the tractor vehId itself because the loop already captures
  -- it from career_modules_inventory.getCurrentVehicle.
  local assocVehIds = {}
  if career_modules_inventory and career_modules_inventory.getCurrentVehicle then
    local currentInvId = career_modules_inventory.getCurrentVehicle()
    if currentInvId then
      table.insert(assocVehIds, currentInvId)

      -- Resolve the BeamNG vehId so we can walk the trailer train, then map
      -- each discovered trailer vehId back to its inventory id (only tracked
      -- vehicles count toward the rental association).
      local beVehId = nil
      if career_modules_inventory.getVehicleIdFromInventoryId then
        beVehId = career_modules_inventory.getVehicleIdFromInventoryId(currentInvId)
      end
      if beVehId and core_trailerRespawn and core_trailerRespawn.getVehicleTrain then
        local train = core_trailerRespawn.getVehicleTrain(beVehId) or {}
        for _, trainVehId in ipairs(train) do
          if trainVehId ~= beVehId and career_modules_inventory.getInventoryIdFromVehicleId then
            local trailerInvId = career_modules_inventory.getInventoryIdFromVehicleId(trainVehId)
            if trailerInvId then
              table.insert(assocVehIds, trailerInvId)
            end
          end
        end
      end
    end
  end

  local rental, err = bcm_rentals.startRental(garageId, sourceMap, assocVehIds, termDays)
  if not rental then
    if guihooks and guihooks.trigger then
      guihooks.trigger('BCMRentalError', { action = 'start', garageId = garageId, reason = err or 'unknown' })
    end
    return false
  end
  sendCrossMapDefinitionsToVue()  -- refresh Realty listing with the new active rental
  return true
end

-- Vue â†’ Lua entry for "Cancel rental" CTAs. Thin wrapper that delegates to
-- bcm_rentals.cancelRental (which already handles vehicle migration, hybrid
-- model cleanup and notifications) and refreshes the Realty listing.
requestCancelRental = function(garageId)
  if not garageId then return false end
  if not bcm_rentals or not bcm_rentals.cancelRental then
    log('W', logTag, 'requestCancelRental: bcm_rentals not available')
    return false
  end
  local ok = bcm_rentals.cancelRental(garageId)
  sendCrossMapDefinitionsToVue()
  if not ok and guihooks and guihooks.trigger then
    guihooks.trigger('BCMRentalError', { action = 'cancel', garageId = garageId, reason = 'cancelFailed' })
  end
  return ok and true or false
end

-- Vue â†’ Lua entry for "Buy this garage" CTAs across every map. Resolves the
-- target garage's definition cross-map (via the new bcm_garages.getGaragesForMap
-- feed) and delegates to the existing purchaseBcmGarage path. Per prices
-- are uniform across maps â€” the target map's JSON basePrice is used as-is with
-- no cost-of-living multiplier. Vanilla garage-manager sync for the target map
-- is deferred to syncAllPurchasedGaragesWithVanilla which runs idempotently on
-- each map load (Pitfall 4).
requestCrossMapPurchase = function(garageId, mapName)
  if not garageId or not mapName then return false end
  if not bcm_garages then
    log('W', logTag, 'requestCrossMapPurchase: bcm_garages not available')
    return false
  end

  -- Resolve the target garage's definition on the requested map
  local def = nil
  if bcm_garages.getGaragesForMap then
    for _, g in ipairs(bcm_garages.getGaragesForMap(mapName) or {}) do
      if g.id == garageId then
        def = g
        break
      end
    end
  end
  if not def then
    log('W', logTag, 'requestCrossMapPurchase: no def for ' .. tostring(garageId) .. ' on ' .. tostring(mapName))
    return false
  end

  --: uniform pricing â€” use the target map JSON basePrice as-is (no
  -- per-map multiplier). purchaseBcmGarage already looks up basePrice from
  -- its own bcmGarageConfig for the current-level code path; for cross-map
  -- the price lookup happens through the same definition resolution so a
  -- future home-map charge resolution remains consistent.
  local priceCents = (def.basePrice or 0) * 100

  -- Balance check (mirrors requestPurchase shape to keep error surface aligned)
  if bcm_banking and priceCents > 0 then
    local account = bcm_banking.getPersonalAccount()
    if not account or (account.balance or 0) < priceCents then
      if guihooks and guihooks.trigger then
        guihooks.trigger('BCMPropertyPurchaseResult', {
          success = false, reason = 'insufficientFunds', garageId = garageId
        })
      end
      return false
    end
  end

  -- Delegate to the canonical purchase path. purchaseBcmGarage uses its own
  -- (current-map) bcmGarageConfig to finalize the record â€” if the garage
  -- belongs to a different map the local config will not contain it and
  -- purchase will abort. In that case we fall back to creating the ownership
  -- record directly via bcm_properties.purchaseProperty, and vanilla sync
  -- happens on arrival (the extended syncAllPurchasedGaragesWithVanilla will
  -- pick it up) so the buyer experience is consistent.
  local record = bcm_garages.purchaseBcmGarage(garageId)
  if not record and bcm_properties and bcm_properties.purchaseProperty then
    record = bcm_properties.purchaseProperty(garageId, 'garage', def.baseCapacity)
  end
  if not record then
    log('W', logTag, 'requestCrossMapPurchase: purchase failed for ' .. tostring(garageId))
    return false
  end

  -- Deduct funds (if priceCents > 0)
  if bcm_banking and priceCents > 0 then
    local account = bcm_banking.getPersonalAccount()
    if account then
      bcm_banking.removeFunds(
        account.id,
        priceCents,
        'property_purchase',
        'Belasco Realty â€” ' .. (def.name or garageId)
      )
    end
  end

  sendCrossMapDefinitionsToVue()
  if guihooks and guihooks.trigger then
    guihooks.trigger('BCMPropertyPurchaseResult', {
      success = true,
      garageId = garageId,
      garageName = def.name or garageId,
      price = priceCents,
      crossMap = true,
      mapName = mapName,
    })
  end
  log('I', logTag, 'requestCrossMapPurchase: ' .. garageId .. ' on ' .. mapName .. ' for ' .. tostring(priceCents) .. ' cents')
  return true
end

-- ============================================================================
-- Inline garage offer bridge (InlineGarageOfferPopup)
-- ============================================================================

-- Sends available garages for a target map to the Vue inline popup.
-- Filters out already-owned (unless rental backup) and already-rented garages.
-- Enriches each entry with dailyRate computed via bcm_rentals.computeDailyRateCents.
sendGarageOffersForMap = function(mapName)
  if not mapName then return end
  if not bcm_multimapApp or not bcm_multimapApp.getGaragesForMap then
    log('W', logTag, 'sendGarageOffersForMap: bcm_multimapApp not available')
    return
  end

  local allGarages = bcm_multimapApp.getGaragesForMap(mapName) or {}
  local filtered = {}

  for _, g in ipairs(allGarages) do
    -- Skip garages already owned by player (type="garage", not a rental shell)
    local isPlayerOwned = bcm_properties and bcm_properties.isOwned and bcm_properties.isOwned(g.id)
    local ownedRec = isPlayerOwned and bcm_properties.getOwnedProperty and bcm_properties.getOwnedProperty(g.id)
    local isFullyOwned = ownedRec and ownedRec.type == 'garage' and not ownedRec.paidRentalMode

    -- Skip garages already rented by player
    local isRented = bcm_rentals and bcm_rentals.hasActiveRental and bcm_rentals.hasActiveRental(g.id)

    if not isFullyOwned and not isRented then
      local basePriceCents = (g.basePrice or 0) * 100
      local dailyRate = bcm_rentals and bcm_rentals.computeDailyRateCents
        and bcm_rentals.computeDailyRateCents(basePriceCents) or 0
      table.insert(filtered, {
        id = g.id,
        name = g.name or g.id,
        basePrice = g.basePrice or 0,
        dailyRate = dailyRate,
        tier = g.tier or 0,
        isBackupGarage = g.isBackupGarage or false,
        isOwned = isPlayerOwned or false,
        maxCapacity = g.baseCapacity or g.maxCapacity or 2,
      })
    end
  end

  if guihooks and guihooks.trigger then
    guihooks.trigger('BCMGarageOffersUpdate', { garages = filtered, mapName = mapName })
  end
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

onCareerModulesActivated = function()
  loadTaxData()

  -- Initialize lastProcessedMonth if not set
  if lastProcessedMonth == 0 and bcm_timeSystem then
    local dateInfo = bcm_timeSystem.getDateInfo()
    if dateInfo then
      lastProcessedMonth = dateInfo.month or 0
    end
  end

  activated = true

  -- Push initial data to Vue
  sendDefinitionsToVue()

  log('I', logTag, 'Real estate app activated')
end

onSaveCurrentSaveSlot = function(currentSavePath)
  saveTaxData(currentSavePath)
end

-- ============================================================================
-- Public API (M table exports)
-- ============================================================================

-- Vue bridge
M.sendDefinitionsToVue = sendDefinitionsToVue

-- Purchase flow
M.requestPurchase = requestPurchase

-- Sell flow
M.requestSell = requestSell
M.requestSellForced = requestSellForced

-- Navigation
M.navigateToGarage = navigateToGarage

-- Sell estimate (for UI price preview)
M.getSellEstimate = getSellEstimate
M.sendSellEstimateToUI = sendSellEstimateToUI

-- Tax queries
M.getTaxRate = getTaxRate
M.getTaxDebt = getTaxDebt

-- Lifecycle hooks
M.onCareerModulesActivated = onCareerModulesActivated
M.onDayAdvanced = onDayAdvanced
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

-- â€” Cross-map feed + rentals action bridges
M.sendCrossMapDefinitionsToVue = sendCrossMapDefinitionsToVue
M.sendActiveRentalsToVue = sendActiveRentalsToVue
M.requestStartRental = requestStartRental
M.requestCancelRental = requestCancelRental
M.requestCrossMapPurchase = requestCrossMapPurchase
M.sendGarageOffersForMap = sendGarageOffersForMap

return M
