-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- BCM: linearTutorial stub override
-- Neutralizes the entire tutorial system by returning safe defaults.
-- Combined with tutorialEnabled=false and boughtStarterVehicle=true,
-- this fully eliminates all intro/tutorial flow.

local M = {}

M.dependencies = {'career_career'}

local logTag = 'bcm_linearTutorial'

-- Always return "tutorial not active"
local function isLinearTutorialActive()
  return false
end

-- Return high step number (tutorial completed long ago)
local function getLinearStep()
  return 999  -- Well beyond any tutorial step
end

-- All tutorial flags return true (all milestones completed)
-- Known flags: purchasedFirstCar, quickTravelEnabled, partShoppingComplete, tuningComplete
local function getTutorialFlag(flagName)
  return true
end

-- No-op intro popups
-- Called by: delivery/progress.lua, delivery/cargoScreen.lua
local function introPopup(name, force)
  -- Do nothing - suppress popup
end

-- Suppress welcome screen
local function showNonTutorialWelcomeSplashscreen()
  -- Do nothing
end

-- Lifecycle hooks (no-ops for stub)
local function onCareerActivated()
  log("I", logTag, "Tutorial system neutralized by BCM stub")
end

local function onCareerActive(active)
  -- Nothing to clean up in a stub
end

-- Public API
M.isLinearTutorialActive = isLinearTutorialActive
M.getLinearStep = getLinearStep
M.getTutorialFlag = getTutorialFlag
M.introPopup = introPopup
M.showNonTutorialWelcomeSplashscreen = showNonTutorialWelcomeSplashscreen
M.onCareerActivated = onCareerActivated
M.onCareerActive = onCareerActive

return M
