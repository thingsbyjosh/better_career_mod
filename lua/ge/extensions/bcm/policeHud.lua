-- BCM Police HUD Streaming Extension
-- Streams pursuit state to Vue every 100ms via guihooks.trigger during active pursuits.
-- Detects new offenses via diffing, normalizes timer values for bar display.
-- Handles pursuit end result linger (EVADED/BUSTED text for ~4 seconds before hiding).
-- Gates all streaming behind pursuitHudEnabled setting.
-- Extension name: bcm_policeHud

local M = {}

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
local broadcastHudState
local onPursuitEvent
local detectNewOffenses
local onUpdate
local onCareerModulesActivated
local onSettingChanged
local onBeforeSetSaveSlot

-- ============================================================================
-- Constants
-- ============================================================================
local logTag          = 'bcm_policeHud'
local STREAM_INTERVAL = 0.1   -- seconds between BCMPursuitHUDUpdate broadcasts
local EVADE_TIME      = 30    -- seconds (matches configurePursuitVars evadeTime)
local ARREST_TIME     = 5     -- seconds (matches configurePursuitVars arrestTime)
local LINGER_DURATION = 4     -- seconds to show EVADED/BUSTED text after pursuit ends

-- Fine amounts in dollars (cents from fines.lua / 100) for offense flash alerts
local OFFENSE_FINE_DISPLAY = {
  speeding      = 300,
  racing        = 600,
  reckless      = 500,
  wrongWay      = 400,
  intersection  = 500,
  hitTraffic    = 200,
  hitPolice     = 800,
}

-- ============================================================================
-- Private state
-- ============================================================================
local activated       = false
local hudEnabled      = true   -- mirrors pursuitHudEnabled setting
local streamAccum     = 0      -- dtSim accumulator for 100ms tick

-- Pursuit tracking
local pursuitActive   = false
local lastOffenseSet  = {}     -- [offenseKey] = true, for delta detection
local lastLevel       = 0      -- last known pursuit level
local lastPoliceCount = 0      -- last known pursuing unit count

-- Linger phase (after pursuit ends)
local lingerTimer      = 0
local lingerResultText = nil   -- 'evaded' | 'busted' | nil

-- ============================================================================
-- Core streaming function
-- ============================================================================

-- Read traffic data, normalize bar values, count pursuing police, detect new offenses, broadcast HUD state
broadcastHudState = function()
  local level       = 0
  local policeCount = 0
  local barMode     = nil
  local barProgress = 0.0

  pcall(function()
    local trafficData = gameplay_traffic.getTrafficData()
    if not trafficData then return end

    local playerVehId = be:getPlayerVehicleID(0)
    if not playerVehId or playerVehId < 0 then return end

    local playerTraffic = trafficData[playerVehId]
    if not playerTraffic then return end

    local pursuit = playerTraffic.pursuit
    if not pursuit then return end

    -- Extract pursuit level — use BCM level from bcm_police (supports damage-based escalation), fallback to vanilla mode
    level = pursuit.mode or 0
    pcall(function()
      if bcm_police and bcm_police.getCurrentLevel then
        local bcmLevel = bcm_police.getCurrentLevel()
        if bcmLevel and bcmLevel > level then
          level = bcmLevel
        end
      end
    end)

    -- Count active pursuing police (mode > 0 means actively pursuing)
    for vehId, tData in pairs(trafficData) do
      if vehId ~= playerVehId
        and tData.role and tData.role.name == 'police'
        and tData.pursuit and tData.pursuit.mode and tData.pursuit.mode > 0 then
        policeCount = policeCount + 1
      end
    end

    -- Detect new offenses in real-time (every 100ms tick, not just on level_change)
    if pursuit.offenses then
      local offenseTypes = {}
      for offenseKey, _ in pairs(pursuit.offenses) do
        table.insert(offenseTypes, offenseKey)
      end
      detectNewOffenses(offenseTypes)
    end

    -- Read timers with full nil guard
    local timers = pursuit.timers
    local evadeTimer  = (timers and timers.evade)  or 0
    local arrestTimer = (timers and timers.arrest) or 0

    -- Determine bar mode and progress
    -- Arrest takes priority over evasion (arrest bar fills; evasion bar drains)
    if arrestTimer > 0 then
      barMode     = 'arrest'
      -- Arrest bar fills from 0 to 1 as timer counts up toward arrest
      barProgress = arrestTimer / ARREST_TIME
      barProgress = math.max(0.0, math.min(1.0, barProgress))
    elseif evadeTimer > 0 then
      barMode     = 'evasion'
      -- Evasion bar drains from 1 to 0 as timer counts down
      barProgress = evadeTimer / EVADE_TIME
      barProgress = math.max(0.0, math.min(1.0, barProgress))
    end
  end)

  -- If pursuit vanished (e.g. vehicle switch cleared traffic data), auto-hide HUD
  if level == 0 and policeCount == 0 and not barMode then
    pursuitActive    = false
    lingerTimer      = 0
    lingerResultText = nil
    lastOffenseSet   = {}
    guihooks.trigger('BCMPursuitHUDUpdate', {
      active      = false,
      level       = 0,
      policeCount = 0,
      barMode     = nil,
      barProgress = 0.0,
      resultText  = nil,
      damageCost  = 0
    })
    return
  end

  -- Cache last known state for linger phase
  lastLevel       = level
  lastPoliceCount = policeCount

  guihooks.trigger('BCMPursuitHUDUpdate', {
    active      = true,
    level       = level,
    policeCount = policeCount,
    barMode     = barMode,
    barProgress = barProgress,
    resultText  = nil,
    damageCost  = bcm_police and bcm_police.getDamageCost and bcm_police.getDamageCost() or 0
  })
