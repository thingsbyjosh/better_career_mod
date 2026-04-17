-- BCM Tutorial Extension
-- 6-step linear tutorial FSM: step definitions, detection hooks, watchdog timers,
-- save/restore resilience, phone blocking, Miramar sale block, pause menu skip injection.
-- Locked save schema and FSM skeleton.
-- Full step logic, detection hooks, watchdog, save/restore, monkey-patches.
-- Restructured 7->6 steps, string sub-steps, v3->v4 migration, loaner removal.
-- Extension name: bcm_tutorial

local M = {}

M.debugName = "BCM Tutorial"
M.debugOrder = 55

-- Log tag
local logTag = 'bcm_tutorial'

-- ============================================================
-- Forward declarations
-- ============================================================
local loadSaveData
local saveTutorialData
local skipTutorial
local beginTutorial
local restoreStepUI
local onFirstCareerStart
local onCareerActive
local onSaveCurrentSaveSlot
local advanceToStep
local checkStepCompletion
local completeTutorial
local setWaypointForStep
local patchPauseMenu
local unpatchPauseMenu
local patchInventorySell
local unpatchInventorySell
local confirmSkip
local skipCurrentStep
local resetVehicle
local isPhoneBlocked
local onUpdate
local onVehicleSwitched
local onComputerMenuOpened
local onBCMTutorialPackComplete
local onBCMSleepComplete
local getGaragePosition
local getNudgeHintForStep
local broadcastStepState
local resetFullTutorial
local onBCMPartsShopCheckoutComplete

-- ============================================================
-- Step definitions
-- ============================================================

-- Helper: get current language from BCM settings
local function isEs()
  return bcm_settings and bcm_settings.getSetting("language") == "es"
end
local function t(en, es)
  return isEs() and es or en
end

-- Step 4 sub-step sequence: named string IDs for the desktop tour + delivery flow
-- Each sub-step is referenced by string ID, not integer index
local STEP4_SUBSTEPS = {
  -- Desktop icon info spotlights
  'desktop_eboy', 'desktop_vpbeta', 'desktop_install_parts',
  'desktop_my_vehicles', 'desktop_garage_mgr', 'desktop_ie',
  -- O'Really flow (per D-04)
  'click_vpbeta',
  'oreally_landing', 'oreally_enter_all', 'oreally_all_tour', 'oreally_all_back',
  'oreally_click_cargo', 'oreally_select_box',
  'oreally_delivery_explain', 'oreally_select_fs',
  'oreally_checkout', 'oreally_confirm',
  'oreally_close_window', 'back_to_desktop',
  -- IE + PlanEx flow (unchanged)
  'click_ie', 'ie_tour_nav', 'ie_tour_favorites',
  'click_planex', 'planex_tour',
  'planex_vehicle_info', 'planex_open_dropdown', 'planex_loaner_info', 'planex_personal_info', 'planex_select_vehicle',
  'planex_click_pack', 'planex_accept_pack',
  'drive_to_depot', 'complete_delivery', 'toll_to_garage',
}

-- Lookup: subStepId -> index (for advancing)
local STEP4_SUBSTEP_INDEX = {}
for i, id in ipairs(STEP4_SUBSTEPS) do
  STEP4_SUBSTEP_INDEX[id] = i
end

-- Dynamic retrieve branch: activated when Miramar not spawned before click_ie (D-08/D-09)
-- These sub-steps are NOT in STEP4_SUBSTEPS — they run as a side branch
local RETRIEVE_SUBSTEPS = {
  'retrieve_open_my_vehicles',
  'retrieve_click_retrieve',
  'retrieve_close_window',
}
local RETRIEVE_SUBSTEP_INDEX = {}
for i, id in ipairs(RETRIEVE_SUBSTEPS) do
  RETRIEVE_SUBSTEP_INDEX[id] = i
end

-- Each step: id, label(), subtext(), type, immediateCheck (optional fn -> bool)
-- label and subtext are functions that return the localized string
local STEPS = {
  [1] = {
    id    = "step_mount",
    label = function() return t("Get in the Miramar", "Sube al Miramar") end,
    subtext = function() return t("Walk up to the car and press the prompt to get in.", "Acércate al coche y pulsa el botón para subir.") end,
    type  = "goal",
    immediateCheck = function()
      return be:getPlayerVehicleID(0) >= 0 and not gameplay_walk.isWalking()
    end,
  },
  [2] = {
    id    = "step_garage",
    label = function() return t("Drive to Chinatown Garage", "Conduce al garaje de Chinatown") end,
    subtext = function() return t("Follow the GPS to the garage.", "Sigue el GPS hasta el garaje.") end,
    type  = "goal",
  },
  [3] = {
    id    = "step_computer",
    label = function() return t("Use the garage computer", "Usa el ordenador del garaje") end,
    -- Note: If player exits computer during step 4, objective reverts to step_computer tasklist text
    subtext = function() return t("Walk inside and interact with the computer terminal.", "Entra y usa la terminal del ordenador.") end,
    type  = "goal",
  },
  [4] = {
    id    = "step_desktop_tour",
    label = function() return t("Complete the desktop tutorial", "Completa el tutorial del escritorio") end,
    subtext = function() return t("Follow the on-screen guides to learn the garage computer tools.", "Sigue las guias en pantalla para aprender las herramientas del ordenador del garaje.") end,
    type  = "goal",
  },
  [5] = {
    id    = "step_sleep",
    label = function() return t("Set up your phone and sleep", "Configura tu móvil y duerme") end,
    subtext = function() return t(
      "Go to Options > Controls > search 'BCM' > assign Shift+M to 'Toggle Phone'. Then open the phone and sleep until 7 AM.",
      "Ve a Opciones > Controles > busca 'BCM' > asigna Shift+M a 'Toggle Phone'. Luego abre el móvil y duerme hasta las 7 AM."
    ) end,
    type  = "goal",
  },
  [6] = {
    id    = "step_complete",
    label = function() return t("Tutorial complete", "Tutorial completado") end,
    subtext = function() return "" end,
    type  = "message",
  },
}

-- ============================================================
-- Save schema defaults
-- ============================================================

local DEFAULT_DATA = {
  version                       = 4,
  tutorialDone                  = false,
  tutorialSkipped               = false,
  currentStep                   = 0,        -- 0 = not started, 1-6 = active, 999 = done
  tutorialSubStep               = '',       -- string sub-step ID within step 4 ('' = none)
  stepStartedAt                 = nil,      -- os.time() when step began
  betaWelcomeShown              = false,
  miramarInventoryId            = nil,      -- set after Miramar spawn
  shownContextualTutorials      = {},       -- { [tutorialId] = true }
  contextualTutorialsDisabled   = false,    -- player opted out of all contextual tutorials
}

-- ============================================================
-- Private state
-- ============================================================

local tutorialData             = nil
local garageProximityTimer     = 0        -- proximity poll accumulator (1s)
local idleTimer                = 0        -- real seconds player hasn't moved significantly
local lastPlayerPos            = nil      -- last known player/vehicle position for idle detection
local lastResetButtonVisible   = false    -- tracks last sent reset button visibility (avoids spam)
local nudgeSent                = false    -- watchdog nudge sent for current step
local originalPauseGetFn       = nil      -- stores original career_modules_uiUtils.getCareerPauseContextButtons
local originalSellVehicle      = nil      -- stores original career_modules_inventory.sellVehicle
local cachedGaragePos          = nil      -- cached garage door position (vec3)

