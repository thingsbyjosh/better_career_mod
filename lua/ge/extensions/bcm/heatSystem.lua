-- BCM Heat System Extension
-- Persistent heat accumulator (0-10000, 10 levels) that tracks police heat across pursuits,
-- decays over real time with a non-linear curve, dynamically modifies police sensitivity
-- via setPursuitVars, and persists across save/load with retroactive decay.
-- Extension name: bcm_heatSystem

local M = {}

-- ============================================================================
-- Forward declarations (ALL functions before any function body -- project rule)
-- ============================================================================
local onPursuitEvent
local applyHeatToPolice
local broadcastHeatUpdate
local runDecayTick
local getHeatLevel
local getHeatAccum
local saveHeatData
local loadHeatData
local onCareerModulesActivated
local onSaveCurrentSaveSlot
local onUpdate
local setHeat          -- debug
local addHeat          -- debug
local resetHeat        -- debug
local forceDecayTick   -- debug
local printStatus      -- debug
-- Per-map heat export/import for multimap
local getHeatForExport
local loadHeatFromImport
-- Vehicle recognition system
local captureVehicleFingerprint
local clearRecognition
local checkRecognition
local triggerRecognitionPursuit
local recognitionCheckAccum

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_heatSystem'
local SAVE_FILE = "heat.json"
local MAX_HEAT = 10000
local NUM_LEVELS = 10
local BROADCAST_INTERVAL = 0.5

-- Heat points awarded per pursuit level on level_change event (3-level system)
local HEAT_POINTS_LEVEL_CHANGE = {
  [1] = 50,
  [2] = 200,
  [3] = 600,
}

-- Heat points awarded per pursuit level on arrest event (3-level system)
local HEAT_POINTS_ARREST = {
  [1] = 30,
  [2] = 120,
  [3] = 400,
}

-- Decay points per second per heat level
-- Designed for ~60 min full decay from level 10 to 0
local DECAY_RATE = {
  [1]  = 2.8,
  [2]  = 4.2,
  [3]  = 5.5,
  [4]  = 6.0,
  [5]  = 6.5,
  [6]  = 7.0,
  [7]  = 7.5,
  [8]  = 8.0,
  [9]  = 8.5,
  [10] = 9.0,
}

-- Police sensitivity parameters per heat level
-- strictness: higher = more sensitive / detects faster (vanilla default 0.5)
-- suspectFrequency: higher = checks player more often (vanilla default 0.5)
local HEAT_POLICE_PARAMS = {
  [0]  = { strictness = 0.20, suspectFrequency = 0.50 },
  [1]  = { strictness = 0.24, suspectFrequency = 0.54 },
  [2]  = { strictness = 0.28, suspectFrequency = 0.58 },
  [3]  = { strictness = 0.32, suspectFrequency = 0.62 },
  [4]  = { strictness = 0.37, suspectFrequency = 0.66 },
  [5]  = { strictness = 0.42, suspectFrequency = 0.70 },
  [6]  = { strictness = 0.48, suspectFrequency = 0.75 },
  [7]  = { strictness = 0.55, suspectFrequency = 0.80 },
  [8]  = { strictness = 0.65, suspectFrequency = 0.85 },
  [9]  = { strictness = 0.78, suspectFrequency = 0.90 },
  [10] = { strictness = 0.95, suspectFrequency = 0.95 },
}

-- Score levels per heat range (3-level system)
-- Only level 1 threshold varies by heat; levels 2-3 blocked (driven by damage cost)
-- These are NOT used directly anymore â€” applyHeatToPolice sets scoreLevels inline
-- Kept as documentation reference only

-- Recognition probability per heat level (checked every 2s when a police unit has line of sight)
local RECOGNITION_PROB = {
  [0]  = 0,
  [1]  = 0.03,
  [2]  = 0.05,
  [3]  = 0.08,
  [4]  = 0.12,
  [5]  = 0.18,
  [6]  = 0.25,
  [7]  = 0.40,
  [8]  = 0.60,
  [9]  = 0.80,
  [10] = 0.95,
}

local RECOGNITION_SIGHT_THRESHOLD = 0.3   -- minimum sightValue to attempt recognition
local RECOGNITION_CHECK_INTERVAL  = 2.0   -- seconds between recognition checks

-- ============================================================================
-- Private state
-- ============================================================================
local activated = false
local heatAccum = 0              -- 0-10000
local pursuitActive = false
local lastDecayTimestamp = nil    -- os.time wall clock on save
local broadcastAccum = 0
-- Recognition system state
local recognitionRecord = nil    -- nil when no fingerprint; table {model, licensePlate, paintColor, offenseTypes, level} when active
recognitionCheckAccum = 0

