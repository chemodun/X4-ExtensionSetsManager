-- Extension Sets Manager - identity, logging and the persistent store.
-- Everything here has to work in the start menu, where player.entity does not exist, so the
-- store is the __ESM_STORE savedvariable (uidata.xml) and nothing else.
--
-- A set is identified by a numeric id, not by its name: the id is the key its body is stored
-- under, it is what "active" points at, and it is what any per-set data hangs off. The name is
-- a label and is free to change.

---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local C = ffi.C

local DEFAULT_DEBUG_LEVEL = "none"

-- The reserved id of the Default set: the setup as it stood when the feature was switched on,
-- kept so there is always something to come back to. It is the shared pool's own set, so it is
-- the one set that can never keep its savegames apart, and it is outside the id sequence -
-- NewSetId still starts at 1, so it costs nothing.
local DEFAULT_SET_ID = 0
-- The savegame prefix is "%05d_", so an id past five digits would no longer match the shape
-- the filter and the mark both test for.
local MAX_SET_ID = 99999

local esm = {
  PAGE             = 1972092441,
  debugLevel       = DEFAULT_DEBUG_LEVEL,
  DEFAULT_SET_ID   = DEFAULT_SET_ID,
  MAX_SET_ID       = MAX_SET_ID,
  -- Unicode characters, counted by the engine: the edit box's own maxChars uses utf8.len.
  MAX_SET_NAME     = 30,
}

function esm.IsDefaultSet(id)
  return id == DEFAULT_SET_ID
end

local SAVED_NAME = "__ESM_STORE"

local state = { sets = {}, enabled = false }
local storedMaxId = 0

local function write(message, ...)
  if select("#", ...) > 0 then
    message = string.format(message, ...)
  end
  DebugError("ExtensionSetsManager: " .. message)
end

function esm.Error(message, ...) write(message, ...) end
function esm.Debug(message, ...) if esm.debugLevel ~= "none" then write(message, ...) end end
function esm.Trace(message, ...) if esm.debugLevel == "trace" then write(message, ...) end end

local function countIds(set)
  local count = 0
  for _ in pairs(set.ids) do
    count = count + 1
  end
  return count
end

function esm.Sets()
  return state.sets
end

function esm.FindSet(id)
  if id == nil then
    return nil, nil
  end
  for index, set in ipairs(state.sets) do
    if set.id == id then
      return set, index
    end
  end
  return nil, nil
end

function esm.FindSetByName(name)
  for index, set in ipairs(state.sets) do
    if set.name == name then
      return set, index
    end
  end
  return nil, nil
end

-- Ids are never reused: the stored bound only grows, so a deleted set's id cannot come back
-- and pick up whatever was keyed to it.
function esm.NewSetId()
  local id = storedMaxId
  for _, set in ipairs(state.sets) do
    if set.id > id then
      id = set.id
    end
  end
  return id + 1
end

-- === the store =============================================================================

