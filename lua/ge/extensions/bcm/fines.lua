-- BCM Fines System
-- Economy layer for police pursuits: calculates per-type infraction fines with arrest surcharge,
-- debits via bcm_banking, maintains a persistent fine ledger, and provides debug commands.
-- Extension name: bcm_fines

local M = {}

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
local onPursuitEvent
local computeArrestFine
local buildSessionHash
local isLoading
local chargeFine
local notifyFine
local appendFineRecord
local trimLedger
local registerFineCategories
local saveFinesData
local loadFinesData
local onCareerModulesActivated
local onSaveCurrentSaveSlot
local issueFine
local printLedger
local clearFines
local getLedger
local getLedgerCount
local issueCameraFine
-- DPS contact helpers
local ensureDpsContact
-- Email/breaking news helpers
local buildFineEmailSubject
local buildFineEmailBody

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_fines'
local SAVE_FILE = "fines.json"
local MAX_LEDGER_ENTRIES = 100

-- Fine amounts in CENTS (CRITICAL: removeFunds takes cents)
local FINE_AMOUNTS = {
  speeding     = 30000,   -- $300
  racing       = 60000,   -- $600
  reckless     = 50000,   -- $500
  wrongWay     = 40000,   -- $400
  intersection = 50000,   -- $500
  hitTraffic   = 20000,   -- $200
  hitPolice    = 80000,   -- $800
  -- Phase 61 activation (data structure ready now):
  speed_radar      = 50000,  -- base $500
  red_light_camera = 75000,  -- $750
  no_plate         = 40000,  -- $400
}

-- Real-world inspired speed fine tiers (Spanish DGT adapted)
-- Amount in CENTS. overSpeed is km/h over posted limit.
local SPEED_FINE_TIERS = {
  { maxOver = 20,  amount = 10000 },   -- $100: 1-20 km/h over
  { maxOver = 40,  amount = 30000 },   -- $300: 21-40 km/h over
  { maxOver = 60,  amount = 50000 },   -- $500: 41-60 km/h over
  { maxOver = 80,  amount = 75000 },   -- $750: 61-80 km/h over
  { maxOver = 999, amount = 100000 },  -- $1000: 80+ km/h over
}

