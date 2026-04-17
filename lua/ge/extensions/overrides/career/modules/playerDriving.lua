-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {'career_career', 'gameplay_walk'}

local playerData = {
  trafficActive = 0
} -- traffic data, parking data, etc.
local testTrafficAmounts = {
  traffic = 1,
  police = 0,
  parkedCars = 1,
  active = 1
} -- amounts to use if restrict mode is true

M.ensureTraffic = false
M.preStart = true
M.debugMode = not shipping_build

local function getPlayerData()
  return playerData
end

local function setPlayerData(newId, oldId)
  -- oldId is optional and is used if the vehicle was switched
  if not newId or newId < 0 then return end

  playerData.isParked = gameplay_parking.getCurrentParkingSpot(newId) and true or false

  if oldId then
    gameplay_parking.disableTracking(oldId)
  end
  if not gameplay_walk.isWalking() then
    gameplay_parking.enableTracking(newId)
  end

  playerData.traffic = gameplay_traffic.getTrafficData()[newId]
  playerData.parking = gameplay_parking.getTrackingData()[newId]
end

local function setTrafficVars()
  gameplay_traffic.setTrafficVars({
    enableRandomEvents = true
  })
  gameplay_parking.setParkingVars({
    precision = 0.2
  })
end

local function setupTraffic(forceSetup)
  if forceSetup or
    (gameplay_traffic.getState() == "off" and not gameplay_traffic.getTrafficList(true)[1] and playerData.trafficActive == 0) then
    log("I", "bcm_playerDriving", "Spawning traffic for career mode")
    local restrict = settings.getValue('trafficRestrictForCareer')
    if shipping_build then
      restrict = false
    end

    -- traffic amount
    local amount = settings.getValue('trafficAmount')
    if amount == 0 then
      amount = gameplay_traffic.getIdealSpawnAmount()
    end
    if not getAllVehiclesByType()[1] then
      amount = amount - 1
    end
    if not M.debugMode then
      amount = clamp(amount, 2, 50)
    end

    -- parked cars amount
    local parkedAmount = settings.getValue('trafficParkedAmount')
    if parkedAmount == 0 then
      parkedAmount = clamp(gameplay_traffic.getIdealSpawnAmount(nil, true), 4, 20)
    end
    if not M.debugMode then
      parkedAmount = clamp(parkedAmount, 2, 50)
    end

    -- Police vehicles are spawned by bcm_police separately (via onTrafficStarted)
    local policeAmount = 0
    local extraAmount = 0
    playerData.trafficActive = math.huge

    gameplay_parking.setupVehicles(restrict and testTrafficAmounts.parkedCars or parkedAmount)

    local totalAmount = restrict and testTrafficAmounts.traffic + extraAmount or amount + extraAmount

    gameplay_traffic.setupTraffic(totalAmount, 0, {
      policeAmount = policeAmount,
      simpleVehs = true,
      autoLoadFromFile = true
    })
    setTrafficVars()

    log('I', 'bcm_playerDriving', 'Traffic spawned: ' .. totalAmount .. ' vehicles')

    M.ensureTraffic = false
  else
    if playerData.trafficActive == 0 then
      playerData.trafficActive = gameplay_traffic.getTrafficVars().activeAmount
    end
    -- BCM: tutorial is always disabled, so always set player data
    local playerVehId = be:getPlayerVehicleID(0)
    if playerVehId and playerVehId >= 0 then
      setPlayerData(playerVehId)
    end
  end
end

local function onVehicleSwitched(oldId, newId)
  if be:getPlayerVehicleID(0) ~= newId then
    return
  end
  -- BCM: tutorial always disabled, skip tutorial check
  if not gameplay_missions_missionManager.getForegroundMissionId() then
    setPlayerData(newId, oldId)
    setTrafficVars()
  end
end

local function playerPursuitActive()
  return playerData.traffic and playerData.traffic.pursuit and playerData.traffic.pursuit.mode ~= 0
end

local function resetPlayerState()
  local playerVehId = be:getPlayerVehicleID(0)
  if playerVehId and playerVehId >= 0 then
    setPlayerData(playerVehId)
  end
  if playerData.traffic then
    playerData.traffic:resetAll()
  end

  setTrafficVars()
end

