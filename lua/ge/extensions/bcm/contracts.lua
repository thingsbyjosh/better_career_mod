-- BCM Contracts Extension
-- Contract pool data layer: pool generation with weighted type distribution,
-- 8-hour rotation windows, CDL gating, save/load persistence, and debug commands.
-- This is the data backbone for the trucking system (Phase 64).
-- Subsequent phases (FSM/Phase 66, UI/Phase 67, phone/Phase 68) consume this pool.
-- Extension name: bcm_contracts
-- Loaded by bcm_extensionManager after bcm_policeDamage.

local M = {}

M.debugName = "BCM Contracts"
M.dependencies = {'career_career', 'career_saveSystem', 'bcm_timeSystem'}

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
local generatePool
local getCurrentRotationId
local checkRotation
local getContractById
local acceptContract
local completeContract
local abandonContract
local pickWeightedType
local generateContract
local computePay
local computeDistance
local enumerateFacilities
local pickRandomFacility
local saveContractData
local loadContractData
local initModule
local resetModule
local debugDumpPool
local debugForceRotation
local debugDumpParcelTemplates
local debugSetCdl

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_contracts'

-- 8 game-hours = 1/3 game-day (3 rotations per game-day)
local ROTATION_PERIOD_DAYS = 1 / 3

local POOL_MIN = 10
local POOL_MAX = 15

-- Type weights (must sum to 100)
local TYPE_WEIGHTS = {
  { type = "standard", weight = 60 },
  { type = "urgent",   weight = 20 },
  { type = "recovery", weight = 15 },
  { type = "special",  weight = 5  },
}

local URGENT_MULTIPLIER_MIN = 1.5
local URGENT_MULTIPLIER_MAX = 2.5
local URGENT_DEADLINE_HOURS = { 4, 6, 8 }  -- game hours from acceptance

-- Pay rates per km by cargo type (dollars/km range: min, max)
local PAY_RATES = {
  parcel   = { min = 50,  max = 80  },
  vehicle  = { min = 80,  max = 120 },
  trailer  = { min = 100, max = 150 },
  material = { min = 60,  max = 100 },
}

-- CDL requirements by cargo type
local CDL_BY_CARGO = {
  parcel   = "none",
  vehicle  = "none",
  trailer  = "CDL-B",   -- medium trailers need CDL-B (special may upgrade to CDL-A)
  material = "CDL-A",
}

-- BCM depot facilities — hardcoded from bcm_depots.facilities.json (Phase 63.1)
-- Used as fallback if freeroam_facilities API doesn't expose them cleanly.
local BCM_DEPOT_FALLBACK = {
  { facId = "bcm_church",   displayName = "Church",     psName = "bcm_church_parking1"  },
  { facId = "bcmTelepizza", displayName = "Telepizza",  psName = "bcmTelepizza_parking1" },
  { facId = "bcmNeedle",    displayName = "The Needle", psName = "bcmNeedle_parking1"   },
}

-- ============================================================================
-- Private state
-- ============================================================================
local contractState = {
  pool             = {},
  lastRotationId   = 0,
  activeContractId = nil,
  completedCount   = 0,
  completedIds     = {},
  cdlUnlocked      = false,
}

-- Active contract data (survives pool reset on rotation)
local activeContractData = nil

local cachedFacilities = {}
local isInitialized = false
local nextContractId = 1

-- onUpdate throttle
local updateTimer = 0

-- ============================================================================
-- Facility enumeration
-- ============================================================================