-- ============================================================
-- Save / Load
-- ============================================================

loadSaveData = function()
  if not career_career or not career_career.isActive() then
    tutorialData = deepcopy(DEFAULT_DATA)
    return
  end

  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available, using default tutorial data')
    tutorialData = deepcopy(DEFAULT_DATA)
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('W', logTag, 'No save slot active, using default tutorial data')
    tutorialData = deepcopy(DEFAULT_DATA)
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    log('W', logTag, 'No autosave found for slot: ' .. tostring(currentSaveSlot))
    tutorialData = deepcopy(DEFAULT_DATA)
    return
  end

  local dataPath = autosavePath .. "/career/bcm/tutorial.json"
  local content = readFile(dataPath, "auto")
  local data = content and jsonDecode(content) or nil

  if not data then
    log('I', logTag, 'No tutorial save found, starting fresh')
    tutorialData = deepcopy(DEFAULT_DATA)
    return
  end

  -- Run version migrations
  if bcm_versionMigration then
    data = bcm_versionMigration.migrateModuleData("tutorial", data)
  end

  -- Ensure shownContextualTutorials is always a table (safety for old saves)
  if type(data.shownContextualTutorials) ~= "table" then
    data.shownContextualTutorials = {}
  end

  -- Ensure contextualTutorialsDisabled is always a boolean (safety for old saves)
  if data.contextualTutorialsDisabled == nil then
    data.contextualTutorialsDisabled = false
  end

  tutorialData = data
  log('I', logTag, 'Tutorial save loaded (step=' .. tostring(tutorialData.currentStep) .. ', done=' .. tostring(tutorialData.tutorialDone) .. ')')
end

saveTutorialData = function(currentSavePath)
  if not tutorialData then
    log('W', logTag, 'saveTutorialData called but no data loaded, skipping')
    return
  end

  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available, cannot save tutorial data')
    return
  end

  -- Resolve save path
  local savePath = currentSavePath
  if not savePath then
    local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
    if currentSaveSlot then
      savePath = career_saveSystem.getAutosave(currentSaveSlot)
    end
  end

  if not savePath then
    log('W', logTag, 'No save path available, cannot save tutorial data')
    return
  end

  local bcmDir = savePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  local dataPath = bcmDir .. "/tutorial.json"
  career_saveSystem.jsonWriteFileSafe(dataPath, tutorialData, true)
  log('I', logTag, 'Tutorial data saved')
end

-- ============================================================
-- Vehicle ID tracking (called by bcm_spawnManager after Miramar spawn)
-- ============================================================

-- Ensure configBaseValue is set on an inventory vehicle.
local function ensureConfigBaseValue(inventoryId, model, config)
  local vehicles = career_modules_inventory.getVehicles()
  if not vehicles or not vehicles[inventoryId] then return end
  local vehicle = vehicles[inventoryId]
  if type(vehicle.configBaseValue) == "number" then return end

  local fallbackValue = 5000
  if model and config and core_vehicles and core_vehicles.getConfig then
    local configData = core_vehicles.getConfig(model, config)
    if configData and type(configData.Value) == "number" then
      fallbackValue = configData.Value
    end
  end
  vehicle.configBaseValue = fallbackValue
  log('I', logTag, 'Set configBaseValue=' .. tostring(fallbackValue) .. ' for inv=' .. tostring(inventoryId))
end

-- Build vehicleInfo table for insurance registration.
local function buildInsuranceVehicleInfo(invVeh, model)
  if not invVeh then return nil end
  return {
    Name = invVeh.niceName or model or "Vehicle",
    Value = invVeh.configBaseValue or 5000,
    Population = 0,
    BodyStyle = {},
    aggregates = {
      ["Body Style"] = {},
    },
  }
end


-- Callback from vehicle Lua after partCondition.initConditions completes.
M.onMiramarSpawnFinished = function(vehId)
  -- 1. Add to inventory
  local inventoryId = career_modules_inventory.addVehicle(vehId, nil, { owned = true })
  if not inventoryId then
    log('E', logTag, 'addVehicle returned nil for vehId=' .. tostring(vehId))
    return
  end

  -- 2. Set plate
  career_modules_inventory.setLicensePlateText(inventoryId, "DADDY")

  -- 3. Assign to starter garage (find by isStarterGarage flag in config)
  local starterGarageId = nil
  if bcm_garages and bcm_garages.getAllDefinitions then
    local allDefs = bcm_garages.getAllDefinitions()
    for garageId, def in pairs(allDefs) do
      if def.isStarterGarage then
        starterGarageId = garageId
        break
      end
    end
  end
  if not starterGarageId then
    starterGarageId = "bcm_chinatown"  -- hardcoded fallback
    log('W', logTag, 'No starter garage found in config, using fallback: ' .. starterGarageId)
  end
  local vehicles = career_modules_inventory.getVehicles()
  if vehicles and vehicles[inventoryId] then
    vehicles[inventoryId].location = starterGarageId
  end

  -- 4. Ensure configBaseValue
  ensureConfigBaseValue(inventoryId, "miramar", "mysummer_starter")

  -- 5. Register with insurance system.
  -- vanilla's addVehicle dispatches onVehicleAdded (NOT onVehicleAddedToInventory).
  -- insurance.lua only listens to onVehicleAddedToInventory, so we must call it manually.
  -- Use insuranceId=1 (dailyDriver1 — basic insurance) same as vanilla's first purchase.
  if career_modules_insurance_insurance and career_modules_insurance_insurance.onVehicleAddedToInventory then
    local invVeh = vehicles and vehicles[inventoryId]
    local vehicleInfo = buildInsuranceVehicleInfo(invVeh, "miramar")
    if vehicleInfo then
      local ok, err = pcall(career_modules_insurance_insurance.onVehicleAddedToInventory, {
        inventoryId = inventoryId,
        vehicleInfo = vehicleInfo,
        purchaseData = { insuranceId = 1 },
      })
      if not ok then
        log('E', logTag, 'onVehicleAddedToInventory CRASHED: ' .. tostring(err))
      end
    end
    -- Diagnose: check what insurance actually wrote
    if career_modules_insurance_insurance.getInvVehs then
      local invVehs = career_modules_insurance_insurance.getInvVehs()
      local entry = invVehs and invVehs[inventoryId]
      if entry then
        log('I', logTag, 'Insurance post-check: inv=' .. tostring(inventoryId)
          .. ' insuranceId=' .. tostring(entry.insuranceId)
          .. ' reqClass=' .. tostring(entry.requiredInsuranceClass and entry.requiredInsuranceClass.id or 'NIL'))
      else
        log('E', logTag, 'Insurance post-check: NO ENTRY for inv=' .. tostring(inventoryId))
      end
      -- Safety net: force insuranceId if vanilla left it nil
      if entry and entry.insuranceId == nil then
        entry.insuranceId = 1
        log('W', logTag, 'Insurance: forced insuranceId=1 for Miramar inv=' .. tostring(inventoryId))
      end
    end
  end

  -- 6. Store in tutorial data
  if tutorialData then
    tutorialData.miramarInventoryId = inventoryId
    saveTutorialData()
  end

  -- 7. Force save
  if career_saveSystem and career_career and career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end

  log('I', logTag, 'Miramar fully registered: inventory + insurance + garage (id=' .. tostring(inventoryId) .. ')')
