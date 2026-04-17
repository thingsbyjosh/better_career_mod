local M = {}

local ourModName = "better_career_mod"
local ourModId = "bcm"

-- Forward declarations
local loadExtensions
local unloadAllExtensions
local startup
local onModActivated
local onModDeactivated

-- Force-replace vanilla career extensions that were loaded before our mod activated.
-- Uses forceReloadOverride to patch the existing M tables in-place, preserving
-- the extension registry references used by BeamNG's hook dispatch.
loadExtensions = function()
  if not bcm_overrideManager then
    log('E', 'bcm_extensionManager', 'overrideManager not available for force-reload')
    return
  end

  -- Force-reload extensions that are already loaded by BeamNG at startup with vanilla code
  bcm_overrideManager.forceReloadOverride("career_career")
  bcm_overrideManager.forceReloadOverride("career_saveSystem")
  bcm_overrideManager.forceReloadOverride("core_recoveryPrompt")

  -- Also reload freeroam_facilities if it's already loaded
  if _G["freeroam_facilities"] then
    bcm_overrideManager.forceReloadOverride("freeroam_facilities")
  end

  -- gameplay_police: no override needed — BCM uses vanilla pursuit logic
  -- bcm_police handles pool spawn, damage tracking, and escalation externally

  -- Force-reload painting if career is active (painting loaded with vanilla code at career start)
  if _G["career_modules_painting"] then
    bcm_overrideManager.forceReloadOverride("career_modules_painting")
  end

  log('I', 'bcm_extensionManager', 'Vanilla extensions replaced with BCM overrides')
end

-- Unloads all career-related extensions used by the mod.
-- This forces removal of career core, save system, and override manager.
unloadAllExtensions = function()
  extensions.unload("career_career")
  extensions.unload("career_saveSystem")
  extensions.unload("bcm_overrideManager")
  extensions.unload("bcm_settings")
  extensions.unload("bcm_phone")
  extensions.unload("bcm_timeSystem")
  extensions.unload("bcm_notifications")
  extensions.unload("bcm_transactionCategories")
  extensions.unload("bcm_banking")
  extensions.unload("bcm_creditScore")
  extensions.unload("bcm_loans")
  extensions.unload("bcm_loanApp")
  extensions.unload("bcm_sleepManager")
  extensions.unload("bcm_clockApp")
  extensions.unload("bcm_bankApp")
  extensions.unload("bcm_settingsApp")
  extensions.unload("bcm_calendarApp")
  extensions.unload("bcm_weatherApp")
  extensions.unload("bcm_weatherForecast")
  extensions.unload("bcm_weather")
  extensions.unload("bcm_identity")
  extensions.unload("bcm_contacts")
  extensions.unload("bcm_email")
  extensions.unload("bcm_breakingNews")
  extensions.unload("bcm_chat")
  extensions.unload("bcm_chatApp")
  extensions.unload("bcm_walletApp")
  extensions.unload("bcm_contactsApp")
  extensions.unload("bcm_planexApp")
  extensions.unload("bcm_planex")
  extensions.unload("bcm_virtualCargo")
  extensions.unload("bcm_contracts")
  extensions.unload("bcm_appRegistry")
  extensions.unload("bcm_realEstateApp")
  extensions.unload("bcm_rentals")
  extensions.unload("bcm_dynoApp")
  extensions.unload("bcm_vehicleGalleryApp")
  extensions.unload("bcm_paintApp")
  extensions.unload("bcm_negotiation")
  extensions.unload("bcm_defects")
  extensions.unload("bcm_dealershipApp")
  extensions.unload("bcm_marketplaceApp")
  extensions.unload("bcm_garageManagerApp")
  extensions.unload("bcm_garages")
  extensions.unload("bcm_properties")
  extensions.unload("bcm_police")
  extensions.unload("bcm_fines")
  extensions.unload("bcm_policeHud")
  extensions.unload("bcm_policeDamage")
  extensions.unload("bcm_heatApp")
  extensions.unload("bcm_heatSystem")
  extensions.unload("bcm_tutorial")
  extensions.unload("bcm_partsShopApp")
  extensions.unload("bcm_fixdProApp")
  extensions.unload("bcm_partsMetadata")
  extensions.unload("bcm_partsOrders")
  -- Map switch and transit journal modules
  extensions.unload("bcm_multimap")
  extensions.unload("bcm_transitJournal")
  -- Travel UI data enrichment bridge
  extensions.unload("bcm_multimapApp")
  -- Trailer re-coupling prototype
  extensions.unload("bcm_trailerCoupling")