-- ============================================================================
-- Core functions
-- ============================================================================

-- Calculate heat level from accumulator: floor(sqrt(accumulator / 100)) clamped to [0, 10]
getHeatLevel = function()
  return math.max(0, math.min(NUM_LEVELS, math.floor(math.sqrt(heatAccum / 100))))
end

-- Return raw accumulator value
getHeatAccum = function()
  return heatAccum
end

-- Push current heat state to Vue frontend (throttled in onUpdate)
broadcastHeatUpdate = function()
  guihooks.trigger('BCMHeatUpdate', {
    accumulator      = heatAccum,
    level            = getHeatLevel(),
    maxAccum         = MAX_HEAT,
    maxLevel         = NUM_LEVELS,
    pursuitActive    = pursuitActive,
    recognitionRecord = recognitionRecord,
  })
end

-- ============================================================================
-- Vehicle recognition system
-- ============================================================================

-- Capture the player's current vehicle fingerprint (model + plate + paint)
captureVehicleFingerprint = function()
  local playerVehId = be:getPlayerVehicleID(0)
  if not playerVehId or playerVehId < 0 then return nil end

  local model = nil
  local ok, err = pcall(function()
    local vehObj = getObjectByID(playerVehId)
    if vehObj then
      model = vehObj:getField('jBeam', '')
    end
  end)
  if not ok or not model or model == '' then
    log('W', logTag, 'captureVehicleFingerprint: could not read jBeam model')
    return nil
  end

  local plate = nil
  pcall(function()
    if bcm_identity and bcm_identity.getLicenseNumber then
      plate = bcm_identity.getLicenseNumber()
    end
  end)
  plate = plate or 'UNKNOWN'

  local paintColor = nil
  pcall(function()
    if career_modules_inventory and career_modules_inventory.getVehicles then
      local vehicles = career_modules_inventory.getVehicles()
      local idMap = career_modules_inventory.getMapInventoryIdToVehId and career_modules_inventory.getMapInventoryIdToVehId() or {}
      for invId, vehInfo in pairs(vehicles) do
        local vid = idMap[invId]
        if vid == playerVehId then
          if vehInfo.config and vehInfo.config.paints and vehInfo.config.paints[1] then
            paintColor = vehInfo.config.paints[1].baseColor
          end
          break
        end
      end
    end
  end)

  return { model = model, licensePlate = plate, paintColor = paintColor }
end

-- Clear the recognition record (called on repaint, vehicle switch, heat decay to 0)
clearRecognition = function()
  if recognitionRecord then
    recognitionRecord = nil
    broadcastHeatUpdate()
    log('I', logTag, 'Recognition record cleared')
  end
end

-- Trigger a recognition pursuit: re-apply stored offenses and notify player
triggerRecognitionPursuit = function()
  if not recognitionRecord then return end

  log('I', logTag, 'Recognition triggered â€” stored vehicle fingerprint matched by police unit')

  -- Send phone notification
  pcall(function()
    if bcm_notifications and bcm_notifications.send then
      bcm_notifications.send({
        titleKey = 'notif.recognitionTitle',
        bodyKey  = 'notif.recognitionBody',
        icon     = 'eye',
        app      = 'heat',
        type     = 'warning',
        duration = 5000,
      })
    end
  end)

  -- HUD flash
  pcall(function()
    if bcm_policeHud and bcm_policeHud.onPursuitEvent then
      bcm_policeHud.onPursuitEvent({ action = 'recognition_spotted' })
    end
  end)

  -- Re-apply the stored offenses as a new arrest fine
  pcall(function()
    if bcm_fines and bcm_fines.onPursuitEvent then
      bcm_fines.onPursuitEvent({
        action           = 'arrest',
        level            = recognitionRecord.level or 1,
        offenseTypes     = recognitionRecord.offenseTypes or {},
        offenses         = #(recognitionRecord.offenseTypes or {}),
        pursuitStartTime = os.clock(),
        vehicleId        = be:getPlayerVehicleID(0),
        position         = { x = 0, y = 0, z = 0 },
        isRecognitionFine = true,
      })
    end
  end)

  -- Force pursuit start â€” lower score threshold so next infraction triggers pursuit
  -- Only lower level 1 threshold; levels 2-3 are controlled by BCM damage escalation
  pcall(function()
    if gameplay_police and gameplay_police.setPursuitVars then
      gameplay_police.setPursuitVars({ scoreLevels = { 1, 1e9, 2e9 } })
    end
  end)

  recognitionRecord = nil
  broadcastHeatUpdate()
