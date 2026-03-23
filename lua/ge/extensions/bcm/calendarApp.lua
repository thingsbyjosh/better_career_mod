-- BCM Calendar App Extension
-- Registers the Calendar app on the phone for calendar event display.
-- Extension name: bcm_calendarApp

local M = {}

-- Forward declarations
local onCareerModulesActivated

-- Register calendar app when career modules are ready
onCareerModulesActivated = function()
 -- Register calendar app on phone
 if bcm_appRegistry then
 bcm_appRegistry.register({
 id = "calendar",
 name = "Calendar",
 component = "PhoneCalendarApp",
 iconName = "calendar",
 color = "#FF3B30",
 visible = true,
 order = 3
 })
 end

 log('I', 'bcm_calendarApp', 'Calendar app registered')
end

-- Public API
M.onCareerModulesActivated = onCareerModulesActivated

return M
