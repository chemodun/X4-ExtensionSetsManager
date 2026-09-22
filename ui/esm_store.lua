-- Extension Sets Manager - identity, logging and the persistent store.
-- Everything here has to work in the start menu, where player.entity does not exist. Two
-- backends are implemented: the __ESM_STORE savedvariable (uidata.xml) and one userdata.xml
-- key per set. The savedvariable is the store; USE_USERDATA switches back.
--
-- A set is identified by a numeric id, not by its name: the id is the "set_<id>" key suffix,
-- it is what "active" points at, and it is what any per-set data hangs off. The name is a
-- label and is free to change.

---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local C = ffi.C

local DEFAULT_DEBUG_LEVEL = "trace"

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

-- Backend switch (Chem, 2026-09-22). The __ESM_STORE savedvariable was proved to survive a
-- restart from the start menu, and C.GetUserData lowercases every value it returns, so the
-- savedvariable is the store. The userdata.xml path stays behind this flag.
local USE_USERDATA = false

local SAVED_NAME = "__ESM_STORE"

local KEY_PREFIX = "extension_sets_manager_"
-- Highest set id ever used, so it is also the bound a load scans to. Named "count" because
-- that is what it held before ids existed, and it still equals the set count until a delete.
local KEY_MAX_ID = KEY_PREFIX .. "count"
local KEY_ACTIVE = KEY_PREFIX .. "active"
local KEY_DEBUG  = KEY_PREFIX .. "debug"
-- The master switch. Off by default: an install that has never been touched has to behave
-- exactly like vanilla.
local KEY_ENABLED = KEY_PREFIX .. "enabled"
-- Ids of the sets that keep their own savegames, "-" joined. One key beside the set bodies
-- rather than a field inside them, so a store written before the flag existed still loads.
local KEY_SAVES  = KEY_PREFIX .. "saves"

-- A set body outgrows one userdata value long before the player runs out of extensions, and
-- the engine's ceiling on a single value is undocumented. 1016 characters is measured to
-- round-trip (the 60-extension set that sat in userdata.xml before this existed) against a
-- longest vanilla value of 49, so a value is sliced at 1000 and continued in "_2", "_3", ...
-- keys. A body that fits stays in one key, exactly as before.
local CHUNK_SIZE = 1000

local state = { sets = {}, enabled = false }
local storedMaxId = 0
-- [setId] = how many keys that set currently occupies in the file.
local storedChunks = {}

local function write(message, ...)
  if select("#", ...) > 0 then
    message = string.format(message, ...)
  end
  DebugError("ExtensionSetsManager: " .. message)
end

function esm.Error(message, ...) write(message, ...) end
function esm.Debug(message, ...) if esm.debugLevel ~= "none" then write(message, ...) end end
function esm.Trace(message, ...) if esm.debugLevel == "trace" then write(message, ...) end end

-- userdata.xml is the game's own progress file, so nothing but [A-Za-z0-9_] and the escape
-- character ever reaches it: no XML metacharacter can arrive from a set name, and "-" stays
-- free as the field separator.
local function encodeChar(char)
  return string.format("%%%02X", string.byte(char))
end

local function decodeHex(hex)
  return string.char(tonumber(hex, 16) or 0)
end

local function encode(text)
  local encoded = tostring(text or ""):gsub("[^A-Za-z0-9_]", encodeChar)
  return encoded
end

local function decode(text)
  local decoded = tostring(text or ""):gsub("%%(%x%x)", decodeHex)
  return decoded
end

