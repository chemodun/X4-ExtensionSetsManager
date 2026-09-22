-- Extension Sets Manager - the extension model: reading the current setup, capturing it
-- into a set, and applying a set back onto the engine's extension settings.

local esm = ESM_Loader.Require("extensions.extension_sets_manager.ui.esm_store")

local sets = {}

-- Never disabled by a set, or the manager would vanish together with the set that turned it
-- off. Matched against the content.xml id and against the extension folder name, because the
-- same mod carries a bare id when installed manually and a ws_ id from the Workshop.
local PROTECTED = {
  ["extension_sets_manager"]      = true,
  ["kuertee_ui_extensions"]       = true,
  ["kuerteeuiextensionsandhud"]   = true,
  ["print_extension_list"]        = true,
  ["ws_3770927339"]               = true,
}

local function basename(path)
  return tostring(path or ""):match("([^/\\]+)[/\\]*$") or ""
end

function sets.IsProtected(extension)
  local id = string.lower(tostring(extension.id or ""))
  local folder = string.lower(basename(extension.location))
  return (PROTECTED[id] == true) or (PROTECTED[folder] == true)
end

-- Vanilla's own resolution: a pending setting wins, otherwise the extension's default.
local function isEnabled(extension, settings)
  local entry = settings[extension.index]
  if (entry ~= nil) and (entry.enabled ~= nil) then
    return entry.enabled
  end
  return extension.enabledbydefault
end

-- Returns the enabled-id map, the raw extension list, and the enabled/total counts.
function sets.CurrentState()
  local list = GetExtensionList()
  local settings = GetAllExtensionSettings()
  local state, enabled = {}, 0

  for _, extension in ipairs(list) do
    if isEnabled(extension, settings) then
      state[extension.id] = true
      enabled = enabled + 1
    end
  end

  esm.Trace("current state: %d of %d extension(s) enabled", enabled, #list)
  return state, list, enabled, #list
end

-- How much of a stored set is still installed: enabled count, and the installed total.
function sets.Counts(set)
  local list = GetExtensionList()
  local enabled = 0

  for _, extension in ipairs(list) do
    if (set.ids[extension.id] == true) or sets.IsProtected(extension) then
      enabled = enabled + 1
    end
  end

  return enabled, #list
end

-- id nil captures a brand new set; otherwise it rewrites both halves of that set, so this is
-- also how a set is renamed. saves nil leaves the individual-saves flag alone.
function sets.Capture(name, id, saves)
  local state = sets.CurrentState()
  local set = esm.FindSet(id)

  if set then
    set.name = name
    set.ids = state
  else
    -- An explicit id is honoured so the Default set can claim the reserved one; nil means the
    -- next free id, which is what every ordinary capture passes.
    set = { id = id or esm.NewSetId(), name = name, ids = state }
    table.insert(esm.Sets(), set)
  end
  if saves ~= nil then
    set.saves = (saves == true)
  end
  -- The Default set is the shared pool's set: it can never hold savegames of its own.
  if esm.IsDefaultSet(set.id) then
    set.saves = false
  end

  esm.Save()
  esm.Debug("captured set %d (%s), individual saves %s", set.id, tostring(name),
    set.saves and "on" or "off")
  return set
end

-- An extension the set says nothing about is disabled, so anything installed since the
-- capture stays off until the set is re-captured. With write false nothing is touched and the
-- count is what an apply would change, which is how the page measures drift.
local function walkState(ids, forceProtected, write)
  local list = GetExtensionList()
  local settings = GetAllExtensionSettings()
  local changed = 0

  for _, extension in ipairs(list) do
    local wanted = (ids[extension.id] == true) or (forceProtected and sets.IsProtected(extension))
    if isEnabled(extension, settings) ~= wanted then
      changed = changed + 1
      if write then
        SetExtensionSettings(extension.id, extension.personal, "enable", wanted)
        esm.Trace("write: %s -> %s", tostring(extension.id), tostring(wanted))
      end
    end
  end

  return changed
end

-- Writes the set onto the engine's pending extension settings, which is what the vanilla
-- list below the mod's table reads back. It does not make the set current - that is the
-- Apply button's job. The engine only reads content.xml at startup, so the setup itself
-- does not change until the game is restarted.
function sets.Apply(set)
  local changed = walkState(set.ids, true, true)
  esm.Debug("applied set %d (%s), %d extension(s) changed", set.id, tostring(set.name), changed)
  return changed
end

-- Puts a state map from sets.CurrentState back, exactly as it was. Protected extensions are
-- not forced here: a restore has to be able to land on the setup the page was entered with,
-- or it would leave a pending change of its own behind.
function sets.Restore(ids)
  local changed = walkState(ids, false, true)
  esm.Trace("restore: %d extension(s) put back", changed)
  return changed
end

-- How far the live setup has drifted from a set: the number of extensions an apply would
-- have to change. Zero means what the vanilla list shows below is exactly this set.
function sets.Deviation(set)
  return walkState(set.ids, true, false)
end

function sets.RestartPending()
  return HaveExtensionSettingsChanged()
end

ESM_Loader.Register("extensions.extension_sets_manager.ui.esm_sets", sets)

return sets
