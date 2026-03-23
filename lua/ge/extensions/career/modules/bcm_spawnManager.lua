-- BCM Spawn Manager
-- Handles player spawn on new career start and initial time setup
-- Extension name: career_modules_bcm_spawnManager
-- Auto-loaded by career core from /lua/ge/extensions/career/modules/
-- KEY DESIGN: Career modules are loaded inside the startFreeroam callback,
-- which fires AFTER onWorldReadyState(2). This means career modules never
-- receive onWorldReadyState(2) on the initial career load.
-- Solution: Use onCareerActive (which fires INSIDE the callback, after modules
-- load) with a core_jobsystem delayed job. The world IS ready at this point
-- because the startFreeroam callback only fires after the level loads.
-- onWorldReadyState is kept ONLY as a fallback for level switches during
-- an active career (not the initial load).

local M = {}

-- Module metadata
M.debugName = "BCM Spawn Manager"
M.debugOrder = 50
M.dependencies = {'career_career', 'freeroam_facilities'}

-- Constants
-- Resolved dynamically from bcm_garages config (isStarterGarage flag)
-- Falls back to bcmGarage_starter if BCM garages module is not loaded yet
local FALLBACK_STARTER_GARAGE_ID = "bcmGarage_starter"
-- BeamNG tod.time: 0.0 = NOON, 0.5 = midnight, 1.0 = noon (Torque3D solar cycle)
-- Formula: visual_hours = (tod.time * 24 + 12) % 24
-- Reverse: tod.time = (desired_hour - 12) / 24
-- mainLevel.lua night range 0.21-0.77 = 5 PM to 6:30 AM visual
-- 0.0 = 12:00 (noon) = maximum daylight, cycle frozen for testing
local INITIAL_TIME = 0.0
-- Hardcoded fallback position from facilities.sites.json for bcmGarage_starter_parking1
-- Used only if the facilities API fails to resolve parking spots
local FALLBACK_POS = {-680, 520, 114}
local FALLBACK_ROT = {0, 0, -0.40, 0.92}

-- Custom tutorial spawn position (player spawns on foot facing toward Miramar)
-- Player position
local TUTORIAL_PLAYER_POS = vec3(-1179.03, 1877.92, 96.04)
-- Direction vector toward Miramar at (-1174.78, 1873.62, 94.71):
-- Original angle was 180° off in-game. Rotated by π:
-- angle = atan2(-4.30, 4.25) + π = 2.351 rad
-- half_angle = 1.175 rad -> sin=0.923, cos=0.386
local TUTORIAL_PLAYER_ROT = quat(0, 0, 0.923, 0.386)

