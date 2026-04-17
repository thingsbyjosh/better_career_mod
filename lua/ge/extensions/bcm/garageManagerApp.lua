-- BCM Garage Manager App Extension
-- Garage management data bridge for Vue: dashboard data, tier upgrades, capacity upgrades.
-- Extension name: bcm_garageManagerApp
-- Loaded by bcm_extensionManager after bcm_garages.

local M = {}

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
local sendGarageData
local upgradeTier
local upgradeCapacity
local transferVehicle
local onComputerAddFunctions
local onComputerMenuOpened
local pendingGateContext    -- { computerFunctions, mode, garageId } — set in addFunctions, applied in menuOpened
local isAtOwnedGarage
local getTierUpgradeCost
local buildTierBenefits
local getImportableVehicles
local patchSpawnVehicleAndTeleportToGarage
local getGarageMode
local getCapabilitiesForMode
local sendGarageModeToVue

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_garageManagerApp'

-- Fixed tier upgrade costs(in dollars)
local TIER_UPGRADE_COSTS = {
  [0] = 10000,  -- T0 -> T1
  [1] = 50000,  -- T1 -> T2
}

-- ============================================================================
-- Helper functions
-- ============================================================================

-- Returns true if the given computerId is at an owned garage
isAtOwnedGarage = function(computerId)
  if not career_modules_garageManager or not bcm_properties then
    return false
  end

  local garageId = career_modules_garageManager.computerIdToGarageId(computerId)
  if not garageId then
    return false
  end

  return bcm_properties.isOwned(garageId)
end

-- ============================================================================
-- Tri-state capability gate (owned / paidRental / backup / none)
-- ============================================================================
-- Derives a garage's operational mode from existing data sources only; no new
-- state. Consumers (Vue layer, action-gating logic) branch on this instead of
-- the previous binary isAtOwnedGarage check so the free backup, a paid rental,
-- and a fully owned garage each unlock the correct set of features (D-10, D-11).
getGarageMode = function(garageId)
  if not garageId then return 'none' end
  if bcm_properties then
    local rec = bcm_properties.getOwnedProperty(garageId)
    -- Owned garage with NO paidRentalMode flag → fully owned (top tier)
    if rec and rec.type == 'garage' and not rec.paidRentalMode then return 'owned' end
    -- Backup garage upgraded to paid-rental mode (hybrid data model, Pitfall 6)
    if rec and rec.type == 'backup' and rec.paidRentalMode then return 'paidRental' end
    -- Backup garage without paid-rental upgrade → backup mode (same caps as freeRental)
    if rec and rec.type == 'backup' and not rec.paidRentalMode then return 'backup' end
    -- Legacy: owned garage with paidRentalMode flag (pre-migration saves)
    if rec and rec.type == 'garage' and rec.paidRentalMode then return 'paidRental' end
    -- Non-backup paid rental shell
    if rec and rec.type == 'rental' then return 'paidRental' end
  end
  -- Defensive fallback: active rental record exists but the bcm_properties side
  -- of the hybrid model has not yet materialized the record (should not happen
  -- in steady state, but guards against race conditions at career activation).
  if bcm_rentals and bcm_rentals.hasActiveRental and bcm_rentals.hasActiveRental(garageId) then
    return 'paidRental'
  end
  -- Backup garage fallback: JSON flag says isBackupGarage but property record hasn't
  -- migrated to type="backup" yet (legacy save, race at activation, etc.). Treat as backup.
  if bcm_garages and bcm_garages.isBackupGarage and bcm_garages.isBackupGarage(garageId) then
    return 'backup'
  end
  return 'none'
end

-- Capability table keyed by mode. The Vue Garage Manager uses this to show/hide
-- tabs and disable blocked actions with the correct tooltip. Centralised here so
-- there is a single source of truth for what each mode unlocks.
getCapabilitiesForMode = function(mode)
  local caps = {
    owned      = { maxVehicles = nil, repair = true,  partsInstall = true,  buyParts = true,  tuning = true,  sales = true,  paint = true  },
    paidRental = { maxVehicles = 6,   repair = true,  partsInstall = true,  buyParts = true,  tuning = false, sales = false, paint = false },
    backup     = { maxVehicles = 2,   repair = true,  partsInstall = false, buyParts = false, tuning = false, sales = false, paint = false },
    none       = { maxVehicles = 0,   repair = false, partsInstall = false, buyParts = false, tuning = false, sales = false, paint = false },
  }
  return caps[mode] or caps.none
end

-- Pushes the current mode + capability table + daily rate + overcapacity flag
-- to Vue via the BCMGarageModeUpdate guihook. Called whenever the UI surface
-- needs to re-render (garage entered, rental state changed, overflow detected).
sendGarageModeToVue = function(garageId)
  if not guihooks or not guihooks.trigger or not garageId then return end
  local mode = getGarageMode(garageId)
  local caps = getCapabilitiesForMode(mode)

  -- Daily rate only matters for paid rentals. Prefer the live rental record, fall
  -- back to the paidRentalMode flag on an owned backup (hybrid data model mirror).
  local dailyRateCents = 0
  if mode == 'paidRental' then
    if bcm_rentals and bcm_rentals.getActiveRental then
      local r = bcm_rentals.getActiveRental(garageId)
      if r then dailyRateCents = r.dailyRateCents or 0 end
    end
    if dailyRateCents == 0 and bcm_properties and bcm_properties.getOwnedProperty then
      local rec = bcm_properties.getOwnedProperty(garageId)
      if rec and rec.paidRentalMode then
        dailyRateCents = rec.paidRentalMode.dailyRateCents or 0
      end
    end
  end

  local isOver = false
  if bcm_garages and bcm_garages.isOvercapacity then
    isOver = bcm_garages.isOvercapacity(garageId) or false
  end

  guihooks.trigger('BCMGarageModeUpdate', {
    garageId = garageId,
    mode = mode,
    capabilities = caps,
    dailyRateCents = dailyRateCents,
    isOvercapacity = isOver,
  })
