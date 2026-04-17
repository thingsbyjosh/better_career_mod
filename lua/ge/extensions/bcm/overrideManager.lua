local M = {}

local logTag = 'bcm_overrideManager'

-- Private state
local overrides = {}
local originalLoad = nil
local originalReload = nil
local ourMod = nil

-- Forward declarations
local convertFormat
local setOverride
local clearOverride
local overrideLoad
local overrideReload
local forceReloadOverride
local installSystem
local unloadOverrides

-- Convert between career_career (underscore) and career/career (slash) formats
-- BeamNG uses both formats interchangeably
convertFormat = function(path)
  if path:find('_') and not path:find('/') then
    return path:gsub('_', '/')  -- career_career -> career/career
  else
    return path:gsub('/', '_')  -- career/career -> career_career
  end
end

-- Register a package.preload override
-- Maps originalPath to overridePath, handling both underscore and slash formats
setOverride = function(originalPath, overridePath)
  if not originalPath or not overridePath then
    return false
  end

  local convertedPath = convertFormat(originalPath)

  -- Store original preload function (for cleanup)
  local originalPreload = package.preload[convertedPath]

  -- Create override entry
  local entry = {
    override = overridePath,
    originalFormat = originalPath,
    convertedFormat = convertedPath,
    originalPreload = originalPreload
  }

  -- Register override in both formats
  overrides[originalPath] = entry
  overrides[convertedPath] = entry

  -- Clear any cached module so require() will use our preload instead of the cached vanilla version
  package.loaded[convertedPath] = nil
  local absolutePath = '/lua/ge/extensions/' .. convertedPath
  package.loaded[absolutePath] = nil

  -- Replace package.preload entry with override loader
  package.preload[convertedPath] = function(...)
    -- Guard: Only load career modules when career is active
    -- Prevents career modules from loading in freeroam mode
    -- convertedPath is in slash format (career/modules/...) so match that
    if convertedPath:find('career/modules/') and (not career_career or not career_career.isActive()) then
      return nil
    end

    -- Use pcall for graceful failure
    local success, result = pcall(require, overridePath)

    if not success then
      log('E', logTag, 'Failed to load override: ' .. overridePath .. ' - ' .. tostring(result))
      return nil
    end

    return result
  end

  -- Also set absolute path version
  -- Some BeamNG code uses absolute paths like /lua/ge/extensions/career/career
  package.preload[absolutePath] = package.preload[convertedPath]

  return true
end

-- Remove a specific override and restore original preload
clearOverride = function(originalPath)
  local entry = overrides[originalPath]
  if not entry then
    return false
  end

  -- Clear both format entries
  overrides[entry.originalFormat] = nil
  overrides[entry.convertedFormat] = nil

  -- Restore original preload if it existed
  if entry.originalPreload then
    package.preload[entry.convertedFormat] = entry.originalPreload
  else
    package.preload[entry.convertedFormat] = nil
  end

  -- Clear absolute path preload
  local absolutePath = '/lua/ge/extensions/' .. entry.convertedFormat
  package.preload[absolutePath] = nil

  log('I', logTag, 'Cleared override for: ' .. originalPath)
  return true
end

-- Replacement for extensions.load() — substitutes override paths
-- When an override is registered for an extension, the override file path
-- is passed to the original load instead of the vanilla path.
overrideLoad = function(...)
  local args = {...}
  local modifiedArgs = {}
  local substitutions = {}  -- track original -> override name for global aliasing

  for _, arg in ipairs(args) do
    if type(arg) == 'string' then
      -- Guard career MODULE paths when career not active (not career_career itself)
      if arg:find('career_modules_') == 1 and (not career_career or not career_career.isActive()) then
        -- Skip loading career modules when career not active
      else
        -- Substitute with override path if one exists
        local entry = overrides[arg]
        if entry then
          table.insert(modifiedArgs, entry.override)
          table.insert(substitutions, {original = arg, override = entry.override})
        else
          table.insert(modifiedArgs, arg)
        end
      end
    else
      table.insert(modifiedArgs, arg)
    end
  end

  local result = originalLoad(unpack(modifiedArgs))

  -- Ensure the original global name points to the loaded override module.
  -- extensions.load registers the module under the PASSED name (override path),
  -- but the UI bridge and other Lua code reference the ORIGINAL name (e.g.
  -- career_modules_vehicleShopping). Without this alias, the global would be nil
  -- or point to the vanilla module.
  for _, sub in ipairs(substitutions) do
    if not _G[sub.original] then
      local overrideGlobalName = sub.override:gsub('%.', '_')
      local loadedModule = _G[overrideGlobalName]
      if loadedModule then
        rawset(_G, sub.original, loadedModule)
        log('I', logTag, 'Aliased global: ' .. sub.original .. ' -> ' .. overrideGlobalName)
      end
    end
  end

  return result
end

-- Replacement for extensions.reload() — substitutes override paths
overrideReload = function(extPath)
  -- Guard career MODULE paths when career not active
  if extPath:find('career_modules_') == 1 and (not career_career or not career_career.isActive()) then
    return false
  end

  -- Substitute with override path if one exists
  local entry = overrides[extPath]
  if entry then
    return originalReload(entry.override)
  end
  return originalReload(extPath)
end