local function retrieveFavoriteVehicle()
  local inventory = career_modules_inventory
  local favoriteVehicleInventoryId = inventory.getFavoriteVehicle()
  if not favoriteVehicleInventoryId then
    return
  end
  local vehInfo = inventory.getVehicles()[favoriteVehicleInventoryId]
  if not vehInfo then
    return
  end

  local vehId = inventory.getVehicleIdFromInventoryId(favoriteVehicleInventoryId)
  if vehId then
    local playerVehObj = getPlayerVehicle(0)
    spawn.safeTeleport(getObjectByID(vehId), playerVehObj:getPosition(), quatFromDir(playerVehObj:getDirectionVector()),
      nil, nil, nil, nil, false)
    core_vehicleBridge.executeAction(getObjectByID(vehId), 'setIgnitionLevel', 0)
  elseif not vehInfo.timeToAccess and not career_modules_insurance_insurance.inventoryVehNeedsRepair(favoriteVehicleInventoryId) then
    inventory.spawnVehicle(favoriteVehicleInventoryId, nil, function()
      local playerVehObj = getPlayerVehicle(0)
      local vehId = inventory.getVehicleIdFromInventoryId(favoriteVehicleInventoryId)
      spawn.safeTeleport(getObjectByID(vehId), playerVehObj:getPosition(),
        quatFromDir(playerVehObj:getDirectionVector()), nil, nil, nil, nil, false)
    end)
  end
end

local function deleteTrailers(veh)
  local trailerData = core_trailerRespawn.getTrailerData()
  local trailerDataThisVeh = trailerData[veh:getId()]

  if trailerDataThisVeh then
    local trailer = getObjectByID(trailerDataThisVeh.trailerId)
    deleteTrailers(trailer)
    career_modules_inventory.removeVehicleObject(career_modules_inventory.getInventoryIdFromVehicleId(
      trailerDataThisVeh.trailerId))
  end
end

local teleportTrailerJob = function(job)
  local args = job.args[1]
  local vehicle = getObjectByID(args.vehicleId)
  local trailer = getObjectByID(args.trailerId)
  local vehRot = quat(0, 0, 1, 0) * quat(vehicle:getRefNodeRotation())
  local vehBB = vehicle:getSpawnWorldOOBB()
  local vehBBCenter = vehBB:getCenter()

  local trailerBB = vehicle:getSpawnWorldOOBB()

  spawn.safeTeleport(trailer, vehBBCenter - vehicle:getDirectionVector() *
    (vehBB:getHalfExtents().y + trailerBB:getHalfExtents().y), vehRot, nil, nil, nil, true, args.resetVeh)

  core_trailerRespawn.getTrailerData()[args.vehicleId] = nil
end

local function teleportToGarage(garageId, veh, resetVeh)
  freeroam_facilities.teleportToGarage(garageId, veh, resetVeh)
  freeroam_bigMapMode.navigateToMission(nil)
  core_vehicleBridge.executeAction(veh, 'setIgnitionLevel', 0)

  local trailerData = core_trailerRespawn.getTrailerData()
  local primaryTrailerData = trailerData[veh:getId()]
  if primaryTrailerData then
    local teleportArgs = {
      trailerId = primaryTrailerData.trailerId,
      vehicleId = veh:getId(),
      resetVeh = resetVeh
    }
    -- need to do this with one frame delay, otherwise the safeTeleport gets confused with two vehicles
    core_jobsystem.create(teleportTrailerJob, 0.1, teleportArgs)

    career_modules_inventory.updatePartConditionsOfSpawnedVehicles(function()
      local trailer = getObjectByID(primaryTrailerData.trailerId)
      deleteTrailers(trailer)
      career_modules_fuel.minimumRefuelingCheck(veh:getId())
    end)
  else
    career_modules_fuel.minimumRefuelingCheck(veh:getId())
  end
end

local function onVehicleParkingStatus(vehId, data)
  if not gameplay_missions_missionManager.getForegroundMissionId() and
    not career_modules_linearTutorial.isLinearTutorialActive() and vehId == be:getPlayerVehicleID(0) then
    if data.event == "valid" then -- this refers to fully stopping while aligned in a parking spot
      if not playerData.isParked then
        playerData.isParked = true
      end
    elseif data.event == "exit" then
      playerData.isParked = false
    end
  end
end

local function onTrafficStarted()
  -- BCM: tutorial always disabled, always run traffic setup
  if not gameplay_missions_missionManager.getForegroundMissionId() then
    local playerVehId = be:getPlayerVehicleID(0)
    if playerVehId and playerVehId >= 0 then
      gameplay_traffic.insertTraffic(playerVehId, true)
      setPlayerData(playerVehId)
    end
    gameplay_traffic.setActiveAmount(playerData.trafficActive)
  end
end

