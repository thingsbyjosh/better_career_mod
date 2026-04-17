-- BCM Devtool V2 — WIP Core
-- Generic baseline/edited/deleted model shared by all devtool modules (garages,
-- delivery, travel, cameras, radar, gas). Handles persistence, drift detection,
-- atomic export, ID generation, undo stack, and snapshots.
--
-- Extension name: bcm_devtoolV2_wipCore
-- Path: bcm/devtoolV2/wipCore.lua

local M = {}

local logTag = 'bcm_devtoolV2_wipCore'

-- ============================================================================
-- Forward declarations (ALL local functions declared before any function body)
-- ============================================================================
local setWipPath
local setSnapshotDir
local registerKind
local createNew
local cloneFromProduction
local cloneFromVanilla
local updateField
local replaceItem
local delete
local get
local list
local listIds
local hydrateAll
local rehydrateKind
local saveWip
local loadWip
local checkDrift
local checkAllDrift
local buildExportPlan
local executeExport
local resolveConflict
local resolveAllConflicts
local undo
local redo
local clearUndoStack
local getUndoDepth
local saveSnapshot
local listSnapshots
local restoreSnapshot
local generateId
local onChange
-- internal helpers (added in later tasks)
local deepCopy
local deepEquals
local applyFieldPath
local pushUndoOp
local notifyObservers
-- filesystem helpers
local ensureBcmAreasParent

-- ============================================================================
-- State
-- ============================================================================

local wipPath = nil
local snapshotDir = nil
local schemas = {}     -- [kindName] = schema table
local state = {        -- matches bcm_devtool_wip_v2.json structure (spec §5)
  version = 2,
  schemaLevel = nil,
  kinds = {},          -- [kindName] = { items = {[id] = {baseline, edited, origin, touchedAt, conflicted}}, deleted = {} }
  lastExport = nil,
}

local undoStack = {}   -- capacity 50
local redoStack = {}
local UNDO_CAPACITY = 50

local observers = {}   -- list of fn()

-- ============================================================================
-- Filesystem helpers (local copies of the orchestrator's helpers — wipCore
-- doesn't have access to devtoolV2.lua's locals, so we duplicate the small
-- routines rather than plumb them through setters)
-- ============================================================================

local MOD_MOUNT = "/mods/unpacked/better_career_mod"

local function getModLevelsPath(levelName)
  return MOD_MOUNT .. "/levels/" .. levelName
end

local function ensureModDir(dirPath)
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath, true)
  end
end

local function writeJsonToMod(modRelativePath, data)
  local dir = modRelativePath:match("^(.*)/[^/]+$")
  if dir then ensureModDir(dir) end
  jsonWriteFile(modRelativePath, data, true)
end

local function writeNdjsonToMod(modRelativePath, objects)
  local dir = modRelativePath:match("^(.*)/[^/]+$")
  if dir then ensureModDir(dir) end
  local lines = {}
  for _, obj in ipairs(objects) do
    table.insert(lines, jsonEncode(obj))
  end
  local content = table.concat(lines, "\n")
  local f = io.open(modRelativePath, "w")
  if f then
    f:write(content .. "\n")
    f:close()
    return true
  end
  log('E', logTag, 'Failed to write NDJSON: ' .. modRelativePath)
  return false
end

local function readNdjsonFile(path)
  local file = io.open(path, "r")
  if not file then return {} end
  local objects = {}
  for line in file:lines() do
    line = line:match("^%s*(.-)%s*$")
    if line and line ~= "" then
      local obj = jsonDecode(line)
      if obj then
        table.insert(objects, obj)
      end
    end
  end
  file:close()
  return objects
end

