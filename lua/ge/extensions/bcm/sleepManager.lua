-- BCM Sleep Manager
-- Central sleep logic module for BCM career mode.
-- Handles sleep state machine, validation, time advance coordination, and loan payment processing.
-- Extension name: bcm_sleepManager
-- Loaded by bcm_extensionManager after bcm_loans.

local M = {}

M.debugName = "BCM Sleep Manager"
M.debugOrder = 50
M.dependencies = {'bcm_timeSystem', 'bcm_loans'}

-- ============================================================================
-- Forward declarations
-- ============================================================================
local calculateSleepDuration
local requestSleep
local clearSleep
local pendingSleep
local completeSleep

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_sleepManager'

local STATE = { IDLE = "idle", SLEEPING = "sleeping", SUMMARIZING = "summarizing" }
local currentState = STATE.IDLE
local sleepResult = nil
local MIN_SLEEP_HOURS = 1    -- Minimum 1 game-hour (flexible, UI controls practical range)
local MAX_SLEEP_HOURS = 24   -- Maximum 24 game-hours (within next day)

-- ============================================================================
-- Sleep Duration Calculation
-- ============================================================================

-- Calculate fractional game days for sleep duration
-- Handles midnight crossing correctly
-- @param fromTod number - Current time-of-day (0-1)
-- @param toTod number - Target time-of-day (0-1)
-- @return number - Game days to advance
calculateSleepDuration = function(fromTod, toTod)
  if toTod > fromTod then
    return toTod - fromTod  -- Same day
  elseif toTod < fromTod then
    return (1.0 - fromTod) + toTod  -- Crosses midnight
  else
    return 1.0  -- Full day if equal (24 hours)
  end
end

-- ============================================================================
-- Sleep Request
-- ============================================================================

-- Public API: Request sleep to target tod
-- @param targetTod number - Target time-of-day float (0.0 = midnight, 0.5 = noon)
-- @return boolean - True if sleep started successfully
requestSleep = function(targetTod)
  targetTod = tonumber(targetTod)
  if not targetTod or targetTod < 0 or targetTod > 1 then
    guihooks.trigger('BCMSleepError', { error = 'invalid_time' })
    return false
  end

  if currentState ~= STATE.IDLE then
    guihooks.trigger('BCMSleepError', { error = 'already_sleeping' })
    return false
  end

  if not bcm_timeSystem then
    guihooks.trigger('BCMSleepError', { error = 'no_time_system' })
    return false
  end

  local currentTod = scenetree.tod and scenetree.tod.time or 0
  local currentGameDay = bcm_timeSystem.getGameTimeDays()

  -- Calculate duration in game days
  local gameDaysAdvance = calculateSleepDuration(currentTod, targetTod)
  local gameHours = gameDaysAdvance * 24

  -- Validate constraints
  if gameHours < MIN_SLEEP_HOURS then
    guihooks.trigger('BCMSleepError', { error = 'too_short', minHours = MIN_SLEEP_HOURS })
    return false
  end
  if gameHours > MAX_SLEEP_HOURS then
    guihooks.trigger('BCMSleepError', { error = 'too_long', maxHours = MAX_SLEEP_HOURS })
    return false
  end

  -- Enter sleeping state, notify UI
  currentState = STATE.SLEEPING

  -- Pause time during sleep animation
  if scenetree.tod then
    scenetree.tod.play = false
  end

  guihooks.trigger('BCMSleepStarted', {})
  log('I', logTag, 'Sleep started. Target hours: ' .. tostring(gameHours))

  -- After delay, advance time and show summary
  -- Store captured values for the timer callback
  local capturedGameDaysAdvance = gameDaysAdvance
  local capturedGameHours = gameHours
  local capturedPreGameDay = currentGameDay

  -- Cancel any existing pending sleep to prevent duplicates
  pendingSleep = {
    gameDaysAdvance = capturedGameDaysAdvance,
    gameHours = capturedGameHours,
    preGameDay = capturedPreGameDay,
    startTime = os.clock(),
    delay = 2.0  -- 2 second delay for sleep animation
  }

  return true
end

-- Clear sleep state (return to idle)
clearSleep = function()
  currentState = STATE.IDLE
  sleepResult = nil
end

-- Complete sleep after animation delay
completeSleep = function()
  if not pendingSleep then return end

  local data = pendingSleep
  pendingSleep = nil

  -- Resume time and advance
  if scenetree.tod then
    scenetree.tod.play = true
  end

  bcm_timeSystem.advanceTime(data.gameDaysAdvance)

  -- Build sleep result
  sleepResult = {
    hoursSlept = data.gameHours,
    gameDaysAdvanced = data.gameDaysAdvance,
    previousGameDay = data.preGameDay,
    newGameDay = bcm_timeSystem.getGameTimeDays(),
    paymentsProcessed = 0,
    paymentsMissed = 0,
    loanEvents = {}
  }

  -- Process loan payments that occurred during sleep
  if bcm_loans and bcm_loans.processSleepPayments then
    local loanResult = bcm_loans.processSleepPayments(data.preGameDay, bcm_timeSystem.getGameTimeDays())
    sleepResult.paymentsProcessed = loanResult.processed
    sleepResult.paymentsMissed = loanResult.missed
    sleepResult.loanEvents = loanResult.details
  end

  -- Transition to summarizing
  currentState = STATE.SUMMARIZING
  guihooks.trigger('BCMSleepComplete', sleepResult)
  extensions.hook("onBCMSleepComplete", sleepResult)

  log('I', logTag, 'Sleep completed. Hours: ' .. tostring(data.gameHours) .. ', Payments: ' .. tostring(sleepResult.paymentsProcessed))

  -- Auto-clear state
  clearSleep()
end

-- ============================================================================
-- Public API
-- ============================================================================

M.requestSleep = requestSleep

M.getState = function()
  return currentState
end

-- Check for pending sleep completion
M.onUpdate = function(dtReal, dtSim, dtRaw)
  if pendingSleep then
    local elapsed = os.clock() - pendingSleep.startTime
    if elapsed >= pendingSleep.delay then
      completeSleep()
    end
  end
end

return M
