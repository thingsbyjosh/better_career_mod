-- BCM Defects Extension
-- Manages hidden defect discovery lifecycle: test drive (hybrid: custom spawn +
-- vanilla testDrive module for timer/tether/damage/fade), inspector NPC,
-- and post-purchase reveal. Integrates with negotiation for chat injection.
-- Extension name: bcm_defects

local M = {}

local logTag = 'bcm_defects'

-- ============================================================================
-- Forward declarations
-- ============================================================================

local loadDefectsData
local saveDefectsData
local startTestDrive
local stopTestDrive
local onTestDriveUpdate
local navigateToTestDrive
local requestInspector
local deliverInspectorReport
local tickInspector
local revealDefect
local revealPostPurchase
local getDiscoveredDefects
local markDefectDiscovered
local getLanguage
local getMarketplace
local getListingById
local getCurrentGameDay

-- ============================================================================
-- State
-- ============================================================================

local activated = false

-- Persisted state (saved with career)
local defectState = nil
-- Shape: {
--   inspectorContactId = nil,
--   discoveryMap = {},         -- [listingId] = { discoveredDefects = {}, inspectorCalled = bool, testDriveUsed = bool }
--   inspectorJobs = {},        -- [listingId] = { travelRemainingSecs, reviewRemainingSecs, status, listingId }
-- }

-- Volatile state (NOT persisted)
local activeTestDrive = nil
local debugTestDriveSecs = nil  -- override test drive duration from console
-- Shape: {
--   listingId = "...",
--   phase = "traveling"|"driving",
--   elapsedRealSecs = 0,
--   defectsToReveal = {},
--   revealBreakpoints = {},
--   revealedCount = 0,
--   spawnedVehId = nil,
--   parkingSpotName = nil,
-- }

-- ============================================================================
-- Bilingual defect descriptions
-- ============================================================================

local DEFECT_DESCRIPTIONS = {
  km_rollback = {
    en = "The real mileage is far higher than listed. The odometer has been tampered with.",
    es = "El kilometraje real es mucho mayor de lo listado. El cuentakilometros ha sido manipulado.",
  },
  false_specs = {
    en = "This vehicle doesn't have the specs listed. Actual power is significantly lower.",
    es = "Este vehiculo no tiene las especificaciones listadas. La potencia real es significativamente menor.",
  },
  accident_count = {
    en = "This vehicle has been in multiple undisclosed accidents.",
    es = "Este vehiculo ha tenido varios accidentes no revelados.",
  },
}

-- ============================================================================
-- Helpers
-- ============================================================================

getLanguage = function()
  if bcm_settings and bcm_settings.getSetting then
    return bcm_settings.getSetting('language') or 'en'
  end
  return 'en'
end

getMarketplace = function()
  return career_modules_bcm_marketplace
end

getListingById = function(listingId)
  local mp = getMarketplace()
  if not mp then return nil end
  local state = mp.getMarketplaceState()
  if not state or not state.listings then return nil end
  for _, listing in ipairs(state.listings) do
    if listing.id == listingId then
      return listing
    end
  end
  return nil
end

getCurrentGameDay = function()
  if bcm_timeSystem and bcm_timeSystem.getCurrentGameDay then
    return bcm_timeSystem.getCurrentGameDay() or 1
  end
  return 1
end

-- ============================================================================
-- Discovery tracking
-- ============================================================================

markDefectDiscovered = function(listingId, defect)
  defectState.discoveryMap = defectState.discoveryMap or {}
  defectState.discoveryMap[listingId] = defectState.discoveryMap[listingId] or {
    discoveredDefects = {},
    inspectorCalled = false,
    testDriveUsed = false,
  }

  -- Check if already discovered
  for _, d in ipairs(defectState.discoveryMap[listingId].discoveredDefects) do
    if d.id == defect.id then
      return false  -- already discovered
    end
  end

  local lang = getLanguage()
  local desc = DEFECT_DESCRIPTIONS[defect.id] and DEFECT_DESCRIPTIONS[defect.id][lang] or defect.id
  table.insert(defectState.discoveryMap[listingId].discoveredDefects, {
    id = defect.id,
    tier = defect.tier,
    severity = defect.severity,
    description = desc,
  })

  return true
end

getDiscoveredDefects = function(listingId)
  if not defectState or not defectState.discoveryMap then return {} end
  local map = defectState.discoveryMap[listingId]
  if not map then return {} end
  return map.discoveredDefects or {}
end

-- ============================================================================
-- Defect reveal
-- ============================================================================

