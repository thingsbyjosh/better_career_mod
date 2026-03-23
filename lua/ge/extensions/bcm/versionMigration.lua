-- BCM Version Migration Framework
-- Provides centralized migration system for BCM module data across save format versions

local M = {}
local logTag = 'bcm_versionMigration'

-- Registry of module migrations
-- Key: module name (e.g., "economy", "missions")
-- Value: { currentVersion = N, migrations = { [fromVersion] = migrationFunction } }
local moduleRegistry = {}

-- Forward declarations
local registerModuleMigrations
local migrateModuleData
local getCurrentVersion
local setCurrentVersion
local getModuleRegistry
local readJsonFile

-- Read a JSON file safely
readJsonFile = function(filepath)
 local content = readFile(filepath, "auto")
 if not content then
 return nil
 end
 return jsonDecode(content)
end

-- Register a module's migration chain
-- @param moduleName string - Name of the module (e.g., "economy")
-- @param currentVersion number - Current version the module expects
-- @param migrations table - Map of {[fromVersion] = migrationFunction}
-- Example: {[1] = migrateV1toV2, [2] = migrateV2toV3}
registerModuleMigrations = function(moduleName, currentVersion, migrations)
 if not moduleName or not currentVersion then
 log("E", logTag, "registerModuleMigrations: moduleName and currentVersion are required")
 return
 end

 moduleRegistry[moduleName] = {
 currentVersion = currentVersion,
 migrations = migrations or {}
 }

 log("I", logTag, "Registered migrations for module: " .. moduleName .. " (v" .. currentVersion .. ")")
end

-- Migrate module data from old version to current version
-- @param moduleName string - Name of the module
-- @param data table - Module data to migrate (must have .version field)
-- @param savePath string - Path to save directory (for backup creation)
-- @return table - Migrated data (or original data if migration not needed/failed)
migrateModuleData = function(moduleName, data, savePath)
 if not moduleName or not data then
 log("W", logTag, "migrateModuleData: moduleName and data are required")
 return data
 end

 -- Look up module in registry
 local registry = moduleRegistry[moduleName]
 if not registry then
 log("D", logTag, "No migrations registered for module: " .. moduleName)
 return data
 end

 -- Get versions
 local dataVersion = data.version or 1
 local targetVersion = registry.currentVersion

 -- Check if migration needed
 if dataVersion >= targetVersion then
 log("D", logTag, moduleName .. " data already at target version v" .. targetVersion)
 return data
 end

 log("I", logTag, "Migrating " .. moduleName .. " data: v" .. dataVersion .. " -> v" .. targetVersion)

 -- Create backup before migrating
 local backupPath = savePath .. "/" .. moduleName .. ".json.v" .. dataVersion .. ".backup"
 if career_saveSystem and career_saveSystem.jsonWriteFileSafe then
 if career_saveSystem.jsonWriteFileSafe(backupPath, data, true) then
 log("I", logTag, "Created backup: " .. backupPath)
 else
 log("W", logTag, "Failed to create backup for " .. moduleName .. " at " .. backupPath)
 end
 else
 log("W", logTag, "career_saveSystem not available, skipping backup creation")
 end

 -- Chain migrations from dataVersion to targetVersion
 local migratedData = deepcopy(data)
 local originalData = deepcopy(data)

 for v = dataVersion, targetVersion - 1 do
 local migrationFn = registry.migrations[v]

 if migrationFn then
 log("I", logTag, "Applying migration step: v" .. v .. " -> v" .. (v + 1))

 -- Wrap migration in pcall for safety
 local success, result = pcall(migrationFn, migratedData)

 if success then
 migratedData = result
 migratedData.version = v + 1
 log("I", logTag, "Migration step successful: v" .. v .. " -> v" .. (v + 1))
 else
 -- Migration failed - attempt to restore from backup
 log("E", logTag, "Migration failed for " .. moduleName .. " at step v" .. v .. " -> v" .. (v + 1) .. ": " .. tostring(result))

 -- Try to read backup
 local backupData = readJsonFile(backupPath)

 if backupData then
 log("W", logTag, "Migration failed, restored from backup: " .. backupPath)
 guihooks.trigger("toastrMsg", {
 type = "warning",
 title = "Migration Warning",
 msg = "Failed to migrate " .. moduleName .. " data. Using backup (v" .. dataVersion .. ").",
 config = {time = 6000}
 })
 return backupData
 else
 -- Backup also failed - use original data from memory
 log("E", logTag, "CRITICAL: Migration failed AND backup unreadable for module: " .. moduleName)
 guihooks.trigger("toastrMsg", {
 type = "error",
 title = "Migration Error",
 msg = "Failed to migrate " .. moduleName .. " data. Using original data.",
 config = {time = 6000}
 })
 return originalData
 end
 end
 else
 log("D", logTag, "No migration function for v" .. v .. ", skipping")
 migratedData.version = v + 1
 end
 end

 -- All migrations completed successfully
 log("I", logTag, "Migration complete for " .. moduleName .. ": v" .. dataVersion .. " -> v" .. targetVersion)
 guihooks.trigger("toastrMsg", {
 type = "info",
 title = "Save Migrated",
 msg = moduleName .. " data updated to v" .. targetVersion,
 config = {time = 4000}
 })

 return migratedData
end

-- Get current version for a module
-- @param moduleName string - Name of the module
-- @return number - Current version, or 1 if not registered
getCurrentVersion = function(moduleName)
 local registry = moduleRegistry[moduleName]
 if registry then
 return registry.currentVersion
 end
 return 1
end

-- Set current version for a module (for testing/debugging)
-- @param moduleName string - Name of the module
-- @param version number - Version to set
setCurrentVersion = function(moduleName, version)
 if not moduleRegistry[moduleName] then
 moduleRegistry[moduleName] = {
 currentVersion = version,
 migrations = {}
 }
 else
 moduleRegistry[moduleName].currentVersion = version
 end
 log("I", logTag, "Set version for " .. moduleName .. ": v" .. version)
end

-- Get the entire module registry (for debugging)
-- @return table - The module registry
getModuleRegistry = function()
 return moduleRegistry
end

-- Export functions
M.registerModuleMigrations = registerModuleMigrations
M.migrateModuleData = migrateModuleData
M.getCurrentVersion = getCurrentVersion
M.setCurrentVersion = setCurrentVersion
M.getModuleRegistry = getModuleRegistry

return M
