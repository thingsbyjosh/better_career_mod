-- BCM Clock App Extension
-- Registers the Clock app on the phone for time display and sleep functionality.
-- Extension name: bcm_clockApp

local M = {}

-- Forward declarations
local onCareerModulesActivated

-- Register clock app when career modules are ready
onCareerModulesActivated = function()
  -- Register clock app on phone
  if bcm_appRegistry then
    bcm_appRegistry.register({
      id = "clock",
      name = "Clock",
      component = "PhoneClockApp",
      iconName = "clock",
      color = "#FF9500",
      visible = true,
      order = 5  -- Before bank app (order 1)
    })
  end

  log('I', 'bcm_clockApp', 'Clock app registered')
end

-- Public API
M.onCareerModulesActivated = onCareerModulesActivated

return M
