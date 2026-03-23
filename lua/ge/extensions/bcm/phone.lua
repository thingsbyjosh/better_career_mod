-- BCM Phone Extension
-- Handles phone toggle, speed monitoring, and auto-close behavior.
-- Follows RLS gameplay/phone.lua pattern with improved responsiveness.

local M = {}

-- Forward declarations
local togglePhone
local onUpdate
local onUIPlayStateChanged
local onExtensionLoaded

-- State
local isPhoneOpen = false

-- Speed monitoring config
local speedUnit = 2.2369362921 -- m/s to MPH conversion
local updateTimer = 0
local updateInterval = 0.5 -- Check every 500ms (more responsive than RLS's 2.5s)
local SPEED_THRESHOLD_MPH = 5

-- Helper: Get current vehicle speed in MPH
local function getCurrentSpeedMPH()
 local vehicleId = be:getPlayerVehicleID(0)
 if not vehicleId or vehicleId == -1 then
 return 0
 end

 local velocity = be:getObjectVelocityXYZ(vehicleId)
 return math.abs(velocity) * speedUnit
end

-- Toggle phone open/close
togglePhone = function(reason)
 reason = reason or "user_input"

 -- Block phone during tutorial steps 1-5
 if bcm_tutorial and bcm_tutorial.isPhoneBlocked and bcm_tutorial.isPhoneBlocked() then
 ui_message("Phone locked during tutorial.", 3, "info", "info")
 return
 end

 if isPhoneOpen then
 -- Close phone
 isPhoneOpen = false
 guihooks.trigger("BCMPhoneToggle", { action = "close", reason = reason })
 else
 -- Check speed before opening
 local speedMPH = getCurrentSpeedMPH()

 if speedMPH > SPEED_THRESHOLD_MPH then
 -- Vehicle is moving - don't allow phone to open
 ui_message("You must be stationary to open the phone.", 3, "info", "info")
 return
 end

 -- Open phone
 isPhoneOpen = true
 guihooks.trigger("BCMPhoneToggle", { action = "open", reason = reason })
 extensions.hook("onBCMPhoneOpened")
 end
end

-- Update loop - monitors speed and auto-closes phone if moving
onUpdate = function(dt)
 if not isPhoneOpen then
 return
 end

 -- Timer-based speed check (not every frame)
 updateTimer = updateTimer + dt
 if updateTimer < updateInterval then
 return
 end
 updateTimer = 0

 -- Check if vehicle is moving
 local speedMPH = getCurrentSpeedMPH()

 if speedMPH > SPEED_THRESHOLD_MPH then
 -- Vehicle exceeded speed threshold - auto-close phone
 isPhoneOpen = false
 guihooks.trigger("BCMPhoneToggle", { action = "close", reason = "speed_exceeded" })
 ui_message("Phone closed due to movement.", 3, "info", "info")
 end
end

-- Reset phone state when UI play state changes (pause menu, etc.)
onUIPlayStateChanged = function(changed)
 if isPhoneOpen then
 isPhoneOpen = false
 guihooks.trigger("BCMPhoneToggle", { action = "close", reason = "ui_state_changed" })
 end
end

-- Extension loaded - reset state
onExtensionLoaded = function()
 isPhoneOpen = false
 updateTimer = 0
end

-- Public API
M.togglePhone = togglePhone
M.onUpdate = onUpdate
M.onUIPlayStateChanged = onUIPlayStateChanged
M.onExtensionLoaded = onExtensionLoaded

-- Read-only state getter (for debugging/logging)
M.isPhoneOpen = function()
 return isPhoneOpen
end

return M
