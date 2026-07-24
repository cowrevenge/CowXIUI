![CowXIUI Banner](assets/banner.png)

# CowXIUI

A HorizonXI-tuned fork of [tirem/XIUI](https://github.com/tirem/XIUI) (successor to HXUI). Era-accurate 75-cap focus, heavy BST / DRG / SMN quality-of-life, combat round timers, resolution presets, treasure-pool automation, and a deep set of interaction and rendering rewrites on top of the upstream module set.

This README mirrors the config menu (`/xiui`). Every tab gets a section.

![CowXIUI Overview](assets/overview.png)

---

## Install (TL;DR)

1. Grab the latest build: [cowrevenge/CowXIUI main.zip](https://github.com/cowrevenge/CowXIUI/archive/refs/heads/main.zip)
2. Extract, rename `CowXIUI-main` to `XIUI`
3. Replace the existing `XIUI` folder in `HorizonXI\Game\addons`
4. Pick XIUI in the HorizonXI launcher, or `/addon load xiui`
5. Open the config: `/xiui`
6. Open the **Preset** tab and load the preset matching your resolution

Step 6 is new. Window layout used to be the one thing you set by hand. It now ships as a preset.

---

## What This Fork Adds

Upstream XIUI provides the module set: Player Bar, Target Bar, Party List, Enemy List, Cast Bar, Cast Cost, Hotbar, Exp Bar, Inventory, Gil Tracker, Mob Info, Treasure Pool, Notifications. CowXIUI builds on that.

**New modules, original to this fork:**

| Module | What it does |
|---|---|
| **Pet Bar / Pet HUD** | Full BST / DRG / SMN / PUP HUD — charm timers, jug database, clickable abilities, Blood Pact favourites, pet portraits |
| **Combat Timers** | Attack / defence round counters and resting tick countdown |
| **Latent Trial** | Weapon-skill point tracker for Trial weapons |
| **Dedication** | EXP-buff item tracker with cap counting |
| **Preset** | Whole-layout save/load, per resolution |
| **BovineLooty** | Auto-lot / auto-pass with rate limiting |
| **Hideparty** | Native UI suppression, five signatures |

**Rewritten from upstream:**

- **Party List** — rewritten around the anchor system, with three layouts, split font rendering, retail dots, and the full click-interaction layer
- **Enemy List** — full reimplementation; upstream's had a draw bug that corrupted the shared render path
- **Cast Cost** — rebuilt as the Cast Box, with MP-cost preview and party-list stacking
- **Treasure Pool** — custom window with live tracking, on top of upstream's lot/pass plumbing

**Original interaction systems** woven through the above: click-to-target, click-to-debuff-cure, click-to-sub-target, sub-target follow, the window anchor system, and the window position / preset persistence layer.

---

## Config Tabs

### Global

General settings, fonts, and bar styling.

Lock HUD Position, status / job icon theme, tooltip scale, Hide During Events, font family / weight / outline, bar bookend style, health bar flash, bar roundness, border thickness, background and entity-name colours.

**Fork changes:** bar effects (flash, roundness, border). Hide Native UI lives in its own **Hideparty** tab rather than being duplicated here.

---

### Cast Bar

Spell / ability cast progress bar.

**Fork changes:** outlined text moved to the imgui foreground draw list so it renders on top of the bar rather than under it.

---

### Cast Cost

Floating panel showing spell / ability / weapon-skill MP cost, recast, and TP requirements before you commit. **Rebuilt in this fork** as the "Cast Box".

- **MP cost preview** with its own flash colour, gradient, and pulse speed. Goes red when you can't afford the cast.
- **Anchor to Party List** (toggle lives under Party List). When ON, the panel stacks above the in-party Target Bar; when OFF it free-floats from its own saved position.
- Independent theme toggle, so the panel can differ from the global theme.
- Stacking coordinates with whether the Target Bar is actually drawing this frame, so there's no phantom gap when no target is held.

---

### Combat Timers

**Original to this fork.** Ported from the standalone bovinebattle addon.

- **Since Attack** — elapsed time since your last melee round landed
- **Since Defence** — elapsed time since a mob last hit or missed you
- **Next Tick** — countdown to the next resting HP/MP tick

Detection is chat-log based, matching bovinebattle exactly. A **0.35s burst window** collapses multi-hit rounds (Double/Triple Attack, Kick Attacks, tight Haste rounds) into a single round, so the timer doesn't reset on every sub-hit.

Both timers only count while **engaged** (`Status == 1`) and read `--` otherwise.

The rest tick countdown is grounded in LSB server source (`0x0e8_camp.cpp`, `HEALING_TICK_DELAY` = 10s) and verified on HorizonXI by wall clock: 9.98s average over 6 intervals, with first-packet latency of 20-23s. The countdown runs from 12s because packets land ±2s and it resets the moment one arrives.

**Config:** Enabled, Hidden Window, Show Resting Tick Countdown, font override, Reset Timers.

---

### Dedication

**Original to this fork.** Tracks EXP-bonus items and how much bonus XP remains before the cap.

| Item | Bonus | Duration | Cap |
|---|---|---|---|
| Empress Band | +50% | 180 min | 1,000 |
| Emperor Band | +75% | 150 min | 2,250 |
| Chariot Band | +100% | 120 min | 4,000 |
| Tale of the Wandering Heroes | +75% | 1440 min | 10,000 |
| Anniversary Ring | +100% | 720 min | 3,000 |

Detection chain: catches the "uses \<Item\>" chat line, waits for the Dedication buff (id 249) to appear within 30s as proof the item actually activated, then increments bonus-used on every XP gain by the extra portion the buff contributed. No buff edge inside 30s means the item failed (you already had the effect) and it's discarded rather than tracked.

Window shows only while Dedication is active.

---

### Enemy List

Engaged-enemy list with HP and debuffs.

**Rewritten from scratch.** Upstream's enemy list had a draw bug that corrupted the render path shared with other addons. This is a full reimplementation drawing entirely onto the foreground draw list, isolated so it no longer breaks neighbours.

Because it holds no imgui window of its own, its position lives in `enemyListX` / `enemyListY` rather than the window-position system, and it can optionally anchor to the target bar.

**Fork additions:** enemy ID display (decimal or hex), distance, HP percent text, per-enemy debuff row, target indicators, configurable rows-per-column and column spacing, borders that can take the entity name colour.

---

### Exp Bar

Experience tracker with merit and Job Point support. The bar switches between XP, merits, or JP depending on the Merit mode in the FFXI menu.

Inherited, no major changes.

---

### Gil Tracker

Gil display with position offset and right-align. Optional gil-per-hour readout.

Inherited, no major changes.

---

### Hideparty

Hide FFXI's native UI elements. Built in, so atom0s's standalone hideparty addon isn't needed.

**Extended vs the standalone addon.** Stock hideparty ships four signatures. CowXIUI adds a fifth: the **spell / ability info window** (the "Blizzard III MP: 120 Recast: 27s" tooltip and its job-ability cousin). That primitive's slot was found relative to the target cursor slot (`target_slot − 4 bytes`) with a primitive enumerator.

Five toggles:

- Main party (members 1-6)
- Alliance 1 (members 7-12)
- Alliance 2 (members 13-18)
- Native target cursor (the in-world arrow)
- Spell / ability info window

Defaults to hiding all five. Restores everything on unload, so toggling XIUI off never leaves you without UI.

---

### Hotbar

Configurable action bar with controller / crossbar support. Inherited from upstream, which in turn adapts concepts from Windower's [XIVHotbar2](https://github.com/Technyze/XIVHotbar2) under BSD licence.

Six independent bars, crossbar mode with hold-to-show triggers, macro palettes, pet palettes, skillchain highlighting, live recast tracking, per-slot MP cost display, and full colour customisation.

**Commands:**

- `/xiui hotbar <bar> <...>` — direct bar manipulation
- `/xiui palette` or `/xiui pal` — palette management

---

### Inventory

Inventory tracker with rows, columns, opacity, and count text. Separate trackers for Satchel, Safe, Storage, Locker, and Wardrobe.

**Fork changes:** shift+click slightly right of the text numbers to reposition the tracker.

---

### Latent Trial

**Original to this fork.** Weapon-skill point tracker for Trial weapons.

Counts your weapon skills while a `... of Trials` weapon is in the main slot, scored per the [HorizonXI wiki](https://horizonffxi.wiki/Weapon_Skill_Points):

| Event | Points |
|---|---|
| Solo WS | 1 |
| Close Lv1 skillchain | 2 |
| Close Lv2 skillchain | 3 |
| Close Lv3 skillchain | 5 |

**Player-only.** The action packet's actor must be your own server ID, so someone else closing a chain on your mob counts nothing.

Per-weapon counts persist to `current_trial.json` in the module folder and reload on init.

**Config:** Enabled, Hidden Window, Rainbow Flash on Finish, Experimental Mode, plus manual +10 / +50 / +100 / Reset buttons for both the trial counter and Chaosbringer.

**Experimental Mode** buffers WS points per mob and only commits them if the mob dies, avoiding points counted on a mob that despawns or gets claimed away.

---

### Notifications

On-screen alerts for items, gil, key items, party invites, trade invites, and treasure pool events.

Configurable grouping (up to 6 groups), stack direction, display duration, max visible, padding, spacing, scale, background theme, and per-type split toggles.

Inherited, with the treasure pool integration tying into BovineLooty.

---

### Party List

The largest module by a wide margin. **Rewritten in this fork** around the anchor system, with a full interaction layer on top.

**Layout and rendering:**

- **Three layouts** — Default, HXUI-style (Layout 1), and Super Compact (Layout 2) for denser bars
- **Stacked HP/MP** option
- **Split font rendering** — values and the `(NN%)` suffix draw as separate elements with mode-specific offsets, so numbers sit properly against the panel edge instead of floating on glyph whitespace
- **Retail-style member dots** — yellow Leader dot tucked left of the name, red Sync dot mirrored right, sized to match retail. Alliance leaders get two yellow dots side by side
- **Gold Treasure / Cyan Trade indicators** above Player 1
- **Rainbow TP** — 3-second hue cycle at 1000+ TP
- Text rendering moved to the imgui foreground draw list so values composite on top of bars rather than under them

**Interaction (original to this fork):**

- **Click-to-target.** Click a member to target them. Works during sub-target mode too
- **Click-to-debuff-cure.** Click a member's debuff icon and CowXIUI fires the matching White Magic remover. Self-casts on `<me>`, party members cured by name. Knows Paralyna, Silena, Stona, Erase, Blindna, Cursna, Viruna, Poisona
- **Click-to-sub-target.** Click a member mid-sub-target and CowXIUI walks the game's own cursor there by simulating arrow-key presses. Wrap-aware shortest path — 6-party with the cursor on row 4 and you click row 2 sends `up 2`, not `down 4`. You press Enter to confirm. Routed through Ashita's input manager so the game runs all its own validation; no memory writes into the target manager
- **Sub-target follow.** Fire `/ma "Cure" <stpc>` and the anchored Target Bar swaps to whoever the cursor is on instead of staying glued to the held mob. Arrow-key the cursor and the bar tracks it. Snaps back when sub-targeting ends
- **Shift+drag.** Plain click targets the member under the cursor; the window only moves while Shift is held. Click-vs-drag is resolved by movement threshold rather than an invisible button, so drags pass straight through to imgui
- **Cure buttons** on party rows (off by default)

**Anchoring:**

- **Anti-flicker on the Target Bar.** The anchor system retains last-known dimensions across invalidations, so the bar lands correctly on the first frame instead of drawing in the wrong place for one frame after re-acquiring a target
- **Cast Cost stacking coordination.** When the Target Bar is enabled but no target is held this frame, Cast Cost stacks flush against the party panel instead of leaving a phantom gap

---

### Pet Bar (Pet HUD)

**Original to this fork.** A comprehensive floating HUD for **BST / DRG / SMN / PUP**.

- HP / TP / MP tracking, plus the BST Ready-charge counter
- Pet portrait images for jug pets, wyverns, all 14 avatars, and spirits
- Pet buff / debuff panel (Stoneskin, Regen, Haste and friends visible on your pet)
- **Charm duration timer** using the PetMe formula with a full 16-slot gear scan and the Familiar +25 min extension. Uses the LSB quintic formula on character level, which is what HorizonXI actually runs — not the BST-level formula from retail references
- **Jug duration timer** backed by an HzXI-accurate pet database, 27 pets sourced from the wiki. Ready charges are 45s on HorizonXI, not retail's 30s
- BST ready-moves list with damage-type icons
- Ability recasts tracked: Reward, Call Beast, Call Wyvern, Spirit Link, Steady Wing, Deep Breathing, Apogee, Mana Cede, Astral Flow, plus the PUP set (Activate, Deactivate, Deploy, Retrieve, Repair, Deus Ex Automata)
- **Clickable.** Any ability or ready-move row fires the matching `/ja` or `/pet`. No macros required
- **2-hour confirmation.** Clicking a 2-hour (Astral Flow, Familiar, Spirit Surge, Overdrive) arms it and prompts "click again to confirm" so you can't fire it by accident
- **Click-to-summon** when no pet is out: Call Wyvern on DRG, Call Beast on BST
- **Per-avatar SMN Blood Pact favourites.** Nested config with all 14 avatars, each with Rage and Ward inputs
- **Per-character jug persistence** across logout, keyed by server ID, surviving desync
- Separate colour themes per pet type (Avatar, Automaton, Charm, Jug, Wyvern)
- Anchored **Pet Target** window showing what your pet is fighting

![Pet HUD Preview](assets/pethud.png)

---

### Player Bar

Your HP / MP / TP / buffs in a floating bar.

**Fork changes:** HP/MP/TP text rendering converted from gdi font primitives to the imgui foreground draw list so text renders on top of the bars. Rest countdown offset, per-value text alignment and offsets, and a TP flash toggle.

---

### Preset

**Original to this fork.** Save and load your entire UI configuration, per screen resolution.

Window positions are absolute pixels, so a layout built at 2560x1440 lands off-screen at 1920x1080. Rather than rescale at runtime — which never quite works, since fonts and bar widths don't scale linearly with the viewport — each resolution gets its own file.

**A preset captures everything:** all 500+ settings, every colour and gradient, every scale and offset, and all window positions. Loading one applies immediately, no reload.

**Shipped presets:** 2560x1440, 1920x1080, 1600x900, 1366x768, 1280x720. The lower-resolution files derive from the 1440p layout with positions and sizes scaled per anchor class — right-edge elements stay pinned right, centered elements stay centered, bottom-anchored elements keep their relationship to the bottom edge. Font sizes scale with a floor of 10px so nothing becomes unreadable.

Only the preset matching your current resolution is offered for loading, which is the whole point of the per-resolution split.

Files live in `modules/presets/<width>x<height>.lua` as plain Lua tables, so they can be hand-edited or shared.

---

### Target Bar

Target info with target-of-target, buffs, and debuffs.

**Fork additions:**

- **Show Enemy ID** (decimal or hex)
- **Always Show Health Percent** — works on friendly / neutral targets where the game normally hides it
- **Subtarget bar** — shows the subtarget cursor selection in its own bar
- **Lock-on border** indicator
- Split cast bar with independent scaling
- Distance, percent, and icon offsets exposed individually
- Outlined text on the foreground draw list to fix text-under-bar bleed

**Mob Info** is configured from this tab: job, level, detection methods, resistances, weaknesses, immunities, server ID. Optionally snaps to the target bar's name text so the two read as one line.

---

### Treasure Pool

Loot display with lot / pass support. **Window rewritten in this fork**, with **BovineLooty** layered on as automation.

**Treasure Pool window:** live tracking of pool items as they drop, with lot counts, per-item timer bars and text, minimise / expand states, and auto-hide when empty.

**BovineLooty** maintains two persisted lists of item IDs and acts on pooled items automatically:

- **Auto-Lot list** — lotted the moment they hit the pool
- **Auto-Pass list** — passed automatically

The safety model matters here, because packet spam gets people flagged:

- **One action per second**, shared across lot and pass, so at most one packet per second total
- **Rolling ceiling** of 10 actions in any 10s window. On hit, the whole queue holds for 5s then resumes
- **Lot-once guard** keyed on `slot + itemId`, not slot alone, because pool slots reindex when items drop out. A given pairing is lotted at most once and cleared when the item leaves the pool
- **Failure handling** — a failed lot (rare/ex, inventory full, already lotted) goes on a 1s cooldown with one retry. A second failure marks it skip-until-exit
- **Mutually exclusive lists** — adding an ID to one removes it from the other, with Lot taking priority on conflict
- **Running defaults to OFF** and must be started each session. The lists persist; the run state doesn't

No packets are parsed. The live pool model is read fresh each tick, so there's no stale-slot race.

**Commands:**

- `/xiui bvl` — toggle the Looty window
- `/xiui bvl start` / `stop` / `toggle` — control the run state
- `/xiui bvl addlot <id>` — add an item ID to Auto-Lot
- `/xiui bvl addpass <id>` — add an item ID to Auto-Pass
- `/xiui bvl rm <id>` — remove an ID from either list
- `/xiui bvl load` / `save` — manage the config file
- `/xiui lot` or `/xiui lotall` — lot every unlotted item right now
- `/xiui pass` or `/xiui passall` — pass every unlotted item right now
- `/xiui tp` — force show / hide the treasure pool window

---

## Cross-cutting Systems

Not tabs, but they run through multiple modules. All original to this fork.

### Window Position System

Every XIUI window stores its position in `gConfig.windowPositions`, so positions travel with presets and survive reloads without depending on `imgui.ini`.

- Positions are captured on the first frame a window renders, whether or not you've ever dragged it
- Changes flush to disk once stable for a second, so dragging doesn't produce a write per frame
- On load, any window lacking an entry is seeded from `imgui.ini`, filtered to XIUI's own windows, with off-screen coordinates clamped back into the viewport
- Anchored windows (in-party Target Bar, anchored Cast Cost, chained Party Lists 2/3, snapped Mob Info, stacked notifications) skip both save and apply while anchored, since their position is derived rather than chosen

### Window Anchor System

Several windows snap to each other rather than holding independent positions:

- **In-party Target Bar** anchors above Party 1. No separate position option; it's always tied to Party 1
- **Cast Cost** can optionally anchor above the in-party Target Bar (Party List → "Anchor Cast Cost to Party List"). Off by default, in which case it free-floats
- **Party List 2 / 3** chain below Party 1
- **Mob Info** can snap to the target bar's name text
- **Pet Target** anchors below the Pet Bar

The anchor system retains last-known dimensions across frames where the parent isn't drawn, which is what fixes the anti-flicker behaviour. Children fall back gracefully when a parent isn't visible.

### Sub-target Behaviour

Three connected pieces, all configured under Party List but woven through the in-party Target Bar and the click handler:

1. **In-party Target Bar follows the sub-target** — shows the cursor selection, not the held mob
2. **Click-to-sub-target** — clicking a member mid-sub-target navigates the game's cursor there via simulated arrow keys
3. **Member dots and highlight** track sub-target state (yellow targeted box on the cursor selection, plus the original target where relevant)

Routed through the game's own keyboard input path rather than memory writes, so FFXI's "is this a valid sub-target candidate" validation keeps running normally.

### Modern Theme

Clean dark-blue panel look, switchable in **Global → General**. Affects party list, alliance lists, in-party Target Bar, and Cast Cost together. Cast Cost keeps an independent toggle if you want the panels split. `patternedBackground` re-enables the old texture on top of the modern base.

---

## Installation (detailed)

1. Download: [cowrevenge/CowXIUI main.zip](https://github.com/cowrevenge/CowXIUI/archive/refs/heads/main.zip)
2. Extract the `.zip`. You'll get a directory called `CowXIUI-main`
3. Rename it to `XIUI`. The addon registers internally as `xiui`, so the folder name must match
4. **Delete your existing `XIUI` folder** in `HorizonXI\Game\addons` and drop this one in its place. This is a complete install, not an overlay
5. Coming from the old HXUI fork? Leave the `HXUI` folder where it is as a fallback
6. Copy the new `XIUI` folder into `HorizonXI\Game\addons`
7. **Recommended:** select XIUI in the HorizonXI launcher so it auto-loads
8. Don't load both XIUI and HXUI at once. You can, but you'll be very confused
9. Manual load in-game: `/addon load xiui`
10. Open the config: `/xiui`
11. **Preset tab → Load Preset** for your resolution

---

## Updating

1. Fresh, pre-configured install. Out of the box it ships in the intended look
2. Before installing a new release, delete the old `XIUI` folder first. Asset directories change between versions and leftover files sometimes collide
3. Re-load your resolution preset after updating if you want the shipped layout back
4. Patch notes display automatically in-game on the first load after an update

---

## Known Todo

- Anchored Target Bar (in-party): treasure / status icons aren't rendering on it yet, and NPC status isn't read correctly. Sub-target follow, flicker, and stacking are all sorted.

---

## Credits and License

- Upstream: [tirem/XIUI](https://github.com/tirem/XIUI) and its predecessor [tirem/HXUI](https://github.com/tirem/HXUI). Massive thanks to the original authors — the module set, config framework, and hotbar all come from there.
- Hotbar concepts originally adapted from [XIVHotbar2](https://github.com/Technyze/XIVHotbar2) (SirEdeonX, Akirane, Technyze) under BSD licence.
- **Original to this fork:** Pet HUD, Combat Timers, Latent Trial, Dedication, the Preset system, BovineLooty, integrated Hideparty (including spell/ability info suppression), the window position and anchor systems, click-to-target, click-to-debuff-cure, click-to-sub-target, sub-target follow, and the Enemy List / Party List / Cast Cost / Treasure Pool rewrites.
- Jug pet data from the [HorizonXI wiki](https://horizonffxi.wiki/Category:Familiars).
- Weapon skill point values from the [HorizonXI wiki](https://horizonffxi.wiki/Weapon_Skill_Points).
- Resting tick cadence verified against [LandSandBoat](https://github.com/LandSandBoat/server) server source.
- Licensed under **GPL-3.0**, matching upstream.

---

## Issues and Contributions

Bug reports and feature requests specific to this fork: [CowXIUI issue tracker](https://github.com/cowrevenge/CowXIUI/issues). Please don't file them upstream against tirem/XIUI or tirem/HXUI; the original maintainers aren't responsible for fork behaviour. PRs welcome.
