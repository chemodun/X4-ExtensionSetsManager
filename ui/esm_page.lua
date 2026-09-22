-- Extension Sets Manager - the mod's own table at the top of the vanilla Extensions page.
--
-- menu.displayExtensions is a hard-coded submenuHandler branch, not an optionDefinitions
-- page, and UIX registers no callback anywhere inside it, so the only way in is a
-- monkey-patch: while displayExtensions runs, the frame's addTable is shadowed so the mod's
-- table is built just above vanilla's 7-column option table, which is then shifted down and
-- shortened by the height taken.
--
-- Frame instances reach addTable through __index on widgetPrototypes.frame, so assigning it
-- on the instance shadows it for that frame only.
local esm   = ESM_Loader.Require("extensions.extension_sets_manager.ui.esm_store")
local sets  = ESM_Loader.Require("extensions.extension_sets_manager.ui.esm_sets")
local saves = ESM_Loader.Require("extensions.extension_sets_manager.ui.esm_saves")

local page = {}

local optionsMenu
local origDisplayExtensions
local origCreateOptionsFrame
local origSubmenuHandler
local origCleanup
local origOnCloseElement
local origExtensionDefaults
local origSettingEnabled

-- Disarms the exit guard for the one exit the player has just agreed to, so the re-issued
-- navigation runs through the ordinary leave path instead of asking a second time.
local exitApproved = false

-- The pending extension setup as it stood when the mod first changed it. A preview is only
-- ever on loan: leaving the Extensions page puts this back. Apply clears it, so the applied
-- setup becomes the baseline the next preview is taken against.
local preview

-- Armed only for the duration of one displayExtensions call.
local injecting = false
local injected = false

-- "select" shows the dropdown; "create" and "edit" swap in an edit box. Picking a name in
-- the dropdown writes that set's extension states straight away, so the vanilla list below
-- shows them, but the set only becomes the current one once Apply is pressed.
-- Sets are tracked by their numeric id throughout; the name is only ever a caption.
local mode = "select"
local selectedId
local editName = ""
local editId
-- The pending individual-saves flag: editable in both create and edit mode, on for a new set.
local editSaves = true
-- Edit mode offers the other half instead: delete this set's own savegames along with the set.
-- It is an action, not a setting, so it starts off every time an edit begins.
local editDeleteSaves = false
-- The extension setup as it stood when Edit or New was pressed. Outside edit mode the vanilla
-- list is locked, so an edit is the only way the states can move - and Cancel puts them back.
local editBaseline

local function T(id, ...)
  local text = tostring(ReadText(esm.PAGE, id))
  if select("#", ...) > 0 then
    return string.format(text, ...)
  end
  return text
end

-- The page's own option rows are config.standardTextProperties - the outlined face at size 10,
-- offset 5/2. config is a local of gameoptions.lua, so the values are repeated here.
local VANILLA_FONT_SIZE = 10
local VANILLA_TEXT_OFFSET_X = 5
local VANILLA_TEXT_OFFSET_Y = 2
-- The block title sits between a vanilla option label (10) and the page header (13). At 10 it
-- measured identical to "Protected UI Mode" but read shorter, because its caption has no
-- ascender taller than a capital while that one has two.
local TITLE_FONT_SIZE = 12
-- Vanilla's own question frame: the layer it clears, its header row and its back arrow.
local VANILLA_OPTIONS_LAYER = 4
local VANILLA_HEADER_FONT_SIZE = 13
local VANILLA_HEADER_TEXT_HEIGHT = 34
local VANILLA_BACK_ARROW = "table_arrow_inv_left"
local VANILLA_BACK_ARROW_OFFSET_X = 3
-- menu.currentOption while the mod's own dialog is up: any value vanilla does not know.
local CHOICE_OPTION = "esm_choice"
local SETTINGS_OPTION = "esm_settings"

-- A label that matches the vanilla rows below it; the title is bold and one step larger.
local function createRowText(cell, text, bold)
  cell:createText(text, {
    font = bold and Helper.standardFontBoldOutlined or Helper.standardFontOutlined,
    fontsize = bold and TITLE_FONT_SIZE or VANILLA_FONT_SIZE,
    x = VANILLA_TEXT_OFFSET_X,
    y = VANILLA_TEXT_OFFSET_Y,
  })
  return cell
end

-- A checkbox has no halign, so a square one is centred by its own x offset, in the pre-scaled
-- units scaling = false pairs with. getColSpanWidth only answers once addRow has finalised the
-- column widths, which it does on the row this cell belongs to.
local function createCenteredCheckBox(cell, checked, properties)
  local size = Helper.scaleX(Helper.standardButtonHeight)
  properties.width = size
  properties.height = size
  properties.scaling = false
  cell:createCheckBox(checked, properties)
  cell.properties.x = math.max(0, math.floor((cell:getColSpanWidth() - size) / 2))
  return cell
