-- better_career_mod/lua/ge/extensions/bcm/rentals.lua
-- Phase 102: Per-Map Garages — Rental lifecycle module
-- Pattern source: bcm/realEstateApp.lua (day-hook + banking + save/load)
-- Decisions: D-01..D-12 per .planning/phases/102-per-map-garages/102-CONTEXT.md

local M = {}
local logTag = 'bcm_rentals'

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
local hasActiveRental
local getActiveRental
local getAllActiveRentals
local computeDailyRateCents
local startRental
local renewRental
local shouldShowRenewalPrompt
local cancelRental
local closeRental
local migrateVehiclesToBackup
local processDailyCharges
local loadData
local saveData
local sendRentalsToVue
local resolveGarageDef
local onSaveCurrentSaveSlot
local onCareerModulesActivated
local onCareerActive
local onDayAdvanced
local onExtensionLoaded
local onExtensionUnloaded

-- ============================================================================
-- Private state
-- ============================================================================
-- activeRentals[garageId] = {
--   garageId,              -- string
--   startDay,              -- integer day number
--   lastChargedDay,        -- integer day number (most recent successful debit)
--   dailyRateCents,        -- integer cents
--   sourceMapName,         -- string map id (e.g. "west_coast_usa", "italy")
--   associatedVehicleIds,  -- array of inventory ids
-- }
local activeRentals = {}
local lastProcessedDay = 0
local activated = false

-- Term discount table. Key = termDays, value = fractional discount.
-- nil termDays (indefinite) maps to 0 discount via the `or 0` fallback.
local DISCOUNTS = { [1] = 0, [7] = 0.05, [30] = 0.15 }

-- ============================================================================
-- Internal helpers
-- ============================================================================

-- Cross-map garage definition lookup.
-- NEVER use bcm_garages.loadGarageConfig here — it is hardcoded to the currently
-- loaded level, so cross-map queries would silently fail.
resolveGarageDef = function(garageId, sourceMapName)
  if not garageId or not sourceMapName then return nil end
  if not bcm_multimapApp or not bcm_multimapApp.getGaragesForMap then return nil end
  local defs = bcm_multimapApp.getGaragesForMap(sourceMapName) or {}
  for _, g in ipairs(defs) do
    if g.id == garageId then return g end
  end
  return nil
end

-- ============================================================================
-- Queries
-- ============================================================================

hasActiveRental = function(garageId)
  if not garageId then return false end
  return activeRentals[garageId] ~= nil
end

getActiveRental = function(garageId)
  if not garageId then return nil end
  return activeRentals[garageId]
end

getAllActiveRentals = function()
  local out = {}
  for id, r in pairs(activeRentals) do out[id] = r end
  return out
end

-- D-01: daily rate = 1% of purchase price per game-day, with optional term discount.
-- termDays: integer (1, 7, 30) or nil (indefinite). Discount from DISCOUNTS table.
computeDailyRateCents = function(basePriceCents, termDays)
  local discount = DISCOUNTS[termDays] or 0
  return math.floor((basePriceCents or 0) * 0.01 * (1 - discount))
end

-- ============================================================================
-- Lifecycle: startRental
-- ============================================================================

