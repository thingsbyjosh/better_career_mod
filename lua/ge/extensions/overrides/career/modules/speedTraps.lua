-- BCM Speed Traps Override
-- Overrides vanilla career/modules/speedTraps.lua to route camera fines through
-- BCM's economy system (banking, ledger, notifications) instead of vanilla's trivial fines.
-- Radar Cameras — fixed speed cameras + red-light cameras.
-- Extension name: career_modules_speedTraps (override)

local M = {}

-- ============================================================================
-- Forward declarations
-- ============================================================================
local onSpeedTrapTriggered
local onRedLightCamTriggered
local hasLicensePlate
local getInventoryIdFromVehId
local onCareerModulesActivated
local onExtensionUnloaded

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_speedTraps'
local COOLDOWN_SECONDS = 45 -- Same camera cannot fine twice within 45 seconds

-- ============================================================================
-- Private state
-- ============================================================================
local activated = false
local cooldownTimers = {} -- { [triggerName] = os.clock() timestamp }

-- ============================================================================
-- Helpers
-- ============================================================================

-- Convert vehId to inventoryId (same as vanilla pattern)
getInventoryIdFromVehId = function(vehId)
 local invId = nil
 pcall(function()
 if career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
 invId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
 end
 end)
 return invId
end

-- License plate check — matches VANILLA pattern exactly:
-- Iterates ALL parts in partInventory, filters by part.location == inventoryId,
-- checks part.name for "licenseplate" substring.
hasLicensePlate = function(inventoryId)
 if not inventoryId then return false end
 local hasPlate = false
 pcall(function()
 if career_modules_partInventory and career_modules_partInventory.getInventory then
 for partId, part in pairs(career_modules_partInventory.getInventory()) do
 if part.location == inventoryId then
 if string.find(part.name, "licenseplate") then
 hasPlate = true
 break
 end
 end
 end
 end
 end)
 return hasPlate
end

-- ============================================================================
-- Speed camera handler
-- Vanilla hook signature: onSpeedTrapTriggered(speedTrapData, playerSpeed, overSpeed)
-- speedTrapData fields: subjectID, triggerName, speedLimit, etc.
-- ============================================================================

onSpeedTrapTriggered = function(speedTrapData, playerSpeed, overSpeed)
 if not activated then return end
 if not speedTrapData then return end

 log('I', logTag, '[SPEEDCAM DEBUG] onSpeedTrapTriggered fired! triggerName=' .. tostring(speedTrapData.triggerName)
 .. ' subjectID=' .. tostring(speedTrapData.subjectID) .. ' vehId=' .. tostring(speedTrapData.vehId)
 .. ' overSpeed=' .. tostring(overSpeed) .. ' playerSpeed=' .. tostring(playerSpeed))

 -- Skip radar zone triggers — handled by bcm_police.onBeamNGTrigger instead
 local trigName = speedTrapData.triggerName or ""
 if string.find(trigName, "bcmRadar_") then
 log('D', logTag, '[SPEEDCAM DEBUG] Skipping radar zone trigger: ' .. trigName)
 return
 end

 -- Vanilla uses subjectID, not vehId
 local vehId = speedTrapData.subjectID or speedTrapData.vehId
 if not vehId then
 log('I', logTag, '[SPEEDCAM DEBUG] No vehId found in speedTrapData, keys: ' .. table.concat((function() local k={} for key,_ in pairs(speedTrapData) do table.insert(k, tostring(key)) end return k end)(), ','))
 return
 end

 -- Only fine the player vehicle, not NPCs
 local playerVehId = be:getPlayerVehicleID(0)
 if vehId ~= playerVehId then
 log('D', logTag, '[SPEEDCAM DEBUG] Not player vehicle: vehId=' .. tostring(vehId) .. ' playerVehId=' .. tostring(playerVehId))
 return
 end

 -- Career must be active
 local careerActive = false
 pcall(function()
 if career_career and career_career.isActive() then careerActive = true end
 end)
 if not careerActive then
 log('I', logTag, '[SPEEDCAM DEBUG] Career not active')
 return
 end

 -- Per-camera cooldown check
 local now = os.clock()
 local triggerName = speedTrapData.triggerName or 'unknown'
 if cooldownTimers[triggerName] and (now - cooldownTimers[triggerName]) < COOLDOWN_SECONDS then
 log('D', logTag, 'Cooldown active for speed camera: ' .. triggerName)
 return
 end

 -- License plate check — no plate means camera cannot identify vehicle
 local inventoryId = getInventoryIdFromVehId(vehId)
 if not hasLicensePlate(inventoryId) then
 log('I', logTag, 'No license plate — speed camera cannot identify vehicle at ' .. triggerName)
 return
 end

 -- overSpeed comes as separate parameter in m/s (vanilla hook signature)
 local overSpeedKmh = math.floor((overSpeed or 0) * 3.6)
 if overSpeedKmh <= 0 then return end -- Not actually speeding

 -- Get tiered fine amount
 local fineAmount = 50000 -- fallback
 pcall(function()
 if bcm_fines and bcm_fines.getSpeedFineTier then
 fineAmount = bcm_fines.getSpeedFineTier(overSpeedKmh)
 end
 end)

 -- Issue the fine through BCM economy
 pcall(function()
 if bcm_fines and bcm_fines.issueCameraFine then
 bcm_fines.issueCameraFine('speed_radar', fineAmount, triggerName, overSpeedKmh)
 end
 end)

 -- Set cooldown
 cooldownTimers[triggerName] = now

 -- Camera flash: audio + visual white flash overlay
 Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Speedcam_Snapshot')
 pcall(function()
 local js = [[
 (function(){
 var f=document.createElement('div');
 f.style.cssText='position:fixed;top:0;left:0;width:100vw;height:100vh;background:white;opacity:0.9;z-index:999999;pointer-events:none;transition:opacity 0.4s ease-out';
 document.body.appendChild(f);
 setTimeout(function(){f.style.opacity='0'},50);
 setTimeout(function(){f.remove()},500);
 })();
 ]]
 be:executeJS(js)
 end)

 log('I', logTag, string.format('Speed camera %s: %d km/h over limit, fine $%d', triggerName, overSpeedKmh, math.floor(fineAmount / 100)))