end

-- ============================================================================
-- Offense delta detection
-- ============================================================================

-- Compare current offenseTypes against lastOffenseSet; fire BCMNewOffense for each new entry
detectNewOffenses = function(offenseTypes)
  if not offenseTypes then return end

  for _, offenseKey in ipairs(offenseTypes) do
    if not lastOffenseSet[offenseKey] then
      lastOffenseSet[offenseKey] = true
      guihooks.trigger('BCMNewOffense', {
        offenseKey = offenseKey,
        amount     = OFFENSE_FINE_DISPLAY[offenseKey] or 0
      })
      log('D', logTag, 'New offense detected: ' .. tostring(offenseKey) .. ' (amount=' .. tostring(OFFENSE_FINE_DISPLAY[offenseKey] or 0) .. ')')
    end
  end
end

-- ============================================================================
-- Pursuit event receiver (dispatched from bcm_police via pcall)
-- ============================================================================

onPursuitEvent = function(data)
  if not activated or not hudEnabled then return end
  if not data then return end

  local action = data.action

  if action == 'start' then
    pursuitActive    = true
    lingerTimer      = 0
    lingerResultText = nil
    -- Initialize lastOffenseSet from the first batch WITHOUT firing alerts
    -- (avoids alert flooding on pursuit start for offenses that triggered the pursuit)
    lastOffenseSet = {}
    if data.offenseTypes then
      for _, offenseKey in ipairs(data.offenseTypes) do
        lastOffenseSet[offenseKey] = true
      end
    end
    log('D', logTag, 'Pursuit started — HUD streaming active')

  elseif action == 'level_change' then
    -- Detect any new offenses that appeared since last event
    detectNewOffenses(data.offenseTypes)

  elseif action == 'arrest' then
    pursuitActive    = false
    lingerTimer      = LINGER_DURATION
    lingerResultText = 'busted'
    lastOffenseSet   = {}
    log('D', logTag, 'Pursuit arrested — showing BUSTED linger')

  elseif action == 'evade' then
    pursuitActive    = false
    lingerTimer      = LINGER_DURATION
    lingerResultText = 'evaded'
    lastOffenseSet   = {}
    log('D', logTag, 'Pursuit evaded — showing EVADED linger')

  elseif action == 'reset' or action == 'timeout_evade' then
    pursuitActive    = false
    lingerTimer      = LINGER_DURATION
    lingerResultText = 'evaded'
    lastOffenseSet   = {}
    log('D', logTag, 'Pursuit reset — showing EVADED linger')
  end
