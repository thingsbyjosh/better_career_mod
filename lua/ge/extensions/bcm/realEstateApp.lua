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

 -- Get all garage definitions and convert to array
 local allDefs = bcm_garages.getAllDefinitions() or {}
 local defsArray = {}
 for _, def in pairs(allDefs) do
 table.insert(defsArray, def)
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

 -- Check for active mortgage — auto-payoff from sale proceeds
 local mortgagePayoffCents = 0
 local activeMortgage = bcm_loans and bcm_loans.getMortgageForProperty and bcm_loans.getMortgageForProperty(garageId)
 if activeMortgage then
 local remaining = (activeMortgage.remainingCents or 0) + (activeMortgage.carryForwardCents or 0)
 if grossSellPriceCents < remaining then
 -- Sale proceeds don't cover mortgage — block sale
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
 -- For now, just proceed with the sell — vehicle handling is TBD
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
 log('I', logTag, 'No saved tax data found — starting fresh')
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

return M