startRental = function(garageId, sourceMapName, assocVehicleIds, termDays)
  if not garageId then
    log('W', logTag, 'startRental: missing garageId')
    return nil, 'missing_garageId'
  end
  if activeRentals[garageId] then
    log('W', logTag, 'startRental: already rented ' .. tostring(garageId))
    return nil, 'already_rented'
  end

  local def = resolveGarageDef(garageId, sourceMapName)
  if not def then
    log('W', logTag, 'startRental: no def for ' .. tostring(garageId) .. ' on ' .. tostring(sourceMapName))
    return nil, 'no_def'
  end

  -- basePrice in garage JSON is in dollars; banking works in cents.
  local basePriceCents = (def.basePrice or 0) * 100
  local dailyRateCents = computeDailyRateCents(basePriceCents, termDays)
  if dailyRateCents <= 0 then
    log('W', logTag, 'startRental: computed zero rate for ' .. tostring(garageId))
    return nil, 'zero_rate'
  end

  if not bcm_banking then
    log('W', logTag, 'startRental: bcm_banking unavailable')
    return nil, 'no_banking'
  end
  local account = bcm_banking.getPersonalAccount()
  if not account or (account.balance or 0) < dailyRateCents then
    log('W', logTag, 'startRental: insufficient funds for first-day charge')
    return nil, 'insufficient_funds'
  end

  -- D-02: charge day-of-arrival up front.
  bcm_banking.removeFunds(
    account.id,
    dailyRateCents,
    'rental_charge',
    'Rental day 1 — ' .. (def.name or garageId)
  )

  local currentDay = 0
  if bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
    currentDay = math.floor(bcm_timeSystem.getGameTimeDays() or 0)
  end

  -- termDays nil = indefinite (never auto-closes). Backward-compatible with existing saves.
  local endDay = termDays and (currentDay + termDays) or nil

  activeRentals[garageId] = {
    garageId = garageId,
    startDay = currentDay,
    lastChargedDay = currentDay,
    dailyRateCents = dailyRateCents,
    sourceMapName = sourceMapName,
    associatedVehicleIds = assocVehicleIds or {},
    termDays = termDays,    -- integer or nil (indefinite)
    endDay = endDay,        -- integer or nil (indefinite = never expires)
  }

  -- D-09 hybrid data model (Plan 02 + Research Pitfall 6):
  --   Backup-free garage being upgraded to paid mode → set paidRentalMode flag on the existing record.
  --   Non-backup garage being rented → create a parallel ownership shell with type="rental".
  local isBackup = bcm_garages and bcm_garages.isBackupGarage and bcm_garages.isBackupGarage(garageId)
  if bcm_properties then
    if isBackup and bcm_properties.isOwned and bcm_properties.isOwned(garageId) then
      if bcm_properties.setPaidRentalMode then
        bcm_properties.setPaidRentalMode(garageId, {
          startDay = currentDay,
          lastChargedDay = currentDay,
          dailyRateCents = dailyRateCents,
        })
      end
    elseif bcm_properties.isOwned and not bcm_properties.isOwned(garageId) then
      if bcm_properties.purchaseProperty then
        bcm_properties.purchaseProperty(garageId, 'rental', def.baseCapacity or 2, currentDay)
      end
    end
  end

  -- Phase 102 hotfix BUG #2: use dedicated rental-started keys (title + body),
  -- not the generic heading/CTA that produced "Daily Rentals / Rent — $X/day" on
  -- screen. Also deliver an email receipt so the player has persistent feedback.
  local amountStr = (bcm_banking.formatMoney and bcm_banking.formatMoney(dailyRateCents))
    or tostring(math.floor(dailyRateCents / 100))
  if bcm_notifications and bcm_notifications.send then
    bcm_notifications.send({
      titleKey = 'garg.notifications.rentalStartedTitle',
      bodyKey  = 'garg.notifications.rentalStartedBody',
      params = {
        name = def.name or garageId,
        amount = amountStr,
      },
      type = 'info',
      duration = 5000,
    })
  end
  if bcm_email and bcm_email.deliver then
    bcm_email.deliver({
      folder = 'inbox',
      from_display = 'Belasco Realty — Rentals Desk',
      from_email = 'rentals@belascorealty.com',
      subjectKey = 'garg.notifications.rentalStartedEmailSubject',
      bodyKey    = 'garg.notifications.rentalStartedEmailBody',
      params = {
        name = def.name or garageId,
        amount = amountStr,
      },
    })
  end

  if guihooks and guihooks.trigger then
    guihooks.trigger('BCMRentalUpdate', { action = 'started', garageId = garageId })
  end
  sendRentalsToVue()

  -- Refresh garage mode in Vue so capabilities update immediately if player is at the garage.
  if bcm_garageManagerApp and bcm_garageManagerApp.sendGarageModeToVue then
    bcm_garageManagerApp.sendGarageModeToVue(garageId)
  end

  return activeRentals[garageId], nil
end

-- ============================================================================
-- Lifecycle: cancelRental / closeRental / migrateVehiclesToBackup
-- ============================================================================

cancelRental = function(garageId)
  return closeRental(garageId, 'cancelled')
end

