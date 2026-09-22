-- Extension Sets Manager - the per-set savegame namespace, and the marking that makes it
-- visible on the save and load pages.
--
-- A set with individual saves on writes its manual slots as "00001_save_003" and sees only
-- its own. The translation is at the boundary: the engine holds the prefixed filename, every
-- vanilla menu keeps seeing the plain save_%03d shape it was written for, so slot layout,
-- empty slots, sorting and the default "#003" names all keep working untouched.
--
-- Proved by the Part B probe (see claude/mod-extension_sets_manager.md): the engine writes,
-- lists, loads and deletes a wholly off-scheme filename verbatim, and GetSaveList's filter is
-- a strict whitelist - so the filter is the namespace and another set's saves are hidden
-- without the mod hiding anything itself.
--
-- Quicksave and autosave are written by the engine under names no Lua call passes through
-- here; they cannot be redirected, only replaced, so they stay shared until that is built.
--
-- The marking is the second half of the file: the page title names the set in use, the
-- details panel gains a set line, every row says "<set>" or "Shared", and the start menu's
-- Continue row carries the mark of the save it would load. It only ever adds text to widgets
-- vanilla already built, and it is silent while no set is applied.

---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local C = ffi.C

local esm = ESM_Loader.Require("extensions.extension_sets_manager.ui.esm_store")

local saves = {}

-- Vanilla's manual save slots (helper.lua, Helper.validSaveFilenames).
local SLOTS = 10

-- gameoptions' own config.standardTextHeight, which no mod can reach: a savegame row's
-- second line sits at it and a two-line row is twice it plus a border.
local TEXT_HEIGHT = 19

local origGetSaveList
local origSaveGame
local origLoadGame

---@type table?
local optionsMenu
local origDisplaySavegameOptions
local origAddSavegameRow
local origCreateOptionsFrame
local origNameContinue
local menuHooked = false

-- Armed only for the duration of one displaySavegameOptions call.
local marking = false

local function T(id, ...)
  local text = tostring(ReadText(esm.PAGE, id))
  if select("#", ...) > 0 then
    return string.format(text, ...)
  end
  return text
end

local function colour(id)
  return ColorText[id] or ""
end

-- The set in use, whatever its individual-saves flag says. nil means the mod stays out of the
-- page entirely: with no set applied, or with the master switch off, the save list has to look
-- exactly like an unmodded one. Every redirection and every mark hangs off this one call.
local function activeSet()
  if not esm.Enabled() then
    return nil
  end
  return (esm.FindSet(esm.ActiveSetId()))
end

-- The prefix the active set writes, or nil when nothing is redirected at all: no active set,
-- the set is gone, or its individual-saves flag is off and it shares the common pool.
local function activePrefix()
  local set = activeSet()
  if (set == nil) or (not set.saves) then
    return nil
  end
  return esm.SaveTag(set.id) .. "_"
end

local function isSlotName(name)
  return (type(name) == "string") and (string.match(name, "^save_%d%d%d$") ~= nil)
end

local function isPrefixed(name)
  return string.match(name, "^%d%d%d%d%d_") ~= nil
end

-- Plain name as vanilla knows it -> the name on disk. Unchanged when nothing is redirected,
-- when the name is not a manual slot, or when it already carries a prefix, so it is safe to
-- apply twice.
function saves.ToReal(plain)
  local prefix = activePrefix()
  if (prefix == nil) or (not isSlotName(plain)) then
    return plain
  end
  return prefix .. plain
end