end

-- Returns the tier upgrade cost in dollars, or nil if at max tier
getTierUpgradeCost = function(currentTier)
  return TIER_UPGRADE_COSTS[currentTier]
end

-- Builds the tier benefits table for the UI
buildTierBenefits = function(currentTier)
  return {
    {
      tier = 0,
      name = "Basic",
      features = {
        { name = "Basic Paint (Curated Colors)", unlocked = true, comingSoon = false },
        { name = "Slot Painting (3 Slots)", unlocked = true, comingSoon = false },
      }
    },
    {
      tier = 1,
      name = "Paint Booth",
      features = {
        { name = "Per-Part Painting", unlocked = (currentTier >= 1), comingSoon = false },
        { name = "Paint Booth", unlocked = (currentTier >= 1), comingSoon = false },
      }
    },
    {
      tier = 2,
      name = "Pro Shop",
      features = {
        { name = "Full RGB + All Finishes", unlocked = (currentTier >= 2), comingSoon = false },
        { name = "Virtual Dyno", unlocked = (currentTier >= 2), comingSoon = false },
      }
    }
  }
end

-- ============================================================================
-- Data bridge
-- ============================================================================

-- Collects and sends full garage dashboard data to Vue
sendGarageData = function(garageId)
  if not bcm_garages or not bcm_properties then
    log('W', logTag, 'sendGarageData: bcm_garages or bcm_properties not available')
    return
  end

  local record = bcm_properties.getOwnedProperty(garageId)
  if not record then
    log('W', logTag, 'sendGarageData: garage not owned: ' .. tostring(garageId))
    return
  end

  local definition = bcm_garages.getGarageDefinition(garageId)
  if not definition then
    log('W', logTag, 'sendGarageData: no definition for: ' .. tostring(garageId))
    return
  end

  local tier = record.tier or 0
  local currentCapacity = bcm_garages.getCurrentCapacity(garageId)
  local rawVehicles = bcm_garages.getVehiclesInGarage(garageId)
  local freeSlots = bcm_garages.getFreeSlots(garageId)

  -- Enrich vehicle list with readable names from career inventory
  local vehicles = {}
  if rawVehicles then
    local invVehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles()
    -- Get current transfers so we can mark in-transit vehicles
    local transfers = bcm_properties and bcm_properties.getVehicleTransfers and bcm_properties.getVehicleTransfers() or {}
    for _, inventoryId in ipairs(rawVehicles) do
      local invRecord = invVehicles and invVehicles[tonumber(inventoryId)]
      local isTransferring = transfers[tostring(inventoryId)] ~= nil
      table.insert(vehicles, {
        id = tostring(inventoryId),
        niceName = (invRecord and invRecord.niceName) or "Unknown Vehicle",
        model = (invRecord and invRecord.model_key) or "",
        transferring = isTransferring,
        timeToAccess = invRecord and invRecord.timeToAccess or nil,
        delayReason = invRecord and invRecord.delayReason or nil,
        location = invRecord and invRecord.location or nil,
        niceLocation = invRecord and invRecord.niceLocation or nil,
      })
    end
  end
  local canUpgradeCap = bcm_garages.canUpgradeCapacity(garageId)
  local slotPrice = bcm_garages.getSlotUpgradePrice(garageId)
  local tierCost = getTierUpgradeCost(tier)

  -- Check if player can afford tier upgrade
  local canAffordTier = false
  if tierCost and bcm_banking then
    local account = bcm_banking.getPersonalAccount()
    if account then
      canAffordTier = (account.balance or 0) >= (tierCost * 100)
    end
  end

  -- Check if player can afford capacity upgrade
  local canAffordCapacity = false
  if slotPrice and bcm_banking then
    local account = bcm_banking.getPersonalAccount()
    if account then
      -- slotUpgradePrice from bcm_garages returns dollars (basePrice * multiplier)
      canAffordCapacity = (account.balance or 0) >= (slotPrice * 100)
    end
  end

  -- Count other owned garages (not the current one)
  -- TODO(102-02): audit for type="rental" — once Plan 03 lands this must use
  -- bcm_properties.getOwnedGarages() so rentals don't inflate the "other garages"
  -- count and accidentally allow selling the only real garage.
  local allProperties = bcm_properties.getAllOwnedProperties()
  local otherGarageCount = 0
  for _, prop in ipairs(allProperties) do
    if prop.type == "garage" and tostring(prop.id) ~= tostring(garageId) then
      otherGarageCount = otherGarageCount + 1
    end
  end

  -- Get mortgage info for this garage (if any)
  local mortgageInfo = nil
  if bcm_loans and bcm_loans.getMortgageForProperty then
    local mortgage = bcm_loans.getMortgageForProperty(garageId)
    if mortgage then
      mortgageInfo = {
        loanId = mortgage.id,
        remainingCents = mortgage.remainingCents or 0,
        loanCategory = mortgage.loanCategory or "purchase_mortgage",
        paymentCents = mortgage.weeklyPaymentCents or 0,
        lenderName = mortgage.lenderName or "Unknown",
        rate = mortgage.rate or 0,
      }
    end
  end

  local data = {
    garageId = garageId,
    name = bcm_garages.getGarageDisplayName(garageId),
    tier = tier,
    currentCapacity = currentCapacity,
    maxCapacity = definition.maxCapacity or currentCapacity,
    baseCapacity = definition.baseCapacity or 1,
    vehicles = vehicles,
    freeSlots = freeSlots,
    location = definition.name or garageId,
    description = definition.description or "",
    canUpgradeCapacity = canUpgradeCap,
    slotUpgradePrice = slotPrice,
    nextSlotNumber = currentCapacity + 1,
    tierUpgradeCost = tierCost,
    canUpgradeTier = tier < 2 and canAffordTier,
    canAffordTier = canAffordTier,
    canAffordCapacity = canAffordCapacity,
    tierBenefits = buildTierBenefits(tier),
    balance = bcm_banking and bcm_banking.getPersonalAccount() and (bcm_banking.getPersonalAccount().balance or 0) / 100 or 0,
    hasOtherGarages = (otherGarageCount > 0),
    otherGarageCount = otherGarageCount,
    mortgageInfo = mortgageInfo,
  }

  guihooks.trigger('BCMGarageManagerData', data)
  log('D', logTag, 'sendGarageData: Sent data for ' .. tostring(garageId) .. ' (tier=' .. tier .. ', capacity=' .. currentCapacity .. '/' .. (definition.maxCapacity or 0) .. ')')