end

-- Remove stale user-space level overrides that persist from World Editor saves.
-- When a player (or another mod) saves the map via World Editor, BeamNG writes
-- items.level.json to the user directory. This overrides mod files in the VFS because
-- user-space files take priority. Clearing these ensures BCM's prefabs/facilities load.
local function cleanUserLevelOverrides()
  local levelPaths = {
    '/levels/west_coast_usa/main/MissionGroup/items.level.json',
    '/levels/italy/main/MissionGroup/items.level.json',
  }
  local userPath = FS:getUserPath()
  if not userPath or userPath == '' then return end

  for _, vpath in ipairs(levelPaths) do
    if FS:fileExists(vpath) then
      local realPath = FS:getFileRealPath(vpath)
      if realPath and realPath ~= '' and string.startswith(realPath, userPath) then
        local backupPath = vpath .. '.bcm_backup'
        FS:renameFile(vpath, backupPath)
        log('W', 'bcm_extensionManager', 'Renamed stale user-space level override: ' .. vpath .. ' -> ' .. backupPath)
      end
    end
  end
end

-- Merge BCM level objects into vanilla items.level.json files.
-- Files named *additional.items.level.json are appended to the vanilla file
-- in the same directory. Reverted on mod deactivation.
local vanillaBackups = {}
local function mergeAdditionalLevelItems()
  local additionalFiles = FS:findFiles("/levels/", "*additional.items.level.json", -1, true, false)
  if not additionalFiles or #additionalFiles == 0 then return end

  local groups = {}
  for _, addPath in ipairs(additionalFiles) do
    local dir = addPath:match("(.*/)")
    local vanillaPath = dir .. "items.level.json"
    if not groups[vanillaPath] then
      groups[vanillaPath] = {}
    end
    table.insert(groups[vanillaPath], addPath)
  end

  for vanillaPath, addPaths in pairs(groups) do
    local vanillaFile = io.open(vanillaPath, "r")
    if vanillaFile then
      local originalContent = vanillaFile:read("*all")
      vanillaFile:close()

      -- Only backup once per session
      if not vanillaBackups[vanillaPath] then
        vanillaBackups[vanillaPath] = originalContent
      end

      local extra = {}
      for _, addPath in ipairs(addPaths) do
        local f = io.open(addPath, "r")
        if f then
          local content = f:read("*all")
          f:close()
          if content and #content > 0 then
            table.insert(extra, content)
          end
        end
      end

      if #extra > 0 then
        local outFile = io.open(vanillaPath, "w")
        if outFile then
          local merged = originalContent
          if not merged:match("\n$") then merged = merged .. "\n" end
          merged = merged .. table.concat(extra, "\n")
          outFile:write(merged)
          outFile:close()
          log('I', 'bcm_extensionManager', 'Merged ' .. #extra .. ' additional items into ' .. vanillaPath)
        end
      end
    end
  end
end

local function restoreVanillaLevelItems()
  for vanillaPath, originalContent in pairs(vanillaBackups) do
    local outFile = io.open(vanillaPath, "w")
    if outFile then
      outFile:write(originalContent)
      outFile:close()
    end
  end
  vanillaBackups = {}
end

-- Mod startup sequence
startup = function()
  cleanUserLevelOverrides()
  mergeAdditionalLevelItems()

  -- Load override manager first (installs package.preload hooks)
  setExtensionUnloadMode("bcm_overrideManager", "manual")
  extensions.load("bcm_overrideManager")

  -- Only unload vanilla if NOT already in career mode
  -- (Prevents breaking active career on mod reload)
  if not core_gamestate.state or core_gamestate.state.state ~= "career" then
    loadExtensions()
  end

  -- Note: loadManualUnloadExtensions() is NOT called here — it was already called
  -- in modScript.lua and bcm_overrideManager is loaded explicitly above.
  -- Calling it again would cause "Failed to set unload mode" errors.

  -- Load global settings BEFORE time/weather so modules receive settings on activation
  extensions.load("bcm_settings")

  -- Load time system (foundation for all v1.3 features)
  extensions.load("bcm_timeSystem")

  -- Load phone extensions
  extensions.load("bcm_phone")

  -- Load notification extension
  extensions.load("bcm_notifications")

  -- Load app registry extension
  extensions.load("bcm_appRegistry")

  -- Load identity module (must load before banking so name is available)
  extensions.load("bcm_identity")

  -- Load contacts module (must load before banking; provides contact IDs for email/chat)
  extensions.load("bcm_contacts")

  -- Load email module (depends on contacts for sender resolution, identity for player name)
  extensions.load("bcm_email")

  -- Load chat module (depends on contacts for contact resolution, identity for player name)
  extensions.load("bcm_chat")

  -- Load banking modules in dependency order
  extensions.load("bcm_transactionCategories")
  extensions.load("bcm_banking")

  -- Load credit score engine (depends on banking for income events)
  extensions.load("bcm_creditScore")

  -- Load loan system (depends on banking + creditScore)
  extensions.load("bcm_loans")
  extensions.load("bcm_loanApp")

  -- Load sleep manager (depends on timeSystem + loans)
  extensions.load("bcm_sleepManager")

  -- Load weather system (depends on timeSystem)
  extensions.load("bcm_weather")
  extensions.load("bcm_weatherForecast")
  extensions.load("bcm_weatherApp")

  -- Load breaking news engine (event-driven FBT articles — Phase 30)
  extensions.load("bcm_breakingNews")

  -- Load property system (must load before garages feature layer)
  extensions.load("bcm_properties")
  extensions.load("bcm_garages")

  -- Load parts system (sidecar metadata + orders + shop app + installer app)
  extensions.load("bcm_partsMetadata")
  extensions.load("bcm_partsOrders")
  extensions.load("bcm_partsShopApp")
  extensions.load("bcm_fixdProApp")

  -- Load garage manager app (depends on garages + properties + banking)
  extensions.load("bcm_garageManagerApp")

  -- Load paint app (depends on garages + properties + banking)
  extensions.load("bcm_paintApp")

  -- Load dyno app (depends on garages + properties)
  extensions.load("bcm_dynoApp")

  -- Load vehicle gallery app (depends on garages + properties + dyno)
  extensions.load("bcm_vehicleGalleryApp")

  -- Load real estate app (depends on garages + properties + banking)
  extensions.load("bcm_realEstateApp")

  -- Load rentals module (depends on properties + banking + timeSystem + garages + multimapApp)
  extensions.load("bcm_rentals")

  -- Load marketplace app (depends on timeSystem + career marketplace module)
  extensions.load("bcm_marketplaceApp")

  -- Load dealership app (depends on marketplace pipeline + garages)
  extensions.load("bcm_dealershipApp")

  -- Load negotiation extension (depends on marketplace + marketplaceApp)
  extensions.load("bcm_negotiation")

  -- Load defects extension (Phase 52: test drive discovery, inspector NPC, post-purchase reveal)
  extensions.load("bcm_defects")

  -- Load police orchestrator (Phase 54: pursuit hooks, stuck detection, debug commands)
  extensions.load("bcm_police")

  -- Load heat system (Phase 55: persistent heat accumulator, depends on police events)
  extensions.load("bcm_heatSystem")
  extensions.load("bcm_heatApp")

  -- Load fine system (Phase 56: fine formula, ledger, bank debit, depends on police + banking)
  extensions.load("bcm_fines")

  -- Load police HUD streaming (Phase 57: pursuit overlay data feed)
  extensions.load("bcm_policeHud")

  -- Load vanilla gameplay_police explicitly: playerDriving sets policeAmount=0
  -- so gameplay_traffic never loads gameplay_police as a dependency.
  -- We must load it so vanilla pursuit logic (setPursuitMode, arrest/evade) is available.
  extensions.load("gameplay_police")

  -- Load police damage tracking (Phase 59.1: damage cost + anonymous benefactor)
  extensions.load("bcm_policeDamage")

  -- Load contract pool (Phase 64: trucking contract data layer, depends on timeSystem)
  extensions.load("bcm_contracts")

  -- Load virtual cargo system (POC: inject cargo capacity into vehicles without native jbeam cargo)
  extensions.load("bcm_virtualCargo")

  -- Load PlanEx dispatch (Phase 73: pack-based delivery system, depends on timeSystem + contracts patterns)
  extensions.load("bcm_planex")

  -- Load PlanEx app bridge (Phase 75: Vue-to-Lua bridge for PlanEx IE site)
  extensions.load("bcm_planexApp")

  -- Load multi-map system (Phase 97: travel graph, triggers, transit journal; depends on banking, planex, heatSystem)
  -- MUST survive level switches — manual unload mode prevents BeamNG from unloading on startFreeroam
  extensions.load("bcm_multimap")
  setExtensionUnloadMode("bcm_multimap", "manual")
  extensions.load("bcm_transitJournal")
  setExtensionUnloadMode("bcm_transitJournal", "manual")

  -- Travel UI data enrichment bridge (depends on multimap + banking + garages)
  extensions.load("bcm_multimapApp")
  setExtensionUnloadMode("bcm_multimapApp", "manual")

  -- Trailer re-coupling prototype (must survive level switches)
  extensions.load("bcm_trailerCoupling")
  setExtensionUnloadMode("bcm_trailerCoupling", "manual")

  -- Load tutorial FSM (Phase 79: first-run tutorial skeleton, depends on banking, time, sleepManager)
  extensions.load("bcm_tutorial")


  -- Load dev tool (always available, activates only via bcm_devtool.start())
  extensions.load("bcm_devtool")

  -- Load dev tool v2 (parallel rework, activates via bcm_devtoolV2.start())
  extensions.load("bcm_devtoolV2")

  -- Load dev tool v2 wipCore (generic WIP model shared by all v2 modules)
  extensions.load("bcm_devtoolV2_wipCore")

  -- Load dev tool v2 garages module
  extensions.load("bcm_devtoolV2_garages")

  -- Load dev tool v2 kind modules
  extensions.load("bcm_devtoolV2_delivery")
  extensions.load("bcm_devtoolV2_travel")
  extensions.load("bcm_devtoolV2_cameras")
  extensions.load("bcm_devtoolV2_radar")
  extensions.load("bcm_devtoolV2_gas")

  -- Load phone apps
  extensions.load("bcm_clockApp")
  extensions.load("bcm_bankApp")
  extensions.load("bcm_settingsApp")
  extensions.load("bcm_calendarApp")
  extensions.load("bcm_walletApp")
  extensions.load("bcm_contactsApp")
  extensions.load("bcm_chatApp")

  log('I', 'bcm_extensionManager', 'Better Career Mod initialized')
end

-- Detect mod activation - store our mod identity
onModActivated = function(modData)
  if ourModName or ourModId then
    return
  end

  if not modData or not modData.modname then
    return
  end

  -- Ignore batch activation/deactivation events
  if modData.modname and (modData.modname:find("BatchActivation_") or modData.modname:find("BatchDeactivation_")) then
    return
  end

  -- Store our mod identity on first activation
  if not ourModName then
    ourModName = modData.modname
    if modData.modData and modData.modData.tagid then
      ourModId = modData.modData.tagid
    end
    return true
  end
end

-- Detect mod deactivation - cleanup when OUR mod is deactivated
onModDeactivated = function(modData)
  if not modData or not modData.modname then
    return
  end

  -- Ignore batch activation/deactivation events
  if modData.modname and (modData.modname:find("BatchActivation_") or modData.modname:find("BatchDeactivation_")) then
    return
  end

  -- Check if OUR mod is being deactivated
  if (ourModName and modData.modname == ourModName) or
     (ourModId and modData.modData and modData.modData.tagid == ourModId) then
    -- Force close phone and clear app registry
    guihooks.trigger('BCMPhoneToggle', { action = 'close' })
    if bcm_appRegistry then
      bcm_appRegistry.clearAll()
    end

    restoreVanillaLevelItems()
    unloadAllExtensions()
    loadManualUnloadExtensions()
  end
end

-- Public API
M.getModData = function()
  return {
    name = ourModName,
    id = ourModId
  }
end

-- Lifecycle hooks
M.onExtensionLoaded = startup
M.onModActivated = onModActivated
M.onModDeactivated = onModDeactivated

return M