closeRental = function(garageId, reason)
  local rental = activeRentals[garageId]
  if not rental then return false end

  -- D-07: migrate associated vehicles to the backup free garage of the same map.
  migrateVehiclesToBackup(rental)

  -- Clean up data-model side (Pitfall 6 hybrid model).
  if bcm_properties then
    if bcm_properties.isPaidRental and bcm_properties.isPaidRental(garageId) then
      if bcm_properties.clearPaidRentalMode then
        bcm_properties.clearPaidRentalMode(garageId)
      end
    else
      local rec = bcm_properties.getOwnedProperty and bcm_properties.getOwnedProperty(garageId)
      if rec and rec.type == 'rental' and bcm_properties.removeProperty then
        bcm_properties.removeProperty(garageId)
      end
    end
  end

  activeRentals[garageId] = nil

  local displayName = (bcm_garages and bcm_garages.getGarageDisplayName
    and bcm_garages.getGarageDisplayName(garageId)) or garageId

  if bcm_notifications and bcm_notifications.send then
    bcm_notifications.send({
      titleKey = (reason == 'noFunds') and 'garg.realty.lowBalanceWarning' or 'garg.realty.cancelRentalCta',
      bodyKey  = 'garg.realty.cancelConfirmBody',
      params = { garageName = displayName },
      type = (reason == 'noFunds') and 'warning' or 'info',
      duration = 6000,
    })
  end

  if bcm_email and bcm_email.deliver and reason == 'noFunds' then
    bcm_email.deliver({
      folder = 'inbox',
      from_display = 'Belasco Realty — Rentals Desk',
      from_email = 'rentals@belascorealty.com',
      subject = 'Rental closed: ' .. displayName,
      body = 'Your rental was closed because funds were insufficient at midnight. '
        .. 'Your vehicles migrated to the free backup bunk of the map. '
        .. 'No debt was recorded — rentals at Belasco are pay-as-you-sleep.',
    })
  end

  if guihooks and guihooks.trigger then
    guihooks.trigger('BCMRentalUpdate', { action = 'closed', garageId = garageId, reason = reason })
  end
  sendRentalsToVue()

  -- Immediately refresh the garage mode in Vue so capabilities are revoked in real-time
  -- (fixes: player retains access after term expires while inside the garage computer).
  if bcm_garageManagerApp and bcm_garageManagerApp.sendGarageModeToVue then
    bcm_garageManagerApp.sendGarageModeToVue(garageId)
  end

  return true
end

migrateVehiclesToBackup = function(rental)
  if not rental or not rental.sourceMapName then return end
  if not bcm_properties or not bcm_properties.assignVehicleToGarage then return end

  -- Resolve the backup free garage id on the rental's source map.
  local backupId = nil
  if bcm_multimapApp and bcm_multimapApp.getGaragesForMap then
    for _, g in ipairs(bcm_multimapApp.getGaragesForMap(rental.sourceMapName) or {}) do
      if g.isBackupGarage == true then backupId = g.id; break end
    end
  end
  if not backupId then
    log('W', logTag, 'migrateVehiclesToBackup: no backup free garage found on ' .. tostring(rental.sourceMapName))
    return
  end

  -- Reassign associated vehicles. Overflow handling is UI-level soft lockout (Pitfall 5).
  for _, invId in ipairs(rental.associatedVehicleIds or {}) do
    local ok, err = pcall(function()
      bcm_properties.assignVehicleToGarage(invId, backupId)
    end)
    if not ok then
      log('W', logTag, 'migrateVehiclesToBackup: failed to reassign ' .. tostring(invId) .. ': ' .. tostring(err))
    end
  end
end

-- ============================================================================
-- Renewal
-- ============================================================================