revealDefect = function(listingId, defect)
  -- Mark as discovered
  local isNew = markDefectDiscovered(listingId, defect)
  if not isNew then return end

  -- Mark discovered on the listing itself
  local listing = getListingById(listingId)
  if listing and listing.defects then
    for _, d in ipairs(listing.defects) do
      if d.id == defect.id then
        d.discovered = true
        break
      end
    end
  end

  local lang = getLanguage()
  local desc = DEFECT_DESCRIPTIONS[defect.id] and DEFECT_DESCRIPTIONS[defect.id][lang] or defect.id

  -- Phone notification
  if bcm_notifications and bcm_notifications.send then
    local title = lang == 'es' and 'Alerta de Prueba' or 'Test Drive Alert'
    bcm_notifications.send({
      title = title,
      message = desc,
      type = "warning",
      duration = 6000,
    })
  end

  -- Inject chat message into seller's negotiation thread
  local session = bcm_negotiation and bcm_negotiation.getSession and bcm_negotiation.getSession(listingId)
  if session then
    local gameDay = getCurrentGameDay()
    -- Append system message to chat (must match appendMessage format: direction, id)
    session.messages = session.messages or {}
    local systemMsg = {
      id = #session.messages + 1,
      direction = "system",
      text = desc,
      gameDay = gameDay,
      action = "defect_discovered",
    }
    table.insert(session.messages, systemMsg)
    -- Fire update to Vue
    if bcm_negotiation and bcm_negotiation.fireSessionUpdate then
      bcm_negotiation.fireSessionUpdate(session)
    end
  end

  -- Fire event for other modules
  guihooks.trigger('BCMDefectDiscovered', {
    listingId = listingId,
    defect = { id = defect.id, tier = defect.tier, description = desc, severity = defect.severity },
  })

  -- Save state
  if career_saveSystem and career_saveSystem.saveCurrentDebounced then
    career_saveSystem.saveCurrentDebounced()
  end

  log('I', logTag, 'Defect revealed: ' .. defect.id .. ' on listing ' .. tostring(listingId))
end

-- ============================================================================
-- Test Drive (hybrid: custom spawn + vanilla testDrive for timer/tether/fade)
-- ============================================================================