local function onTrafficStopped()
  playerData.traffic = nil  -- FIX PFND-02: dereference only, engine recreates on next onTrafficStarted

  if M.ensureTraffic then -- temp solution to reset traffic
    setupTraffic(true)
  end
end

local function onPlayerCameraReady()
  setupTraffic(true) -- spawns traffic while the loading screen did not fade out yet
end

local function onUpdate(dtReal, dtSim, dtRaw)
  local playerVehId = be:getPlayerVehicleID(0)
  local hasPlayerVeh = playerVehId and playerVehId >= 0

  if M.preStart and freeroam_specialTriggers and playerData.traffic and hasPlayerVeh then -- this cycles all lights triggers, to eliminate lag spikes (move this code later)
    if not playerData.preStartTicks then
      playerData.preStartTicks = 6
    end
    playerData.preStartTicks = playerData.preStartTicks - 1
    for k, v in pairs(freeroam_specialTriggers.getTriggers()) do
      if not v.vehIds[playerVehId] then
        if playerData.preStartTicks == 3 then
          freeroam_specialTriggers.setTriggerActive(k, true, true)
        elseif playerData.preStartTicks == 0 then
          freeroam_specialTriggers.setTriggerActive(k, false, true)
          M.preStart = false
        end
      end
    end
    if playerData.preStartTicks == 0 then
      playerData.preStartTicks = nil
    end
  end

  -- Pursuit stuck detection — delegated to bcm_police for intelligent recovery (PFND-04)
  if playerPursuitActive() and bcm_police then
    bcm_police.onPursuitUpdate(dtSim, playerData, playerVehId)
  end
end

local function onCareerModulesActivated(alreadyInLevel)
  M.ensureTraffic = true
  if alreadyInLevel then
    setupTraffic(true)
  end
end

local function onClientStartMission()
  setupTraffic()
end

local function buildCamPath(targetPos, endDir)
  local camMode = core_camera.getGlobalCameras().bigMap

  local path = {
    looped = false,
    manualFov = false
  }
  local startPos = core_camera.getPosition() + vec3(0, 0, 30)

  local m1 = {
    fov = 30,
    movingEnd = false,
    movingStart = false,
    positionSmooth = 0.5,
    pos = startPos,
    rot = quatFromDir(targetPos - startPos),
    time = 0,
    trackPosition = false
  }
  local m2 = {
    fov = 30,
    movingEnd = false,
    movingStart = false,
    positionSmooth = 0.5,
    pos = startPos,
    rot = quatFromDir(targetPos - startPos),
    time = 0.5,
    trackPosition = false
  }
  local m3 = {
    fov = core_camera.getFovDeg(),
    movingEnd = false,
    movingStart = false,
    positionSmooth = 0.5,
    pos = core_camera.getPosition(),
    rot = endDir and quatFromDir(endDir) or core_camera.getQuat(),
    time = 5.5,
    trackPosition = false
  }
  path.markers = {m1, m2, m3}

  return path
end

local function showPosition(pos)
  local camDir = pos - getPlayerVehicle(0):getPosition()
  if gameplay_walk.isWalking() then
    gameplay_walk.setRot(camDir)
  end

  local camDirLength = camDir:length()
  local rayDist = castRayStatic(getPlayerVehicle(0):getPosition(), camDir, camDirLength)

  if rayDist < camDirLength then
    -- Play cam path to show where the position is
    local camPath = buildCamPath(pos, camDir)
    local initData = {}
    initData.finishedPath = function(this)
      core_camera.setVehicleCameraByIndexOffset(0, 1)
    end
    core_paths.playPath(camPath, 0, initData)
  end
end

local function onWorldReadyState(state)
  if state == 2 and career_career.isActive() then
    setupTraffic()
  end
end

M.onWorldReadyState = onWorldReadyState
M.getPlayerData = getPlayerData
M.retrieveFavoriteVehicle = retrieveFavoriteVehicle
M.playerPursuitActive = playerPursuitActive
M.resetPlayerState = resetPlayerState
M.teleportToGarage = teleportToGarage
M.showPosition = showPosition

M.onPlayerCameraReady = onPlayerCameraReady
M.onTrafficStarted = onTrafficStarted
M.onTrafficStopped = onTrafficStopped
M.onVehicleParkingStatus = onVehicleParkingStatus
M.onVehicleSwitched = onVehicleSwitched
M.onCareerModulesActivated = onCareerModulesActivated
M.onClientStartMission = onClientStartMission
M.onUpdate = onUpdate

return M
