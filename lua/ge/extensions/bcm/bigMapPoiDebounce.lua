-- Suppresses the redundant rawPois.clear() that vanilla bigMapPoiProvider fires
-- at lua/ge/extensions/freeroam/bigMapPoiProvider.lua:442 immediately after a
-- bigmap open. The first clear (from bigMapMode.enterBigMapActual) already
-- rebuilt the POI list; the second clear invalidates that fresh cache and
-- forces the whole hook — dominated by career_modules_delivery_general with
-- many active cargos — to run a second time, visible as a distinct stutter
-- ~150ms after the first one.
--
-- Any other caller to rawPois.clear() (cargo pickup, facility discovery, map
-- change, etc.) continues to invalidate the cache normally.

local M = {}
M.dependencies = {}

local logTag = "bcm_bigMapPoiDebounce"

local _origClear = nil
local _wrapped = false
local _suppressedCount = 0

local _firstCallLogged = false

local function wrap()
  if _wrapped then return end
  if not gameplay_rawPois or not gameplay_rawPois.clear then
    log('W', logTag, 'gameplay_rawPois not ready; will retry later')
    return
  end
  _origClear = gameplay_rawPois.clear
  gameplay_rawPois.clear = function(...)
    -- Inline the caller check so debug.getinfo(2) resolves to the real caller
    -- of rawPois.clear(), not to a helper function sitting between us.
    local info = debug.getinfo(2, "S")
    local src = info and info.source or ""
    if not _firstCallLogged then
      _firstCallLogged = true
      log('I', logTag, 'first rawPois.clear observed; caller source = ' .. tostring(src))
    end
    if src:find("bigMapPoiProvider", 1, true) then
      _suppressedCount = _suppressedCount + 1
      if _suppressedCount <= 3 or _suppressedCount % 50 == 0 then
        log('I', logTag, string.format('suppressed redundant clear from bigMapPoiProvider (count=%d)', _suppressedCount))
      end
      return
    end
    return _origClear(...)
  end
  _wrapped = true
  log('I', logTag, 'wrapped gameplay_rawPois.clear')
end

local function unwrap()
  if not _wrapped or not _origClear then return end
  gameplay_rawPois.clear = _origClear
  _origClear = nil
  _wrapped = false
  log('I', logTag, string.format('unwrapped gameplay_rawPois.clear (suppressed %d calls total)', _suppressedCount))
end

M.onExtensionLoaded = function()
  wrap()
end

M.onWorldReadyState = function(state)
  if not _wrapped then wrap() end
end

M.onExtensionUnloaded = function()
  unwrap()
end

return M