end

-- ============================================================================
-- Tier upgrade flow
-- ============================================================================

-- Execute tier upgrade for a garage
upgradeTier = function(garageId)
  if not bcm_properties or not bcm_banking then
    log('W', logTag, 'upgradeTier: missing dependencies')
    return
  end

  local record = bcm_properties.getOwnedProperty(garageId)
  if not record then
    log('W', logTag, 'upgradeTier: garage not owned: ' .. tostring(garageId))
    return
  end

  local tier = record.tier or 0

  -- Guard: already at max tier
  if tier >= 2 then
    guihooks.trigger('BCMGarageManagerResult', {
      success = false,
      action = 'tierUpgrade',
      reason = 'maxTier',
      garageId = garageId
    })
    return
  end

  local costDollars = getTierUpgradeCost(tier)
  if not costDollars then
    log('W', logTag, 'upgradeTier: no cost defined for tier ' .. tostring(tier))
    return
  end

  local costCents = costDollars * 100
  local account = bcm_banking.getPersonalAccount()
  if not account then
    guihooks.trigger('BCMGarageManagerResult', {
      success = false,
      action = 'tierUpgrade',
      reason = 'noAccount',
      garageId = garageId
    })
    return
  end

  -- Check funds
  if (account.balance or 0) < costCents then
    guihooks.trigger('BCMGarageManagerResult', {
      success = false,
      action = 'tierUpgrade',
      reason = 'insufficientFunds',
      required = costDollars,
      balance = (account.balance or 0) / 100,
      garageId = garageId
    })
    return
  end

  -- Execute upgrade
  local newTier = tier + 1
  bcm_banking.removeFunds(account.id, costCents, 'tier_upgrade', 'Tier Upgrade T' .. tostring(newTier))
  bcm_properties.upgradePropertyTier(garageId)

  -- Save
  if career_saveSystem then
    career_saveSystem.saveCurrent()
  end

  -- Notify
  guihooks.trigger('BCMGarageManagerResult', {
    success = true,
    action = 'tierUpgrade',
    garageId = garageId,
    newTier = newTier
  })

  -- Auto-refresh dashboard data
  sendGarageData(garageId)

  log('I', logTag, 'upgradeTier: Upgraded ' .. garageId .. ' to T' .. newTier .. ' for $' .. tostring(costDollars))
end

-- ============================================================================
-- Capacity upgrade flow
-- ============================================================================

-- Execute capacity upgrade for a garage
upgradeCapacity = function(garageId)
  if not bcm_properties or not bcm_banking or not bcm_garages then
    log('W', logTag, 'upgradeCapacity: missing dependencies')
    return
  end

  -- Guard: can upgrade capacity
  if not bcm_garages.canUpgradeCapacity(garageId) then
    guihooks.trigger('BCMGarageManagerResult', {
      success = false,
      action = 'capacityUpgrade',
      reason = 'maxCapacity',
      garageId = garageId
    })
    return
  end

  -- Get price (getSlotUpgradePrice returns dollars)
  local priceDollars = bcm_garages.getSlotUpgradePrice(garageId)
  if not priceDollars then
    log('W', logTag, 'upgradeCapacity: no price available for ' .. tostring(garageId))
    return
  end

  local priceCents = priceDollars * 100
  local account = bcm_banking.getPersonalAccount()
  if not account then
    guihooks.trigger('BCMGarageManagerResult', {
      success = false,
      action = 'capacityUpgrade',
      reason = 'noAccount',
      garageId = garageId
    })
    return
  end

  -- Check funds
  if (account.balance or 0) < priceCents then
    guihooks.trigger('BCMGarageManagerResult', {
      success = false,
      action = 'capacityUpgrade',
      reason = 'insufficientFunds',
      required = priceDollars,
      balance = (account.balance or 0) / 100,
      garageId = garageId
    })
    return
  end

  -- Execute upgrade
  bcm_banking.removeFunds(account.id, priceCents, 'capacity_upgrade', 'Slot Upgrade - ' .. (bcm_garages.getGarageDisplayName(garageId) or garageId))
  bcm_properties.upgradePropertyCapacity(garageId)

  -- Save
  if career_saveSystem then
    career_saveSystem.saveCurrent()
  end

  local newCapacity = bcm_garages.getCurrentCapacity(garageId)

  -- Notify
  guihooks.trigger('BCMGarageManagerResult', {
    success = true,
    action = 'capacityUpgrade',
    garageId = garageId,
    newCapacity = newCapacity
  })

  -- Auto-refresh dashboard data
  sendGarageData(garageId)

  log('I', logTag, 'upgradeCapacity: Upgraded ' .. garageId .. ' to ' .. newCapacity .. ' slots for $' .. tostring(priceDollars))