-- The savedvariable carries real Lua values, so a set is stored as a table and nothing is
-- encoded. ids is an array of strings rather than a key set because the engine's serializer
-- type coerces an integer-looking table key on the way back, while it leaves a value alone.
local function toObject(set)
  local ids = {}
  for id in pairs(set.ids) do
    ids[#ids + 1] = tostring(id)
  end
  table.sort(ids)
  return { name = tostring(set.name or ""), ids = ids, saves = (set.saves == true) }
end

-- Tolerant on the way back: a boolean may return as a string or a number.
local function isTrue(value)
  return (value == true) or (value == "true") or (tonumber(value) == 1)
end

local function fromObject(id, body)
  local set = { id = id, name = tostring(body.name or ""), ids = {}, saves = isTrue(body.saves) }
  for _, extid in ipairs(body.ids or {}) do
    set.ids[tostring(extid)] = true
  end
  return set
end

-- writes is cumulative, so a value above 1 on the first load of a session is the proof that
-- the savedvariable survived the restart.
local function savedWrite()
  ---@diagnostic disable-next-line: undefined-global
  local existing = __ESM_STORE
  local data = {
    writes  = ((type(existing) == "table") and tonumber(existing.writes) or 0) + 1,
    active  = state.activeId,
    maxId   = storedMaxId,
    debug   = esm.debugLevel,
    enabled = state.enabled,
    sets    = {},
  }
  for _, set in ipairs(state.sets) do
    data.sets[set.id] = toObject(set)
    esm.Trace("saved write: set %d (%s), %d extension(s), individual saves %s",
      set.id, tostring(set.name), countIds(set), set.saves and "on" or "off")
  end
  ---@diagnostic disable-next-line: global-in-non-module
  __ESM_STORE = data
  esm.Debug("saved write (%s): writes=%d sets=%d active=%s maxId=%s",
    SAVED_NAME, data.writes, #state.sets, tostring(data.active), tostring(data.maxId))
end

-- Fills state from the savedvariable; false means the table was not there at all, which is the
-- normal case on an install that has never saved a set.
local function savedRead()
  ---@diagnostic disable-next-line: undefined-global
  local data = __ESM_STORE
  if type(data) ~= "table" then
    esm.Debug("saved read (%s): absent (%s) - nothing stored yet", SAVED_NAME, type(data))
    return false
  end

  state.sets = {}
  local maxId = math.floor(tonumber(data.maxId) or 0)

  -- The engine's serializer writes an integer-looking key back as a number, so the key's type
  -- is never trusted. id 0 is the Default set, so only a negative one is nonsense.
  for key, body in pairs(data.sets or {}) do
    local id = tonumber(key)
    if (id == nil) or (id < 0) or (type(body) ~= "table") then
      esm.Error("saved read: set key %s is unreadable", tostring(key))
    else
      id = math.floor(id)
      local set = fromObject(id, body)
      state.sets[#state.sets + 1] = set
      if id > maxId then
        maxId = id
      end
      esm.Trace("saved read: set %d (%s), %d extension(s)", id, tostring(set.name), countIds(set))
    end
  end
  table.sort(state.sets, function(a, b) return a.id < b.id end)

  storedMaxId = maxId
  state.activeId = tonumber(data.active)
  state.enabled = isTrue(data.enabled)
  if (type(data.debug) == "string") and (data.debug ~= "") then
    esm.debugLevel = data.debug
  end

  esm.Debug("saved read (%s): writes=%s sets=%d active=%s maxId=%d enabled=%s",
    SAVED_NAME, tostring(data.writes), #state.sets, tostring(state.activeId), storedMaxId,
    tostring(state.enabled))
  return true
end

function esm.Save()
  savedWrite()

  -- The engine's own flush of the UI data is what puts the store on disk. The cdef is
  -- void(void) and an argument to it raises, which is what made the savedvariable look dead.
  local ok, err = pcall(function() C.SaveUIUserData() end)
  if not ok then
    esm.Error("SaveUIUserData failed: %s", tostring(err))
  end

  esm.Debug("saved %d set(s), active=%s", #state.sets, tostring(state.activeId))
  return true
end

-- The master switch. While it is off the mod is inert: no savegame namespace, no page
-- marking and no lock on the vanilla extension list. Nothing stored is touched by it, so the
-- sets and the active-set record survive a switch off and come back on a switch on.
function esm.Enabled()
  return state.enabled == true
end

function esm.SetEnabled(flag)
  state.enabled = (flag == true)
  esm.Save()
  esm.Debug("extension sets %s", state.enabled and "enabled" or "disabled")
  return state.enabled
end

function esm.ActiveSetId()
  return state.activeId
end

function esm.SetActiveSetId(id)
  state.activeId = id
  esm.Save()
end

-- Where the sets are read from and written to, for the settings page.
function esm.Backend()
  return SAVED_NAME
end

-- The set id as it appears in a savegame filename: zero padded to 5 characters.
function esm.SaveTag(id)
  return string.format("%05d", tonumber(id) or 0)
end

-- Used for the default name of a captured set: "Set 1", "Set 2", ... - keyed off the id the
-- set is about to get, so the label and the id line up on a fresh install.
function esm.NextFreeName(prefix)
  local index = esm.NewSetId()
  while esm.FindSetByName(prefix .. " " .. index) do
    index = index + 1
  end
  return prefix .. " " .. index
end

function esm.DeleteSet(id)
  local set, index = esm.FindSet(id)
  if not index then
    return false
  end
  table.remove(state.sets, index)
  if state.activeId == id then
    state.activeId = nil
  end
  esm.Save()
  esm.Debug("deleted set %d (%s)", id, tostring(set.name))
  return true
end

function esm.SetDebugLevel(_, level)
  if level and level ~= "" then
    esm.debugLevel = tostring(level)
    esm.Debug("debug level set to %s", esm.debugLevel)
    esm.Save()
  end
end

local registered = false

local function init()
  savedRead()
  if not registered then
    registered = true
    RegisterEvent("ExtensionSetsManager.SetDebugLevel", esm.SetDebugLevel)
  end
  esm.Debug("store init: backend=%s debugLevel=%s sets=%d active=%s enabled=%s",
    SAVED_NAME, esm.debugLevel, #esm.Sets(), tostring(esm.ActiveSetId()),
    tostring(esm.Enabled()))
end

ESM_Loader.Register("extensions.extension_sets_manager.ui.esm_store", esm, init)

return esm
