-- BCM Weather Forecast Extension
-- Generates 3-day weather forecast with intentional 20% inaccuracy.
-- Uses seasonal probability tables from bcm_weather for predictions.
-- Extension name: bcm_weatherForecast

local M = {}

-- Forward declarations
local generateForecast
local getForecast
local onUpdate

-- Constants
local logTag = 'bcm_weatherForecast'
local INACCURACY_CHANCE = 0.20 -- 20% chance forecast is wrong

-- Temperature ranges by season (Celsius)
local TEMP_RANGES = {
 spring = {low = 8, high = 22},
 summer = {low = 18, high = 35},
 autumn = {low = 5, high = 18},
 winter = {low = -5, high = 8}
}

-- Day name keys
local DAY_KEYS = {"monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"}

-- State
local cachedForecast = nil
local cachedDay = -1

-- Get season from month number
local function getSeasonFromMonth(month)
 if month >= 3 and month <= 5 then return "spring"
 elseif month >= 6 and month <= 8 then return "summer"
 elseif month >= 9 and month <= 11 then return "autumn"
 else return "winter" end
end

-- Select weather state from probability table using weighted random
local function selectFromProbabilities(probs, states)
 local cumulative = {}
 local total = 0
 for _, state in ipairs(states) do
 local weight = probs[state] or 0
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
 return "sunny"
end

-- Generate forecast for 3 days (today + next 2 days)
generateForecast = function()
 local dateInfo = nil
 if extensions.bcm_timeSystem then
 dateInfo = extensions.bcm_timeSystem.getDateInfo()
 end
 if not dateInfo then
 log('W', logTag, 'Time system not available for forecast generation')
 return nil
 end

 local states = nil
 if extensions.bcm_weather then
 states = extensions.bcm_weather.getStates()
 end
 if not states then
 states = {"sunny", "overcast", "drizzle", "storm", "snow", "blizzard"}
 end

 local forecast = {}
 local currentGameDays = extensions.bcm_timeSystem.getGameTimeDays() or 0

 for dayOffset = 0, 2 do
 -- Get date for this forecast day
 local forecastDate = extensions.bcm_timeSystem.gameTimeToDate(currentGameDays + dayOffset)
 local month = forecastDate.month
 local season = getSeasonFromMonth(month)

 -- Get seasonal probabilities
 local probs = nil
 if extensions.bcm_weather then
 probs = extensions.bcm_weather.getSeasonalProbabilities(month)
 end
 if not probs then
 probs = {sunny = 40, overcast = 30, drizzle = 20, storm = 10, snow = 0}
 end

 -- Select predicted weather
 local predicted = selectFromProbabilities(probs, states)

 -- 20% chance of inaccuracy: replace with a different random state
 if math.random() < INACCURACY_CHANCE then
 local alternative = selectFromProbabilities(probs, states)
 -- Ensure it's actually different
 local attempts = 0
 while alternative == predicted and attempts < 5 do
 alternative = selectFromProbabilities(probs, states)
 attempts = attempts + 1
 end
 if alternative ~= predicted then
 predicted = alternative
 end
 end

 -- Generate confidence percentage
 local confidence = math.random(60, 95)

 -- Generate temperature range based on season
 local range = TEMP_RANGES[season] or TEMP_RANGES.spring
 local tempHigh = math.floor(range.low + math.random() * (range.high - range.low) + (math.random() - 0.5) * 3)
 local tempLow = tempHigh - math.random(4, 10)

 -- Weather state modifiers
 if predicted == "storm" then tempHigh = tempHigh - 3 end
 if predicted == "snow" or predicted == "blizzard" then tempHigh = math.min(tempHigh, 2); tempLow = math.min(tempLow, -2) end
 if predicted == "sunny" then tempHigh = tempHigh + 2 end

 -- Day name
 local dayOfWeek = (forecastDate.dayOfWeek) or ((math.floor(currentGameDays + dayOffset) % 7) + 1)
 local dayName = DAY_KEYS[dayOfWeek] or "monday"

 table.insert(forecast, {
 dayOffset = dayOffset,
 predicted = predicted,
 confidence = confidence,
 tempHigh = tempHigh,
 tempLow = tempLow,
 dayName = dayName,
 date = string.format("%02d/%02d", forecastDate.day, forecastDate.month),
 month = month,
 season = season
 })
 end

 cachedForecast = forecast
 cachedDay = math.floor(currentGameDays)
 log('I', logTag, 'Forecast generated for ' .. #forecast .. ' days')
 return forecast
end

-- Get cached forecast (generates if needed)
getForecast = function()
 if not cachedForecast then
 generateForecast()
 end
 return cachedForecast or {}
end

-- Check if day changed and regenerate forecast
onUpdate = function(dtReal, dtSim, dtRaw)
 if not extensions.bcm_timeSystem then return end
 local currentGameDays = extensions.bcm_timeSystem.getGameTimeDays() or 0
 local currentDay = math.floor(currentGameDays)
 if currentDay ~= cachedDay then
 generateForecast()
 end
end

-- Public API
M.generateForecast = generateForecast
M.getForecast = getForecast
M.onUpdate = onUpdate

return M
