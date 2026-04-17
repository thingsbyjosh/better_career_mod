-- BCM Weather System
-- Core weather state machine with seasonal probability tables, smooth transitions,
-- and scenetree control (rain, fog, clouds, wind, sound).
-- Weather regenerates fresh each session from season probabilities (no persistence).
-- Extension name: bcm_weather
-- Loaded by bcm_extensionManager after bcm_sleepManager.

local M = {}

M.debugName = "BCM Weather"
M.debugOrder = 15

-- ============================================================================
-- Forward declarations
-- ============================================================================
local initWeatherObjects
local cleanupWeatherObjects
local selectWeatherFromSeason
local selectAndApplyWeather
local startTransition
local updateTransition
local scheduleNextWeatherChange
local getSeasonalProbabilities
local easeInOutQuad
local lerpValue
local getScenetreeTargets
local applyScenetreeValues
local switchRainDataBlock
local updateRainSound
local broadcastWeatherUpdate
local onUpdate
local onCareerActive
-- Plan 01 (settings): Weather control API forward declarations
local setWeatherEnabled
local setSeasonLock
-- Plan 03: Physics integration forward declarations
local updateGroundmodel
local applyGroundmodel
local updateWindEffect
local updateThunderLightning
local updateTrafficSpeed

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_weather'

-- Weather states
local STATES = {"sunny", "overcast", "drizzle", "storm", "snow", "blizzard"}

-- Transition duration: 180 seconds (3 minutes real time for smooth visual blending)
local TRANSITION_DURATION = 180

-- Weather duration ranges per state (real seconds)
-- Most time spent in calm conditions, adverse events are brief
local STATE_DURATION = {
  sunny    = {min = 900,  max = 2400},  -- 15-40 min (dominant)
  overcast = {min = 300,  max = 900},   -- 5-15 min (transition state, shorter)
  drizzle  = {min = 180,  max = 600},   -- 3-10 min (builds up to storm or clears)
  storm    = {min = 120,  max = 180},   -- 2-3 min (brief intense peak)
  snow     = {min = 300,  max = 600},   -- 5-10 min (moderate)
  blizzard = {min = 90,   max = 150},   -- 1.5-2.5 min (rare & very brief)
}

-- Natural weather progression chains (weather moves gradually, no jumping)
-- Each state lists what it can transition TO
local WEATHER_CHAINS = {
  sunny    = {"overcast"},                          -- can only get cloudier
  overcast = {"sunny", "drizzle", "snow"},           -- clears, rain starts, or snow starts
  drizzle  = {"overcast", "storm"},                  -- eases off or intensifies
  storm    = {"drizzle"},                            -- always winds down to drizzle first
  snow     = {"overcast", "blizzard"},               -- clears or intensifies
  blizzard = {"snow"},                               -- always winds down to snow first
}

-- Scenetree target profiles for each weather state
-- skyBrightness: multiplier applied to sunsky.brightness (1.0 = normal, lower = darker)
local WEATHER_PROFILES = {
  sunny = {
    cloudsCoverage = 0.2,
    fogDensity = 0.0001,
    rainNumDrops = 0,
    windStrength = 0.1,
    rainDropSize = 1.0,
    rainSoundVolume = 0,
    skyBrightness = 1.0
  },
  overcast = {
    cloudsCoverage = 0.8,
    fogDensity = 0.001,
    rainNumDrops = 0,
    windStrength = 0.2,
    rainDropSize = 1.0,
    rainSoundVolume = 0,
    skyBrightness = 0.75
  },
  drizzle = {
    cloudsCoverage = 1.0,
    fogDensity = 0.005,
    rainNumDrops = 800,
    windStrength = 0.3,
    rainDropSize = 1.0,
    rainSoundVolume = 0.3,
    skyBrightness = 0.6
  },
  storm = {
    cloudsCoverage = 1.3,
    fogDensity = 0.02,
    rainNumDrops = 2500,
    windStrength = 0.5,
    rainDropSize = 1.0,
    rainSoundVolume = 0.7,
    skyBrightness = 0.10
  },
  snow = {
    cloudsCoverage = 1.0,
    fogDensity = 0.008,
    rainNumDrops = 1500,
    windStrength = 0.15,
    rainDropSize = 0.75,
    rainSoundVolume = 0,
    skyBrightness = 0.55
  },
  blizzard = {
    cloudsCoverage = 1.5,
    fogDensity = 0.04,
    rainNumDrops = 3000,
    windStrength = 0.6,
    rainDropSize = 1.0,
    rainSoundVolume = 0,
    skyBrightness = 0.08
  }
}

-- Stagger control: rain/sound starts AFTER clouds/fog/brightness
-- Value 0-1: at what % of transition progress rain begins (0.4 = rain starts at 40%)
local RAIN_DELAY_FACTOR = 0.4

-- Seasonal probability tables keyed to month (1-12)
-- These weight the CHAIN transitions (not direct selection)
-- Higher weight = more likely to be chosen when it's a valid chain option
-- Note: sunny/overcast dominate because chains funnel through them naturally
local SEASONAL_PROBABILITIES = {
  -- Winter (blizzard only in Dec-Feb, very rare)
  [1]  = {sunny = 20, overcast = 35, drizzle = 0, storm = 0, snow = 40, blizzard = 5},
  [2]  = {sunny = 25, overcast = 35, drizzle = 0, storm = 0, snow = 35, blizzard = 5},
  -- Spring
  [3]  = {sunny = 45, overcast = 30, drizzle = 20, storm = 5, snow = 0, blizzard = 0},
  [4]  = {sunny = 55, overcast = 25, drizzle = 15, storm = 5, snow = 0, blizzard = 0},
  [5]  = {sunny = 60, overcast = 22, drizzle = 13, storm = 5, snow = 0, blizzard = 0},
  -- Summer
  [6]  = {sunny = 70, overcast = 18, drizzle = 8, storm = 4, snow = 0, blizzard = 0},
  [7]  = {sunny = 75, overcast = 15, drizzle = 6, storm = 4, snow = 0, blizzard = 0},
  [8]  = {sunny = 70, overcast = 18, drizzle = 8, storm = 4, snow = 0, blizzard = 0},
  -- Autumn
  [9]  = {sunny = 40, overcast = 30, drizzle = 22, storm = 8, snow = 0, blizzard = 0},
  [10] = {sunny = 25, overcast = 35, drizzle = 28, storm = 12, snow = 0, blizzard = 0},
  [11] = {sunny = 20, overcast = 38, drizzle = 25, storm = 12, snow = 5, blizzard = 0},
  -- Winter
  [12] = {sunny = 20, overcast = 30, drizzle = 0, storm = 0, snow = 45, blizzard = 5},
}

