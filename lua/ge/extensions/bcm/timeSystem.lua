-- BCM Time System
-- Core time management for BCM career mode.
-- Manages day/night cycle, dual time tracking (real-time for loans + game-time for calendar),
-- 56-day year date system, save/load persistence, and guihook broadcasts to Vue.
-- Extension name: bcm_timeSystem
-- Loaded by bcm_extensionManager before bcm_phoneTime.

local M = {}

M.debugName = "BCM Time System"
M.debugOrder = 10 -- High priority (foundation module)
M.dependencies = {'career_career', 'career_saveSystem'}

-- ============================================================================
-- Forward declarations
-- ============================================================================
local gameTimeToDate
local todToVisualHours
local visualHoursToTod
local broadcastTimeUpdate
local onUpdate
local saveTimeData
local loadTimeData
local initModule
local resetModule
local applyTodSettings
local isInNightRange
local getGameDayOfWeek
local onBeforeRadialOpened
local onHideRadialMenu
local getRadialTimeData
local installQuickAccessFilter
local uninstallQuickAccessFilter
local calcRealDateGameDays

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_timeSystem'

local START_EPOCH = {year = 2026, month = 3, day = 15} -- Epoch year for date calc (new saves start on real OS date)
local START_TOD = 0.2083 -- 17:00 (5 PM) as tod.time: ((17-12)%24)/24

local DAYS_PER_SEASON = 14
local DAYS_PER_YEAR = 56
local SEASONS = {"spring", "summer", "autumn", "winter"}
local SEASON_MONTHS = {3, 6, 9, 12} -- Map season index to representative month

-- Leap year check
local function isLeapYear(y)
 return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