-- Note: C.GetUserData returns the stored value lowercased, so a name only keeps its capitals
-- in the savedvariable backend.
local function readKey(name)
  local ok, value = pcall(function() return ffi.string(C.GetUserData(name)) end)
  if not ok then
    esm.Error("GetUserData(%s) failed: %s", name, tostring(value))
    return ""
  end
  value = tostring(value or "")
  esm.Trace("userdata read: %s = %d char(s)", name, #value)
  return value
end

local function writeKey(name, value)
  local ok, err = pcall(function() C.SetUserData(name, value) end)
  if not ok then
    esm.Error("SetUserData(%s) failed: %s", name, tostring(err))
    return false
  end
  return true
end

local function chunkKey(baseKey, index)
  if index == 1 then
    return baseKey
  end
  return baseKey .. "_" .. index
end

-- Returns the number of keys written.
local function writeValue(baseKey, value)
  local count = math.max(1, math.ceil(#value / CHUNK_SIZE))
  for index = 1, count do
    writeKey(chunkKey(baseKey, index), string.sub(value, (index - 1) * CHUNK_SIZE + 1, index * CHUNK_SIZE))
  end
  return count
end

-- A short chunk is the last one; a full-length chunk means there may be another.
local function readValue(baseKey)
  local parts = {}
  local index = 1
  while true do
    local chunk = readKey(chunkKey(baseKey, index))
    if chunk == "" then
      break
    end
    parts[#parts + 1] = chunk
    if #chunk < CHUNK_SIZE then
      break
    end
    index = index + 1
  end
  return table.concat(parts), #parts
end

local function blankChunks(baseKey, from, to)
  for index = from, to do
    writeKey(chunkKey(baseKey, index), "")
  end
end

local function countIds(set)
  local count = 0
  for _ in pairs(set.ids) do
    count = count + 1
  end
  return count
end

-- "<name>-<enabledId>-<enabledId>..."; a set with nothing enabled is just the name. The set's
-- own id is the key suffix, so it is not repeated in the value.
local function serialize(set)
  local parts = { encode(set.name) }
  for id in pairs(set.ids) do
    parts[#parts + 1] = encode(id)
  end
  return table.concat(parts, "-")
end

local function deserialize(id, value)
  local parts = {}
  for part in string.gmatch(value, "[^-]+") do
    parts[#parts + 1] = part
  end
  if #parts == 0 then
    return nil
  end
  local set = { id = id, name = decode(parts[1]), ids = {} }
  for index = 2, #parts do
    set.ids[decode(parts[index])] = true
  end
  return set
end

-- The individual-saves flag lives outside the set bodies: "1-3" means sets 1 and 3 keep
-- their own savegames.
local function serializeSaves()
  local parts = {}
  for _, set in ipairs(state.sets) do
    if set.saves then
      parts[#parts + 1] = tostring(set.id)
    end
  end
  return table.concat(parts, "-")
end

-- only, when given, limits the sweep to the sets that came back in the packed form; an object
-- body carries its own flag.
local function applySaves(value, only)
  local wanted = {}
  for part in string.gmatch(tostring(value or ""), "%d+") do
    wanted[tonumber(part)] = true
  end
  for _, set in ipairs(state.sets) do
    if (only == nil) or only[set.id] then
      set.saves = (wanted[set.id] == true)
    end
  end
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

-- === savedvariable backend =================================================================

-- The savedvariable carries real Lua values, so a set is stored as a table: nothing is encoded
-- and nothing is chunked, and only the userdata.xml backend still needs the packed string.
-- ids is an array rather than a key set because the engine's serializer type coerces a table
-- key on the way back, while it leaves a value alone.
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
    writes = ((type(existing) == "table") and tonumber(existing.writes) or 0) + 1,
    active = state.activeId,
    maxId  = storedMaxId,
    debug  = esm.debugLevel,
    enabled = state.enabled,
    saves  = serializeSaves(),
    sets   = {},
    legacy = {},
  }
  for _, set in ipairs(state.sets) do
    data.sets[set.id] = toObject(set)
    -- The packed string as well, as the fallback while a two-level nested table inside a
    -- savedvariable is unproven. It and data.saves go once a run confirms the object form.
    data.legacy[set.id] = serialize(set)
    esm.Trace("saved write: set %d (%s), %d extension(s), individual saves %s",
      set.id, tostring(set.name), countIds(set), set.saves and "on" or "off")
  end
  ---@diagnostic disable-next-line: global-in-non-module
  __ESM_STORE = data
  esm.Debug("saved write (%s): writes=%d sets=%d active=%s maxId=%s saves=%s",
    SAVED_NAME, data.writes, #state.sets, tostring(data.active), tostring(data.maxId),
    (data.saves ~= "") and data.saves or "none")
end

-- Fills state from the savedvariable; false means the table was not there at all, which is
-- what lets a first run after the backend switch still pick the sets out of userdata.xml.
local function savedRead()
  ---@diagnostic disable-next-line: undefined-global
  local data = __ESM_STORE
  if type(data) ~= "table" then
    esm.Debug("saved read (%s): absent (%s) - savedvariable did not come back", SAVED_NAME, type(data))
    return false
  end

  state.sets = {}
  storedChunks = {}
  local maxId = math.floor(tonumber(data.maxId) or 0)
  local seen = {}
  local packed = {}

  -- The engine's serializer writes an integer-looking key back as a number, so the key's type
  -- is never trusted. A body is the object form when it is a table and the packed string
  -- otherwise, which is also how a store written before this format still loads.
  local function take(key, body, source)
    local id = tonumber(key)
    if id == nil then
      return
    end
    id = math.floor(id)
    -- id 0 is the Default set, so only a negative one is nonsense.
    if (id < 0) or seen[id] then
      return
    end
    local set
    if type(body) == "table" then
      set = fromObject(id, body)
    else
      set = deserialize(id, tostring(body))
      packed[id] = true
    end
    if set == nil then
      esm.Error("saved read: set key %s is unreadable", tostring(key))
      return
    end
    seen[id] = true
    state.sets[#state.sets + 1] = set
    if id > maxId then
      maxId = id
    end
    esm.Trace("saved read (%s): set %d (%s), %d extension(s)",
      source, id, tostring(set.name), countIds(set))
  end

  for key, body in pairs(data.sets or {}) do
    take(key, body, "object")
  end
  for key, body in pairs(data.legacy or {}) do
    take(key, body, "legacy")
  end
  table.sort(state.sets, function(a, b) return a.id < b.id end)
  -- Only a set that came back packed needs the separate saves list; an object carries its own.
  applySaves(data.saves, packed)

  storedMaxId = maxId
  state.activeId = tonumber(data.active)
  state.enabled = isTrue(data.enabled)
  if (type(data.debug) == "string") and (data.debug ~= "") then
    esm.debugLevel = data.debug
  end

  esm.Debug("saved read (%s): writes=%s sets=%d active=%s maxId=%d saves=%s enabled=%s",
    SAVED_NAME, tostring(data.writes), #state.sets, tostring(state.activeId), storedMaxId,
    serializeSaves(), tostring(state.enabled))
  return true
end

-- === userdata.xml backend ==================================================================

local function userDataWrite()
  local used = {}

  for _, set in ipairs(state.sets) do
    if set.id > storedMaxId then
      storedMaxId = set.id
    end
    local baseKey = KEY_PREFIX .. "set_" .. set.id
    local count = writeValue(baseKey, serialize(set))
    -- A set that shrank leaves continuation keys behind it.
    blankChunks(baseKey, count + 1, storedChunks[set.id] or 0)
    used[set.id] = count
  end
  -- A deleted set leaves a gap; blank every key it held.
  for id, count in pairs(storedChunks) do
    if used[id] == nil then
      blankChunks(KEY_PREFIX .. "set_" .. id, 1, count)
    end
  end
  storedChunks = used

  writeKey(KEY_MAX_ID, tostring(storedMaxId))
  writeKey(KEY_ACTIVE, state.activeId and ("s" .. state.activeId) or "")
  writeKey(KEY_SAVES, serializeSaves())
  writeKey(KEY_DEBUG, esm.debugLevel)
  writeKey(KEY_ENABLED, state.enabled and "1" or "0")
end

-- "s<id>". Anything else is a set name from before ids existed and is resolved once, here.
local function readActiveId(value)
  local id = string.match(value, "^s(%d+)$")
  if id then
    return tonumber(id)
  end
  local set = esm.FindSetByName(decode(value))
  return set and set.id or nil
end

local function userDataRead()
  local maxId = math.floor(tonumber(readKey(KEY_MAX_ID)) or 0)
  state.sets = {}
  storedChunks = {}

  for id = DEFAULT_SET_ID, maxId do
    local value, count = readValue(KEY_PREFIX .. "set_" .. id)
    local set = deserialize(id, value)
    if set then
      state.sets[#state.sets + 1] = set
      storedChunks[id] = count
      esm.Trace("userdata read: set %d (%s) over %d key(s), %d extension(s)",
        id, tostring(set.name), count, countIds(set))
    end
  end
  storedMaxId = maxId

  state.activeId = readActiveId(readKey(KEY_ACTIVE))
  applySaves(readKey(KEY_SAVES))
  state.enabled = (readKey(KEY_ENABLED) == "1")

  local level = readKey(KEY_DEBUG)
  if level ~= "" then
    esm.debugLevel = level
  end

  esm.Debug("userdata read: sets=%d active=%s maxId=%d enabled=%s",
    #state.sets, tostring(state.activeId), storedMaxId, tostring(state.enabled))
end

function esm.Save()
  if USE_USERDATA then
    userDataWrite()
  end
  savedWrite()

  -- The engine's own flush of the UI data is what puts either store on disk. The cdef is
  -- void(void) and an argument to it raises, which is what made the savedvariable look dead.
  local ok, err = pcall(function() C.SaveUIUserData() end)
  if not ok then
    esm.Error("SaveUIUserData failed: %s", tostring(err))
  end

  esm.Debug("saved %d set(s), active=%s", #state.sets, tostring(state.activeId))
  return true
end

local function load()
  if USE_USERDATA then
    userDataRead()
    return
  end
  if not savedRead() then
    esm.Debug("savedvariable empty - reading userdata.xml once to migrate")
    userDataRead()
  end
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
  load()
  if not registered then
    registered = true
    RegisterEvent("ExtensionSetsManager.SetDebugLevel", esm.SetDebugLevel)
  end
  esm.Debug("store init: backend=%s debugLevel=%s sets=%d active=%s enabled=%s",
    USE_USERDATA and "userdata.xml" or SAVED_NAME, esm.debugLevel, #esm.Sets(),
    tostring(esm.ActiveSetId()), tostring(esm.Enabled()))
end

ESM_Loader.Register("extensions.extension_sets_manager.ui.esm_store", esm, init)

return esm