-- Season lock -> month mapping (representative month for probability tables)
-- Used when player locks weather to a specific season in settings
local SEASON_LOCK_MONTH = {
  spring = 4,   -- April probabilities
  summer = 7,   -- July probabilities
  autumn = 10,  -- October probabilities
  winter = 1    -- January probabilities
}

-- Temperature ranges by season (Celsius)
local TEMP_RANGES = {
  spring = {low = 8, high = 22},
  summer = {low = 18, high = 35},
  autumn = {low = 5, high = 18},
  winter = {low = -5, high = 8}
}

-- ============================================================================
-- Private state
-- ============================================================================
local weatherState = {
  currentState = "sunny",
  previousState = nil,
  transitioning = false,
  transitionProgress = 0,
  startValues = {},
  goalValues = {},
  timeInCurrentState = 0,
  scheduledDuration = 0,
  windDirection = 0,           -- Radians
  temperature = 20,            -- Current temperature (Celsius)
  season = "spring",
  month = 1,
  weatherEnabled = true,       -- When false, forces sunny and stops all transitions
  seasonLock = "auto",         -- "auto" or "spring"/"summer"/"autumn"/"winter"
}

local activated = false
local activatedTime = nil
local rainObject = nil
local fogObject = nil
local cloudsObject = nil
local windObject = nil
local sunskyObject = nil
local rainSoundEmitter = nil
local weatherObjectsInitialized = false

-- Plan 03: Physics integration constants
local RAIN_THRESHOLD_DRY_TO_WET = 400       -- numDrops threshold for wet groundmodel
local RAIN_THRESHOLD_WET_TO_STORM = 1500     -- numDrops threshold for storm groundmodel
local MIN_GROUNDMODEL_CHANGE_INTERVAL = 60   -- seconds (debounce)
local GROUNDMODEL_CHECK_INTERVAL = 1.0       -- seconds between groundmodel checks

-- Groundmodel name map: gmType -> target vanilla name for asphalt materials
-- Uses vanilla BeamNG groundmodel names (no custom JSON needed)
local gmTargetName = {
  dry   = "ASPHALT",
  wet   = "ASPHALT_WET",
  storm = "ASPHALT_WET",
  snow     = "ASPHALT_WET",  -- ASPHALT_WET not ICE (ICE makes parked cars slide downhill)
  blizzard = "ICE"          -- Full chaos: ICE groundmodel
}

-- Vanilla asphalt-family names to match when scanning terrain materials
local ASPHALT_NAMES = {
  GROUNDMODEL_ASPHALT1 = true,
  ASPHALT = true,
  ASPHALT_OLD = true,
  GROUNDMODEL_ASPHALT_OLD = true,
  CONCRETE = true,
  CONCRETE2 = true,
  ASPHALT_WET = true,
  ASPHALT_WET2 = true,
  ASPHALT_WET3 = true,
  ICE = true,
  ASPHALT_ICY = true,
}

-- Wind force base values by weather state (Newtons)
local WIND_FORCE_BASE = {
  sunny = 0,
  overcast = 0,
  drizzle = 300,
  storm = 1000,
  snow = 400,
  blizzard = 1200
}

-- AI traffic speed multipliers by weather state
local TRAFFIC_SPEED_MULT = {
  sunny = 1.0,
  overcast = 1.0,
  drizzle = 0.8,
  storm = 0.6,
  snow = 0.65,
  blizzard = 0.4
}

-- Thunder/lightning timing
local THUNDER_MIN_INTERVAL = 40   -- seconds (minimum between strikes)
local THUNDER_MAX_INTERVAL = 120  -- seconds (maximum between strikes)
local LIGHTNING_FLASH_DURATION = 0.08  -- seconds (very brief flash)

-- Physics integration state
local currentGroundmodel = "dry"
local lastGroundmodelChangeTime = 0
local groundmodelCheckAccum = 0
local thunderTimer = 0
local thunderNextInterval = 30
local lightningFlashTimer = 0
local lightningActive = false
local originalSunskyBrightness = nil
local trafficSpeedSet = false
local currentRainDrops = 0  -- Tracks interpolated rain for groundmodel decisions
local baseSkyBrightness = nil  -- Original sunsky brightness (stored on first activation)

-- Demo state (for demoAllStates command)
local demoActive = false
local demoQueue = {}
local demoTimer = 0
local demoInterval = 0
local demoOrigTransition = 0

-- ============================================================================
-- Utility functions
-- ============================================================================

-- Ease-in-out quadratic interpolation
easeInOutQuad = function(t)
  if t < 0.5 then
    return 2 * t * t
  else
    return 1 - math.pow(-2 * t + 2, 2) / 2
  end
end

-- Linear interpolation
lerpValue = function(a, b, t)
  return a + (b - a) * t
end

-- Get seasonal probabilities for a given month
getSeasonalProbabilities = function(month)
  return SEASONAL_PROBABILITIES[month] or SEASONAL_PROBABILITIES[1]
end

-- Select a weather state from probability table using weighted random
selectWeatherFromSeason = function(month, excludeState)
  local probs = getSeasonalProbabilities(month)

  -- Build cumulative distribution, optionally excluding a state
  local cumulative = {}
  local total = 0
  for _, state in ipairs(STATES) do
    local weight = probs[state] or 0
    if excludeState and state == excludeState then
      weight = 0
    end
    total = total + weight
    table.insert(cumulative, {state = state, threshold = total})
  end

  if total <= 0 then return "sunny" end

  local roll = math.random() * total
  for _, entry in ipairs(cumulative) do
    if roll <= entry.threshold then
      return entry.state
    end
  end

  return "sunny"  -- Fallback
end

-- Check if a weather state uses snow particles (snow or blizzard)
local function isSnowState(state)
  return state == "snow" or state == "blizzard"
end

-- Generate temperature for current season with random variation
local function generateTemperature(season, state)
  local range = TEMP_RANGES[season] or TEMP_RANGES.spring
  local base = lerpValue(range.low, range.high, math.random())
  -- Weather modifiers
  if state == "storm" then base = base - 3 end
  if isSnowState(state) then base = math.min(base, 2) end
  if state == "sunny" then base = base + 2 end
  -- Add small variation
  base = base + (math.random() - 0.5) * 3
  return math.floor(base * 10) / 10  -- 1 decimal place
end

-- ============================================================================
-- Scenetree object management
-- ============================================================================

