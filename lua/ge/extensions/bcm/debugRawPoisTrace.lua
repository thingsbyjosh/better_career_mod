-- TEMPORARY INSTRUMENTATION — DO NOT COMMIT.
-- Investigates bigmap-open visual stutter in career mode.
-- Wraps gameplay_rawPois.getRawPoiListByLevel to measure:
--   * total rebuild time
--   * per-extension time (ms)
--   * per-extension POI contribution count (how many POIs each one added)
-- This is the v2 instrumentation — v1 measured only time. v2 adds the count
-- to detect extensions adding too many POIs (e.g. facilities the user has set
-- to invisible still showing up).
--
-- Remove after stutter investigation.

local M = {}
M.dependencies = {}

local logTag = "bcm_debugRawPoisTrace"

local _origGetList = nil
local _wrapped = false

local KNOWN_RESPONDERS = {
  "freeroam_facilities",
  "freeroam_gasStations",
  "bcm_multimap",
  "career_modules_delivery_general",
  "career_modules_delivery_generator",
  "career_modules_inspectVehicle",
  "career_modules_inventory",
  "career_modules_testDrive",
  "core_levels",
  "gameplay_crawl_general",
  "gameplay_drag_general",
  "gameplay_drift_freeroam_driftSpots",
  "gameplay_missions_missions",
  "gameplay_missions_poiTest",
}

local function instrumentOnce(perCallMs, perCallCount)
  local restore = {}
  for _, name in ipairs(KNOWN_RESPONDERS) do
    local ext = rawget(_G, name)
    if ext and type(ext.onGetRawPoiListForLevel) == "function" then
      local orig = ext.onGetRawPoiListForLevel
      ext.onGetRawPoiListForLevel = function(levelIdentifier, elements)
        local before = elements and #elements or 0
        local t = hptimer()
        orig(levelIdentifier, elements)
        perCallMs[name] = (perCallMs[name] or 0) + t:stop()
        local after = elements and #elements or 0
        perCallCount[name] = (perCallCount[name] or 0) + (after - before)
      end
      table.insert(restore, { ext = ext, orig = orig })
    end
  end
  return restore
end

local function restoreResponders(restoreList)
  for _, entry in ipairs(restoreList) do
    entry.ext.onGetRawPoiListForLevel = entry.orig
  end
end

local function wrapGetList()
  if _wrapped then return end
  if not gameplay_rawPois or not gameplay_rawPois.getRawPoiListByLevel then return end
  _origGetList = gameplay_rawPois.getRawPoiListByLevel
  gameplay_rawPois.getRawPoiListByLevel = function(level)
    local perCallMs = {}
    local perCallCount = {}
    local restoreList = instrumentOnce(perCallMs, perCallCount)
    local t = hptimer()
    local a, b = _origGetList(level)
    local totalMs = t:stop()
    restoreResponders(restoreList)

    if next(perCallMs) then
      -- Build combined entries sorted by ms desc.
      local entries = {}
      for name, ms in pairs(perCallMs) do
        table.insert(entries, { name = name, ms = ms, count = perCallCount[name] or 0 })
      end
      table.sort(entries, function(x, y) return x.ms > y.ms end)

      local parts = {}
      local totalPois = 0
      for _, e in ipairs(entries) do
        table.insert(parts, string.format("%s=%.2fms/%d", e.name, e.ms, e.count))
        totalPois = totalPois + e.count
      end
      log('I', logTag, string.format('getRawPoiListByLevel(%s) TOTAL=%.2fms pois=%d | %s',
        tostring(level), totalMs, totalPois, table.concat(parts, " | ")))
    end
    return a, b
  end
  _wrapped = true
  log('I', logTag, 'wrapped getRawPoiListByLevel')
end

local function unwrapGetList()
  if not _wrapped or not _origGetList then return end
  gameplay_rawPois.getRawPoiListByLevel = _origGetList
  _origGetList = nil
  _wrapped = false
end

M.onExtensionLoaded = function()
  wrapGetList()
end

M.onWorldReadyState = function(state)
  if not _wrapped then wrapGetList() end
end

M.onExtensionUnloaded = function()
  unwrapGetList()
end

return M