-- Enumerate BCM depot facilities. Caches the result.
-- Tries freeroam_facilities first; falls back to hardcoded list.
enumerateFacilities = function()
  if #cachedFacilities > 0 then return cachedFacilities end

  local facilities = {}

  -- Attempt freeroam_facilities query
  if freeroam_facilities and freeroam_facilities.getFacilities then
    local allFacilities = freeroam_facilities.getFacilities()
    if allFacilities then
      for facId, facData in pairs(allFacilities) do
        -- Only include BCM depot facilities (ID starts with "bcm")
        if type(facId) == "string" and facId:sub(1, 3) == "bcm" then
          local entry = {
            facId       = facId,
            displayName = (facData and facData.name) or facId,
            psName      = facId .. "_parking1",
          }
          -- Try to get the first parking spot name if available
          if facData and facData.manualAccessPoints and #facData.manualAccessPoints > 0 then
            entry.psName = facData.manualAccessPoints[1].psName or entry.psName
          end
          table.insert(facilities, entry)
        end
      end
    end
  end

  -- Fallback to hardcoded list if query produced nothing
  if #facilities == 0 then
    log('W', logTag, 'freeroam_facilities query yielded no BCM facilities — using hardcoded fallback')
    for _, f in ipairs(BCM_DEPOT_FALLBACK) do
      table.insert(facilities, { facId = f.facId, displayName = f.displayName, psName = f.psName })
    end
  else
    log('I', logTag, string.format('Enumerated %d BCM facilities from freeroam_facilities', #facilities))
  end

  cachedFacilities = facilities
  return cachedFacilities
end

-- Pick a random facility from the list, excluding the one at excludeIdx
pickRandomFacility = function(facilityList, excludeIdx)
  if #facilityList == 0 then return nil, nil end
  if #facilityList == 1 then
    -- Only one facility: can't have different origin/destination
    return facilityList[1], 1
  end

  local idx = math.random(1, #facilityList)
  -- Retry if we picked the excluded index
  local attempts = 0
  while idx == excludeIdx and attempts < 10 do
    idx = math.random(1, #facilityList)
    attempts = attempts + 1
  end
  return facilityList[idx], idx
end

-- ============================================================================
-- Weighted type selection
-- ============================================================================

-- Pick a contract type using weighted random selection from TYPE_WEIGHTS
pickWeightedType = function()
  local total = 0
  for _, entry in ipairs(TYPE_WEIGHTS) do
    total = total + entry.weight
  end

  local roll = math.random(1, total)
  local cumulative = 0
  for _, entry in ipairs(TYPE_WEIGHTS) do
    cumulative = cumulative + entry.weight
    if roll <= cumulative then
      return entry.type
    end
  end
  return "standard"  -- Fallback
end

-- ============================================================================
-- Pay and distance computation
-- ============================================================================

-- Estimate distance between two facilities (km)
-- Uses random range 2-15 km since facility positions aren't directly accessible here.
-- The road factor of 1.3x is baked into the range.
computeDistance = function()
  return math.random(20, 150) / 10.0  -- 2.0 to 15.0 km
end

-- Compute base pay from distance and cargo type (dollars)
computePay = function(distanceKm, cargoType)
  local rates = PAY_RATES[cargoType] or PAY_RATES.parcel
  local ratePerKm = rates.min + math.random() * (rates.max - rates.min)
  return math.floor(distanceKm * ratePerKm)
end

-- ============================================================================
-- Contract generation
-- ============================================================================

-- Pick cargo type based on contract type
local function pickCargoType(contractType)
  if contractType == "recovery" then
    return "vehicle"
  elseif contractType == "special" then
    -- Special leans toward trailer/material
    local r = math.random(1, 100)
    if r <= 45 then return "trailer"
    elseif r <= 75 then return "material"
    elseif r <= 90 then return "vehicle"
    else return "parcel"
    end
  else
    -- Standard and urgent: any cargo type
    local r = math.random(1, 100)
    if r <= 40 then return "parcel"
    elseif r <= 65 then return "vehicle"
    elseif r <= 85 then return "trailer"
    else return "material"
    end
  end
end

-- Generate a single contract table
generateContract = function(id, contractType, facilities, currentRotationId)
  local cargoType = pickCargoType(contractType)
  local distanceKm = computeDistance()
  local basePay = computePay(distanceKm, cargoType)

  -- Pick origin and destination (must be different)
  local originFac, originIdx = pickRandomFacility(facilities, nil)
  local destFac = nil
  if originFac then
    destFac = pickRandomFacility(facilities, originIdx)
  end

  if not originFac then
    log('W', logTag, 'Cannot generate contract — no facilities available')
    return nil
  end
  -- If only one facility, destination = origin (degenerate but non-crashing)
  if not destFac then
    destFac = originFac
  end

  -- CDL requirement
  local cdlRequired = CDL_BY_CARGO[cargoType] or "none"
  -- Special large trailers may need CDL-A
  if cargoType == "trailer" and contractType == "special" and math.random() < 0.5 then
    cdlRequired = "CDL-A"
  end

  -- Hazmat: only for chemical materials
  local hazmats = false
  if cargoType == "material" and math.random() < 0.15 then
    hazmats = true
  end

  -- Pay multiplier (urgent only)
  local payMultiplier = 1.0
  local deadlineTimestamp = nil
  local deadlineGameHours = nil
  if contractType == "urgent" then
    payMultiplier = URGENT_MULTIPLIER_MIN + math.random() * (URGENT_MULTIPLIER_MAX - URGENT_MULTIPLIER_MIN)
    payMultiplier = math.floor(payMultiplier * 100) / 100  -- Round to 2 decimal places
    deadlineGameHours = URGENT_DEADLINE_HOURS[math.random(1, #URGENT_DEADLINE_HOURS)]
    -- deadlineTimestamp is set when contract is accepted (relative to acceptance time)
  end

  -- Special-type extras
  local constraintVehicle = nil
  local damageMultiplier = nil
  if contractType == "special" then
    if math.random() < 0.30 then
      -- 30% chance of specific truck model requirement
      local truckModels = { "us_semi", "semi" }
      constraintVehicle = truckModels[math.random(1, #truckModels)]
    end
    -- Fragile cargo: damage multiplier
    damageMultiplier = 1.5 + math.random() * 1.5  -- 1.5 to 3.0
    damageMultiplier = math.floor(damageMultiplier * 100) / 100
  end

  local totalPay = math.floor(basePay * payMultiplier)

  return {
    id                = string.format("cntr_%04d", id),
    type              = contractType,
    cargoType         = cargoType,
    origin            = {
      facId       = originFac.facId,
      displayName = originFac.displayName,
      psName      = originFac.psName,
    },
    destination       = {
      facId       = destFac.facId,
      displayName = destFac.displayName,
      psName      = destFac.psName,
    },
    distanceKm        = math.floor(distanceKm * 10) / 10,
    basePay           = basePay,
    payMultiplier     = payMultiplier,
    totalPay          = totalPay,
    cdlRequired       = cdlRequired,
    hazmats           = hazmats,
    deadlineTimestamp = deadlineTimestamp,
    deadlineGameHours = deadlineGameHours,
    constraintVehicle = constraintVehicle,
    damageMultiplier  = damageMultiplier,
    status            = "available",
    expiresAtRotation = currentRotationId + 1,
  }
end

-- ============================================================================
-- Pool generation
-- ============================================================================

-- Get the current rotation ID (integer that increments every 8 game-hours)
getCurrentRotationId = function()
  if not bcm_timeSystem then return 0 end
  local gameDays = bcm_timeSystem.getGameTimeDays() or 0
  return math.floor(gameDays / ROTATION_PERIOD_DAYS)
end

-- Generate a fresh contract pool for the given rotation ID
generatePool = function(rotationId)
  math.randomseed(rotationId)

  local facilities = enumerateFacilities()
  if #facilities == 0 then
    log('W', logTag, 'No facilities available — contract pool not generated')
    contractState.pool = {}
    contractState.lastRotationId = rotationId
    return
  end

  local poolSize = math.random(POOL_MIN, POOL_MAX)
  local pool = {}

  -- Type distribution tracking (for logging)
  local typeCounts = { standard = 0, urgent = 0, recovery = 0, special = 0 }

  for i = 1, poolSize do
    local contractType = pickWeightedType()

    -- CDL gating: if CDL not unlocked, skip contracts requiring CDL
    if not contractState.cdlUnlocked then
      local tempType = contractType
      -- Standard and urgent can have CDL-required cargo — filter if needed
      -- We'll generate and check CDL requirement after
    end

    local contract = generateContract(nextContractId, contractType, facilities, rotationId)
    if contract then
      -- CDL gating: if CDL not unlocked, downgrade CDL-required contracts
      if not contractState.cdlUnlocked then
        if contract.cdlRequired == "CDL-A" or contract.cdlRequired == "CDL-B" then
          -- Replace with parcel cargo (no CDL required)
          contract.cargoType = "parcel"
          contract.cdlRequired = "none"
          contract.hazmats = false
          contract.basePay = computePay(contract.distanceKm, "parcel")
          contract.totalPay = math.floor(contract.basePay * contract.payMultiplier)
        end
      end

      table.insert(pool, contract)
      typeCounts[contractType] = (typeCounts[contractType] or 0) + 1
      nextContractId = nextContractId + 1
    end
  end

  contractState.pool = pool
  contractState.lastRotationId = rotationId

  log('I', logTag, string.format(
    'Contract pool generated: %d contracts (rotation %d) | standard=%d urgent=%d recovery=%d special=%d',
    #pool, rotationId,
    typeCounts.standard, typeCounts.urgent, typeCounts.recovery, typeCounts.special
  ))
end

-- ============================================================================
-- Rotation check
-- ============================================================================

-- Check if rotation has advanced; regenerate pool if needed
checkRotation = function()
  local currentRotationId = getCurrentRotationId()
  if currentRotationId ~= contractState.lastRotationId then
    log('I', logTag, string.format(
      'Rotation changed: %d -> %d — expiring old contracts, generating fresh pool',
      contractState.lastRotationId, currentRotationId
    ))

    -- Expire all non-accepted contracts
    for _, contract in ipairs(contractState.pool) do
      if contract.status == "available" then
        contract.status = "expired"
      end
    end

    -- Generate fresh pool
    generatePool(currentRotationId)

    -- Re-inject active contract if one exists (it survives rotation)
    if activeContractData and contractState.activeContractId then
      local found = false
      for _, c in ipairs(contractState.pool) do
        if c.id == contractState.activeContractId then
          found = true
          break
        end
      end
      if not found then
        table.insert(contractState.pool, activeContractData)
        log('I', logTag, 'Active contract re-injected into fresh pool: ' .. contractState.activeContractId)
      end
    end
  end
end

-- ============================================================================
-- Save / Load
-- ============================================================================

saveContractData = function(currentSavePath)
  if not isInitialized then return end

  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available — cannot save contract data')
    return
  end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  -- Cap completedIds to last 100 to avoid unbounded growth
  local completedIds = contractState.completedIds
  if #completedIds > 100 then
    local trimmed = {}
    for i = #completedIds - 99, #completedIds do
      table.insert(trimmed, completedIds[i])
    end
    completedIds = trimmed
  end

  local data = {
    lastRotationId   = contractState.lastRotationId,
    activeContractId = contractState.activeContractId,
    completedCount   = contractState.completedCount,
    completedIds     = completedIds,
    cdlUnlocked      = contractState.cdlUnlocked,
    activeContractData = activeContractData,  -- Full active contract data survives pool reset
    nextContractId   = nextContractId,
    version          = 1,
  }

  career_saveSystem.jsonWriteFileSafe(bcmDir .. "/contracts.json", data, true)
  log('I', logTag, string.format('Contract data saved. Rotation: %d, Active: %s, Completed: %d',
    contractState.lastRotationId,
    tostring(contractState.activeContractId),
    contractState.completedCount
  ))
end

loadContractData = function()
  if not career_career or not career_career.isActive() then return end
  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available — cannot load contract data')
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('W', logTag, 'No save slot active — cannot load contract data')
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    log('W', logTag, 'No autosave found for slot: ' .. tostring(currentSaveSlot))
    return
  end

  local dataPath = autosavePath .. "/career/bcm/contracts.json"
  local data = jsonReadFile(dataPath)

  if data then
    contractState.lastRotationId   = data.lastRotationId   or 0
    contractState.activeContractId = data.activeContractId or nil
    contractState.completedCount   = data.completedCount   or 0
    contractState.completedIds     = data.completedIds     or {}
    contractState.cdlUnlocked      = data.cdlUnlocked      or false
    activeContractData             = data.activeContractData or nil
    nextContractId                 = data.nextContractId    or 1
    log('I', logTag, string.format('Contract data loaded. Rotation: %d, Active: %s, Completed: %d',
      contractState.lastRotationId,
      tostring(contractState.activeContractId),
      contractState.completedCount
    ))
  else
    log('I', logTag, 'No saved contract data found — fresh career start')
  end
end

-- ============================================================================
-- Module lifecycle
-- ============================================================================

initModule = function()
  loadContractData()

  local currentRotationId = getCurrentRotationId()
  if currentRotationId ~= contractState.lastRotationId then
    log('I', logTag, 'Rotation changed since last save — regenerating pool')
    generatePool(currentRotationId)
  else
    -- Same rotation: generate pool for current rotation (pool is not persisted)
    generatePool(currentRotationId)
  end

  -- Re-inject active contract if it exists
  if activeContractData and contractState.activeContractId then
    local found = false
    for _, c in ipairs(contractState.pool) do
      if c.id == contractState.activeContractId then
        found = true
        break
      end
    end
    if not found then
      table.insert(contractState.pool, activeContractData)
      log('I', logTag, 'Active contract re-injected into pool on resume: ' .. contractState.activeContractId)
    end
  end

  isInitialized = true
  log('I', logTag, string.format('BCM Contracts initialized. Pool size: %d', #contractState.pool))
end

resetModule = function()
  contractState.pool             = {}
  contractState.lastRotationId   = 0
  contractState.activeContractId = nil
  contractState.completedCount   = 0
  contractState.completedIds     = {}
  contractState.cdlUnlocked      = false
  activeContractData             = nil
  cachedFacilities               = {}
  isInitialized                  = false
  updateTimer                    = 0
  log('I', logTag, 'BCM Contracts reset')
end

-- ============================================================================
-- Contract operations (public API)
-- ============================================================================

getContractById = function(id)
  for _, contract in ipairs(contractState.pool) do
    if contract.id == id then
      return contract
    end
  end
  return nil
end

acceptContract = function(id)
  local contract = getContractById(id)
  if not contract then
    log('W', logTag, 'acceptContract: contract not found: ' .. tostring(id))
    return nil
  end
  if contract.status ~= "available" then
    log('W', logTag, 'acceptContract: contract not available (status=' .. contract.status .. '): ' .. id)
    return nil
  end
  if contractState.activeContractId then
    log('W', logTag, 'acceptContract: already have active contract: ' .. contractState.activeContractId)
    return nil
  end

  contract.status = "accepted"
  contractState.activeContractId = id

  -- Set deadline timestamp for urgent contracts (current game time + deadline hours)
  if contract.type == "urgent" and contract.deadlineGameHours then
    if bcm_timeSystem then
      local currentDays = bcm_timeSystem.getGameTimeDays() or 0
      contract.deadlineTimestamp = currentDays + (contract.deadlineGameHours / 24.0)
    end
  end

  -- Cache accepted contract data for persistence across pool rotations
  activeContractData = contract

  log('I', logTag, string.format('Contract accepted: %s (%s, %s, $%d)',
    id, contract.type, contract.cargoType, contract.totalPay
  ))
  return contract
end

completeContract = function(id)
  local contract = getContractById(id)
  if not contract then
    log('W', logTag, 'completeContract: contract not found: ' .. tostring(id))
    return nil
  end

  contract.status = "completed"
  contractState.completedCount = contractState.completedCount + 1
  table.insert(contractState.completedIds, id)
  contractState.activeContractId = nil
  activeContractData = nil

  log('I', logTag, string.format('Contract completed: %s (total completed: %d)',
    id, contractState.completedCount
  ))
  return contract
end

abandonContract = function()
  if not contractState.activeContractId then
    log('W', logTag, 'abandonContract: no active contract')
    return nil
  end

  local contract = getContractById(contractState.activeContractId)
  if contract then
    contract.status = "abandoned"
  end

  local id = contractState.activeContractId
  contractState.activeContractId = nil
  activeContractData = nil

  log('I', logTag, 'Contract abandoned: ' .. tostring(id))
  return contract
end

-- ============================================================================
-- Debug commands
-- ============================================================================

debugDumpPool = function()
  local pool = contractState.pool
  if #pool == 0 then
    log('I', logTag, 'DEBUG: Contract pool is empty')
    return
  end

  log('I', logTag, string.format('DEBUG: Contract pool (%d contracts, rotation %d):',
    #pool, contractState.lastRotationId
  ))

  for _, c in ipairs(pool) do
    local urgentInfo = ""
    if c.type == "urgent" then
      urgentInfo = string.format(" | deadline=%dh x%.2f", c.deadlineGameHours or 0, c.payMultiplier)
    end
    local specialInfo = ""
    if c.type == "special" then
      if c.constraintVehicle then
        specialInfo = " | vehicle=" .. c.constraintVehicle
      end
      if c.damageMultiplier then
        specialInfo = specialInfo .. string.format(" | dmgMult=%.1f", c.damageMultiplier)
      end
    end

    log('I', logTag, string.format(
      '  [%s] %s | %s | %s->%s | %.1fkm | $%d | CDL:%s | status:%s%s%s',
      c.id, c.type, c.cargoType,
      c.origin.displayName, c.destination.displayName,
      c.distanceKm, c.totalPay,
      c.cdlRequired, c.status,
      urgentInfo, specialInfo
    ))
  end

  -- Type distribution summary
  local counts = { standard = 0, urgent = 0, recovery = 0, special = 0 }
  for _, c in ipairs(pool) do
    if c.status == "available" then
      counts[c.type] = (counts[c.type] or 0) + 1
    end
  end
  log('I', logTag, string.format(
    'DEBUG: Distribution — standard=%d urgent=%d recovery=%d special=%d | CDL unlocked: %s',
    counts.standard, counts.urgent, counts.recovery, counts.special,
    tostring(contractState.cdlUnlocked)
  ))
end

debugForceRotation = function()
  local newRotationId = contractState.lastRotationId + 1
  log('I', logTag, 'DEBUG: Forcing rotation to ' .. newRotationId)
  generatePool(newRotationId)
  log('I', logTag, 'DEBUG: Pool regenerated with ' .. #contractState.pool .. ' contracts')
end

debugDumpParcelTemplates = function()
  -- Attempt to call career_modules_delivery_generator's template function
  if career_modules_delivery_generator and career_modules_delivery_generator.getDeliveryParcelTemplates then
    local templates = career_modules_delivery_generator.getDeliveryParcelTemplates()
    if templates then
      local count = 0
      for k, _ in pairs(templates) do
        count = count + 1
        log('I', logTag, 'DEBUG: Parcel template: ' .. tostring(k))
      end
      log('I', logTag, 'DEBUG: Total parcel templates loaded: ' .. count)
    else
      log('I', logTag, 'DEBUG: getDeliveryParcelTemplates returned nil')
    end
  else
    log('I', logTag, 'DEBUG: career_modules_delivery_generator not available or missing API. Check in-game delivery offers to verify bcm_* JSONs loaded.')
  end
end

debugSetCdl = function(val)
  contractState.cdlUnlocked = val and true or false
  log('I', logTag, 'DEBUG: CDL unlocked set to: ' .. tostring(contractState.cdlUnlocked))
  -- Regenerate pool to apply CDL filter
  local currentRotationId = getCurrentRotationId()
  generatePool(currentRotationId)
  log('I', logTag, 'DEBUG: Pool regenerated with CDL=' .. tostring(contractState.cdlUnlocked) .. ', ' .. #contractState.pool .. ' contracts')
end

-- ============================================================================
-- Lifecycle hooks (BeamNG callbacks)
-- ============================================================================

-- onCareerActive is the correct hook for BCM extensions (not onCareerActivated)
M.onCareerActive = function(active)
  if active then
    initModule()
  else
    resetModule()
  end
end

-- Called during save
M.onSaveCurrentSaveSlot = function(currentSavePath)
  saveContractData(currentSavePath)
end

-- Called every frame — throttle rotation checks to every 30 real seconds
M.onUpdate = function(dtReal)
  if not isInitialized then return end
  updateTimer = updateTimer + dtReal
  if updateTimer >= 30 then
    updateTimer = 0
    checkRotation()
  end
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Get all available contracts in the pool
M.getPool = function()
  local available = {}
  for _, contract in ipairs(contractState.pool) do
    if contract.status == "available" then
      table.insert(available, contract)
    end
  end
  return available
end

-- Get all contracts (including accepted/expired) for debugging
M.getAllContracts = function()
  return contractState.pool
end

-- Find a contract by ID
M.getContractById = getContractById

-- Get the currently active (accepted) contract
M.getActiveContract = function()
  if not contractState.activeContractId then return nil end
  return getContractById(contractState.activeContractId)
end

-- Accept a contract
M.acceptContract = acceptContract

-- Mark a contract as completed and return it for reward calculation
M.completeContract = completeContract

-- Abandon the active contract
M.abandonContract = abandonContract

-- Check if the pool is initialized and has contracts
M.isPoolReady = function()
  return isInitialized and #contractState.pool > 0
end

-- Get CDL unlock status
M.getCdlStatus = function()
  return contractState.cdlUnlocked
end

-- Set CDL unlock status (called by Phase 65 CDL exam system)
M.setCdlUnlocked = function(val)
  contractState.cdlUnlocked = val and true or false
  -- Regenerate pool to apply CDL filter to new pool
  if isInitialized then
    generatePool(getCurrentRotationId())
  end
end

-- Get completed contract count
M.getCompletedCount = function()
  return contractState.completedCount
end

-- Debug commands
M.debugDumpPool          = debugDumpPool
M.debugForceRotation     = debugForceRotation
M.debugDumpParcelTemplates = debugDumpParcelTemplates
M.debugSetCdl            = debugSetCdl

return M
