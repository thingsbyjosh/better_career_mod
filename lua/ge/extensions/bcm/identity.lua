-- BCM Identity Extension
-- Core player identity module: name, sex, birthday, driver's license number.
-- Persists per save slot. Fires guihook events consumed by identityStore.js.
-- Foundation for all v1.4 Identity & Communications features.

local M = {}

-- Forward declarations (ALL functions declared before any function body)
local generateLicenseNumber
local setIdentity
local getIdentity
local getFullName
local getSexDisplay
local getLicenseNumber
local hasIdentity
local sendIdentityToUI
local saveIdentityData
local loadIdentityData
local onCareerModulesActivated
local onSaveCurrentSaveSlot
local onBeforeSetSaveSlot

-- Private state
local identityData = nil
local activated = false

-- ============================================================================
-- Deterministic license number generation
-- Same (firstName, lastName, birthday) ALWAYS produces the same license number.
-- ============================================================================
generateLicenseNumber = function(firstName, lastName, birthday)
  local seed = string.lower((firstName or "") .. (lastName or "") .. (birthday or ""))
  local hash = 0
  for i = 1, #seed do
    hash = (hash * 31 + string.byte(seed, i)) % 1000000000000
  end
  local d1 = hash % 10000
  local d2 = math.floor(hash / 10000) % 10000
  local d3 = math.floor(hash / 100000000) % 10000
  return string.format("D%04d-%04d-%04d", d1, d2, d3)
end

-- ============================================================================
-- Identity CRUD
-- ============================================================================

-- Set player identity from Vue modal (receives JSON string)
setIdentity = function(jsonStr)
  local data = jsonDecode(jsonStr)
  if not data then
    log('E', 'bcm_identity', 'setIdentity: failed to parse JSON')
    return false
  end

  -- Validate required fields
  if not data.firstName or data.firstName == "" then
    log('E', 'bcm_identity', 'setIdentity: missing firstName')
    return false
  end
  if not data.lastName or data.lastName == "" then
    log('E', 'bcm_identity', 'setIdentity: missing lastName')
    return false
  end
  if not data.sex or data.sex == "" then
    log('E', 'bcm_identity', 'setIdentity: missing sex')
    return false
  end
  if not data.birthday or data.birthday == "" then
    log('E', 'bcm_identity', 'setIdentity: missing birthday')
    return false
  end

  -- Generate deterministic license number
  local licenseNumber = generateLicenseNumber(data.firstName, data.lastName, data.birthday)

  -- Calculate issue date from current game time
  local issueDate = { day = 1, month = 3, year = 2026 }
  if bcm_timeSystem and bcm_timeSystem.getDateInfo then
    local dateInfo = bcm_timeSystem.getDateInfo()
    if dateInfo then
      issueDate = { day = dateInfo.day, month = dateInfo.month, year = dateInfo.year }
    end
  end

  -- Expiry = issue date + 8 years
  local expiryDate = {
    day = issueDate.day,
    month = issueDate.month,
    year = issueDate.year + 8
  }

  -- Store identity
  identityData = {
    firstName = data.firstName,
    lastName = data.lastName,
    sex = data.sex,
    birthday = data.birthday,
    licenseNumber = licenseNumber,
    issueDate = issueDate,
    expiryDate = expiryDate,
    rejectionCount = data.rejectionCount or 0
  }

  -- Notify Vue
  guihooks.trigger('BCMIdentityUpdate', identityData)
  guihooks.trigger('BCMIdentityModalDone', {})

  -- Notify Lua extensions (tutorial waits for this to start)
  extensions.hook("onBCMIdentitySet")

  -- Trigger debounced save
  if career_saveSystem and career_saveSystem.saveCurrentDebounced then
    career_saveSystem.saveCurrentDebounced()
  end

  log('I', 'bcm_identity', 'Identity set: ' .. data.firstName .. ' ' .. data.lastName .. ' (license: ' .. licenseNumber .. ')')
  return true
end

-- Get full identity table (or empty table)
getIdentity = function()
  return identityData or {}
end

-- Get full name string
getFullName = function()
  if not identityData or not identityData.firstName then
    return ""
  end
  return identityData.firstName .. ' ' .. identityData.lastName
end