end

-- ============================================================================
-- Vehicle transfer system
-- ============================================================================

-- Transfer cost in cents ($500)
local TRANSFER_COST_CENTS = 50000

-- Min/max real-time delay in seconds for transfer (1-20 minutes)
local TRANSFER_MIN_SECONDS = 60
local TRANSFER_MAX_SECONDS = 1200

-- Approximate min/max garage distances on west_coast_usa map (meters)
local TRANSFER_MIN_DIST = 100
local TRANSFER_MAX_DIST = 3000

-- Get garage position from freeroam_facilities (or fall back to nil)
local function getGaragePosition(garageId)
  if not freeroam_facilities then return nil end
  local ok, garage = pcall(freeroam_facilities.getFacility, "garage", garageId)
  if ok and garage then
    if freeroam_facilities.getAverageDoorPositionForFacility then
      return freeroam_facilities.getAverageDoorPositionForFacility(garage)
    end
  end
  return nil
end

-- Calculate transfer delay in seconds based on distance between garages
local function calcTransferDelay(fromGarageId, toGarageId)
  local posA = getGaragePosition(fromGarageId)
  local posB = getGaragePosition(toGarageId)
  if not posA or not posB then
    return TRANSFER_MIN_SECONDS  -- default: 1 minute
  end
  local dist = posA:distance(posB)
  -- Linear interpolation: min dist -> TRANSFER_MIN_SECONDS, max dist -> TRANSFER_MAX_SECONDS
  local t = math.max(0, math.min(1, (dist - TRANSFER_MIN_DIST) / (TRANSFER_MAX_DIST - TRANSFER_MIN_DIST)))
  return math.floor(TRANSFER_MIN_SECONDS + t * (TRANSFER_MAX_SECONDS - TRANSFER_MIN_SECONDS))
end

-- Build transfer targets list for UI: other owned garages with free capacity
local function buildTransferTargets(fromGarageId, vehicleId)
  local targets = {}
  if not bcm_properties or not bcm_garages then return targets end

  local ownedProps = bcm_properties.getAllOwnedProperties()
  if not ownedProps then return targets end

  for _, propData in ipairs(ownedProps) do
    if propData.type == "garage" and propData.id ~= fromGarageId then
      local freeSlots = bcm_garages.getFreeSlots(propData.id)
      if freeSlots and freeSlots > 0 then
        local delaySec = calcTransferDelay(fromGarageId, propData.id)
        local estimatedMinutes = math.max(1, math.ceil(delaySec / 60))
        table.insert(targets, {
          garageId = propData.id,
          name = bcm_garages.getGarageDisplayName(propData.id) or propData.id,
          freeSlots = freeSlots,
          estimatedMinutes = estimatedMinutes,
          cost = 500,
        })
      end
    end
  end

  return targets
end

-- Send transfer targets to Vue
local function getTransferTargets(fromGarageId, vehicleId)
  local targets = buildTransferTargets(fromGarageId, vehicleId)
  guihooks.trigger('BCMTransferTargets', {
    garageId = fromGarageId,
    vehicleId = vehicleId,
    targets = targets,
  })
end