renewRental = function(garageId, newTermDays)
  local rental = activeRentals[garageId]
  if not rental then
    log('W', logTag, 'renewRental: no active rental at ' .. tostring(garageId))
    return nil, 'no_active_rental'
  end

  -- Re-read basePrice to recompute rate with the new term's discount.
  local def = resolveGarageDef(garageId, rental.sourceMapName)
  if not def then
    log('W', logTag, 'renewRental: no def for ' .. tostring(garageId))
    return nil, 'no_def'
  end

  local basePriceCents = (def.basePrice or 0) * 100
  local newDailyRate = computeDailyRateCents(basePriceCents, newTermDays)

  local currentDay = 0
  if bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
    currentDay = math.floor(bcm_timeSystem.getGameTimeDays() or 0)
  end

  rental.termDays = newTermDays
  rental.dailyRateCents = newDailyRate
  rental.endDay = newTermDays and (currentDay + newTermDays) or nil

  -- Notification
  local displayName = (def.name or garageId)
  local amountStr = (bcm_banking and bcm_banking.formatMoney and bcm_banking.formatMoney(newDailyRate))
    or tostring(math.floor(newDailyRate / 100))
  if bcm_notifications and bcm_notifications.send then
    bcm_notifications.send({
      titleKey = 'garg.notifications.rentalRenewedTitle',
      bodyKey  = 'garg.notifications.rentalRenewedBody',
      params = {
        name = displayName,
        days = newTermDays and tostring(newTermDays) or 'indef',
        amount = amountStr,
      },
      type = 'info',
      duration = 5000,
    })
  end

  if guihooks and guihooks.trigger then
    guihooks.trigger('BCMRentalUpdate', { action = 'renewed', garageId = garageId })
  end
  sendRentalsToVue()
  return rental, nil
end

shouldShowRenewalPrompt = function(garageId)
  local rental = activeRentals[garageId]
  if not rental then return false end
  if not rental.endDay then return false end  -- indefinite never prompts

  local currentDay = 0
  if bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
    currentDay = math.floor(bcm_timeSystem.getGameTimeDays() or 0)
  end

  return (rental.endDay - currentDay) <= 1
end

-- ============================================================================
-- Day-hook (D-02 + D-04: idempotent, balance-check-before-debit, no debt)
-- ============================================================================

processDailyCharges = function(newDay)
  if not bcm_banking then return end
  local account = bcm_banking.getPersonalAccount()
  if not account then return end

  -- Collect targets first to avoid mutating activeRentals while iterating it.
  local targets = {}
  for garageId, rental in pairs(activeRentals) do
    if newDay > (rental.lastChargedDay or 0) then
      table.insert(targets, garageId)
    end
  end

  for _, garageId in ipairs(targets) do
    local rental = activeRentals[garageId]
    if rental then
      -- Term expiry check: if endDay is set and we've reached it, close the rental.
      if rental.endDay and newDay >= rental.endDay then
        local displayName = (bcm_garages and bcm_garages.getGarageDisplayName
          and bcm_garages.getGarageDisplayName(garageId)) or garageId
        if bcm_notifications and bcm_notifications.send then
          bcm_notifications.send({
            titleKey = 'garg.notifications.rentalExpiredTitle',
            bodyKey  = 'garg.notifications.rentalExpiredBody',
            params = { name = displayName },
            type = 'info',
            duration = 6000,
          })
        end
        closeRental(garageId, 'termExpired')
      elseif (account.balance or 0) >= rental.dailyRateCents then
        bcm_banking.removeFunds(
          account.id,
          rental.dailyRateCents,
          'rental_charge',
          'Rental: ' .. ((bcm_garages and bcm_garages.getGarageDisplayName
            and bcm_garages.getGarageDisplayName(garageId)) or garageId)
        )
        rental.lastChargedDay = newDay
        -- Mirror into paidRentalMode flag if it exists (hybrid model cohesion).
        if bcm_properties and bcm_properties.isPaidRental and bcm_properties.isPaidRental(garageId) then
          local rec = bcm_properties.getOwnedProperty and bcm_properties.getOwnedProperty(garageId)
          if rec and rec.paidRentalMode then
            rec.paidRentalMode.lastChargedDay = newDay
          end
        end
        -- Refresh account snapshot for the next iteration — balance changed.
        account = bcm_banking.getPersonalAccount() or account
      else
        -- D-04: no debt, close immediately.
        closeRental(garageId, 'noFunds')
      end
    end
  end
end

onDayAdvanced = function(newDay)
  if not bcm_timeSystem or not bcm_timeSystem.getGameTimeDays then return end
  local currentDay = math.floor(bcm_timeSystem.getGameTimeDays() or 0)
  -- Pitfall 2: idempotent guard against double-fire during map switch / serialization.
  if currentDay <= lastProcessedDay then return end
  processDailyCharges(currentDay)
  lastProcessedDay = currentDay