-- Get sex display character: M, F, or X
getSexDisplay = function()
  if not identityData or not identityData.sex then
    return ""
  end
  local sex = string.lower(identityData.sex)
  if sex == "male" or sex == "m" then return "M" end
  if sex == "female" or sex == "f" then return "F" end
  return "X"  -- "Other" displays as X (like real US states)
end

-- Get license number
getLicenseNumber = function()
  if not identityData then return "" end
  return identityData.licenseNumber or ""
end

-- Check if identity has been set
hasIdentity = function()
  return identityData ~= nil and identityData.firstName ~= nil and identityData.firstName ~= ""
end

-- Resend identity data to UI (called after UI reload or on Vue store init)
-- If no identity exists, re-triggers the modal so the race condition is resolved
sendIdentityToUI = function()
  if identityData then
    guihooks.trigger('BCMIdentityUpdate', identityData)
  elseif activated then
    -- Career is active but no identity â€” show modal (Vue missed the first trigger)
    log('I', 'bcm_identity', 'sendIdentityToUI: no identity, re-triggering modal')
    guihooks.trigger('BCMShowIdentityModal', {})
  end
end

-- ============================================================================
-- Save / Load
-- ============================================================================

-- Save identity data to disk
saveIdentityData = function(currentSavePath)
  if not career_saveSystem then
    log('W', 'bcm_identity', 'career_saveSystem not available, cannot save identity data')
    return
  end

  if not identityData then
    log('D', 'bcm_identity', 'No identity data to save')
    return
  end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  local dataPath = bcmDir .. "/identity.json"
  career_saveSystem.jsonWriteFileSafe(dataPath, identityData, true)

  log('I', 'bcm_identity', 'Saved identity data: ' .. (identityData.firstName or "?") .. ' ' .. (identityData.lastName or "?"))
end

-- Load identity data from disk
loadIdentityData = function()
  if not career_career or not career_career.isActive() then
    return
  end

  if not career_saveSystem then
    log('W', 'bcm_identity', 'career_saveSystem not available, cannot load identity data')
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('W', 'bcm_identity', 'No save slot active, cannot load identity data')
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    log('W', 'bcm_identity', 'No autosave found for slot: ' .. currentSaveSlot)
    return
  end

  local dataPath = autosavePath .. "/career/bcm/identity.json"
  local data = jsonReadFile(dataPath)

  -- Reset state
  identityData = nil

  -- Tell Vue to reset
  guihooks.trigger('BCMIdentityReset', {})

  if data and data.firstName then
    identityData = data
    guihooks.trigger('BCMIdentityUpdate', identityData)
    log('I', 'bcm_identity', 'Loaded identity: ' .. data.firstName .. ' ' .. data.lastName)
  else
    -- No identity data = new career, show modal
    log('I', 'bcm_identity', 'No identity data found â€” triggering identity modal')
    guihooks.trigger('BCMShowIdentityModal', {})
  end
end

-- ============================================================================
-- Lifecycle Hooks
-- ============================================================================

-- Career modules activated â€” load existing identity or prompt for new one
onCareerModulesActivated = function()
  loadIdentityData()
  activated = true

  -- Fallback: if loadIdentityData couldn't reach identity.json (new career, no autosave yet),
  -- guarantee the modal fires so the player can set their identity
  if not identityData then
    log('I', 'bcm_identity', 'No identity after activation â€” triggering modal (fallback)')
    guihooks.trigger('BCMShowIdentityModal', {})
  end

  log('I', 'bcm_identity', 'Identity module activated')
end

-- Save hook â€” persist identity to disk
onSaveCurrentSaveSlot = function(currentSavePath)
  saveIdentityData(currentSavePath)
end

-- Before save slot change â€” clean up state
onBeforeSetSaveSlot = function()
  identityData = nil
  activated = false
  guihooks.trigger('BCMIdentityReset', {})
  log('D', 'bcm_identity', 'Identity state reset (save slot change)')
end

-- ============================================================================
-- Public API
-- ============================================================================

M.setIdentity = setIdentity
M.getIdentity = getIdentity
M.getFullName = getFullName
M.getSexDisplay = getSexDisplay
M.getLicenseNumber = getLicenseNumber
M.hasIdentity = hasIdentity
M.sendIdentityToUI = sendIdentityToUI
M.generateLicenseNumber = generateLicenseNumber

-- Lifecycle hooks
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onBeforeSetSaveSlot = onBeforeSetSaveSlot

return M
