![BovineXIUI Banner](assets/banner.png)

# BovineXIUI

A HorizonXI-tuned fork of [tirem/XIUI](https://github.com/tirem/XIUI) (the successor to HXUI). Era-accurate 75-cap focus, heavy BST / DRG / SMN quality-of-life, a modern visual refresh, and a deep set of UX improvements layered on the stock featureset.

The structure of this README mirrors the config menu (`/xiui`). Each tab gets its own section below: what it controls, plus what's been added or changed vs stock XIUI.

![BovineXIUI Overview](assets/overview.png)

---

## Install (TL;DR)

1. Grab the latest build: [cowrevenge/CowXIUI main.zip](https://github.com/cowrevenge/CowXIUI/archive/refs/heads/main.zip)
2. Extract, rename `CowXIUI-main` to `XIUI`
3. Replace the existing `XIUI` folder in `HorizonXI\Game\addons` with this one
4. Pick XIUI in the HorizonXI launcher, or load in-game with `/addon load xiui`
5. Open the config: `/xiui`

The build is pre-tuned. First-time setup is just dragging the windows where you want them.

---

## Config Tabs

### Global

General settings, fonts, and bar styling.

**What's here:** Lock HUD Position, status / job icon theme, tooltip scale, "Hide During Events", font family / weight / outline, bar bookend style, health bar flash, bar roundness, border thickness, background and entity-name colors.

**What we changed:** Added the bar effects (flash, roundness, border). Hide Native UI lives in its own dedicated **Hideparty** tab below, not duplicated here.

### Player Bar

Your HP / MP / TP / buffs in a floating bar.

**Inherited from XIUI**, no major changes.

### Target Bar

The standalone target window (separate from the in-party-list target preview, which lives in Party List). Shows target HP, TOT, buffs / debuffs, distance, cast bar.

**What we added:** Show Enemy ID, Always Show Health Percent (works on friendly / neutral targets where the game normally hides it), and the subtarget bar option (shows the subtarget cursor selection in its own bar when sub-targeting). Note: the in-party-list target preview now follows the sub-target directly in its own bar instead of needing a second window. See **Party List** below.

### Enemy List

The engaged-enemies list with HP and debuffs.

**Rewritten from scratch.** The stock XIUI / HXUI enemy list had a draw bug that broke other addons sharing the render path. This is a full reimplementation, not an inherited module, and the rendering is isolated so it no longer corrupts state used by neighbors.

### Party List

The biggest module by a wide margin. Member display, sub-target highlighting, click handlers, status icons, dots, anchored Target Bar, anchored Cast Cost.

**What we added or changed:**

- **Three layouts.** Default, HXUI-style (Layout 1), and Super Compact (Layout 2) for denser bars.
- **Stacked HP/MP** option.
- **Retail-style member dots.** Yellow Leader dot tucked left of the name, red Sync dot mirrored on the right side of the bar, sized to match retail. Alliance leader gets two yellow dots side by side.
- **Gold Treasure / Cyan Trade dots** above Player 1 at the 25% / 75% marks.
- **Click-to-target.** Click a member to target. Now also works during sub-target mode (see below).
- **Click-to-debuff-cure.** Click a member's debuff icon and BovineXIUI fires the matching White Magic remover automatically. Self casts on `<me>`, party members cured by name. Knows Paralyna, Silena, Stona, Erase, Blindna, Cursna, Viruna, Poisona.
- **Sub-target follow.** When you fire `/ma "Cure" <stpc>` or similar, the anchored Target Bar above the party list swaps to show whoever the sub-target cursor is on, instead of staying glued to the held mob. Arrow-key the cursor and the bar tracks it. Snaps back when sub-targeting ends.
- **Click-to-sub-target.** Click a party member during sub-target mode and BovineXIUI walks the game's own cursor to that row by simulating arrow-key presses. Wrap-aware shortest path (6-party with cursor on row 4 and you click row 2 sends `up 2`, not `down 4`). You press Enter yourself to confirm. Implemented as keyboard input through Ashita's input manager so the game does all its own validation; no memory writes into the target manager.
- **Shift+drag.** Plain click targets the member under the cursor; window only moves when you hold Shift. Prevents accidental yank when click-targeting.
- **Cure buttons** on party list rows (off by default).
- **Anti-flicker on the Target Bar.** Previously the in-party-list Target Bar would briefly draw in the wrong place for one frame when you re-acquired a target. The anchor system now retains last-known dimensions across invalidations, so it lands correctly on the first frame.
- **Castcost stacking coordination.** When the Target Bar is enabled in config but no target is held this frame, Cast Cost stacks flush against the party panel instead of leaving a phantom gap where the invisible target would have lived.

### Exp Bar

Experience tracker with Job Point support.

**What's here:** HzXI-style XP / merit / JP toggle. The bar shows merit points or job points depending on the Merit mode setting in the FFXI menu.

**Inherited from HXUI fork, no changes.**

### Gil Tracker

Gil display.

**What's here:** Position offset, right-align option.

**Inherited from XIUI**, no major changes.

### Inventory

Inventory tracker (rows, columns, opacity, count text).

**What we changed:** Shift+click slightly to the right of the text numbers to reposition the inventory tracker.

### Cast Bar

Spell / ability cast progress bar.

**Inherited from XIUI**, no major changes.

### Cast Cost

Floating info panel showing spell / ability / weapon-skill MP cost, recast, and TP requirements.

**What we added:**

- The whole module is original to this fork (it's the "Cast Box" feature).
- **Anchor to Party List** option (lives under Party List config, but the Cast Cost itself sits here). When ON, the Cast Cost stacks above the in-party Target Bar; when OFF, it uses its own free-floating position.
- Modern theme toggle independent of the global theme.
- Stacking now correctly coordinates with whether the Target Bar is actually drawing this frame.

### Pet Bar (Pet HUD)

A comprehensive floating HUD for **BST / DRG / SMN**.

**Original to this fork.**

- HP / TP / MP tracking, plus the BST Ready-charge counter.
- Pet portrait images for jug pets, wyverns, all 14 avatars, and spirits.
- Pet buff / debuff panel (Stoneskin, Regen, Haste, etc. visible on your pet).
- Charm duration timer using the PetMe formula with a full 16-slot gear scan and the Familiar +25 min extension.
- Jug duration timer backed by an HzXI-accurate pet database (27 pets sourced from the HzXI wiki).
- BST ready-moves list with damage-type icons.
- Ability recasts tracked: Reward, Call Beast, Call Wyvern, Spirit Link, Steady Wing, Deep Breathing, Apogee, Mana Cede, Astral Flow.
- **Clickable.** Any ability or ready-move row fires the matching `/ja` or `/pet` command. No macros required.
- **2-hour confirmation.** Clicking a 2-hour ability (Astral Flow, Familiar, Spirit Surge, Overdrive) arms it and prompts "click again to confirm" so you can't fire by accident.
- **Click-to-summon** when no pet is out: "Call Wyvern" on DRG, "Call Beast" on BST.
- **Per-avatar SMN Blood Pact favorites.** Nested config menu with all 14 avatars, each with Rage and Ward inputs.

![Pet HUD Preview](assets/pethud.png)

### Notifications

In-game notification system (gear, status, treasure pool sync).

**Inherited from XIUI**, with the treasure pool integration tying into BovineLooty.

### Hideparty

Hide FFXI's native UI elements. Built in so you don't need atom0s's standalone hideparty addon.

**Different from the regular hideparty addon:** stock hideparty ships four signatures (party0, party1, party2, target cursor). BovineXIUI adds a fifth: the **spell / ability info window** (the "Blizzard III MP: 120 Recast: 27s" tooltip and its job-ability cousin). The slot for that primitive was discovered relative to the target cursor slot (target_slot − 4 bytes) using a primitive enumerator.

**The five toggles:**
- Main party (members 1-6)
- Alliance 1 (members 7-12)
- Alliance 2 (members 13-18)
- Native target cursor (the in-world arrow)
- Spell / ability info window

Defaults to hiding all five. Restores everything on unload, so toggling XIUI off doesn't leave you stuck without UI.

### Treasure Pool

Custom treasure pool window with live item tracking, plus **BovineLooty** (the auto-pass / auto-lot system).

**Original to this fork.**

**Treasure Pool window:** live tracking of pool items as they drop, instead of relying on the native window.

**BovineLooty:**
- **Auto-Lot list.** Item IDs you want lotted automatically the moment they hit the pool.
- **Auto-Pass list.** Item IDs you want passed automatically (the inverse, for stuff you don't want).
- Configurable through the in-game window (`/xiui bvl` to open).
- Saves and loads from disk.

**Commands:**
- `/xiui bvl` - toggle the Looty window
- `/xiui bvl start` / `stop` / `toggle` - control the auto-pass / auto-lot run state
- `/xiui bvl addlot <id>` - add an item ID to Auto-Lot
- `/xiui bvl addpass <id>` - add an item ID to Auto-Pass
- `/xiui bvl rm <id>` - remove an ID from either list
- `/xiui bvl load` / `save` - manage the config file
- `/xiui lot` or `/xiui lotall` - lot every unlotted item right now
- `/xiui pass` or `/xiui passall` - pass every unlotted item right now
- `/xiui tp` - force-show / hide the treasure pool window

---

## Cross-cutting Systems

These aren't tabs themselves but show up across multiple modules.

### Window Anchor System

Several windows can snap to each other instead of having independent positions:

- **In-party Target Bar** anchors above Party 1 (no separate position option, it's always tied to Party 1).
- **Cast Cost** can optionally anchor above the in-party Target Bar (Party List → "Anchor Cast Cost to Party List"). Off by default, in which case Cast Cost uses its own free-floating position from the Cast Cost tab.

The anchor system retains last-known dimensions across frames where a parent window isn't drawn, which is what fixes the anti-flicker behavior. Children fall back gracefully when a parent isn't visible.

### Sub-target Behavior

Three connected pieces, all in Party List but woven through the in-party Target Bar and the click handler:

1. **In-party Target Bar follows the sub-target.** When sub-targeting, the bar shows the cursor selection, not the held mob.
2. **Click-to-sub-target.** Clicking a partymember mid-sub-target navigates the game's cursor there via simulated arrow keys.
3. **Member dots/highlight** track the sub-target state (yellow targeted box on the cursor selection, plus the original target if relevant).

Implemented through the game's own keyboard input path rather than memory writes, so FFXI's "is this entity a valid sub-target candidate" validation continues to run normally.

### Modern Theme

Clean dark-blue panel look. Switchable in **Global** → General. Affects party list, alliance lists, in-party Target Bar, and Cast Cost together. The Cast Cost has its own independent Modern toggle if you want the panels split.

---

## Inherited Core Elements (from XIUI / HXUI)

These are the base modules from upstream that BovineXIUI inherits and styles:

- Player Bar
- Target Bar (with TOT, buffs / debuffs)
- Party List (with buffs / debuffs)
- Cast Bar
- Exp Bar
- Inventory Tracker
- Gil Tracker
- Full configuration UI covering every element

---

## Installation (detailed)

1. Download: [cowrevenge/CowXIUI main.zip](https://github.com/cowrevenge/CowXIUI/archive/refs/heads/main.zip)
2. Extract the `.zip`. You'll get a directory called `CowXIUI-main` with the addon files
3. Rename that directory to `XIUI`. The addon registers internally as `xiui`, so the folder name must match
4. **Delete your existing `XIUI` folder** in `HorizonXI\Game\addons` and drop this one in its place. This is a complete install, not an overlay, so it should replace XIUI on first run
5. If you're coming from the old HXUI fork, leave the `HXUI` folder where it is as a backup in case you want to fall back
6. Copy the new `XIUI` folder into `HorizonXI\Game\addons`
7. **Recommended:** select XIUI in the HorizonXI launcher so it auto-loads every session
8. Don't load both XIUI and HXUI at the same time. You can, but you'll be very confused
9. To manually load in-game: `/addon load xiui`
10. To open the configuration menu: `/xiui`

---

## Updating

1. Fresh, pre-configured install. Out-of-the-box it ships in the intended look, so a first run replaces XIUI rather than merging into an old config
2. Before installing a new release, delete the old `XIUI` folder in `game/addons` first. Asset directories change between versions and leftover files sometimes collide
3. Window positions are the one thing not baked into the defaults. Set them once on first run; everything else (layout, fonts, colors, offsets) comes pre-tuned
4. Patch notes display automatically in-game on the first load after an update via the built-in Patch Notes window

---

## Known Todo

- Anchored Target Bar (in-party): treasure / status icons aren't rendering on it yet, NPC status isn't read correctly. Sub-target follow, flicker, and stacking are all sorted.

---

## Credits and License

- Upstream lineage: [tirem/XIUI](https://github.com/tirem/XIUI) and its predecessor [tirem/HXUI](https://github.com/tirem/HXUI). Massive thanks to the original authors.
- HorizonXI-specific enhancements, Pet HUD, Modern theme, Cast Cost / Cast Box, BovineLooty (Auto Pass / Auto Lot), integrated Hideparty (including the spell / ability info window suppression), in-party Target Bar sub-target follow, click-to-sub-target, and the anchor anti-flicker work are original to this fork.
- Jug pet data sourced from the [HorizonXI wiki](https://horizonffxi.wiki/Category:Familiars).
- Licensed under **GPL-3.0**, matching upstream.

---

## Issues and Contributions

Bug reports and feature requests specific to this fork: [CowXIUI issue tracker](https://github.com/cowrevenge/CowXIUI/issues). Please don't file them upstream against tirem/XIUI or tirem/HXUI, the original maintainers aren't responsible for fork behavior. PRs welcome.