end

-- ============================================================
-- Garage position helper
-- ============================================================

getGaragePosition = function()
  if cachedGaragePos then return cachedGaragePos end

  -- Try to resolve dynamically from bcm_garages (uses isStarterGarage flag)
  if bcm_garages and bcm_garages.getStarterGarageId and freeroam_facilities then
    local starterId = bcm_garages.getStarterGarageId()
    if starterId then
      local spots = freeroam_facilities.getParkingSpotsForFacility and
                    freeroam_facilities.getParkingSpotsForFacility(starterId)
      if spots and spots[1] and spots[1].pos then
        cachedGaragePos = spots[1].pos
        log('I', logTag, 'Garage position resolved from facilities: ' .. tostring(cachedGaragePos))
        return cachedGaragePos
      end
    end
  end

  -- Fallback: hardcoded Chinatown parking1 position (from facilities.sites.json)
  cachedGaragePos = vec3(-807.81, 605.74, 117.36)
  log('I', logTag, 'Garage position using hardcoded Chinatown fallback')
  return cachedGaragePos
end

-- ============================================================
-- Watchdog nudge hints
-- ============================================================

getNudgeHintForStep = function(step)
  local hints = {
    [1] = t("Walk to the red car and press the enter-vehicle prompt.", "Acércate al coche rojo y pulsa el botón para subir."),
    [2] = t("Follow the GPS route to reach the garage.", "Sigue la ruta GPS para llegar al garaje."),
    [3] = t("Enter the garage and interact with the computer terminal.", "Entra al garaje e interactúa con la terminal del ordenador."),
    [4] = t("Follow the on-screen guides to complete the desktop tutorial.", "Sigue las guias en pantalla para completar el tutorial del escritorio."),
    [5] = t("Open your phone and use the sleep feature.", "Abre tu movil y usa la funcion de dormir."),
    [6] = t("The tutorial is complete! Enjoy Better Career Mod.", "El tutorial esta completo! Disfruta de Better Career Mod."),
  }
  return hints[step] or t("Check the tasklist for your current objective.", "Consulta la lista de tareas para ver tu objetivo actual.")
end

-- ============================================================
-- Waypoint management
-- ============================================================

setWaypointForStep = function(n)
  local subStep = tutorialData and tutorialData.tutorialSubStep or ''
  if n == 2 or (n == 4 and subStep == 'toll_to_garage') then
    local garagePos = getGaragePosition()
    if garagePos then
      if freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then
        freeroam_bigMapMode.setNavFocus(garagePos)
      end
      log('I', logTag, 'GPS waypoint set to garage for step ' .. tostring(n))
    end
  else
    -- Clear waypoint
    if freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then
      freeroam_bigMapMode.setNavFocus(nil)
    end
  end
end

-- ============================================================
-- broadcastStepState — single source of truth for Vue step sync
-- ============================================================

broadcastStepState = function()
  if not tutorialData then return end
  local stepDef = STEPS[tutorialData.currentStep]
  guihooks.trigger("BCMTutorialStepChanged", {
    step    = tutorialData.currentStep,
    subStep = tutorialData.tutorialSubStep or '',
    total   = 6,
    stepId  = stepDef and stepDef.id or "",
  })
end

-- ============================================================
-- FSM: advanceToStep
-- ============================================================

advanceToStep = function(n)
  log('I', logTag, 'advanceToStep(' .. tostring(n) .. ') called')
  if not tutorialData then return end
  if n > 6 then
    completeTutorial()
    return
  end

  tutorialData.currentStep    = n
  tutorialData.tutorialSubStep = ''  -- reset sub-step for new step
  tutorialData.stepStartedAt  = os.time()
  saveTutorialData()

  -- Reset per-step watchdog tracking
  nudgeSent       = false
  idleTimer       = 0
  lastPlayerPos   = nil

  -- Clear existing tasklist and set new header + task
  guihooks.trigger("ClearTasklist", {})
  guihooks.trigger("SetTasklistHeader", {
    label   = t("Tutorial", "Tutorial"),
    subtext = t("Step " .. tostring(n) .. " of 6", "Paso " .. tostring(n) .. " de 6"),
  })

  local step = STEPS[n]
  if step then
    guihooks.trigger("SetTasklistTask", {
      id        = step.id,
      label     = step.label(),
      subtext   = step.subtext(),
      type      = step.type,
      attention = true,
    })
  end

  -- Notify Vue of step change (includes subStep='')
  broadcastStepState()

  -- Set GPS for navigation steps
  setWaypointForStep(n)

  -- Configure radial menu for this step
  if core_recoveryPrompt then
    if n == 5 then
      -- Step 5 (phone+sleep): restore career defaults, radial recovery no longer part of tutorial
      core_recoveryPrompt.setDefaultsForCareer()
    else
      core_recoveryPrompt.setDefaultsForTutorial()
    end
  end

  -- Step 4: inject tutorial pack + start at first sub-step (PC is already open since step 3 completed from it)
  if n == 4 then
    if bcm_planex and bcm_planex.injectTutorialPack then
      local ok, err = pcall(bcm_planex.injectTutorialPack)
      if not ok then
        log('W', logTag, 'injectTutorialPack error (non-fatal): ' .. tostring(err))
      end
    else
      log('W', logTag, 'bcm_planex.injectTutorialPack not available at step 4')
    end
    -- The computer is already open (step 3 = "use the computer"), start at first sub-step
    M.setSubStep('desktop_eboy')
  end

  -- Step 6: tutorial complete — fire popup event and return (popup dismiss calls completeTutorial)
  if n == 6 then
    guihooks.trigger("BCMTutorialComplete", {})
    return
  end

  -- Immediate check: if condition already met, complete now
  if step and step.immediateCheck then
    local ok, err = pcall(function()
      if step.immediateCheck() then
        checkStepCompletion(n)
      end
    end)
    if not ok then
      log('W', logTag, 'immediateCheck error for step ' .. tostring(n) .. ': ' .. tostring(err))
    end
  end
end

-- ============================================================
-- FSM: checkStepCompletion
-- ============================================================

checkStepCompletion = function(n)
  if not tutorialData then return end
  if tutorialData.currentStep ~= n then
    log('I', logTag, 'checkStepCompletion(' .. tostring(n) .. ') ignored — current step is ' .. tostring(tutorialData.currentStep))
    return
  end

  local step = STEPS[n]
  if not step then return end

  log('I', logTag, 'Step ' .. tostring(n) .. ' (' .. step.id .. ') completed')

  -- Fire tasklist completion events
  guihooks.trigger("CompleteTasklistGoal", step.id)
  guihooks.trigger("DiscardTasklistItem", step.id, 2000)

  -- Advance to next step after brief delay (1.5s)
  local advanced = false
  if core_jobsystem and core_jobsystem.create then
    local ok, err = pcall(function()
      core_jobsystem.create(function(job)
        job.sleep(1.5)
        advanceToStep(n + 1)
      end)
    end)
    if ok then
      advanced = true
    else
      log('W', logTag, 'core_jobsystem.create failed: ' .. tostring(err) .. ' — advancing immediately')
    end
  end
  if not advanced then
    advanceToStep(n + 1)
  end
end

