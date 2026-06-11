![BovineXIUI Banner](assets/banner.png)

# BovineXIUI

**Updated XIUI for HorizonXI.** A forked, actively-maintained build now rebased onto [tirem/XIUI](https://github.com/tirem/XIUI) (the successor to HXUI), tuned for the **HorizonXI** private server (75-cap, era-accurate content), with a heavy focus on Beastmaster / Dragoon / Summoner quality-of-life, a modern visual refresh, and a pile of UX improvements layered on top of the stock feature set.

Welcome to BovineXIUI — we have now completed the rebase to XIUI. Everything the original XIUI/HXUI shipped still works, all of the fork's features have been ported across, and the config menu picks up new sections automatically.

![BovineXIUI Overview](assets/overview.png)

---

## Rebase Notes — Read First

This release is a **complete, clean install** built on the XIUI base, not an in-place update of the old HXUI fork.

- On first run, **delete your existing `XIUI` addon and replace it with this build.** This ships pre-tuned and is meant to stand on its own.
- You can **leave your old `HXUI` folder in place as a backup** — if you decide you don't like the rebase, you can fall back to it without having lost anything.
- This build registers internally as `xiui`, so the folder must be named `XIUI`, you load it with `/addon load xiui`, and you open the config with `/xiui`.

---

## What's New

### Rebased

- **Full rebase onto XIUI.** All BovineXIUI features have been ported across to the new base, including the **Pet HUD**, **Click-to-Target**, and **Click-to-Debuff** systems.
- **Pre-tuned defaults.** A fresh install comes up already configured in the intended look — compact party layout, fonts, scales, colors, and text offsets are all baked in. The only thing you need to do on first run is drag the windows to where you want them; window placement is intentionally left to you.

### Added

- **Treasure Pool: Auto Pass / Auto Lot.** The Treasure Pool window now supports automatic passing and lotting via configurable lists — set items to auto-pass or auto-lot and the pool handles them for you, no manual clicking.
- **Stacked HP/MP option** for denser player/target bars.
- **Modern Style** — clean dark-blue panel look, switchable in the General section. Affects party list, alliance lists, target preview, and cast cost window together.
- **Treasure Pool window** with live item tracking (the base the Auto Pass/Lot system sits on top of).
- **Cast Box** — floating info panel above the target showing spell / ability / weapon-skill MP cost, recast, and TP requirements. Has its own Modern theme toggle separate from the global one.
- **Cure buttons on party list** (off by default).
- **Fixed-anchor target window** in the party menu — the Target preview snaps to Party 1 so it stops wandering when the party list scales.
- **Target bar options** — Show Enemy ID, Always Show Health Percent (including friendly / neutral targets).
- **Party status dot system:**
  - Gold Treasure / Cyan Trade dots above Player 1 at the 25% / 75% marks.
  - Yellow Leader / Red Sync dots beside each member's job icon.
  - All dots render correctly in both the textured and Modern themes.

![Pet HUD Preview](assets/pethud.png)

- **Pet HUD** — a comprehensive floating HUD for **BST / DRG / SMN**:
  - HP / TP / MP tracking and the BST Ready-charge counter.
  - Pet portrait images for jug pets, wyverns, all 14 avatars, and spirits.
  - Pet buff / debuff panel (Stoneskin, Regen, Haste, etc. visible on your pet).
  - Charm duration timer using the PetMe formula with a full 16-slot gear scan and the Familiar +25 min extension.
  - Jug duration timer backed by an HzXI-accurate pet database (27 pets sourced from the HzXI wiki).
  - BST ready-moves list with damage-type icons.
  - Ability recasts tracked for Reward, Call Beast, Call Wyvern, Spirit Link, Steady Wing, Deep Breathing, Apogee, Mana Cede, and Astral Flow.
  - **Clickable** — any ability or ready-move row fires the matching `/ja` or `/pet` command. No macros required.
  - **2-hour confirmation** — clicking a 2-hour ability (Astral Flow, Familiar, Spirit Surge, Overdrive) arms it and prompts "click again to confirm" so you can't fire it by accident.
  - **Click-to-summon** when no pet is out: "Call Wyvern" on DRG, "Call Beast" on BST.
  - **Per-avatar SMN Blood Pact favorites** — nested config menu with all 14 avatars, each with Rage and Ward inputs.

### Modded

- Shift+click slightly to the right of the text numbers to move the inventory tracker.
- **Enhanced Debuffs** — click a party member's debuff icon to auto-cast the matching White Magic cure (Paralyna / Silena / Stona, etc.). Self-targets cast on `<me>`; party members are cured by name.
- **Enhanced Targeting** — click alliance or party member names to target them directly.
- Party list Shift+hold-drag to move the window (plain click still targets the member under the cursor).

### Known Todo

- **Anchored target bar (party menu) is unfinished:** no locked-position support yet, treasure / status icons don't render on it, and NPC status isn't read correctly. Working on it.

---

## Core Elements (inherited from XIUI / HXUI)

- Player Bar
- Target Bar (w/ Target of Target and Buffs & Debuffs)
- Party List (w/ Buffs & Debuffs)
- Enemy List (w/ Buffs & Debuffs)
- Cast Bar
- Exp Bar
- Inventory Tracker
- Gil Tracker
- Full configuration UI covering every element

---

## Installation

1. Download the latest build:
   [cowrevenge/CowXIUI (main .zip)](https://github.com/cowrevenge/CowXIUI/archive/refs/heads/main.zip)
2. Extract the `.zip`. You'll get a directory called `CowXIUI-main` containing the addon files.
3. Rename that directory to `XIUI` (the addon registers internally as `xiui`, so the folder name must match).
4. **Delete your existing `XIUI` folder** in `HorizonXI\Game\addons` and drop this one in its place. This is a complete install, not an overlay — it should replace XIUI on first run.
   - If you're coming from the old HXUI fork, you can **leave the `HXUI` folder where it is as a backup** in case you want to fall back.
5. Copy the new `XIUI` folder into `HorizonXI\Game\addons`.
6. **Recommended:** make the addon auto-load every session.
   Select XIUI in the horizone loader
   Do not load BOTH XIUI and HXUI at the same time! (I mean you can.. but you will be very confused)
7. To manually load in-game: `/addon load xiui`
8. To open the configuration menu: `/xiui`

---

## Updating Notes

1. **This is a fresh, pre-configured install.** It ships in the intended look out of the box, so on first run it replaces XIUI rather than merging into an old config.
2. **Before installing a new release**, delete the old `XIUI` folder in `game/addons` first — asset directories can change between versions and leftover files sometimes collide.
3. Window positions are the one thing not baked into the defaults, so you'll set those once on first run; everything else (layout, fonts, colors, offsets) comes pre-tuned.
4. Patch notes display automatically in-game on the first load after an update, via the built-in Patch Notes window.

---

## Credits & License

- Upstream lineage: [tirem/XIUI](https://github.com/tirem/XIUI) and its predecessor [tirem/HXUI](https://github.com/tirem/HXUI) — the foundational addons this fork is built on. Massive thanks to the original authors.
- HorizonXI-specific enhancements, the Pet HUD module, Modern theme, Cast Box, Treasure Pool Auto Pass/Lot, and the QoL modifications are original to this fork.
- Jug pet data sourced from the [HorizonXI wiki](https://horizonffxi.wiki/Category:Familiars).
- Licensed under **GPL-3.0**, matching upstream.

## Issues & Contributions

Bug reports and feature requests specific to this fork belong in the [CowXIUI issue tracker](https://github.com/cowrevenge/CowXIUI/issues) — please don't file them upstream against tirem/XIUI or tirem/HXUI, as the original maintainers aren't responsible for fork behavior. PRs welcome.