-- Execute vehicle transfer: deduct $500, record pending transfer in properties
transferVehicle = function(vehicleId, fromGarageId, toGarageId)
  if not bcm_properties or not bcm_banking or not bcm_garages then
    log('W', logTag, 'transferVehicle: missing dependencies')
    guihooks.trigger('BCMTransferResult', { success = false, reason = 'missingDeps' })
    return
  end

  -- Validate vehicle exists in fromGarage
  local vehiclesInGarage = bcm_garages.getVehiclesInGarage(fromGarageId)
  local found = false
  for _, vid in ipairs(vehiclesInGarage) do
    if tostring(vid) == tostring(vehicleId) then found = true break end
  end
  if not found then
    guihooks.trigger('BCMTransferResult', { success = false, reason = 'vehicleNotInGarage' })
    return
  end

  -- Validate destination has capacity
  local freeSlots = bcm_garages.getFreeSlots(toGarageId)
  if not freeSlots or freeSlots <= 0 then
    guihooks.trigger('BCMTransferResult', { success = false, reason = 'noCapacity' })
    return
  end

  -- Check funds
  local account = bcm_banking.getPersonalAccount()
  if not account or (account.balance or 0) < TRANSFER_COST_CENTS then
    guihooks.trigger('BCMTransferResult', { success = false, reason = 'insufficientFunds' })
    return
  end

  -- If the vehicle is currently spawned, despawn it before transfer
  local numVehId = tonumber(vehicleId)
  if numVehId and career_modules_inventory.getMapInventoryIdToVehId then
    local map = career_modules_inventory.getMapInventoryIdToVehId()
    if map[numVehId] then
      career_modules_inventory.removeVehicleObject(numVehId)
      -- Refresh computer so desktop icons update
      if career_modules_computer and career_modules_computer.refreshComputerData then
        career_modules_computer.refreshComputerData()
      end
    end
  end

  -- Deduct $500
  bcm_banking.removeFunds(account.id, TRANSFER_COST_CENTS, 'vehicle_transfer', 'Vehicle Transfer')

  -- Calculate delay
  local delaySec = calcTransferDelay(fromGarageId, toGarageId)
  local completionTime = os.time() + delaySec

  -- Record pending transfer in bcm_properties
  if bcm_properties.addVehicleTransfer then
    bcm_properties.addVehicleTransfer(tostring(vehicleId), {
      fromGarageId = fromGarageId,
      toGarageId = toGarageId,
      startTime = os.time(),
      completionTime = completionTime,
    })
  end

  -- Save
  if career_saveSystem then
    career_saveSystem.saveCurrent()
  end

  guihooks.trigger('BCMTransferResult', {
    success = true,
    vehicleId = vehicleId,
    fromGarageId = fromGarageId,
    toGarageId = toGarageId,
    estimatedMinutes = math.max(1, math.ceil(delaySec / 60)),
  })

  -- Refresh source garage UI
  sendGarageData(fromGarageId)

  log('I', logTag, 'transferVehicle: Started transfer of veh=' .. tostring(vehicleId) .. ' from ' .. fromGarageId .. ' to ' .. toGarageId .. ' (delay=' .. delaySec .. 's)')
end

-- Check for completed transfers — called from onUpdate
local function checkCompletedTransfers()
  if not bcm_properties or not bcm_properties.getVehicleTransfers then return end
  local transfers = bcm_properties.getVehicleTransfers()
  local now = os.time()
  for vehicleId, transfer in pairs(transfers) do
    if now >= transfer.completionTime then
      -- Complete the transfer
      if bcm_properties.assignVehicleToGarage and bcm_properties.removeVehicleTransfer then
        pcall(bcm_properties.assignVehicleToGarage, vehicleId, transfer.toGarageId)
        pcall(bcm_properties.removeVehicleTransfer, vehicleId)
        log('I', logTag, 'Transfer completed: veh=' .. tostring(vehicleId) .. ' -> ' .. tostring(transfer.toGarageId))
        -- Refresh computer so it detects newly available vehicles
        if career_modules_computer and career_modules_computer.refreshComputerData then
          career_modules_computer.refreshComputerData()
        end
        -- Refresh both garages if manager is open
        guihooks.trigger('BCMTransferComplete', { vehicleId = vehicleId, toGarageId = transfer.toGarageId })
      end
    end
  end
end

-- onUpdate: check for completed transfers periodically
local transferCheckInterval = 30  -- seconds
local lastTransferCheck = 0
local function onUpdate(dtReal)
  if not dtReal then return end
  lastTransferCheck = (lastTransferCheck or 0) + dtReal
  if lastTransferCheck >= transferCheckInterval then
    lastTransferCheck = 0
    checkCompletedTransfers()
  end
end

-- ============================================================================
-- Computer integration
-- ============================================================================

-- Add "Garage Manager" to computer functions when at an owned / paid-rental /
-- free-backup garage. Phase 102 widens the gate from a binary "owned or not"
-- check to the tri-state getGarageMode helper: the UI opens for any non-"none"
-- mode and the Vue layer uses the BCMGarageModeUpdate payload to decide which
-- tabs and actions to disable per capability table (D-10, D-11).
onComputerAddFunctions = function(menuData, computerFunctions)
  if not computerFunctions.general then
    computerFunctions.general = {}
  end

  local computerId = menuData.computerFacility.id
  -- Resolve the garageId from the computer so we can query tri-state mode
  local garageId = nil
  if career_modules_garageManager and career_modules_garageManager.computerIdToGarageId then
    garageId = career_modules_garageManager.computerIdToGarageId(computerId)
  end
  local mode = getGarageMode(garageId)
  local gateOpen = mode ~= 'none'

  -- Option A — auto-update vehicle location on garage computer open.
  -- The player is here with whatever vehicle they drove in. Update its
  -- location (+ any coupled trailers) to this garage so My Vehicles reflects
  -- the last place the player actually went with each vehicle.
  if garageId and gateOpen and bcm_properties and bcm_properties.assignVehicleToGarage then
    local currentInvId = nil
    if career_modules_inventory and career_modules_inventory.getCurrentVehicle then
      currentInvId = career_modules_inventory.getCurrentVehicle()
    end
    if currentInvId then
      bcm_properties.assignVehicleToGarage(currentInvId, garageId)
      -- Also update any coupled trailers (core_trailerRespawn.getVehicleTrain)
      local vehId = career_modules_inventory.getVehicleIdFromInventoryId
                    and career_modules_inventory.getVehicleIdFromInventoryId(currentInvId) or nil
      if vehId and core_trailerRespawn and core_trailerRespawn.getVehicleTrain then
        local train = core_trailerRespawn.getVehicleTrain(vehId) or {}
        for _, tVehId in ipairs(train) do
          if tVehId ~= vehId and career_modules_inventory.getInventoryIdFromVehicleId then
            local tInvId = career_modules_inventory.getInventoryIdFromVehicleId(tVehId)
            if tInvId then
              bcm_properties.assignVehicleToGarage(tInvId, garageId)
            end
          end
        end
      end
    end
  end

  -- Phase 102 Pack 2: Check if rental at this garage is expiring — fire renewal prompt.
  if garageId and bcm_rentals and bcm_rentals.shouldShowRenewalPrompt then
    if bcm_rentals.shouldShowRenewalPrompt(garageId) then
      local rental = bcm_rentals.getActiveRental(garageId)
      if rental and guihooks and guihooks.trigger then
        guihooks.trigger('BCMRentalRenewalPrompt', {
          garageId = garageId,
          mapName = rental.sourceMapName,
          dailyRateCents = rental.dailyRateCents,
          endDay = rental.endDay,
          termDays = rental.termDays,
        })
      end
    end
  end

  -- Use hash-key assignment (not table.insert) matching vanilla pattern
  computerFunctions.general["garageManager"] = {
    id = "garageManager",
    label = "Garage Manager",
    icon = "garage",
    disabled = not gateOpen,
    reason = not gateOpen and { label = "Not at a usable garage" } or nil,
    callback = function()
      -- Push the tri-state mode + capability table to Vue first so the dashboard
      -- renders with the correct gating before the full sendGarageData payload
      -- arrives. sendGarageData itself still handles the heavy vehicle/tier data.
      sendGarageModeToVue(garageId)
      sendGarageData(computerId)
    end
  }

  -- Stash context for the onComputerMenuOpened hook. BCM can't guarantee it runs
  -- after vanilla modules in the same onComputerAddFunctions hook chain — depends
  -- on extension load order. onComputerMenuOpened fires AFTER all add-functions
  -- hooks have populated the computerFunctions table, so we apply the gate there.
  pendingGateContext = {
    computerFunctions = computerFunctions,
    mode = mode,
    gateOpen = gateOpen,
  }
