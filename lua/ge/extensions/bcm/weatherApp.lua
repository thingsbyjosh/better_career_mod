-- BCM Weather App Extension
-- Registers the Weather app on the phone and bridges forecast data to Vue.
-- Sends severe weather notifications for storms and snow.
-- Extension name: bcm_weatherApp

local M = {}

-- Forward declarations
local onCareerModulesActivated
local sendWeatherToVue
local onWeatherStateChanged
local lastNotifiedState

-- Constants
local logTag = 'bcm_weatherApp'

-- Track last notified state to avoid duplicate notifications
lastNotifiedState = nil

-- Register weather app when career modules are ready
onCareerModulesActivated = function()
  -- Register weather app on phone
  if bcm_appRegistry then
    bcm_appRegistry.register({
      id = "weather",
      name = "Weather",
      component = "PhoneWeatherApp",
      iconName = "weather",
      color = "#4A90E2",
      visible = true,
      order = 15
    })
  end

  log('I', logTag, 'Weather app registered')
end

-- Send current weather + forecast data to Vue
sendWeatherToVue = function()
  local current = nil
  if extensions.bcm_weather then
    current = extensions.bcm_weather.getWeatherInfo()
  end

  local forecast = nil
  if extensions.bcm_weatherForecast then
    forecast = extensions.bcm_weatherForecast.getForecast()
  end

  guihooks.trigger('BCMWeatherForecast', {
    current = current or {},
    forecast = forecast or {}
  })

  log('D', logTag, 'Weather data sent to Vue')
end

-- Handle weather state changes for severe weather notifications
-- Called from bcm_weather via guihooks or direct call
onWeatherStateChanged = function(state)
  if not state then return end

  -- Only notify for severe weather (storm, snow, blizzard)
  if state ~= "storm" and state ~= "snow" and state ~= "blizzard" then
    lastNotifiedState = nil
    return
  end

  -- Don't notify twice for same state
  if state == lastNotifiedState then return end
  lastNotifiedState = state

  -- Send notification
  if bcm_notifications then
    if state == "storm" then
      bcm_notifications.send({
        titleKey = "weather.alert.title",
        bodyKey = "weather.alert.storm",
        title = "Weather Alert",
        body = "Thunderstorm approaching - drive carefully!",
        type = "warning",
        duration = 8000
      })
    elseif state == "snow" then
      bcm_notifications.send({
        titleKey = "weather.alert.title",
        bodyKey = "weather.alert.snow",
        title = "Weather Alert",
        body = "Snow expected - roads will be slippery!",
        type = "warning",
        duration = 8000
      })
    elseif state == "blizzard" then
      bcm_notifications.send({
        titleKey = "weather.alert.title",
        bodyKey = "weather.alert.blizzard",
        title = "Weather Alert",
        body = "BLIZZARD WARNING - Extreme conditions, avoid driving!",
        type = "warning",
        duration = 12000
      })
    end
  end
end

-- Listen for weather updates to trigger notifications and push data to Vue
M.onUpdate = function(dtReal)
  -- Check for weather state changes by polling bcm_weather
  if extensions.bcm_weather then
    local info = extensions.bcm_weather.getWeatherInfo()
    if info and info.state then
      onWeatherStateChanged(info.state)
    end
  end
end

-- Public API
M.onCareerModulesActivated = onCareerModulesActivated
M.sendWeatherToVue = sendWeatherToVue

return M
