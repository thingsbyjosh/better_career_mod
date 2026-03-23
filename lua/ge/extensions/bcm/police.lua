-- BCM Police Orchestrator
-- Central police module: vehicle pool, damage tracking, 3-level escalation,
-- pursuit lifecycle hooks, FMOD queue, recycling, interceptors, save/load.
-- Uses vanilla gameplay_police for all core pursuit logic (no override).
-- Extension name: bcm_police

local M = {}

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
-- Core pursuit lifecycle
local onPursuitAction
local onPursuitUpdate
local onPatrolUpdate
local configurePursuitVars
-- Save/load
local savePoliceData
local loadPoliceData
-- Lifecycle hooks
local onCareerModulesActivated
local onSaveCurrentSaveSlot
local onSettingChanged
local onTrafficStarted
local onTrafficStopped
local onClientEndMission
local onVehicleGroupSpawned
-- Vehicle pool
local validateConfigPool
local spawnPolicePool
-- FMOD queue
local queueFmodAction
local processFmodQueue
local executeFmodAction
-- Damage tracking & escalation
local checkDamageCosts
local accumulatePursuitScore
local applyLevelAggression
-- Recycling
local checkRecycling
local recycleVehicle
-- Interceptors
local spawnInterceptor
local cleanupInterceptors
local countInterceptors
local findInactivePoolMember
-- Orphan cleanup
local cleanupOrphanedPolice
-- State management
local resetBcmPursuitState
local getCurrentLevel
local getDamageCost
-- Mobile radar
local loadRadarSpots
local spawnRadarCars
local despawnRadarCars
local onBeamNGTrigger
local rotateRadarSpots
local selectRadarSpots
-- No-plate detection
local checkNoPlate
local hasLicensePlate
-- Spike strips
local deploySpikeStrips
local cleanupSpikeStrips
-- Flexible spawn mode
local deactivateReserveUnit
local activateReserveUnit
local updateReinforcementTimer
local updateReserveDeactivation
local getReinforcementInterval
local isFlexibleMode
local getFlexPoolVehIds
-- Citizen reports (witness-triggered pursuit)
local checkCitizenReports
local checkReportedSighting
local getSpeedLimitAtPosition
-- Debug commands
local spawnPolice
local triggerPursuit
local resetPursuit
local printStatus

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_police'
local SAVE_FILE = "police.json"

-- Stuck detection
local STUCK_SPEED_THRESHOLD = 3
local STUCK_TIME_THRESHOLD = 10
local PATROL_STUCK_THRESHOLD = 60
local MAX_PATROL_RESPAWNS = 3
local PATROL_CHECK_INTERVAL = 5

-- 3-level pursuit: only level 1 by score, levels 2-3 by damage cost
-- IMPORTANT: each value must be strictly greater than the previous, otherwise
-- vanilla setPursuitMode sets score=scoreLevels[mode] which auto-triggers the next level
local PURSUIT_SCORE_LEVELS = {100, 1e9, 2e9}

-- Damage cost thresholds for level escalation
-- Level 1 = default (score-based), Level 2 at $20k, Level 3 at $80k
local BCM_DAMAGE_LEVELS = {0, 20000, 80000}

-- Aggression per pursuit level (vanilla follow=level1-2, chase=level3)
local LEVEL_AGGRESSION = {0.4, 0.65, 1.0}

-- Passive score injection (keeps score growing during pursuit)
local PASSIVE_SCORE_BASE = 8
local PASSIVE_SCORE_INTERVAL = 5.0
local PASSIVE_SCORE_MULTIPLIER = {1, 3, 8}

-- Continuous offense score bonuses
local OFFENSE_SCORE_SPEEDING = 15
local OFFENSE_SCORE_FAST = 30
local OFFENSE_SCORE_RECKLESS = 40
local OFFENSE_SPEED_THRESHOLDS = {20, 35, 50}
local OFFENSE_SPEED_SCORES = {OFFENSE_SCORE_SPEEDING, OFFENSE_SCORE_FAST, OFFENSE_SCORE_RECKLESS}
local OFFENSE_SCORE_WRONG_WAY = 25
local OFFENSE_SCORE_HIT_POLICE = 80

-- Damage cost tracking
local POLICE_VEHICLE_VALUE = 30000
local CIVILIAN_VEHICLE_VALUE = 22000
local DAMAGE_DELTA_THRESHOLD = 50
local DAMAGE_TOTALED_THRESHOLD = 50000
local DAMAGE_CHECK_INTERVAL = 0.5

-- Recycling (teleport far/damaged police closer)
local RECYCLE_DISTANCE = 600
local RECYCLE_DAMAGE = 35000
local RECYCLE_CHECK_INTERVAL = 3.0
local RECYCLE_DAMAGE_COOLDOWN = 12
local RECYCLE_SAFE_ZONE = 200
local RECYCLE_COOLDOWN = 20

-- Interceptors (level 3 head-on charge)
local INTERCEPTOR_INTERVAL = 35
local INTERCEPTOR_SPAWN_DIST_MIN = 300
local INTERCEPTOR_SPAWN_DIST_MAX = 500
local INTERCEPTOR_AGGRESSION = 1.0
local INTERCEPTOR_PASS_DISTANCE = 80
local INTERCEPTOR_MAX_ACTIVE = 2

-- FMOD queue (serializes siren/teleport operations to prevent FMOD heap corruption)
local FMOD_TICK_INTERVAL = 0.5

-- Spawn group name for core_multiSpawn identification
local BCM_POLICE_GROUP_NAME = 'bcmPolice'

-- Mobile radar (parked police cars at fixed spots)
local RADAR_DEFAULT_SPEED_LIMIT = 80 -- km/h fallback when spot has no speedLimit
local RADAR_FINE_COOLDOWN = 60 -- seconds between fines from same radar trigger
local RADAR_ROTATION_HOURS = 8 -- game hours between spot rotations
local RADAR_MAX_CARS = 2 -- number of radar cars active at once

-- Default radar spots (fallback if no devtool-exported JSON found)
-- Each spot has speedLimit in km/h — radar fines when player exceeds it
local DEFAULT_RADAR_SPOTS = {
 { pos = {-760, 135, 51.5}, heading = 0.8, speedLimit = 80 }, -- Highway near town entrance
 { pos = {-380, 640, 75.3}, heading = 2.1, speedLimit = 60 }, -- Industrial district road
 { pos = {120, -290, 103.5}, heading = -0.5, speedLimit = 80 }, -- Mountain pass pullover
 { pos = {-540, -480, 38.2}, heading = 1.5, speedLimit = 80 }, -- Coast highway shoulder
 { pos = {380, 250, 119.0}, heading = 3.0, speedLimit = 60 }, -- Rural road by farm
 { pos = {-190, 890, 52.1}, heading = -1.2, speedLimit = 60 }, -- Port area entrance
}

-- Active radar spots (loaded from JSON or defaults)
local RADAR_SPOTS = DEFAULT_RADAR_SPOTS

-- Helper: count entries in a hash table
local function tableSize(t) local c = 0 for _ in pairs(t) do c = c + 1 end return c end

-- Helper: get current level identifier from mission filename
local function getPoliceCurrentLevelIdentifier()
 local levelPath = getMissionFilename and getMissionFilename() or ""
 return string.match(levelPath, "levels/([^/]+)/") or "west_coast_usa"
end

-- No-plate detection
local NOPLATE_DETECTION_RADIUS = 80 -- meters — police must be relatively close
local NOPLATE_CHECK_INTERVAL = 3.0 -- seconds between checks
local NOPLATE_COOLDOWN_HOURS = 1 -- game hours between repeated no-plate fines
local NOPLATE_FINE_AMOUNT = 40000 -- $400

-- Spike strips (level 3 roadblock enhancement)
local SPIKE_STRIP_MODEL = 'spikestrip'
local SPIKE_STRIP_CONFIGS = {
 'vehicles/spikestrip/flex8.pc',
 'vehicles/spikestrip/flexr_dual.pc',
}
local SPIKE_STRIP_OFFSET = 4 -- meters ahead of roadblock position
local SPIKE_STRIP_MAX = 2 -- max strips per roadblock

-- Vehicle pool — west coast USA configs (from police-vehicle-tiers.md)
-- Shuffled at spawn time; other maps use vanilla defaults
local POLICE_CONFIGS = {
 "fullsize/police",
 "bastion/police_v8_awd_A",
 "bastion/police_unmarked_v8_awd_A",
 "roamer/police",
 "van/police",
 "van/police_passenger",
 "midtruck/4x4_police_petrol",
 "sunburst2/interceptor",
 "md_series/md_60_armored_police",
 "bastion/police_v8_awd_A_interceptor",
}

-- ============================================================================
-- Private state
-- ============================================================================
local activated = false
local policeStats = { totalPursuits = 0, totalEvasions = 0, totalArrests = 0 }
local pursuitWasActive = false
local lastPursuitLevel = 0
local pursuitStartTime = 0
local stuckTimer = 0
local stuckRespawnAttempts = 0
local patrolStuckTimers = {}
local patrolCheckAccumulator = 0
local triggerPursuitActive = false
local sirenState = {}

-- BCM pursuit state (absorbed from override)
local bcmPursuitActive = false
local bcmPursuitReason = nil -- e.g. 'no_plate' — reason BCM triggered the pursuit
local currentPursuitLevel = 0
local pursuitDamageCost = 0
local policeDamageSnapshot = {}
local passiveScoreAccum = 0
local levelEscalationTimer = 0 -- seconds at current level without damage escalation
local LEVEL_ESCALATION_TIMEOUT = 180 -- 3 minutes → auto-escalate one level
local recycleCheckAccum = 0
local damageCheckAccum = 0
local damageCooldowns = {}
local recycleCooldowns = {}
local interceptorTimer = 0
local interceptorVehIds = {}

-- FMOD queue state
local fmodQueue = {}
local fmodQueueAccum = 0

-- Vehicle pool state
local validatedConfigs = nil
local poolSpawnRequested = false

-- Mobile radar state
local radarVehicleIds = {} -- spawned radar car vehicle IDs
local radarVehToSpotIdx = {} -- { [vehId] = spotIndex } — maps radar car to its spot data
local activeSpotIndices = {} -- indices into RADAR_SPOTS currently in use
local radarCooldowns = {} -- radarVehId -> os.clock() last fine time
local nextRadarRotation = 0 -- game time (days) for next rotation
local radarSpawned = false -- flag to prevent double-spawning

-- No-plate state
local noplateCheckTimer = 0
local lastNoplateFineTime = 0 -- game time of last no-plate fine
local cachedPlateStatus = {} -- vehId -> bool (cache plate check per vehicle)

-- Spike strip state
local spikeStripIds = {} -- spawned spike strip vehicle IDs
local spikeStripsDeployed = false -- flag to prevent re-deployment

-- Citizen report state (witness-triggered pursuit)
local reportActive = false -- true = player has been reported by witnesses
local reportTimer = 0 -- countdown timer (seconds) — resets on new infraction
local reportReason = nil -- 'collision' or 'speeding' (most recent reason)
local reportDamageSnapshot = {} -- { [vehId] = damage } — tracks NPC damage outside pursuit
local reportCheckTimer = 0 -- accumulator for report check interval
local REPORT_DURATION = 120 -- seconds (2 minutes)
local REPORT_CHECK_INTERVAL = 1.0 -- seconds between report checks
local REPORT_SPEED_FACTOR = 2.0 -- double the speed limit
local REPORT_TRAFFIC_PROXIMITY = 50 -- meters — must be near traffic to trigger speed report
local REPORT_DAMAGE_THRESHOLD = 30 -- minimum damage delta to count as collision
local REPORT_VISIBLE_DAMAGE_THRESHOLD = 40000 -- player vehicle damage level (~80% of totaled) to trigger report
local REPORT_VISIBLE_DAMAGE_COOLDOWN = 120 -- 2 min cooldown between visible damage reports
local reportVisibleDamageCooldown = 0 -- countdown timer for visible damage report cooldown

-- Flexible spawn mode state
local flexPoolVehIds = {} -- ALL police vehicle IDs from spawn (both active + reserve)
local allEverSpawnedPolice = {} -- accumulates ALL police vehIds across respawns (for tutorial deactivation)
local reserveVehIds = {} -- vehicle IDs currently deactivated (reserve pool)
local activeFlexVehIds = {} -- vehicle IDs currently active in traffic
local reinforcementTimer = 0 -- accumulator for next reserve activation
local deactivatingVehIds = {} -- { [vehId] = true } — vehicles driving away, pending deactivation
local DEACTIVATE_DISTANCE = 250 -- meters from player before reserve is deactivated
local REINFORCEMENT_INTERVAL_MIN = 1 -- seconds (heat 10)
local REINFORCEMENT_INTERVAL_MAX = 8 -- seconds (heat 0)

-- ============================================================================
-- FMOD Action Queue (serializes audio-critical operations)
-- ============================================================================