end

-- Capability-gate vanilla computer functions based on BCM garage mode. Runs in
-- onComputerMenuOpened so we're guaranteed to run after every extension's
-- onComputerAddFunctions (tuning, partShop, partInventory, painting, etc.) has
-- populated their entries. D-10/D-11 hard enforcement.
onComputerMenuOpened = function()
  local ctx = pendingGateContext
  pendingGateContext = nil
  if not ctx or not ctx.gateOpen or not ctx.computerFunctions then return end

  local caps = getCapabilitiesForMode(ctx.mode)
  local gateMap = {
    tuning         = caps.tuning,
    partShop       = caps.buyParts,
    partInventory  = caps.partsInstall,
    painting       = caps.paint,
  }
  local reasonLabel = (ctx.mode == 'paidRental' and 'Locked — reserved for owned garages')
                  or (ctx.mode == 'backup' and 'Locked — backup garage has limited capabilities')
                  or 'Not available at this garage mode'

  if ctx.computerFunctions.general then
    for funcId, fn in pairs(ctx.computerFunctions.general) do
      if gateMap[funcId] == false and fn then
        fn.disabled = true
        fn.reason = { label = reasonLabel }
      end
    end
  end

  if ctx.computerFunctions.vehicleSpecific then
    for invId, perVehicle in pairs(ctx.computerFunctions.vehicleSpecific) do
      if type(perVehicle) == 'table' then
        for funcId, fn in pairs(perVehicle) do
          if gateMap[funcId] == false and fn then
            fn.disabled = true
            fn.reason = { label = reasonLabel }
          end
        end
      end
    end
  end
end

-- ============================================================================
-- Import/export vehicle queries
-- ============================================================================

-- Returns vehicles in OTHER garages that can be imported to the given garage
getImportableVehicles = function(toGarageId)
  local result = { garageId = toGarageId, vehicles = {} }

  if not bcm_properties or not bcm_garages then
    guihooks.trigger('BCMImportableVehicles', result)
    return
  end

  -- Check if THIS garage has capacity
  local freeSlots = bcm_garages.getFreeSlots(toGarageId)
  if not freeSlots or freeSlots <= 0 then
    result.noCapacity = true
    guihooks.trigger('BCMImportableVehicles', result)
    return
  end

  -- TODO(102-02): audit for type="rental" — rentals are valid vehicle sources
  -- today so iterating all properties is acceptable. Plan 03/04 must audit the
  -- transfer delay + display name paths for rental sources before shipping.
  local allProperties = bcm_properties.getAllOwnedProperties()
  local allVehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles() or {}
  local vehicleTransfers = bcm_properties.getVehicleTransfers and bcm_properties.getVehicleTransfers() or {}

  -- Get position of destination garage for distance calculation
  local toPos = nil
  if freeroam_facilities and freeroam_facilities.getAverageDoorPositionForFacility then
    local ok, fac = pcall(freeroam_facilities.getFacility, "garage", toGarageId)
    if ok and fac then
      toPos = freeroam_facilities.getAverageDoorPositionForFacility(fac)
    end
  end

  for _, prop in ipairs(allProperties) do
    local srcGarageId = tostring(prop.id)
    if srcGarageId ~= tostring(toGarageId) then
      -- Get vehicles assigned to this other garage
      local vehicleIds = bcm_garages.getVehiclesInGarage(srcGarageId) or {}
      for _, vehId in ipairs(vehicleIds) do
        local strVehId = tostring(vehId)
        -- Skip vehicles already in transit
        if not vehicleTransfers[strVehId] then
          local invRecord = allVehicles[tonumber(vehId)]
          local niceName = invRecord and invRecord.niceName or "Unknown"

          -- Calculate transfer time
          local estimatedMinutes = 10 -- default
          local fromPos = nil
          if freeroam_facilities and freeroam_facilities.getAverageDoorPositionForFacility then
            local ok2, facFrom = pcall(freeroam_facilities.getFacility, "garage", srcGarageId)
            if ok2 and facFrom then
              fromPos = freeroam_facilities.getAverageDoorPositionForFacility(facFrom)
            end
          end
          if fromPos and toPos then
            local dist = (fromPos - toPos):length()
            local minDist, maxDist = 100, 3000
            local minTime, maxTime = 1, 20
            local t = math.max(0, math.min(1, (dist - minDist) / (maxDist - minDist)))
            estimatedMinutes = math.floor(minTime + t * (maxTime - minTime))
          end

          table.insert(result.vehicles, {
            vehicleId = strVehId,
            niceName = niceName,
            sourceGarageId = srcGarageId,
            sourceGarageName = prop.name or bcm_garages.getGarageDisplayName(srcGarageId) or srcGarageId,
            estimatedMinutes = estimatedMinutes,
            cost = 500
          })
        end
      end
    end
  end

  guihooks.trigger('BCMImportableVehicles', result)