end

-- Check if any nearby police unit spots a recognized vehicle and triggers a pursuit
checkRecognition = function()
  if not recognitionRecord then return end
  if pursuitActive then return end
  if heatAccum <= 0 then return end

  local playerVehId = be:getPlayerVehicleID(0)
  if not playerVehId or playerVehId < 0 then return end

  local level = getHeatLevel()
  local prob = RECOGNITION_PROB[level] or 0
  if prob <= 0 then return end

  local ok, trafficData = pcall(function()
    return gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData()
  end)
  if not ok or not trafficData then return end

  for vehId, tData in pairs(trafficData) do
    if tData.role and tData.role.name == 'police' and vehId ~= playerVehId then
      local sv = 0
      if tData.sightValues then
        sv = tData.sightValues[playerVehId] or tData.sightValues[tostring(playerVehId)] or 0
      end
      if sv >= RECOGNITION_SIGHT_THRESHOLD then
        if math.random() < prob then
          log('I', logTag, string.format('Recognition check: police unit %s spotted player (sv=%.2f, prob=%.2f)', tostring(vehId), sv, prob))
          triggerRecognitionPursuit()
          return
        end
      end
    end
  end
end

-- Run one decay tick for dt seconds of real time
runDecayTick = function(dt)
  if pursuitActive then return end
  if heatAccum <= 0 then return end

  local level = getHeatLevel()
  local rate = DECAY_RATE[level] or 5.0
  heatAccum = math.max(0, heatAccum - rate * dt)

  -- Clear recognition when heat fully decays
  if heatAccum <= 0 then
    heatAccum = 0
    if recognitionRecord then clearRecognition() end
  end
end

-- Apply heat-modified police sensitivity via setPursuitVars
-- IMPORTANT: Only pass strictness and suspectFrequency.
-- scoreLevels are owned by bcm_police (level 1 only by score, 2-3 by damage).
-- Do NOT pass arrestTime, evadeTime, autoRelease -- those are owned by bcm_police
applyHeatToPolice = function()
  local level = getHeatLevel()
  local params = HEAT_POLICE_PARAMS[level] or HEAT_POLICE_PARAMS[0]

  -- Heat affects how easily pursuit STARTS (level 1 score threshold) but NOT escalation
  -- Higher heat = lower threshold to trigger initial pursuit
  local scoreLevel1
  if level <= 3 then
    scoreLevel1 = 100   -- normal: need 100 score to start pursuit
  elseif level <= 6 then
    scoreLevel1 = 50    -- medium heat: easier to trigger
  elseif level <= 9 then
    scoreLevel1 = 20    -- high heat: very easy
  else
    scoreLevel1 = 1     -- max heat: any infraction starts pursuit
  end

  pcall(function()
    if gameplay_police and gameplay_police.setPursuitVars then
      gameplay_police.setPursuitVars({
        strictness       = params.strictness,
        suspectFrequency = params.suspectFrequency,
        scoreLevels      = { scoreLevel1, 1e9, 2e9 },
      })
    end
  end)
end

-- ============================================================================
-- Event handlers
-- ============================================================================

-- Handle pursuit events dispatched from bcm_police
onPursuitEvent = function(data)
  if not activated then return end
  if not data then return end

  local action = data.action
  local level  = data.level or 0

  if action == 'start' then
    pursuitActive = true

  elseif action == 'level_change' then
    -- Add heat for ALL intermediate levels when pursuit jumps (e.g., 0â†’3 awards levels 1+2+3)
    local prevLevel = data.prevLevel or 0
    local totalPts = 0
    for l = prevLevel + 1, level do
      totalPts = totalPts + (HEAT_POINTS_LEVEL_CHANGE[l] or 0)
    end
    if totalPts == 0 then
      totalPts = HEAT_POINTS_LEVEL_CHANGE[level] or 0
    end
    heatAccum = math.min(MAX_HEAT, heatAccum + totalPts)
    log('I', logTag, string.format('Heat +%d from level_change (level=%d, prev=%d) -- total=%.0f', totalPts, level, prevLevel, heatAccum))

  elseif action == 'arrest' then
    -- Add heat for arrest FIRST, then clear pursuit flag
    local pts = HEAT_POINTS_ARREST[level] or 0
    heatAccum = math.min(MAX_HEAT, heatAccum + pts)
    log('I', logTag, string.format('Heat +%d from arrest (level=%d) -- total=%.0f', pts, level, heatAccum))
    pursuitActive = false

  elseif action == 'roadblock' then
    -- Roadblock = serious escalation, treat like level_change
    local pts = HEAT_POINTS_LEVEL_CHANGE[level] or HEAT_POINTS_LEVEL_CHANGE[5] or 0
    heatAccum = math.min(MAX_HEAT, heatAccum + pts)
    log('I', logTag, string.format('Heat +%d from roadblock (level=%d) -- total=%.0f', pts, level, heatAccum))

  elseif action == 'evade' or action == 'reset' or action == 'timeout_evade' then
    -- Neutral: no heat change
    pursuitActive = false

    -- Capture fingerprint on successful evasion (not on debug reset)
    if action == 'evade' or action == 'timeout_evade' then
      local fp = captureVehicleFingerprint()
      if fp then
        recognitionRecord = fp
        recognitionRecord.offenseTypes = data.offenseTypes or {}
        recognitionRecord.level = data.level or 1
        log('I', logTag, 'Recognition record captured: model=' .. fp.model .. ' plate=' .. fp.licensePlate)
      end
    end
  end

  -- Re-apply police sensitivity after every event
  applyHeatToPolice()

  -- Broadcast to Vue
  broadcastHeatUpdate()