-- Force-reload a specific override by patching the existing M table in-place.
-- This is needed for extensions already loaded before our mod activates (e.g., career_career).
-- We load the override file directly (not through extensions.load) and copy all keys
-- from the override M table into the vanilla M table that's already in the extension registry.
-- This preserves the table reference used by BeamNG's hook dispatch system.
local function forceReloadOverride(extensionName)
  local entry = overrides[extensionName]
  if not entry then
    log('W', logTag, 'No override registered for: ' .. extensionName)
    return false
  end

  -- Get the existing M table from the extension registry (used by hook dispatch)
  local existingM = extensions[extensionName]

  -- Load the override file directly using loadfile
  local overrideFile = '/' .. entry.override:gsub('%.', '/') .. '.lua'
  local chunk, loadErr = loadfile(overrideFile)
  if not chunk then
    log('E', logTag, 'Failed to load override file: ' .. overrideFile .. ' - ' .. tostring(loadErr))
    return false
  end

  local ok, overrideM = pcall(chunk)
  if not ok or type(overrideM) ~= 'table' then
    log('E', logTag, 'Error executing override: ' .. overrideFile .. ' - ' .. tostring(overrideM))
    return false
  end

  if existingM and type(existingM) == 'table' then
    -- Preserve internal BeamNG metadata fields before wiping
    local preserved = {}
    for k, v in pairs(existingM) do
      if type(k) == 'string' and k:sub(1, 2) == '__' and k:sub(-2) == '__' then
        preserved[k] = v
      end
    end

    -- Patch the existing M table in-place: remove old keys, copy override keys
    -- This preserves the table reference in the extension registry and hook dispatch
    for k in pairs(existingM) do
      existingM[k] = nil
    end
    for k, v in pairs(overrideM) do
      existingM[k] = v
    end

    -- Restore internal BeamNG metadata (e.g. __extensionName__, __virtual__)
    for k, v in pairs(preserved) do
      if existingM[k] == nil then
        existingM[k] = v
      end
    end
    -- Ensure the global points to the patched registry table (not overrideM)
    rawset(_G, extensionName, existingM)
    log('I', logTag, 'Patched extension in-place: ' .. extensionName)
  else
    -- No existing M table in registry — just set the global
    -- The override file's rawset already did this, but be explicit
    rawset(_G, extensionName, overrideM)
    log('W', logTag, 'No registry entry for ' .. extensionName .. ', set global only')
  end

  return true
end

-- Install the override system: hijack extensions.load/reload and scan /overrides/ directory
installSystem = function()
  -- Guard against double-install
  if originalLoad or originalReload then
    log('E', logTag, 'Override system already installed')
    return false
  end

  -- Store original functions
  originalLoad = extensions.load
  if originalLoad then
    extensions.load = overrideLoad
  end

  originalReload = extensions.reload
  if originalReload then
    extensions.reload = overrideReload
  end

  -- Scan /overrides/ directory for override files
  local overridesDir = '/lua/ge/extensions/overrides/'
  local luaFiles = FS:findFiles(overridesDir, '*.lua', -1, true, false)

  local overrideCount = 0
  if luaFiles and #luaFiles > 0 then
    for _, overrideFile in ipairs(luaFiles) do
      -- Convert file path to module path (dot notation for require)
      -- /lua/ge/extensions/overrides/career/career.lua -> lua.ge.extensions.overrides.career.career
      local modulePath = overrideFile:gsub('^/lua/ge/extensions/', 'lua.ge.extensions.')
                                      :gsub('%.lua$', '')
                                      :gsub('/', '.')

      -- Extract original extension path (remove 'overrides' segment)
      -- lua.ge.extensions.overrides.career.career -> lua.ge.extensions.career.career
      local originalPath = modulePath:gsub('%.overrides%.', '.')

      -- Convert to extension name format (underscore notation)
      -- lua.ge.extensions.career.career -> career_career
      local extensionPath = originalPath:gsub('lua%.ge%.extensions%.', ''):gsub('%.', '_')

      if setOverride(extensionPath, modulePath) then
        overrideCount = overrideCount + 1
        log('I', logTag, 'Registered override: ' .. extensionPath .. ' -> ' .. modulePath)
      end
    end
  end

  log('I', logTag, 'Installed override system with ' .. overrideCount .. ' overrides')
  return true
end

-- Clean shutdown: restore original functions and clear all overrides
unloadOverrides = function()
  if not originalLoad then
    return false
  end

  -- Restore original extension functions
  extensions.load = originalLoad
  originalLoad = nil

  extensions.reload = originalReload
  originalReload = nil

  -- Clear all overrides
  local pathsToClear = {}
  for path, _ in pairs(overrides) do
    table.insert(pathsToClear, path)
  end

  for _, path in ipairs(pathsToClear) do
    clearOverride(path)
  end

  log('I', logTag, 'Unloaded override system')
  return true
end

-- Lifecycle hooks

local function onExtensionLoaded()
  -- Get mod data from extension manager
  ourMod = bcm_extensionManager.getModData()

  -- Install override system
  installSystem()
end

local function onModDeactivated(modData)
  if not ourMod then
    return
  end

  -- Check if OUR mod is being deactivated
  if (ourMod.name and modData.modname == ourMod.name) or
     (ourMod.id and modData.modData and modData.modData.tagid == ourMod.id) then
    log('I', logTag, 'BCM deactivated, unloading overrides')
    unloadOverrides()
  end
end

-- Export module table
M.onExtensionLoaded = onExtensionLoaded
M.onModDeactivated = onModDeactivated
M.forceReloadOverride = forceReloadOverride

return M
