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
 extensions.unload("bcm_partsMetadata")
 extensions.unload("bcm_partsOrders")
end

-- Mod startup sequence
startup = function()
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

 -- Load parts system (sidecar metadata + orders + shop app)
 extensions.load("bcm_partsMetadata")
 extensions.load("bcm_partsOrders")
 extensions.load("bcm_partsShopApp")

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

 -- Load tutorial FSM (Phase 79: first-run tutorial skeleton, depends on banking, time, sleepManager)
 extensions.load("bcm_tutorial")


 -- Load dev tool (always available, activates only via bcm_devtool.start())
 extensions.load("bcm_devtool")

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
