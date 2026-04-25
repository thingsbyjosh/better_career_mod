-- BCM Props Remover — applies blacklist of vanilla object removals per map
--
-- Extension name: bcm_propsRemover
-- Path: bcm/propsRemover.lua (BeamNG splits on first underscore: bcm_propsRemover → bcm/propsRemover.lua)
--
-- Reads /levels/<map>/main/MissionGroup/BCM_AREAS/bcm_props/removed_vanilla.json
-- and removes matching scene objects (TSStatic, Prefab, PrefabInstance, Forest)
-- after map load. Transient — applied on every map load.

local M = {}

local logTag = 'bcm_propsRemover'

local REMOVABLE_CLASSES = {
  "TSStatic",
  "Prefab",
  "PrefabInstance",
  "Forest",
  -- Additional classes that may appear in vanilla maps:
  "ForestItemData",
  "StaticShape",
  "TSStaticObject",
}

local appliedForLevel = nil  -- flag to prevent double-apply when both hooks fire

local applyBlacklist
local matchObject
local detectLevelName
local resetFlag

-- ============================================================================
-- Implementation
-- ============================================================================

detectLevelName = function()
  if not getMissionFilename then return nil end
  local mission = getMissionFilename()  -- e.g. "/levels/west_coast_usa/main.level.json"
  if not mission or mission == "" then return nil end
  local lvl = mission:match("/levels/([^/]+)/")
  return lvl
end

-- Match a blacklist entry to an actual scene object across REMOVABLE_CLASSES.
-- Returns the object or nil. Back-compat: entries without `className` default
-- to scanning every class (legacy blacklists were TSStatic-only).
matchObject = function(entry)
  -- Strategy 1: persistentId
  if entry.persistentId and entry.persistentId ~= "" then
    for _, className in ipairs(REMOVABLE_CLASSES) do
      local objs = scenetree.findClassObjects(className) or {}
      for _, name in ipairs(objs) do
        local o = scenetree.findObject(name)
        if o then
          local pid = nil
          pcall(function() pid = o:getField("persistentId") end)
          if not pid or pid == "" then pcall(function() pid = o.persistentId end) end
          if pid == entry.persistentId then
            return o
          end
        end
      end
    end
  end
  -- Strategy 2: name (must also be one of the removable classes)
  if entry.name and entry.name ~= "" then
    local o = scenetree.findObject(entry.name)
    if o then
      local cls = o.getClassName and o:getClassName() or nil
      for _, wanted in ipairs(REMOVABLE_CLASSES) do
        if cls == wanted then return o end
      end
    end
  end
  -- Strategy 3: shapeName + lastKnownPosition (0.5m tolerance).
  -- Only applicable to classes that expose shapeName (TSStatic and Forest
  -- items in practice). For Prefab/PrefabInstance the match falls through.
  if entry.shapeName and entry.lastKnownPosition then
    local targetPos = vec3(entry.lastKnownPosition[1], entry.lastKnownPosition[2], entry.lastKnownPosition[3])
    local classesToCheck = entry.className and {entry.className} or REMOVABLE_CLASSES
    for _, className in ipairs(classesToCheck) do
      local objs = scenetree.findClassObjects(className) or {}
      for _, name in ipairs(objs) do
        local o = scenetree.findObject(name)
        if o and o.shapeName == entry.shapeName then
          local p = o:getPosition()
          if p and (vec3(p) - targetPos):length() < 0.5 then
            return o
          end
        end
      end
    end
  end
  return nil
end

applyBlacklist = function()
  local levelName = detectLevelName()
  if not levelName then
    log('D', logTag, 'applyBlacklist: no level detected, skip')
    return
  end

  if appliedForLevel == levelName then
    log('D', logTag, 'applyBlacklist: already applied for ' .. levelName)
    return
  end

  local path = "/levels/" .. levelName .. "/main/MissionGroup/BCM_AREAS/bcm_props/removed_vanilla.json"
  if not FS:fileExists(path) then
    log('I', logTag, 'No removals for ' .. levelName)
    appliedForLevel = levelName
    return
  end

  local raw = readFile(path)
  if not raw or raw == "" then
    appliedForLevel = levelName
    return
  end

  local ok, entries = pcall(jsonDecode, raw)
  if not ok or type(entries) ~= "table" then
    log('W', logTag, 'Failed to parse ' .. path)
    appliedForLevel = levelName
    return
  end

  local success = 0
  for _, entry in ipairs(entries) do
    local obj = matchObject(entry)
    if obj then
      -- Class-aware removal: TSStatic and Forest delete cleanly. Prefab /
      -- PrefabInstance can explode on hard delete during gameplay (their
      -- children are wired into the MissionGroup tree), so hide + disable
      -- collision is the safer, reversible path.
      local cls = (obj.getClassName and obj:getClassName()) or "TSStatic"
      local delOk
      if cls == "TSStatic" or cls == "Forest" then
        delOk = pcall(function() obj:delete() end)
      else
        delOk = pcall(function()
          obj.hidden = true
          if obj.collidable ~= nil then obj.collidable = false end
        end)
      end
      if delOk then
        success = success + 1
      else
        log('W', logTag, 'Remove failed for entry [' .. tostring(cls)
          .. '] persistentId=' .. tostring(entry.persistentId))
      end
    else
      log('W', logTag, 'No match for blacklist entry: ' .. jsonEncode(entry))
    end
  end

  log('I', logTag, string.format('Applied %d/%d removals for %s', success, #entries, levelName))
  appliedForLevel = levelName
end

resetFlag = function()
  appliedForLevel = nil
end

-- ============================================================================
-- Hooks
-- ============================================================================

M.onClientPostStartMission = applyBlacklist
M.onWorldReadyState = function(state)
  if state == 2 then applyBlacklist() end  -- WORLD_READY state in BeamNG
end
M.onClientStartMission = resetFlag

return M