-- Miramar constants (grandfather's car — always granted on new career)
local MIRAMAR_MODEL = "miramar"
local MIRAMAR_CONFIG = "vehicles/miramar/mysummer_starter.pc"
local MIRAMAR_POS = vec3(-1174.78, 1873.62, 94.71)
local MIRAMAR_ROT = quat(0.0016, -0.0007, 0.4052, 0.9142)
local MIRAMAR_MILEAGE = 900000000 -- 900k km in meters (worn daily driver from grandpa)

-- Forward declarations
local initializeNewCareer
local spawnAtStarterGarage
local spawnMiramarAtLocation
local grantMiramarToGarage
local initializeTime
local removeDefaultVehicle
local exitLoadingScreen
local onCareerActive
local onWorldReadyState

-- Private state
local logTag = 'bcm_spawnManager'
local isNewCareer = false
local initialized = false

-- Remove ALL non-traffic vehicles (including the default Covet)
-- BeamNG spawns a default vehicle during level load even with spawn.preventPlayerSpawning
removeDefaultVehicle = function()
 local removed = false
 -- Remove all non-traffic vehicles (same pattern as career.lua removeNonTrafficVehicles)
 local safeIds = {}
 if gameplay_traffic then
 safeIds = gameplay_traffic.getTrafficList(true) or {}
 end
 if gameplay_parking then
 local parked = gameplay_parking.getParkedCarsList(true) or {}
 for _, id in ipairs(parked) do
 table.insert(safeIds, id)
 end
 end

 for i = be:getObjectCount() - 1, 0, -1 do
 local obj = be:getObject(i)
 if obj then
 local objId = obj:getID()
 local isSafe = false
 for _, safeId in ipairs(safeIds) do
 if safeId == objId then
 isSafe = true
 break
 end
 end
 if not isSafe then
 obj:delete()
 log("I", logTag, "Removed vehicle (id: " .. objId .. ")")
 removed = true
 end
 end
 end
 return removed
end

-- Spawn player at starter garage in walking mode
spawnAtStarterGarage = function()
 local pos, rot

 -- Resolve starter garage: prefer BCM config, fall back to hardcoded
 local starterGarageId = FALLBACK_STARTER_GARAGE_ID
 if bcm_garages then
 local allDefs = bcm_garages.getAllDefinitions()
 if allDefs then
 for garageId, def in pairs(allDefs) do
 if def.isStarterGarage == true then
 starterGarageId = garageId
 break
 end
 end
 end
 end
 log("I", logTag, "Resolved starter garage: " .. starterGarageId)

 local garage = freeroam_facilities.getFacility("garage", starterGarageId)
 if garage then
 local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(garage)
 if parkingSpots and parkingSpots[1] then
 pos = parkingSpots[1].pos
 rot = parkingSpots[1].rot or quat(0, 0, 0, 1)
 log("I", logTag, "Using parking spot from facilities API")
 end
 end

 -- Fallback to hardcoded coordinates if facilities API failed
 if not pos then
 log("W", logTag, "Facilities API failed, using fallback coordinates for " .. starterGarageId)
 pos = vec3(FALLBACK_POS[1], FALLBACK_POS[2], FALLBACK_POS[3])
 rot = quat(FALLBACK_ROT[1], FALLBACK_ROT[2], FALLBACK_ROT[3], FALLBACK_ROT[4])
 end

 -- Spawn player in first-person walking mode at garage position
 gameplay_walk.setWalkingMode(true, pos, rot)
 log("I", logTag, "Player spawned at starter garage: " .. starterGarageId)
 return true
end

-- Set initial time for new career
-- The TimeOfDay object may not be indexed in the scenetree during early
-- initialization, so we retry with a separate job if the first attempt fails.
initializeTime = function()
 local tod = scenetree.tod
 if tod then
 tod.time = INITIAL_TIME
 -- tod.play is managed by bcm_timeSystem (sets to true on career activation)
 log("I", logTag, "Time set to noon (tod=0.0 = 12:00 visual)")
 return true
 end

 log("W", logTag, "scenetree.tod not available yet, scheduling retry job")
 core_jobsystem.create(function(job)
 for attempt = 1, 10 do
 job.sleep(0.5)
 local retryTod = scenetree.tod
 if retryTod then
 retryTod.time = INITIAL_TIME
 -- tod.play is managed by bcm_timeSystem
 log("I", logTag, "Time set on retry " .. attempt .. " (tod=0.0 = 12:00 visual)")
 return
 end
 end
 log("E", logTag, "Failed to set time: TimeOfDay object not found after 10 retries")
 end)
 return false
end

-- Exit the career loading screen (normally onVehicleGroupSpawned handles this,
-- but in walking mode with no vehicle, we need to do it ourselves)
exitLoadingScreen = function()
 core_jobsystem.create(function(job)
 job.sleep(1.0) -- Brief delay for scene to settle
 commands.setGameCamera(true)
 if core_gamestate.getLoadingStatus("careerLoading") then
 core_gamestate.requestExitLoadingScreen("careerLoading")
 log("I", logTag, "Exited career loading screen (walking mode)")
 end
 end)
end

-- Spawn Miramar physically at the tutorial location (with tutorial active)
spawnMiramarAtLocation = function()
 log('I', logTag, 'Spawning Miramar at tutorial location')
 local ok, vehObj = pcall(function()
 return core_vehicles.spawnNewVehicle(MIRAMAR_MODEL, {
 config = MIRAMAR_CONFIG,
 pos = MIRAMAR_POS,
 rot = MIRAMAR_ROT,
 autoEnterVehicle = false,
 cling = true
 })
 end)

 if ok and vehObj then
 local vehId = vehObj:getID()
 -- Grandpa's Miramar: 900k km AND poorly maintained. visualValue 0.25 gives
 -- the beat-up paintwork look. getVisualValueFromMileage would give 0.81 which
 -- is too clean for a neglected barn find.
 local visualValue = 0.25
 vehObj:queueLuaCommand(string.format(
 "partCondition.initConditions(nil, %d, nil, %f) obj:queueGameEngineLua('bcm_tutorial.onMiramarSpawnFinished(%d)')",
 MIRAMAR_MILEAGE, visualValue, vehId
 ))
 core_vehicleBridge.executeAction(vehObj, 'setIgnitionLevel', 0)
 log('I', logTag, 'Miramar spawned, waiting for partCondition callback (vehId=' .. tostring(vehId) .. ')')
 else
 log('E', logTag, 'Miramar physical spawn failed: ' .. tostring(vehObj))
 -- Fallback: grant to garage without physical spawn
 grantMiramarToGarage()
 end
end

-- Grant Miramar to inventory without physical spawn (debug mode / no tutorial)
-- Uses a temporary spawn + immediate despawn to go through the full parts pipeline
grantMiramarToGarage = function()
 log('I', logTag, 'Granting Miramar to garage (no physical spawn)')
 local ok, vehObj = pcall(function()
 return core_vehicles.spawnNewVehicle(MIRAMAR_MODEL, {
 config = MIRAMAR_CONFIG,
 pos = vec3(0, 0, -100), -- spawn underground, will be despawned
 autoEnterVehicle = false,
 })
 end)

 if ok and vehObj then
 local vehId = vehObj:getID()
 -- Grandpa's Miramar: 900k km AND poorly maintained. visualValue 0.25 gives
 -- the beat-up paintwork look. getVisualValueFromMileage would give 0.81 which
 -- is too clean for a neglected barn find.
 local visualValue = 0.25
 -- initConditions → callback → addVehicle → removeVehicleObject (despawn physical)
 vehObj:queueLuaCommand(string.format(
 "partCondition.initConditions(nil, %d, nil, %f) obj:queueGameEngineLua('bcm_tutorial.onMiramarSpawnFinished(%d)')",
 MIRAMAR_MILEAGE, visualValue, vehId
 ))
 -- Schedule despawn after registration completes
 core_jobsystem.create(function(job)
 job.sleep(3.0)
 if career_modules_inventory then
 local vehicles = career_modules_inventory.getVehicles()
 for invId, veh in pairs(vehicles or {}) do
 if veh.niceName and veh.niceName:lower():find("miramar") then
 career_modules_inventory.removeVehicleObject(invId)
 log('I', logTag, 'Miramar physical object despawned (garage-only mode)')
 break
 end
 end
 end
 end)
 else
 log('E', logTag, 'Miramar grant-to-garage also failed: ' .. tostring(vehObj))
 end
end

-- Main initialization sequence for a new career
-- Called from either onCareerActive (primary) or onWorldReadyState (fallback)
initializeNewCareer = function()
 if initialized then
 log("I", logTag, "Already initialized, skipping")
 return
 end
 initialized = true
 isNewCareer = false

 log("I", logTag, "=== Initializing new career spawn ===")

 -- 1. Remove default-spawned vehicles (Covet etc.)
 removeDefaultVehicle()

 -- 2. Spawn player: custom tutorial position for new career, starter garage otherwise
 if bcm_tutorial and not (bcm_settings and bcm_settings.getSetting("debugMode")) then
 -- tutorial spawn at custom coordinates facing Miramar
 gameplay_walk.setWalkingMode(true, TUTORIAL_PLAYER_POS, TUTORIAL_PLAYER_ROT)
 log("I", logTag, "Player spawned at tutorial position (facing Miramar)")
 else
 -- Debug mode or no tutorial module: use standard starter garage
 spawnAtStarterGarage()
 end

 -- 3. Set initial time to mid-afternoon
 initializeTime()

 -- 4. Starter garage is handled by bcm_garages.grantStarterGarageIfNeeded()
 -- which runs during onCareerModulesActivated (before this delayed job).
 -- Do NOT call purchaseDefaultGarage() here — it buys Sealbrick1058 (vanilla default).

 -- 5. Spawn Miramar (grandfather's car — always on new career)
 local hasTutorial = bcm_tutorial and not (bcm_settings and bcm_settings.getSetting("debugMode"))
 if hasTutorial then
 spawnMiramarAtLocation() -- physical spawn at tutorial coords
 else
 grantMiramarToGarage() -- inventory only, assigned to starter garage
 end

 -- 6. Exit career loading screen for walking mode (no vehicle to trigger
 -- onVehicleGroupSpawned, so we handle it ourselves)
 -- Always exit loading screen to avoid getting stuck
 exitLoadingScreen()

 -- 7. Emit hook for tutorial system
 extensions.hook("onFirstCareerStart")
 log("I", logTag, "=== First career start complete ===")
end

-- Hook: called after career activates
-- For new careers, this fires INSIDE the startFreeroam callback (after level loads).
-- The world IS ready at this point, but we use a brief job delay to let the
-- scene fully settle (vehicle spawns, physics init, etc.)
onCareerActive = function(active, isNewSave)
 if not active then
 isNewCareer = false
 initialized = false
 return
 end

 if not isNewSave then
 log("I", logTag, "Existing career loaded, checking player state")
 -- Ensure player has a valid position on existing career load
 -- If no vehicle is spawned, place player at last garage in walking mode
 core_jobsystem.create(function(job)
 job.sleep(3.0) -- Wait for inventory to spawn vehicles
 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then
 log("W", logTag, "No player vehicle after career load, placing at starter garage")
 spawnAtStarterGarage()
 else
 log("I", logTag, "Player vehicle found (id: " .. playerVehId .. "), position OK")
 end
 end)
 return
 end

 isNewCareer = true
 log("I", logTag, "New career detected in onCareerActive, scheduling initialization")

 -- Use a delayed job: the world is loaded (we're in the startFreeroam callback),
 -- but a brief delay ensures scene tree, facilities, and vehicle spawns are settled.
 -- Career loading screen is still showing, so the player won't see the transition.
 core_jobsystem.create(function(job)
 job.sleep(2.0) -- Wait for scene to fully settle
 log("I", logTag, "Delayed job executing, isNewCareer=" .. tostring(isNewCareer))
 if isNewCareer then
 initializeNewCareer()
 end
 end)
end

-- Hook: fallback for level switches during active career
-- NOT used for initial career load (modules aren't loaded when this fires)
onWorldReadyState = function(state)
 if state ~= 2 then return end
 if not career_career.isActive() then return end
 if not isNewCareer then return end

 log("I", logTag, "onWorldReadyState fallback triggered")
 initializeNewCareer()
end

M.onCareerActive = onCareerActive
M.onWorldReadyState = onWorldReadyState

return M