end

-- ============================================================================
-- Vue bridge
-- ============================================================================

sendRentalsToVue = function()
  if not guihooks or not guihooks.trigger then return end
  local payload = { activeRentals = {} }
  for id, r in pairs(activeRentals) do
    -- Compute discount percentage for Vue display (0 for indefinite or 1-day)
    local discountPct = 0
    if r.termDays and DISCOUNTS[r.termDays] then
      discountPct = math.floor(DISCOUNTS[r.termDays] * 100)
    end
    payload.activeRentals[id] = {
      garageId = r.garageId,
      startDay = r.startDay,
      lastChargedDay = r.lastChargedDay,
      dailyRateCents = r.dailyRateCents,
      sourceMapName = r.sourceMapName,
      associatedVehicleIds = r.associatedVehicleIds,
      termDays = r.termDays,        -- integer or nil (indefinite)
      endDay = r.endDay,            -- integer or nil (indefinite)
      discountPct = discountPct,    -- integer 0-100
    }
  end
  guihooks.trigger('BCMRentalsUpdate', payload)
end

-- ============================================================================
-- Persistence (pattern source: realEstateApp.saveTaxData / loadTaxData)
-- ============================================================================

saveData = function(currentSavePath)
  if not career_saveSystem then return end
  if not currentSavePath then return end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  local data = {
    activeRentals = activeRentals,
    lastProcessedDay = lastProcessedDay,
  }

  career_saveSystem.jsonWriteFileSafe(bcmDir .. "/rentals.json", data, true)
  log('D', logTag, 'Rental data saved')
end

loadData = function()
  if not career_career or not career_career.isActive() then return end
  if not career_saveSystem then return end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then return end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then return end

  local dataPath = autosavePath .. "/career/bcm/rentals.json"
  local data = jsonReadFile(dataPath)

  -- Always start from a clean slate before populating (Pitfall 1: cross-map survival
  -- is handled here via disk hydration, never via in-memory retention across career swaps).
  activeRentals = {}
  lastProcessedDay = 0

  if data then
    activeRentals = data.activeRentals or {}
    lastProcessedDay = data.lastProcessedDay or 0
    log('I', logTag, 'Rental data loaded')
  else
    log('I', logTag, 'No saved rental data found — starting fresh')
  end
end

-- ============================================================================
-- Lifecycle hooks (match realEstateApp.lua structure)
-- ============================================================================

onSaveCurrentSaveSlot = function(currentSavePath)
  saveData(currentSavePath)
end

onCareerModulesActivated = function()
  loadData()

  -- Initialize lastProcessedDay from the current day if the save carried none.
  if lastProcessedDay == 0 and bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
    lastProcessedDay = math.floor(bcm_timeSystem.getGameTimeDays() or 0)
  end

  activated = true
  log('I', logTag, 'Rentals module activated')
  sendRentalsToVue()
end

-- Pitfall 1 safety: only reset state when the career actually exits, never on map-switch events.
onCareerActive = function(active)
  if not active then
    activeRentals = {}
    lastProcessedDay = 0
    activated = false
  end
end

onExtensionLoaded = function()
  log('I', logTag, 'bcm_rentals loaded')
end

onExtensionUnloaded = function()
  log('I', logTag, 'bcm_rentals unloaded')
end

-- ============================================================================
-- Public API (M table exports)
-- ============================================================================

M.hasActiveRental = hasActiveRental
M.getActiveRental = getActiveRental
M.getAllActiveRentals = getAllActiveRentals
M.computeDailyRateCents = computeDailyRateCents
M.startRental = startRental
M.renewRental = renewRental
M.shouldShowRenewalPrompt = shouldShowRenewalPrompt
M.cancelRental = cancelRental
M.closeRental = closeRental
M.processDailyCharges = processDailyCharges
M.sendRentalsToVue = sendRentalsToVue

M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onCareerModulesActivated = onCareerModulesActivated
M.onCareerActive = onCareerActive
M.onDayAdvanced = onDayAdvanced
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