end

-- ============================================================================
-- Red-light camera handler
-- Vanilla hook signature: onRedLightCamTriggered(data, vehSpeed)
-- data fields: subjectID, triggerName, signalName, etc.
-- ============================================================================

onRedLightCamTriggered = function(data, vehSpeed)
 if not activated then return end
 if not data then return end

 -- Vanilla uses subjectID
 local vehId = data.subjectID
 if not vehId then return end

 -- Only fine the player vehicle, not NPCs
 local playerVehId = be:getPlayerVehicleID(0)
 if vehId ~= playerVehId then return end

 -- Career must be active
 local careerActive = false
 pcall(function()
 if career_career and career_career.isActive() then careerActive = true end
 end)
 if not careerActive then return end

 -- Per-camera cooldown check
 local now = os.clock()
 local triggerName = data.triggerName or 'unknown'
 if cooldownTimers[triggerName] and (now - cooldownTimers[triggerName]) < COOLDOWN_SECONDS then
 log('D', logTag, 'Cooldown active for red-light camera: ' .. triggerName)
 return
 end

 -- License plate check
 local inventoryId = getInventoryIdFromVehId(vehId)
 if not hasLicensePlate(inventoryId) then
 log('I', logTag, 'No license plate — red-light camera cannot identify vehicle at ' .. triggerName)
 return
 end

 -- Fixed $750 fine for red-light violation
 local fineAmount = 75000

 -- Issue the fine through BCM economy
 pcall(function()
 if bcm_fines and bcm_fines.issueCameraFine then
 bcm_fines.issueCameraFine('red_light_camera', fineAmount, triggerName, nil)
 end
 end)

 -- Set cooldown
 cooldownTimers[triggerName] = now

 -- Camera flash: audio + visual white flash overlay
 Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Speedcam_Snapshot')
 pcall(function()
 local js = [[
 (function(){
 var f=document.createElement('div');
 f.style.cssText='position:fixed;top:0;left:0;width:100vw;height:100vh;background:white;opacity:0.9;z-index:999999;pointer-events:none;transition:opacity 0.4s ease-out';
 document.body.appendChild(f);
 setTimeout(function(){f.style.opacity='0'},50);
 setTimeout(function(){f.remove()},500);
 })();
 ]]
 be:executeJS(js)
 end)

 log('I', logTag, string.format('Red-light camera %s: fine $%d', triggerName, math.floor(fineAmount / 100)))
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

onCareerModulesActivated = function()
 activated = true
 cooldownTimers = {}
 log('I', logTag, 'BCM Speed Traps override activated — camera fines routed through BCM economy')
end

onExtensionUnloaded = function()
 activated = false
 cooldownTimers = {}
end

-- ============================================================================
-- M table exports
-- ============================================================================

-- Hook handlers (BeamNG dispatches these from gameplay/speedTraps.lua)
M.onSpeedTrapTriggered = onSpeedTrapTriggered
M.onRedLightCamTriggered = onRedLightCamTriggered

-- Lifecycle
M.onCareerModulesActivated = onCareerModulesActivated
M.onExtensionUnloaded = onExtensionUnloaded

return M