-- ============================================================
-- FSM: completeTutorial
-- ============================================================

completeTutorial = function()
  if not tutorialData then return end

  -- Reactivate police pool (units were deactivated to reserve during tutorial)
  if bcm_police and bcm_police.reactivatePool then
    bcm_police.reactivatePool()
  end

  tutorialData.tutorialDone     = true
  tutorialData.currentStep      = 999
  tutorialData.tutorialSubStep  = ''
  -- Mark spotlights already seen during linear tutorial (subSteps 1-3 covered these)
  tutorialData.shownContextualTutorials["garage_desktop"] = true
  saveTutorialData()

  guihooks.trigger("ClearTasklist", {})
  broadcastStepState()
  guihooks.trigger("BCMTutorialShowResetButton", { visible = false })

  unpatchPauseMenu()
  unpatchInventorySell()

  -- Restore radial menu to career defaults
  if core_recoveryPrompt and core_recoveryPrompt.setDefaultsForCareer then
    core_recoveryPrompt.setDefaultsForCareer()
  end

  log('I', logTag, 'Tutorial completed!')
end

-- ============================================================
-- Pause menu monkey-patch
-- ============================================================

patchPauseMenu = function()
  if not career_modules_uiUtils then return end
  if originalPauseGetFn then return end  -- already patched

  originalPauseGetFn = career_modules_uiUtils.getCareerPauseContextButtons

  career_modules_uiUtils.getCareerPauseContextButtons = function()
    local data = originalPauseGetFn()
    if not data then data = { buttons = {} } end
    if not data.buttons then data.buttons = {} end

    -- Insert "Skip Tutorial" at position 1
    table.insert(data.buttons, 1, {
      label         = "Skip Tutorial",
      icon          = "skip_next",
      fun           = function()
        guihooks.trigger("BCMTutorialSkipRequested", {})
      end,
      showIndicator = false,
    })

    -- Re-index function IDs (critical: prevents wrong button firing)
    if career_modules_uiUtils.storeCareerPauseContextButtons then
      career_modules_uiUtils.storeCareerPauseContextButtons(data)
    end

    return data
  end

  log('I', logTag, 'Pause menu patched with Skip Tutorial button')
end

unpatchPauseMenu = function()
  if not career_modules_uiUtils then return end
  if not originalPauseGetFn then return end

  career_modules_uiUtils.getCareerPauseContextButtons = originalPauseGetFn
  originalPauseGetFn = nil

  log('I', logTag, 'Pause menu unpatched')
end

-- ============================================================
-- Inventory sell monkey-patch (Miramar sale block)
-- ============================================================

patchInventorySell = function()
  if not career_modules_inventory then return end
  if originalSellVehicle then return end  -- already patched

  originalSellVehicle = career_modules_inventory.sellVehicle

  career_modules_inventory.sellVehicle = function(inventoryId, price)
    if tutorialData
      and not tutorialData.tutorialDone
      and tutorialData.miramarInventoryId
      and inventoryId == tutorialData.miramarInventoryId
    then
      ui_message(t("You can't sell the Miramar during the tutorial.", "No puedes vender el Miramar durante el tutorial."), 4, "warning", "warning")
      return false
    end
    return originalSellVehicle(inventoryId, price)
  end

  log('I', logTag, 'Inventory sell patched — Miramar sale blocked during tutorial')
end

unpatchInventorySell = function()
  if not career_modules_inventory then return end
  if not originalSellVehicle then return end

  career_modules_inventory.sellVehicle = originalSellVehicle
  originalSellVehicle = nil

  log('I', logTag, 'Inventory sell unpatched')
end

-- ============================================================
-- Public actions
-- ============================================================

confirmSkip = function()
  if not tutorialData then return end

  -- If step 4 is active, cancel the tutorial pack
  if tutorialData.currentStep == 4 then
    if bcm_planex and bcm_planex.abandonPack then
      bcm_planex.abandonPack()
    end
  end

  -- Reactivate police pool
  if bcm_police and bcm_police.reactivatePool then
    bcm_police.reactivatePool()
  end

  skipTutorial()

  guihooks.trigger("BCMTutorialShowResetButton", { visible = false })
  broadcastStepState()
  guihooks.trigger("ClearTasklist", {})

  unpatchPauseMenu()
  unpatchInventorySell()

  -- Restore radial menu
  if core_recoveryPrompt and core_recoveryPrompt.setDefaultsForCareer then
    core_recoveryPrompt.setDefaultsForCareer()
  end

  log('I', logTag, 'Tutorial skipped via confirmSkip()')
end

skipCurrentStep = function()
  if not tutorialData then return end
  if tutorialData.tutorialDone then return end
  local step = tutorialData.currentStep
  if step < 1 or step > 6 then return end

  -- If skipping step 4 (PlanEx delivery), silently reset PlanEx state and clear GPS
  if step == 4 and bcm_planex then
    bcm_planex.abandonPack()
  end

  log('I', logTag, 'Skipping individual step ' .. tostring(step))
  advanceToStep(step + 1)
end