queueFmodAction = function(action)
 if not action or not action.type then return end
 table.insert(fmodQueue, action)
 log('D', logTag, 'FMOD queue: +' .. action.type .. ' (queue size: ' .. #fmodQueue .. ')')
end

processFmodQueue = function(dtSim)
 fmodQueueAccum = fmodQueueAccum + dtSim
 if fmodQueueAccum >= FMOD_TICK_INTERVAL and #fmodQueue > 0 then
 fmodQueueAccum = fmodQueueAccum - FMOD_TICK_INTERVAL
 local action = table.remove(fmodQueue, 1)
 executeFmodAction(action)
 end
end

executeFmodAction = function(action)
 if not action then return end
 local actionType = action.type

 if actionType == 'siren' then
 pcall(function()
 local obj = getObjectByID(action.vehId)
 if obj then
 obj:queueLuaCommand('electrics.set_lightbar_signal(' .. (action.signal or 0) .. ')')
 sirenState[action.vehId] = action.signal or 0
 end
 end)
 elseif actionType == 'teleport' then
 pcall(function()
 if gameplay_traffic and gameplay_traffic.forceTeleport then
 gameplay_traffic.forceTeleport(action.vehId)
 end
 end)
 elseif actionType == 'repair' then
 pcall(function()
 local obj = getObjectByID(action.vehId)
 if obj then
 obj:resetBrokenFlexMesh()
 end
 end)
 elseif actionType == 'spawnRadarCar' then
 pcall(function()
 local configPath = action.config
 local parts = split(configPath, '/')
 local modelName = parts[1]
 local configName = parts[2]
 local spot = action.spot
 local spawnOptions = {
 config = configName,
 pos = vec3(spot.pos[1], spot.pos[2], spot.pos[3]),
 rot = quatFromAxisAngle(vec3(0, 0, 1), spot.heading or 0),
 autoEnterVehicle = false,
 }
 local vehObj = core_vehicles.spawnNewVehicle(modelName, spawnOptions)
 if vehObj then
 local vehId = vehObj:getId()
 table.insert(radarVehicleIds, vehId)
 radarVehToSpotIdx[vehId] = action.spotIndex
 -- Lights off, AI stopped
 vehObj:queueLuaCommand('electrics.set_lightbar_signal(0)')
 vehObj:queueLuaCommand('ai.setMode("stop")')
 vehObj.playerUsable = false
 -- Remove from player vehicle list so minimap doesn't show it
 pcall(function()
 if core_vehicle_manager and core_vehicle_manager.removePlayerVehicle then
 core_vehicle_manager.removePlayerVehicle(vehId)
 elseif core_vehicles and core_vehicles.removeVehicleFromList then
 core_vehicles.removeVehicleFromList(vehId)
 end
 end)
 log('I', logTag, 'Radar car spawned: vehId=' .. tostring(vehId) .. ' at spot index ' .. tostring(action.spotIndex))
 end
 end)
 elseif actionType == 'spawnSpikeStrip' then
 pcall(function()
 -- Raycast down to find ground level
 local spawnPos = action.pos
 local rayOrigin = vec3(spawnPos.x, spawnPos.y, spawnPos.z + 10)
 local rayDir = vec3(0, 0, -1)
 local hitDist = castRayStatic(rayOrigin, rayDir, 50)
 if hitDist > 0 and hitDist < 50 then
 spawnPos = vec3(spawnPos.x, spawnPos.y, rayOrigin.z - hitDist + 0.05)
 end

 -- Use quatFromDir (same as vanilla roadblock placement) when road direction available
 local spawnRot
 if action.roadDir then
 spawnRot = quatFromDir(action.roadDir, action.roadNormal or vec3(0, 0, 1))
 else
 spawnRot = quatFromAxisAngle(vec3(0, 0, 1), action.heading or 0)
 end

 local spawnOptions = {
 config = SPIKE_STRIP_CONFIGS[math.random(1, #SPIKE_STRIP_CONFIGS)],
 pos = spawnPos,
 rot = spawnRot,
 autoEnterVehicle = false,
 }
 local vehObj = core_vehicles.spawnNewVehicle(SPIKE_STRIP_MODEL, spawnOptions)
 if vehObj then
 local vehId = vehObj:getId()
 table.insert(spikeStripIds, vehId)
 vehObj.playerUsable = false
 log('I', logTag, string.format('Spike strip spawned: vehId=%d pos=(%.1f,%.1f,%.1f)', vehId, spawnPos.x, spawnPos.y, spawnPos.z))
 end
 end)
 end
end

-- ============================================================================
-- Config pool validation & spawning
-- ============================================================================

validateConfigPool = function()
 local validated = {}
 for _, configPath in ipairs(POLICE_CONFIGS) do
 local parts = split(configPath, '/')
 local modelName = parts[1]
 local ok, modelData = pcall(function()
 return core_vehicles.getModel(modelName)
 end)
 if ok and modelData then
 table.insert(validated, configPath)
 else
 log('W', logTag, 'Config pool: missing model "' .. modelName .. '", skipping')
 end
 end

 if #validated == 0 then
 validated = {"fullsize/police"}
 log('W', logTag, 'Config pool: all configs missing, using fallback')
 end

 validatedConfigs = validated
 log('I', logTag, 'Config pool validated: ' .. #validated .. ' configs available')
 return validated
end

isFlexibleMode = function()
 local mode = "flexible"
 pcall(function()
 if bcm_settings then
 mode = bcm_settings.getSetting('policeSpawnMode') or "flexible"
 end
 end)
 return mode == "flexible"
end

getFlexPoolVehIds = function()
 return flexPoolVehIds
end

spawnPolicePool = function()
 if not activated then return end
 if poolSpawnRequested then return end
 poolSpawnRequested = true

 local policeEnabled = true
 local policeCount = 3
 local spawnMode = "flexible"
 local flexMin = 1
 local flexMax = 4
 pcall(function()
 if bcm_settings then
 policeEnabled = bcm_settings.getSetting('policeEnabled')
 if policeEnabled == nil then policeEnabled = true end
 policeCount = bcm_settings.getSetting('policeCount') or 3
 spawnMode = bcm_settings.getSetting('policeSpawnMode') or "flexible"
 flexMin = bcm_settings.getSetting('policeFlexMin') or 1
 flexMax = bcm_settings.getSetting('policeFlexMax') or 4
 end
 end)

 if not policeEnabled then
 log('I', logTag, 'Police disabled in BCM settings, skipping spawn')
 return
 end

 -- In flexible mode, always spawn flexMax (extras will be deactivated after spawn)
 -- In static mode, use policeCount as before
 -- flexMax/policeCount of 0 means no police (e.g., during tutorial)
 if spawnMode == "flexible" then
 if flexMax <= 0 then
 log('I', logTag, 'Police flex pool max is 0, skipping spawn')
 return
 end
 policeCount = math.max(2, math.min(6, flexMax))
 else
 if policeCount <= 0 then return end
 policeCount = math.max(2, math.min(12, policeCount))
 end

 if not validatedConfigs then
 validateConfigPool()
 end

 -- Shuffle validated configs so each session spawns a different subset
 local shuffled = {}
 for _, v in ipairs(validatedConfigs) do table.insert(shuffled, v) end
 for i = #shuffled, 2, -1 do
 local j = math.random(1, i)
 shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
 end

 -- Build vehicle group — core_multiSpawn handles road positioning
 local group = {}
 for i = 1, policeCount do
 local config = shuffled[((i - 1) % #shuffled) + 1]
 local parts = split(config, '/')
 table.insert(group, {
 model = parts[1],
 config = parts[2],
 })
 end

 core_multiSpawn.spawnGroup(group, policeCount, {
 name = BCM_POLICE_GROUP_NAME,
 mode = 'traffic',
 instant = false,
 })

 log('I', logTag, 'Spawning ' .. policeCount .. ' police via core_multiSpawn')
end

-- Handle our police group spawn completion
onVehicleGroupSpawned = function(vehIds, groupId, groupName)
 if groupName ~= BCM_POLICE_GROUP_NAME then return end
 if not vehIds or #vehIds == 0 then return end

 log('I', logTag, 'BCM police group spawned: ' .. #vehIds .. ' vehicles')

 -- Store all spawned IDs for flexible mode tracking
 flexPoolVehIds = {}
 for _, vehId in ipairs(vehIds) do
 table.insert(flexPoolVehIds, vehId)
 table.insert(allEverSpawnedPolice, vehId)
 end

 -- Insert ALL vehicles into traffic first (vanilla needs this for role assignment)
 for _, vehId in ipairs(vehIds) do
 gameplay_traffic.insertTraffic(vehId, false, false)
 end

 -- In flexible mode, deactivate reserves after traffic init
 if isFlexibleMode() then
 local flexMin = 1
 pcall(function()
 if bcm_settings then
 flexMin = bcm_settings.getSetting('policeFlexMin') or 1
 end
 end)
 flexMin = math.max(1, math.min(#vehIds, flexMin))

 -- First flexMin vehicles stay active, rest go to reserve
 activeFlexVehIds = {}
 reserveVehIds = {}
 for i, vehId in ipairs(flexPoolVehIds) do
 if i <= flexMin then
 table.insert(activeFlexVehIds, vehId)
 else
 table.insert(reserveVehIds, vehId)
 end
 end

 -- Queue siren-off for reserves (FMOD safety)
 for _, vehId in ipairs(reserveVehIds) do
 queueFmodAction({ type = 'siren', vehId = vehId, signal = 0 })
 end

 log('I', logTag, string.format('Flexible mode: %d active, %d reserve (will deactivate on next tick)', #activeFlexVehIds, #reserveVehIds))
 else
 -- Static mode: all active, no reserve tracking
 activeFlexVehIds = {}
 reserveVehIds = {}
 end

 log('I', logTag, 'BCM police pool active: ' .. #vehIds .. ' vehicles inserted into traffic')

 -- If tutorial is active, immediately deactivate all units (pool spawns first, then we silence them)
 if bcm_tutorial and bcm_tutorial.isTutorialActive and bcm_tutorial.isTutorialActive() then
 M.deactivateAllUnits()
 end
end

-- ============================================================================
-- Mobile radar subsystem
-- ============================================================================

loadRadarSpots = function()
 -- Try to load devtool-exported radar spots JSON
 local levelName = nil
 pcall(function()
 levelName = getPoliceCurrentLevelIdentifier()
 end)
 if not levelName then levelName = "west_coast_usa" end

 local jsonPath = "/levels/" .. levelName .. "/facilities/bcm_radarSpots.json"
 local data = nil
 pcall(function()
 data = jsonReadFile(jsonPath)
 end)

 if data and type(data) == "table" and #data > 0 then
 RADAR_SPOTS = data
 log('I', logTag, 'Loaded ' .. #data .. ' radar spots from ' .. jsonPath)
 else
 RADAR_SPOTS = DEFAULT_RADAR_SPOTS
 log('I', logTag, 'No custom radar spots found at ' .. jsonPath .. ', using ' .. #DEFAULT_RADAR_SPOTS .. ' defaults')
 end
end

selectRadarSpots = function()
 local indices = {}
 for i = 1, #RADAR_SPOTS do table.insert(indices, i) end
 -- Fisher-Yates shuffle
 for i = #indices, 2, -1 do
 local j = math.random(1, i)
 indices[i], indices[j] = indices[j], indices[i]
 end
 activeSpotIndices = {}
 for i = 1, math.min(RADAR_MAX_CARS, #indices) do
 table.insert(activeSpotIndices, indices[i])
 end
 log('I', logTag, 'Selected ' .. #activeSpotIndices .. ' radar spots from ' .. #RADAR_SPOTS .. ' total')
end

spawnRadarCars = function()
 if radarSpawned then return end
 if #activeSpotIndices == 0 then
 selectRadarSpots()
 end

 -- Use tier 1-2 patrol configs (first 7 entries, not interceptors)
 local patrolConfigs = {}
 for i = 1, math.min(7, #POLICE_CONFIGS) do
 table.insert(patrolConfigs, POLICE_CONFIGS[i])
 end

 for _, spotIdx in ipairs(activeSpotIndices) do
 local spot = RADAR_SPOTS[spotIdx]
 if spot then
 local configIdx = math.random(1, #patrolConfigs)
 queueFmodAction({
 type = 'spawnRadarCar',
 config = patrolConfigs[configIdx],
 spot = spot,
 spotIndex = spotIdx,
 })
 end
 end

 radarSpawned = true
 log('I', logTag, 'Radar cars queued for spawn at ' .. #activeSpotIndices .. ' spots')
end

despawnRadarCars = function()
 for _, vehId in ipairs(radarVehicleIds) do
 pcall(function()
 local obj = getObjectByID(vehId)
 if obj then obj:delete() end
 end)
 end
 local count = #radarVehicleIds
 radarVehicleIds = {}
 radarVehToSpotIdx = {}
 radarCooldowns = {}
 radarSpawned = false
 log('I', logTag, 'Radar cars despawned (' .. count .. ' removed)')
end

-- checkMobileRadar removed — detection now uses BeamNGTrigger zones exported by devtool
-- The onBeamNGTrigger handler below processes radar zone triggers

onBeamNGTrigger = function(data)
 if not activated then return end
 if not data then return end

 -- Only handle radar zone triggers (exported by devtool with bcmRadarSpot = true)
 -- Trigger names follow pattern: bcmRadar_N_zone
 local triggerName = data.triggerName or ""
 if not string.find(triggerName, "bcmRadar_") then return end

 -- Only trigger on enter events
 if data.event ~= "enter" then return end

 -- Only fine the player vehicle
 local vehId = data.subjectID
 if not vehId then return end
 local playerVehId = be:getPlayerVehicleID(0)
 if vehId ~= playerVehId then return end

 -- Skip if walking
 local isWalking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()
 if isWalking then return end

 -- Career must be active
 local careerActive = false
 pcall(function()
 if career_career and career_career.isActive() then careerActive = true end
 end)
 if not careerActive then return end

 -- Get player speed
 local pvx, pvy, pvz = be:getObjectVelocityXYZ(playerVehId)
 local playerSpeedMs = math.sqrt(pvx*pvx + pvy*pvy + pvz*pvz)
 local playerSpeedKmh = playerSpeedMs * 3.6

 -- Find which radar spot this trigger belongs to
 -- triggerName format: bcmRadar_N_zone → extract N (1-based index matching export order)
 local spotIdx = tonumber(string.match(triggerName, "bcmRadar_(%d+)_zone"))
 if not spotIdx then return end

 -- Only fine if this spot is in the active rotation (has a police car there)
 local isActiveSpot = false
 for _, idx in ipairs(activeSpotIndices) do
 if idx == spotIdx then isActiveSpot = true break end
 end
 if not isActiveSpot then return end

 local spotSpeedLimit = RADAR_DEFAULT_SPEED_LIMIT
 if RADAR_SPOTS[spotIdx] then
 spotSpeedLimit = RADAR_SPOTS[spotIdx].speedLimit or RADAR_DEFAULT_SPEED_LIMIT
 end

 local overSpeed = playerSpeedKmh - spotSpeedLimit
 if overSpeed <= 0 then return end

 local ppx, ppy, ppz = be:getObjectPositionXYZ(playerVehId)
 log('I', logTag, string.format('[RADAR DEBUG] trigger=%s spotSpeedLimit=%d playerSpeed=%.1f overSpeed=%.1f playerPos=(%.0f,%.0f,%.0f)',
 triggerName, spotSpeedLimit, playerSpeedKmh, overSpeed, ppx, ppy, ppz))

 -- License plate check — radar camera cannot identify vehicle without plate
 if not hasLicensePlate(playerVehId) then
 log('I', logTag, 'No license plate — radar cannot identify vehicle at ' .. triggerName)
 return
 end

 -- Cooldown check (per trigger name)
 local now = os.clock()
 if radarCooldowns[triggerName] and (now - radarCooldowns[triggerName]) < RADAR_FINE_COOLDOWN then
 log('I', logTag, '[RADAR DEBUG] Cooldown active for ' .. triggerName)
 return
 end

 -- Issue tiered speed fine
 local fineAmount = 50000
 pcall(function()
 if bcm_fines and bcm_fines.getSpeedFineTier then
 fineAmount = bcm_fines.getSpeedFineTier(math.floor(overSpeed))
 end
 end)

 log('I', logTag, string.format('[RADAR FINE] trigger=%s playerVeh=%d speed=%.0f limit=%d over=%d fine=$%d playerPos=(%.0f,%.0f,%.0f)',
 triggerName, playerVehId, playerSpeedKmh, spotSpeedLimit, math.floor(overSpeed), math.floor(fineAmount/100), ppx, ppy, ppz))

 pcall(function()
 if bcm_fines and bcm_fines.issueCameraFine then
 bcm_fines.issueCameraFine('speed_radar', fineAmount, triggerName, math.floor(overSpeed))
 end
 end)

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

 radarCooldowns[triggerName] = now
end

rotateRadarSpots = function()
 pcall(function()
 local currentGameTime = 0
 if bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
 currentGameTime = bcm_timeSystem.getGameTimeDays()
 else
 return -- Cannot rotate without time system
 end

 if nextRadarRotation > 0 and currentGameTime >= nextRadarRotation then
 log('I', logTag, 'Rotating radar spots (game time ' .. string.format('%.3f', currentGameTime) .. ')')
 despawnRadarCars()
 selectRadarSpots()
 spawnRadarCars()
 nextRadarRotation = currentGameTime + (RADAR_ROTATION_HOURS / 24)
 end
 end)
end

-- ============================================================================
-- No-plate detection subsystem
-- ============================================================================

hasLicensePlate = function(vehId)
 if cachedPlateStatus[vehId] ~= nil then
 return cachedPlateStatus[vehId]
 end
 local hasPlate = false
 local ok, err = pcall(function()
 -- Convert vehId → inventoryId (vanilla pattern)
 local inventoryId = nil
 if career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
 inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
 end
 if not inventoryId then
 log('D', logTag, 'hasLicensePlate: no inventoryId for vehId=' .. tostring(vehId))
 return
 end

 -- Iterate ALL parts, filter by location == inventoryId (vanilla pattern)
 if career_modules_partInventory and career_modules_partInventory.getInventory then
 local partCount = 0
 for partId, part in pairs(career_modules_partInventory.getInventory()) do
 if part.location == inventoryId then
 partCount = partCount + 1
 if string.find(part.name, "licenseplate") then
 hasPlate = true
 break
 end
 end
 end
 if not hasPlate then
 log('D', logTag, 'hasLicensePlate: inventoryId=' .. tostring(inventoryId) .. ' scanned ' .. partCount .. ' parts, no plate found')
 end
 else
 log('D', logTag, 'hasLicensePlate: partInventory module not available')
 end
 end)
 if not ok then
 log('W', logTag, 'hasLicensePlate error: ' .. tostring(err))
 end
 cachedPlateStatus[vehId] = hasPlate
 return hasPlate
end

checkNoPlate = function(dtSim)
 noplateCheckTimer = noplateCheckTimer + dtSim
 if noplateCheckTimer < NOPLATE_CHECK_INTERVAL then return end
 noplateCheckTimer = noplateCheckTimer - NOPLATE_CHECK_INTERVAL

 -- Clear plate cache each cycle (plates can be added/removed)
 cachedPlateStatus = {}

 pcall(function()
 -- Skip if already in pursuit (no need to re-trigger)
 if currentPursuitLevel > 0 then return end

 -- Skip if player is walking (unicycle has no plates)
 if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then return end

 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then return end

 -- Fast path: if player HAS plates, skip all distance checks
 local plateResult = hasLicensePlate(playerVehId)
 if plateResult then return end

 -- Cooldown: don't re-trigger pursuit too quickly after last detection
 local currentGameTime = 0
 if bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
 currentGameTime = bcm_timeSystem.getGameTimeDays()
 end
 if lastNoplateFineTime > 0 and (currentGameTime - lastNoplateFineTime) < (NOPLATE_COOLDOWN_HOURS / 24) then
 return
 end

 local ppx, ppy, ppz = be:getObjectPositionXYZ(playerVehId)

 -- Line-of-sight helper: raycast from police to player, check if terrain/buildings block view
 local function hasLineOfSight(fromX, fromY, fromZ, toX, toY, toZ)
 local origin = vec3(fromX, fromY, fromZ + 1) -- raise slightly above ground
 local target = vec3(toX, toY, toZ + 1)
 local dir = target - origin
 local dist = dir:length()
 if dist < 0.1 then return true end
 local hitDist = castRayStatic(origin, dir:normalized(), dist)
 return hitDist >= dist or hitDist <= 0
 end

 -- Check proximity + line of sight to traffic police
 local trafficData = gameplay_traffic.getTrafficData()
 if trafficData then
 for vehId, tData in pairs(trafficData) do
 if tData.role and tData.role.name == 'police' and vehId ~= playerVehId then
 local tpx, tpy, tpz = be:getObjectPositionXYZ(vehId)
 local dx = tpx - ppx
 local dy = tpy - ppy
 local dz = tpz - ppz
 local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
 if dist <= NOPLATE_DETECTION_RADIUS and hasLineOfSight(tpx, tpy, tpz, ppx, ppy, ppz) then
 log('I', logTag, string.format('[NOPLATE PURSUIT] Police spotted no-plate: playerVeh=%d policeVeh=%d dist=%.0fm',
 playerVehId, vehId, dist))
 bcmPursuitReason = 'no_plate'
 triggerPursuit(1)
 lastNoplateFineTime = currentGameTime
 return
 end
 end
 end
 end

 -- Check proximity + line of sight to radar cars
 for _, radarId in ipairs(radarVehicleIds) do
 local rpx, rpy, rpz = be:getObjectPositionXYZ(radarId)
 local dx = rpx - ppx
 local dy = rpy - ppy
 local dz = rpz - ppz
 local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
 if dist <= NOPLATE_DETECTION_RADIUS and hasLineOfSight(rpx, rpy, rpz, ppx, ppy, ppz) then
 log('I', logTag, string.format('[NOPLATE PURSUIT] Radar car spotted no-plate: playerVeh=%d radarVeh=%d dist=%.0fm',
 playerVehId, radarId, dist))
 bcmPursuitReason = 'no_plate'
 triggerPursuit(1)
 lastNoplateFineTime = currentGameTime
 return
 end
 end
 end)
end

-- ============================================================================
-- Citizen reports: witness-triggered pursuit
-- When the player collides with traffic or speeds excessively near NPCs,
-- witnesses "report" them. For 2 minutes, if any police officer sees the
-- player (line-of-sight + proximity), an instant 1-star pursuit starts.
-- ============================================================================

-- Get the road speed limit (m/s) at a world position using the map graph
getSpeedLimitAtPosition = function(pos)
 local mapData = map.getMap()
 if not mapData or not mapData.nodes then return nil end
 local n1, n2 = map.findClosestRoad(pos)
 if not n1 or not n2 then return nil end
 local nodes = mapData.nodes
 if not nodes[n1] or not nodes[n1].links then return nil end
 local link = nodes[n1].links[n2]
 if not link and nodes[n2] and nodes[n2].links then
 link = nodes[n2].links[n1]
 end
 if not link then return nil end
 return link.speedLimit -- m/s
end

-- Check for citizen report triggers: collision with traffic or excessive speed near traffic
checkCitizenReports = function(dtSim)
 reportCheckTimer = reportCheckTimer + dtSim
 if reportCheckTimer < REPORT_CHECK_INTERVAL then return end
 reportCheckTimer = reportCheckTimer - REPORT_CHECK_INTERVAL

 -- Check pursuit state using vanilla traffic data directly (bcmPursuitActive can be stale)
 local inPursuit = false
 pcall(function()
 local pVeh = be:getPlayerVehicleID(0)
 if pVeh and pVeh >= 0 and gameplay_traffic then
 local td = gameplay_traffic.getTrafficData()
 local pt = td and td[pVeh]
 if pt and pt.pursuit and pt.pursuit.mode and pt.pursuit.mode > 0 then
 inPursuit = true
 end
 end
 end)
 if inPursuit then return end

 pcall(function()

 -- Skip if player is walking
 if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then return end

 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then return end

 local trafficData = gameplay_traffic.getTrafficData()
 if not trafficData then return end

 local ppx, ppy, ppz = be:getObjectPositionXYZ(playerVehId)
 local playerPos = vec3(ppx, ppy, ppz)

 -- Player speed (m/s) — read directly from physics, not traffic data (more accurate)
 local pvx, pvy, pvz = be:getObjectVelocityXYZ(playerVehId)
 local playerSpeed = math.sqrt(pvx*pvx + pvy*pvy + pvz*pvz)

 -- Get road speed limit at player position
 local roadSpeedLimit = getSpeedLimitAtPosition(playerPos)

 local triggered = false

 -- Check 1: Collision with traffic NPC — verify actual physical contact via objectCollisions API
 for vehId, tData in pairs(trafficData) do
 if vehId ~= playerVehId then
 local role = tData.role and tData.role.name
 if role == 'standard' then
 local curDamage = tData.damage or 0
 local prevDamage = reportDamageSnapshot[vehId] or 0
 local delta = curDamage - prevDamage
 reportDamageSnapshot[vehId] = curDamage
 if delta > REPORT_DAMAGE_THRESHOLD then
 -- Verify this NPC is actually in physical contact with the player vehicle
 local npcObj = map.objects[vehId]
 local inContact = npcObj and npcObj.objectCollisions and npcObj.objectCollisions[playerVehId] == 1
 if inContact then
 triggered = true
 reportReason = 'collision'
 log('I', logTag, string.format('[CITIZEN REPORT] Collision with traffic: veh=%d delta=%.0f speed=%.0f km/h (contact confirmed)', vehId, delta, playerSpeed * 3.6))
 end
 end
 end
 end
 end

 -- Check 2: Excessive speed near traffic (>50% over road limit, within proximity of NPC)
 if not triggered and roadSpeedLimit and roadSpeedLimit > 0 then
 local threshold = roadSpeedLimit * REPORT_SPEED_FACTOR
 if playerSpeed > threshold then
 -- Check if any traffic NPC is nearby
 for vehId, tData in pairs(trafficData) do
 if vehId ~= playerVehId then
 local role = tData.role and tData.role.name
 if role == 'standard' then
 local tpx, tpy, tpz = be:getObjectPositionXYZ(vehId)
 local dx = tpx - ppx
 local dy = tpy - ppy
 local dz = tpz - ppz
 local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
 if dist <= REPORT_TRAFFIC_PROXIMITY then
 triggered = true
 reportReason = 'speeding'
 log('I', logTag, string.format(
 '[CITIZEN REPORT] Speeding near traffic: playerSpeed=%.0f km/h limit=%.0f km/h threshold=%.0f km/h nearVeh=%d dist=%.0fm',
 playerSpeed * 3.6, roadSpeedLimit * 3.6, threshold * 3.6, vehId, dist))
 break
 end
 end
 end
 end
 end
 end

 -- Check 3: Visible vehicle damage — heavily damaged car near traffic triggers report
 -- Uses cooldown to prevent repeated reports for the same damage
 if not triggered then
 reportVisibleDamageCooldown = math.max(0, reportVisibleDamageCooldown - REPORT_CHECK_INTERVAL)
 if reportVisibleDamageCooldown <= 0 then
 local playerTraffic = trafficData[playerVehId]
 local playerDamage = playerTraffic and playerTraffic.damage or 0
 if playerDamage >= REPORT_VISIBLE_DAMAGE_THRESHOLD then
 -- Must be near traffic for someone to see and call it in
 for vehId, tData in pairs(trafficData) do
 if vehId ~= playerVehId then
 local role = tData.role and tData.role.name
 if role == 'standard' then
 local tpx, tpy, tpz = be:getObjectPositionXYZ(vehId)
 local dx = tpx - ppx
 local dy = tpy - ppy
 local dz = tpz - ppz
 local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
 if dist <= 2 then
 triggered = true
 reportReason = 'damaged_vehicle'
 reportVisibleDamageCooldown = REPORT_VISIBLE_DAMAGE_COOLDOWN
 log('I', logTag, string.format(
 '[CITIZEN REPORT] Damaged vehicle spotted: damage=%.0f nearVeh=%d dist=%.0fm',
 playerDamage, vehId, dist))
 break
 end
 end
 end
 end
 end
 end
 end

 -- Activate or refresh report timer
 if triggered then
 local wasActive = reportActive
 reportActive = true
 reportTimer = REPORT_DURATION -- reset to 2 minutes

 -- Send phone notification only on new report (not on refresh)
 if not wasActive then
 pcall(function()
 if bcm_notifications and bcm_notifications.send then
 bcm_notifications.send({
 titleKey = 'notif.citizenReport',
 bodyKey = 'notif.citizenReportBody',
 params = {},
 type = 'warning',
 duration = 6000
 })
 end
 end)
 end
 end
 end)
end

-- Check if any police officer can see the reported player — triggers instant pursuit
checkReportedSighting = function(dtSim)
 if not reportActive then return end

 -- Count down timer
 reportTimer = reportTimer - dtSim
 if reportTimer <= 0 then
 log('I', logTag, '[CITIZEN REPORT] Report expired — no police sighting in 2 minutes')
 reportActive = false
 reportTimer = 0
 reportReason = nil
 return
 end

 -- Skip if already in pursuit (check vanilla traffic data directly)
 local inPursuit = false
 pcall(function()
 local pVeh = be:getPlayerVehicleID(0)
 if pVeh and pVeh >= 0 and gameplay_traffic then
 local td = gameplay_traffic.getTrafficData()
 local pt = td and td[pVeh]
 if pt and pt.pursuit and pt.pursuit.mode and pt.pursuit.mode > 0 then
 inPursuit = true
 end
 end
 end)
 if inPursuit then
 reportActive = false
 reportTimer = 0
 reportReason = nil
 return
 end

 pcall(function()
 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then return end

 local ppx, ppy, ppz = be:getObjectPositionXYZ(playerVehId)

 -- Line-of-sight helper (same as checkNoPlate)
 local function hasLineOfSight(fromX, fromY, fromZ, toX, toY, toZ)
 local origin = vec3(fromX, fromY, fromZ + 1)
 local target = vec3(toX, toY, toZ + 1)
 local dir = target - origin
 local dist = dir:length()
 if dist < 0.1 then return true end
 local hitDist = castRayStatic(origin, dir:normalized(), dist)
 return hitDist >= dist or hitDist <= 0
 end

 -- Check traffic police
 local trafficData = gameplay_traffic.getTrafficData()
 if trafficData then
 for vehId, tData in pairs(trafficData) do
 if tData.role and tData.role.name == 'police' and vehId ~= playerVehId then
 local tpx, tpy, tpz = be:getObjectPositionXYZ(vehId)
 local dx = tpx - ppx
 local dy = tpy - ppy
 local dz = tpz - ppz
 local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
 if dist <= NOPLATE_DETECTION_RADIUS and hasLineOfSight(tpx, tpy, tpz, ppx, ppy, ppz) then
 log('I', logTag, string.format('[CITIZEN REPORT] Police spotted reported player: policeVeh=%d dist=%.0fm reason=%s timer=%.0fs',
 vehId, dist, tostring(reportReason), reportTimer))
 local reason = reportReason
 bcmPursuitReason = 'citizen_report'
 triggerPursuit(1)
 -- Inject offense matching the citizen report reason
 local pt = trafficData[playerVehId]
 if pt and pt.pursuit then
 if reason == 'speeding' and not pt.pursuit.offenses.speeding then
 local speedLimit = getSpeedLimitAtPosition(vec3(ppx, ppy, ppz)) or 0
 pt.pursuit.offenses.speeding = {value = 0, maxLimit = speedLimit, score = 100}
 table.insert(pt.pursuit.offensesList, 'speeding')
 pt.pursuit.uniqueOffensesCount = pt.pursuit.uniqueOffensesCount + 1
 pt.pursuit.offensesCount = pt.pursuit.offensesCount + 1
 log('I', logTag, '[CITIZEN REPORT] Injected offense: speeding')
 elseif reason == 'collision' and not pt.pursuit.offenses.hitTraffic then
 pt.pursuit.offenses.hitTraffic = {value = 0, score = 100}
 table.insert(pt.pursuit.offensesList, 'hitTraffic')
 pt.pursuit.uniqueOffensesCount = pt.pursuit.uniqueOffensesCount + 1
 pt.pursuit.offensesCount = pt.pursuit.offensesCount + 1
 log('I', logTag, '[CITIZEN REPORT] Injected offense: hitTraffic')
 elseif reason == 'damaged_vehicle' and not pt.pursuit.offenses.hitTraffic then
 pt.pursuit.offenses.hitTraffic = {value = 0, score = 80}
 table.insert(pt.pursuit.offensesList, 'hitTraffic')
 pt.pursuit.uniqueOffensesCount = pt.pursuit.uniqueOffensesCount + 1
 pt.pursuit.offensesCount = pt.pursuit.offensesCount + 1
 log('I', logTag, '[CITIZEN REPORT] Injected offense: hitTraffic (damaged vehicle)')
 end
 end
 reportActive = false
 reportTimer = 0
 reportReason = nil
 return
 end
 end
 end
 end

 -- Check radar cars
 for _, radarId in ipairs(radarVehicleIds) do
 local rpx, rpy, rpz = be:getObjectPositionXYZ(radarId)
 local dx = rpx - ppx
 local dy = rpy - ppy
 local dz = rpz - ppz
 local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
 if dist <= NOPLATE_DETECTION_RADIUS and hasLineOfSight(rpx, rpy, rpz, ppx, ppy, ppz) then
 log('I', logTag, string.format('[CITIZEN REPORT] Radar car spotted reported player: radarVeh=%d dist=%.0fm reason=%s',
 radarId, dist, tostring(reportReason)))
 local reason = reportReason
 bcmPursuitReason = 'citizen_report'
 triggerPursuit(1)
 -- Inject offense matching the citizen report reason
 local pt = trafficData[playerVehId]
 if pt and pt.pursuit then
 if reason == 'speeding' and not pt.pursuit.offenses.speeding then
 local speedLimit = getSpeedLimitAtPosition(vec3(ppx, ppy, ppz)) or 0
 pt.pursuit.offenses.speeding = {value = 0, maxLimit = speedLimit, score = 100}
 table.insert(pt.pursuit.offensesList, 'speeding')
 pt.pursuit.uniqueOffensesCount = pt.pursuit.uniqueOffensesCount + 1
 pt.pursuit.offensesCount = pt.pursuit.offensesCount + 1
 log('I', logTag, '[CITIZEN REPORT] Injected offense: speeding')
 elseif reason == 'collision' and not pt.pursuit.offenses.hitTraffic then
 pt.pursuit.offenses.hitTraffic = {value = 0, score = 100}
 table.insert(pt.pursuit.offensesList, 'hitTraffic')
 pt.pursuit.uniqueOffensesCount = pt.pursuit.uniqueOffensesCount + 1
 pt.pursuit.offensesCount = pt.pursuit.offensesCount + 1
 log('I', logTag, '[CITIZEN REPORT] Injected offense: hitTraffic')
 elseif reason == 'damaged_vehicle' and not pt.pursuit.offenses.hitTraffic then
 pt.pursuit.offenses.hitTraffic = {value = 0, score = 80}
 table.insert(pt.pursuit.offensesList, 'hitTraffic')
 pt.pursuit.uniqueOffensesCount = pt.pursuit.uniqueOffensesCount + 1
 pt.pursuit.offensesCount = pt.pursuit.offensesCount + 1
 log('I', logTag, '[CITIZEN REPORT] Injected offense: hitTraffic (damaged vehicle)')
 end
 end
 reportActive = false
 reportTimer = 0
 reportReason = nil
 return
 end
 end
 end)
end

-- ============================================================================
-- Flexible spawn: reserve pool management
-- ============================================================================

deactivateReserveUnit = function(vehId)
 -- Safety: check vehicle still exists
 local obj = be:getObjectByID(vehId)
 if not obj then
 log('W', logTag, 'deactivateReserveUnit: vehicle ' .. tostring(vehId) .. ' no longer exists')
 return false
 end

 -- Remove from traffic (stops AI, removes role) then deactivate physics/render
 pcall(function()
 gameplay_traffic.removeTraffic(vehId, true)
 end)
 pcall(function()
 obj:setActive(0)
 end)

 -- Track in reserve pool
 deactivatingVehIds[vehId] = nil
 -- Add to reserve if not already there
 local found = false
 for _, id in ipairs(reserveVehIds) do
 if id == vehId then found = true; break end
 end
 if not found then
 table.insert(reserveVehIds, vehId)
 end
 -- Remove from active
 for i = #activeFlexVehIds, 1, -1 do
 if activeFlexVehIds[i] == vehId then
 table.remove(activeFlexVehIds, i)
 break
 end
 end

 log('D', logTag, 'Reserve unit deactivated: ' .. tostring(vehId) .. ' (active=' .. #activeFlexVehIds .. ' reserve=' .. #reserveVehIds .. ')')
 return true
end

activateReserveUnit = function()
 if #reserveVehIds == 0 then return false end

 local vehId = table.remove(reserveVehIds, 1) -- FIFO: activate oldest reserve first

 local obj = be:getObjectByID(vehId)
 if not obj then
 log('W', logTag, 'activateReserveUnit: vehicle ' .. tostring(vehId) .. ' no longer exists, skipping')
 return activateReserveUnit() -- try next reserve
 end

 -- Reactivate: physics/render on, then insert into traffic
 pcall(function()
 obj:setActive(1)
 end)
 pcall(function()
 gameplay_traffic.insertTraffic(vehId, false, false)
 end)

 -- Teleport to a spawn point near the player (reuse traffic spawn logic)
 pcall(function()
 local playerVehId = be:getPlayerVehicleID(0)
 if playerVehId and playerVehId >= 0 then
 local px, py, pz = be:getObjectPositionXYZ(playerVehId)
 if px then
 local playerPos = vec3(px, py, pz)
 local playerDir = vec3(0, 1, 0)
 pcall(function()
 local vx, vy, vz = be:getObjectDirectionVectorXYZ(playerVehId)
 if vx then playerDir = vec3(vx, vy, vz) end
 end)

 local spawnData = nil
 pcall(function()
 spawnData = gameplay_traffic_trafficUtils.findSpawnPointOnRoute(
 playerPos, playerDir, 200, 400, 300, {pathRandomization = 0.5}
 )
 end)

 if spawnData and spawnData.pos then
 obj:setPositionNoPhysicsReset(Point3F(spawnData.pos.x, spawnData.pos.y, spawnData.pos.z))
 if spawnData.rot then
 obj:setRotation(spawnData.rot)
 end
 log('D', logTag, string.format('Reserve unit teleported to (%.0f,%.0f,%.0f)', spawnData.pos.x, spawnData.pos.y, spawnData.pos.z))
 end
 end
 end
 end)

 -- Queue siren on (pursuit is active when we activate reserves)
 queueFmodAction({ type = 'siren', vehId = vehId, signal = 2 })

 table.insert(activeFlexVehIds, vehId)
 log('I', logTag, 'Reserve unit activated: ' .. tostring(vehId) .. ' (active=' .. #activeFlexVehIds .. ' reserve=' .. #reserveVehIds .. ')')
 return true
end

getReinforcementInterval = function()
 local heatLevel = 0
 pcall(function()
 if bcm_heatSystem and bcm_heatSystem.getHeatLevel then
 heatLevel = bcm_heatSystem.getHeatLevel()
 end
 end)
 -- Linear interpolation: heat 0 = 5s, heat 10 = 1s
 return REINFORCEMENT_INTERVAL_MAX - (heatLevel / 10) * (REINFORCEMENT_INTERVAL_MAX - REINFORCEMENT_INTERVAL_MIN)
end

updateReinforcementTimer = function(dt)
 if not isFlexibleMode() then return end
 if not bcmPursuitActive then return end
 if #reserveVehIds == 0 then return end -- all units already active

 reinforcementTimer = reinforcementTimer + dt
 local interval = getReinforcementInterval()

 if reinforcementTimer >= interval then
 reinforcementTimer = 0
 activateReserveUnit()
 end
end

updateReserveDeactivation = function(dt)
 if not isFlexibleMode() then return end
 if bcmPursuitActive then return end -- don't deactivate during pursuit

 -- Check if we have more active units than flexMin
 local flexMin = 1
 pcall(function()
 if bcm_settings then
 flexMin = bcm_settings.getSetting('policeFlexMin') or 1
 end
 end)

 if #activeFlexVehIds <= flexMin then
 deactivatingVehIds = {}
 return -- already at minimum
 end

 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then return end

 local px, py, pz = 0, 0, 0
 pcall(function()
 px, py, pz = be:getObjectPositionXYZ(playerVehId)
 end)
 local playerPos = vec3(px, py, pz)

 -- Mark excess active units as "deactivating" (they should drive away)
 for i, vehId in ipairs(activeFlexVehIds) do
 if i > flexMin and not deactivatingVehIds[vehId] then
 deactivatingVehIds[vehId] = true
 -- Turn off siren and reset pursuit action so they drive away as traffic
 queueFmodAction({ type = 'siren', vehId = vehId, signal = 0 })
 pcall(function()
 local td = gameplay_traffic.getTrafficData()
 if td and td[vehId] and td[vehId].role then
 td[vehId].role:resetAction()
 end
 end)
 log('D', logTag, 'Marked unit ' .. tostring(vehId) .. ' for deactivation (driving away)')
 end
 end

 -- Check distance of deactivating units — deactivate when far enough
 local toDeactivate = {}
 for vehId, _ in pairs(deactivatingVehIds) do
 local obj = be:getObjectByID(vehId)
 if obj then
 local ox, oy, oz = 0, 0, 0
 pcall(function()
 ox, oy, oz = be:getObjectPositionXYZ(vehId)
 end)
 local dist = playerPos:distance(vec3(ox, oy, oz))
 if dist > DEACTIVATE_DISTANCE then
 table.insert(toDeactivate, vehId)
 end
 else
 -- Vehicle no longer exists, just remove from tracking
 table.insert(toDeactivate, vehId)
 end
 end

 for _, vehId in ipairs(toDeactivate) do
 deactivateReserveUnit(vehId)
 end
end

-- ============================================================================
-- Spike strip subsystem (level 3 roadblock enhancement)
-- ============================================================================

deploySpikeStrips = function(roadblockPos, heading, roadDir, roadNormal)
 if spikeStripsDeployed then return end
 if getCurrentLevel() < 3 then return end

 -- Offset: along road (ahead of roadblock) + lateral (away from center of police car)
 local h = heading or 0
 local alongX = math.cos(h) * SPIKE_STRIP_OFFSET
 local alongY = math.sin(h) * SPIKE_STRIP_OFFSET
 local lateralOffset = 3 -- meters perpendicular, toward the open side
 local latX = math.cos(h + math.pi / 2) * lateralOffset
 local latY = math.sin(h + math.pi / 2) * lateralOffset
 local stripPos = vec3(
 (roadblockPos.x or roadblockPos[1] or 0) + alongX + latX,
 (roadblockPos.y or roadblockPos[2] or 0) + alongY + latY,
 (roadblockPos.z or roadblockPos[3] or 0)
 )

 -- Queue spawn through FMOD queue for safety
 queueFmodAction({
 type = 'spawnSpikeStrip',
 pos = stripPos,
 roadDir = roadDir,
 roadNormal = roadNormal,
 heading = h,
 })

 spikeStripsDeployed = true
 log('I', logTag, 'Spike strips queued for deployment at level 3 roadblock')
end

cleanupSpikeStrips = function()
 local count = #spikeStripIds
 for _, stripId in ipairs(spikeStripIds) do
 pcall(function()
 local obj = getObjectByID(stripId)
 if obj then obj:delete() end
 end)
 end
 spikeStripIds = {}
 spikeStripsDeployed = false
 if count > 0 then
 log('I', logTag, 'Spike strips cleaned up (' .. count .. ' removed)')
 end
end

-- checkRoadblockForStrips removed: spike strips now deploy exclusively from
-- onPursuitAction 'roadblock' event, which provides the exact roadblock position.

-- ============================================================================
-- BCM pursuit state management
-- ============================================================================

resetBcmPursuitState = function()
 bcmPursuitActive = false
 bcmPursuitReason = nil
 currentPursuitLevel = 0
 pursuitDamageCost = 0
 policeDamageSnapshot = {}
 passiveScoreAccum = 0
 levelEscalationTimer = 0
 recycleCheckAccum = 0
 damageCheckAccum = 0
 damageCooldowns = {}
 recycleCooldowns = {}
 interceptorTimer = 0
 interceptorVehIds = {}
 -- Spike strip cleanup on pursuit end
 cleanupSpikeStrips()
 -- Reset no-plate cooldown
 lastNoplateFineTime = 0
 -- Reset flexible spawn reinforcement state (but DON'T deactivate reserves here —
 -- that happens gradually in updateReserveDeactivation)
 reinforcementTimer = 0
 deactivatingVehIds = {}
 -- Clear citizen report state (pursuit ended, report is irrelevant now)
 reportActive = false
 reportTimer = 0
 reportReason = nil
end

getCurrentLevel = function()
 return currentPursuitLevel
end

getDamageCost = function()
 return pursuitDamageCost
end

-- ============================================================================
-- Orphan cleanup: reset ALL police on arrest/evade
-- Vanilla only resets police with matching targetId, which can leave
-- standby units stuck in pursuit state.
-- ============================================================================

cleanupOrphanedPolice = function()
 pcall(function()
 local trafficData = gameplay_traffic.getTrafficData()
 if not trafficData then return end

 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then return end

 for vehId, tData in pairs(trafficData) do
 if vehId ~= playerVehId and tData.role and tData.role.name == 'police' then
 if tData.role.flags and tData.role.flags.pursuit then
 tData.role:resetAction()
 -- Kill siren via FMOD queue
 queueFmodAction({ type = 'siren', vehId = vehId, signal = 0 })
 log('D', logTag, 'Orphan cleanup: reset police unit ' .. tostring(vehId))
 end
 end
 end
 end)
end

-- ============================================================================
-- Pursuit vars configuration (3 levels)
-- ============================================================================

configurePursuitVars = function()
 if not gameplay_police or not gameplay_police.setPursuitVars then
 log('W', logTag, 'gameplay_police.setPursuitVars not available')
 return
 end

 gameplay_police.setPursuitVars({
 scoreLevels = PURSUIT_SCORE_LEVELS,
 strictness = 0.2,
 arrestTime = 5,
 arrestRadius = 15,
 evadeTime = 30,
 evadeRadius = 80,
 suspectFrequency = 0.5,
 roadblockFrequency = 0.5,
 useVisibility = true,
 autoRelease = true
 })
 log('I', logTag, 'Pursuit vars configured: 3 levels, scoreLevels=' .. table.concat(PURSUIT_SCORE_LEVELS, ','))
end

-- ============================================================================
-- Level aggression (simple: set aggression on police units per level)
-- AI mode (follow/chase) is handled by vanilla role system via setPursuitMode
-- ============================================================================

applyLevelAggression = function(level)
 if level < 1 or level > 3 then return end

 local aggression = LEVEL_AGGRESSION[level]

 pcall(function()
 local trafficData = gameplay_traffic.getTrafficData()
 if not trafficData then return end

 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then return end

 for vehId, tData in pairs(trafficData) do
 if tData.role and tData.role.name == 'police' and vehId ~= playerVehId then
 local obj = getObjectByID(vehId)
 if obj then
 obj:queueLuaCommand('ai.setAggression(' .. aggression .. ')')
 end
 end
 end
 end)

 log('I', logTag, string.format('Level %d aggression applied: %.2f', level, aggression))
end

-- ============================================================================
-- Damage cost tracking
-- ============================================================================

checkDamageCosts = function()
 pcall(function()
 local trafficData = gameplay_traffic.getTrafficData()
 if not trafficData then return end
 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then return end

 for vehId, tData in pairs(trafficData) do
 if vehId ~= playerVehId then
 local role = tData.role and tData.role.name
 if role == 'police' or role == 'standard' then
 local curDamage = tData.damage or 0
 local prevDamage = policeDamageSnapshot[vehId] or 0
 local delta = curDamage - prevDamage

 if delta > DAMAGE_DELTA_THRESHOLD then
 local vehValue = (role == 'police') and POLICE_VEHICLE_VALUE or CIVILIAN_VEHICLE_VALUE
 local normalizedDelta = math.min(delta / DAMAGE_TOTALED_THRESHOLD, 1.0)
 local addedCost = math.floor(normalizedDelta * vehValue)
 pursuitDamageCost = pursuitDamageCost + addedCost
 log('D', logTag, string.format(
 'Damage cost: veh=%d role=%s +$%d (total=$%d)',
 vehId, role, addedCost, pursuitDamageCost
 ))
 end
 policeDamageSnapshot[vehId] = curDamage
 end
 end
 end
 end)
end

-- ============================================================================
-- Passive score accumulation + damage-based escalation
-- ============================================================================

accumulatePursuitScore = function(dtSim)
 passiveScoreAccum = passiveScoreAccum + dtSim
 if passiveScoreAccum < PASSIVE_SCORE_INTERVAL then return end
 passiveScoreAccum = passiveScoreAccum - PASSIVE_SCORE_INTERVAL

 pcall(function()
 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then return end

 local trafficData = gameplay_traffic.getTrafficData()
 if not trafficData then return end

 local playerTraffic = trafficData[playerVehId]
 if not playerTraffic or not playerTraffic.pursuit then return end

 local mult = PASSIVE_SCORE_MULTIPLIER[currentPursuitLevel] or 1
 local scoreToAdd = PASSIVE_SCORE_BASE * mult

 -- Speed bonuses
 local speed = playerTraffic.speed or 0
 for i = #OFFENSE_SPEED_THRESHOLDS, 1, -1 do
 if speed >= OFFENSE_SPEED_THRESHOLDS[i] then
 scoreToAdd = scoreToAdd + OFFENSE_SPEED_SCORES[i]
 break
 end
 end

 -- Wrong-way driving
 local tracking = playerTraffic.tracking
 if tracking and tracking.side and tracking.side < 0 then
 scoreToAdd = scoreToAdd + OFFENSE_SCORE_WRONG_WAY
 end

 -- Hit police detection
 for vehId, tData in pairs(trafficData) do
 if vehId ~= playerVehId and tData.role and tData.role.name == 'police' then
 local curDamage = tData.damage or 0
 local prevDamage = policeDamageSnapshot[vehId] or 0
 if curDamage > prevDamage + DAMAGE_DELTA_THRESHOLD then
 scoreToAdd = scoreToAdd + OFFENSE_SCORE_HIT_POLICE
 end
 end
 end

 playerTraffic.pursuit.addScore = scoreToAdd

 -- Damage-based level escalation: call vanilla setPursuitMode to escalate
 local derivedLevel = 1
 for i = #BCM_DAMAGE_LEVELS, 1, -1 do
 if pursuitDamageCost >= BCM_DAMAGE_LEVELS[i] then
 derivedLevel = i
 break
 end
 end
 derivedLevel = math.min(derivedLevel, 3)

 if derivedLevel > currentPursuitLevel then
 log('I', logTag, 'BCM escalation (damage): level ' .. currentPursuitLevel .. ' -> ' .. derivedLevel .. ' (damageCost=$' .. pursuitDamageCost .. ')')
 currentPursuitLevel = derivedLevel
 levelEscalationTimer = 0 -- reset timer on damage-based escalation
 applyLevelAggression(currentPursuitLevel)

 if gameplay_police and gameplay_police.setPursuitMode then
 gameplay_police.setPursuitMode(derivedLevel)
 end

 pcall(function()
 if bcm_policeHud then
 bcm_policeHud.onPursuitEvent({ action = 'level_change', level = derivedLevel })
 end
 end)
 end

 -- Time-based escalation: if stuck at current level for 3 min, auto-escalate
 if currentPursuitLevel > 0 and currentPursuitLevel < 3 then
 levelEscalationTimer = levelEscalationTimer + PASSIVE_SCORE_INTERVAL
 if levelEscalationTimer >= LEVEL_ESCALATION_TIMEOUT then
 local newLevel = currentPursuitLevel + 1
 log('I', logTag, 'BCM escalation (time): level ' .. currentPursuitLevel .. ' -> ' .. newLevel .. ' (timeout ' .. LEVEL_ESCALATION_TIMEOUT .. 's)')
 currentPursuitLevel = newLevel
 levelEscalationTimer = 0
 applyLevelAggression(currentPursuitLevel)

 if gameplay_police and gameplay_police.setPursuitMode then
 gameplay_police.setPursuitMode(newLevel)
 end

 pcall(function()
 if bcm_policeHud then
 bcm_policeHud.onPursuitEvent({ action = 'level_change', level = newLevel })
 end
 end)
 end
 end
 end)
end

-- ============================================================================
-- Recycling (teleport far/damaged police closer via FMOD queue)
-- ============================================================================

checkRecycling = function(dtSim)
 recycleCheckAccum = recycleCheckAccum + dtSim
 if recycleCheckAccum < RECYCLE_CHECK_INTERVAL then return end
 recycleCheckAccum = recycleCheckAccum - RECYCLE_CHECK_INTERVAL

 pcall(function()
 local trafficData = gameplay_traffic.getTrafficData()
 if not trafficData then return end

 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then return end

 local ppx, ppy, ppz = be:getObjectPositionXYZ(playerVehId)

 for vehId, tData in pairs(trafficData) do
 if tData.role and tData.role.name == 'police' and vehId ~= playerVehId then
 -- Skip interceptors
 if interceptorVehIds[vehId] then
 goto continueRecycleLoop
 end

 -- Skip reserve (deactivated) vehicles in flexible mode
 if isFlexibleMode() then
 for _, rid in ipairs(reserveVehIds) do
 if rid == vehId then goto continueRecycleLoop end
 end
 end

 local tpx, tpy, tpz = be:getObjectPositionXYZ(vehId)
 local dx = tpx - ppx
 local dy = tpy - ppy
 local dz = tpz - ppz
 local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
 local damage = tData.damage or 0

 -- Safe zone: never recycle within visual range
 if dist < RECYCLE_SAFE_ZONE then
 goto continueRecycleLoop
 end

 -- Post-recycle cooldown
 local now = os.clock()
 if recycleCooldowns[vehId] and now - recycleCooldowns[vehId] < RECYCLE_COOLDOWN then
 goto continueRecycleLoop
 end

 local shouldRecycle = false
 local reason = ''

 if dist > RECYCLE_DISTANCE then
 shouldRecycle = true
 reason = string.format('distance=%.0f > %d', dist, RECYCLE_DISTANCE)
 elseif damage > RECYCLE_DAMAGE then
 if not damageCooldowns[vehId] then
 damageCooldowns[vehId] = now
 elseif now - damageCooldowns[vehId] >= RECYCLE_DAMAGE_COOLDOWN then
 shouldRecycle = true
 reason = string.format('damage=%.2f > %.2f', damage, RECYCLE_DAMAGE)
 damageCooldowns[vehId] = nil
 end
 else
 damageCooldowns[vehId] = nil
 end

 if shouldRecycle then
 log('I', logTag, 'Recycling vehicle ' .. vehId .. ': ' .. reason)
 recycleVehicle(vehId)
 end

 ::continueRecycleLoop::
 end
 end
 end)
end

recycleVehicle = function(vehId)
 queueFmodAction({ type = 'siren', vehId = vehId, signal = 0 })
 queueFmodAction({ type = 'teleport', vehId = vehId })
 queueFmodAction({ type = 'siren', vehId = vehId, signal = 2 })

 policeDamageSnapshot[vehId] = 0
 recycleCooldowns[vehId] = os.clock()

 log('I', logTag, 'Recycled vehicle ' .. vehId .. ' via FMOD queue')
end

-- ============================================================================
-- Interceptors (level 3 head-on charge)
-- ============================================================================

countInterceptors = function()
 local n = 0
 for _ in pairs(interceptorVehIds) do n = n + 1 end
 return n
end

findInactivePoolMember = function()
 local trafficData = gameplay_traffic.getTrafficData()
 if not trafficData then return nil end

 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then return nil end

 local ppx, ppy, ppz = be:getObjectPositionXYZ(playerVehId)

 for vehId, tData in pairs(trafficData) do
 if tData.role and tData.role.name == 'police' and vehId ~= playerVehId then
 if not interceptorVehIds[vehId] then
 local tpx, tpy, tpz = be:getObjectPositionXYZ(vehId)
 local dx = tpx - ppx
 local dy = tpy - ppy
 local dz = tpz - ppz
 local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
 if dist > 400 then
 return vehId
 end
 end
 end
 end

 return nil
end

spawnInterceptor = function()
 if countInterceptors() >= INTERCEPTOR_MAX_ACTIVE then return end

 local vehId = findInactivePoolMember()
 if not vehId then return end

 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then return end

 local playerObj = getObjectByID(playerVehId)
 if not playerObj then return end

 local playerPos = playerObj:getPosition()
 local pvx, pvy, pvz = be:getObjectVelocityXYZ(playerVehId)
 local playerSpeed = math.sqrt(pvx*pvx + pvy*pvy + pvz*pvz)

 if playerSpeed < 5 then return end

 local fwdDir = vec3(pvx / playerSpeed, pvy / playerSpeed, 0):normalized()

 local positioned = false
 local obj = getObjectByID(vehId)
 if not obj then return end

 pcall(function()
 if not gameplay_traffic_trafficUtils then
 extensions.load('gameplay_traffic_trafficUtils')
 end
 if not gameplay_traffic_trafficUtils or not gameplay_traffic_trafficUtils.findSpawnPointRadial then return end

 local spawnDist = INTERCEPTOR_SPAWN_DIST_MIN + math.random() * (INTERCEPTOR_SPAWN_DIST_MAX - INTERCEPTOR_SPAWN_DIST_MIN)
 local options = {
 gap = 20,
 usePrivateRoads = false,
 minDrivability = 0.5,
 minRadius = 1.0,
 pathRandomization = 0.1
 }

 local spawnData, isValid = gameplay_traffic_trafficUtils.findSpawnPointRadial(
 playerPos, fwdDir, INTERCEPTOR_SPAWN_DIST_MIN, INTERCEPTOR_SPAWN_DIST_MAX, spawnDist, options)

 if isValid and spawnData.pos then
 local finalPos, finalDir = gameplay_traffic_trafficUtils.finalizeSpawnPoint(
 spawnData.pos, spawnData.dir, spawnData.n1, spawnData.n2,
 {legalDirection = false, dirRandomization = 0})

 if finalPos then
 local toPlayer = (playerPos - finalPos):normalized()
 local normal = vec3(0, 0, 1)
 pcall(function()
 normal = map.surfaceNormal(finalPos, 1) or vec3(0, 0, 1)
 end)
 local rot = quatFromDir(toPlayer, normal)

 obj:setPositionRotation(finalPos.x, finalPos.y, finalPos.z, rot.x, rot.y, rot.z, rot.w)
 positioned = true
 end
 end
 end)

 if not positioned then return end

 if playerObj then
 obj:queueLuaCommand('ai.setTarget("' .. playerObj:getName() .. '")')
 obj:queueLuaCommand('ai.setMode("chase")')
 obj:queueLuaCommand('ai.setAggression(' .. INTERCEPTOR_AGGRESSION .. ')')
 end

 interceptorVehIds[vehId] = true
 log('I', logTag, 'Interceptor spawned: vehId=' .. vehId .. ' (active: ' .. countInterceptors() .. ')')
end

cleanupInterceptors = function()
 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then return end

 local ppx, ppy, ppz = be:getObjectPositionXYZ(playerVehId)
 local pvx, pvy, pvz = be:getObjectVelocityXYZ(playerVehId)
 local playerSpeed = math.sqrt(pvx*pvx + pvy*pvy + pvz*pvz)
 if playerSpeed < 2 then return end

 local fwdX = pvx / playerSpeed
 local fwdY = pvy / playerSpeed
 local fwdZ = pvz / playerSpeed

 local trafficData = gameplay_traffic.getTrafficData()

 local toRemove = {}
 for vehId, _ in pairs(interceptorVehIds) do
 if not trafficData or not trafficData[vehId] then
 table.insert(toRemove, vehId)
 else
 local tpx, tpy, tpz = be:getObjectPositionXYZ(vehId)
 local dx = tpx - ppx
 local dy = tpy - ppy
 local dz = tpz - ppz
 local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
 local dot = fwdX * dx + fwdY * dy + fwdZ * dz

 if dot < -0.3 and dist > INTERCEPTOR_PASS_DISTANCE then
 table.insert(toRemove, vehId)
 local obj = getObjectByID(vehId)
 if obj then
 obj:queueLuaCommand('ai.setMode("traffic")')
 obj:queueLuaCommand('ai.setAggression(0.05)')
 end
 end
 end
 end

 for _, vehId in ipairs(toRemove) do
 interceptorVehIds[vehId] = nil
 end
end

-- ============================================================================
-- Pursuit lifecycle (BeamNG hook: onPursuitAction)
-- ============================================================================

onPursuitAction = function(vehId, action, pursuitData)
 if not activated then return end

 -- Only track player vehicle
 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or vehId ~= playerVehId then return end

 -- Get player speed
 local vx, vy, vz = 0, 0, 0
 pcall(function()
 vx, vy, vz = be:getObjectVelocityXYZ(vehId)
 end)
 local speed = math.sqrt((vx or 0)^2 + (vy or 0)^2 + (vz or 0)^2)

 -- Get player position
 local px, py, pz = 0, 0, 0
 pcall(function()
 px, py, pz = be:getObjectPositionXYZ(vehId)
 end)

 -- Extract pursuit data fields
 local mode = (pursuitData and pursuitData.mode) or 0
 local score = (pursuitData and pursuitData.score) or 0
 local offenses = (pursuitData and pursuitData.uniqueOffensesCount) or 0

 local offenseTypes = {}
 if pursuitData and pursuitData.offenses then
 for offenseKey, _ in pairs(pursuitData.offenses) do
 table.insert(offenseTypes, offenseKey)
 end
 end

 local duration = 0
 if pursuitStartTime > 0 then
 duration = os.clock() - pursuitStartTime
 end

 -- Build enriched event data
 local data = {
 action = action,
 level = mode,
 score = score,
 offenses = offenses,
 offenseTypes = offenseTypes,
 bcmPursuitReason = bcmPursuitReason,
 pursuitStartTime = pursuitStartTime,
 vehicleId = vehId,
 speed = speed,
 position = { x = px, y = py, z = pz },
 duration = duration,
 damageCost = pursuitDamageCost
 }

 -- Track pursuit start
 if action == 'start' then
 pursuitStartTime = os.clock()
 policeStats.totalPursuits = policeStats.totalPursuits + 1
 pursuitWasActive = true
 stuckTimer = 0
 stuckRespawnAttempts = 0
 data.duration = 0

 -- Initialize BCM pursuit state
 bcmPursuitActive = true
 currentPursuitLevel = math.max(1, mode)
 pursuitDamageCost = 0
 passiveScoreAccum = 0
 levelEscalationTimer = 0

 -- Snapshot current damage of all vehicles so pre-existing damage is not counted
 policeDamageSnapshot = {}
 pcall(function()
 local td = gameplay_traffic.getTrafficData()
 if td then
 for vehId, tData in pairs(td) do
 if tData.damage then
 policeDamageSnapshot[vehId] = tData.damage
 end
 end
 end
 end)
 recycleCheckAccum = 0
 damageCheckAccum = 0
 damageCooldowns = {}
 recycleCooldowns = {}
 interceptorTimer = 0
 interceptorVehIds = {}

 -- Reset flexible reinforcement timer
 reinforcementTimer = 0
 deactivatingVehIds = {}

 applyLevelAggression(currentPursuitLevel)
 end

 -- Track terminal events
 if action == 'arrest' then
 policeStats.totalArrests = policeStats.totalArrests + 1
 pursuitWasActive = false
 pursuitStartTime = 0
 stuckTimer = 0
 stuckRespawnAttempts = 0

 -- Clean up spike strips + orphaned police
 cleanupSpikeStrips()
 cleanupOrphanedPolice()
 resetBcmPursuitState()

 elseif action == 'evade' then
 policeStats.totalEvasions = policeStats.totalEvasions + 1
 pursuitWasActive = false
 pursuitStartTime = 0
 stuckTimer = 0
 stuckRespawnAttempts = 0

 if triggerPursuitActive then
 triggerPursuitActive = false
 configurePursuitVars()
 end

 cleanupSpikeStrips()
 cleanupOrphanedPolice()
 resetBcmPursuitState()

 elseif action == 'roadblock' then
 -- Vanilla just placed a roadblock — deploy spike strips at the roadblock position
 log('I', logTag, 'Pursuit event: roadblock placed')
 if pursuitData and pursuitData.roadblockPos and currentPursuitLevel >= 3 then
 -- Clean up previous spike strips so new ones can deploy at the new roadblock
 cleanupSpikeStrips()

 local rbPos = pursuitData.roadblockPos

 -- Replicate vanilla's findSpawnPointOnRoute to get spawnData.dir (road direction)
 -- Vanilla uses quatFromDir(spawnData.dir, spawnData.normal) to place roadblock vehicles
 local roadDir = nil
 local roadNormal = nil
 local heading = 0
 pcall(function()
 local td = gameplay_traffic.getTrafficData()
 local playerVeh = td and td[vehId]
 if playerVeh and playerVeh.pos and playerVeh.dirVec then
 local spawnData = gameplay_traffic_trafficUtils.findSpawnPointOnRoute(
 playerVeh.pos, playerVeh.dirVec, 100, 300, 200, {pathRandomization = 0}
 )
 if spawnData and spawnData.dir then
 roadDir = spawnData.dir
 roadNormal = spawnData.normal
 heading = math.atan2(spawnData.dir.y, spawnData.dir.x)
 log('I', logTag, string.format('Roadblock dir: (%.2f,%.2f,%.2f) normal: %s',
 roadDir.x, roadDir.y, roadDir.z, tostring(roadNormal)))
 end
 end
 end)

 log('I', logTag, string.format('Deploying spike strips at roadblock pos=(%.1f,%.1f,%.1f)', rbPos.x, rbPos.y, rbPos.z))
 deploySpikeStrips({ x = rbPos.x, y = rbPos.y, z = rbPos.z }, heading, roadDir, roadNormal)
 end

 elseif action == 'reset' then
 pursuitWasActive = false
 pursuitStartTime = 0
 stuckTimer = 0
 stuckRespawnAttempts = 0

 if triggerPursuitActive then
 triggerPursuitActive = false
 configurePursuitVars()
 end

 cleanupOrphanedPolice()
 resetBcmPursuitState()
 end

 -- Detect level change (synthesize level_change event)
 if mode ~= lastPursuitLevel and lastPursuitLevel >= 0 and mode > 0 then
 -- Update BCM level if vanilla escalated (e.g., score-based to level 1)
 if mode > currentPursuitLevel then
 currentPursuitLevel = mode
 applyLevelAggression(currentPursuitLevel)
 end

 local levelChangeData = {
 action = 'level_change',
 level = mode,
 prevLevel = lastPursuitLevel,
 score = score,
 offenses = offenses,
 offenseTypes = offenseTypes,
 pursuitStartTime = pursuitStartTime,
 vehicleId = vehId,
 speed = speed,
 position = { x = px, y = py, z = pz },
 duration = duration,
 damageCost = pursuitDamageCost
 }

 log('I', logTag, string.format(
 'PURSUIT EVENT: action=%s level=%d->%d score=%.0f offenses=%d veh=%d speed=%.1f duration=%.1f',
 'level_change', lastPursuitLevel, mode, score, offenses, vehId, speed, duration
 ))

 -- Dispatch level_change to BCM modules
 pcall(function()
 if bcm_heatSystem then bcm_heatSystem.onPursuitEvent(levelChangeData) end
 end)
 pcall(function()
 if bcm_fines then bcm_fines.onPursuitEvent(levelChangeData) end
 end)
 pcall(function()
 if bcm_policeHud then bcm_policeHud.onPursuitEvent(levelChangeData) end
 end)
 pcall(function()
 if bcm_policeDamage then bcm_policeDamage.onPursuitEvent(levelChangeData) end
 end)
 -- Breaking news: pursuit escalation (no email — news only)
 pcall(function()
 if bcm_breakingNews and bcm_breakingNews.onEvent then
 -- unitCount: interceptors + base vanilla units (approximate via level * 2)
 local unitCount = countInterceptors() + (mode * 2)
 bcm_breakingNews.onEvent('pursuit_escalation', {
 level = mode,
 unitCount = unitCount
 })
 end
 end)
 end

 -- Update last pursuit level
 lastPursuitLevel = mode

 -- Log all events
 log('I', logTag, string.format(
 'PURSUIT EVENT: action=%s level=%d score=%.0f offenses=%d veh=%d speed=%.1f duration=%.1f damageCost=$%d',
 tostring(action), mode, score, offenses, vehId, speed, duration, pursuitDamageCost
 ))

 -- Dispatch to BCM modules
 pcall(function()
 if bcm_heatSystem then bcm_heatSystem.onPursuitEvent(data) end
 end)
 pcall(function()
 if bcm_fines then bcm_fines.onPursuitEvent(data) end
 end)
 pcall(function()
 if bcm_policeHud then bcm_policeHud.onPursuitEvent(data) end
 end)
 pcall(function()
 if bcm_policeDamage then bcm_policeDamage.onPursuitEvent(data) end
 end)
end

-- ============================================================================
-- Pursuit stuck detection (called from playerDriving.lua onUpdate)
-- ============================================================================

onPursuitUpdate = function(dtSim, playerData, playerVehId)
 if not activated then return end
 if not pursuitWasActive then return end
 if not playerData or not playerData.traffic then return end

 local traffic = playerData.traffic
 if not traffic.pursuit then return end

 local isStuck = traffic.speed < STUCK_SPEED_THRESHOLD
 and traffic.pursuit.timers
 and traffic.pursuit.timers.arrest == 0
 and traffic.pursuit.timers.evade == 0

 if isStuck then
 stuckTimer = stuckTimer + dtSim
 if stuckTimer >= STUCK_TIME_THRESHOLD then
 if stuckRespawnAttempts < 2 then
 local respawned = false
 pcall(function()
 local trafficData = gameplay_traffic.getTrafficData()
 if trafficData then
 local ppx, ppy, ppz = be:getObjectPositionXYZ(playerVehId)
 local pvx, pvy, pvz = be:getObjectVelocityXYZ(playerVehId)
 local pSpeed = math.sqrt(pvx*pvx + pvy*pvy + pvz*pvz)

 for tVehId, tData in pairs(trafficData) do
 if tData.role and tData.role.name == 'police' and tData.speed < 1 and tVehId ~= playerVehId then
 local isBehind = false
 if pSpeed > 0.5 then
 local tpx, tpy, tpz = be:getObjectPositionXYZ(tVehId)
 local dx = tpx - ppx
 local dy = tpy - ppy
 local dz = tpz - ppz
 local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
 if dist > 0.1 then
 local dot = (pvx * dx + pvy * dy + pvz * dz) / (pSpeed * dist)
 isBehind = dot < -0.3
 end
 end

 if not isBehind then
 gameplay_police.evadeVehicle(tVehId, true)
 sirenState[tVehId] = nil
 respawned = true
 log('I', logTag, 'Stuck detection: evaded stuck police unit ' .. tostring(tVehId))
 break
 end
 end
 end
 end
 end)

 stuckRespawnAttempts = stuckRespawnAttempts + 1
 stuckTimer = 0
 else
 -- Force-evade player vehicle
 log('I', logTag, 'Force-evade after 2 respawn attempts')
 if gameplay_police and gameplay_police.evadeVehicle then
 gameplay_police.evadeVehicle(playerVehId, true)
 end

 local evx, evy, evz = 0, 0, 0
 local epx, epy, epz = 0, 0, 0
 pcall(function()
 evx, evy, evz = be:getObjectVelocityXYZ(playerVehId)
 epx, epy, epz = be:getObjectPositionXYZ(playerVehId)
 end)
 local espeed = math.sqrt(evx*evx + evy*evy + evz*evz)
 local eduration = pursuitStartTime > 0 and (os.clock() - pursuitStartTime) or 0

 local timeoutData = {
 action = 'timeout_evade',
 level = lastPursuitLevel,
 score = 0,
 offenses = 0,
 offenseTypes = {},
 pursuitStartTime = pursuitStartTime,
 vehicleId = playerVehId,
 speed = espeed,
 position = { x = epx, y = epy, z = epz },
 duration = eduration,
 damageCost = pursuitDamageCost
 }

 pcall(function()
 if bcm_heatSystem then bcm_heatSystem.onPursuitEvent(timeoutData) end
 end)
 pcall(function()
 if bcm_fines then bcm_fines.onPursuitEvent(timeoutData) end
 end)

 stuckTimer = 0
 stuckRespawnAttempts = 0
 pursuitWasActive = false
 pursuitStartTime = 0
 resetBcmPursuitState()
 end
 end
 else
 stuckTimer = 0
 end
end

-- ============================================================================
-- Patrol stuck detection (runs every PATROL_CHECK_INTERVAL seconds)
-- ============================================================================

onPatrolUpdate = function(dtSim)
 if not activated then return end

 pcall(function()
 local trafficData = gameplay_traffic.getTrafficData()
 if not trafficData then return end

 local activeVehIds = {}

 for vehId, tData in pairs(trafficData) do
 if tData.role and tData.role.name == 'police' then
 -- Skip reserve (deactivated) vehicles in flexible mode
 local isReserve = false
 if isFlexibleMode() then
 for _, rid in ipairs(reserveVehIds) do
 if rid == vehId then isReserve = true; break end
 end
 end

 if not isReserve and not (tData.pursuit and tData.pursuit.mode and tData.pursuit.mode > 0) then
 activeVehIds[vehId] = true

 if not patrolStuckTimers[vehId] then
 patrolStuckTimers[vehId] = { timer = 0, respawnCount = 0 }
 end

 local pst = patrolStuckTimers[vehId]

 if tData.speed < 1 then
 pst.timer = pst.timer + PATROL_CHECK_INTERVAL
 if pst.timer > PATROL_STUCK_THRESHOLD and pst.respawnCount < MAX_PATROL_RESPAWNS then
 gameplay_police.evadeVehicle(vehId, true)
 sirenState[vehId] = nil
 pst.respawnCount = pst.respawnCount + 1
 pst.timer = 0
 log('I', logTag, 'Patrol stuck: evaded idle police unit ' .. tostring(vehId))
 end
 else
 pst.timer = 0
 end
 end
 end
 end

 for vehId, _ in pairs(patrolStuckTimers) do
 if not activeVehIds[vehId] then
 patrolStuckTimers[vehId] = nil
 end
 end
 end)
end

-- ============================================================================
-- Save/Load
-- ============================================================================

savePoliceData = function(currentSavePath)
 if not career_saveSystem then return end

 local bcmDir = currentSavePath .. "/career/bcm"
 if not FS:directoryExists(bcmDir) then
 FS:directoryCreate(bcmDir)
 end

 local data = {
 stats = policeStats,
 pursuitWasActive = pursuitWasActive,
 -- Radar spots are re-selected fresh on each load, no need to persist
 }

 career_saveSystem.jsonWriteFileSafe(bcmDir .. "/" .. SAVE_FILE, data, true)
 log('I', logTag, 'Saved police data: pursuits=' .. policeStats.totalPursuits .. ' evasions=' .. policeStats.totalEvasions .. ' arrests=' .. policeStats.totalArrests)
end

loadPoliceData = function()
 if not career_career or not career_career.isActive() then return end
 if not career_saveSystem then return end

 local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
 if not currentSaveSlot then return end

 local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
 if not autosavePath then return end

 local dataPath = autosavePath .. "/career/bcm/" .. SAVE_FILE
 local data = jsonReadFile(dataPath)

 if data then
 if data.stats then
 policeStats.totalPursuits = data.stats.totalPursuits or 0
 policeStats.totalEvasions = data.stats.totalEvasions or 0
 policeStats.totalArrests = data.stats.totalArrests or 0
 end
 pursuitWasActive = data.pursuitWasActive or false
 -- Radar spots re-selected fresh on load (no restore needed)
 log('I', logTag, 'Loaded police data: pursuits=' .. policeStats.totalPursuits .. ' evasions=' .. policeStats.totalEvasions .. ' arrests=' .. policeStats.totalArrests)
 else
 policeStats = { totalPursuits = 0, totalEvasions = 0, totalArrests = 0 }
 pursuitWasActive = false
 log('I', logTag, 'No saved police data found, using defaults')
 end
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

onCareerModulesActivated = function(alreadyInLevel)
 activated = true
 loadPoliceData()
 configurePursuitVars()

 -- Reset pursuit state
 lastPursuitLevel = 0
 pursuitStartTime = 0
 stuckTimer = 0
 stuckRespawnAttempts = 0
 patrolStuckTimers = {}
 patrolCheckAccumulator = 0
 triggerPursuitActive = false
 sirenState = {}
 poolSpawnRequested = false

 resetBcmPursuitState()

 -- Load radar spots from devtool-exported JSON (or defaults)
 loadRadarSpots()

 -- Validate config pool
 pcall(function()
 validateConfigPool()
 end)

 -- Try to spawn police if traffic is already running
 pcall(function()
 if gameplay_traffic and gameplay_traffic.getTrafficData() then
 spawnPolicePool()
 end
 end)

 log('I', logTag, 'BCM Police activated — stats: pursuits=' .. policeStats.totalPursuits .. ' evasions=' .. policeStats.totalEvasions .. ' arrests=' .. policeStats.totalArrests)
end

onSaveCurrentSaveSlot = function(currentSavePath, oldSaveIdentifier, forceSyncSave)
 if not activated then return end
 savePoliceData(currentSavePath)
end

onSettingChanged = function(key, value)
 log('I', logTag, 'Setting changed: ' .. tostring(key) .. ' = ' .. tostring(value))

 if key == 'policeEnabled' and value == false then
 -- Deactivate all active police units via the flexible pool system (clean teardown)
 local toDeactivate = {}
 for _, vehId in ipairs(activeFlexVehIds) do
 table.insert(toDeactivate, vehId)
 end
 for _, vehId in ipairs(toDeactivate) do
 deactivateReserveUnit(vehId)
 end
 -- Also despawn radar cars (these are stationary, not in the flex pool)
 despawnRadarCars()
 log('I', logTag, 'Police disabled — deactivated ' .. #toDeactivate .. ' pool units + radar cars (reserve=' .. #reserveVehIds .. ')')
 elseif key == 'policeEnabled' and value == true then
 -- Reset any active pursuit state first — police should start fresh in patrol mode
 resetPursuit()

 -- Re-enable: spawn fresh pool (don't reuse reserves — they may have stale AI state)
 poolSpawnRequested = false
 spawnPolicePool()
 log('I', logTag, 'Police re-enabled — spawning fresh pool + reset pursuit state')

 -- Also re-spawn radar cars
 despawnRadarCars()
 selectRadarSpots()
 spawnRadarCars()
 elseif key == 'policeSpawnMode' then
 if value == 'static' then
 -- Switching to static: activate all reserves immediately
 while #reserveVehIds > 0 do
 activateReserveUnit()
 end
 deactivatingVehIds = {}
 log('I', logTag, 'Switched to static mode — all reserves activated')
 elseif value == 'flexible' and not bcmPursuitActive then
 -- Switching to flexible during idle: deactivate excess
 -- This will happen naturally via updateReserveDeactivation on next tick
 log('I', logTag, 'Switched to flexible mode — excess units will deactivate')
 end
 end
end

onTrafficStarted = function()
 -- Reload radar spots from JSON (may have been exported since activation)
 loadRadarSpots()

 pcall(function()
 spawnPolicePool()
 end)
 -- Spawn mobile radar cars
 pcall(function()
 if #activeSpotIndices == 0 then
 selectRadarSpots()
 end
 spawnRadarCars()
 -- Set initial rotation time
 if nextRadarRotation == 0 then
 if bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
 nextRadarRotation = bcm_timeSystem.getGameTimeDays() + (RADAR_ROTATION_HOURS / 24)
 end
 end
 end)
end

onTrafficStopped = function()
 despawnRadarCars()
 cleanupSpikeStrips()
 resetBcmPursuitState()
 fmodQueue = {}
 fmodQueueAccum = 0
 poolSpawnRequested = false
 sirenState = {}
 patrolStuckTimers = {}
 flexPoolVehIds = {}
 allEverSpawnedPolice = {}
 reserveVehIds = {}
 activeFlexVehIds = {}
 deactivatingVehIds = {}
 reinforcementTimer = 0
 reportActive = false
 reportTimer = 0
 reportReason = nil
 reportDamageSnapshot = {}
 reportCheckTimer = 0
 reportVisibleDamageCooldown = 0
end

onClientEndMission = function()
 despawnRadarCars()
 cleanupSpikeStrips()
 resetBcmPursuitState()
 fmodQueue = {}
 fmodQueueAccum = 0
 activated = false
 validatedConfigs = nil
 poolSpawnRequested = false
 sirenState = {}
 patrolStuckTimers = {}
 flexPoolVehIds = {}
 allEverSpawnedPolice = {}
 reserveVehIds = {}
 activeFlexVehIds = {}
 deactivatingVehIds = {}
 reinforcementTimer = 0
 reportActive = false
 reportTimer = 0
 reportReason = nil
 reportDamageSnapshot = {}
 reportCheckTimer = 0
 reportVisibleDamageCooldown = 0
end

-- ============================================================================
-- Debug commands
-- ============================================================================

spawnPolice = function()
 log('I', logTag, 'Debug: spawnPolice — forcing traffic respawn')
 pcall(function()
 if career_modules_playerDriving and career_modules_playerDriving.setupTraffic then
 career_modules_playerDriving.ensureTraffic = true
 if gameplay_traffic and gameplay_traffic.setupTraffic then
 gameplay_traffic.setupTraffic(0, 0, {})
 end
 end
 end)
end

triggerPursuit = function(level)
 level = math.max(1, math.min(3, level or 1))
 log('I', logTag, 'Debug: triggerPursuit level=' .. level)

 pcall(function()
 if gameplay_police and gameplay_police.setPursuitVars then
 gameplay_police.setPursuitVars({
 scoreLevels = {1, 2, 3}
 })
 triggerPursuitActive = true
 end

 -- Inject pursuit score to actually start the pursuit
 local playerVehId = be:getPlayerVehicleID(0)
 if playerVehId and playerVehId >= 0 and gameplay_traffic then
 local trafficData = gameplay_traffic.getTrafficData()
 if trafficData and trafficData[playerVehId] and trafficData[playerVehId].pursuit then
 trafficData[playerVehId].pursuit.addScore = 5
 log('I', logTag, 'triggerPursuit: injected score=5 to player pursuit data')
 else
 log('W', logTag, 'triggerPursuit: no pursuit data found for player vehicle')
 end
 end
 end)
end

resetPursuit = function()
 log('I', logTag, 'Debug: resetPursuit')

 pcall(function()
 local playerVehId = be:getPlayerVehicleID(0)
 if playerVehId and playerVehId >= 0 and gameplay_police then
 gameplay_police.evadeVehicle(playerVehId, true)
 end
 end)

 configurePursuitVars()
 triggerPursuitActive = false
 lastPursuitLevel = 0
 pursuitStartTime = 0
 stuckTimer = 0
 stuckRespawnAttempts = 0
 resetBcmPursuitState()
end

printStatus = function()
 local policeEnabled = true
 local policeCount = 3
 pcall(function()
 if bcm_settings then
 policeEnabled = bcm_settings.getSetting('policeEnabled') ~= false
 policeCount = bcm_settings.getSetting('policeCount') or 3
 end
 end)

 local totalPolice = 0
 local activePolice = 0
 pcall(function()
 local trafficData = gameplay_traffic.getTrafficData()
 if trafficData then
 for vehId, tData in pairs(trafficData) do
 if tData.role and tData.role.name == 'police' then
 totalPolice = totalPolice + 1
 if tData.isActive then
 activePolice = activePolice + 1
 end
 end
 end
 end
 end)

 log('I', logTag, '========== BCM POLICE STATUS ==========')
 log('I', logTag, 'policeEnabled: ' .. tostring(policeEnabled))
 log('I', logTag, 'policeCount (setting): ' .. tostring(policeCount))
 log('I', logTag, 'Police in traffic: ' .. totalPolice .. ' (active: ' .. activePolice .. ')')
 log('I', logTag, 'Stats: pursuits=' .. policeStats.totalPursuits .. ' evasions=' .. policeStats.totalEvasions .. ' arrests=' .. policeStats.totalArrests)
 log('I', logTag, 'pursuitWasActive: ' .. tostring(pursuitWasActive))
 log('I', logTag, 'currentPursuitLevel: ' .. currentPursuitLevel)
 log('I', logTag, 'lastPursuitLevel: ' .. lastPursuitLevel)
 log('I', logTag, 'bcmPursuitActive: ' .. tostring(bcmPursuitActive))
 log('I', logTag, 'pursuitDamageCost: $' .. tostring(pursuitDamageCost))
 log('I', logTag, 'fmodQueue size: ' .. #fmodQueue)
 log('I', logTag, 'active interceptors: ' .. countInterceptors())
 log('I', logTag, 'stuckTimer: ' .. string.format('%.1f', stuckTimer))
 log('I', logTag, 'triggerPursuitActive: ' .. tostring(triggerPursuitActive))
 log('I', logTag, '--- Flexible Spawn ---')
 log('I', logTag, 'mode: ' .. (isFlexibleMode() and 'flexible' or 'static'))
 log('I', logTag, 'flexPoolVehIds: ' .. #flexPoolVehIds)
 log('I', logTag, 'activeFlexVehIds: ' .. #activeFlexVehIds)
 log('I', logTag, 'reserveVehIds: ' .. #reserveVehIds)
 log('I', logTag, 'deactivatingVehIds: ' .. tableSize(deactivatingVehIds))
 log('I', logTag, 'reinforcementTimer: ' .. string.format('%.1f', reinforcementTimer))
 log('I', logTag, 'reinforcementInterval: ' .. string.format('%.1f', getReinforcementInterval()))
 log('I', logTag, '--- Citizen Reports ---')
 log('I', logTag, 'reportActive: ' .. tostring(reportActive))
 log('I', logTag, 'reportTimer: ' .. string.format('%.1f', reportTimer) .. 's')
 log('I', logTag, 'reportReason: ' .. tostring(reportReason))
 log('I', logTag, '========================================')
end

-- ============================================================================
-- onUpdate — main tick
-- ============================================================================
local function onUpdate(dtReal, dtSim, dtRaw)
 if not activated then return end

 -- Process FMOD action queue
 pcall(function()
 processFmodQueue(dtSim)
 end)

 -- Flexible mode: deactivate reserves on first tick after spawn
 if isFlexibleMode() and #reserveVehIds > 0 and not bcmPursuitActive then
 for _, vehId in ipairs(reserveVehIds) do
 local obj = be:getObjectByID(vehId)
 if obj then
 local isObjActive = true
 pcall(function() isObjActive = be:getObjectActive(vehId) end)
 if isObjActive then
 pcall(function() gameplay_traffic.removeTraffic(vehId, true) end)
 pcall(function() obj:setActive(0) end)
 log('D', logTag, 'Initial deactivation of reserve unit: ' .. tostring(vehId))
 end
 end
 end
 end

 -- Flexible spawn mode: reinforcement timer during pursuit
 updateReinforcementTimer(dtReal)
 -- Flexible spawn mode: deactivate excess units after pursuit
 updateReserveDeactivation(dtReal)

 -- BCM pursuit tick (damage check, passive score, recycling, interceptors)
 if bcmPursuitActive then
 pcall(function()
 -- Damage cost check (0.5s tick)
 damageCheckAccum = damageCheckAccum + dtSim
 if damageCheckAccum >= DAMAGE_CHECK_INTERVAL then
 damageCheckAccum = damageCheckAccum - DAMAGE_CHECK_INTERVAL
 checkDamageCosts()
 end

 -- Passive score accumulation + escalation check (5s tick)
 accumulatePursuitScore(dtSim)

 -- Recycling
 checkRecycling(dtSim)

 -- Interceptors (level 3)
 if currentPursuitLevel >= 3 then
 interceptorTimer = interceptorTimer + dtSim
 if interceptorTimer >= INTERCEPTOR_INTERVAL then
 interceptorTimer = 0
 spawnInterceptor()
 end
 cleanupInterceptors()
 end
 end)
 end

 -- Radar car rotation (detection now handled by BeamNGTrigger zones, not distance)
 pcall(function()
 rotateRadarSpots()
 end)

 -- No-plate detection (always active, passive patrol)
 pcall(function()
 checkNoPlate(dtSim)
 end)

 -- Citizen reports: detect infractions and check if police spots reported player
 pcall(function()
 checkCitizenReports(dtSim)
 end)
 pcall(function()
 checkReportedSighting(dtSim)
 end)

 -- Auto-detect pursuit state from traffic data (fallback for missed events)
 pcall(function()
 local playerVehId = be:getPlayerVehicleID(0)
 if playerVehId and playerVehId >= 0 then
 local td = gameplay_traffic.getTrafficData()
 local pt = td and td[playerVehId]
 if pt and pt.pursuit and pt.pursuit.mode and pt.pursuit.mode > 0 then
 if not bcmPursuitActive then
 bcmPursuitActive = true
 currentPursuitLevel = math.max(1, pt.pursuit.mode)
 pursuitDamageCost = 0
 policeDamageSnapshot = {}
 passiveScoreAccum = 0
 recycleCheckAccum = 0
 damageCheckAccum = 0
 damageCooldowns = {}
 recycleCooldowns = {}
 interceptorTimer = 0
 interceptorVehIds = {}
 log('I', logTag, 'BCM pursuit detected via traffic data — level ' .. currentPursuitLevel)
 end
 -- Update level if vanilla escalated
 if pt.pursuit.mode > currentPursuitLevel then
 currentPursuitLevel = pt.pursuit.mode
 applyLevelAggression(currentPursuitLevel)
 end
 elseif bcmPursuitActive then
 log('I', logTag, 'BCM pursuit ended (traffic mode=0) — damageCost=$' .. pursuitDamageCost)
 resetBcmPursuitState()
 end
 end
 end)

 -- Patrol stuck detection + siren management (every PATROL_CHECK_INTERVAL seconds)
 patrolCheckAccumulator = patrolCheckAccumulator + dtSim
 if patrolCheckAccumulator >= PATROL_CHECK_INTERVAL then
 onPatrolUpdate(patrolCheckAccumulator)
 patrolCheckAccumulator = 0

 -- FMOD siren proximity management: only 2 closest police get siren+lights
 pcall(function()
 local trafficData = gameplay_traffic.getTrafficData()
 if not trafficData then return end

 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then return end

 local ppx, ppy, ppz = be:getObjectPositionXYZ(playerVehId)

 local playerTraffic = trafficData[playerVehId]
 local pursuitActive = playerTraffic and playerTraffic.pursuit and playerTraffic.pursuit.mode and playerTraffic.pursuit.mode > 0

 local policeList = {}
 local activeVehIds = {}
 for vehId, tData in pairs(trafficData) do
 if tData.role and tData.role.name == 'police' and vehId ~= playerVehId then
 local tpx, tpy, tpz = be:getObjectPositionXYZ(vehId)
 local dx = tpx - ppx
 local dy = tpy - ppy
 local dz = tpz - ppz
 local distSq = dx*dx + dy*dy + dz*dz
 table.insert(policeList, { id = vehId, distSq = distSq })
 activeVehIds[vehId] = true
 end
 end

 table.sort(policeList, function(a, b) return a.distSq < b.distSq end)

 local MAX_SIREN_COUNT = 2
 for i, entry in ipairs(policeList) do
 local obj = getObjectByID(entry.id)
 if obj then
 local desiredSignal = (pursuitActive and i <= MAX_SIREN_COUNT) and 2 or 0
 local currentSignal = sirenState[entry.id]
 if currentSignal ~= desiredSignal then
 obj:queueLuaCommand('electrics.set_lightbar_signal(' .. desiredSignal .. ')')
 sirenState[entry.id] = desiredSignal
 end
 end
 end

 for vehId, _ in pairs(sirenState) do
 if not activeVehIds[vehId] then
 sirenState[vehId] = nil
 end
 end
 end)
 end
end

-- ============================================================================
-- M table exports
-- ============================================================================

-- Lifecycle hooks (BeamNG dispatches these)
M.onBeamNGTrigger = onBeamNGTrigger
M.onPursuitAction = onPursuitAction
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onTrafficStarted = onTrafficStarted
M.onTrafficStopped = onTrafficStopped
M.onClientEndMission = onClientEndMission
M.onVehicleGroupSpawned = onVehicleGroupSpawned

-- Called by playerDriving.lua onUpdate (optional coupling)
M.onPursuitUpdate = onPursuitUpdate

-- Called by settings.lua applySettingToModule
M.onSettingChanged = onSettingChanged

-- Main tick
M.onUpdate = onUpdate

-- Public API (used by policeHud)
M.getCurrentLevel = getCurrentLevel
M.getDamageCost = getDamageCost

-- Debug commands
M.spawnPolice = spawnPolice
M.triggerPursuit = triggerPursuit
M.resetPursuit = resetPursuit
M.printStatus = printStatus

-- Tutorial API: disable all police activity
M.deactivateAllUnits = function()
 -- 1. Disable vanilla police runtime (stops pursuits, suspect detection, etc.)
 if gameplay_police then
 gameplay_police.enabled = false
 end

 -- 2. Deactivate all BCM police vehicles (stop AI + hide)
 local count = 0
 for _, vehId in ipairs(allEverSpawnedPolice) do
 local obj = be:getObjectByID(vehId)
 if obj then
 obj:queueLuaCommand('ai.setMode("stop")')
 obj:setActive(0)
 count = count + 1
 end
 end

 -- Rebuild tracking: all to reserve, none active
 activeFlexVehIds = {}
 reserveVehIds = {}
 for _, vehId in ipairs(flexPoolVehIds) do
 local obj = be:getObjectByID(vehId)
 if obj then
 table.insert(reserveVehIds, vehId)
 end
 end

 -- Also hide radar cars
 despawnRadarCars()
 log('I', logTag, 'Tutorial: disabled police runtime + deactivated ' .. count .. ' vehicles (ever spawned=' .. #allEverSpawnedPolice .. ', reserve=' .. #reserveVehIds .. ')')
end

-- Tutorial API: reactivate units from reserve based on current spawn mode
-- Note: does NOT check policeEnabled — the tutorial temporarily deactivated
-- units and must restore them regardless. If the player had police disabled
-- before the tutorial, there would be no units in the pool to reactivate.
M.reactivatePool = function()
 -- Reset pursuit state so police start fresh in patrol mode
 resetPursuit()

 -- Reset vanilla police pursuit state
 if gameplay_police and gameplay_police.setPursuitMode then
 gameplay_police.setPursuitMode(0)
 end

 -- Re-enable vanilla police runtime
 if gameplay_police then
 gameplay_police.enabled = true
 end

 local mode = bcm_settings and bcm_settings.getSetting('policeSpawnMode') or 'flexible'

 if mode == 'static' then
 -- Static mode: activate ALL reserve units
 while #reserveVehIds > 0 do
 if not activateReserveUnit() then break end
 end
 log('I', logTag, 'Tutorial end: static mode — activated all (active=' .. #activeFlexVehIds .. ')')
 else
 -- Flexible mode: activate up to flexMin
 local flexMin = bcm_settings and bcm_settings.getSetting('policeFlexMin') or 1
 local toActivate = math.max(0, flexMin - #activeFlexVehIds)
 for i = 1, toActivate do
 if not activateReserveUnit() then break end
 end
 log('I', logTag, 'Tutorial end: flexible mode — reactivated to flexMin (active=' .. #activeFlexVehIds .. ' reserve=' .. #reserveVehIds .. ')')
 end

 -- Re-spawn radar cars
 pcall(function()
 selectRadarSpots()
 spawnRadarCars()
 end)
end
M.testSpikeStrips = function()
 pcall(function()
 -- Clean up any existing strips first
 cleanupSpikeStrips()
 spikeStripsDeployed = false

 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId < 0 then
 log('E', logTag, 'testSpikeStrips: no player vehicle')
 return
 end

 local trafficData = gameplay_traffic.getTrafficData()
 if not trafficData or not trafficData[playerVehId] then
 log('E', logTag, 'testSpikeStrips: no traffic data for player')
 return
 end

 local playerVeh = trafficData[playerVehId]
 local playerPos = playerVeh.pos or vec3(be:getObjectPositionXYZ(playerVehId))
 local playerDir = playerVeh.dirVec
 if not playerDir then
 local obj = getObjectByID(playerVehId)
 playerDir = obj:getDirectionVector()
 end

 -- Use vanilla's findSpawnPointOnRoute to find a road point 80-200m ahead
 local spawnData = nil
 if gameplay_traffic_trafficUtils and gameplay_traffic_trafficUtils.findSpawnPointOnRoute then
 spawnData = gameplay_traffic_trafficUtils.findSpawnPointOnRoute(playerPos, playerDir, 80, 200, 140, {pathRandomization = 0})
 end

 if not spawnData or not spawnData.pos then
 log('W', logTag, 'testSpikeStrips: findSpawnPointOnRoute returned nil, fallback')
 local ppx, ppy, ppz = be:getObjectPositionXYZ(playerVehId)
 local heading = math.atan2(playerDir.y or 0, playerDir.x or 0)
 queueFmodAction({
 type = 'spawnSpikeStrip',
 pos = vec3(ppx + math.cos(heading) * 100, ppy + math.sin(heading) * 100, ppz),
 heading = heading + math.pi / 2,
 })
 spikeStripsDeployed = true
 return
 end

 -- Get road direction from spawn data nodes to orient strip perpendicular
 local stripHeading = 0
 if spawnData.n1 and spawnData.n2 then
 local mapNodes = map.getMap().nodes
 if mapNodes and mapNodes[spawnData.n1] and mapNodes[spawnData.n2] then
 local roadDir = mapNodes[spawnData.n2].pos - mapNodes[spawnData.n1].pos
 stripHeading = math.atan2(roadDir.y, roadDir.x) + math.pi / 2
 end
 end

 queueFmodAction({
 type = 'spawnSpikeStrip',
 pos = vec3(spawnData.pos),
 heading = stripHeading,
 })
 spikeStripsDeployed = true

 log('I', logTag, string.format('testSpikeStrips: deployed on route at (%.0f,%.0f,%.0f) ~%.0fm ahead',
 spawnData.pos.x, spawnData.pos.y, spawnData.pos.z, (vec3(spawnData.pos) - playerPos):length()))
 end)
end

return M