-- Initialize weather-related scenetree objects
-- Following MK's Dynamic Weather pattern: createObject + registerObject + findSubClassObjects
initWeatherObjects = function()
  if weatherObjectsInitialized then return end

  -- Find fog via theLevelInfo (confirmed: MK's mod uses this for fog properties)
  fogObject = scenetree.findObject("theLevelInfo")
  if fogObject then
    log('I', logTag, 'Found fog object: theLevelInfo')
  else
    log('W', logTag, 'theLevelInfo not found — fog effects disabled')
  end

  -- Find sunsky for lightning flash and brightness control
  sunskyObject = scenetree.findObject("sunsky") or scenetree.findObject("theSun")
  if sunskyObject then
    -- Store original brightness to use as base for weather dimming
    if not baseSkyBrightness then
      baseSkyBrightness = sunskyObject.brightness or 1.0
    end
    log('I', logTag, 'Found sunsky object (base brightness: ' .. tostring(baseSkyBrightness) .. ')')
  end

  -- Find clouds via findSubClassObjects (MK pattern: finds first visible CloudLayer)
  local cloudObjs = scenetree.findSubClassObjects('CloudLayer')
  if cloudObjs and #cloudObjs > 0 then
    for i, v in ipairs(cloudObjs) do
      local obj = scenetree.findObject(cloudObjs[i])
      if obj and not obj.hidden then
        cloudsObject = obj
        log('I', logTag, 'Found cloud layer: ' .. tostring(cloudObjs[i]))
        break
      end
    end
    -- If all hidden, use the first one
    if not cloudsObject and #cloudObjs > 0 then
      cloudsObject = scenetree.findObject(cloudObjs[1])
      if cloudsObject then
        cloudsObject.hidden = false
        log('I', logTag, 'Using first cloud layer (was hidden): ' .. tostring(cloudObjs[1]))
      end
    end
  end
  if not cloudsObject then
    log('W', logTag, 'No CloudLayer found — cloud effects disabled')
  end

  -- Find ForestWind
  local windObjs = scenetree.findSubClassObjects('ForestWind')
  if windObjs and #windObjs > 0 then
    windObject = scenetree.findObject(windObjs[1])
    if windObject then
      log('I', logTag, 'Found ForestWind: ' .. tostring(windObjs[1]))
    end
  end
  if not windObject then
    log('D', logTag, 'No ForestWind found — wind visual effects disabled')
  end

  -- Delete any existing BCM rain/sound objects from previous session
  local existingRain = scenetree.findObject("rain_bcm")
  if existingRain then
    pcall(function() existingRain:delete() end)
  end
  local existingSound = scenetree.findObject("rain_sound_bcm")
  if existingSound then
    pcall(function() existingSound:delete() end)
  end

  -- Create rain precipitation object (MK pattern: createObject + registerObject)
  local ok, err = pcall(function()
    local rain = createObject("Precipitation")
    rain.dataBlock = scenetree.findObject("rain_medium")
    rain.numDrops = 0
    rain.splashSize = 0
    rain.splashMS = 0
    rain.animateSplashes = 0
    rain.boxWidth = 16.0
    rain.boxHeight = 16.0
    rain.dropSize = 1.0
    rain.doCollision = true
    rain.hitVehicles = true
    rain.rotateWithCamVel = false
    rain.followCam = true
    rain.useWind = true
    rain.minSpeed = 0.3
    rain.maxSpeed = 0.6
    rain.minMass = 4
    rain.maxMass = 5
    rain:registerObject('rain_bcm')
    rainObject = rain
  end)
  if ok and rainObject then
    log('I', logTag, 'Created rain precipitation object')
  else
    log('W', logTag, 'Failed to create rain object: ' .. tostring(err))
  end

  -- Create SFXEmitter for rain sound (MK pattern)
  local ok2, err2 = pcall(function()
    local sound = createObject("SFXEmitter")
    sound.scale = Point3F(100, 100, 100)
    sound.fileName = String('/art/sound/environment/amb_rain_medium.ogg')
    sound.playOnAdd = true
    sound.isLooping = true
    sound.volume = 0.0
    sound.isStreaming = true
    sound.is3D = false
    sound:registerObject('rain_sound_bcm')
    rainSoundEmitter = sound
  end)
  if ok2 and rainSoundEmitter then
    log('I', logTag, 'Created rain sound emitter')
  else
    log('D', logTag, 'Rain sound emitter skipped: ' .. tostring(err2))
  end

  weatherObjectsInitialized = true
  log('I', logTag, 'Weather objects initialized — clouds:' .. tostring(cloudsObject ~= nil) .. ' fog:' .. tostring(fogObject ~= nil) .. ' rain:' .. tostring(rainObject ~= nil) .. ' wind:' .. tostring(windObject ~= nil))
end

-- Cleanup weather objects when career deactivates
cleanupWeatherObjects = function()
  -- Reset fog to clear
  if fogObject then
    pcall(function()
      fogObject.fogDensity = 0.0001
      postApplyObj(fogObject)
    end)
  end

  -- Reset clouds to light coverage
  if cloudsObject then
    pcall(function()
      cloudsObject.coverage = 0.2
      postApplyObj(cloudsObject)
    end)
  end

  -- Restore original sky brightness
  if sunskyObject and baseSkyBrightness then
    pcall(function()
      sunskyObject.brightness = baseSkyBrightness
    end)
  end

  -- Delete BCM-created objects (rain + sound emitter)
  if rainObject then
    pcall(function() rainObject:delete() end)
  end
  if rainSoundEmitter then
    pcall(function() rainSoundEmitter:delete() end)
  end

  weatherObjectsInitialized = false
  rainObject = nil
  fogObject = nil
  cloudsObject = nil
  windObject = nil
  sunskyObject = nil
  rainSoundEmitter = nil

  log('I', logTag, 'Weather objects cleaned up')
end

-- ============================================================================
-- Scenetree property control
-- ============================================================================

-- Get current scenetree values as a table
getScenetreeTargets = function()
  local values = {
    cloudsCoverage = 0.2,
    fogDensity = 0.0001,
    rainNumDrops = 0,
    windStrength = 0.1,
    rainDropSize = 1.0,
    rainSoundVolume = 0,
    skyBrightness = 1.0
  }

  if cloudsObject then
    pcall(function() values.cloudsCoverage = cloudsObject.coverage or 0.2 end)
  end
  if fogObject then
    pcall(function() values.fogDensity = fogObject.fogDensity or 0.0001 end)
  end
  if rainObject then
    pcall(function() values.rainNumDrops = rainObject.numDrops or 0 end)
    pcall(function() values.rainDropSize = rainObject.dropSize or 1.0 end)
  end
  if windObject then
    pcall(function() values.windStrength = windObject.strength or 0.1 end)
  end
  if rainSoundEmitter then
    pcall(function() values.rainSoundVolume = rainSoundEmitter.volume or 0 end)
  end
  if sunskyObject and baseSkyBrightness then
    pcall(function() values.skyBrightness = sunskyObject.brightness / baseSkyBrightness end)
  end

  return values
end

-- Helper: call postApply on a scenetree object (required for BeamNG to apply property changes)
local function postApplyObj(obj)
  pcall(function()
    scenetree.findObjectById(obj:getId()):postApply()
  end)
end

-- Apply values to scenetree objects
-- commitMode: if true, calls postApply() to commit changes (use for instant/final only)
--             if false/nil, just sets properties (use for per-frame interpolation)
applyScenetreeValues = function(values, commitMode)
  if cloudsObject then
    pcall(function() cloudsObject.coverage = values.cloudsCoverage end)
    if commitMode then postApplyObj(cloudsObject) end
  end
  if fogObject then
    pcall(function() fogObject.fogDensity = values.fogDensity end)
    if commitMode then postApplyObj(fogObject) end
  end
  if rainObject then
    pcall(function() rainObject.numDrops = math.floor(values.rainNumDrops) end)
    pcall(function() rainObject.dropSize = values.rainDropSize end)
    if commitMode then postApplyObj(rainObject) end
  end
  -- Track interpolated rain for groundmodel decisions
  currentRainDrops = values.rainNumDrops or 0
  if windObject then
    pcall(function() windObject.strength = values.windStrength end)
    if commitMode then postApplyObj(windObject) end
  end
  if rainSoundEmitter then
    pcall(function() rainSoundEmitter.volume = values.rainSoundVolume end)
    if commitMode then postApplyObj(rainSoundEmitter) end
  end
  -- Apply sky brightness (dimming for storms/overcast)
  if sunskyObject and baseSkyBrightness and values.skyBrightness then
    -- Don't touch brightness if lightning is active (lightning controls it temporarily)
    if not lightningActive then
      pcall(function()
        sunskyObject.brightness = baseSkyBrightness * values.skyBrightness
      end)
    end
  end
end

-- Switch rain dataBlock between rain and snow
switchRainDataBlock = function(isSnow)
  if not rainObject then return end

  pcall(function()
    if isSnow then
      local snowDb = scenetree.findObject("Snow_menu")
      if snowDb then
        rainObject.dataBlock = snowDb
        log('D', logTag, 'Switched to snow dataBlock')
      end
    else
      local rainDb = scenetree.findObject("rain_medium")
      if rainDb then
        rainObject.dataBlock = rainDb
        log('D', logTag, 'Switched to rain dataBlock')
      end
    end
  end)
  postApplyObj(rainObject)
end

-- Update rain sound volume proportional to numDrops
updateRainSound = function(numDrops, isSnow)
  if not rainSoundEmitter then return end

  if isSnow then
    pcall(function() rainSoundEmitter.volume = 0 end)
    return
  end

  -- Scale volume: 0 drops = 0 volume, 2500 drops = 0.7 volume
  local vol = math.min(0.7, (numDrops / 2500) * 0.7)
  pcall(function() rainSoundEmitter.volume = vol end)
end

-- ============================================================================
-- Weather transition system
-- ============================================================================

-- Start a transition to a new weather state
startTransition = function(newState)
  if weatherState.transitioning then
    -- If already transitioning, snap to current goal and start new transition
    applyScenetreeValues(weatherState.goalValues, true)
  end

  local profile = WEATHER_PROFILES[newState]
  if not profile then
    log('W', logTag, 'Unknown weather state: ' .. tostring(newState))
    return
  end

  -- Switch rain/snow dataBlock before transition
  local wasSnow = isSnowState(weatherState.currentState)
  local nowSnow = isSnowState(newState)
  if wasSnow ~= nowSnow then
    switchRainDataBlock(nowSnow)
  end

  weatherState.previousState = weatherState.currentState
  weatherState.currentState = newState
  weatherState.transitioning = true
  weatherState.transitionProgress = 0
  weatherState.startValues = getScenetreeTargets()
  weatherState.goalValues = {
    cloudsCoverage = profile.cloudsCoverage,
    fogDensity = profile.fogDensity,
    rainNumDrops = profile.rainNumDrops,
    windStrength = profile.windStrength,
    rainDropSize = profile.rainDropSize,
    rainSoundVolume = profile.rainSoundVolume,
    skyBrightness = profile.skyBrightness or 1.0
  }

  -- Generate new wind direction on weather change
  weatherState.windDirection = math.random() * math.pi * 2

  -- Generate temperature
  weatherState.temperature = generateTemperature(weatherState.season, newState)

  log('I', logTag, 'Starting transition: ' .. tostring(weatherState.previousState) .. ' -> ' .. newState .. ' (duration: ' .. TRANSITION_DURATION .. 's)')
end

-- Update transition progress (called every frame)
updateTransition = function(dtReal)
  if not weatherState.transitioning then return end

  weatherState.transitionProgress = weatherState.transitionProgress + (dtReal / TRANSITION_DURATION)

  if weatherState.transitionProgress >= 1 then
    -- Transition complete
    weatherState.transitionProgress = 1
    weatherState.transitioning = false
    applyScenetreeValues(weatherState.goalValues, true)
    updateRainSound(weatherState.goalValues.rainNumDrops, isSnowState(weatherState.currentState))

    -- Broadcast state change (only after transition completes)
    broadcastWeatherUpdate()

    -- Schedule next weather change
    scheduleNextWeatherChange()

    log('I', logTag, 'Transition complete: now ' .. weatherState.currentState)
    return
  end

  -- Interpolate all values using ease-in-out
  local t = easeInOutQuad(weatherState.transitionProgress)

  -- Staggered rain: rain/sound start later than clouds/fog/brightness
  -- If t < RAIN_DELAY_FACTOR, rain progress = 0. Then it catches up from delay to 1.0
  local tRain = 0
  if weatherState.transitionProgress > RAIN_DELAY_FACTOR then
    tRain = easeInOutQuad((weatherState.transitionProgress - RAIN_DELAY_FACTOR) / (1 - RAIN_DELAY_FACTOR))
  end

  local interpolated = {}
  for key, startVal in pairs(weatherState.startValues) do
    local goalVal = weatherState.goalValues[key] or startVal
    -- Rain and sound use delayed progress, everything else uses normal progress
    if key == "rainNumDrops" or key == "rainDropSize" or key == "rainSoundVolume" then
      interpolated[key] = lerpValue(startVal, goalVal, tRain)
    else
      interpolated[key] = lerpValue(startVal, goalVal, t)
    end
  end

  applyScenetreeValues(interpolated)
  updateRainSound(interpolated.rainNumDrops, isSnowState(weatherState.currentState))
end

-- Schedule when next weather change should occur
scheduleNextWeatherChange = function()
  local dur = STATE_DURATION[weatherState.currentState] or {min = 600, max = 1200}
  weatherState.scheduledDuration = dur.min + math.random() * (dur.max - dur.min)
  weatherState.timeInCurrentState = 0

  log('D', logTag, 'Next weather change in ' .. string.format("%.0f", weatherState.scheduledDuration) .. 's (' .. weatherState.currentState .. ')')
end

-- ============================================================================
-- Weather selection and application
-- ============================================================================

-- Select next weather state following natural progression chains
-- Uses chain transitions weighted by seasonal probabilities
local function selectNextWeather(currentState, month)
  local candidates = WEATHER_CHAINS[currentState]
  if not candidates or #candidates == 0 then
    return "sunny" -- fallback
  end

  -- If only one option, return it directly
  if #candidates == 1 then
    return candidates[1]
  end

  -- Weight candidates by seasonal probabilities
  local probs = getSeasonalProbabilities(month)
  local cumulative = {}
  local total = 0
  for _, state in ipairs(candidates) do
    local weight = probs[state] or 0
    -- Give minimum weight of 1 so every chain option has a chance
    weight = math.max(weight, 1)
    total = total + weight
    table.insert(cumulative, {state = state, threshold = total})
  end

  local roll = math.random() * total
  for _, entry in ipairs(cumulative) do
    if roll <= entry.threshold then
      return entry.state
    end
  end

  return candidates[1]
end

-- Select and instantly apply weather (no transition, used on initial load)
selectAndApplyWeather = function()
  -- Get current month from time system
  local dateInfo = nil
  if extensions.bcm_timeSystem then
    dateInfo = extensions.bcm_timeSystem.getDateInfo()
  end

  -- Guard: if timeSystem hasn't loaded yet (gameTimeDays still 0 → Jan 1),
  -- fall back to OS date so weather matches the real calendar date
  if dateInfo and dateInfo.totalGameDays == 0 then
    local ok, now = pcall(os.date, "*t")
    if ok and type(now) == "table" then
      dateInfo = {month = now.month, season = nil}
      if now.month >= 3 and now.month <= 5 then dateInfo.season = "spring"
      elseif now.month >= 6 and now.month <= 8 then dateInfo.season = "summer"
      elseif now.month >= 9 and now.month <= 11 then dateInfo.season = "autumn"
      else dateInfo.season = "winter" end
      log('I', logTag, 'TimeSystem not ready, using OS date for weather (month: ' .. now.month .. ')')
    else
      dateInfo = nil
    end
  end

  if dateInfo then
    weatherState.month = dateInfo.month
    weatherState.season = dateInfo.season
  else
    -- Ultimate fallback: May (spring)
    weatherState.month = 5
    weatherState.season = "spring"
  end

  -- Apply season lock override (settings: lock to specific season)
  if weatherState.seasonLock ~= "auto" then
    local lockMonth = SEASON_LOCK_MONTH[weatherState.seasonLock]
    if lockMonth then
      weatherState.month = lockMonth
      weatherState.season = weatherState.seasonLock
    end
  end

  -- If weather is disabled, force sunny and skip all transitions
  if not weatherState.weatherEnabled then
    weatherState.currentState = "sunny"
    weatherState.previousState = nil
    weatherState.transitioning = false
    weatherState.transitionProgress = 0
    local profile = WEATHER_PROFILES["sunny"]
    if profile then
      applyScenetreeValues(profile, true)
      updateRainSound(0, false)
    end
    weatherState.scheduledDuration = 999999  -- Never auto-change while disabled
    weatherState.timeInCurrentState = 0
    broadcastWeatherUpdate()
    log('I', logTag, 'Weather disabled — forced sunny')
    return
  end

  -- Select weather from seasonal probabilities
  local selectedState = selectWeatherFromSeason(weatherState.month)
  weatherState.currentState = selectedState
  weatherState.previousState = nil
  weatherState.transitioning = false
  weatherState.transitionProgress = 0

  -- Generate wind direction and temperature
  weatherState.windDirection = math.random() * math.pi * 2
  weatherState.temperature = generateTemperature(weatherState.season, selectedState)

  -- Switch rain/snow dataBlock
  switchRainDataBlock(isSnowState(selectedState))

  -- Instantly apply scenetree values (no transition on first load)
  local profile = WEATHER_PROFILES[selectedState]
  if profile then
    applyScenetreeValues(profile, true)
    updateRainSound(profile.rainNumDrops, isSnowState(selectedState))
  end

  -- Schedule first weather change
  scheduleNextWeatherChange()

  -- Broadcast initial state
  broadcastWeatherUpdate()

  log('I', logTag, 'Initial weather: ' .. selectedState .. ' (month: ' .. weatherState.month .. ', season: ' .. weatherState.season .. ')')
end

-- ============================================================================
-- Guihook broadcast
-- ============================================================================

-- Broadcast weather update to Vue components
broadcastWeatherUpdate = function()
  local info = {
    state = weatherState.currentState,
    season = weatherState.season,
    month = weatherState.month,
    windSpeed = WEATHER_PROFILES[weatherState.currentState] and WEATHER_PROFILES[weatherState.currentState].windStrength or 0,
    rainIntensity = WEATHER_PROFILES[weatherState.currentState] and WEATHER_PROFILES[weatherState.currentState].rainNumDrops or 0,
    temperature = weatherState.temperature,
    transitioning = weatherState.transitioning
  }

  guihooks.trigger('BCMWeatherUpdate', info)
end

-- ============================================================================
-- Physics integration (Plan 03)
-- ============================================================================

-- Determine target groundmodel based on interpolated rain intensity
-- This makes grip change gradually during transitions, not instantly
updateGroundmodel = function(dtReal)
  groundmodelCheckAccum = groundmodelCheckAccum + dtReal
  if groundmodelCheckAccum < GROUNDMODEL_CHECK_INTERVAL then return end
  groundmodelCheckAccum = 0

  -- Safety: don't switch groundmodels too soon after career load
  if activatedTime and (os.clock() - activatedTime) < 15 then return end

  local now = os.clock()
  if (now - lastGroundmodelChangeTime) < MIN_GROUNDMODEL_CHANGE_INTERVAL then return end

  local target = "dry"
  if isSnowState(weatherState.currentState) then
    -- Snow/blizzard: use ICE only for blizzard, wet for normal snow
    if weatherState.currentState == "blizzard" then
      target = "blizzard"
    else
      target = "snow"
    end
  else
    -- Rain-based: use interpolated numDrops for gradual grip change
    if currentRainDrops >= RAIN_THRESHOLD_WET_TO_STORM then
      target = "storm"
    elseif currentRainDrops >= RAIN_THRESHOLD_DRY_TO_WET then
      target = "wet"
    end
  end

  if target ~= currentGroundmodel then
    applyGroundmodel(target)
  end
end

-- Apply a specific groundmodel to all terrain materials (MK Dynamic Weather pattern)
-- Uses vanilla BeamNG groundmodel names — no custom JSON file needed
applyGroundmodel = function(gmType)
  local targetName = gmTargetName[gmType]
  if not targetName then return end

  local terrain = scenetree.findObject("theTerrain")
  if not terrain then
    log('D', logTag, 'No terrain found, skipping groundmodel switch')
    return
  end

  local ok, err = pcall(function()
    local matCount = terrain:getMaterialCount()
    local changed = false
    for i = 0, matCount - 1 do
      local mtl = terrain:getMaterial(i)
      if mtl then
        local gmName = mtl.groundmodelName or ""
        -- Only change materials that are in the asphalt family
        if ASPHALT_NAMES[gmName] then
          if gmName ~= targetName then
            mtl.groundmodelName = targetName
            changed = true
          end
        end
      end
    end

    if changed then
      be:reloadCollision()
    end
  end)

  if ok then
    currentGroundmodel = gmType
    lastGroundmodelChangeTime = os.clock()
    log('I', logTag, 'Groundmodel switched to: ' .. gmType .. ' (' .. targetName .. ')')
  else
    log('W', logTag, 'Groundmodel switch failed: ' .. tostring(err))
  end
end

-- Apply wind force to player vehicle (proportional to speed)
-- NOTE: Disabled - applyClusterVelocityScaleAdd crashes the BeamNG engine (C++ access violation).
-- Wind force requires a different approach (e.g., vehicle-side Lua extension or input perturbation).
updateWindEffect = function(dtReal)
  -- DISABLED: causes C++ crash via queueLuaCommand('obj:applyClusterVelocityScaleAdd')
  -- TODO: investigate safe wind force API in future phase
end

-- Thunder and lightning effects during storms
updateThunderLightning = function(dtReal)
  if not sunskyObject then return end

  -- Only during storms
  if weatherState.currentState ~= "storm" then
    -- Reset lightning if active
    if lightningActive and originalSunskyBrightness then
      pcall(function()
        sunskyObject.brightness = originalSunskyBrightness
        postApplyObj(sunskyObject)
      end)
      lightningActive = false
      originalSunskyBrightness = nil
    end
    return
  end

  -- Handle active lightning flash fade
  if lightningActive then
    lightningFlashTimer = lightningFlashTimer - dtReal
    if lightningFlashTimer <= 0 then
      -- Restore original brightness
      pcall(function()
        sunskyObject.brightness = originalSunskyBrightness
        postApplyObj(sunskyObject)
      end)
      lightningActive = false

      -- Note: BeamNG has no built-in thunder sound asset
      -- Thunder audio would require shipping a custom .ogg file
    end
    return
  end

  -- Countdown to next lightning strike
  thunderTimer = thunderTimer + dtReal
  if thunderTimer >= thunderNextInterval then
    thunderTimer = 0
    thunderNextInterval = THUNDER_MIN_INTERVAL + math.random() * (THUNDER_MAX_INTERVAL - THUNDER_MIN_INTERVAL)

    -- Lightning flash: subtle brightness bump (not epileptic)
    pcall(function()
      originalSunskyBrightness = sunskyObject.brightness
      sunskyObject.brightness = originalSunskyBrightness + 0.6
      postApplyObj(sunskyObject)
      lightningActive = true
      lightningFlashTimer = LIGHTNING_FLASH_DURATION
      log('D', logTag, 'Lightning flash')
    end)
  end
end

-- Adjust AI traffic speed based on weather
updateTrafficSpeed = function()
  local mult = TRAFFIC_SPEED_MULT[weatherState.currentState] or 1.0

  -- Try gameplay_traffic API
  local ok = pcall(function()
    if gameplay_traffic and gameplay_traffic.setSpeedMultiplier then
      gameplay_traffic.setSpeedMultiplier(mult)
      trafficSpeedSet = true
    end
  end)

  if not ok then
    -- Try alternative traffic API
    pcall(function()
      if traffic and traffic.setSpeedMultiplier then
        traffic.setSpeedMultiplier(mult)
        trafficSpeedSet = true
      end
    end)
  end
end

-- Reset traffic speed to normal
local function resetTrafficSpeed()
  if not trafficSpeedSet then return end
  pcall(function()
    if gameplay_traffic and gameplay_traffic.setSpeedMultiplier then
      gameplay_traffic.setSpeedMultiplier(1.0)
    elseif traffic and traffic.setSpeedMultiplier then
      traffic.setSpeedMultiplier(1.0)
    end
  end)
  trafficSpeedSet = false
end

-- ============================================================================
-- Update loop
-- ============================================================================

-- Called every frame when career is active
onUpdate = function(dtReal, dtSim, dtRaw)
  if not activated then return end

  -- Weather disabled: maintain sunny state, skip all weather processing
  if not weatherState.weatherEnabled then return end

  -- Demo mode: advance through queued states on timer
  if demoActive then
    demoTimer = demoTimer + dtReal
    if demoTimer >= demoInterval and #demoQueue > 0 then
      demoTimer = 0
      local nextState = table.remove(demoQueue, 1)
      startTransition(nextState)
      broadcastWeatherUpdate()
      updateTrafficSpeed()
      log('I', logTag, 'Demo: transitioning to ' .. nextState .. ' (' .. #demoQueue .. ' remaining)')
      if #demoQueue == 0 then
        demoActive = false
        TRANSITION_DURATION = demoOrigTransition
        log('I', logTag, 'Demo complete — restored normal settings')
      end
    end
  end

  -- Update transition interpolation
  updateTransition(dtReal)

  -- Physics effects (every frame for smooth wind, timer-based for others)
  updateGroundmodel(dtReal)
  updateWindEffect(dtReal)
  updateThunderLightning(dtReal)

  -- Track time in current state (only when not transitioning, skip during demo)
  if not weatherState.transitioning and not demoActive then
    weatherState.timeInCurrentState = weatherState.timeInCurrentState + dtReal

    -- Check if it's time for a weather change
    if weatherState.timeInCurrentState >= weatherState.scheduledDuration then
      -- Update season info from time system
      local dateInfo = nil
      if extensions.bcm_timeSystem then
        dateInfo = extensions.bcm_timeSystem.getDateInfo()
      end
      if dateInfo then
        weatherState.month = dateInfo.month
        weatherState.season = dateInfo.season
      end

      -- Apply season lock override to month used for weather selection
      if weatherState.seasonLock ~= "auto" then
        local lockMonth = SEASON_LOCK_MONTH[weatherState.seasonLock]
        if lockMonth then
          weatherState.month = lockMonth
          weatherState.season = weatherState.seasonLock
        end
      end

      -- Select next weather following natural progression chain
      local newState = selectNextWeather(weatherState.currentState, weatherState.month)
      startTransition(newState)

      -- Update traffic speed on weather change
      updateTrafficSpeed()
    end
  end
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

-- Called when career becomes active/inactive
onCareerActive = function(active)
  if active then
    activated = true
    activatedTime = os.clock()
    -- Seed random for weather variety
    math.randomseed(os.clock() * 1000 + os.time())
    -- Initialize scenetree objects
    initWeatherObjects()
    -- Select seasonal context (month/season), then force sunny start instantly
    selectAndApplyWeather()
    if weatherState.currentState ~= "sunny" then
      -- Snap to sunny immediately (no 180s transition)
      local sunnyProfile = WEATHER_PROFILES["sunny"]
      if sunnyProfile then
        weatherState.previousState = weatherState.currentState
        weatherState.currentState = "sunny"
        weatherState.transitioning = false
        weatherState.transitionProgress = 0
        switchRainDataBlock(false)
        applyScenetreeValues(sunnyProfile, true)
        updateRainSound(0, false)
        weatherState.temperature = generateTemperature(weatherState.season, "sunny")
        broadcastWeatherUpdate()
        -- Keep existing scheduledDuration — next change uses seasonal flow
      end
      log('I', logTag, 'Forced sunny start — seasonal cycle will take over')
    end
    -- Set initial traffic speed
    updateTrafficSpeed()
    log('I', logTag, 'Weather system activated')
  else
    activated = false
    activatedTime = nil
    -- Reset groundmodel to dry when leaving career
    if currentGroundmodel ~= "dry" then
      pcall(function() applyGroundmodel("dry") end)
    end
    -- Reset traffic speed
    resetTrafficSpeed()
    -- Reset lightning state
    if lightningActive and originalSunskyBrightness and sunskyObject then
      pcall(function()
        sunskyObject.brightness = originalSunskyBrightness
        postApplyObj(sunskyObject)
      end)
      lightningActive = false
      originalSunskyBrightness = nil
    end
    cleanupWeatherObjects()
    log('I', logTag, 'Weather system deactivated')
  end
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Get current weather state string
M.getCurrentState = function()
  return weatherState.currentState
end

-- Get full weather info table
M.getWeatherInfo = function()
  return {
    state = weatherState.currentState,
    transitioning = weatherState.transitioning,
    transitionProgress = weatherState.transitionProgress,
    season = weatherState.season,
    month = weatherState.month,
    windSpeed = WEATHER_PROFILES[weatherState.currentState] and WEATHER_PROFILES[weatherState.currentState].windStrength or 0,
    rainIntensity = WEATHER_PROFILES[weatherState.currentState] and WEATHER_PROFILES[weatherState.currentState].rainNumDrops or 0,
    temperature = weatherState.temperature,
    windDirection = weatherState.windDirection,
    timeInState = weatherState.timeInCurrentState,
    scheduledDuration = weatherState.scheduledDuration
  }
end

-- Get seasonal probability table for a given month (used by weatherForecast.lua)
M.getSeasonalProbabilities = getSeasonalProbabilities

-- Get the STATES list (used by weatherForecast.lua)
M.getStates = function()
  return STATES
end

-- Get current groundmodel state (for console testing)
M.getGroundmodelState = function()
  return currentGroundmodel
end

-- Ensure weather system is ready (for debug commands after reload)
local function ensureActive()
  if not activated then
    activated = true
    activatedTime = os.clock()
    math.randomseed(os.clock() * 1000 + os.time())
    initWeatherObjects()
    log('I', logTag, 'Debug: auto-activated weather system')
  end
end

-- Debug: force weather state transition (for console testing)
M.forceWeather = function(stateName)
  if not WEATHER_PROFILES[stateName] then
    log('W', logTag, 'Invalid state: ' .. tostring(stateName) .. '. Valid: sunny, overcast, drizzle, storm, snow, blizzard')
    return false
  end
  ensureActive()
  log('I', logTag, 'Forcing weather to: ' .. stateName)
  startTransition(stateName)
  scheduleNextWeatherChange()
  return true
end

-- Debug: instant weather (no transition, for quick testing)
M.setWeatherInstant = function(stateName)
  if not WEATHER_PROFILES[stateName] then
    log('W', logTag, 'Invalid state: ' .. tostring(stateName) .. '. Valid: sunny, overcast, drizzle, storm, snow, blizzard')
    return false
  end
  ensureActive()
  log('I', logTag, 'Setting weather instantly to: ' .. stateName)
  local wasSnow = isSnowState(weatherState.currentState)
  local nowSnow = isSnowState(stateName)
  if wasSnow ~= nowSnow then
    switchRainDataBlock(nowSnow)
  end
  weatherState.currentState = stateName
  weatherState.transitioning = false
  weatherState.transitionProgress = 0
  applyScenetreeValues(WEATHER_PROFILES[stateName], true)
  scheduleNextWeatherChange()
  broadcastWeatherUpdate()
  return true
end

-- Debug: cycle through all states with smooth transitions (total ~5 min)
-- Each state: ~15s hold + ~15s transition to next = ~30s per step
-- Usage: bcm_weather.demoAllStates()
M.demoAllStates = function()
  local states = {"sunny", "overcast", "drizzle", "storm", "drizzle", "overcast", "snow", "blizzard", "snow", "overcast", "sunny"}

  demoInterval = 15   -- seconds between transitions (hold time)
  demoOrigTransition = TRANSITION_DURATION
  TRANSITION_DURATION = 15  -- fast transitions for demo

  -- Build queue (skip first, it's applied instantly)
  demoQueue = {}
  for i = 2, #states do
    table.insert(demoQueue, states[i])
  end

  ensureActive()

  -- Apply first state instantly (without scheduleNextWeatherChange)
  local firstState = states[1]
  switchRainDataBlock(isSnowState(firstState))
  weatherState.currentState = firstState
  weatherState.transitioning = false
  weatherState.transitionProgress = 0
  applyScenetreeValues(WEATHER_PROFILES[firstState], true)
  broadcastWeatherUpdate()

  demoTimer = 0
  demoActive = true

  local route = table.concat(states, " -> ")
  log('I', logTag, 'Demo started (' .. (#states * demoInterval) .. 's): ' .. route)
  return "Demo: " .. route
end

-- Stop demo and restore normal settings
M.demoStop = function()
  if not demoActive then return "No demo running" end
  demoActive = false
  demoQueue = {}
  TRANSITION_DURATION = demoOrigTransition
  log('I', logTag, 'Demo stopped')
  return "Demo stopped"
end

-- Debug: force next chain step (simulates natural progression)
-- Usage: bcm_weather.nextWeather()
M.nextWeather = function()
  ensureActive()
  local current = weatherState.currentState
  local next = selectNextWeather(current, weatherState.month)
  log('I', logTag, 'Forcing next chain step: ' .. current .. ' -> ' .. next)
  startTransition(next)
  broadcastWeatherUpdate()
  return current .. " -> " .. next
end

-- ============================================================================
-- Settings API (Plan 01: Options Menu backend)
-- ============================================================================

-- Enable or disable the weather system
-- When disabled: immediately forces sunny, stops all transitions and state changes
-- When re-enabled: selects fresh weather based on current season
setWeatherEnabled = function(enabled)
  weatherState.weatherEnabled = enabled and true or false

  if not weatherState.weatherEnabled and activated then
    -- Immediately force sunny when disabling
    weatherState.transitioning = false
    -- Switch back to rain datablock if was in snow state
    local wasSnow = isSnowState(weatherState.currentState)
    if wasSnow then switchRainDataBlock(false) end
    weatherState.currentState = "sunny"
    local profile = WEATHER_PROFILES["sunny"]
    if profile then
      applyScenetreeValues(profile, true)
      updateRainSound(0, false)
    end
    -- Reset groundmodel to dry
    if currentGroundmodel ~= "dry" then
      pcall(function() applyGroundmodel("dry") end)
    end
    weatherState.scheduledDuration = 999999
    weatherState.timeInCurrentState = 0
    broadcastWeatherUpdate()
    log('I', logTag, 'Weather disabled — forced sunny')

  elseif weatherState.weatherEnabled and activated then
    -- Re-enable: select fresh weather based on current season
    selectAndApplyWeather()
    log('I', logTag, 'Weather re-enabled')
  end
end

-- Lock weather probability tables to a specific season
-- season: "auto" (follows game calendar), "spring", "summer", "autumn", "winter"
-- This affects what weather types can occur — it does not freeze current weather
setSeasonLock = function(season)
  local valid = {auto = true, spring = true, summer = true, autumn = true, winter = true}
  if not valid[season] then
    log('W', logTag, 'Invalid season lock value: ' .. tostring(season) .. ' (valid: auto, spring, summer, autumn, winter)')
    return
  end
  weatherState.seasonLock = season
  if season ~= "auto" then
    local lockMonth = SEASON_LOCK_MONTH[season]
    if lockMonth then
      weatherState.month = lockMonth
      weatherState.season = season
    end
  end
  log('I', logTag, 'Season lock set to: ' .. season)
end

M.setWeatherEnabled = setWeatherEnabled
M.setSeasonLock = setSeasonLock
M.getWeatherEnabled = function() return weatherState.weatherEnabled end
M.getSeasonLock = function() return weatherState.seasonLock end

-- After sleep: simulate weather progression for the hours that passed.
-- Without this, player wakes up to the same blizzard they went to sleep in.
M.onBCMSleepComplete = function(data)
  if not weatherState.weatherEnabled then return end
  if not data then return end

  local hoursSlept = data.hoursSlept or data.gameHours or 8
  local secondsElapsed = hoursSlept * 3600  -- convert game hours to seconds

  -- Walk through weather states: consume time, trigger transitions as needed
  local remaining = secondsElapsed
  local maxSteps = 20  -- safety: max weather changes during sleep
  local steps = 0

  while remaining > 0 and steps < maxSteps do
    local timeLeft = weatherState.scheduledDuration - weatherState.timeInCurrentState
    if remaining >= timeLeft then
      -- This state expires during sleep — advance to next
      remaining = remaining - timeLeft

      -- Update season info
      local dateInfo = extensions.bcm_timeSystem and extensions.bcm_timeSystem.getDateInfo()
      if dateInfo then
        weatherState.month = dateInfo.month
        weatherState.season = dateInfo.season
      end
      if weatherState.seasonLock ~= "auto" then
        local lockMonth = SEASON_LOCK_MONTH and SEASON_LOCK_MONTH[weatherState.seasonLock]
        if lockMonth then weatherState.month = lockMonth end
      end

      local newState = selectNextWeather(weatherState.currentState, weatherState.month)
      -- Snap directly (no smooth transition — player was asleep)
      weatherState.previousState = weatherState.currentState
      weatherState.currentState = newState
      weatherState.transitioning = false
      weatherState.transitionProgress = 0
      scheduleNextWeatherChange()
      steps = steps + 1
    else
      -- Sleep ends mid-state — advance the clock
      weatherState.timeInCurrentState = weatherState.timeInCurrentState + remaining
      remaining = 0
    end
  end

  -- Apply the final weather state to scenetree (snap, no transition)
  if steps > 0 then
    startTransition(weatherState.currentState)
    -- Snap transition to 100% immediately
    weatherState.transitioning = false
    weatherState.transitionProgress = 0
    if weatherState.goalValues then
      applyScenetreeValues(weatherState.goalValues, true)
    end
    broadcastWeatherUpdate()
    updateTrafficSpeed()
    log('I', logTag, 'Post-sleep weather: ' .. weatherState.currentState .. ' (simulated ' .. steps .. ' transitions over ' .. tostring(hoursSlept) .. 'h)')
  end
end

-- Lifecycle hooks
M.onCareerActive = onCareerActive
M.onUpdate = onUpdate

return M