end

-- ============================================================================
-- Save / Load
-- ============================================================================

-- Persist heat data to save slot
saveHeatData = function(currentSavePath)
  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end
  local data = { heatAccum = heatAccum, savedAt = os.time(), recognitionRecord = recognitionRecord }
  career_saveSystem.jsonWriteFileSafe(bcmDir .. "/" .. SAVE_FILE, data, true)
  log('D', logTag, string.format('Heat saved: accum=%.0f, level=%d', heatAccum, getHeatLevel()))
end

-- Load heat data from save slot with retroactive decay
loadHeatData = function()
  if not career_career or not career_career.isActive() then
    return
  end

  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available, cannot load heat data')
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('W', logTag, 'No save slot active, cannot load heat data')
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    log('W', logTag, 'No autosave found for slot: ' .. currentSaveSlot)
    return
  end

  local dataPath = autosavePath .. "/career/bcm/" .. SAVE_FILE
  local data = jsonReadFile(dataPath)

  if data then
    heatAccum = data.heatAccum or 0
    recognitionRecord = data.recognitionRecord or nil

    -- Retroactive decay: apply elapsed time since save
    if data.savedAt then
      local elapsed = os.time() - data.savedAt
      -- Cap at 7200 seconds (2 hours) to prevent drift issues
      elapsed = math.min(elapsed, 7200)
      if elapsed > 0 then
        -- Apply decay in 60-second chunks so level-based rate changes are respected
        local ticks = math.floor(elapsed / 60)
        for i = 1, ticks do
          runDecayTick(60)
        end
        -- Apply remainder
        local remainder = elapsed - (ticks * 60)
        if remainder > 0 then
          runDecayTick(remainder)
        end
      end
    end

    log('I', logTag, string.format('Heat loaded: accum=%.0f, level=%d (after retroactive decay)', heatAccum, getHeatLevel()))
  else
    -- Clean slate for pre-saves
    heatAccum = 0
    log('I', logTag, 'No heat data found, starting clean')
  end
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

onCareerModulesActivated = function()
  activated = true
  loadHeatData()
  applyHeatToPolice()
  broadcastHeatUpdate()
  log('I', logTag, string.format('Heat system activated: accum=%.0f, level=%d', heatAccum, getHeatLevel()))
end

onSaveCurrentSaveSlot = function(currentSavePath)
  saveHeatData(currentSavePath)
end

onUpdate = function(dtReal, dtSim, dtRaw)
  if not activated then return end

  runDecayTick(dtSim)

  -- Throttle broadcasts to every BROADCAST_INTERVAL seconds
  broadcastAccum = broadcastAccum + dtSim
  if broadcastAccum >= BROADCAST_INTERVAL then
    broadcastAccum = 0
    broadcastHeatUpdate()
  end

  -- Throttle recognition checks to every RECOGNITION_CHECK_INTERVAL seconds
  recognitionCheckAccum = recognitionCheckAccum + dtSim
  if recognitionCheckAccum >= RECOGNITION_CHECK_INTERVAL then
    recognitionCheckAccum = 0
    checkRecognition()
  end
end

-- ============================================================================
-- Debug commands (callable from BeamNG console as bcm_heatSystem.commandName)
-- ============================================================================

-- Set heat to exact accumulator value (0-10000)
setHeat = function(value)
  heatAccum = math.max(0, math.min(MAX_HEAT, tonumber(value) or 0))
  applyHeatToPolice()
  broadcastHeatUpdate()
  log('I', logTag, 'Debug setHeat: accumulator=' .. string.format('%.0f', heatAccum) .. ' level=' .. getHeatLevel())