end

-- ============================================================================
-- Spawn override: resolve garage from vehicle.location instead of getClosestGarage
-- ============================================================================

patchSpawnVehicleAndTeleportToGarage = function()
  if not career_modules_inventory or not career_modules_inventory.spawnVehicleAndTeleportToGarage then return end

  local _originalSpawn = career_modules_inventory.spawnVehicleAndTeleportToGarage

  career_modules_inventory.spawnVehicleAndTeleportToGarage = function(enterAfterSpawn, inventoryId, replaceOthers)
    -- BCM: resolve target garage from vehicle.location first
    local targetGarageId = nil
    local vehicles = career_modules_inventory.getVehicles()
    if vehicles and vehicles[inventoryId] then
      targetGarageId = vehicles[inventoryId].location
    end
    -- Fall back to closest garage (vanilla behavior)
    if not targetGarageId then
      local closestGarage = career_modules_inventory.getClosestGarage()
      targetGarageId = closestGarage and closestGarage.id
    end
    if not targetGarageId then
      log('E', logTag, 'spawnVehicleAndTeleportToGarage: no target garage found for inv=' .. tostring(inventoryId))
      return
    end

    -- Call original spawn (spawns + teleports to closest garage)
    _originalSpawn(enterAfterSpawn, inventoryId, replaceOthers)

    -- Then re-teleport to the correct (assigned) garage if different from closest
    local closestGarage = career_modules_inventory.getClosestGarage()
    local closestId = closestGarage and closestGarage.id
    if targetGarageId ~= closestId then
      -- Deferred re-teleport: wait a frame for the spawn callback to finish
      local checkCount = 0
      local function tryReteleport()
        checkCount = checkCount + 1
        if checkCount > 30 then return end -- safety: stop after 30 frames
        local vehId = career_modules_inventory.getMapInventoryIdToVehId and career_modules_inventory.getMapInventoryIdToVehId()[inventoryId]
        if vehId then
          local vehObj = be:getObjectByID(vehId)
          if vehObj and freeroam_facilities and freeroam_facilities.teleportToGarage then
            freeroam_facilities.teleportToGarage(targetGarageId, vehObj, false)
            log('I', logTag, 'Re-teleported vehicle inv=' .. tostring(inventoryId) .. ' to assigned garage=' .. tostring(targetGarageId))
            return
          end
        end
        -- Vehicle not spawned yet, try next frame
        if be and be.queueAllObjectLua then
          be:queueAllObjectLua("obj:queueGameEngineLua('bcm_garageManagerApp._reteleportCheck(" .. tostring(inventoryId) .. ", \"" .. tostring(targetGarageId) .. "\", " .. tostring(checkCount) .. ")')")
        end
      end
      -- Start check on next frame
      tryReteleport()
    end
  end
  log('I', logTag, 'spawnVehicleAndTeleportToGarage patched to use vehicle.location')
end

-- Internal helper for deferred re-teleport (called from queueGameEngineLua)
local function _reteleportCheck(inventoryId, targetGarageId, checkCount)
  if checkCount > 30 then return end
  local vehId = career_modules_inventory.getMapInventoryIdToVehId and career_modules_inventory.getMapInventoryIdToVehId()[inventoryId]
  if vehId then
    local vehObj = be:getObjectByID(vehId)
    if vehObj and freeroam_facilities and freeroam_facilities.teleportToGarage then
      freeroam_facilities.teleportToGarage(targetGarageId, vehObj, false)
      log('I', logTag, 'Deferred re-teleport complete: inv=' .. tostring(inventoryId) .. ' -> garage=' .. tostring(targetGarageId))
      return
    end
  end
end

-- ============================================================================
-- Delivery notification watchlist
-- ============================================================================

local deliveryWatchlist = {}  -- {[inventoryIdStr] = true} for vehicles currently in delivery