startTestDrive = function(listingId, listing)
  if not activated then return { success = false, error = "not_activated" } end
  if activeTestDrive then return { success = false, error = "test_drive_active" } end
  if not listing then return { success = false, error = "no_listing" } end

  -- Guard: don't start test drive if negotiation is dead (sold elsewhere, blocked, ghosted)
  local session = bcm_negotiation and bcm_negotiation.getSession and bcm_negotiation.getSession(listingId)
  if session and (session.isBlocked or session.isGhosting or session._soldElsewhere) then
    return { success = false, error = "negotiation_closed" }
  end

  -- Check if already used
  if listing.defects and #listing.defects > 0 then
    defectState.discoveryMap = defectState.discoveryMap or {}
    local map = defectState.discoveryMap[listingId]
    if map and map.testDriveUsed then
      return { success = false, error = "already_used" }
    end
  end

  -- Determine which config to actually spawn
  -- For scammers with false_specs: spawn the REAL (cheap) config, not the advertised one
  local spawnConfig = listing.vehicleConfigKey
  if listing.defects then
    for _, d in ipairs(listing.defects) do
      if d.id == "false_specs" and d.realConfigKey then
        spawnConfig = d.realConfigKey
        break
      end
    end
  end

  -- Sort defects and compute reveal breakpoints
  local sorted = {}
  local breakpoints = {}
  if listing.defects and #listing.defects > 0 then
    for _, d in ipairs(listing.defects) do
      table.insert(sorted, d)
    end
    table.sort(sorted, function(a, b) return a.tier < b.tier end)

    local count = #sorted
    if count == 1 then
      breakpoints = { 240 }  -- 80% of 300
    elseif count == 2 then
      breakpoints = { 150, 240 }  -- 50%, 80%
    elseif count >= 3 then
      breakpoints = { 90, 180, 240 }  -- 30%, 60%, 80%
    end
    -- false_specs (tier 1) reveals early — you see it's the wrong car quickly
    for i, d in ipairs(sorted) do
      if d.id == "false_specs" and d.tier == 1 then
        breakpoints[i] = 30
        break
      end
    end
  end

  activeTestDrive = {
    listingId = listingId,
    phase = "traveling",  -- "traveling" = going to parking, "driving" = player in vehicle
    elapsedRealSecs = 0,
    defectsToReveal = sorted,
    revealBreakpoints = breakpoints,
    revealedCount = 0,
  }

  -- Spawn vehicle at a random public parking spot (same approach as vanilla private sales)
  if listing.vehicleModelKey and spawnConfig then
    local spawnOptions = { config = spawnConfig, autoEnterVehicle = false }
    local newVeh = core_vehicles.spawnNewVehicle(listing.vehicleModelKey, spawnOptions)

    if newVeh then
      activeTestDrive.spawnedVehId = newVeh:getID()

      -- Freeze and set mileage — use REAL mileage if km_rollback defect exists
      core_vehicleBridge.executeAction(newVeh, 'setIgnitionLevel', 0)
      core_vehicleBridge.executeAction(newVeh, 'setFreeze', true)
      local realKm = listing.mileageKm or 50000
      if listing.defects then
        for _, d in ipairs(listing.defects) do
          if d.id == "km_rollback" and d.realMileageKm then
            realKm = d.realMileageKm
            break
          end
        end
      end
      local mileageMeters = realKm * 1000
      newVeh:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, 1.0)", mileageMeters))

      -- Move to a random parking spot
      if gameplay_parking and gameplay_parking.getParkingSpots then
        local parkingSpots = gameplay_parking.getParkingSpots().byName
        if parkingSpots then
          local spotNames = tableKeys(parkingSpots)
          local spotCount = tableSize(spotNames)
          if spotCount > 0 then
            -- Pick a random public parking spot (same filter as vanilla private sales)
            local attempts = 0
            local spot
            local chosenName
            repeat
              attempts = attempts + 1
              local name = spotNames[math.random(spotCount)]
              local candidate = parkingSpots[name]
              if candidate and not (candidate.customFields and candidate.customFields.tags and candidate.customFields.tags.notprivatesale) then
                spot = candidate
                chosenName = name
              end
            until spot or attempts > 20

            if spot then
              activeTestDrive.parkingSpotName = chosenName

              -- Clear any vehicles already in the spot
              local hasVehicles, vehicleIds = spot:hasAnyVehicles()
              if hasVehicles and gameplay_traffic and gameplay_traffic.forceTeleport then
                for _, vehId in ipairs(vehicleIds) do
                  gameplay_traffic.forceTeleport(vehId)
                end
              end

              -- Move test drive vehicle to the spot
              spot:moveResetVehicleTo(newVeh:getID(), nil, nil, nil, nil, true)

              -- Set GPS waypoint to the parking spot
              if core_groundMarkers and core_groundMarkers.setPath then
                core_groundMarkers.setPath(spot.pos)
              end

              log('I', logTag, 'Test drive vehicle parked at spot: ' .. tostring(chosenName) .. ', GPS set')
            end
          end
        end
      end
    end
  end

  -- Record test drive used
  if listing.defects and #listing.defects > 0 then
    defectState.discoveryMap = defectState.discoveryMap or {}
    defectState.discoveryMap[listingId] = defectState.discoveryMap[listingId] or {
      discoveredDefects = {},
      inspectorCalled = false,
      testDriveUsed = false,
    }
    defectState.discoveryMap[listingId].testDriveUsed = true
  end

  -- Send seller message: "Go pick up the car"
  local session = bcm_negotiation and bcm_negotiation.getSession and bcm_negotiation.getSession(listingId)
  if session then
    local lang = getLanguage()
    local gameDay = getCurrentGameDay()
    session.messages = session.messages or {}
    local sellerMsg = {
      id = #session.messages + 1,
      direction = "seller",
      text = lang == 'es'
        and "Vale, te he dejado el coche en un parking. Te pongo la ubicación en el GPS."
        or "Alright, I left the car at a parking spot. I'm sending you the location.",
      gameDay = gameDay,
    }
    table.insert(session.messages, sellerMsg)
    if bcm_negotiation and bcm_negotiation.fireSessionUpdate then
      bcm_negotiation.fireSessionUpdate(session)
    end
  end

  guihooks.trigger('BCMTestDriveStarted', { listingId = listingId, phase = "traveling" })
  log('I', logTag, 'Test drive started (traveling): ' .. tostring(listingId) .. ' config=' .. tostring(spawnConfig) .. ' defects=' .. tostring(#sorted))
  return { success = true }
end

stopTestDrive = function()
  if not activeTestDrive then return end

  local listingId = activeTestDrive.listingId
  local spawnedVehId = activeTestDrive.spawnedVehId

  -- If vanilla testDrive is active, let it handle the fade/teleport
  -- (it will fire onTestDriveEndedAfterFade and we'll clean up there)
  if career_modules_testDrive and career_modules_testDrive.isActive and career_modules_testDrive.isActive() then
    career_modules_testDrive.stop()
    -- Don't clean up here — onTestDriveEndedAfterFade will handle it
    return
  end

  -- Fallback: vanilla testDrive not active (e.g. still in traveling phase)
  -- Do manual cleanup
  if spawnedVehId then
    local veh = be:getObjectByID(spawnedVehId)
    if veh then veh:delete() end
  end
  if core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath(nil)
  end

  -- Reveal all remaining defects
  local defects = activeTestDrive.defectsToReveal or {}
  local revealed = activeTestDrive.revealedCount or 0
  for i = revealed + 1, #defects do
    revealDefect(listingId, defects[i])
  end

  activeTestDrive = nil

  -- Extend deal expiry if it was frozen during test drive — give player 1 extra day
  local session = bcm_negotiation and bcm_negotiation.getSession and bcm_negotiation.getSession(listingId)
  local gameDay = getCurrentGameDay()
  if session and session.dealReached and session.dealExpiresGameDay and session.dealExpiresGameDay <= gameDay then
    session.dealExpiresGameDay = gameDay + 1
    log('I', logTag, 'Extended deal expiry to day ' .. tostring(session.dealExpiresGameDay) .. ' after test drive for listing ' .. tostring(listingId))
  end

  -- Seller sends "how was it?" message to negotiation chat
  if session then
    local lang = getLanguage()
    session.messages = session.messages or {}
    local sellerMsg = {
      id = #session.messages + 1,
      direction = "seller",
      text = lang == 'es'
        and "Bueno, ¿qué tal la prueba? ¿Te ha gustado el coche?"
        or "So, how was the test drive? Did you like the car?",
      gameDay = gameDay,
    }
    table.insert(session.messages, sellerMsg)
    if bcm_negotiation and bcm_negotiation.fireSessionUpdate then
      bcm_negotiation.fireSessionUpdate(session)
    end
  end

  guihooks.trigger('BCMTestDriveEnded', { listingId = listingId })
  log('I', logTag, 'Test drive stopped (manual): ' .. tostring(listingId))
end

navigateToTestDrive = function()
  if not activeTestDrive then return end
  if activeTestDrive.phase ~= "traveling" then return end
  if not activeTestDrive.spawnedVehId then return end

  -- Re-set GPS to the spawned vehicle's current position
  local veh = be:getObjectByID(activeTestDrive.spawnedVehId)
  if veh then
    local pos = veh:getPosition()
    if pos and core_groundMarkers and core_groundMarkers.setPath then
      core_groundMarkers.setPath(pos)
      log('I', logTag, 'GPS re-set to test drive vehicle')
    end
  end
end

onTestDriveUpdate = function(dtReal)
  if not activeTestDrive then return end

  -- Phase: traveling — wait for player to enter the spawned vehicle
  if activeTestDrive.phase == "traveling" then
    if activeTestDrive.spawnedVehId then
      local playerVeh = be:getPlayerVehicle(0)
      if playerVeh and playerVeh:getID() == activeTestDrive.spawnedVehId then
        -- Player entered the test drive vehicle — switch to driving phase
        activeTestDrive.phase = "driving"
        activeTestDrive.elapsedRealSecs = 0

        -- Unfreeze the vehicle so they can drive
        core_vehicleBridge.executeAction(playerVeh, 'setFreeze', false)
        core_vehicleBridge.executeAction(playerVeh, 'setIgnitionLevel', 3)

        -- Clear GPS (they're already at the car)
        if core_groundMarkers and core_groundMarkers.setPath then
          core_groundMarkers.setPath(nil)
        end

        -- Start vanilla testDrive for timer, tether, damage snapshot, fade
        if career_modules_testDrive and career_modules_testDrive.start then
          local duration = debugTestDriveSecs or 300
          local testDriveInfo = {
            timeLimit = duration,
            abandonFees = 0,        -- private sale, no fees
          }
          career_modules_testDrive.start(activeTestDrive.spawnedVehId, testDriveInfo)
          log('I', logTag, 'Vanilla testDrive.start() called for vehId=' .. tostring(activeTestDrive.spawnedVehId))
        end

        guihooks.trigger('BCMTestDriveDriving', {
          listingId = activeTestDrive.listingId,
          durationSecs = 300,
        })
        log('I', logTag, 'Test drive driving phase started: ' .. tostring(activeTestDrive.listingId))
      end
    end
    return  -- Don't tick timer while traveling
  end

  -- Phase: driving — tick defect breakpoint timer (vanilla handles the overall timer)
  activeTestDrive.elapsedRealSecs = activeTestDrive.elapsedRealSecs + dtReal

  -- Check breakpoints
  local defects = activeTestDrive.defectsToReveal or {}
  local brkpoints = activeTestDrive.revealBreakpoints or {}
  local revealed = activeTestDrive.revealedCount or 0

  while revealed < #defects and revealed < #brkpoints do
    local nextBP = brkpoints[revealed + 1]
    if activeTestDrive.elapsedRealSecs >= nextBP then
      revealed = revealed + 1
      activeTestDrive.revealedCount = revealed
      revealDefect(activeTestDrive.listingId, defects[revealed])
    else
      break
    end
  end

  -- No manual timer expiry check — vanilla testDrive handles that and fires
  -- onTestDriveEndedAfterFade when the timer expires
end

-- ============================================================================
-- Vanilla testDrive hooks
-- ============================================================================

-- Fired by vanilla testDrive.lua when it starts (after player enters vehicle)
-- We use this to confirm driving phase
M.onTestDriveStarted = function()
  if not activeTestDrive then return end
  -- Already handled in onTestDriveUpdate traveling→driving transition
  log('I', logTag, 'Vanilla onTestDriveStarted hook — driving confirmed for: ' .. tostring(activeTestDrive.listingId))
end

-- Fired by vanilla testDrive.lua after fade + teleport back
-- This is our cleanup point: reveal defects, despawn vehicle, send seller message
M.onTestDriveEndedAfterFade = function()
  if not activeTestDrive then return end

  local listingId = activeTestDrive.listingId
  local spawnedVehId = activeTestDrive.spawnedVehId

  log('I', logTag, 'Vanilla onTestDriveEndedAfterFade — cleaning up: ' .. tostring(listingId))

  -- Reveal all remaining defects
  local defects = activeTestDrive.defectsToReveal or {}
  local revealed = activeTestDrive.revealedCount or 0
  for i = revealed + 1, #defects do
    revealDefect(listingId, defects[i])
  end

  -- Keep the vehicle alive at its parking spot so the player can re-visit it.
  -- It will be cleaned up when the listing expires or the negotiation ends.

  activeTestDrive = nil

  -- Seller sends "how was it?" message to negotiation chat
  local session = bcm_negotiation and bcm_negotiation.getSession and bcm_negotiation.getSession(listingId)
  if session then
    local lang = getLanguage()
    local gameDay = getCurrentGameDay()
    session.messages = session.messages or {}
    local sellerMsg = {
      id = #session.messages + 1,
      direction = "seller",
      text = lang == 'es'
        and "Bueno, ¿qué tal la prueba? ¿Te ha gustado el coche?"
        or "So, how was the test drive? Did you like the car?",
      gameDay = gameDay,
    }
    table.insert(session.messages, sellerMsg)
    if bcm_negotiation and bcm_negotiation.fireSessionUpdate then
      bcm_negotiation.fireSessionUpdate(session)
    end
  end

  guihooks.trigger('BCMTestDriveEnded', { listingId = listingId })
  log('I', logTag, 'Test drive finished (vanilla fade): ' .. tostring(listingId))
end

-- ============================================================================
-- Inspector NPC
-- ============================================================================

requestInspector = function(listingId)
  if not activated then return end
  if not defectState then return end

  local listing = getListingById(listingId)
  if not listing then
    log('W', logTag, 'requestInspector: listing not found: ' .. tostring(listingId))
    return
  end

  -- Inspector is an independent path — no test drive prerequisite

  -- Check if already called
  if map and map.inspectorCalled then
    if bcm_notifications and bcm_notifications.send then
      local lang = getLanguage()
      bcm_notifications.send({
        title = "Rudy Verduras",
        message = lang == 'es'
          and "Ya inspeccioné ese vehiculo."
          or "I already inspected this vehicle.",
        type = "info",
        duration = 4000,
      })
    end
    return
  end

  -- Calculate fee: 8% of listing price
  local feeCents = math.floor((listing.priceCents or 0) * 0.08)
  local feeDollars = string.format("$%s", tostring(math.floor(feeCents / 100)))

  -- Debit fee
  if bcm_banking and bcm_banking.removeFunds then
    local account = bcm_banking.getPersonalAccount()
    if not account then return end
    local success = bcm_banking.removeFunds(account.id, feeCents, "inspector", "Inspector Fee - Rudy Verduras")
    if not success then
      if bcm_notifications and bcm_notifications.send then
        local lang = getLanguage()
        bcm_notifications.send({
          title = "Rudy Verduras",
          message = lang == 'es'
            and "No tienes suficiente dinero para mi servicio."
            or "You don't have enough money for my service.",
          type = "warning",
          duration = 5000,
        })
      end
      return
    end
  end

  -- Calculate travel time: 15-45 game-minutes
  local pricingEngine = require('lua/ge/extensions/bcm/pricingEngine')
  local travelSeed = pricingEngine.lcg(#listingId * 7919)
  local travelMinutes = 15 + (travelSeed % 31)
  local travelSecs = travelMinutes * 60  -- game seconds
  local reviewSecs = 3600  -- 60 game-minutes = 1 game-hour

  -- Create inspector job
  defectState.inspectorJobs = defectState.inspectorJobs or {}
  defectState.inspectorJobs[listingId] = {
    travelRemainingSecs = travelSecs,
    reviewRemainingSecs = reviewSecs,
    status = "traveling",
    listingId = listingId,
  }

  -- Mark inspector called
  defectState.discoveryMap = defectState.discoveryMap or {}
  defectState.discoveryMap[listingId] = defectState.discoveryMap[listingId] or {
    discoveredDefects = {},
    inspectorCalled = false,
    testDriveUsed = false,
  }
  defectState.discoveryMap[listingId].inspectorCalled = true

  -- Send confirmation notification
  if bcm_notifications and bcm_notifications.send then
    local lang = getLanguage()
    bcm_notifications.send({
      title = "Rudy Verduras",
      message = lang == 'es'
        and string.format("Voy para alla! Estare ahi en unos %d minutos. Mi tarifa es %s.", travelMinutes, feeDollars)
        or string.format("On my way! I'll be there in about %d minutes. My fee is %s.", travelMinutes, feeDollars),
      type = "info",
      duration = 6000,
    })
  end

  -- Save state
  if career_saveSystem and career_saveSystem.saveCurrentDebounced then
    career_saveSystem.saveCurrentDebounced()
  end

  log('I', logTag, 'Inspector requested for: ' .. tostring(listingId) .. ' fee=' .. tostring(feeCents) .. ' travel=' .. tostring(travelMinutes) .. 'min')
end

tickInspector = function(dtSim)
  if not defectState or not defectState.inspectorJobs then return end

  for listingId, job in pairs(defectState.inspectorJobs) do
    if job.status == "traveling" then
      job.travelRemainingSecs = job.travelRemainingSecs - dtSim
      if job.travelRemainingSecs <= 0 then
        job.status = "reviewing"
        job.travelRemainingSecs = 0
        -- Notify arrival
        if bcm_notifications and bcm_notifications.send then
          local lang = getLanguage()
          bcm_notifications.send({
            title = "Rudy Verduras",
            message = lang == 'es'
              and "He llegado. Empiezo la inspeccion ahora."
              or "I've arrived. Starting my inspection now.",
            type = "info",
            duration = 4000,
          })
        end
        log('I', logTag, 'Inspector arrived at listing: ' .. tostring(listingId))
      end
    elseif job.status == "reviewing" then
      job.reviewRemainingSecs = job.reviewRemainingSecs - dtSim
      if job.reviewRemainingSecs <= 0 then
        deliverInspectorReport(listingId)
      end
    end
  end
end

deliverInspectorReport = function(listingId)
  local listing = getListingById(listingId)
  if not listing then
    log('W', logTag, 'deliverInspectorReport: listing not found: ' .. tostring(listingId))
    -- Clean up job
    if defectState.inspectorJobs then
      defectState.inspectorJobs[listingId] = nil
    end
    return
  end

  local lang = getLanguage()

  -- Reveal ALL defects
  if listing.defects then
    for _, d in ipairs(listing.defects) do
      if not d.discovered then
        revealDefect(listingId, d)
      end
    end
  end

  -- Build report
  local defectList = {}
  if listing.defects then
    for _, d in ipairs(listing.defects) do
      local desc = DEFECT_DESCRIPTIONS[d.id] and DEFECT_DESCRIPTIONS[d.id][lang] or d.id
      table.insert(defectList, "- " .. desc)
    end
  end

  local vehicleName = listing.title or listing.vehicleBrand .. " " .. listing.vehicleModel
  local reportBody
  if #defectList > 0 then
    reportBody = lang == 'es'
      and ("Informe de inspeccion para " .. vehicleName .. ":\n\n" .. table.concat(defectList, "\n") .. "\n\nRecomiendo negociar el precio basandose en estos hallazgos.\n\nRudy Verduras\nInspector Vehicular Certificado")
      or ("Inspection report for " .. vehicleName .. ":\n\n" .. table.concat(defectList, "\n") .. "\n\nI recommend negotiating the price based on these findings.\n\nRudy Verduras\nCertified Vehicle Inspector")
  else
    reportBody = lang == 'es'
      and ("Informe de inspeccion para " .. vehicleName .. ":\n\nNo se encontraron defectos. El vehiculo esta en buen estado.\n\nRudy Verduras\nInspector Vehicular Certificado")
      or ("Inspection report for " .. vehicleName .. ":\n\nNo defects found. The vehicle is in good condition.\n\nRudy Verduras\nCertified Vehicle Inspector")
  end

  -- Send email
  if bcm_email and bcm_email.deliver then
    local subject = lang == 'es'
      and ("Informe de Inspeccion - " .. vehicleName)
      or ("Inspection Report - " .. vehicleName)
    bcm_email.deliver({
      folder = "inbox",
      from_display = "Rudy Verduras",
      from_email = "rudy@verdurasinspections.com",
      subject = subject,
      body = reportBody,
      is_spam = false,
    })
  end

  -- Notification
  if bcm_notifications and bcm_notifications.send then
    bcm_notifications.send({
      title = lang == 'es' and "Informe del Inspector Listo" or "Inspector Report Ready",
      message = lang == 'es'
        and "Rudy Verduras ha enviado su informe por email."
        or "Rudy Verduras has sent his report via email.",
      type = "info",
      duration = 6000,
    })
  end

  -- Clean up job
  if defectState.inspectorJobs then
    defectState.inspectorJobs[listingId] = nil
  end

  guihooks.trigger('BCMInspectorReportReady', { listingId = listingId })

  -- Save state
  if career_saveSystem and career_saveSystem.saveCurrentDebounced then
    career_saveSystem.saveCurrentDebounced()
  end

  log('I', logTag, 'Inspector report delivered for: ' .. tostring(listingId))
end

-- ============================================================================
-- Post-purchase reveal
-- ============================================================================

revealPostPurchase = function(listingId, listing, inventoryId)
  if not listing then return end

  local lang = getLanguage()

  -- Reveal undiscovered defects
  if listing.defects then
    for _, d in ipairs(listing.defects) do
      if not d.discovered then
        local desc = DEFECT_DESCRIPTIONS[d.id] and DEFECT_DESCRIPTIONS[d.id][lang] or d.id
        if bcm_notifications and bcm_notifications.send then
          bcm_notifications.send({
            title = lang == 'es' and 'Descubrimiento post-compra' or 'Post-Purchase Discovery',
            message = desc,
            type = "warning",
            duration = 8000,
          })
        end
        markDefectDiscovered(listingId, d)
      end
    end
  end

  -- Hidden gem notification
  if listing.isGem then
    if bcm_notifications and bcm_notifications.send then
      bcm_notifications.send({
        title = lang == 'es' and 'Ganga!' or 'Hidden Gem!',
        message = lang == 'es'
          and 'Este vehiculo esta en mejor condicion de lo esperado.'
          or 'This vehicle is in better condition than expected.',
        type = "success",
        duration = 8000,
      })
    end
  end

  -- Persist defect metadata into vehicle inventory record
  local defectSummary = {}
  if listing.defects then
    for _, d in ipairs(listing.defects) do
      local desc = DEFECT_DESCRIPTIONS[d.id] and DEFECT_DESCRIPTIONS[d.id][lang] or d.id
      table.insert(defectSummary, {
        id = d.id,
        description = desc,
        severity = d.severity,
      })
    end
  end
  if listing.isGem then
    table.insert(defectSummary, {
      id = "hidden_gem",
      description = lang == 'es' and 'Este vehiculo esta en mejor condicion de lo esperado.' or 'This vehicle is in better condition than expected.',
      severity = 0,
    })
  end

  -- Store into vehicle inventory metadata
  if inventoryId and career_modules_inventory and career_modules_inventory.getVehicles then
    local vehicles = career_modules_inventory.getVehicles()
    if vehicles and vehicles[inventoryId] then
      vehicles[inventoryId].bcmDefects = defectSummary
      log('I', logTag, 'Persisted bcmDefects to inventory: inv=' .. tostring(inventoryId) .. ' defects=' .. tostring(#defectSummary))
    end
  end

  log('I', logTag, 'Post-purchase reveal for: ' .. tostring(listingId) .. ' inv=' .. tostring(inventoryId))
end

-- ============================================================================
-- Save / Load
-- ============================================================================

saveDefectsData = function(currentSavePath)
  if not career_saveSystem then return end
  if not defectState then return end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  local dataPath = bcmDir .. "/defects.json"
  career_saveSystem.jsonWriteFileSafe(dataPath, defectState, true)
  log('I', logTag, 'Saved defects state')
end

loadDefectsData = function()
  -- Reset state
  defectState = {
    inspectorContactId = nil,
    discoveryMap = {},
    inspectorJobs = {},
  }
  activeTestDrive = nil

  if not career_career or not career_career.isActive() then
    return
  end

  if not career_saveSystem then return end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then return end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then return end

  local dataPath = autosavePath .. "/career/bcm/defects.json"
  local data = jsonReadFile(dataPath)

  if data then
    defectState = data
    defectState.discoveryMap = defectState.discoveryMap or {}
    defectState.inspectorJobs = defectState.inspectorJobs or {}
    log('I', logTag, 'Loaded defects state')
  end
end

-- ============================================================================
-- Inspector contact registration
-- ============================================================================

local function registerInspectorContact()
  if not bcm_contacts or not bcm_contacts.addContact then return end
  if defectState.inspectorContactId then
    -- Already registered, verify it still exists
    if bcm_contacts.getContact and bcm_contacts.getContact(defectState.inspectorContactId) then
      return  -- Still exists
    end
  end

  local contactId = bcm_contacts.addContact({
    firstName = "Rudy",
    lastName = "Verduras",
    phone = "555-7839",
    email = "rudy@verdurasinspections.com",
    group = "services",
  })

  if contactId then
    defectState.inspectorContactId = contactId
    log('I', logTag, 'Inspector contact registered: ' .. tostring(contactId))
    if career_saveSystem and career_saveSystem.saveCurrentDebounced then
      career_saveSystem.saveCurrentDebounced()
    end
  end
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

M.onCareerModulesActivated = function()
  loadDefectsData()
  registerInspectorContact()
  activated = true
  log('I', logTag, 'Defects module activated')
end

M.onUpdate = function(dtReal, dtSim, dtRaw)
  if not activated then return end
  onTestDriveUpdate(dtReal)
  tickInspector(dtSim)
end

M.onSaveCurrentSaveSlot = function(currentSavePath)
  saveDefectsData(currentSavePath)
end

M.onBeforeSetSaveSlot = function()
  defectState = {
    inspectorContactId = nil,
    discoveryMap = {},
    inspectorJobs = {},
  }
  activeTestDrive = nil
  activated = false
  log('D', logTag, 'Defects state reset (save slot change)')
end

-- ============================================================================
-- Public API
-- ============================================================================

M.startTestDrive = startTestDrive
M.stopTestDrive = stopTestDrive
M.navigateToTestDrive = navigateToTestDrive
M.getActiveTestDrive = function() return activeTestDrive end
M.cancelTestDrive = function()
  -- Player-initiated cancel (e.g., from phone UI). Works in any phase.
  if not activeTestDrive then return false end
  stopTestDrive()
  return true
end
M.requestInspector = requestInspector
M.revealPostPurchase = revealPostPurchase
M.getDiscoveredDefects = getDiscoveredDefects
M.isTestDriveActive = function()
  return activeTestDrive ~= nil
end
-- Debug: set test drive duration in seconds (e.g. bcm_defects.debugSetTestDriveSecs(30))
M.debugSetTestDriveSecs = function(secs)
  debugTestDriveSecs = secs
  log('I', logTag, 'Debug: test drive duration set to ' .. tostring(secs) .. 's')
end
M.getActiveTestDriveListingId = function()
  return activeTestDrive and activeTestDrive.listingId or nil
end

-- Push all discovered defects to Vue (called on UI re-init to rehydrate)
M.pushAllDiscoveredDefects = function()
  if not defectState or not defectState.discoveryMap then return end
  for listingId, map in pairs(defectState.discoveryMap) do
    local defects = map.discoveredDefects or {}
    for _, d in ipairs(defects) do
      guihooks.trigger('BCMDefectDiscovered', {
        listingId = listingId,
        defect = { id = d.id, tier = d.tier, description = d.description, severity = d.severity },
      })
    end
  end
end

-- Push active test drive state to Vue (called on UI re-init to rehydrate)
M.pushTestDriveState = function()
  if not activeTestDrive then
    -- No active test drive — tell Vue to clear any stale state
    guihooks.trigger('BCMTestDriveEnded', {})
    return
  end
  if activeTestDrive.phase == "traveling" then
    guihooks.trigger('BCMTestDriveStarted', { listingId = activeTestDrive.listingId, phase = "traveling" })
  elseif activeTestDrive.phase == "driving" then
    guihooks.trigger('BCMTestDriveDriving', { listingId = activeTestDrive.listingId, durationSecs = 300 })
  end
end

-- ============================================================================
-- Debug commands
-- ============================================================================

M.debugRevealAllDefects = function()
  if not activeTestDrive then
    log('W', logTag, 'debugRevealAllDefects: no active test drive')
    return
  end
  local defects = activeTestDrive.defectsToReveal or {}
  local revealed = activeTestDrive.revealedCount or 0
  for i = revealed + 1, #defects do
    revealDefect(activeTestDrive.listingId, defects[i])
  end
  activeTestDrive.revealedCount = #defects
  log('I', logTag, 'Debug: revealed all defects on active test drive')
end

M.debugEndTestDrive = function()
  if not activeTestDrive then
    log('W', logTag, 'debugEndTestDrive: no active test drive')
    return
  end
  stopTestDrive()
  log('I', logTag, 'Debug: ended test drive')
end

M.debugInspectorInstantArrive = function()
  if not defectState or not defectState.inspectorJobs then return end
  for listingId, job in pairs(defectState.inspectorJobs) do
    if job.status == "traveling" then
      job.travelRemainingSecs = 0
      log('I', logTag, 'Debug: inspector instant arrive for ' .. tostring(listingId))
    end
  end
end

M.debugInspectorInstantAll = function()
  if not defectState or not defectState.inspectorJobs then return end
  local jobsCopy = {}
  for listingId, job in pairs(defectState.inspectorJobs) do
    table.insert(jobsCopy, listingId)
  end
  for _, listingId in ipairs(jobsCopy) do
    deliverInspectorReport(listingId)
  end
  log('I', logTag, 'Debug: all inspector jobs completed instantly')
end

return M