resetVehicle = function()
  local vehId = be:getPlayerVehicleID(0)
  if not vehId or vehId < 0 then return end

  local veh = be:getObjectByID(vehId)
  if not veh then return end

  -- Teleport to last road position
  if spawn and spawn.teleportToLastRoad then
    spawn.teleportToLastRoad(veh)
  end

  -- Start repair if available
  if career_modules_insurance_insurance and career_modules_insurance_insurance.startRepair then
    career_modules_insurance_insurance.startRepair(nil)
  end

  -- Restore cargo weight on the vehicle after reset (parcels may lose their vehicle location)
  if bcm_planex and bcm_planex.getActivePack then
    local pack = bcm_planex.getActivePack()
    if pack and pack.isTutorialPack and pack.stops then
      pcall(function()
        career_modules_delivery_general.getNearbyVehicleCargoContainers(function(containers)
          local vehContainers = {}
          for _, con in ipairs(containers) do
            if con.vehId == vehId and con.location then
              table.insert(vehContainers, con)
            end
          end
          if #vehContainers > 0 then
            local conIdx = 1
            for _, stop in ipairs(pack.stops) do
              if stop.parcelId then
                career_modules_delivery_parcelManager.addTransientMoveCargo(stop.parcelId, vehContainers[conIdx].location)
                conIdx = (conIdx % #vehContainers) + 1
              end
            end
            log('I', logTag, 'resetVehicle: cargo re-attached to vehicle after reset')
          end
        end)
      end)
    end
  end

  -- Reset idle timer
  idleTimer     = 0
  lastPlayerPos = nil
  nudgeSent     = false

  guihooks.trigger("BCMTutorialShowResetButton", { visible = false })
  log('I', logTag, 'resetVehicle called for vehId=' .. tostring(vehId))
end

isPhoneBlocked = function()
  return tutorialData ~= nil
    and not tutorialData.tutorialDone
    and (tutorialData.currentStep or 0) >= 1
    and (tutorialData.currentStep or 0) < 5
end

-- ============================================================
-- Detection hooks (M.onXxx — called by extensions.hook)
-- ============================================================

onVehicleSwitched = function(oldId, newId)
  if not tutorialData or tutorialData.tutorialDone then return end
  if tutorialData.currentStep == 1 and newId and newId >= 0 then
    checkStepCompletion(1)
  end
end

onComputerMenuOpened = function()
  if not tutorialData or tutorialData.tutorialDone then return end
  if tutorialData.currentStep == 3 then
    checkStepCompletion(3)
  end
end

-- onComputerAddFunctions: receives menuData (same data Vue uses for icons/CARamp).
-- menuData.vehiclesInGarage has the exact list of vehicles visible at the computer.
M.onComputerAddFunctions = function(menuData, computerFunctions)
  if not tutorialData or tutorialData.tutorialDone then return end
  if tutorialData.currentStep ~= 4 then return end

  -- Don't re-evaluate during O'Really branch — let checkout flow finish
  local sub = tutorialData.tutorialSubStep or ''
  if sub:find('^oreally_') or sub == 'back_to_desktop' then
    log('I', logTag, 'onComputerAddFunctions: skipping re-eval during O\'Really flow (sub="' .. sub .. '")')
    return
  end

  -- Retrieve branch — don't re-evaluate, but ONLY for valid retrieve sub-steps
  if RETRIEVE_SUBSTEP_INDEX[sub] then
    log('I', logTag, 'onComputerAddFunctions: skipping re-eval during retrieve (sub="' .. sub .. '")')
    return
  end

  -- Ensure tutorial pack exists
  if bcm_planex and bcm_planex.injectTutorialPack then
    pcall(bcm_planex.injectTutorialPack)
  end

  -- ══════════════════════════════════════════════════════════════
  -- STEP 4: On every computer open, recalculate from real state.
  -- menuData.vehiclesInGarage = same list that shows icons/CARamp.
  -- If Miramar isn't in this list → retrieve. If it is → cargo check.
  -- ══════════════════════════════════════════════════════════════

  local allVehicles = career_modules_inventory and career_modules_inventory.getVehicles() or {}
  local miramarVehObj = nil
  local garageVehicles = menuData and menuData.vehiclesInGarage or {}
  for _, vehData in ipairs(garageVehicles) do
    local invId = vehData.inventoryId
    local veh = allVehicles[invId]
    if veh and veh.model == 'miramar' then
      local objId = career_modules_inventory.getVehicleIdFromInventoryId(invId)
      if objId then
        miramarVehObj = be:getObjectByID(objId)
      end
      break
    end
  end
  log('I', logTag, 'Step 4: vehiclesInGarage=' .. #garageVehicles .. ' miramarFound=' .. tostring(miramarVehObj ~= nil))

  -- 1. Miramar not at computer → retrieve branch
  if not miramarVehObj then
    M.setSubStep('retrieve_open_my_vehicles')
    log('I', logTag, 'Step 4: Miramar not spawned → retrieve branch')
    return
  end

  -- 2. Miramar spawned → async cargo check to decide IE or O'Really
  core_vehicleBridge.requestValue(miramarVehObj, function(data)
    if not tutorialData or tutorialData.currentStep ~= 4 then return end
    local totalSlots = 0
    local containers = data and data[1] or nil
    if containers then
      for _, container in pairs(containers) do
        totalSlots = totalSlots + (container.capacity or 0)
      end
    end
    local hasCargo = totalSlots > 50
    log('I', logTag, 'Step 4 cargo check: capacity=' .. totalSlots .. ' hasCargo=' .. tostring(hasCargo))
    if hasCargo then
      M.setSubStep('click_ie')
      log('I', logTag, 'Step 4: has cargo → click_ie (IE/PlanEx flow)')
    else
      M.setSubStep('desktop_eboy')
      log('I', logTag, 'Step 4: no cargo → desktop_eboy (O\'Really flow)')
    end
  end, 'getCargoContainers')
end

onBCMPartsShopCheckoutComplete = function(data)
  if not tutorialData or tutorialData.tutorialDone then return end
  if tutorialData.currentStep ~= 4 then return end
  if data and data.deliveryType == 'fullservice' then
    M.setSubStep('oreally_close_window')
    log('I', logTag, 'Step 4 subStep oreally_close_window: fullservice checkout complete')
  end
end

onBCMTutorialPackComplete = function()
  if not tutorialData or tutorialData.tutorialDone then return end
  if tutorialData.currentStep ~= 4 then return end
  -- Delivery complete, player must return to garage
  M.setSubStep('toll_to_garage')
  guihooks.trigger("SetTasklistTask", {
    id      = STEPS[4].id,
    label   = t("Return to the garage", "Vuelve al garaje"),
    subtext = t("Drive back to the Chinatown Garage. Press M to check the map.", "Conduce de vuelta al garaje de Chinatown. Pulsa M para consultar el mapa."),
    type    = STEPS[4].type,
  })
  -- Set GPS waypoint to garage for return
  setWaypointForStep(4)
  log('I', logTag, 'Step 4 subStep toll_to_garage: delivery complete, return to garage')
end

-- Step 4: pack accepted → "drive to depot"
M.onBCMTutorialPackAccepted = function()
  if not tutorialData or tutorialData.tutorialDone then return end
  if tutorialData.currentStep ~= 4 then return end
  M.setSubStep('drive_to_depot')
  guihooks.trigger("SetTasklistTask", {
    id      = STEPS[4].id,
    label   = t("Drive to the depot", "Conduce al deposito"),
    subtext = t("Follow the GPS to the depot to pick up your cargo.", "Sigue el GPS hasta el deposito para recoger tu carga."),
    type    = STEPS[4].type,
  })
  log('I', logTag, 'Step 4 subStep drive_to_depot: pack accepted')
end

-- Step 4: cargo picked up at depot → "deliver the cargo"
M.onBCMTutorialDepotPickup = function()
  if not tutorialData or tutorialData.tutorialDone then return end
  if tutorialData.currentStep ~= 4 then return end
  M.setSubStep('complete_delivery')
  guihooks.trigger("SetTasklistTask", {
    id      = STEPS[4].id,
    label   = t("Deliver the cargo", "Entrega la mercancia"),
    subtext = t("Follow the GPS to the delivery location and drop off the cargo.", "Sigue el GPS hasta el punto de entrega y descarga la mercancia."),
    type    = STEPS[4].type,
  })
  log('I', logTag, 'Step 4 subStep complete_delivery: delivering')
end

onBCMSleepComplete = function(result)
  if not tutorialData or tutorialData.tutorialDone then return end
  if tutorialData.currentStep == 5 then
    checkStepCompletion(5)
  end
end

-- Step 5: phone opened → update tasklist (standalone spotlight pattern, keyed by step 5)
M.onBCMPhoneOpened = function()
  if not tutorialData or tutorialData.tutorialDone then return end
  if tutorialData.currentStep ~= 5 then return end
  if (tutorialData.tutorialSubStep or '') ~= '' then return end  -- already advanced
  M.setSubStep('phone_opened')
  guihooks.trigger("SetTasklistTask", {
    id      = STEPS[5].id,
    label   = t("Sleep until 7 AM", "Duerme hasta las 7 AM"),
    subtext = t("Use the phone to sleep until 7:00 AM tomorrow.", "Usa el movil para dormir hasta las 7:00 AM de manana."),
    type    = STEPS[5].type,
  })
  log('I', logTag, 'Step 5 subStep phone_opened')
end

-- ============================================================
-- onUpdate — proximity polling, idle/flip detection, watchdog
-- ============================================================

onUpdate = function(dtReal, dtSim, dtRaw)
  if not tutorialData then return end
  if tutorialData.tutorialDone then return end

  local step = tutorialData.currentStep
  if step < 1 or step > 6 then return end

  -- ---- Garage proximity polling (step 2 and step 4 toll_to_garage) ----
  local subStep = tutorialData.tutorialSubStep or ''
  local doGarageCheck = (step == 2)
    or (step == 4 and subStep == 'toll_to_garage')

  if doGarageCheck then
    garageProximityTimer = garageProximityTimer + dtReal
    if garageProximityTimer >= 1.0 then
      garageProximityTimer = 0

      local garagePos = getGaragePosition()
      if garagePos then
        local vehId = be:getPlayerVehicleID(0)
        local playerPos = nil
        if vehId and vehId >= 0 then
          local veh = be:getObjectByID(vehId)
          if veh then
            playerPos = veh:getPosition()
          end
        end

        if playerPos then
          local dx = garagePos.x - playerPos.x
          local dy = garagePos.y - playerPos.y
          local dz = (garagePos.z or 0) - (playerPos.z or 0)
          local dist = math.sqrt(dx*dx + dy*dy + dz*dz)

          if dist < 30 then
            log('I', logTag, 'Step ' .. tostring(step) .. ': garage proximity triggered (dist=' .. string.format("%.1f", dist) .. 'm)')
            checkStepCompletion(step)
          end
        end
      end
    end
  end

  -- ---- Idle/flip/damage detection (for showing reset button) ----
  -- Skip entirely if player is walking
  local vehId = be:getPlayerVehicleID(0)
  local shouldShowReset = false
  local isWalking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()

  if vehId and vehId >= 0 and not isWalking then
    local veh = be:getObjectByID(vehId)
    if veh then
      -- Flip detection: vehicle upside down or on its side
      local upOk, upVec = pcall(function() return veh:getDirectionVectorUp() end)
      if upOk and upVec and upVec.z < 0.5 then
        shouldShowReset = true
      end

      -- Damage detection: show reset if vehicle has significant damage
      if core_vehicle_partCondition then
        local ok, brokenCount = pcall(function()
          return core_vehicle_partCondition.getNumberOfBrokenParts(vehId) or 0
        end)
        if ok and brokenCount and brokenCount >= 3 then
          shouldShowReset = true
        end
      end

      -- Idle detection (10s instead of 30s — tutorial should be responsive)
      local pos = veh:getPosition()
      if pos then
        if lastPlayerPos then
          local dx = pos.x - lastPlayerPos.x
          local dy = pos.y - lastPlayerPos.y
          local moved = math.sqrt(dx*dx + dy*dy)

          if moved < 0.5 then
            idleTimer = idleTimer + dtReal
            if idleTimer >= 10 then
              shouldShowReset = true
            end
          else
            idleTimer = 0
          end
        end
        lastPlayerPos = { x = pos.x, y = pos.y, z = pos.z or 0 }
      end
    end
  end

  -- Only send guihook when visibility state actually changes
  if shouldShowReset ~= lastResetButtonVisible then
    lastResetButtonVisible = shouldShowReset
    guihooks.trigger("BCMTutorialShowResetButton", { visible = shouldShowReset })
  end

  -- ---- Watchdog: nudge notification after 30s ----
  if not nudgeSent and tutorialData.stepStartedAt then
    local elapsed = os.time() - tutorialData.stepStartedAt
    if elapsed > 30 then
      nudgeSent = true
      local hint = getNudgeHintForStep(step)
      if bcm_notifications and bcm_notifications.showNotification then
        bcm_notifications.showNotification({
          title   = "Hint",
          message = hint,
          type    = "info",
        })
      else
        ui_message(hint, 6, "info", "info")
      end
      log('I', logTag, 'Watchdog nudge fired for step ' .. tostring(step))
    end
  end
end

-- ============================================================
-- FSM: restoreStepUI (replaces Phase 79 no-op)
-- ============================================================

restoreStepUI = function()
  if not tutorialData then return end
  if tutorialData.tutorialDone then return end

  local step = tutorialData.currentStep
  if not step or step == 0 or step == 999 then return end

  -- ── Recovery: map saved step to a coherent restart point ──────────────
  -- Steps 1-3: recover to step=4 subStep='' (go to computer)
  -- Step 4: preserve subStep — onComputerMenuOpened will handle resume
  -- Steps 5-6: keep as-is (post-delivery, independent actions)
  if step >= 1 and step <= 3 then
    log('I', logTag, 'restoreStepUI: recovery step ' .. step .. ' -> 4 subStep ""')
    tutorialData.currentStep = 4
    tutorialData.tutorialSubStep = ''
    tutorialData.stepStartedAt = os.time()
    saveTutorialData()
    step = 4
  elseif step == 4 then
    -- Preserve subStep, but validate it exists in known sub-step tables
    local sub = tutorialData.tutorialSubStep or ''
    if sub == 'drive_to_depot' or sub == 'complete_delivery' then
      -- Mid-delivery: abandon pack and restart from click_ie
      if bcm_planex and bcm_planex.abandonPack then
        pcall(function() bcm_planex.abandonPack() end)
      end
      tutorialData.tutorialSubStep = 'click_ie'
      saveTutorialData()
      log('I', logTag, 'restoreStepUI: step 4 mid-delivery "' .. sub .. '" -> click_ie (pack abandoned)')
    elseif sub ~= '' and not STEP4_SUBSTEP_INDEX[sub] and not RETRIEVE_SUBSTEP_INDEX[sub] then
      -- Stale/removed sub-step: reset so onComputerAddFunctions can re-evaluate
      tutorialData.tutorialSubStep = ''
      saveTutorialData()
      log('I', logTag, 'restoreStepUI: step 4 stale subStep "' .. sub .. '" -> "" (will re-evaluate)')
    else
      log('I', logTag, 'restoreStepUI: step 4 preserving subStep "' .. sub .. '"')
    end
  end

  -- ── Re-fire tasklist UI ───────────────────────────────────────────────
  guihooks.trigger("SetTasklistHeader", {
    label   = t("Tutorial", "Tutorial"),
    subtext = t("Step " .. tostring(step) .. " of 6", "Paso " .. tostring(step) .. " de 6"),
  })

  local stepDef = STEPS[step]
  if stepDef then
    guihooks.trigger("SetTasklistTask", {
      id        = stepDef.id,
      label     = stepDef.label(),
      subtext   = stepDef.subtext(),
      type      = stepDef.type,
      attention = false,
    })
  end

  -- Re-fire step changed for Vue (includes subStep)
  broadcastStepState()

  -- Re-fire waypoint
  setWaypointForStep(step)

  -- Step 4 recovery: inject tutorial pack when facilities are ready
  if step == 4 then
    local function tryInject(attempt)
      if not bcm_planex or not bcm_planex.injectTutorialPack then return end
      local ok = bcm_planex.injectTutorialPack()
      if not ok and attempt < 10 then
        log('I', logTag, 'restoreStepUI: tutorial pack inject attempt ' .. attempt .. ' failed, retrying in 2s')
        if core_jobsystem then
          core_jobsystem.create(function(job)
            job.sleep(2.0)
            tryInject(attempt + 1)
          end)
        end
      end
    end
    tryInject(1)
  end

  -- Re-show reset button if applicable
  if idleTimer >= 30 then
    guihooks.trigger("BCMTutorialShowResetButton", { visible = true })
  end

  log('I', logTag, 'restoreStepUI: restored UI for step ' .. tostring(step))
end

-- ============================================================
-- Tutorial FSM: skipTutorial / beginTutorial
-- ============================================================

skipTutorial = function()
  if not tutorialData then
    log('W', logTag, 'skipTutorial called but no data loaded')
    return
  end
  tutorialData.tutorialDone    = true
  tutorialData.tutorialSkipped = true
  tutorialData.currentStep     = 999
  saveTutorialData()
  -- Ensure PlanEx pool is ready so the player isn't left with zero packs.
  -- Force rotation check on next PlanEx open by resetting lastRotationId.
  if bcm_planex and bcm_planex.forcePoolReady then
    bcm_planex.forcePoolReady()
  end
  log('I', logTag, 'Tutorial skipped')
end

beginTutorial = function()
  if not tutorialData then
    log('W', logTag, 'beginTutorial called but no data loaded')
    return
  end
  tutorialData.currentStep  = 1
  tutorialData.stepStartedAt = os.time()
  saveTutorialData()

  patchPauseMenu()
  patchInventorySell()

  -- Disable police during tutorial: deactivate all units to reserve
  if bcm_police and bcm_police.deactivateAllUnits then
    bcm_police.deactivateAllUnits()
  end

  advanceToStep(1)

  log('I', logTag, 'Tutorial started at step 1')
end

-- ============================================================
-- Lifecycle Hooks
-- ============================================================

onFirstCareerStart = function()
  if not tutorialData then
    log('W', logTag, 'onFirstCareerStart: tutorialData not loaded, cannot proceed')
    return
  end

  -- Debug mode: auto-skip tutorial (no need to wait for DUMB)
  if bcm_settings and bcm_settings.getSetting("debugMode") then
    log('I', logTag, 'devMode active — auto-skipping tutorial')
    skipTutorial()
    return
  end

  -- Mark tutorial as pending — will start when identity modal (DUMB) closes
  tutorialData.pendingStart = true
  saveTutorialData()
  log('I', logTag, 'Tutorial pending — waiting for identity modal (DUMB) to close')
end

-- Called by identity.lua after player submits identity form
M.onBCMIdentitySet = function()
  if not tutorialData then return end
  if not tutorialData.pendingStart then return end
  if tutorialData.tutorialDone then return end

  tutorialData.pendingStart = nil
  saveTutorialData()

  log('I', logTag, 'Identity set — starting tutorial now')
  beginTutorial()
end

onCareerActive = function(active)
  if not active then
    tutorialData     = nil
    cachedGaragePos  = nil
    originalPauseGetFn  = nil
    originalSellVehicle = nil
    return
  end

  -- Register migrations
  if bcm_versionMigration then
    bcm_versionMigration.registerModuleMigrations("tutorial", 4, {
      [1] = function(data)
        -- v1 -> v2: add contextualTutorialsDisabled
        if data.contextualTutorialsDisabled == nil then
          data.contextualTutorialsDisabled = false
        end
        return data
      end,
      [2] = function(data)
        -- v2 -> v3: add numeric tutorialSubStep, remove string sub-phases
        data.tutorialSubStep = 0
        data.step4SubPhase = nil
        data.step5SubPhase = nil
        data.step6SubPhase = nil
        return data
      end,
      [3] = function(data)
        -- v3 -> v4: restructure 7 steps to 6, string sub-steps, remove loaner
        local step = data.currentStep or 0
        if step >= 1 and step <= 3 then
          -- steps 1-3 map 1:1, no change
        elseif step == 4 or step == 5 then
          data.currentStep = 4
        elseif step == 6 then
          data.currentStep = 5
        elseif step == 7 then
          data.currentStep = 6
        end
        -- done/999 stays as-is
        -- Sub-step is ephemeral: always reset (D-07)
        data.tutorialSubStep = ''
        -- Remove loaner field (D-08)
        data.loanerInventoryId = nil
        return data
      end,
    })
  end

  loadSaveData()

  -- Restore patches if tutorial still active
  if tutorialData and not tutorialData.tutorialDone and tutorialData.currentStep > 0 then
    patchPauseMenu()
    patchInventorySell()

    -- Re-deactivate police on load (they may have respawned during load)
    if bcm_police and bcm_police.deactivateAllUnits then
      bcm_police.deactivateAllUnits()
      log('I', logTag, 'Police deactivated on load (tutorial still active)')
    end
  end

  restoreStepUI()
end

onSaveCurrentSaveSlot = function(currentSavePath, oldSaveDate, forceSyncSave)
  if not tutorialData then return end
  saveTutorialData(currentSavePath)
end

-- ============================================================
-- Full tutorial reset (restart from step 1)
-- ============================================================

resetFullTutorial = function()
  if not tutorialData then return end

  -- Cancel any active PlanEx pack
  if bcm_planex and bcm_planex.abandonPack then
    pcall(function() bcm_planex.abandonPack() end)
  end

  -- Unpatch everything
  unpatchPauseMenu()
  unpatchInventorySell()

  -- Restore radial menu
  if core_recoveryPrompt and core_recoveryPrompt.setDefaultsForCareer then
    core_recoveryPrompt.setDefaultsForCareer()
  end

  -- Reactivate police
  if bcm_police and bcm_police.reactivatePool then
    bcm_police.reactivatePool()
  end

  -- Reset all tutorial state
  tutorialData.tutorialDone = false
  tutorialData.tutorialSkipped = false
  tutorialData.currentStep = 0
  tutorialData.tutorialSubStep = ''
  tutorialData.stepStartedAt = nil
  tutorialData.shownContextualTutorials = {}
  tutorialData.contextualTutorialsDisabled = false
  -- Keep miramarInventoryId — the player still owns the Miramar

  saveTutorialData()

  -- Clear UI
  guihooks.trigger("ClearTasklist", {})
  guihooks.trigger("BCMTutorialShowResetButton", { visible = false })
  broadcastStepState()

  -- Start tutorial fresh
  beginTutorial()

  log('I', logTag, 'Full tutorial reset -- restarting from step 1')
end

-- ============================================================
-- Debug commands (gated behind debugMode)
-- ============================================================

M.debugForceStep = function(step, subStep)
  if not bcm_settings or not bcm_settings.getSetting('debugMode') then
    log('W', logTag, 'debugForceStep: debugMode is off')
    return
  end
  if not tutorialData then return end
  tutorialData.currentStep = step or 0
  tutorialData.tutorialSubStep = subStep or ''
  tutorialData.tutorialDone = (step == 999)
  tutorialData.tutorialSkipped = false
  saveTutorialData()
  restoreStepUI()
  log('I', logTag, 'debugForceStep(' .. tostring(step) .. ', "' .. tostring(subStep) .. '")')
end

M.debugForceSpotlight = function(spotlightId)
  if not bcm_settings or not bcm_settings.getSetting('debugMode') then
    log('W', logTag, 'debugForceSpotlight: debugMode is off')
    return
  end
  if not spotlightId then return end
  guihooks.trigger('BCMDebugForceSpotlight', { id = spotlightId })
  log('I', logTag, 'debugForceSpotlight("' .. tostring(spotlightId) .. '")')
end

-- ============================================================
-- Extension reload: re-initialize if career is active
-- ============================================================

M.onExtensionLoaded = function()
  if career_career and career_career.isActive() then
    log('I', logTag, 'Extension reloaded while career active — re-initializing')
    onCareerActive(true)
  end
end

-- ============================================================
-- Public API
-- ============================================================

M.onFirstCareerStart         = onFirstCareerStart
M.onCareerActive             = onCareerActive
-- Insurance: existing saves patched by bcm_marketplaceApp (patches insurance.json on disk).
-- New careers: onMiramarSpawnFinished calls onVehicleAddedToInventory with insuranceId=-1.
M.onSaveCurrentSaveSlot      = onSaveCurrentSaveSlot
M.onUpdate                   = onUpdate
M.onVehicleSwitched          = onVehicleSwitched
M.onComputerMenuOpened       = onComputerMenuOpened
M.onBCMTutorialPackComplete  = onBCMTutorialPackComplete

M.isInTollToGarage = function()
  return tutorialData and not tutorialData.tutorialDone
    and tutorialData.currentStep == 4
    and tutorialData.tutorialSubStep == 'toll_to_garage'
end

M.refreshGarageWaypoint = function()
  setWaypointForStep(4)
  log('I', logTag, 'refreshGarageWaypoint: re-set GPS after results dismiss')
end
M.onBCMPartsShopCheckoutComplete = onBCMPartsShopCheckoutComplete
M.onBCMSleepComplete         = onBCMSleepComplete
M.completeTutorial           = completeTutorial
M.resetFullTutorial          = resetFullTutorial

-- Called from Vue after retrieve branch completes (My Vehicles window closed).
-- Re-evaluates Miramar + cargo state without needing onComputerAddFunctions menuData.
M.onComputerReevaluate = function()
  if not tutorialData or tutorialData.tutorialDone then return end
  if tutorialData.currentStep ~= 4 then return end
  log('I', logTag, 'onComputerReevaluate: re-checking Miramar + cargo after retrieve')

  -- Ensure tutorial pack
  if bcm_planex and bcm_planex.injectTutorialPack then
    pcall(bcm_planex.injectTutorialPack)
  end

  -- Find Miramar via inventory (same logic as onComputerAddFunctions)
  local allVehicles = career_modules_inventory and career_modules_inventory.getVehicles() or {}
  local miramarVehObj = nil
  for invId, veh in pairs(allVehicles) do
    if veh.model == 'miramar' then
      local objId = career_modules_inventory.getVehicleIdFromInventoryId(invId)
      if objId then
        miramarVehObj = be:getObjectByID(objId)
      end
      break
    end
  end

  if not miramarVehObj then
    M.setSubStep('retrieve_open_my_vehicles')
    log('I', logTag, 'onComputerReevaluate: still no Miramar → retrieve again')
    return
  end

  core_vehicleBridge.requestValue(miramarVehObj, function(data)
    if not tutorialData or tutorialData.currentStep ~= 4 then return end
    local totalSlots = 0
    local containers = data and data[1] or nil
    if containers then
      for _, container in pairs(containers) do
        totalSlots = totalSlots + (container.capacity or 0)
      end
    end
    local hasCargo = totalSlots > 50
    log('I', logTag, 'onComputerReevaluate cargo: capacity=' .. totalSlots .. ' hasCargo=' .. tostring(hasCargo))
    if hasCargo then
      M.setSubStep('click_ie')
    else
      M.setSubStep('desktop_eboy')
    end
  end, 'getCargoContainers')
end

-- isTutorialActive: returns true when linear tutorial is actively in progress
-- (step > 0, not done, not skipped). Used by Vue-side contextual tutorial gates.
-- setSubStep / advanceSubStep: called by Vue to advance sub-steps within step 4
M.setSubStep = function(id)
  if not tutorialData then return end
  tutorialData.tutorialSubStep = id or ''
  saveTutorialData()
  broadcastStepState()
  log('I', logTag, 'setSubStep("' .. tostring(id) .. '") -- step=' .. tostring(tutorialData.currentStep))
end

M.advanceSubStep = function()
  if not tutorialData then return end
  local currentId = tutorialData.tutorialSubStep or ''
  -- Check if in retrieve branch
  local rIdx = RETRIEVE_SUBSTEP_INDEX[currentId]
  if rIdx then
    if rIdx < #RETRIEVE_SUBSTEPS then
      M.setSubStep(RETRIEVE_SUBSTEPS[rIdx + 1])
    else
      -- Retrieve complete, return to normal flow
      M.setSubStep('click_ie')
    end
    return
  end
  -- Normal STEP4 advance
  local idx = STEP4_SUBSTEP_INDEX[currentId]
  if idx and idx < #STEP4_SUBSTEPS then
    M.setSubStep(STEP4_SUBSTEPS[idx + 1])
  else
    log('I', logTag, 'advanceSubStep: no next for "' .. tostring(currentId) .. '"')
  end
end

M.getSubStep = function()
  return tutorialData and tutorialData.tutorialSubStep or ''
end

M.isTutorialActive           = function()
  if spotlightsPaused then return false end
  return tutorialData ~= nil
    and not tutorialData.tutorialDone
    and not tutorialData.tutorialSkipped
    and tutorialData.currentStep > 0
end
M.isTutorialDone             = function() return tutorialData ~= nil and tutorialData.tutorialDone == true end
M.isPhoneBlocked             = isPhoneBlocked
M.getCurrentStep             = function() return tutorialData and tutorialData.currentStep or 0 end
M.confirmSkip                = confirmSkip
M.skipCurrentStep            = skipCurrentStep
M.resetVehicle               = resetVehicle

M.hasShownContextualTutorial = function(id)
  return tutorialData ~= nil and tutorialData.shownContextualTutorials[id] == true
end
M.markContextualTutorialShown = function(id)
  if tutorialData then
    tutorialData.shownContextualTutorials[id] = true
    saveTutorialData()
  end
end

M.disableAllContextualTutorials = function()
  if tutorialData then
    tutorialData.contextualTutorialsDisabled = true
    saveTutorialData()
  end
end

M.enableContextualTutorials = function()
  if tutorialData then
    tutorialData.contextualTutorialsDisabled = false
    saveTutorialData()
  end
end

M.areContextualTutorialsDisabled = function()
  return tutorialData ~= nil and tutorialData.contextualTutorialsDisabled == true
end

M.resetContextualTutorials = function()
  if tutorialData then
    tutorialData.shownContextualTutorials = {}
    tutorialData.contextualTutorialsDisabled = false
    saveTutorialData()
    guihooks.trigger('BCMContextualTutorialsReset', {})
  end
end

M.hasActiveSave = function()
  return tutorialData ~= nil
end

-- Debug: pause/resume spotlight system without changing tutorial state
local spotlightsPaused = false
M.pauseSpotlights = function()
  spotlightsPaused = true
  guihooks.trigger('BCMClearSpotlight', {})
  log('I', logTag, 'Spotlights PAUSED (use bcm_tutorial.resumeSpotlights() to resume)')
end
M.resumeSpotlights = function()
  spotlightsPaused = false
  broadcastStepState()
  log('I', logTag, 'Spotlights RESUMED')
end
M.areSpotlightsPaused = function() return spotlightsPaused end

M.broadcastStepState = function()
  broadcastStepState()
end

M.debugDumpState = function() return tutorialData end

return M