-- Ensure main/MissionGroup/BCM_AREAS/items.level.json exists in the mod output
-- dir with a minimal manifest. Safe to call multiple times. Returns true if the
-- file exists after the call.
ensureBcmAreasParent = function(levelName)
  if not levelName or levelName == "" then return false end
  local writePath = getModLevelsPath(levelName) .. "/main/MissionGroup/BCM_AREAS/items.level.json"
  if FS:fileExists(writePath) then return true end
  local readPath = "/levels/" .. levelName .. "/main/MissionGroup/BCM_AREAS/items.level.json"
  local seed = readNdjsonFile(readPath) or {}
  writeNdjsonToMod(writePath, seed)
  log('I', logTag, 'ensureBcmAreasParent: seeded ' .. writePath .. ' with ' .. #seed .. ' entries')
  return true
end

-- ============================================================================
-- Module API (filled in next tasks)
-- ============================================================================

-- Deep copy a Lua value. Handles tables recursively. Does NOT handle cycles
-- (not needed for WIP data which is tree-shaped). Preserves __jsontype metatable
-- hints used by the JSON serializer for distinguishing empty arrays from empty
-- objects.
deepCopy = function(v)
  if type(v) ~= "table" then return v end
  local copy = {}
  for k, sub in pairs(v) do
    copy[k] = deepCopy(sub)
  end
  local mt = getmetatable(v)
  if mt then setmetatable(copy, mt) end
  return copy
end

-- Replace contents of `target` with contents of `source` while preserving
-- target's table identity. Callers in devtoolV2.lua hydrate mirror arrays
-- (deliveryFacilities[i] = entry.edited) by reference, so reassigning
-- entry.edited to a new table would leave those mirrors pointing at the old,
-- stale data. This helper keeps the table identity intact so mirrors stay
-- consistent after replaceItem / undo / redo.
local function assignInPlace(target, source)
  if type(target) ~= "table" or type(source) ~= "table" then return end
  for k in pairs(target) do target[k] = nil end
  for k, v in pairs(source) do target[k] = v end
end

-- Deep structural equality. Key ordering in tables is ignored (Lua tables are
-- unordered). For floats, uses exact equality — drift detection is meant to
-- catch edits, not floating-point noise, so callers should round explicitly if
-- they care.
deepEquals = function(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, va in pairs(a) do
    if not deepEquals(va, b[k]) then return false end
  end
  for k, _ in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

-- Register a kind's schema. Called once per module at init time. Schema shape:
--   { name, idPrefix, exports = {...}, hydrate, serialize, validate, defaults,
--     [writeTargetDirect] }
-- After registration, the kind's bucket is created in state.kinds if not already
-- present. Re-registering the same kind overwrites the schema (used for hot
-- reload during development).
registerKind = function(schema)
  if not schema or not schema.name or not schema.idPrefix then
    log('E', logTag, 'registerKind: schema missing name or idPrefix')
    return false
  end
  if not schema.hydrate or not schema.serialize or not schema.validate or not schema.defaults then
    log('E', logTag, 'registerKind: schema missing required functions (hydrate/serialize/validate/defaults)')
    return false
  end
  if not schema.exports or type(schema.exports) ~= "table" or #schema.exports == 0 then
    log('E', logTag, 'registerKind: schema missing exports array')
    return false
  end
  schemas[schema.name] = schema
  if not state.kinds[schema.name] then
    state.kinds[schema.name] = { items = {}, deleted = {} }
  end
  log('I', logTag, 'Registered kind: ' .. schema.name .. ' (' .. #schema.exports .. ' export targets)')
  return true
end

-- Atomic WIP persistence. Writes to <wipPath>.tmp then renames. On failure,
-- leaves the old file intact and logs the error. The .tmp file is cleaned up
-- on failure. Windows rename fails if target exists, so we remove target first.
saveWip = function()
  if not wipPath then
    log('W', logTag, 'saveWip: wipPath not set, skipping')
    return false
  end
  local tmpPath = wipPath .. ".tmp"

  -- Ensure schemaLevel is up to date before writing
  state.schemaLevel = getCurrentLevelIdentifier() or state.schemaLevel

  local ok, err = pcall(function()
    jsonWriteFile(tmpPath, state, true)
  end)
  if not ok then
    log('E', logTag, 'saveWip: failed to write tmp file: ' .. tostring(err))
    FS:removeFile(tmpPath)
    return false
  end
  if not FS:fileExists(tmpPath) then
    log('E', logTag, 'saveWip: tmp file missing after write')
    return false
  end
  if FS:fileExists(wipPath) then
    FS:removeFile(wipPath)
  end
  local renamed = FS:renameFile(tmpPath, wipPath)
  if not renamed then
    log('E', logTag, 'saveWip: rename failed')
    return false
  end
  log('D', logTag, 'saveWip: persisted WIP to ' .. wipPath)
  return true
end

-- Load WIP from disk into `state`. If file missing or malformed, resets state
-- to empty but keeps registered schemas. Does NOT trigger hydration — caller
-- must call hydrateAll after this.
loadWip = function()
  if not wipPath then
    log('W', logTag, 'loadWip: wipPath not set, skipping')
    return false
  end
  if not FS:fileExists(wipPath) then
    log('I', logTag, 'loadWip: no WIP file at ' .. wipPath .. ', starting empty')
    state.kinds = {}
    for name, _ in pairs(schemas) do
      state.kinds[name] = { items = {}, deleted = {} }
    end
    state.lastExport = nil
    return true
  end
  local data = jsonReadFile(wipPath)
  if not data or type(data) ~= "table" or data.version ~= 2 then
    log('W', logTag, 'loadWip: malformed or version-mismatched WIP, resetting')
    state.kinds = {}
    for name, _ in pairs(schemas) do
      state.kinds[name] = { items = {}, deleted = {} }
    end
    return false
  end
  state.schemaLevel = data.schemaLevel
  state.kinds = data.kinds or {}
  state.lastExport = data.lastExport
  for name, _ in pairs(schemas) do
    if not state.kinds[name] then
      state.kinds[name] = { items = {}, deleted = {} }
    end
  end
  local total = 0
  for _, kindBucket in pairs(state.kinds) do
    for _, _ in pairs(kindBucket.items) do total = total + 1 end
  end
  log('I', logTag, 'loadWip: loaded ' .. total .. ' items from ' .. wipPath)
  return true
end

-- ============================================================================
-- Observers
-- ============================================================================

notifyObservers = function()
  for _, fn in ipairs(observers) do
    local ok, err = pcall(fn)
    if not ok then
      log('W', logTag, 'observer error: ' .. tostring(err))
    end
  end
end

onChange = function(fn)
  if type(fn) == "function" then
    table.insert(observers, fn)
  end
end

-- ============================================================================
-- Level short codes
-- ============================================================================

local LEVEL_SHORT_CODES = {
  italy                 = "it",
  west_coast_usa        = "wc",
  east_coast_usa        = "ec",
  utah                  = "ut",
  johnson_valley        = "jv",
  jungle_rock_island    = "jr",
  small_island          = "si",
  hirochi_raceway       = "hr",
  industrial            = "in",
  automation_test_track = "at",
}

local function getLevelShortCode(levelName)
  if not levelName or levelName == "" then return "un" end
  local hard = LEVEL_SHORT_CODES[levelName]
  if hard then return hard end
  if levelName:find("_") then
    local parts = {}
    for tok in string.gmatch(levelName, "[^_]+") do
      table.insert(parts, tok)
    end
    if #parts >= 2 then
      return (parts[1]:sub(1,1) .. parts[2]:sub(1,1)):lower()
    end
  end
  return levelName:sub(1, 2):lower()
end

-- ============================================================================
-- ID generation (stub — replaced with full impl in Task 7)
-- ============================================================================

-- Scans WIP items, WIP deleted[], and production (via schema.hydrate) for the
-- given kind. Finds max numeric suffix matching <prefix>_<idPrefix>_<N>.
-- Returns <prefix>_<idPrefix>_<max+1>. Collision with non-numeric IDs
-- increments until free.
generateId = function(kind, levelName)
  local schema = schemas[kind]
  if not schema then
    log('E', logTag, 'generateId: unknown kind ' .. tostring(kind))
    return nil
  end
  levelName = levelName or getCurrentLevelIdentifier() or "unknown"
  local shortCode = getLevelShortCode(levelName)
  local pattern = "^" .. shortCode .. "_" .. schema.idPrefix .. "_(%d+)$"
  local maxN = 0
  local bucket = state.kinds[kind] or { items = {}, deleted = {} }
  for id, _ in pairs(bucket.items) do
    local n = id:match(pattern)
    if n then
      n = tonumber(n)
      if n and n > maxN then maxN = n end
    end
  end
  for _, id in ipairs(bucket.deleted) do
    local n = id:match(pattern)
    if n then
      n = tonumber(n)
      if n and n > maxN then maxN = n end
    end
  end
  local prodItems = schema.hydrate(levelName) or {}
  for _, prod in ipairs(prodItems) do
    local n = prod.id and prod.id:match(pattern)
    if n then
      n = tonumber(n)
      if n and n > maxN then maxN = n end
    end
  end
  local candidate = shortCode .. "_" .. schema.idPrefix .. "_" .. tostring(maxN + 1)
  local attempts = 0
  while bucket.items[candidate] and attempts < 100 do
    maxN = maxN + 1
    candidate = shortCode .. "_" .. schema.idPrefix .. "_" .. tostring(maxN + 1)
    attempts = attempts + 1
  end
  return candidate
end

-- ============================================================================
-- Field path helper
-- ============================================================================

-- Apply value at a dot-separated path inside a table. Creates nested tables if
-- missing. Supports numeric array indices ("parkingSpots.0.pos.x") — 0-indexed
-- for consistency with JS/Vue path strings, converted to Lua 1-indexed on walk.
-- Returns the previous value at that path.
applyFieldPath = function(tbl, path, value)
  local parts = {}
  for token in string.gmatch(path, "[^.]+") do
    table.insert(parts, token)
  end
  local cur = tbl
  for i = 1, #parts - 1 do
    local key = parts[i]
    local numKey = tonumber(key)
    if numKey ~= nil then key = numKey + 1 end
    if cur[key] == nil then cur[key] = {} end
    cur = cur[key]
    if type(cur) ~= "table" then
      log('W', logTag, 'applyFieldPath: non-table at ' .. path)
      return nil
    end
  end
  local lastKey = parts[#parts]
  local numLast = tonumber(lastKey)
  if numLast ~= nil then lastKey = numLast + 1 end
  local prev = cur[lastKey]
  cur[lastKey] = value
  return prev
end

-- ============================================================================
-- CRUD
-- ============================================================================

-- Create a new item in the given kind. Assigns a fresh ID via generateId.
-- extraFields (optional) is merged on top of schema.defaults(id).
-- Origin is "new", baseline is nil.
createNew = function(kind, extraFields)
  local schema = schemas[kind]
  if not schema then
    log('E', logTag, 'createNew: unknown kind ' .. tostring(kind))
    return nil
  end
  local levelName = getCurrentLevelIdentifier() or "unknown"
  local id = generateId(kind, levelName)
  local edited = schema.defaults(id)
  if extraFields then
    for k, v in pairs(extraFields) do
      edited[k] = v
    end
  end
  edited.id = id
  local entry = {
    baseline = nil,
    edited = edited,
    origin = "new",
    touchedAt = os.time(),
    conflicted = false,
  }
  state.kinds[kind].items[id] = entry
  saveWip()
  notifyObservers()
  log('I', logTag, 'createNew ' .. kind .. ': ' .. id)
  return entry
end

get = function(kind, id)
  local bucket = state.kinds[kind]
  if not bucket then return nil end
  return bucket.items[id]
end

list = function(kind)
  local bucket = state.kinds[kind]
  if not bucket then return {} end
  local result = {}
  for _, entry in pairs(bucket.items) do
    table.insert(result, entry)
  end
  table.sort(result, function(a, b) return (a.touchedAt or 0) < (b.touchedAt or 0) end)
  return result
end

listIds = function(kind)
  local bucket = state.kinds[kind]
  if not bucket then return {} end
  local result = {}
  for id, _ in pairs(bucket.items) do
    table.insert(result, id)
  end
  table.sort(result)
  return result
end

updateField = function(kind, id, fieldPath, value)
  local entry = get(kind, id)
  if not entry then
    log('W', logTag, 'updateField: no item ' .. kind .. '/' .. tostring(id))
    return false
  end
  -- Capture baseline snapshot on first edit (spec §5 invariant 2)
  if entry.origin == "production" and entry.baseline == nil then
    entry.baseline = deepCopy(entry.edited)
  end
  local prev = applyFieldPath(entry.edited, fieldPath, value)
  entry.touchedAt = os.time()
  pushUndoOp({
    op = "updateField",
    kind = kind,
    id = id,
    fieldPath = fieldPath,
    before = prev,
    after = value,
    timestamp = entry.touchedAt,
  })
  saveWip()
  notifyObservers()
  return true, prev
end

-- replaceItem(kind, id, newEdited [, explicitBefore])
-- If explicitBefore is provided, it's used as the "before" snapshot in the
-- undo op. This is needed when the caller has already mutated entry.edited
-- in-place (e.g., via a shared reference from the orchestrator's legacy
-- garages[] mirror) — the internal deepCopy of entry.edited would capture
-- the ALREADY-mutated state, making before==after and the undo useless.
replaceItem = function(kind, id, newEdited, explicitBefore)
  local entry = get(kind, id)
  if not entry then
    log('W', logTag, 'replaceItem: no item ' .. kind .. '/' .. tostring(id))
    return false
  end
  if entry.origin == "production" and entry.baseline == nil then
    entry.baseline = explicitBefore and deepCopy(explicitBefore) or deepCopy(entry.edited)
  end
  local beforeSnapshot = explicitBefore or deepCopy(entry.edited)
  assignInPlace(entry.edited, deepCopy(newEdited))
  entry.edited.id = id  -- ID is immutable
  entry.touchedAt = os.time()
  pushUndoOp({
    op = "replaceItem",
    kind = kind,
    id = id,
    before = beforeSnapshot,
    after = deepCopy(entry.edited),
    timestamp = entry.touchedAt,
  })
  saveWip()
  notifyObservers()
  return true
end

delete = function(kind, id)
  local bucket = state.kinds[kind]
  if not bucket then return false end
  local entry = bucket.items[id]
  if not entry then return false end
  local beforeSnapshot = deepCopy(entry)
  local wasInDeleted = false
  if entry.origin == "production" then
    table.insert(bucket.deleted, id)
    wasInDeleted = true
  end
  bucket.items[id] = nil
  pushUndoOp({
    op = "delete",
    kind = kind,
    id = id,
    before = beforeSnapshot,
    wasInDeleted = wasInDeleted,
    timestamp = os.time(),
  })
  saveWip()
  notifyObservers()
  log('I', logTag, 'delete ' .. kind .. ': ' .. id)
  return true
end

-- ============================================================================
-- Undo stack
-- ============================================================================

pushUndoOp = function(op)
  table.insert(undoStack, op)
  if #undoStack > UNDO_CAPACITY then
    table.remove(undoStack, 1)
  end
  redoStack = {}
end

clearUndoStack = function()
  undoStack = {}
  redoStack = {}
end

getUndoDepth = function()
  return #undoStack
end

undo = function()
  local op = table.remove(undoStack)
  if not op then
    log('D', logTag, 'undo: stack empty')
    return false
  end
  local bucket = state.kinds[op.kind]
  if not bucket then
    log('W', logTag, 'undo: unknown kind ' .. tostring(op.kind))
    return false
  end
  if op.op == "updateField" then
    local entry = bucket.items[op.id]
    if entry then
      applyFieldPath(entry.edited, op.fieldPath, op.before)
      entry.touchedAt = os.time()
    end
  elseif op.op == "replaceItem" then
    local entry = bucket.items[op.id]
    if entry then
      assignInPlace(entry.edited, deepCopy(op.before))
      entry.touchedAt = os.time()
    end
  elseif op.op == "delete" then
    bucket.items[op.id] = deepCopy(op.before)
    if op.wasInDeleted then
      for i, did in ipairs(bucket.deleted) do
        if did == op.id then
          table.remove(bucket.deleted, i)
          break
        end
      end
    end
  end
  table.insert(redoStack, op)
  saveWip()
  notifyObservers()
  log('I', logTag, 'undo: ' .. op.op .. ' on ' .. op.kind .. '/' .. op.id)
  return true
end

redo = function()
  local op = table.remove(redoStack)
  if not op then
    log('D', logTag, 'redo: stack empty')
    return false
  end
  local bucket = state.kinds[op.kind]
  if not bucket then return false end
  if op.op == "updateField" then
    local entry = bucket.items[op.id]
    if entry then
      applyFieldPath(entry.edited, op.fieldPath, op.after)
      entry.touchedAt = os.time()
    end
  elseif op.op == "replaceItem" then
    local entry = bucket.items[op.id]
    if entry then
      assignInPlace(entry.edited, deepCopy(op.after))
      entry.touchedAt = os.time()
    end
  elseif op.op == "delete" then
    if op.wasInDeleted then
      table.insert(bucket.deleted, op.id)
    end
    bucket.items[op.id] = nil
  end
  table.insert(undoStack, op)
  saveWip()
  notifyObservers()
  log('I', logTag, 'redo: ' .. op.op .. ' on ' .. op.kind .. '/' .. op.id)
  return true
end

-- ============================================================================
-- Hydration
-- ============================================================================

-- For a single kind, pull production items and merge into WIP. Items already
-- present in WIP (regardless of origin) are untouched. Items in deleted[] are
-- also skipped. New items from production get inserted with origin="production",
-- baseline=<copy>, edited=<copy>.
rehydrateKind = function(kind, levelName)
  local schema = schemas[kind]
  if not schema then
    log('W', logTag, 'rehydrateKind: unknown kind ' .. tostring(kind))
    return 0
  end
  levelName = levelName or getCurrentLevelIdentifier()
  if not levelName then
    log('W', logTag, 'rehydrateKind: no level identifier')
    return 0
  end
  local bucket = state.kinds[kind]
  if not bucket then
    state.kinds[kind] = { items = {}, deleted = {} }
    bucket = state.kinds[kind]
  end
  local deletedSet = {}
  for _, did in ipairs(bucket.deleted) do deletedSet[did] = true end
  local prodItems = schema.hydrate(levelName) or {}
  local added = 0
  for _, prod in ipairs(prodItems) do
    local id = prod.id
    if id and not bucket.items[id] and not deletedSet[id] then
      bucket.items[id] = {
        baseline = deepCopy(prod.data),
        edited = deepCopy(prod.data),
        origin = "production",
        touchedAt = os.time(),
        conflicted = false,
      }
      added = added + 1
    end
  end
  log('I', logTag, 'rehydrateKind ' .. kind .. ': added ' .. added .. ' items from production')
  return added
end

hydrateAll = function(levelName)
  levelName = levelName or getCurrentLevelIdentifier() or "unknown"
  state.schemaLevel = levelName
  local total = 0
  for name, _ in pairs(schemas) do
    total = total + rehydrateKind(name, levelName)
  end
  if total > 0 then
    saveWip()
    notifyObservers()
  end
  log('I', logTag, 'hydrateAll (' .. levelName .. '): ' .. total .. ' items added')
  return total
end

-- ============================================================================
-- Drift detection
-- ============================================================================

-- Reads the current production content for the item and compares it against
-- entry.baseline. Returns "safe"|"drift"|"new"|"untouched".
checkDrift = function(kind, id, levelName)
  local entry = get(kind, id)
  if not entry then return "untouched" end
  if entry.origin ~= "production" or entry.baseline == nil then
    return "new"
  end
  local schema = schemas[kind]
  if not schema then return "new" end
  local prodItems = schema.hydrate(levelName) or {}
  local prodEntry = nil
  for _, prod in ipairs(prodItems) do
    if prod.id == id then prodEntry = prod.data; break end
  end
  if prodEntry == nil then
    return "drift"
  end
  if deepEquals(entry.baseline, prodEntry) then
    return "safe"
  else
    return "drift"
  end
end

checkAllDrift = function(levelName)
  levelName = levelName or getCurrentLevelIdentifier()
  local result = {}
  for kindName, bucket in pairs(state.kinds) do
    result[kindName] = {}
    for id, _ in pairs(bucket.items) do
      result[kindName][id] = checkDrift(kindName, id, levelName)
    end
  end
  return result
end

-- ============================================================================
-- Export plan
-- ============================================================================

-- Recursive field-path diff between two tables. Returns a list of dot-notation
-- paths whose values differ. Treats arrays as ordered. Used by buildExportPlan
-- to surface per-item changes for the UI.
local function diffFields(a, b, prefix, out)
  prefix = prefix or ""
  out = out or {}
  if a == nil and b == nil then return out end
  if (a == nil) ~= (b == nil) or type(a) ~= type(b) then
    table.insert(out, prefix == "" and "<root>" or prefix)
    return out
  end
  if type(a) ~= "table" then
    if a ~= b then
      table.insert(out, prefix == "" and "<root>" or prefix)
    end
    return out
  end
  local seen = {}
  for k, v in pairs(a) do
    seen[k] = true
    local p = prefix == "" and tostring(k) or (prefix .. "." .. tostring(k))
    diffFields(v, b[k], p, out)
  end
  for k, v in pairs(b) do
    if not seen[k] then
      local p = prefix == "" and tostring(k) or (prefix .. "." .. tostring(k))
      diffFields(nil, v, p, out)
    end
  end
  return out
end

-- Walks each kind, validates every item via schema.validate, classifies each
-- item as toWrite / skipped / invalid. Drifted items are SKIPPED (not written)
-- until the user explicitly resolves them via resolveConflict (keepMine or
-- takeProd). Writing drifted items silently overwrites external changes — this
-- cost us real work when prod JSONs were hand-edited while an older WIP was
-- still loaded. To export a drifted item, resolve it first so its driftStatus
-- drops back to "safe".
--
-- Plan shape:
--   kinds[kindName] = {
--     toWrite  = { entry, ... },             -- raw WIP entries (unchanged ref for executeExport)
--     toDelete = { id, ... },
--     itemMeta = { [id] = { drift, changedFields, name, skipped } },
--     conflicts = { { id, name }, ... },     -- drift items (all live in `skipped`, NOT toWrite)
--     skipped  = { { id, name, reason } },   -- items intentionally excluded from write
--     invalid  = { { id, errors }, ... },
--   }
buildExportPlan = function(levelName)
  levelName = levelName or getCurrentLevelIdentifier()
  local plan = {
    kinds = {},
    summary = {
      totalToWrite = 0, totalToDelete = 0,
      totalConflicts = 0, totalInvalid = 0, totalChanged = 0, totalSkipped = 0,
    },
  }
  for kindName, bucket in pairs(state.kinds) do
    local schema = schemas[kindName]
    if schema then
      local kindPlan = {
        toWrite = {}, toDelete = {}, conflicts = {}, skipped = {}, invalid = {},
        itemMeta = {},
      }
      for id, entry in pairs(bucket.items) do
        local ok, errs = schema.validate(entry.edited)
        if not ok then
          table.insert(kindPlan.invalid, { id = id, errors = errs })
          plan.summary.totalInvalid = plan.summary.totalInvalid + 1
        else
          local driftStatus = checkDrift(kindName, id, levelName)
          local changed = diffFields(entry.baseline, entry.edited)
          if #changed > 0 then plan.summary.totalChanged = plan.summary.totalChanged + 1 end
          local isDrift = (driftStatus == "drift")
          local meta = {
            drift = isDrift,
            driftStatus = driftStatus,
            changedFields = changed,
            name = (entry.edited and entry.edited.name) or id,
            skipped = isDrift,
          }
          kindPlan.itemMeta[id] = meta
          if isDrift then
            -- Hold back drifted items — prod stays untouched until the user
            -- explicitly resolves via keepMine/takeProd.
            table.insert(kindPlan.conflicts, { id = id, name = meta.name, status = driftStatus })
            table.insert(kindPlan.skipped,   { id = id, name = meta.name, reason = "drift" })
            plan.summary.totalConflicts = plan.summary.totalConflicts + 1
            plan.summary.totalSkipped   = plan.summary.totalSkipped + 1
          else
            table.insert(kindPlan.toWrite, entry)
            plan.summary.totalToWrite = plan.summary.totalToWrite + 1
          end
        end
      end
      for _, id in ipairs(bucket.deleted) do
        table.insert(kindPlan.toDelete, id)
        plan.summary.totalToDelete = plan.summary.totalToDelete + 1
      end
      plan.kinds[kindName] = kindPlan
    end
  end
  return plan
end

-- ============================================================================
-- Conflict resolution
-- ============================================================================

-- Resolves a single conflicted item by re-capturing the current production
-- snapshot as the new baseline. Strategy controls what happens to `edited`:
--   "keepMine" → baseline := currentProd, edited unchanged (your edits ride
--                on top of the new prod state in the next export).
--   "takeProd" → baseline := currentProd, edited := currentProd (your edits
--                are discarded; item effectively returns to prod state).
-- Returns true on success, false + error string on failure.
resolveConflict = function(kind, id, strategy, levelName)
  levelName = levelName or getCurrentLevelIdentifier()
  if not levelName then return false, "no level" end
  local bucket = state.kinds[kind]
  if not bucket then return false, "unknown kind" end
  local entry = bucket.items[id]
  if not entry then return false, "unknown id" end
  local schema = schemas[kind]
  if not schema then return false, "no schema" end

  local prodItems = schema.hydrate(levelName) or {}
  local prodEntry = nil
  for _, p in ipairs(prodItems) do
    if p.id == id then prodEntry = p.data; break end
  end
  if prodEntry == nil then
    return false, "item no longer exists in production"
  end

  entry.baseline = deepCopy(prodEntry)
  if strategy == "takeProd" then
    entry.edited = deepCopy(prodEntry)
  elseif strategy ~= "keepMine" then
    return false, "unknown strategy " .. tostring(strategy)
  end
  entry.conflicted = false
  entry.touchedAt = os.time()
  saveWip()
  notifyObservers()
  log('I', logTag, 'resolveConflict ' .. kind .. '/' .. id .. ': ' .. strategy)
  return true
end

-- Bulk resolution: runs resolveConflict for every currently-drifting item.
-- kind = nil applies across all kinds; kind = "delivery" limits scope.
-- Returns { resolved = N, failed = {{id, err}, ...} }.
resolveAllConflicts = function(strategy, kind, levelName)
  levelName = levelName or getCurrentLevelIdentifier()
  if not levelName then return { resolved = 0, failed = {} } end
  local resolved = 0
  local failed = {}
  for kindName, bucket in pairs(state.kinds) do
    if kind == nil or kind == kindName then
      for id, _ in pairs(bucket.items) do
        if checkDrift(kindName, id, levelName) == "drift" then
          local ok, err = resolveConflict(kindName, id, strategy, levelName)
          if ok then
            resolved = resolved + 1
          else
            table.insert(failed, { kind = kindName, id = id, err = err })
          end
        end
      end
    end
  end
  log('I', logTag, 'resolveAllConflicts (' .. strategy .. '): ' .. resolved
    .. ' resolved, ' .. #failed .. ' failed')
  return { resolved = resolved, failed = failed }
end

-- ============================================================================
-- Atomic export
-- ============================================================================

-- Groups writes by destination file, serializes each entry via schema.serialize,
-- stages every target to .tmp, then renames all atomically. On stage failure,
-- rolls back all .tmp files. Supports the __placeInto / __extra / __skipCoreWrite
-- serialize protocol so complex kinds (like garages) can direct where entries
-- land inside their target files, or take over a target file entirely.
executeExport = function(plan, levelName)
  levelName = levelName or getCurrentLevelIdentifier()
  if not levelName then
    log('E', logTag, 'executeExport: no level identifier')
    return { success = false, error = "no level" }
  end

  -- Phase A.5: pre-export snapshot
  if snapshotDir then
    saveSnapshot("pre-export")
  end

  -- Phase A: build file write buckets keyed by absolute write path
  local fileWrites = {}  -- [writePath] = { format, mergeMode, readPath, entries, deletions, kindName, schema }

  for kindName, kindPlan in pairs(plan.kinds) do
    local schema = schemas[kindName]
    if schema then
      -- Skip kinds that have nothing to write AND nothing to delete.
      -- Without this guard, a kind with an empty WIP bucket would fall into the
      -- generic merge path below with zero entries and rewrite (corrupt) its
      -- production target file.
      local hasWork = (#kindPlan.toWrite > 0) or (#kindPlan.toDelete > 0)
      if hasWork then
      for _, target in ipairs(schema.exports) do
        local resolvedSubPath = target.path:gsub("<level>", levelName)
        local writePath = getModLevelsPath(levelName) .. "/" .. resolvedSubPath
        local readPath = "/levels/" .. levelName .. "/" .. resolvedSubPath
        -- Check first entry — if serialize returns __skipCoreWrite, delegate to writeTargetDirect.
        -- If there are no entries but there are deletions, probe against schema.defaults so
        -- we still detect the delegate path for pure-delete operations.
        local delegateDirect = false
        local probeItem = nil
        if #kindPlan.toWrite > 0 then
          probeItem = kindPlan.toWrite[1].edited
        elseif schema.defaults then
          probeItem = schema.defaults()
        end
        if probeItem then
          local probe = schema.serialize(probeItem, target, levelName, nil)
          if probe and probe.__skipCoreWrite then
            delegateDirect = true
          end
        end
        if delegateDirect then
          if schema.writeTargetDirect then
            local ok, err = pcall(function()
              schema.writeTargetDirect(target, kindPlan.toWrite, kindPlan.toDelete, levelName)
            end)
            if not ok then
              log('E', logTag, 'writeTargetDirect failed for ' .. target.path .. ': ' .. tostring(err))
            end
          else
            log('W', logTag, 'serialize returned __skipCoreWrite but no writeTargetDirect on schema')
          end
        else
          if not fileWrites[writePath] then
            fileWrites[writePath] = {
              format = target.format,
              mergeMode = target.mergeMode,
              readPath = readPath,
              entries = {},
              deletions = {},
              kindName = kindName,
              schema = schema,
              targetSpec = target,
            }
          end
          for _, entry in ipairs(kindPlan.toWrite) do
            local serialized = schema.serialize(entry.edited, target, levelName, nil)
            if serialized and not serialized.__skipCoreWrite then
              table.insert(fileWrites[writePath].entries, {
                item = entry.edited,
                serialized = serialized,
              })
            end
          end
          for _, id in ipairs(kindPlan.toDelete) do
            table.insert(fileWrites[writePath].deletions, id)
          end
        end
      end
      end  -- if hasWork
    end
  end

  -- Phase B: stage writes to .tmp
  local stagedTmpFiles = {}
  local stageErrors = {}

  for writePath, bucket in pairs(fileWrites) do
    local existing
    if bucket.format == "json" then
      existing = jsonReadFile(bucket.readPath) or {}
    elseif bucket.format == "ndjson" then
      existing = readNdjsonFile(bucket.readPath) or {}
    end

    local applied
    if bucket.mergeMode == "replace" then
      -- Check if the container is a flat array (like garages_<level>.json)
      local isFlatArray = false
      if #bucket.entries > 0 and bucket.entries[1].serialized.__placeInto == "__topLevel_array" then
        isFlatArray = true
      end
      if isFlatArray then
        applied = {}
        for _, ent in ipairs(bucket.entries) do
          table.insert(applied, ent.serialized.entry)
        end
      else
        -- Preserve sibling fields of the existing object
        applied = {}
        if type(existing) == "table" then
          for k, v in pairs(existing) do
            -- Preserve scalar/object siblings not matching known container-array names
            if type(v) ~= "table" or (type(v) == "table" and v[1] == nil and next(v) == nil) then
              applied[k] = v
            elseif type(v) == "table" and v[1] == nil then
              -- Object (non-array) — preserve
              applied[k] = v
            end
          end
        end
        for _, ent in ipairs(bucket.entries) do
          local s = ent.serialized
          if s.__placeInto then
            applied[s.__placeInto] = applied[s.__placeInto] or {}
            table.insert(applied[s.__placeInto], s.entry)
          end
          if s.__extra then
            for _, extra in ipairs(s.__extra) do
              applied[extra.key] = applied[extra.key] or {}
              if extra.entry then
                table.insert(applied[extra.key], extra.entry)
              end
              if extra.entries then
                for _, e in ipairs(extra.entries) do
                  table.insert(applied[extra.key], e)
                end
              end
            end
          end
        end
      end
    else  -- mergeMode == "field"
      applied = type(existing) == "table" and deepCopy(existing) or {}
      -- Delete entries matching toDelete IDs from known container arrays
      local deletedSet = {}
      for _, id in ipairs(bucket.deletions) do deletedSet[id] = true end
      if type(applied) == "table" then
        for k, v in pairs(applied) do
          if type(v) == "table" and v[1] ~= nil then
            local kept = {}
            for _, item in ipairs(v) do
              local itemId = item.id or item.garageId
              if not (itemId and deletedSet[itemId]) then
                table.insert(kept, item)
              end
            end
            applied[k] = kept
          end
        end
      end
      -- Now remove entries with IDs matching those being rewritten (replace-by-id)
      local rewriteIds = {}
      for _, ent in ipairs(bucket.entries) do
        local s = ent.serialized
        if s.__placeInto and s.entry and s.entry.id then
          rewriteIds[s.entry.id] = true
        end
        if s.__extra then
          for _, extra in ipairs(s.__extra) do
            if extra.entry and extra.entry.id then
              rewriteIds[extra.entry.id] = true
            end
            if extra.entry and extra.entry.garageId then
              rewriteIds[extra.entry.garageId] = true
            end
          end
        end
      end
      if type(applied) == "table" then
        for k, v in pairs(applied) do
          if type(v) == "table" and v[1] ~= nil then
            local kept = {}
            for _, item in ipairs(v) do
              local iid = item.id or item.garageId
              if not (iid and rewriteIds[iid]) then
                table.insert(kept, item)
              end
            end
            applied[k] = kept
          end
        end
      end
      -- Upsert new entries. Match each new entry to an existing one by
      -- id/garageId/name (whichever is present). If found, DEEP-MERGE the new
      -- entry onto the existing one so fields v2 doesn't model (e.g. bot/top/
      -- color on zones) survive the round-trip. If not found, append as new.
      -- This is the preserve-unknowns pattern — v2 only owns the fields it
      -- actively writes; everything else is passthrough.
      local function entryKey(e)
        if type(e) ~= "table" then return nil end
        return e.id or e.garageId or e.name
      end
      local function deepMerge(base, overlay)
        if type(base) ~= "table" then return deepCopy(overlay) end
        if type(overlay) ~= "table" then return deepCopy(overlay) end
        local out = deepCopy(base)
        for k, v in pairs(overlay) do
          if type(v) == "table" and type(out[k]) == "table" and v[1] == nil and out[k][1] == nil then
            -- both are non-array objects → recurse
            out[k] = deepMerge(out[k], v)
          else
            -- scalar, array, or type mismatch → overlay wins
            out[k] = deepCopy(v)
          end
        end
        return out
      end
      local function upsert(containerKey, newEntry)
        applied[containerKey] = applied[containerKey] or {}
        local key = entryKey(newEntry)
        if key ~= nil then
          for i, existing in ipairs(applied[containerKey]) do
            if entryKey(existing) == key then
              applied[containerKey][i] = deepMerge(existing, newEntry)
              return
            end
          end
        end
        table.insert(applied[containerKey], newEntry)
      end
      for _, ent in ipairs(bucket.entries) do
        local s = ent.serialized
        if s.__placeInto and s.entry then
          upsert(s.__placeInto, s.entry)
        end
        if s.__extra then
          for _, extra in ipairs(s.__extra) do
            if extra.entry then
              upsert(extra.key, extra.entry)
            end
            if extra.entries then
              for _, e in ipairs(extra.entries) do
                upsert(extra.key, e)
              end
            end
          end
        end
      end
    end

    -- No-shrink guard: for any container array under `applied`, count must be
    -- >= the same container in `existing` minus the number of deletions planned.
    -- This catches the silent-overwrite class of bugs where a buggy serializer
    -- or skipped-conflict path produces fewer entries than expected.
    local shrinkErr = nil
    if type(existing) == "table" and type(applied) == "table" then
      local plannedDeletes = #bucket.deletions
      for k, v in pairs(existing) do
        if type(v) == "table" and v[1] ~= nil then
          local oldCount = #v
          local newV = applied[k]
          local newCount = (type(newV) == "table") and #newV or 0
          local minAllowed = oldCount - plannedDeletes
          if newCount < minAllowed then
            shrinkErr = string.format(
              "no-shrink: %s.%s has %d entries, was %d (only %d deletions planned)",
              writePath, k, newCount, oldCount, plannedDeletes)
            break
          end
        end
      end
    end
    if shrinkErr then
      table.insert(stageErrors, shrinkErr)
    else
      local tmpPath = writePath .. ".tmp"
      local ok, err = pcall(function()
        if bucket.format == "json" then
          writeJsonToMod(tmpPath, applied)
        elseif bucket.format == "ndjson" then
          writeNdjsonToMod(tmpPath, applied)
        end
      end)
      if not ok then
        table.insert(stageErrors, "Stage failed for " .. writePath .. ": " .. tostring(err))
      else
        table.insert(stagedTmpFiles, {
          tmp = tmpPath,
          final = writePath,
          format = bucket.format,
          kindName = bucket.kindName,
        })
      end
    end
  end

  if #stageErrors > 0 then
    for _, f in ipairs(stagedTmpFiles) do
      FS:removeFile(f.tmp)
    end
    log('E', logTag, 'executeExport: stage phase failed with ' .. #stageErrors .. ' errors')
    for _, e in ipairs(stageErrors) do log('E', logTag, '  ' .. e) end
    return { success = false, errors = stageErrors }
  end

  -- Phase B.5: cross-file integrity validation (defensive). Each schema can
  -- declare an `integrityCheck(stagedTmpFiles, plan, levelName, helpers)` hook
  -- that returns nil on success or a list of error strings. The hook receives
  -- a tmpByFinal lookup so it can read its own .tmp files (and other kinds')
  -- to verify cross-file invariants such as "every facility manualAccessPoints
  -- psName exists in sites.json parkingSpots". Failure aborts the whole export
  -- and rolls back ALL .tmp files — no destination is touched.
  local tmpByFinal = {}
  for _, f in ipairs(stagedTmpFiles) do
    tmpByFinal[f.final] = f
  end
  local helpers = {
    readJson = function(path) return jsonReadFile(path) end,
    readNdjson = function(path) return readNdjsonFile(path) end,
    getModLevelsPath = getModLevelsPath,
  }
  local integrityErrors = {}
  for kindName, schema in pairs(schemas) do
    if type(schema.integrityCheck) == "function" then
      local ok, errsOrErr = pcall(schema.integrityCheck, stagedTmpFiles, plan, levelName, helpers, tmpByFinal)
      if not ok then
        table.insert(integrityErrors, kindName .. ".integrityCheck crashed: " .. tostring(errsOrErr))
      elseif type(errsOrErr) == "table" then
        for _, e in ipairs(errsOrErr) do
          table.insert(integrityErrors, kindName .. ": " .. tostring(e))
        end
      end
    end
  end
  if #integrityErrors > 0 then
    for _, f in ipairs(stagedTmpFiles) do
      FS:removeFile(f.tmp)
    end
    log('E', logTag, 'executeExport: integrity check failed with ' .. #integrityErrors .. ' errors')
    for _, e in ipairs(integrityErrors) do log('E', logTag, '  ' .. e) end
    return { success = false, errors = integrityErrors, integrityFailed = true }
  end

  -- Phase C: rename all .tmp → final
  local renameErrors = {}
  for _, f in ipairs(stagedTmpFiles) do
    if FS:fileExists(f.final) then FS:removeFile(f.final) end
    if not FS:renameFile(f.tmp, f.final) then
      table.insert(renameErrors, "Rename failed for " .. f.final)
    end
  end

  if #renameErrors > 0 then
    log('E', logTag, 'executeExport: rename phase errors: ' .. table.concat(renameErrors, "; "))
    return { success = false, errors = renameErrors }
  end

  -- Phase D: post-export — update baselines, clear delete lists, clear undo stack
  for kindName, kindPlan in pairs(plan.kinds) do
    local bucket = state.kinds[kindName]
    for _, entry in ipairs(kindPlan.toWrite) do
      entry.baseline = deepCopy(entry.edited)
      entry.conflicted = false
    end
    for _, id in ipairs(kindPlan.toDelete) do
      for i = #bucket.deleted, 1, -1 do
        if bucket.deleted[i] == id then
          table.remove(bucket.deleted, i)
          break
        end
      end
    end
  end
  clearUndoStack()
  state.lastExport = { timestamp = os.time() }
  saveWip()
  notifyObservers()

  log('I', logTag, 'executeExport: wrote ' .. #stagedTmpFiles .. ' files, '
    .. plan.summary.totalToWrite .. ' items, ' .. plan.summary.totalToDelete .. ' deletions')
  return { success = true, filesWritten = #stagedTmpFiles }
end

-- ============================================================================
-- Snapshots
-- ============================================================================

-- Writes a full copy of current state to <snapshotDir>/<NNNN>_<label>.json.
-- If label is nil or empty, uses "auto". Counter is max existing + 1 in the
-- snapshot dir. Returns the snapshot path on success, nil on failure.
saveSnapshot = function(label)
  if not snapshotDir then
    log('W', logTag, 'saveSnapshot: snapshotDir not set')
    return nil
  end
  if not label or label == "" then label = "auto" end
  if not FS:directoryExists(snapshotDir) then
    FS:directoryCreate(snapshotDir)
  end
  local existing = FS:findFiles(snapshotDir, "*.json", 0, true, false) or {}
  local maxCounter = 0
  for _, path in ipairs(existing) do
    local n = path:match("/(%d+)_")
    if n then
      n = tonumber(n)
      if n and n > maxCounter then maxCounter = n end
    end
  end
  local filename = string.format("%04d_%s.json", maxCounter + 1, label)
  local snapshotPath = snapshotDir .. "/" .. filename
  local ok, err = pcall(function()
    jsonWriteFile(snapshotPath, state, true)
  end)
  if not ok then
    log('E', logTag, 'saveSnapshot: ' .. tostring(err))
    return nil
  end
  log('I', logTag, 'saveSnapshot: wrote ' .. filename)
  return snapshotPath
end

listSnapshots = function()
  if not snapshotDir or not FS:directoryExists(snapshotDir) then return {} end
  local files = FS:findFiles(snapshotDir, "*.json", 0, true, false) or {}
  local result = {}
  for _, path in ipairs(files) do
    local name = path:match("([^/]+)%.json$")
    local counter, label = name and name:match("^(%d+)_(.+)$")
    local itemCount = 0
    local data = jsonReadFile(path)
    if data and data.kinds then
      for _, bucket in pairs(data.kinds) do
        for _, _ in pairs(bucket.items or {}) do itemCount = itemCount + 1 end
      end
    end
    table.insert(result, {
      path = path,
      name = name,
      counter = tonumber(counter),
      label = label,
      itemCount = itemCount,
    })
  end
  table.sort(result, function(a, b) return (a.counter or 0) > (b.counter or 0) end)
  return result
end

restoreSnapshot = function(path)
  if not FS:fileExists(path) then
    log('E', logTag, 'restoreSnapshot: file not found ' .. tostring(path))
    return false
  end
  local data = jsonReadFile(path)
  if not data or type(data) ~= "table" or data.version ~= 2 then
    log('E', logTag, 'restoreSnapshot: malformed or version-mismatched snapshot')
    return false
  end
  state.schemaLevel = data.schemaLevel
  state.kinds = data.kinds or {}
  state.lastExport = data.lastExport
  for name, _ in pairs(schemas) do
    if not state.kinds[name] then
      state.kinds[name] = { items = {}, deleted = {} }
    end
  end
  clearUndoStack()
  saveWip()
  notifyObservers()
  log('I', logTag, 'restoreSnapshot: restored from ' .. path)
  return true
end

-- ============================================================================
-- Module table
-- ============================================================================

setWipPath = function(p) wipPath = p end
setSnapshotDir = function(d) snapshotDir = d end

M.setWipPath = setWipPath
M.setSnapshotDir = setSnapshotDir
M.registerKind = registerKind
M.saveWip = saveWip
M.loadWip = loadWip
M.createNew = createNew
M.get = get
M.list = list
M.listIds = listIds
M.updateField = updateField
M.replaceItem = replaceItem
M.delete = delete
M.onChange = onChange
M.generateId = generateId
M.undo = undo
M.redo = redo
M.clearUndoStack = clearUndoStack
M.getUndoDepth = getUndoDepth
M.hydrateAll = hydrateAll
M.rehydrateKind = rehydrateKind
M.checkDrift = checkDrift
-- Expose filesystem helpers so kind modules (garages, etc) can reuse them
-- instead of duplicating or relying on devtoolV2.lua's locals.
M.getModLevelsPath = getModLevelsPath
M.ensureModDir = ensureModDir
M.writeJsonToMod = writeJsonToMod
M.writeNdjsonToMod = writeNdjsonToMod
M.readNdjsonFile = readNdjsonFile
M.ensureBcmAreasParent = ensureBcmAreasParent
M.deepCopy = deepCopy
M.checkAllDrift = checkAllDrift
M.buildExportPlan = buildExportPlan
M.executeExport = executeExport
M.resolveConflict = resolveConflict
M.resolveAllConflicts = resolveAllConflicts
M.saveSnapshot = saveSnapshot
M.listSnapshots = listSnapshots
M.restoreSnapshot = restoreSnapshot
-- Other bindings added as functions are implemented in later tasks.

return M