end

-- Vanilla caches both the settings snapshot its list renders from and the "restart required"
-- flag, and refreshes the pair in every one of its own toggle callbacks
-- (gameoptions.lua:8148). Anything the mod writes has to do the same or the page keeps
-- showing the state from before the write: displayExtensions re-reads the snapshot on a full
-- render, but the warning is a live callback over a flag that only recomputes when nil.
local function refreshVanillaCaches()
  if optionsMenu then
    optionsMenu.extensionSettings = GetAllExtensionSettings()
    optionsMenu.extensionSettingsChanged = nil
  end
end

-- While the feature is on, the vanilla extension list is read-only: a state change has to go
-- through a set, so it is only unlocked while one is being created or edited.
local function locked()
  return esm.Enabled() and (mode == "select")
end

local function showExtensionsPage()
  if optionsMenu then
    optionsMenu.userQuestion = nil
    refreshVanillaCaches()
    esm.Trace("re-render extensions page")
    optionsMenu.submenuHandler("extensions")
  end
end

-- A page of the mod's own, built as vanilla's question dialog (gameoptions.lua:12716): the
-- header carries the title and a back arrow, the rows are the caller's. currentOption is the
-- mod's own, so a row select falls past vanilla's chain to its generic "rowdata carries a
-- callback" branch (gameoptions.lua:13574); userQuestion is still set, because that is what
-- puts the title in the header and what sends the back arrow and Escape to negCallback instead
-- of popping the history one page too far.
local function ownPage(option, title, onBack)
  Helper.clearDataForRefresh(optionsMenu, VANILLA_OPTIONS_LAYER)
  optionsMenu.selectedOption = nil
  ---@diagnostic disable-next-line: assign-type-mismatch
  optionsMenu.currentOption = option
  ---@diagnostic disable-next-line: assign-type-mismatch
  optionsMenu.userQuestion = { question = title, negCallback = onBack }

  local frame = optionsMenu.createOptionsFrame()
  local ftable = frame:addTable(7, {
    tabOrder = 1,
    x = optionsMenu.table.x,
    y = optionsMenu.table.y,
    width = optionsMenu.table.width,
    maxVisibleHeight = optionsMenu.table.height,
  })
  ftable:setColWidth(1, optionsMenu.table.arrowColumnWidth, false)

  local titleRow = ftable:addRow({}, { fixed = true })
  titleRow[1]:setBackgroundColSpan(2)
  local backButton = titleRow[1]:createButton({ height = VANILLA_HEADER_TEXT_HEIGHT })
  backButton:setIcon(VANILLA_BACK_ARROW, { x = VANILLA_BACK_ARROW_OFFSET_X })
  titleRow[1].handlers.onClick = onBack
  titleRow[2]:setColSpan(6):createText(optionsMenu.nameUserQuestion, {
    font = Helper.standardFontBoldOutlined,
    fontsize = VANILLA_HEADER_FONT_SIZE,
    x = VANILLA_TEXT_OFFSET_X,
    y = 6,
    minRowHeight = VANILLA_HEADER_TEXT_HEIGHT,
    titleColor = Color["row_title"],
  })

  return frame, ftable
end