end

-- ============================================================================
-- onUpdate — main streaming tick (100ms accumulator)
-- ============================================================================

onUpdate = function(dtReal, dtSim, dtRaw)
  if not activated or not hudEnabled then return end

  -- Handle linger phase (overrides normal streaming)
  if lingerTimer > 0 then
    lingerTimer = lingerTimer - dtSim

    if lingerTimer <= 0 then
      -- Linger expired — hide HUD
      lingerTimer      = 0
      lingerResultText = nil
      guihooks.trigger('BCMPursuitHUDUpdate', {
        active      = false,
        level       = 0,
        policeCount = 0,
        barMode     = nil,
        barProgress = 0.0,
        resultText  = nil,
        damageCost  = 0
      })
      return
    end

    -- Broadcast linger state on same 100ms gate (avoids per-frame CEF spam)
    streamAccum = streamAccum + dtSim
    if streamAccum >= STREAM_INTERVAL then
      streamAccum = streamAccum - STREAM_INTERVAL
      guihooks.trigger('BCMPursuitHUDUpdate', {
        active      = true,
        level       = lastLevel,
        policeCount = lastPoliceCount,
        barMode     = nil,
        barProgress = 0.0,
        resultText  = lingerResultText,
        damageCost  = bcm_police and bcm_police.getDamageCost and bcm_police.getDamageCost() or 0
      })
    end
    return
  end

  -- Normal streaming during active pursuit (100ms gate)
  if not pursuitActive then return end

  streamAccum = streamAccum + dtSim
  if streamAccum >= STREAM_INTERVAL then
    streamAccum = streamAccum - STREAM_INTERVAL
    broadcastHudState()
  end
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

onCareerModulesActivated = function(alreadyInLevel)
  activated  = true
  hudEnabled = true  -- default

  -- Read setting if available
  pcall(function()
    if bcm_settings then
      local val = bcm_settings.getSetting('pursuitHudEnabled')
      if val ~= nil then
        hudEnabled = val
      end
    end
  end)

  log('I', logTag, 'BCM Police HUD activated — hudEnabled=' .. tostring(hudEnabled))
end

onSettingChanged = function(key, value)
  if key == 'pursuitHudEnabled' then
    hudEnabled = value
    log('I', logTag, 'pursuitHudEnabled changed to: ' .. tostring(value))

    -- Hide HUD immediately when disabled
    if not value then
      guihooks.trigger('BCMPursuitHUDUpdate', {
        active      = false,
        level       = 0,
        policeCount = 0,
        barMode     = nil,
        barProgress = 0.0,
        resultText  = nil,
        damageCost  = 0
      })
    end
  end
end

-- Hide HUD during save slot transitions / loading screens
onBeforeSetSaveSlot = function()
  guihooks.trigger('BCMPursuitHUDUpdate', {
    active      = false,
    level       = 0,
    policeCount = 0,
    barMode     = nil,
    barProgress = 0.0,
    resultText  = nil,
    damageCost  = 0
  })

  -- Reset all state (pursuit resets on load)
  pursuitActive    = false
  lingerTimer      = 0
  lingerResultText = nil
  lastOffenseSet   = {}
  streamAccum      = 0
end

-- ============================================================================
-- M table exports
-- ============================================================================

-- Lifecycle hooks (BeamNG dispatches these)
M.onCareerModulesActivated = onCareerModulesActivated
M.onBeforeSetSaveSlot      = onBeforeSetSaveSlot

-- Called by bcm_police.lua via pcall optional coupling
M.onPursuitEvent           = onPursuitEvent

-- Called by bcm_settings.lua applySettingToModule
M.onSettingChanged         = onSettingChanged

-- Main tick (registered via extensions.load; BeamNG calls onUpdate on all loaded extensions)
M.onUpdate                 = onUpdate

-- No save/load — HUD state is volatile, never persisted

return M