-- Calculate game days offset for a real-world date (days since Jan 1 of START_EPOCH.year)
-- Returns nil on failure (os.date may not be available in all contexts)
calcRealDateGameDays = function()
 local ok, now = pcall(os.date, "*t")
 if not ok or type(now) ~= "table" then
 log('W', logTag, 'os.date("*t") failed: ' .. tostring(now))
 -- Fallback: try os.time() to build date manually
 local ok2, epoch = pcall(os.time)
 if ok2 and epoch then
 local ok3, dateStr = pcall(os.date, "%Y-%m-%d", epoch)
 if ok3 and dateStr then
 local y, m, d = dateStr:match("(%d+)-(%d+)-(%d+)")
 if y then
 now = {year = tonumber(y), month = tonumber(m), day = tonumber(d)}
 log('I', logTag, 'Used os.date fallback: ' .. dateStr)
 end
 end
 end
 if type(now) ~= "table" then
 log('W', logTag, 'All date methods failed, cannot determine real date')
 return nil
 end
 end

 log('I', logTag, string.format('Real OS date detected: %04d-%02d-%02d', now.year, now.month, now.day))

 local epochYear = START_EPOCH.year
 local totalDays = 0
 -- Add full years from epochYear to now.year
 for y = epochYear, now.year - 1 do
 totalDays = totalDays + (isLeapYear(y) and 366 or 365)
 end
 -- Add days in current year up to current date
 local leap = isLeapYear(now.year)
 local daysInMonth = {31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
 for m = 1, now.month - 1 do
 totalDays = totalDays + daysInMonth[m]
 end
 totalDays = totalDays + (now.day - 1) -- 0-based: Jan 1 = day 0
 return totalDays
end

-- Base day length: 1 real minute = 15 game minutes at 1x speed
-- 1 game day = 96 real minutes = 5760 real seconds
local BASE_DAY_LENGTH = 5760

-- Night range in tod.time (0 = noon, 0.5 = midnight)
-- ~6 PM = tod 0.25, ~7 AM = tod 0.7917
local NIGHT_THRESHOLD_START = 0.25
local NIGHT_THRESHOLD_END = 0.7917

-- Night skip uses very high nightScale to fast-forward
local NIGHT_SKIP_SCALE = 100

-- Max broadcast rate (seconds between broadcasts at high speed)
local MAX_BROADCAST_INTERVAL = 0.5

-- Day name keys (Monday=1 through Sunday=7) — translated in Vue
local DAY_KEYS = {
 "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
}

-- ============================================================================
-- Private state
-- ============================================================================
local timeState = {
 gameTimeDays = 0, -- Accumulated game days since career start (float)
 realTimeAccumSecs = 0, -- Real-time seconds accumulator (for loan system)
 speedMultiplier = 1.0, -- User speed setting (0.25 to 8.0)
 nightRatio = 10/48, -- Night duration as fraction of day (~10 real min night, ~48 min day)
 skipNights = false, -- Whether to fast-forward through nights
 timeFormat24h = true, -- 24h vs 12h display format
 lastTodTime = nil, -- For detecting day boundary crossings
 isNightSkipping = false, -- Currently in night skip mode
}

local activated = false
local isInitialized = false
local todSnapshot = nil -- Captures TOD state before radial menu opens (Phase 31 — FIX-02)
local lastBroadcastMinute = -1
local lastBroadcastTime = 0 -- os.clock() of last broadcast (for high-speed throttle)

-- Debug fast-forward state
local fastForward = nil -- { targetDays, daysRemaining, originalSpeed, originalNightRatio, originalSkipNights }

-- ============================================================================
-- Date calculation
-- ============================================================================

-- Convert game-time days elapsed to a calendar date
-- 1 game-day = 1 calendar day, starting from January 1st of START_EPOCH.year
gameTimeToDate = function(gameDays)
 local totalDays = math.floor(gameDays)

 -- Find year, accounting for leap years
 local year = START_EPOCH.year
 local remaining = totalDays
 while true do
 local daysThisYear = isLeapYear(year) and 366 or 365
 if remaining < daysThisYear then break end
 remaining = remaining - daysThisYear
 year = year + 1
 end

 -- Find month from remaining days (0-based day-of-year)
 local leap = isLeapYear(year)
 local daysInMonth = {31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
 local month = 1
 for m = 1, 12 do
 if remaining < daysInMonth[m] then
 month = m
 break
 end
 remaining = remaining - daysInMonth[m]
 end
 local day = remaining + 1 -- 1-based

 -- Season from month
 local seasonIndex
 if month >= 3 and month <= 5 then seasonIndex = 0 -- spring
 elseif month >= 6 and month <= 8 then seasonIndex = 1 -- summer
 elseif month >= 9 and month <= 11 then seasonIndex = 2 -- autumn
 else seasonIndex = 3 end -- winter

 return {
 year = year,
 month = month,
 day = day,
 season = SEASONS[seasonIndex + 1],
 totalGameDays = totalDays,
 dayOfWeek = (totalDays % 7) + 1 -- 1=lunes, 7=domingo
 }
end

-- formatFullDate removed — Vue handles localized formatting via bcmI18n

-- ============================================================================
-- Time conversion and formatting
-- ============================================================================

-- Convert tod.time (0-1, noon-based) to visual hours (0-23, midnight-based)
todToVisualHours = function(todTime)
 return (todTime * 24 + 12) % 24
end

-- Convert visual hours (0-23) back to tod.time (0-1)
visualHoursToTod = function(hours)
 return ((hours - 12) % 24) / 24
end

-- Check if a tod.time value is in the night range
isInNightRange = function(todTime)
 return todTime >= NIGHT_THRESHOLD_START and todTime <= NIGHT_THRESHOLD_END
end

-- ============================================================================
-- Guihook broadcast
-- ============================================================================

-- Broadcast time update to Vue via guihooks
-- Throttled: only fires on minute change or every MAX_BROADCAST_INTERVAL seconds
broadcastTimeUpdate = function(todTime)
 if not todTime then return end

 local visualHours = todToVisualHours(todTime)
 local hours = math.floor(visualHours)
 local minutes = math.floor((visualHours - hours) * 60)
 local currentMinute = hours * 60 + minutes

 -- Throttle: only broadcast on minute change or time interval
 local now = os.clock()
 if currentMinute == lastBroadcastMinute and (now - lastBroadcastTime) < MAX_BROADCAST_INTERVAL then
 return
 end
 lastBroadcastMinute = currentMinute
 lastBroadcastTime = now

 local dateInfo = gameTimeToDate(timeState.gameTimeDays)

 -- Pre-format clock string (no i18n needed)
 local timeStr
 if timeState.timeFormat24h then
 timeStr = string.format("%02d:%02d", hours, minutes)
 else
 local period = "AM"
 local dh = hours
 if hours == 0 then dh = 12
 elseif hours == 12 then period = "PM"
 elseif hours > 12 then dh = hours - 12; period = "PM"
 end
 timeStr = string.format("%d:%02d %s", dh, minutes, period)
 end

 guihooks.trigger("BCMTimeUpdate", {
 time = timeStr,
 date = string.format("%02d/%02d", dateInfo.day, dateInfo.month),
 -- Raw keys for i18n translation in Vue
 dayOfWeek = DAY_KEYS[dateInfo.dayOfWeek] or "monday",
 monthNum = dateInfo.month,
 dayNum = dateInfo.day,
 yearNum = dateInfo.year,
 season = dateInfo.season,
 gameDay = timeState.gameTimeDays,
 todFloat = todTime,
 timeFormat24h = timeState.timeFormat24h
 })
end

-- ============================================================================
-- TOD settings application
-- ============================================================================

-- Apply current speed and night ratio settings to scenetree.tod
applyTodSettings = function()
 if not scenetree.tod then return end

 -- Set overall cycle speed based on multiplier
 scenetree.tod.dayLength = BASE_DAY_LENGTH / timeState.speedMultiplier

 -- Set night scale for asymmetric day/night duration
 -- nightScale > 1 makes night pass faster (shorter duration)
 -- nightRatio = 1/3 means night is 1/3 of day, so nightScale = 3.0
 if timeState.isNightSkipping then
 scenetree.tod.nightScale = NIGHT_SKIP_SCALE
 else
 scenetree.tod.nightScale = 1 / timeState.nightRatio
 end

 -- dayScale stays at 1.0 (baseline)
 scenetree.tod.dayScale = 1.0
end

-- ============================================================================
-- Update loop
-- ============================================================================

-- Called every frame when career is active
onUpdate = function(dtReal, dtSim, dtRaw)
 if not activated then return end
 if not scenetree.tod then return end

 -- Accumulate real time (for loan system compatibility)
 timeState.realTimeAccumSecs = timeState.realTimeAccumSecs + dtReal

 -- Read current tod
 local currentTod = scenetree.tod.time

 -- Day boundary detection: tod.time wraps from ~1.0 back to ~0.0
 -- Use threshold of 0.1 to distinguish real wraps from minor fluctuations
 if timeState.lastTodTime ~= nil then
 if currentTod < timeState.lastTodTime - 0.1 then
 -- Crossed midnight boundary: increment game day counter
 timeState.gameTimeDays = timeState.gameTimeDays + 1
 log('D', logTag, 'Day boundary crossed. Game day: ' .. tostring(math.floor(timeState.gameTimeDays)))

 -- Notify all modules that a new game day has started
 extensions.hook('onBCMNewGameDay', { gameDay = math.floor(timeState.gameTimeDays) })

 -- Fast-forward: count down remaining days
 if fastForward then
 fastForward.daysRemaining = fastForward.daysRemaining - 1
 log('I', logTag, 'Fast-forward: ' .. tostring(fastForward.daysRemaining) .. ' days remaining')
 if fastForward.daysRemaining <= 0 then
 -- Restore original settings
 timeState.speedMultiplier = fastForward.originalSpeed
 timeState.nightRatio = fastForward.originalNightRatio
 timeState.skipNights = fastForward.originalSkipNights
 timeState.isNightSkipping = false
 log('I', logTag, 'Fast-forward complete. Speed restored to ' .. tostring(timeState.speedMultiplier))
 fastForward = nil
 end
 end
 end
 end

 -- Midday boundary detection: tod crosses 0.5 (noon)
 -- Used by marketplace for 12h listing rotation
 if timeState.lastTodTime ~= nil then
 if timeState.lastTodTime < 0.5 and currentTod >= 0.5 then
 extensions.hook('onBCMMidday', { gameDay = math.floor(timeState.gameTimeDays) })
 end
 end

 -- Update last known tod
 timeState.lastTodTime = currentTod

 -- Night skip logic
 if timeState.skipNights then
 local inNight = isInNightRange(currentTod)
 if inNight and not timeState.isNightSkipping then
 -- Entering night: enable night skip
 timeState.isNightSkipping = true
 log('D', logTag, 'Night skip activated')
 elseif not inNight and timeState.isNightSkipping then
 -- Exiting night: disable night skip
 timeState.isNightSkipping = false
 log('D', logTag, 'Night skip deactivated')
 end
 else
 -- skipNights disabled, ensure we're not stuck in skip mode
 if timeState.isNightSkipping then
 timeState.isNightSkipping = false
 end
 end

 -- Apply tod settings (speed, night ratio, night skip)
 applyTodSettings()

 -- Broadcast time update to Vue
 broadcastTimeUpdate(currentTod)
end

-- ============================================================================
-- Save / Load
-- ============================================================================

-- Save time state to disk
saveTimeData = function(currentSavePath)
 if not isInitialized then return end

 if not career_saveSystem then
 log('W', logTag, 'career_saveSystem not available, cannot save time data')
 return
 end

 -- Ensure BCM directory exists
 local bcmDir = currentSavePath .. "/career/bcm"
 if not FS:directoryExists(bcmDir) then
 FS:directoryCreate(bcmDir)
 end

 local data = {
 gameTimeDays = timeState.gameTimeDays,
 realTimeAccumSecs = timeState.realTimeAccumSecs,
 speedMultiplier = timeState.speedMultiplier,
 nightRatio = timeState.nightRatio,
 skipNights = timeState.skipNights,
 timeFormat24h = timeState.timeFormat24h,
 todTime = scenetree.tod and scenetree.tod.time or 0,
 version = 1 -- For future migration support
 }

 local dataPath = bcmDir .. "/timeSystem.json"
 career_saveSystem.jsonWriteFileSafe(dataPath, data, true)
 log('I', logTag, 'Time data saved. Game day: ' .. tostring(math.floor(timeState.gameTimeDays)))
end

-- Load time state from disk
loadTimeData = function(newSave)
 if not career_career or not career_career.isActive() then
 return
 end

 if not career_saveSystem then
 log('W', logTag, 'career_saveSystem not available, cannot load time data')
 return
 end

 -- New career: start on today's real-world date
 if newSave then
 local startDays = calcRealDateGameDays() or 0
 timeState.gameTimeDays = startDays
 timeState.realTimeAccumSecs = 0
 timeState.speedMultiplier = 1.0
 timeState.nightRatio = 10/48
 timeState.skipNights = false
 timeState.timeFormat24h = true
 timeState.lastTodTime = nil
 timeState.isNightSkipping = false

 -- Set starting time: 5 PM on first career day
 if scenetree.tod then
 scenetree.tod.time = START_TOD
 scenetree.tod.play = true
 end

 local startDate = gameTimeToDate(startDays)
 log('I', logTag, string.format('New career started on real date: %04d-%02d-%02d (gameDay=%d)',
 startDate.year, startDate.month, startDate.day, startDays))
 return
 end

 -- Existing career: restore from save
 local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
 if not currentSaveSlot then
 log('W', logTag, 'No save slot active, cannot load time data')
 return
 end

 local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
 if not autosavePath then
 log('W', logTag, 'No autosave found for slot: ' .. tostring(currentSaveSlot))
 return
 end

 local dataPath = autosavePath .. "/career/bcm/timeSystem.json"
 local data = jsonReadFile(dataPath)

 if data then
 timeState.gameTimeDays = data.gameTimeDays or 0
 timeState.realTimeAccumSecs = data.realTimeAccumSecs or 0
 timeState.speedMultiplier = data.speedMultiplier or 1.0
 timeState.nightRatio = data.nightRatio or (1/3)
 timeState.skipNights = data.skipNights or false
 timeState.timeFormat24h = (data.timeFormat24h ~= false) -- default true
 timeState.lastTodTime = nil -- Reset boundary detection on load
 timeState.isNightSkipping = false

 -- Restore tod position (play is always forced true by initModule)
 if scenetree.tod and data.todTime ~= nil then
 scenetree.tod.time = data.todTime
 end

 log('I', logTag, 'Time data loaded. Game day: ' .. tostring(math.floor(timeState.gameTimeDays)))
 else
 -- Fallback: no save file but not flagged as new (shouldn't happen)
 timeState.gameTimeDays = 0
 timeState.realTimeAccumSecs = 0
 timeState.speedMultiplier = 1.0
 timeState.nightRatio = 10/48
 timeState.skipNights = false
 timeState.timeFormat24h = true
 timeState.lastTodTime = nil
 timeState.isNightSkipping = false

 if scenetree.tod then
 scenetree.tod.time = START_TOD
 scenetree.tod.play = true
 end

 log('W', logTag, 'No save file and not newSave — initialized defaults')
 end

 -- Apply speed settings after load
 applyTodSettings()

 -- Reset broadcast state
 lastBroadcastMinute = -1
 lastBroadcastTime = 0
end

-- ============================================================================
-- Module lifecycle
-- ============================================================================

-- Initialize module state
initModule = function(newSave)
 loadTimeData(newSave)
 isInitialized = true
 activated = true

 -- Ensure day/night cycle is running
 if scenetree.tod then
 scenetree.tod.play = true
 end

 -- Immediately broadcast current time
 if scenetree.tod then
 broadcastTimeUpdate(scenetree.tod.time)
 end

 log('I', logTag, 'Time system activated')
end

-- Reset module state
resetModule = function()
 timeState.gameTimeDays = 0
 timeState.realTimeAccumSecs = 0
 timeState.speedMultiplier = 1.0
 timeState.nightRatio = 1/3
 timeState.skipNights = false
 timeState.timeFormat24h = true
 timeState.lastTodTime = nil
 timeState.isNightSkipping = false

 activated = false
 isInitialized = false
 lastBroadcastMinute = -1
 lastBroadcastTime = 0

 log('I', logTag, 'Time system reset')
end

-- ============================================================================
-- Radial menu TOD lock (Phase 31 — FIX-02)
-- Prevents vanilla time-of-day controls from overriding BCM time during career
-- ============================================================================

-- Snapshot TOD state before radial menu opens
onBeforeRadialOpened = function()
 if not activated then return end
 if not scenetree.tod then return end

 todSnapshot = {
 time = scenetree.tod.time,
 play = scenetree.tod.play
 }
end

-- Restore TOD state when radial menu closes, reverting any vanilla time changes
onHideRadialMenu = function()
 if not activated then return end
 if not todSnapshot then return end
 if not scenetree.tod then return end

 scenetree.tod.time = todSnapshot.time
 scenetree.tod.play = todSnapshot.play
 todSnapshot = nil

 log('D', logTag, 'TOD values restored after radial menu close')
end

-- ============================================================================
-- Radial menu quickAccess filter (Phase 31 — FIX-02)
-- Wraps core_quickAccess.getUiData to hide vanilla time entries during career
-- ============================================================================
local originalGetUiData = nil

installQuickAccessFilter = function()
 if originalGetUiData then return end -- Already installed
 if not core_quickAccess then return end

 originalGetUiData = core_quickAccess.getUiData
 core_quickAccess.getUiData = function(...)
 local data = originalGetUiData(...)
 if not data then return data end
 if not activated then return data end -- Only filter during active BCM career

 -- Filter items: remove entries whose action contains time-of-day keywords
 if data.items and type(data.items) == "table" then
 local filtered = {}
 for _, item in ipairs(data.items) do
 local dominated = false
 local title = type(item.title) == "string" and item.title:lower() or ""
 local icon = type(item.icon) == "string" and item.icon:lower() or ""
 local action = type(item.action) == "string" and item.action:lower() or ""

 -- Match vanilla time-of-day entries by their known characteristics
 if action:find("core_environment") then
 dominated = true
 end
 if icon == "sunrise" or icon == "sunset" or icon:find("sunrise") or icon:find("sunset") then
 dominated = true
 end
 if title:find("time of day") or title:find("time slider") then
 dominated = true
 end

 if not dominated then
 table.insert(filtered, item)
 end
 end
 data.items = filtered
 end

 return data
 end
 log('I', logTag, 'QuickAccess filter installed — vanilla time controls hidden during career')
end

uninstallQuickAccessFilter = function()
 if not originalGetUiData then return end
 if not core_quickAccess then return end

 core_quickAccess.getUiData = originalGetUiData
 originalGetUiData = nil
 log('I', logTag, 'QuickAccess filter removed — vanilla time controls restored')
end

-- ============================================================================
-- Radial menu BCM time data (Phase 31 — FIX-02)
-- Provides time info for BCM radial menu entries
-- ============================================================================

getRadialTimeData = function()
 if not activated then return nil end

 local todTime = scenetree.tod and scenetree.tod.time or 0
 local visualHours = todToVisualHours(todTime)
 local hours = math.floor(visualHours)
 local minutes = math.floor((visualHours - hours) * 60)

 local timeStr
 if timeState.timeFormat24h then
 timeStr = string.format("%02d:%02d", hours, minutes)
 else
 local period = hours >= 12 and "PM" or "AM"
 local h12 = hours % 12
 if h12 == 0 then h12 = 12 end
 timeStr = string.format("%d:%02d %s", h12, minutes, period)
 end

 local gameDays = math.floor(timeState.gameTimeDays) + 1 -- 1-based day number

 return {
 timeString = timeStr,
 dayNumber = gameDays,
 hours = hours,
 minutes = minutes
 }
end

-- ============================================================================
-- Lifecycle hooks (BeamNG callbacks)
-- ============================================================================

-- Called when career becomes active/inactive
-- NOTE: BCM extensions receive onCareerActive (global hook), NOT onCareerActivated
-- (which only fires for career/modules/ registered modules).
M.onCareerActive = function(active, newSave)
 if active then
 initModule(newSave)
 installQuickAccessFilter()
 else
 uninstallQuickAccessFilter()
 activated = false
 todSnapshot = nil
 end
end

-- Called during save
M.onSaveCurrentSaveSlot = function(currentSavePath)
 saveTimeData(currentSavePath)
end

-- Called before switching save slots (clear state)
M.onBeforeSetSaveSlot = function()
 uninstallQuickAccessFilter()
 resetModule()
end

-- Called when world is fully loaded (restore tod state)
M.onWorldReadyState = function(state)
 if state == 2 and activated then
 loadTimeData()
 end
end

-- Called every frame
M.onUpdate = onUpdate

-- Radial menu lifecycle hooks (Phase 31 — prevent vanilla time controls)
M.onBeforeRadialOpened = onBeforeRadialOpened
M.onHideRadialMenu = onHideRadialMenu
M.getRadialTimeData = getRadialTimeData

-- ============================================================================
-- Public API
-- ============================================================================

-- Get accumulated game days (float)
M.getGameTimeDays = function()
 return timeState.gameTimeDays
end

-- Get real-time accumulator in seconds (for loan system)
M.getRealTimeAccumSecs = function()
 return timeState.realTimeAccumSecs
end

-- Get full date info table
M.getDateInfo = function()
 return gameTimeToDate(timeState.gameTimeDays)
end

-- Get current day of week (1=Monday through 7=Sunday)
getGameDayOfWeek = function()
 local dateInfo = gameTimeToDate(timeState.gameTimeDays)
 return dateInfo.dayOfWeek
end

M.getGameDayOfWeek = getGameDayOfWeek

-- Convert game-time days to date info table (used by loans.lua for due date calculation)
M.gameTimeToDate = gameTimeToDate

-- Convert tod.time (0-1) to visual hours (0-23)
M.todToVisualHours = todToVisualHours

-- Get formatted time string (using current format setting)
M.getFormattedTime = function()
 if not scenetree.tod then return "--:--" end
 local visualHours = todToVisualHours(scenetree.tod.time)
 local h = math.floor(visualHours)
 local m = math.floor((visualHours - h) * 60)
 if timeState.timeFormat24h then
 return string.format("%02d:%02d", h, m)
 else
 local period = "AM"
 local dh = h
 if h == 0 then dh = 12
 elseif h == 12 then period = "PM"
 elseif h > 12 then dh = h - 12; period = "PM"
 end
 return string.format("%d:%02d %s", dh, m, period)
 end
end

-- Get compact date string (dd/mm)
M.getFormattedDate = function()
 local dateInfo = gameTimeToDate(timeState.gameTimeDays)
 return string.format("%02d/%02d", dateInfo.day, dateInfo.month)
end

-- Get raw date info table (for external formatting)
M.getFullDateInfo = function()
 local dateInfo = gameTimeToDate(timeState.gameTimeDays)
 dateInfo.dayOfWeekKey = DAY_KEYS[dateInfo.dayOfWeek] or "monday"
 return dateInfo
end

-- Speed multiplier (0.25 to 8.0)
M.getSpeedMultiplier = function()
 return timeState.speedMultiplier
end

M.setSpeedMultiplier = function(mult)
 mult = tonumber(mult) or 1.0
 timeState.speedMultiplier = math.max(0.25, math.min(8.0, mult))
 applyTodSettings()
 log('I', logTag, 'Speed multiplier set to: ' .. tostring(timeState.speedMultiplier))
end

-- Debug: fast-forward N days at turbo speed (x20), then restore original settings.
-- The game visually speeds up and all systems (offers, timers) run naturally.
M.debugFastForward = function(days, speed)
 days = tonumber(days) or 3
 speed = tonumber(speed) or 20

 if fastForward then
 log('W', logTag, 'Fast-forward already active (' .. tostring(fastForward.daysRemaining) .. ' days remaining). Ignoring.')
 return
 end

 fastForward = {
 targetDays = days,
 daysRemaining = days,
 originalSpeed = timeState.speedMultiplier,
 originalNightRatio = timeState.nightRatio,
 originalSkipNights = timeState.skipNights,
 }

 -- Turbo: high speed, skip nights, compress night duration
 timeState.speedMultiplier = speed
 timeState.skipNights = true
 timeState.nightRatio = 0.1 -- Night passes very fast
 applyTodSettings()

 log('I', logTag, 'Fast-forward started: ' .. tostring(days) .. ' days at x' .. tostring(speed))
end

-- Cancel an active fast-forward
M.debugStopFastForward = function()
 if not fastForward then
 log('W', logTag, 'No fast-forward active')
 return
 end
 timeState.speedMultiplier = fastForward.originalSpeed
 timeState.nightRatio = fastForward.originalNightRatio
 timeState.skipNights = fastForward.originalSkipNights
 timeState.isNightSkipping = false
 fastForward = nil
 applyTodSettings()
 log('I', logTag, 'Fast-forward cancelled. Speed restored.')
end

-- Check if fast-forward is active
M.isFastForwarding = function()
 return fastForward ~= nil
end

-- Time format (24h or 12h)
M.getTimeFormat24h = function()
 return timeState.timeFormat24h
end

M.setTimeFormat24h = function(use24h)
 timeState.timeFormat24h = use24h and true or false
 -- Force immediate broadcast with new format
 lastBroadcastMinute = -1
 if scenetree.tod then
 broadcastTimeUpdate(scenetree.tod.time)
 end
 log('I', logTag, 'Time format set to: ' .. (timeState.timeFormat24h and '24h' or '12h'))
end

-- Night ratio (0.1 to 1.0)
M.getNightRatio = function()
 return timeState.nightRatio
end

M.setNightRatio = function(ratio)
 ratio = tonumber(ratio) or (1/3)
 timeState.nightRatio = math.max(0.01, math.min(1.0, ratio))
 applyTodSettings()
 log('I', logTag, 'Night ratio set to: ' .. tostring(timeState.nightRatio))
end

-- Night skip toggle
M.getSkipNights = function()
 return timeState.skipNights
end

M.setSkipNights = function(skip)
 timeState.skipNights = skip and true or false
 if not timeState.skipNights then
 timeState.isNightSkipping = false
 end
 applyTodSettings()
 log('I', logTag, 'Night skip set to: ' .. tostring(timeState.skipNights))
end

-- Full state (for debug)
M.getTimeState = function()
 local state = {}
 for k, v in pairs(timeState) do
 state[k] = v
 end
 state.activated = activated
 state.isInitialized = isInitialized
 if scenetree.tod then
 state.currentTodTime = scenetree.tod.time
 state.todPlay = scenetree.tod.play
 state.todDayLength = scenetree.tod.dayLength
 state.todDayScale = scenetree.tod.dayScale
 state.todNightScale = scenetree.tod.nightScale
 end
 return state
end

-- Advance game-time by N days (for Phase 16 sleep integration)
-- Adjusts gameTimeDays, tod.time, and realTimeAccumSecs accordingly
-- @param gameDays number - Number of game days to advance
-- @return number - Number of game days actually advanced
M.advanceTime = function(gameDays)
 gameDays = tonumber(gameDays) or 0
 if gameDays <= 0 then return 0 end

 -- Advance game day counter
 timeState.gameTimeDays = timeState.gameTimeDays + gameDays
 log('I', logTag, 'Advanced time by ' .. tostring(gameDays) .. ' days. New game day: ' .. tostring(math.floor(timeState.gameTimeDays)))

 -- Sync real-time accumulator proportionally
 -- realSecsPerGameDay = BASE_DAY_LENGTH / speedMultiplier
 local realSecsPerGameDay = BASE_DAY_LENGTH / timeState.speedMultiplier
 local realSecsAdvance = gameDays * realSecsPerGameDay
 timeState.realTimeAccumSecs = timeState.realTimeAccumSecs + realSecsAdvance

 -- Advance tod.time by the fractional part of days
 if scenetree.tod then
 -- Each full day = 1.0 in tod.time cycle, fractional days = partial cycle
 local todAdvance = gameDays % 1.0 -- only fractional part affects tod position
 local newTod = (scenetree.tod.time + todAdvance) % 1.0
 scenetree.tod.time = newTod
 -- Reset boundary detection to avoid false day increments
 timeState.lastTodTime = newTod
 end

 -- Force immediate broadcast
 lastBroadcastMinute = -1
 if scenetree.tod then
 broadcastTimeUpdate(scenetree.tod.time)
 end

 return gameDays
end

return M