-- Vanilla's question dialog answers yes or no; this is the same frame with a row per answer,
-- for a question that has three.
local function displayChoice(question, answers, onBack)
  local frame, ftable = ownPage(CHOICE_OPTION, question, onBack)

  for _, answer in ipairs(answers) do
    local row = ftable:addRow({ callback = answer.callback }, {})
    createRowText(row[2]:setColSpan(6), answer.text)
  end

  esm.Trace("choice: %d answer(s) offered", #answers)
  frame:display()
end

-- Log verbosity, in the order the dropdown offers it.
local DEBUG_LEVELS = {
  { id = "none", textid = 1001 },
  { id = "debug", textid = 132 },
  { id = "trace", textid = 133 },
}

-- The mod has no Options page - none of that machinery runs in the main menu - so its own
-- settings sit behind the "..." button of its title row, where vanilla puts an extension's.
local function displaySettings()
  local frame, ftable = ownPage(SETTINGS_OPTION,
    T(1) .. " - " .. ReadText(1001, 2679), showExtensionsPage)

  local options = {}
  for _, level in ipairs(DEBUG_LEVELS) do
    options[#options + 1] = { id = level.id, text = T(level.textid), icon = "", displayremoveoption = false }
  end

  local levelRow = ftable:addRow(true, {})
  createRowText(levelRow[2]:setColSpan(3), T(131))
  levelRow[5]:setColSpan(2):createDropDown(options, {
    startOption = esm.debugLevel,
    mouseOverText = T(134),
  })
  levelRow[5].handlers.onDropDownConfirmed = function(_, id)
    esm.SetDebugLevel(nil, id)
    displaySettings()
  end

  -- What the store and the save redirection are actually doing right now: the numbers a log
  -- read would otherwise have to be opened for.
  local active = esm.FindSet(esm.ActiveSetId())
  local prefix = (active and active.saves) and (esm.SaveTag(active.id) .. "_") or T(1001)
  local info = {
    { T(135), esm.Backend() },
    { T(120), tostring(#esm.Sets()) },
    { T(136), prefix },
    { T(1005), ReadText(1001, sets.RestartPending() and 2617 or 2618) },
  }
  for _, line in ipairs(info) do
    local row = ftable:addRow(false, {})
    createRowText(row[2]:setColSpan(3), line[1])
    createRowText(row[5]:setColSpan(2), line[2])
  end

  esm.Trace("settings page: level=%s backend=%s prefix=%s",
    tostring(esm.debugLevel), tostring(esm.Backend()), tostring(prefix))
  frame:display()
end

-- With the feature on there is always at least one set: whatever the setup is when the last
-- one goes away becomes the Default set, at the reserved id 0, and it becomes the current one.
-- That is what gives an install with no sets of its own something to come back to.
local function ensureDefaultSet()
  if (not esm.Enabled()) or (#esm.Sets() > 0) then
    return
  end
  local set = sets.Capture(ReadText(1001, 3231), esm.DEFAULT_SET_ID, false)
  esm.SetActiveSetId(set.id)
  saves.Sync()
  esm.Debug("default set captured: %d (%s)", set.id, tostring(set.name))
end

-- Falls back to the active set when nothing is selected or the selection has gone away.
local function selectedSet()
  local set = esm.FindSet(selectedId)
  if set == nil then
    selectedId = esm.ActiveSetId()
    set = esm.FindSet(selectedId)
  end
  return set
end

-- Dropdown option ids round-trip through the engine as strings, so the set id goes in as one.
local function dropdownOptions()
  local options = {}
  for _, set in ipairs(esm.Sets()) do
    options[#options + 1] = { id = tostring(set.id), text = set.name, icon = "", displayremoveoption = false }
  end
  return options
end

-- Extension changes only take effect on a full restart and X4 has no reload, so confirming
-- exits to desktop. Vanilla's own quit question is the second line of the prompt.
local function quitGame()
  QuitGame()
  optionsMenu.closeMenu("close")
end

-- The extension setup this page leaves behind is always the applied set, so a mismatch on the
-- way out is the player's to resolve: a preview they did not apply, an unfinished edit, a set
-- captured but never applied. Only the extensions area counts - the mod's own question frame
-- sets currentOption to its own value, which is also what keeps this from asking twice.
local function onOwnPage()
  if exitApproved or (optionsMenu == nil) or (not esm.Enabled()) then
    return false
  end
  local option = optionsMenu.currentOption
  return (option == "extensions") or (option == "extensionsettings")
end

-- The mod's own frames: the choice dialog and the settings page. Neither is a vanilla option,
-- so both leave through their own negCallback rather than vanilla's history.
local function onOwnFrame()
  local option = optionsMenu and optionsMenu.currentOption
  return (option == CHOICE_OPTION) or (option == SETTINGS_OPTION)
end

local function exitDeviation()
  if not onOwnPage() then
    return nil, 0
  end
  local active = esm.FindSet(esm.ActiveSetId())
  if active == nil then
    return nil, 0
  end
  local differs = sets.Deviation(active)
  if differs == 0 then
    return nil, 0
  end
  return active, differs
end

-- Returns true when it has taken the exit over: the question is on screen and the navigation
-- that asked for it has been dropped. Answering yes re-issues that same navigation with the
-- guard disarmed, so the ordinary leave path re-applies the active set on the way out.
local function guardExit(proceed)
  -- An unfinished edit has no "leave" answer: the page is holding a name and a setup that only
  -- Save or Cancel can resolve, so the guard says so and puts the player back on the edit.
  if onOwnPage() and (mode ~= "select") then
    esm.Debug("exit guard: %s in progress, exit refused", mode)
    displayChoice(T(1027), { { text = T(1023), callback = showExtensionsPage } }, showExtensionsPage)
    return true
  end
  local active, differs = exitDeviation()
  if active == nil then
    return false
  end
  esm.Debug("exit guard: %d extension(s) differ from active set %d (%s)",
    differs, active.id, tostring(active.name))
  displayChoice(T(1024, differs, active.name), {
    {
      text = T(1025, active.name),
      callback = function()
        exitApproved = true
        optionsMenu.userQuestion = nil
        ---@diagnostic disable-next-line: assign-type-mismatch
        optionsMenu.currentOption = "extensions"
        proceed()
        exitApproved = false
      end,
    },
    { text = T(1026), callback = showExtensionsPage },
  }, showExtensionsPage)
  return true
end

-- A back off the single-extension page only returns to the extension list, so it leaves
-- nothing: vanilla re-enters submenuHandler with menu.history[1] (gameoptions.lua:13754).
-- An empty history is a real exit, and so is any close.
local function backStaysInArea(dueToClose)
  if dueToClose ~= "back" then
    return false
  end
  local last = optionsMenu and optionsMenu.history and optionsMenu.history[1]
  local target = last and last.optionParameter
  return (target == "extensions") or (target == "extensionsettings")
end

-- Leaving the Extensions page drops everything the page was holding: the previewed states go
-- back, the selection returns to the active set and an unfinished edit is abandoned. The
-- selection has to be reset too, or the dropdown keeps naming a set whose states are gone.
local function leaveExtensionsPage(reason)
  -- While the feature is on, what the game runs is a set, not a snapshot: whatever the page
  -- was previewing, editing or had just captured is dropped, and the active set is what the
  -- page leaves behind - guardExit has already asked about anything that differs, so by the
  -- time this runs the re-apply is usually a zero-change write. Only with the feature off is
  -- there a snapshot to fall back to - and
  -- then it is the preview, the older of the two, which lands on the setup the page was
  -- entered with.
  local active = esm.Enabled() and esm.FindSet(esm.ActiveSetId()) or nil
  if active then
    preview = nil
    editBaseline = nil
    local changed = sets.Apply(active)
    refreshVanillaCaches()
    esm.Debug("left extensions page (%s): active set %d (%s) re-applied, %d extension(s) changed, restart pending=%s",
      reason, active.id, tostring(active.name), changed, tostring(sets.RestartPending()))
  elseif (preview ~= nil) or (editBaseline ~= nil) then
    local baseline = preview or editBaseline
    preview = nil
    editBaseline = nil
    local restored = sets.Restore(baseline)
    refreshVanillaCaches()
    esm.Debug("preview dropped (%s), %d extension(s) restored, restart pending=%s",
      reason, restored, tostring(sets.RestartPending()))
  else
    esm.Trace("left extensions page (%s), no preview held", reason)
  end

  if (mode ~= "select") or (selectedId ~= nil) then
    esm.Trace("page reset: mode %s -> select, selected %s -> active %s",
      mode, tostring(selectedId), tostring(esm.ActiveSetId()))
  end
  mode = "select"
  editId = nil
  editName = ""
  editSaves = true
  editDeleteSaves = false
  editBaseline = nil
  selectedId = nil

  -- This page is the only place the savegame namespace can move, so leaving it is the one
  -- moment vanilla's cached save list has to be told.
  saves.Sync()
end

-- Selecting is a preview: the set's extension states go in so the vanilla list reflects
-- them, but nothing is recorded and nothing is persisted.
local function onSelect(_, id)
  selectedId = tonumber(id)
  local set = esm.FindSet(selectedId)
  esm.Trace("select: dropdown gave %s -> set %s, preview %s",
    tostring(id), set and tostring(set.name) or "none", preview and "already held" or "taken now")
  if set then
    if preview == nil then
      preview = sets.CurrentState()
    end
    sets.Apply(set)
  end
  showExtensionsPage()
end

-- Apply is the commit: it records the set as the current one, persists that, and offers the
-- restart the new setup needs. Re-applying the states first covers a selection that fell
-- back to the active set.
local function applySet(set)
  sets.Apply(set)
  refreshVanillaCaches()
  esm.SetActiveSetId(set.id)
  preview = nil
  selectedId = set.id
  esm.Debug("apply: set %d (%s) is now current, restart pending=%s",
    set.id, tostring(set.name), tostring(sets.RestartPending()))
  if not sets.RestartPending() then
    showExtensionsPage()
    return
  end
  optionsMenu.displayUserQuestion(T(1004, set.name) .. "\n\n" .. ReadText(1001, 4876),
    quitGame, showExtensionsPage, nil, nil, nil, nil, ReadText(1001, 2689))
end

local function onApply()
  local set = selectedSet()
  if not set then
    esm.Trace("apply: nothing selected")
    return
  end
  applySet(set)
end

local function onEdit()
  local set = selectedSet()
  if not set then
    return
  end
  mode = "edit"
  editId = set.id
  editName = set.name
  editSaves = (set.saves == true) and (not esm.IsDefaultSet(set.id))
  editDeleteSaves = false
  editBaseline = sets.CurrentState()
  esm.Trace("edit: set %d (%s), baseline taken", set.id, tostring(editName))
  showExtensionsPage()
end

local function onNew()
  -- The id goes into the savegame prefix as five digits, so it is the id that runs out first.
  if esm.NewSetId() > esm.MAX_SET_ID then
    esm.Debug("new refused: next id %d is past %d", esm.NewSetId(), esm.MAX_SET_ID)
    optionsMenu.displayUserQuestion(T(1019, esm.MAX_SET_ID), showExtensionsPage, showExtensionsPage)
    return
  end
  mode = "create"
  editId = nil
  editName = esm.NextFreeName(T(110))
  -- On by default: a set is a setup plus the games played under it, and a set that shares the
  -- common pool is the exception.
  editSaves = true
  editDeleteSaves = false
  editBaseline = sets.CurrentState()
  esm.Trace("new: proposed name %s, baseline taken", tostring(editName))
  showExtensionsPage()
end

-- Abandoning an edit puts the extension states back where they were when it started: with the
-- vanilla list locked outside edit mode, anything the player changed here was part of the edit.
local function abandonEdit(reason)
  if editBaseline ~= nil then
    local restored = sets.Restore(editBaseline)
    editBaseline = nil
    refreshVanillaCaches()
    esm.Debug("%s: %d extension(s) restored, restart pending=%s",
      reason, restored, tostring(sets.RestartPending()))
  end
  mode = "select"
  editId = nil
end

local function onCancel()
  esm.Trace("cancel: leaving %s mode", mode)
  abandonEdit("edit cancelled")
  showExtensionsPage()
end

-- The commit half of Save: the typed name and the extension setup behind it.
local function commitSave(name)
  esm.Trace("save: mode=%s editId=%s name=%s", mode, tostring(editId), tostring(name))
  selectedId = sets.Capture(name, editId, editSaves).id
  mode = "select"
  editId = nil
  -- Saved: the edited states are what was just captured, so they stay.
  editBaseline = nil
  saves.Sync()
  showExtensionsPage()
end

local function onSave()
  local name = editName
  if (name == nil) or (name == "") then
    return
  end
  local clash = esm.FindSetByName(name)
  if clash and (clash.id ~= editId) then
    esm.Debug("save refused: name %s already belongs to set %d", tostring(name), clash.id)
    optionsMenu.displayUserQuestion(T(1007, name), showExtensionsPage, showExtensionsPage)
    return
  end
  -- Individual saves going off strands whatever the set already wrote under its own prefix.
  -- Deleting those savegames and keeping them are both reasonable, and so is going back to the
  -- edit, so the question has three answers rather than a yes and a no.
  local editedId = editId
  if (mode == "edit") and (not editSaves) and saves.HasOwnSaves(editedId) then
    esm.Debug("save: set %d gives up its own savegames, asking first", editedId)
    displayChoice(T(1020, name), {
      {
        text = T(1021),
        callback = function()
          saves.DeleteOwnSaves(editedId)
          commitSave(name)
        end,
      },
      { text = T(1022), callback = function() commitSave(name) end },
      { text = T(1023), callback = showExtensionsPage },
    }, showExtensionsPage)
    return
  end
  commitSave(name)
end

-- Individual saves is part of what an edit writes, like the name, and both create and edit
-- offer it. Outside an edit the checkbox is read-only, and the Default set never has it.
local function onToggleSaves()
  if (mode == "select") or esm.IsDefaultSet(editId) then
    return
  end
  editSaves = not editSaves
  esm.Trace("individual saves pending: %s", tostring(editSaves))
  showExtensionsPage()
end

-- The edit-mode checkbox is Delete's modifier, not a setting: it says whether the set's own
-- savegames go with it. Nothing is stored, so it is armed for one delete only.
local function onToggleDeleteSaves()
  if (mode ~= "edit") or esm.IsDefaultSet(editId) or (not saves.HasOwnSaves(editId)) then
    return
  end
  editDeleteSaves = not editDeleteSaves
  esm.Trace("delete savegames pending: %s", tostring(editDeleteSaves))
  showExtensionsPage()
end

-- Delete stands where Apply does in select mode: an edit is the only place a set is both
-- named on screen and already stored. What happens next depends on whether the deleted set
-- was the applied one: only then is there nothing left in effect, and only then does the
-- Default set take its place. Deleting any other set is a bookkeeping change - the applied
-- setup and the selection stay where they are. The Default set itself cannot be deleted.
local function onDelete()
  local set = esm.FindSet(editId)
  if (set == nil) or esm.IsDefaultSet(set.id) then
    esm.Trace("delete: nothing to delete in mode %s", mode)
    return
  end
  -- The savegames are the one thing a delete can take that the extensions cannot get back,
  -- so the question names them whenever they are going too.
  local alsoSaves = editDeleteSaves and saves.HasOwnSaves(set.id)
  local wasActive = (set.id == esm.ActiveSetId())
  optionsMenu.displayUserQuestion(T(alsoSaves and 1017 or 1013, set.name), function()
    if alsoSaves then
      saves.DeleteOwnSaves(set.id)
    end
    esm.DeleteSet(set.id)
    editDeleteSaves = false
    if wasActive then
      selectedId = nil
      abandonEdit("active set deleted")
      saves.Sync()
      local fallback = esm.FindSet(esm.DEFAULT_SET_ID)
      if fallback then
        applySet(fallback)
        return
      end
    else
      -- The deleted set was only ever a preview. The applied setup is the older of the two
      -- snapshots, so that is the one the abandoned edit hands back, and the selection
      -- returns to the set that is still current.
      editBaseline = preview or editBaseline
      preview = nil
      selectedId = esm.ActiveSetId()
      abandonEdit("set deleted")
      saves.Sync()
    end
    showExtensionsPage()
  end, showExtensionsPage)
end

-- The master switch. It changes nothing that is stored and nothing that is applied: switching
-- off only stops the mod acting - no savegame namespace, no marking, no lock on the vanilla
-- list - and every set, the active-set record and the per-set savegames stay where they are.
local function onToggleEnabled()
  local enabled = not esm.Enabled()
  esm.SetEnabled(enabled)
  if not enabled then
    -- The preview and the edit baseline are both loans from the feature that just went away,
    -- so they are handed back here rather than at the page exit: what stays applied is the
    -- setup the page was entered with, which is the one the player actually committed to.
    leaveExtensionsPage("feature disabled")
  end
  refreshVanillaCaches()
  saves.Sync()
  showExtensionsPage()
end

-- The same separator vanilla puts between its own blocks (gameoptions.lua:10401), so the mod's
-- rows read as one more block of the page.
local function addSeparatorRow(ftable)
  local row = ftable:addRow(false, {})
  row[2]:setColSpan(6):createText(" ",
    { fontsize = 1, height = Helper.borderSize, cellBGColor = Color["row_separator"] })
end

local function addButton(row, column, textid, active, handler)
  row[column]:createButton({ active = active }):setText(ReadText(1001, textid), { halign = "center" })
  row[column].handlers.onClick = handler
end

-- Builds the mod's table into the frame and returns the height it occupies.
local function buildSetTable(frame, properties)
  local ftable = frame.addTable(frame, 7, {
    tabOrder = 3,
    x = properties.x,
    y = properties.y,
    width = properties.width,
    skipTabChange = true,
  })
  ftable:setColWidth(1, optionsMenu.table.arrowColumnWidth, false)
  ftable:setColWidthPercent(2, 40)
  -- Column 4 is one checkbox wide plus a border either side, so the edit row's flag sits in it
  -- and the name field keeps column 3 alone. In select mode the dropdown still spans 3+4 and is
  -- as wide as it ever was.
  ftable:setColWidth(4, Helper.scaleX(Helper.standardButtonHeight) + (2 * Helper.borderSize), false)
  ftable:setColWidthPercent(5, 13)
  ftable:setColWidthPercent(6, 13)
  ftable:setColWidth(7, optionsMenu.table.arrowColumnWidth, false)

  -- The title row carries the master switch, so it has to be interactive. The caption is the
  -- mod's own name (t 1), so the block names itself the way the list below it names extensions.
  local titleRow = ftable:addRow(true, {})
  createRowText(titleRow[2]:setColSpan(4), T(1), true)
  createCenteredCheckBox(titleRow[6], esm.Enabled(), { mouseOverText = T(125) })
  titleRow[6].handlers.onClick = onToggleEnabled
  -- Column 7 is where every extension row keeps its "..." (gameoptions.lua:10467), so the mod's
  -- own settings are reached the same way. It stays available with the feature off.
  titleRow[7]:createButton({ mouseOverText = T(130) }):setText("...",
    { fontsize = VANILLA_FONT_SIZE, halign = "center" })
  titleRow[7].handlers.onClick = displaySettings
  -- The title closes with a line of its own, so the caption reads as a heading over the rows
  -- under it rather than as the first of them. It is drawn with the feature off as well, where
  -- it is the only thing between the mod's row and vanilla's list.
  addSeparatorRow(ftable)

  -- Off means off: the page is vanilla's again apart from this one row.
  if not esm.Enabled() then
    esm.Trace("build table: disabled, title row only")
    return ftable:getVisibleHeight()
  end

  ensureDefaultSet()

  local editing = (mode ~= "select")
  local set = selectedSet()
  esm.Trace("build table: mode=%s selected=%s active=%s sets=%d preview=%s locked=%s restart pending=%s",
    mode, set and tostring(set.name) or "none", tostring(esm.ActiveSetId()), #esm.Sets(),
    preview and "held" or "none", tostring(locked()), tostring(sets.RestartPending()))

  -- Individual saves is a set attribute, like the name: it is written by both create and edit
  -- and read-only outside them, so it keeps its own captioned row in every mode. The Default
  -- set never has it.
  -- editId is nil while a set is being created, which is never the Default set - so the two
  -- cases cannot be folded into one "editing and ... or ..." without swallowing that nil.
  local flagId
  if editing then
    flagId = editId
  else
    flagId = set and set.id
  end
  local isDefault = (flagId ~= nil) and esm.IsDefaultSet(flagId)
  local savesId = editing and (editId or esm.NewSetId()) or (set and set.id)

  local savesOn
  if editing then
    savesOn = editSaves and (not isDefault)
  else
    savesOn = (set ~= nil) and (set.saves == true)
  end
  local savesEditable = editing and (not isDefault)
  local savesTip
  if isDefault then
    savesTip = T(127)
  elseif editing then
    savesTip = T(1014, esm.SaveTag(savesId))
  elseif set == nil then
    savesTip = ""
  elseif savesOn then
    savesTip = T(1012, esm.SaveTag(savesId))
  else
    savesTip = T(1018)
  end

  -- Delete's own modifier, and it is only ever shown beside a Delete that can be pressed: a
  -- set being created has nothing to delete, and the Default set is never deletable.
  local deletable = (mode == "edit") and (editId ~= nil) and (not isDefault)
  local dropSavesActive = deletable and saves.HasOwnSaves(editId)

  local nameRow = ftable:addRow(true, {})
  createRowText(nameRow[2], T(120))

  if editing then
    -- maxChars is counted in characters, not bytes: the engine measures it with utf8.len.
    nameRow[3]:createEditBox({ maxChars = esm.MAX_SET_NAME }):setText(editName, {})
    nameRow[3].handlers.onTextChanged = function(_, text) editName = text or "" end
    nameRow[3].handlers.onEditBoxDeactivated = function(_, text) editName = text or "" end
    if deletable then
      createCenteredCheckBox(nameRow[4], editDeleteSaves and dropSavesActive, {
        active = dropSavesActive,
        mouseOverText = dropSavesActive and T(1015) or T(1016),
      })
      nameRow[4].handlers.onClick = onToggleDeleteSaves
      createRowText(nameRow[5], ReadText(1001, 8974))
    end
  else
    local options = dropdownOptions()
    local hasSets = #options > 0
    nameRow[3]:setColSpan(2):createDropDown(options, {
      active = hasSets,
      startOption = selectedId and tostring(selectedId) or "",
      textOverride = hasSets and "" or T(1001),
    })
    nameRow[3].handlers.onDropDownConfirmed = onSelect
  end

  if editing then
    -- Delete takes Apply's place, inactive wherever the modifier beside it is not drawn.
    addButton(nameRow, 6, 8931, deletable, onDelete)
  else
    -- The selection has already put the states in place, so Apply only has the record left to
    -- make - pointless while the selected set is already the current one.
    addButton(nameRow, 6, 12704, (set ~= nil) and (set.id ~= esm.ActiveSetId()), onApply)
  end

  local buttonRow = ftable:addRow(true, {})

  -- The flag's own row, in every mode: left aligned under the dropdown's left edge.
  createRowText(buttonRow[2], T(122))
  buttonRow[3]:createCheckBox(savesOn, {
    active = savesEditable,
    width = Helper.standardButtonHeight,
    height = Helper.standardButtonHeight,
    mouseOverText = savesTip,
  })
  if savesEditable then
    buttonRow[3].handlers.onClick = onToggleSaves
  end

  if editing then
    addButton(buttonRow, 5, 64, true, onCancel)
    addButton(buttonRow, 6, 8967, editName ~= "", onSave)
  else
    addButton(buttonRow, 5, 9001, true, onNew)
    addButton(buttonRow, 6, 8529, set ~= nil, onEdit)
  end

  addSeparatorRow(ftable)

  return ftable:getVisibleHeight()
end

local function wrapFrame(frame)
  local origAddTable = frame.addTable

  frame.addTable = function(self, numcolumns, properties)
    -- Vanilla's option table on this page is the 7-column one; the title table above it has
    -- 2. injected keeps the mod's own addTable call below from recursing.
    if injecting and (not injected) and (numcolumns == 7) and properties and properties.maxVisibleHeight then
      injected = true
      local used = buildSetTable(self, properties) + Helper.borderSize
      properties.y = properties.y + used
      properties.maxVisibleHeight = properties.maxVisibleHeight - used
    end
    return origAddTable(self, numcolumns, properties)
  end

  return frame
end

local function onDisplayExtensions(...)
  if not origDisplayExtensions then
    return
  end

  injecting = true
  injected = false

  local ok, err = pcall(origDisplayExtensions, ...)

  injecting = false
  if not ok then
    esm.Error("displayExtensions failed: %s", tostring(err))
  end
end

local hooked = false

function page.EnsureHooked()
  if hooked then
    return
  end

  optionsMenu = Helper.getMenu("OptionsMenu")
  if not (optionsMenu and optionsMenu.displayExtensions and optionsMenu.createOptionsFrame) then
    esm.Debug("EnsureHooked: OptionsMenu not available yet")
    return
  end

  origDisplayExtensions = optionsMenu.displayExtensions
  origCreateOptionsFrame = optionsMenu.createOptionsFrame
  origSubmenuHandler = optionsMenu.submenuHandler
  origCleanup = optionsMenu.cleanup
  origOnCloseElement = optionsMenu.onCloseElement
  origExtensionDefaults = optionsMenu.callbackExtensionDefaults

  optionsMenu.displayExtensions = onDisplayExtensions
  optionsMenu.createOptionsFrame = function(...)
    local frame = origCreateOptionsFrame(...)
    if injecting and frame then
      return wrapFrame(frame)
    end
    return frame
  end

  -- The back arrow and Escape both funnel through onCloseElement, and it runs before vanilla
  -- touches menu.history - which is what lets the guard drop an exit with nothing to undo.
  -- Escape over the mod's own question frame is handled here too: vanilla would run the
  -- negative callback and then close the menu anyway, so the answer would be ignored.
  optionsMenu.onCloseElement = function(dueToClose, layer, extra)
    esm.Trace("onCloseElement(%s%s) on %s", tostring(dueToClose), extra and ", forced" or "",
      tostring(optionsMenu.currentOption))
    -- Only the View teardown passes extra (helper.lua:3868): a hotkey has already taken the
    -- menu away, so refusing this close leaves a registered menu with no view behind it and
    -- the options menu cannot be opened again. Drop the mod's own question and let vanilla
    -- close - the cleanup patch still re-applies the active set on the way out.
    if extra then
      if onOwnFrame() then
        optionsMenu.userQuestion = nil
      end
      return origOnCloseElement(dueToClose, layer, extra)
    end
    if onOwnFrame() then
      local question = optionsMenu.userQuestion
      if question and question.negCallback then
        question.negCallback()
        return
      end
    end
    if backStaysInArea(dueToClose) then
      esm.Trace("back from %s stays in the extension area, guard skipped", tostring(optionsMenu.currentOption))
      return origOnCloseElement(dueToClose, layer, extra)
    end
    if guardExit(function() return origOnCloseElement(dueToClose, layer, extra) end) then
      return
    end
    return origOnCloseElement(dueToClose, layer, extra)
  end

  -- Every move inside the options menu, back arrow included, comes through submenuHandler.
  -- The single-extension page is still the extensions area, so it keeps the preview. The
  -- guard sits here as well for the moves that never pass onCloseElement.
  optionsMenu.submenuHandler = function(option, ...)
    esm.Trace("submenuHandler(%s)", tostring(option))
    if (option ~= "extensions") and (option ~= "extensionsettings") then
      if guardExit(function() return optionsMenu.submenuHandler(option) end) then
        return
      end
      leaveExtensionsPage("submenu " .. tostring(option))
    end
    return origSubmenuHandler(option, ...)
  end

  -- cleanup is the menu itself going away - closed, or replaced by a load or a new game.
  optionsMenu.cleanup = function(...)
    leaveExtensionsPage("menu cleanup")
    return origCleanup(...)
  end

  -- Every extension and DLC row puts its Enabled/Disabled toggle in column 6, and the row the
  -- builder just added is the table's last one - so the button is greyed there rather than by
  -- rebuilding the row. Vanilla has one builder; UIX splits the list and sends mods through
  -- displayModRow, which is why both are wrapped and why a missing one is not an error.
  for _, name in ipairs({ "displayExtensionRow", "displayModRow" }) do
    local original = optionsMenu[name]
    if original then
      optionsMenu[name] = function(ftable, ...)
        local result = original(ftable, ...)
        if locked() and ftable and ftable.rows then
          local row = ftable.rows[#ftable.rows]
          if row and row[6] then
            row[6].properties.active = false
            row[6].properties.mouseOverText = T(126)
          end
        end
        return result
      end
      esm.Trace("EnsureHooked: wrapped %s", name)
    end
  end

  -- The same toggle is reachable from the single-extension page, which builds its rows from a
  -- table this mod cannot see, so that one is stopped at the callback instead.
  if optionsMenu.callbackExtensionSettingEnabled then
    origSettingEnabled = optionsMenu.callbackExtensionSettingEnabled
    optionsMenu.callbackExtensionSettingEnabled = function(...)
      if locked() then
        esm.Debug("extension toggle blocked: edit a set to change extension states")
        return
      end
      return origSettingEnabled(...)
    end
  end

  -- ResetAllExtensionSettings is the player's own wipe; reverting on the way out would put
  -- the preview straight back over it.
  if origExtensionDefaults then
    optionsMenu.callbackExtensionDefaults = function(...)
      preview = nil
      return origExtensionDefaults(...)
    end
  end

  hooked = true
  esm.Debug("EnsureHooked: patched displayExtensions, createOptionsFrame, submenuHandler, cleanup, onCloseElement and the extension toggle")
end

local function init()
  page.EnsureHooked()
end

ESM_Loader.Register("extensions.extension_sets_manager.ui.esm_page", page, init)

return page