local function watchDeliveries(dtReal)
  if not career_modules_inventory or not career_modules_inventory.getVehicles then return end
  local vehicles = career_modules_inventory.getVehicles()
  if not vehicles then return end

  for inventoryId, vehInfo in pairs(vehicles) do
    local idStr = tostring(inventoryId)
    if vehInfo.timeToAccess and vehInfo.timeToAccess > 0 then
      deliveryWatchlist[idStr] = true
    elseif deliveryWatchlist[idStr] then
      -- Transition: was in delivery, now delivered
      deliveryWatchlist[idStr] = nil
      -- Fire BCM mobile phone notification
      if bcm_notifications and bcm_notifications.send then
        local garageName = vehInfo.niceLocation or vehInfo.location or "your garage"
        bcm_notifications.send({
          titleKey = "notif.vehicleDelivered",
          bodyKey = "notif.vehicleDeliveredBody",
          params = {
            vehicleName = vehInfo.niceName or "Vehicle",
            garageName = garageName,
          },
          type = "success",
          duration = 8000,
        })
      end
      -- Fire guihook for Vue to refresh garage data
      guihooks.trigger('BCMDeliveryComplete', {
        inventoryId = inventoryId,
        niceName = vehInfo.niceName,
        location = vehInfo.location,
        niceLocation = vehInfo.niceLocation,
      })
      log('I', logTag, 'Delivery complete: ' .. tostring(vehInfo.niceName) .. ' -> ' .. tostring(vehInfo.niceLocation))
    end
  end
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

local function onCareerModulesActivated()
  patchSpawnVehicleAndTeleportToGarage()
  deliveryWatchlist = {}
  log('I', logTag, 'garageManagerApp activated — spawn override patched')
end

-- ============================================================================
-- Public API (M table exports)
-- ============================================================================

-- ============================================================================
-- Force-delete vehicle (escape valve for bugged vehicles)
-- ============================================================================
-- Removes a vehicle from inventory entirely, regardless of condition, insurance
-- state, or any other status. Use when a vehicle is stuck/bugged.
local function forceDeleteVehicle(inventoryId)
  local logTag = 'bcm_garageManager'
  inventoryId = tonumber(inventoryId)
  if not inventoryId then
    guihooks.trigger('BCMForceDeleteResult', { success = false, reason = 'invalid_id' })
    return
  end

  local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles() or {}
  if not vehicles[inventoryId] then
    guihooks.trigger('BCMForceDeleteResult', { success = false, reason = 'vehicle_not_found' })
    return
  end

  log('W', logTag, 'Force-deleting vehicle inv=' .. tostring(inventoryId))

  -- Despawn if currently in world
  pcall(function()
    if career_modules_inventory.removeVehicleObject then
      career_modules_inventory.removeVehicleObject(inventoryId)
    end
  end)

  -- Cancel any active marketplace listings for this vehicle
  pcall(function()
    local mp = career_modules_bcm_marketplace or (extensions and extensions['career_modules_bcm_marketplace'])
    if mp and mp.getPlayerListingByInventoryId then
      local listing = mp.getPlayerListingByInventoryId(inventoryId)
      if listing and mp.cancelBuyerSessionsForListing then
        mp.cancelBuyerSessionsForListing(listing.id)
      end
      if listing and mp.removePlayerListing then
        mp.removePlayerListing(listing.id)
      end
    end
  end)

  -- Cancel any active loans
  pcall(function()
    if bcm_loans and bcm_loans.forceCloseLoanForVehicle then
      bcm_loans.forceCloseLoanForVehicle(inventoryId)
    end
  end)

  -- Remove from garage assignment
  pcall(function()
    if bcm_properties and bcm_properties.unassignVehicleFromGarage then
      bcm_properties.unassignVehicleFromGarage(tostring(inventoryId))
    end
  end)

  -- Remove from inventory (the nuclear option)
  local removed = false
  pcall(function()
    if career_modules_inventory.removeVehicle then
      career_modules_inventory.removeVehicle(inventoryId)
      removed = true
    end
  end)

  if removed then
    log('I', logTag, 'Vehicle force-deleted: inv=' .. tostring(inventoryId))
    -- Force save to persist the deletion
    pcall(function()
      if career_saveSystem and career_saveSystem.saveCurrent then
        career_saveSystem.saveCurrent()
      end
    end)
    guihooks.trigger('BCMForceDeleteResult', { success = true, inventoryId = inventoryId })
  else
    log('E', logTag, 'Force-delete failed for inv=' .. tostring(inventoryId))
    guihooks.trigger('BCMForceDeleteResult', { success = false, reason = 'remove_failed' })
  end
end

M.forceDeleteVehicle = forceDeleteVehicle
M.sendGarageData = sendGarageData
M.upgradeTier = upgradeTier
M.upgradeCapacity = upgradeCapacity
M.transferVehicle = transferVehicle
M.getTransferTargets = getTransferTargets
M.getImportableVehicles = getImportableVehicles
M.onComputerAddFunctions = onComputerAddFunctions
M.onComputerMenuOpened = onComputerMenuOpened
M.onCareerModulesActivated = onCareerModulesActivated
M._reteleportCheck = _reteleportCheck

-- Phase 102 — tri-state capability gate exports
M.getGarageMode = getGarageMode
M.getCapabilitiesForMode = getCapabilitiesForMode
M.sendGarageModeToVue = sendGarageModeToVue

-- onUpdate: check transfers + watch deliveries
local _origOnUpdate = onUpdate
local function onUpdateWrapped(dtReal)
  _origOnUpdate(dtReal)
  watchDeliveries(dtReal)
end
M.onUpdate = onUpdateWrapped

return M