-- The name on disk -> what vanilla should see, or nil for an entry this set must not show:
-- another set's prefix, or the shared pool while this set keeps its own.
local function toPlain(real, prefix)
  if string.sub(real, 1, #prefix) == prefix then
    local plain = string.sub(real, #prefix + 1)
    return isSlotName(plain) and plain or nil
  end
  if isPrefixed(real) or isSlotName(real) then
    return nil
  end
  return real
end

local function widenFilter(filter, prefix)
  local wide = {}
  if type(filter) == "table" then
    for name in pairs(filter) do
      wide[name] = true
    end
  end
  for i = 1, SLOTS do
    wide[string.format("%ssave_%03d", prefix, i)] = true
  end
  return wide
end

-- The list is the only place the mod has to be exhaustive: everything downstream - the save
-- callback, the load callback, the delete button - takes its filename from an entry here.
local function wrappedGetSaveList(filter, ...)
  saves.EnsureHooked()

  local prefix = activePrefix()
  if prefix == nil then
    -- Logged as loudly as the filtered path: a silent pass-through is indistinguishable from
    -- a call that never reached the wrapper at all.
    local shared = origGetSaveList(filter, ...)
    esm.Trace("save list (shared): %d entr(ies) passed through", #shared)
    return shared
  end

  local list = origGetSaveList(widenFilter(filter, prefix), ...)
  local kept = {}
  for _, entry in ipairs(list) do
    local plain = toPlain(entry.filename, prefix)
    if plain then
      -- The prefix having been stripped is the whole test for "this one is the set's own".
      entry.esmOwned = (plain ~= entry.filename)
      entry.realfilename = entry.filename
      entry.filename = plain
      kept[#kept + 1] = entry
    end
  end

  esm.Trace("save list (%s): %d of %d entr(ies) kept", prefix, #kept, #list)
  return kept
end

-- Does this set already hold savegames of its own? Only the individual-saves flag writes under
-- a set's prefix, so this separates a set that once kept its own from one that never did. The
-- filter is a whitelist, so the ten slot names are the whole search space.
function saves.HasOwnSaves(setId)
  if (setId == nil) or (origGetSaveList == nil) then
    return false
  end
  local prefix = esm.SaveTag(setId) .. "_"
  for _, entry in ipairs(origGetSaveList(widenFilter(nil, prefix))) do
    if string.sub(entry.filename, 1, #prefix) == prefix then
      return true
    end
  end
  return false
end

-- Deletes every savegame a set holds under its own prefix. The engine keeps the prefixed name
-- verbatim, so the real name goes straight to C.DeleteSavegame - the menu's own delete
-- callback is the one that takes a plain name and is patched to translate it.
function saves.DeleteOwnSaves(setId)
  if (setId == nil) or (origGetSaveList == nil) then
    return 0
  end
  local prefix = esm.SaveTag(setId) .. "_"
  local removed = 0
  for _, entry in ipairs(origGetSaveList(widenFilter(nil, prefix))) do
    if string.sub(entry.filename, 1, #prefix) == prefix then
      C.DeleteSavegame(entry.filename)
      removed = removed + 1
      esm.Trace("delete save: %s", entry.filename)
    end
  end
  if removed > 0 then
    C.ReloadSaveList()
    if optionsMenu ~= nil then
      optionsMenu.savegames = nil
      optionsMenu.autoReloadSave = nil
    end
  end
  esm.Debug("delete: %d savegame(s) of set %d removed", removed, setId)
  return removed
end

local function wrappedSaveGame(filename, ...)
  local real = saves.ToReal(filename)
  if real ~= filename then
    esm.Debug("save: %s -> %s", tostring(filename), real)
  end
  return origSaveGame(real, ...)
end

local function wrappedLoadGame(filename, ...)
  local real = saves.ToReal(filename)
  if real ~= filename then
    esm.Debug("load: %s -> %s", tostring(filename), real)
  end
  return origLoadGame(real, ...)
end

---------- Marking the save and load pages ----------

-- The set name, or "Shared" for anything still in the common pool - which is every visible
-- save while the active set has individual saves off. nil means there is nothing to say.
local function markText(owned)
  local set = activeSet()
  if set == nil then
    return nil
  end
  if owned then
    return colour("text_positive") .. tostring(set.name) .. "\27X"
  end
  return colour("text_inactive") .. T(123) .. "\27X"
end

-- An online save lives outside the namespace entirely, so it is left unmarked.
local function markForSave(savegame)
  if (type(savegame) ~= "table") or savegame.isonline or savegame.isonlinesavefilename then
    return nil
  end
  return markText(savegame.esmOwned == true)
end

-- Wherever the mark is appended to someone else's text it has to say what it is; the details
-- panel is the exception, because there the same label is already the row caption.
local function labelled(mark)
  if mark == nil then
    return nil
  end
  return colour("text_inactive") .. T(124) .. ReadText(1001, 120) .. " \27X" .. mark
end

-- The start menu's Continue row is named from the first non-online entry of menu.savegames, so
-- it takes the same mark its row on the load page does. The entry is found the way nameContinue
-- finds it rather than parsed back out of the string it returned.
local function wrappedNameContinue(...)
  local name = origNameContinue(...)
  local list = optionsMenu and optionsMenu.isStartmenu and optionsMenu.savegames
  if type(list) ~= "table" then
    -- In game, or nameContinue fell back to menu.autoReloadSave - a string already marked here.
    return name
  end

  local entry
  for _, save in ipairs(list) do
    if not save.isonline then
      entry = save
      break
    end
  end

  local mark = entry and labelled(markForSave(entry))
  if mark == nil then
    return name
  end
  return name .. colour("text_inactive") .. " · \27X" .. mark
end

-- The mark goes on the row's second line, the one vanilla uses for "modified": that line is
-- never truncated, so it takes colour and a full set name. A row that has no second line yet
-- gets one, plus the height vanilla would have given a two-line row.
local function stampRow(ftable, savegame)
  local mark = labelled(markForSave(savegame))
  if mark == nil then
    return
  end
  local row = ftable.rows[#ftable.rows]
  if (row == nil) or (row.rowdata ~= savegame) then
    return
  end
  local cell = row[3]
  if (cell == nil) or (cell.type ~= "icon") then
    return
  end

  local existing = cell.properties.text2.text
  if type(existing) ~= "string" then
    existing = ""
  end
  if existing == "" then
    cell.properties.height = 2 * Helper.scaleY(TEXT_HEIGHT) + Helper.borderSize
    cell.properties.text2.font = row[4].properties.font
    cell.properties.text2.fontsize = row[4].properties.fontsize
    cell.properties.text2.x = cell.properties.text.x
    cell.properties.text2.y = TEXT_HEIGHT
    cell.properties.text2.scaling = true
  else
    existing = existing .. colour("text_inactive") .. " · \27X"
  end
  cell.properties.text2.text = existing .. mark
end

-- What the selected row is worth saying. An empty slot answers where a save written into it
-- would go, which is the one thing the save page cannot show otherwise.
local function selectedMark()
  local selected = optionsMenu and optionsMenu.selectedOption
  if type(selected) ~= "table" then
    return ""
  end
  if selected.empty then
    local set = activeSet()
    return (set ~= nil) and (markText(set.saves == true) or "") or ""
  end
  if selected.filename == nil then
    return ""
  end
  return markForSave(selected) or ""
end

local function findTable(frame, tabOrder)
  for _, item in ipairs(frame.content) do
    if (item.type == "table") and (item.properties.tabOrder == tabOrder) then
      return item
    end
  end
  return nil
end

-- The details panel's own value style, taken from one of vanilla's own rows rather than
-- guessed: the menu's fonts live in a config table no mod can reach.
local function valueTextStyle(infotable)
  for _, row in ipairs(infotable.rows) do
    local cell = row[3]
    if (cell ~= nil) and (cell.type == "text") and (cell.properties.halign == "right") then
      return cell.properties.font, cell.properties.fontsize
    end
  end
  return nil, nil
end

-- "Load Game · Extension Set: Set 2". The name is green while the set keeps its own saves,
-- plain while it shares the pool, which is the same distinction the rows below draw.
local function markTitle(frame, set)
  local titletable = findTable(frame, 3)
  if titletable == nil then
    return
  end
  for _, row in ipairs(titletable.rows) do
    if (type(row.rowdata) == "table") and (row.rowdata.titlerow == "title") then
      local cell = row[2]
      if (cell ~= nil) and (type(cell.properties.text) == "string") then
        cell.properties.text = cell.properties.text
            .. colour("text_inactive") .. " · " .. T(124) .. ReadText(1001, 120) .. " \27X"
            .. colour(set.saves and "text_positive" or "text_normal") .. tostring(set.name) .. "\27X"
      end
      return
    end
  end
end

-- The blank spacer row at the top of the details panel becomes the set line. Reusing it keeps
-- vanilla's own layout arithmetic untouched - nothing is inserted, nothing moves.
local function markDetails(frame)
  local infotable = findTable(frame, 2)
  if infotable == nil then
    return
  end
  local row = infotable.rows[1]
  if (row == nil) or (row[1].type ~= "text") or (row[1].properties.text ~= " ") then
    return
  end

  local font, fontsize = valueTextStyle(infotable)
  row[1]:setColSpan(2)
  row[1].properties.text = T(124) .. ReadText(1001, 120)
  row[3]:setColSpan(2):createText(selectedMark, { font = font, fontsize = fontsize, halign = "right" })
end

local function markFrame(frame)
  local set = activeSet()
  if set == nil then
    return
  end
  markTitle(frame, set)
  markDetails(frame)
end

-- The marks have to be in place before the frame is displayed, and display is the last thing
-- displaySavegameOptions does - so the frame's own display is shadowed for one call.
local function wrapFrame(frame)
  local origDisplay = frame.display

  frame.display = function(self, ...)
    -- One shot: a second display of the same frame must not append the title twice.
    self.display = origDisplay
    local ok, err = pcall(markFrame, self)
    if not ok then
      esm.Error("save page marking failed: %s", tostring(err))
    end
    return origDisplay(self, ...)
  end

  return frame
end

local function onAddSavegameRow(ftable, savegame, ...)
  local height = origAddSavegameRow(ftable, savegame, ...)
  if not marking then
    return height
  end

  local ok, err = pcall(stampRow, ftable, savegame)
  if not ok then
    esm.Error("save row marking failed: %s", tostring(err))
    return height
  end

  -- A row that gained its second line here is taller than the height vanilla measured.
  local row = ftable.rows[#ftable.rows]
  return (row ~= nil) and row:getHeight() or height
end

local function onDisplaySavegameOptions(...)
  if not origDisplaySavegameOptions then
    return
  end

  marking = true
  local ok, err = pcall(origDisplaySavegameOptions, ...)
  marking = false
  if not ok then
    esm.Error("displaySavegameOptions failed: %s", tostring(err))
  end
end

-- callbackDeleteSave is reached with the plain name the list handed out, so without this
-- C.DeleteSavegame would remove a legacy shared save_NNN the player still has. Its return
-- value cannot be used as a check: the probe got true for a filename never written.
function saves.EnsureHooked()
  if menuHooked then
    return
  end
  optionsMenu = Helper.getMenu("OptionsMenu")
  if not (optionsMenu and optionsMenu.callbackDeleteSave and optionsMenu.displaySavegameOptions
        and optionsMenu.addSavegameRow and optionsMenu.createOptionsFrame
        and optionsMenu.nameContinue) then
    return
  end

  local origDeleteSave = optionsMenu.callbackDeleteSave
  optionsMenu.callbackDeleteSave = function(filename, ...)
    local real = saves.ToReal(filename)
    if real ~= filename then
      esm.Debug("delete: %s -> %s", tostring(filename), real)
    end
    return origDeleteSave(real, ...)
  end

  origDisplaySavegameOptions = optionsMenu.displaySavegameOptions
  origAddSavegameRow = optionsMenu.addSavegameRow
  origCreateOptionsFrame = optionsMenu.createOptionsFrame
  origNameContinue = optionsMenu.nameContinue

  optionsMenu.displaySavegameOptions = onDisplaySavegameOptions
  optionsMenu.addSavegameRow = onAddSavegameRow
  optionsMenu.nameContinue = wrappedNameContinue
  -- esm_page wraps this too; each wrapper calls the one it captured, so they chain.
  optionsMenu.createOptionsFrame = function(...)
    local frame = origCreateOptionsFrame(...)
    if marking and frame then
      return wrapFrame(frame)
    end
    return frame
  end

  menuHooked = true
  esm.Debug("saves: patched callbackDeleteSave, displaySavegameOptions, addSavegameRow, nameContinue and createOptionsFrame")
end

-- The last prefix vanilla's cached list was built under.
local lastPrefix

-- Vanilla reads the save list once and keeps it for config.saveReloadInterval (60s), and the
-- start menu's Continue row is simply its newest non-online entry. So a set applied mid-session
-- leaves that row - and anything else reading menu.savegames - pointing into the namespace the
-- player just left. Dropping the cache makes onUpdate refill it through the wrapper and rebuild
-- the main menu from the result, which is what makes Continue follow the namespace at all.
function saves.Sync()
  local prefix = activePrefix()
  if prefix == lastPrefix then
    return
  end
  esm.Debug("namespace: %s -> %s, dropping the cached save list",
    tostring(lastPrefix), tostring(prefix))
  lastPrefix = prefix

  saves.EnsureHooked()
  if optionsMenu == nil then
    return
  end
  optionsMenu.savegames = nil
  -- nameContinue falls back to this cached string while the list is away, so it has to go too.
  optionsMenu.autoReloadSave = nil
end

local function init()
  if origGetSaveList == nil then
    origGetSaveList = GetSaveList
    origSaveGame = SaveGame
    origLoadGame = LoadGame
    ---@diagnostic disable-next-line: lowercase-global
    GetSaveList = wrappedGetSaveList
    ---@diagnostic disable-next-line: lowercase-global
    SaveGame = wrappedSaveGame
    ---@diagnostic disable-next-line: lowercase-global
    LoadGame = wrappedLoadGame
  end
  saves.EnsureHooked()
  lastPrefix = activePrefix()
  esm.Debug("saves init: prefix=%s", tostring(lastPrefix))
end

ESM_Loader.Register("extensions.extension_sets_manager.ui.esm_saves", saves, init)

return saves
