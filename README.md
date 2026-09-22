# Extension Sets Manager

Save named sets of enabled and disabled extensions, switch between them from the Extensions page, and optionally keep each set's savegames apart from the rest.

## Overview

X4 keeps exactly one list of enabled extensions. Playing a heavily modded game and a light one, or keeping a stable setup beside a test setup, means toggling extensions by hand every time and remembering which of the sixty entries in the list were on.

This mod adds its own block at the top of **Options > Extensions**: capture the current setup under a name, keep as many of those sets as you like, and switch between them with one drop-down and one button. Extension changes need a full restart in any case, so applying a set offers to exit to desktop right away.

A set can also own its savegames. With that turned on, everything saved while the set is active is stored under an id of its own and only that set sees it, so a save made in the modded setup cannot be loaded into the light one by accident. The save and load pages, and the Continue entry in the main menu, say which set each save belongs to.

The whole feature is off on a fresh install. Nothing changes until you switch it on, and switching it off again leaves every set, every setting and every savegame where it was.

## Requirements

- **X4: Foundations**: Version **8.00** or higher and **UI Extensions and HUD**: Version **v8.0.4.x** or higher by [kuertee](https://next.nexusmods.com/profile/kuertee?gameId=2659):
  - Available on Nexus Mods: [UI Extensions and HUD](https://www.nexusmods.com/x4foundations/mods/552)
- **X4: Foundations**: Version **9.00** or higher and **UI Extensions and HUD**: Version **v9.0.0.4** or higher by [kuertee](https://next.nexusmods.com/profile/kuertee?gameId=2659).
- **Print Extension List**: Version **1.00** or higher by [Chem O`Dun](https://next.nexusmods.com/profile/ChemODun/mods?gameId=2659):
  - Available on Steam Workshop: [Print Extension List](https://steamcommunity.com/sharedfiles/filedetails/?id=3770927339)
  - Available on Nexus Mods: [Print Extension List](https://www.nexusmods.com/x4foundations/mods/2191)

## Installation

- **Steam Workshop**: link to be added on publication.
- **Nexus Mods**: link to be added on publication.

## How to use it

### Switching the feature on

Open **Options > Extensions**. The mod's block sits above the extension list, with a **...** button on its title row. Press it to open the mod's settings page and tick **Enabled** there; press the back arrow and the block has opened up.

The first time it is switched on, the setup you are already running is captured as a set called **Default**, and that set becomes the active one. Nothing about your extensions changes.

While the feature is on, the extension list below is read-only: the Enabled and Disabled buttons are greyed out, and the way to change an extension state is to edit a set. Untick **Enabled** on the settings page and the list is yours again.

### Creating a set

Press **New**, type a name, and set the extensions in the list below to whatever that set should be. Press **Save** to store it, or **Cancel** to drop the edit and put the extension states back as they were.

A set name can be up to 30 characters and has to be unique.

### Switching to another set

Pick the set in the drop-down. The extension list immediately shows what that set holds, so you can look it over before committing to it. Nothing is recorded yet.

Press **Apply** to make it the active set. Because extension changes only take effect on a restart, the game then offers to exit to desktop. Start X4 again and the set is running.

Leaving the Extensions page without pressing Apply puts the active set's extensions straight back.

### Editing a set

Pick the set, press **Edit**, and the name becomes an edit box while the extension list becomes editable. **Save** stores both halves at once, so editing is how a set is renamed and how it is re-captured from the current list. **Cancel** drops everything.

### Individual savegames

Each set except Default carries an **Individual Saves** checkbox, editable while the set is being edited. With it on, saves written while that set is active carry the set's own five-digit id and are listed only for that set. With it off, the set shares the common savegames with every other set that shares them.

The **Default** set always shares the common pool, which is what makes it the way back to an unmodified save list.

Quicksaves and autosaves are written by the game itself and stay shared across all sets.

### Deleting a set

Press **Edit** on the set, then **Delete**. The extensions themselves are not touched. If the set owns savegames, a second checkbox appears beside the button to delete those along with it; leave it unticked and the savegames stay on disk for the next set that takes the same id.

The **Default** set cannot be deleted.

### Settings of the mod itself

The title row of the mod's block carries a **...** button, in the same column where every extension row keeps its own. It opens the mod's settings page, and the back arrow returns to the extension list. The page is reachable whether the feature is switched on or off.

- **Enabled**: the master switch for the whole feature. Off, the mod does nothing at all - no set is applied, no savegames are kept apart, and the extension list below is an ordinary one. Every set, the active-set record and the per-set savegames stay exactly where they are, so switching it back on picks up where it left off.
- **Debug mode**: how much the mod writes to the game log. **None** is the normal setting and still reports errors; **Debug** adds what the mod does on every action; **Trace** adds every store read and write, every button and every page build. Use the last two only while troubleshooting, then set it back.
- Under it, for reference: the store the sets are kept in, how many sets are saved, the savegame prefix the active set writes, and whether a restart is already pending.

## Limitations

- **A set only takes effect after a restart.** There is no way to reload extensions in a running X4, so applying a set always means exiting and starting the game again.
- **This mod and the extensions it needs are always kept enabled** in every set. A set that switched the manager off could not be switched away from.
- **Individual savegames cover manual saves only.** `quicksave`, the autosaves and online saves are written by the engine under names no script sees, so they stay shared.
- **A set's saves are hidden while another set is active**, in the start menu as well as in game. That is the point of the feature, but it is the first thing that looks like a bug: if a save seems to be missing, check which set is active.
- **The per-extension page** reached through the "..." button of an extension row still shows its Enabled row as clickable while the feature is on. The click does nothing; use Edit on a set to change extension states.
- **One package covers both game versions.** The mod patches the options menu at runtime rather than replacing any game file, so 8.00 and 9.00 are served by the same build.
- **Set ids stop at 99999**, which is also the number of sets that can ever have existed in one installation, since an id is never reused.

## Credits

- **Author**: Chem O`Dun, on [Nexus Mods](https://www.nexusmods.com/profile/ChemODun/mods?gameId=2659) and [Steam Workshop](https://steamcommunity.com/id/chemodun/myworkshopfiles/?appid=392160)
- *"X4: Foundations"* is a trademark of [Egosoft](https://www.egosoft.com).

## Acknowledgements

- [EGOSOFT](https://www.egosoft.com) - for the X series.
- [kuertee](https://next.nexusmods.com/profile/kuertee?gameId=2659) - for *UI Extensions and HUD*, which this mod builds its page on.

## Changelog

### [1.00] - 2026-09-??

- **Added**
  - Initial release.