local function getSpeedFineTier(overSpeedKmh)
  for _, tier in ipairs(SPEED_FINE_TIERS) do
    if overSpeedKmh <= tier.maxOver then
      return tier.amount
    end
  end
  return SPEED_FINE_TIERS[#SPEED_FINE_TIERS].amount
end

local ARREST_SURCHARGE_PER_UNIT = 20000  -- $200 per (level x unique) unit

-- ============================================================================
-- Private state
-- ============================================================================
local activated = false
local fines = {}              -- ledger array
local processedHashes = {}    -- session-only idempotency set
local dpsContactId = nil      -- cached DPS contact ID (persisted across sessions)

-- ============================================================================
-- Core functions
-- ============================================================================

isLoading = function()
  local loading = false
  pcall(function()
    loading = core_gamestate.getLoadingStatus("careerLoading")
  end)
  return loading
end

buildSessionHash = function(data)
  local startTime = tostring(data.pursuitStartTime or 0)
  local posX = string.format("%.0f", (data.position and data.position.x) or 0)
  local posY = string.format("%.0f", (data.position and data.position.y) or 0)
  return startTime .. "_" .. posX .. "_" .. posY
end

computeArrestFine = function(offenseTypes, pursuitLevel, uniqueCount)
  -- Sum per-type fines from FINE_AMOUNTS for each offense
  local total = 0
  local typesFound = 0

  if offenseTypes and #offenseTypes > 0 then
    for _, offenseKey in ipairs(offenseTypes) do
      local amount = FINE_AMOUNTS[offenseKey]
      if amount then
        total = total + amount
        typesFound = typesFound + 1
      end
    end
  end

  -- Fallback: if offenseTypes is empty but uniqueCount > 0, use average fine
  if typesFound == 0 and uniqueCount > 0 then
    total = uniqueCount * 30000  -- average fine per offense
  end

  -- Add arrest surcharge: pursuitLevel x uniqueCount x ARREST_SURCHARGE_PER_UNIT
  local surcharge = (pursuitLevel or 1) * (uniqueCount or 0) * ARREST_SURCHARGE_PER_UNIT
  total = total + surcharge

  -- Minimum fine of $100 if somehow zero
  if total <= 0 then
    total = 10000
  end

  return total
end

chargeFine = function(amountCents, categoryId, description)
  -- Get personal account via bcm_banking
  local account = nil
  pcall(function()
    if bcm_banking and bcm_banking.getPersonalAccount then
      account = bcm_banking.getPersonalAccount()
    end
  end)

  if not account then
    log('W', logTag, 'No bank account available — fine recorded but not charged')
    return false
  end

  -- Cap actual charge at available balance (never go negative)
  local charge = math.min(amountCents, math.max(0, account.balance or 0))

  if charge > 0 then
    pcall(function()
      bcm_banking.removeFunds(account.id, charge, categoryId, description)
    end)
    log('I', logTag, 'Charged fine: ' .. tostring(charge) .. ' cents under category ' .. tostring(categoryId))
  else
    log('I', logTag, 'Player has no funds — fine recorded but $0 charged')
  end

  -- Fine always recorded regardless of balance
  return true
end

notifyFine = function(amountCents, fineTypeKey)
  pcall(function()
    if bcm_notifications and bcm_notifications.send then
      local formattedAmount = ''
      pcall(function()
        if bcm_banking and bcm_banking.formatMoney then
          formattedAmount = bcm_banking.formatMoney(amountCents)
        else
          formattedAmount = '$' .. tostring(math.floor(amountCents / 100))
        end
      end)

      bcm_notifications.send({
        titleKey = 'notif.fineIssued',
        bodyKey = 'notif.fineBody',
        params = { amount = formattedAmount, type = fineTypeKey or 'arrest' },
        icon = 'alert',
        app = 'heat',
        type = 'warning',
        duration = 7000
      })
    end
  end)
end

appendFineRecord = function(record)
  table.insert(fines, record)
  trimLedger()

  -- Notify Vue UI
  pcall(function()
    guihooks.trigger('BCMFinesUpdate', { fines = fines, count = #fines })
  end)
end

trimLedger = function()
  while #fines > MAX_LEDGER_ENTRIES do
    table.remove(fines, 1)
  end
end

-- ============================================================================
-- DPS Contact Registration
-- ============================================================================

-- Register (or recover) the DPS contact. Call once after loadFinesData().
-- Deduplication: only calls addContact() if dpsContactId is nil after load.
ensureDpsContact = function()
  if dpsContactId then return dpsContactId end
  if not bcm_contacts then return nil end

  -- Check if a contact with this ID already exists in contacts store
  if bcm_contacts.getContact then
    local existing = bcm_contacts.getContact("bcm_dps")
    if existing then
      dpsContactId = existing.id
      return dpsContactId
    end
  end

  -- Try getContactByName as secondary dedup check
  if bcm_contacts.getContactByName then
    local existing = bcm_contacts.getContactByName("Dept. of Public Safety", "DPS")
    if existing then
      dpsContactId = existing.id
      return dpsContactId
    end
  end

  -- Create the DPS contact
  local newId = bcm_contacts.addContact({
    id = "bcm_dps",
    firstName = "Dept. of Public Safety",
    lastName = "DPS",
    phone = "555-DPS-0001",
    email = "notices@dps.gov",
    group = "government",
    hidden = false
  })

  dpsContactId = newId
  log('I', logTag, 'DPS contact registered (id: ' .. tostring(dpsContactId) .. ')')
  return dpsContactId
end

-- ============================================================================
-- Email helpers
-- ============================================================================

-- Build formal subject line for a fine notification email
buildFineEmailSubject = function(fineType, amountCents)
  local amountStr = '$' .. tostring(math.floor((amountCents or 0) / 100))

  if fineType == 'speed_camera' then
    return 'Notice of Automated Speed Enforcement Citation — ' .. amountStr
  elseif fineType == 'speed_radar' then
    return 'Notice of Mobile Radar Enforcement Citation — ' .. amountStr
  elseif fineType == 'red_light_camera' then
    return 'Notice of Red Light Enforcement Citation — ' .. amountStr
  elseif fineType == 'arrest' then
    return 'Notice of Arrest Fine Assessment — ' .. amountStr
  else
    return 'Official Fine Notice — ' .. amountStr
  end
end

-- Build formal email body for a fine notification
buildFineEmailBody = function(fineType, amountCents, locationHint, overSpeed)
  local amountStr = '$' .. tostring(math.floor((amountCents or 0) / 100))
  local dateStr = ''
  pcall(function()
    if bcm_timeSystem and bcm_timeSystem.getCurrentDateFormatted then
      dateStr = bcm_timeSystem.getCurrentDateFormatted()
    end
  end)

  local locationLine = ''
  if locationHint and locationHint ~= '' then
    locationLine = '<p><b>Location:</b> ' .. tostring(locationHint) .. '</p>'
  end

  local speedLine = ''
  if overSpeed and overSpeed > 0 then
    speedLine = '<p><b>Recorded Speed:</b> ' .. tostring(overSpeed) .. ' km/h over posted limit</p>'
  end

  local typeDesc = 'traffic citation'
  if fineType == 'speed_camera' then
    typeDesc = 'automated speed enforcement camera citation'
  elseif fineType == 'speed_radar' then
    typeDesc = 'mobile radar unit citation'
  elseif fineType == 'red_light_camera' then
    typeDesc = 'red light enforcement camera citation'
  elseif fineType == 'arrest' then
    typeDesc = 'arrest fine assessment'
  end

  return '<p>Dear Motorist,</p>'
    .. '<p>This notice serves to inform you that the Department of Public Safety has assessed a fine in connection with a recorded ' .. typeDesc .. '. The details of this infraction are as follows:</p>'
    .. '<p><b>Date of Infraction:</b> ' .. (dateStr ~= '' and dateStr or 'On file') .. '</p>'
    .. locationLine
    .. speedLine
    .. '<p><b>Fine Amount:</b> ' .. amountStr .. '</p>'
    .. '<p>Payment is due within 30 days of the date of this notice. Failure to remit payment may result in additional administrative fees, escalated enforcement action, or a strongly worded follow-up letter from this department.</p>'
    .. '<p>To contest this citation, please contact the DPS Traffic Violations Bureau in writing. Please note that the Bureau is not responsible for the actions of automated enforcement equipment, nor can it confirm whether the camera had a "bad angle."</p>'
    .. '<p>Sincerely,<br>Department of Public Safety<br>Traffic Enforcement Division<br>notices@dps.gov</p>'
end

-- ============================================================================
-- Fine category registration
-- ============================================================================

registerFineCategories = function()
  pcall(function()
    if not bcm_transactionCategories or not bcm_transactionCategories.register then
      log('W', logTag, 'bcm_transactionCategories not available — fine categories not registered')
      return
    end

    local categories = {
      { id = 'fine_speeding',   label = 'Speeding Fine',              iconName = 'gauge',          color = '#f97316', isIncome = false },
      { id = 'fine_racing',     label = 'Racing Fine',                iconName = 'flag',           color = '#ef4444', isIncome = false },
      { id = 'fine_reckless',   label = 'Reckless Driving Fine',      iconName = 'alert-triangle', color = '#ef4444', isIncome = false },
      { id = 'fine_wrongway',   label = 'Wrong Way Fine',             iconName = 'arrow-left',     color = '#f59e0b', isIncome = false },
      { id = 'fine_intersection', label = 'Intersection Violation',   iconName = 'traffic-cone',   color = '#f59e0b', isIncome = false },
      { id = 'fine_hittraffic', label = 'Vehicle Collision Fine',     iconName = 'car',            color = '#dc2626', isIncome = false },
      { id = 'fine_hitpolice',  label = 'Police Vehicle Collision',   iconName = 'shield',         color = '#dc2626', isIncome = false },
      { id = 'fine_arrest',     label = 'Arrest Fine',                iconName = 'alert-circle',   color = '#7c3aed', isIncome = false },
      { id = 'fine_radar',      label = 'Speed Camera Fine',          iconName = 'camera',         color = '#0ea5e9', isIncome = false },
      { id = 'fine_redlight',   label = 'Red Light Camera Fine',      iconName = 'alert-octagon',  color = '#dc2626', isIncome = false },
      { id = 'fine_noplate',   label = 'No License Plate Fine',      iconName = 'file-x',         color = '#f59e0b', isIncome = false },
    }

    for _, cat in ipairs(categories) do
      bcm_transactionCategories.register(cat)
    end

    log('I', logTag, 'Registered ' .. #categories .. ' fine transaction categories')
  end)
end

-- ============================================================================
-- Event handler
-- ============================================================================

onPursuitEvent = function(data)
  if not activated then return end
  if not data then return end

  -- ARST-05 scene-transition guard: do not process events during loading
  if isLoading() then
    log('W', logTag, 'Ignoring pursuit event during scene transition (careerLoading=true)')
    return
  end

  if data.action == 'arrest' then
    -- Build session hash for idempotency
    local hash = buildSessionHash(data)
    if processedHashes[hash] then
      log('W', logTag, 'Duplicate arrest event blocked (hash=' .. hash .. ')')
      return
    end
    processedHashes[hash] = true

    -- Extract arrest parameters
    local offenseTypes = data.offenseTypes or {}
    local pursuitLevel = data.level or 1
    local uniqueCount = data.offenses or 0

    -- Compute total fine
    local totalCents = computeArrestFine(offenseTypes, pursuitLevel, uniqueCount)

    -- Build description string listing infractions
    local desc = 'Arrest'
    if #offenseTypes > 0 then
      desc = 'Arrest: ' .. table.concat(offenseTypes, ', ') .. ' (level ' .. tostring(pursuitLevel) .. ')'
    else
      desc = 'Arrest (level ' .. tostring(pursuitLevel) .. ', ' .. tostring(uniqueCount) .. ' offenses)'
    end

    -- Single bank transaction for the total fine
    chargeFine(totalCents, 'fine_arrest', desc)

    -- Get current game time for record
    local gameDate = 0
    pcall(function()
      if bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
        gameDate = bcm_timeSystem.getGameTimeDays()
      else
        gameDate = os.time()
      end
    end)

    -- Append ledger record with full breakdown
    appendFineRecord({
      type = 'arrest',
      amount = totalCents,
      description = desc,
      date = gameDate,
      paidStatus = 'paid',
      location = data.position,
      vehicleId = data.vehicleId,
      level = pursuitLevel,
      offenseTypes = offenseTypes,
      offenseCount = uniqueCount,
      hash = hash
    })

    -- Send notification
    notifyFine(totalCents, 'arrest')

    -- Breaking news: arrest event
    pcall(function()
      if bcm_breakingNews and bcm_breakingNews.onEvent then
        local heatLevel = 1
        pcall(function()
          if bcm_heatSystem and bcm_heatSystem.getHeatLevel then
            heatLevel = bcm_heatSystem.getHeatLevel()
          end
        end)
        bcm_breakingNews.onEvent('arrest', {
          amount = totalCents,
          heatLevel = heatLevel,
          pursuitLevel = pursuitLevel
        })
      end
    end)

    -- Email: arrest fine notice
    pcall(function()
      if bcm_email and bcm_email.deliver then
        bcm_email.deliver({
          folder = 'inbox',
          from_contact_id = dpsContactId,
          subject = buildFineEmailSubject('arrest', totalCents),
          body = buildFineEmailBody('arrest', totalCents, nil, nil),
          metadata = { fineType = 'arrest', amount = totalCents, pursuitLevel = pursuitLevel }
        })
      end
    end)

    -- Force save to persist the fine immediately
    pcall(function()
      if career_saveSystem and career_saveSystem.saveCurrent then
        career_saveSystem.saveCurrent()
      end
    end)

    -- Format amount for log
    local formattedAmount = '$' .. tostring(math.floor(totalCents / 100))
    log('I', logTag, 'ARREST FINE: ' .. formattedAmount .. ' — ' .. desc)
  end
end

-- ============================================================================
-- Save/Load (follows heatSystem.lua pattern exactly)
-- ============================================================================

saveFinesData = function(currentSavePath)
  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available, cannot save fines data')
    return
  end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  local data = {
    fines = fines,
    dpsContactId = dpsContactId,
    version = 1
  }

  local dataPath = bcmDir .. "/" .. SAVE_FILE
  career_saveSystem.jsonWriteFileSafe(dataPath, data, true)
  log('I', logTag, 'Saved fines data: ' .. #fines .. ' records')
end

loadFinesData = function()
  if not career_career or not career_career.isActive() then
    return
  end

  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available, cannot load fines data')
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('W', logTag, 'No save slot active, cannot load fines data')
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    log('W', logTag, 'No autosave found for slot: ' .. currentSaveSlot)
    return
  end

  -- Reset state before loading
  fines = {}
  processedHashes = {}
  dpsContactId = nil

  local dataPath = autosavePath .. "/career/bcm/" .. SAVE_FILE
  local data = jsonReadFile(dataPath)

  if data then
    if data.fines then
      fines = data.fines
    end
    -- Restore DPS contact ID (prevents re-registration and duplicate contacts)
    if data.dpsContactId then
      dpsContactId = data.dpsContactId
    end
    log('I', logTag, 'Loaded fines data: ' .. #fines .. ' records (version ' .. tostring(data.version or 0) .. ')')
  else
    fines = {}
    log('I', logTag, 'No saved fines data found, using defaults')
  end
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

onCareerModulesActivated = function()
  activated = true
  loadFinesData()
  registerFineCategories()
  -- Register DPS contact only if not already loaded from save
  ensureDpsContact()
  log('I', logTag, 'BCM Fines activated — ' .. #fines .. ' ledger records loaded')
end

onSaveCurrentSaveSlot = function(currentSavePath)
  if not activated then return end
  saveFinesData(currentSavePath)
end

-- ============================================================================
-- Debug commands — callable from BeamNG console as bcm_fines.X()
-- ============================================================================

issueFine = function(fineType)
  fineType = fineType or "speeding"
  local amount = FINE_AMOUNTS[fineType] or 30000

  local desc = 'Debug fine: ' .. fineType
  chargeFine(amount, 'fine_arrest', desc)

  -- Get current game time for record
  local gameDate = 0
  pcall(function()
    if bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
      gameDate = bcm_timeSystem.getGameTimeDays()
    else
      gameDate = os.time()
    end
  end)

  appendFineRecord({
    type = fineType,
    amount = amount,
    description = desc,
    date = gameDate,
    paidStatus = 'paid',
    level = 0,
    offenseTypes = { fineType },
    offenseCount = 1,
    hash = 'debug_' .. tostring(os.clock())
  })

  notifyFine(amount, fineType)

  local formattedAmount = '$' .. tostring(math.floor(amount / 100))
  log('I', logTag, 'DEBUG: Issued ' .. fineType .. ' fine — ' .. formattedAmount)
end

printLedger = function()
  log('I', logTag, '========== BCM FINES LEDGER ==========')
  if #fines == 0 then
    log('I', logTag, '(empty — 0 fine records)')
  else
    for i, record in ipairs(fines) do
      local formattedAmount = '$' .. tostring(math.floor((record.amount or 0) / 100))
      log('I', logTag, string.format(
        '#%d: type=%s amount=%s date=%s status=%s level=%s offenses=%s',
        i,
        tostring(record.type or '?'),
        formattedAmount,
        tostring(record.date or '?'),
        tostring(record.paidStatus or '?'),
        tostring(record.level or '?'),
        tostring(record.offenseCount or 0)
      ))
    end
  end
  log('I', logTag, 'Total: ' .. #fines .. ' fine records')
  log('I', logTag, '======================================')
end

clearFines = function()
  fines = {}
  processedHashes = {}
  log('I', logTag, 'Fine ledger cleared')
end

-- ============================================================================
-- Public API (read-only)
-- ============================================================================

getLedger = function()
  return fines
end

getLedgerCount = function()
  return #fines
end

-- ============================================================================
-- Camera fine API (Phase 61 — used by overrides/career/modules/speedTraps.lua)
-- ============================================================================

issueCameraFine = function(fineType, amountCents, triggerName, overSpeedKmh)
  if not activated then return end

  -- Scene-transition guard (same as onPursuitEvent)
  if isLoading() then
    log('W', logTag, 'Ignoring camera fine during scene transition (careerLoading=true)')
    return
  end

  -- Get current game time
  local gameDate = 0
  pcall(function()
    if bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
      gameDate = bcm_timeSystem.getGameTimeDays()
    end
  end)

  -- Determine bank category
  local categoryId = 'fine_radar'
  if fineType == 'red_light_camera' then
    categoryId = 'fine_redlight'
  elseif fineType == 'no_plate' then
    categoryId = 'fine_noplate'
  end

  -- Build description
  local desc
  if fineType == 'red_light_camera' then
    desc = 'Red Light Camera: ' .. tostring(triggerName or 'unknown')
  elseif fineType == 'no_plate' then
    desc = 'No License Plate'
  else
    desc = string.format('Speed Camera: %d km/h over at %s', overSpeedKmh or 0, tostring(triggerName or 'unknown'))
  end

  -- Charge fine via banking
  chargeFine(amountCents, categoryId, desc)

  -- Append ledger record
  appendFineRecord({
    type = fineType,
    amount = amountCents,
    description = desc,
    date = gameDate,
    paidStatus = 'paid',
    triggerName = triggerName,
    overSpeed = overSpeedKmh,
    hash = 'cam_' .. tostring(triggerName or 'unk') .. '_' .. string.format('%.2f', gameDate)
  })

  -- Dual notification (toast + phone push)
  notifyFine(amountCents, fineType)

  -- Breaking news: map fineType to the appropriate template event type
  pcall(function()
    if bcm_breakingNews and bcm_breakingNews.onEvent then
      local eventType = fineType  -- speed_camera, speed_radar, red_light_camera all match directly
      if fineType == 'no_plate' then
        -- no_plate has no breaking news template — skip
        return
      end
      bcm_breakingNews.onEvent(eventType, {
        overSpeed = overSpeedKmh or 0,
        location = tostring(triggerName or 'unknown'),
        amount = amountCents
      })
    end
  end)

  -- Email: fine notice from DPS
  pcall(function()
    if bcm_email and bcm_email.deliver and fineType ~= 'no_plate' then
      local locationHint = tostring(triggerName or '')
      bcm_email.deliver({
        folder = 'inbox',
        from_contact_id = dpsContactId,
        subject = buildFineEmailSubject(fineType, amountCents),
        body = buildFineEmailBody(fineType, amountCents, locationHint, overSpeedKmh),
        metadata = { fineType = fineType, amount = amountCents, location = locationHint, overSpeed = overSpeedKmh }
      })
    end
  end)

  -- Force save
  pcall(function()
    if career_saveSystem and career_saveSystem.saveCurrent then
      career_saveSystem.saveCurrent()
    end
  end)

  local formattedAmount = '$' .. tostring(math.floor(amountCents / 100))
  log('I', logTag, 'CAMERA FINE: ' .. formattedAmount .. ' — ' .. desc)
end

-- ============================================================================
-- M table exports
-- ============================================================================

-- Lifecycle hooks (BeamNG dispatches these)
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

-- Event handler (called by bcm_police.lua)
M.onPursuitEvent = onPursuitEvent

-- Public API (read-only)
M.getLedger = getLedger
M.getLedgerCount = getLedgerCount

-- Camera fine API
M.issueCameraFine = issueCameraFine
M.getSpeedFineTier = getSpeedFineTier

-- Debug commands — callable from BeamNG console as bcm_fines.X()
M.issueFine = issueFine
M.printLedger = printLedger
M.clearFines = clearFines

return M