end

-- Add heat points directly
addHeat = function(points)
  heatAccum = math.max(0, math.min(MAX_HEAT, heatAccum + (tonumber(points) or 0)))
  applyHeatToPolice()
  broadcastHeatUpdate()
  log('I', logTag, 'Debug addHeat: accumulator=' .. string.format('%.0f', heatAccum) .. ' level=' .. getHeatLevel())
end

-- Reset heat to zero
resetHeat = function()
  heatAccum = 0
  applyHeatToPolice()
  broadcastHeatUpdate()
  log('I', logTag, 'Debug resetHeat: heat cleared')
end

-- Create a fake recognition record for testing (without running a real pursuit)
local setRecognition
setRecognition = function()
  recognitionRecord = {
    model        = 'debug',
    licensePlate = 'DEBUG-0000',
    paintColor   = { r = 1, g = 0, b = 0 },
    offenseTypes = { 'speeding', 'racing' },
    level        = 3,
  }
  broadcastHeatUpdate()
  log('I', logTag, 'Debug setRecognition: fake recognition record created')
end

-- Force one decay tick (60 seconds worth)
forceDecayTick = function()
  local before = heatAccum
  runDecayTick(60)
  log('I', logTag, string.format('Debug forceDecayTick: %.0f -> %.0f (level %d)', before, heatAccum, getHeatLevel()))
  applyHeatToPolice()
  broadcastHeatUpdate()
end

-- Full status dump
printStatus = function()
  log('I', logTag, '========== BCM HEAT STATUS ==========')
  log('I', logTag, 'heatAccum: ' .. string.format('%.0f', heatAccum) .. ' / ' .. MAX_HEAT)
  log('I', logTag, 'heatLevel: ' .. getHeatLevel() .. ' / ' .. NUM_LEVELS)
  log('I', logTag, 'pursuitActive: ' .. tostring(pursuitActive))
  -- Recognition record
  if recognitionRecord then
    log('I', logTag, 'recognitionRecord.model: ' .. tostring(recognitionRecord.model))
    log('I', logTag, 'recognitionRecord.licensePlate: ' .. tostring(recognitionRecord.licensePlate))
    log('I', logTag, 'recognitionRecord.level: ' .. tostring(recognitionRecord.level))
    local offenses = recognitionRecord.offenseTypes or {}
    log('I', logTag, 'recognitionRecord.offenseTypes: ' .. table.concat(offenses, ', '))
  else
    log('I', logTag, 'recognitionRecord: nil (no active fingerprint)')
  end
  log('I', logTag, '=====================================')
  -- Also print police sensitivity being applied
  local level = getHeatLevel()
  local params = HEAT_POLICE_PARAMS[level] or HEAT_POLICE_PARAMS[0]
  log('I', logTag, string.format('Current police params: strictness=%.2f suspectFreq=%.2f', params.strictness, params.suspectFrequency))
end

-- ============================================================================
-- Per-map heat export/import
-- ============================================================================

-- Export current heat state for per-map storage by bcm_multimap
getHeatForExport = function()
  return {
    heatAccum = heatAccum,
    recognitionRecord = deepcopy(recognitionRecord),
  }
end

-- Import heat state from per-map storage (called by bcm_multimap on map switch)
loadHeatFromImport = function(data)
  heatAccum = (data and data.heatAccum) or 0
  recognitionRecord = (data and data.recognitionRecord) or nil
  applyHeatToPolice()
  broadcastHeatUpdate()
  log('I', logTag, string.format('Heat imported: accum=%.0f, level=%d', heatAccum, getHeatLevel()))
end

-- ============================================================================
-- Module exports
-- ============================================================================

-- Lifecycle hooks
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onUpdate = onUpdate

-- Event handlers
M.onPursuitEvent = onPursuitEvent

-- Public API
M.getHeatLevel = getHeatLevel
M.getHeatAccum = getHeatAccum
M.applyHeatToPolice = applyHeatToPolice
M.broadcastHeatUpdate = broadcastHeatUpdate

-- Debug commands
M.setHeat = setHeat
M.addHeat = addHeat
M.resetHeat = resetHeat
M.forceDecayTick = forceDecayTick
M.printStatus = printStatus

-- Recognition system API
M.clearRecognition = clearRecognition
M.onVehicleSwitched = function(oldId, newId) clearRecognition() end

-- Recognition debug command
M.setRecognition = setRecognition

-- Per-map heat export/import
M.getHeatForExport = getHeatForExport
M.loadHeatFromImport = loadHeatFromImport

return M
