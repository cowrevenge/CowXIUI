--[[
* MIT License
*
* Copyright (c) 2023 tirem [github.com/tirem]
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
]]--

-- Modified fork maintained by shadowcaw for HorizonXI. Based on XIUI by
-- Team XIUI (tirem, github.com/tirem/XIUI), used under the MIT License above.
-- Changes include HorizonXI-targeted command aliases, pet buff bar/HUD
-- handling, click-to-cure party menus, and treasure pool lotting.

addon.name      = 'XIUI';
addon.author    = 'shadowcow (fork of XIUI by Team XIUI / tirem)';
addon.version   = '1.7';
addon.desc      = 'HorizonXI UI suite: party/target/pet bars, pet buff HUD, click-to-cure party menus';
addon.link      = 'https://github.com/tirem/XIUI'

-- Ashita version targeting (for ImGui compatibility)
_G._XIUI_USE_ASHITA_4_3 = false;
require('handlers.imgui_compat');

require('common');
local settings = require('settings');
local chat = require('chat');
local gdi = require('submodules.gdifonts.include');

-- Core modules
local settingsDefaults = require('core.settings.init');
local settingsMigration = require('core.settings.migration');
local settingsUpdater = require('core.settings.updater');
local gameState = require('core.gamestate');
local uiModules = require('core.moduleregistry');

-- UI modules
local uiMods = require('modules.init');
local playerBar = uiMods.playerbar;
local targetBar = uiMods.targetbar;
local enemyList = uiMods.enemylist;
local expBar = uiMods.expbar;
local gilTracker = uiMods.giltracker;
local inventoryTracker = uiMods.inventory.inventory;
local satchelTracker = uiMods.inventory.satchel;
local lockerTracker = uiMods.inventory.locker;
local safeTracker = uiMods.inventory.safe;
local storageTracker = uiMods.inventory.storage;
local wardrobeTracker = uiMods.inventory.wardrobe;
local partyList = uiMods.partylist;
local castBar = uiMods.castbar;
local petBar = uiMods.petbar;
local castCost = uiMods.castcost;
local notifications = uiMods.notifications;
local treasurePool = uiMods.treasurepool;
local bovinelatent = uiMods.bovinelatent;
local bovinededication = uiMods.bovinededication;
local bovinecombat = uiMods.bovinecombat;
local hotbar = uiMods.hotbar;
-- Hotbar helper modules used directly from XIUI.lua (packet routing, palette
-- persistence, skillchain WS highlighting, deferred slot tooltip flush).
local macropalette = require('modules.hotbar.macropalette');
local palette = require('modules.hotbar.palette');
local skillchainModule = require('modules.hotbar.skillchain');
local slotrenderer = require('modules.hotbar.slotrenderer');
local imtext = require('libs.imtext');
local components = require('config.components');
local configMenu = require('config');
local debuffHandler = require('handlers.debuffhandler');
local petBuffHandler = require('handlers.petbuffhandler');
local actionTracker = require('handlers.actiontracker');
local mobInfo = require('modules.mobinfo.init');
local statusHandler = require('handlers.statushandler');
local progressbar = require('libs.progressbar');
local TextureManager = require('libs.texturemanager');

-- Global switch to hard-disable functionality that is limited on HX servers
HzLimitedMode = true;

-- Raw controller-input debug: when true, the xinput/dinput button handlers log
-- every event before hotbar processing. Toggled via /xiui debug rawinput.
DEBUG_RAW_INPUT = false;

-- =================
-- = XIUI DEV ONLY =
-- =================
local _XIUI_DEV_HOT_RELOADING_ENABLED = false;
local _XIUI_DEV_HOT_RELOAD_POLL_TIME_SECONDS = 1;
local _XIUI_DEV_HOT_RELOAD_LAST_RELOAD_TIME;
local _XIUI_DEV_HOT_RELOAD_FILES = {};

-- Local split function for hot reload (avoids monkeypatching string metatable)
local function _split_string(str, sep)
    sep = sep or ":";
    local fields = {};
    local pattern = string.format("([^%s]+)", sep);
    str:gsub(pattern, function(c) fields[#fields + 1] = c end);
    return fields;
end

function _check_hot_reload()
    local path = string.gsub(addon.path, '\\\\', '\\');
    local result = io.popen("forfiles /P " .. path .. ' /M *.lua /C "cmd /c echo @file @fdate @ftime"');
    local needsReload = false;

    for line in result:lines() do
        if #line > 0 then
            local splitLine = _split_string(line, " ");
            local filename = splitLine[1];
            local dateModified = splitLine[2];
            local timeModified = splitLine[3];
            filename = string.gsub(filename, '"', '');
            local fileTable = {dateModified, timeModified};

            if _XIUI_DEV_HOT_RELOAD_FILES[filename] ~= nil then
                if table.concat(_XIUI_DEV_HOT_RELOAD_FILES[filename]) ~= table.concat(fileTable) then
                    needsReload = true;
                    print("[XIUI] Development file " .. filename .. " changed, reloading XIUI.")
                end
            end
            _XIUI_DEV_HOT_RELOAD_FILES[filename] = fileTable;
        end
    end
    result:close();

    if needsReload then
        AshitaCore:GetChatManager():QueueCommand(-1, '/addon reload xiui', channelCommand);
    end
end
-- ==================
-- = /XIUI DEV ONLY =
-- ==================

-- Register all UI modules
uiModules.Register('playerBar', {
    module = playerBar,
    settingsKey = 'playerBarSettings',
    configKey = 'showPlayerBar',
    hideOnEventKey = 'playerBarHideDuringEvents',
    hasSetHidden = true,
});
uiModules.Register('targetBar', {
    module = targetBar,
    settingsKey = 'targetBarSettings',
    configKey = 'showTargetBar',
    hideOnEventKey = 'targetBarHideDuringEvents',
    hasSetHidden = true,
});
uiModules.Register('enemyList', {
    module = enemyList,
    settingsKey = 'enemyListSettings',
    configKey = 'showEnemyList',
    hasSetHidden = true,
});
uiModules.Register('expBar', {
    module = expBar,
    settingsKey = 'expBarSettings',
    configKey = 'showExpBar',
    hasSetHidden = true,
});
uiModules.Register('gilTracker', {
    module = gilTracker,
    settingsKey = 'gilTrackerSettings',
    configKey = 'showGilTracker',
    hasSetHidden = true,
});
uiModules.Register('inventoryTracker', {
    module = inventoryTracker,
    settingsKey = 'inventoryTrackerSettings',
    configKey = 'showInventoryTracker',
    hasSetHidden = true,
});
uiModules.Register('satchelTracker', {
    module = satchelTracker,
    settingsKey = 'satchelTrackerSettings',
    configKey = 'showSatchelTracker',
    hasSetHidden = true,
});
uiModules.Register('lockerTracker', {
    module = lockerTracker,
    settingsKey = 'lockerTrackerSettings',
    configKey = 'showLockerTracker',
    hasSetHidden = true,
});
uiModules.Register('safeTracker', {
    module = safeTracker,
    settingsKey = 'safeTrackerSettings',
    configKey = 'showSafeTracker',
    hasSetHidden = true,
});
uiModules.Register('storageTracker', {
    module = storageTracker,
    settingsKey = 'storageTrackerSettings',
    configKey = 'showStorageTracker',
    hasSetHidden = true,
});
uiModules.Register('wardrobeTracker', {
    module = wardrobeTracker,
    settingsKey = 'wardrobeTrackerSettings',
    configKey = 'showWardrobeTracker',
    hasSetHidden = true,
});
uiModules.Register('partyList', {
    module = partyList,
    settingsKey = 'partyListSettings',
    configKey = 'showPartyList',
    hideOnEventKey = 'partyListHideDuringEvents',
    hasSetHidden = true,
});
uiModules.Register('castBar', {
    module = castBar,
    settingsKey = 'castBarSettings',
    configKey = 'showCastBar',
    hasSetHidden = true,
});
uiModules.Register('castCost', {
    module = castCost,
    settingsKey = 'castCostSettings',
    configKey = 'showCastCost',
    hasSetHidden = true,
});
uiModules.Register('mobInfo', {
    module = mobInfo.display,
    settingsKey = 'mobInfoSettings',
    configKey = 'showMobInfo',
    hasSetHidden = true,
});
uiModules.Register('petBar', {
    module = petBar,
    settingsKey = 'petBarSettings',
    configKey = 'showPetBar',
    hideOnEventKey = 'petBarHideDuringEvents',
    hasSetHidden = true,
});
uiModules.Register('hotbar', {
    module = hotbar,
    settingsKey = 'hotbarSettings',
    configKey = 'showhotbar',
    hideOnEventKey = 'hotbarHideDuringEvents',
    hasSetHidden = true,
});
uiModules.Register('notifications', {
    module = notifications,
    settingsKey = 'notificationsSettings',
    configKey = 'showNotifications',
    hideOnEventKey = 'notificationsHideDuringEvents',
    hasSetHidden = true,
});
uiModules.Register('treasurePool', {
    module = treasurePool,
    settingsKey = 'treasurePoolSettings',
    configKey = 'treasurePoolEnabled',
    hasSetHidden = true,
});
uiModules.Register('bovinelatent', {
    module = bovinelatent,
    settingsKey = 'bovinelatentSettings',
    configKey = 'showBovinelatent',
    hasSetHidden = true,
});
uiModules.Register('bovinededication', {
    module = bovinededication,
    settingsKey = 'bovinededicationSettings',
    configKey = 'showBovinededication',
    hasSetHidden = true,
});
uiModules.Register('bovinecombat', {
    module = bovinecombat,
    settingsKey = 'bovinecombatSettings',
    configKey = 'showBovinecombat',
    hasSetHidden = true,
});

-- Initialize settings from defaults
local user_settings_container = T{
    userSettings = settingsDefaults.user_settings;
};

gAdjustedSettings = deep_copy_table(settingsDefaults.default_settings);
defaultUserSettings = deep_copy_table(settingsDefaults.user_settings);

-- Run HXUI file migration BEFORE loading settings (so migrated files are picked up)
local migrationResult = settingsMigration.MigrateFromHXUI();

-- Load settings and run structure migrations
local config = settings.load(user_settings_container);
gConfig = config.userSettings;
gConfigVersion = 0; -- Incremented on settings changes for cache invalidation
settingsMigration.RunStructureMigrations(gConfig, defaultUserSettings);

-- ============================================================================
-- StartKey migration:
-- Acts as a "settings version" check. If the user's saved StartKey doesn't
-- match the StartKey baked into the current defaults (from myconfig.lua),
-- replace their settings with the current defaults, preserving on-screen
-- window positions. Bump StartKey in myconfig.lua any time you want every
-- existing user to pick up the new defaults on next load.
--   Fires whenever the keys don't match - includes fresh installs (user
-- has nil, defaults have 1) and version bumps (user has 1, defaults now 2).
-- ============================================================================
local expectedStartKey = defaultUserSettings.StartKey;
if gConfig.StartKey ~= expectedStartKey then
    -- Window/position settings that must survive the reset (per-user placement).
    local POSITION_KEYS = {
        'partyListState',
        'gilTrackerPosOffset',
        'bsthudPosX', 'bsthudPosY',
        'petBarWindowPosX', 'petBarWindowPosY',
    };

    -- Stash the user's current positions.
    local preserved = {};
    for _, k in ipairs(POSITION_KEYS) do
        if gConfig[k] ~= nil then
            preserved[k] = deep_copy_table(gConfig[k]);
        end
    end

    -- Replace the user's settings with a fresh copy of the defaults.
    gConfig = deep_copy_table(defaultUserSettings);

    -- Restore the preserved window positions.
    for k, v in pairs(preserved) do
        gConfig[k] = v;
    end

    -- Stamp the current expected StartKey so this migration won't run again
    -- until you bump the value in myconfig.lua.
    gConfig.StartKey = expectedStartKey;

    -- Point the loaded config container at the new table and persist it.
    config.userSettings = gConfig;
    settings.save();
end

-- Show migration message after settings are loaded (deferred to ensure chat is ready)
if migrationResult and migrationResult.count > 0 then
    ashita.tasks.once(1, function()
        print('[XIUI] Successfully migrated settings for ' .. migrationResult.count .. ' character(s) from HXUI.');
    end);
end

-- State variables
showConfig = { false };
local pendingVisualUpdate = false;
bLoggedIn = gameState.CheckLoggedIn();
local bInitialized = false;
local wasInParty = false;  -- Tracks party state for detecting party leave

-- Check if player is currently in a party (has other members)
local function IsInParty()
    local party = AshitaCore:GetMemoryManager():GetParty();
    if party == nil then return false; end
    -- Check if any other party members (slots 1-5) are active
    for i = 1, 5 do
        if party:GetMemberIsActive(i) == 1 then
            return true;
        end
    end
    return false;
end

-- Helper function to get party settings by index (1=A, 2=B, 3=C)
function GetPartySettings(partyIndex)
    if partyIndex == 3 then return gConfig.partyC;
    elseif partyIndex == 2 then return gConfig.partyB;
    else return gConfig.partyA;
    end
end

-- Helper function to get layout template for a party
function GetLayoutTemplate(partyIndex)
    local party = GetPartySettings(partyIndex);
    return party.layout == 1 and gConfig.layoutCompact or gConfig.layoutHorizontal;
end

function ResetSettings()
    gConfig = deep_copy_table(defaultUserSettings);
    config.userSettings = gConfig;
    UpdateSettings();
    settings.save();
end

function SavePartyListLayoutSetting(key, value)
    local currentLayout = (gConfig.partyListLayout == 1) and gConfig.partyListLayout2 or gConfig.partyListLayout1;
    currentLayout[key] = value;
end

function CheckVisibility()
    uiModules.CheckVisibility(gConfig);
end

function UpdateUserSettings()
    gConfigVersion = gConfigVersion + 1; -- Notify caches of settings change (for real-time slider updates)
    settingsUpdater.UpdateUserSettings(gAdjustedSettings, settingsDefaults.default_settings, gConfig);
end

function SaveSettingsToDisk()
    if gConfig.colorCustomization == nil then
        gConfig.colorCustomization = deep_copy_table(defaultUserSettings.colorCustomization);
    end
    gConfigVersion = gConfigVersion + 1; -- Notify caches of settings change
    settings.save();
end

function SaveSettingsOnly()
    if gConfig.colorCustomization == nil then
        gConfig.colorCustomization = deep_copy_table(defaultUserSettings.colorCustomization);
    end
    gConfigVersion = gConfigVersion + 1; -- Notify caches of settings change
    settings.save();
    UpdateUserSettings();
end

-- Module-specific visual updaters (includes disk save - use for dropdowns, checkboxes)
UpdatePlayerBarVisuals = uiModules.CreateVisualUpdater('playerBar', SaveSettingsOnly, gAdjustedSettings);
UpdateTargetBarVisuals = uiModules.CreateVisualUpdater('targetBar', SaveSettingsOnly, gAdjustedSettings);
UpdatePartyListVisuals = uiModules.CreateVisualUpdater('partyList', SaveSettingsOnly, gAdjustedSettings);
UpdateEnemyListVisuals = uiModules.CreateVisualUpdater('enemyList', SaveSettingsOnly, gAdjustedSettings);
UpdateExpBarVisuals = uiModules.CreateVisualUpdater('expBar', SaveSettingsOnly, gAdjustedSettings);
UpdateInventoryTrackerVisuals = uiModules.CreateVisualUpdater('inventoryTracker', SaveSettingsOnly, gAdjustedSettings);
UpdateCastBarVisuals = uiModules.CreateVisualUpdater('castBar', SaveSettingsOnly, gAdjustedSettings);
UpdateCastCostVisuals = uiModules.CreateVisualUpdater('castCost', SaveSettingsOnly, gAdjustedSettings);

function UpdateGilTrackerVisuals()
    UpdateUserSettings();
    gilTracker.UpdateVisuals(gAdjustedSettings.gilTrackerSettings);
end

function UpdateSettings()
    SaveSettingsOnly();
    CheckVisibility();
    -- Clear cached colors to pick up new settings
    InvalidateInterpolationColorCache();
    InvalidateColorCaches();
    uiModules.UpdateVisualsAll(gAdjustedSettings);
end

function DeferredUpdateVisuals()
    pendingVisualUpdate = true;
end

settings.register('settings', 'settings_update', function (s)
    if (s ~= nil) then
        config = s;
        gConfig = config.userSettings;
        UpdateSettings();
    end
end);

--[[
* Event Handlers
]]--

ashita.events.register('d3d_present', 'present_cb', function ()
    if not bInitialized then return; end

    -- Process deferred hotbar icon-cache clears scheduled by macro CRUD last
    -- frame. Runs before any rendering this frame so stale caches don't produce
    -- wrong icons. Guarded: only fires when the hotbar module is present.
    if gConfig.hotbarEnabled and macropalette and macropalette.FlushPendingFrameWork then
        pcall(macropalette.FlushPendingFrameWork);
    end

    -- Process pending visual updates outside the render loop. Wrapped in pcall
    -- so a broken module's UpdateVisuals can't take down the present chain
    -- (which would also prevent the config menu from rendering and recovering).
    if pendingVisualUpdate then
        pendingVisualUpdate = false;
        local ok, err = pcall(function()
            statusHandler.clear_cache();
            UpdateUserSettings();
            uiModules.UpdateVisualsAll(gAdjustedSettings);
        end);
        if not ok then
            _xiuiPendingVisualErrLogged = _xiuiPendingVisualErrLogged or {};
            local key = tostring(err);
            if not _xiuiPendingVisualErrLogged[key] then
                _xiuiPendingVisualErrLogged[key] = true;
                local okp = pcall(function()
                    print(chat.header('XIUI'):append(chat.error(
                        'pendingVisualUpdate error: ' .. tostring(err))));
                end);
                if not okp then
                    print('[XIUI] pendingVisualUpdate error: ' .. tostring(err));
                end
            end
        end
    end

    -- Render config menu FIRST, in its own pcall. Recovery path: if ANY module
    -- is broken below, the menu still comes up so the user can locate and
    -- disable the offender. configMenu.DrawWindow is a near no-op when the
    -- menu is closed (showConfig[1] == false). Imgui z-order is independent
    -- of draw order so the menu still appears on top of module windows.
    do
        local ok, err = pcall(configMenu.DrawWindow);
        if not ok then
            _xiuiConfigMenuErrLogged = _xiuiConfigMenuErrLogged or {};
            local key = tostring(err);
            if not _xiuiConfigMenuErrLogged[key] then
                _xiuiConfigMenuErrLogged[key] = true;
                -- Print via chat if available, else fall back to plain print so
                -- the handler itself can never crash the present loop.
                local okp = pcall(function()
                    print(chat.header('XIUI'):append(chat.error(
                        'configMenu error: ' .. tostring(err))));
                end);
                if not okp then
                    print('[XIUI] configMenu error: ' .. tostring(err));
                end
            end
        end
    end

    local eventSystemActive = gameState.GetEventSystemActive();

    if not gameState.ShouldHideUI(gConfig.hideDuringEvents, bLoggedIn) then
        -- Sync treasure pool from memory (authoritative source of truth).
        -- Wrapped so a packet/memory edge case here can't gate module rendering.
        if gConfig.showNotifications then
            pcall(notifications.SyncTreasurePoolFromMemory);
            -- Check pending pool items - creates "Treasure Pool" notification if item
            -- hasn't been awarded (0x00D3) within 200ms of dropping (0x00D2)
            pcall(notifications.CheckPendingPoolNotifications);
        end

        -- Render all registered modules. Each call is pcall-wrapped inside
        -- uiModules.RenderModule (see core/moduleregistry.lua), so one broken
        -- module no longer takes out the rest of the chain.
        for name, _ in pairs(uiModules.GetAll()) do
            uiModules.RenderModule(name, gConfig, gAdjustedSettings, eventSystemActive);
        end

        -- Drive Treasure Pool preview from (config menu open AND Preview checked).
        -- This persists the checkbox across loads (the setting lives in gConfig)
        -- while only rendering mock items while the menu is open -- and clears
        -- automatically when the menu closes (showConfig[1] == false below).
        if treasurePool and treasurePool.SetPreview then
            pcall(function()
                local wantPreview = (showConfig[1] == true) and (gConfig.treasurePoolPreview == true);
                if treasurePool.IsPreviewActive() ~= wantPreview then
                    treasurePool.SetPreview(wantPreview);
                end
            end);
        end

        -- Render deferred hotbar slot tooltip last so it draws on top of all
        -- module windows (correct z-order). Guarded for hotbar presence.
        if gConfig.hotbarEnabled and slotrenderer and slotrenderer.FlushTooltip then
            pcall(slotrenderer.FlushTooltip);
        end
    else
        pcall(uiModules.HideAll);
    end

    -- XIUI DEV ONLY
    if _XIUI_DEV_HOT_RELOADING_ENABLED then
        local currentTime = os.time();
        if not _XIUI_DEV_HOT_RELOAD_LAST_RELOAD_TIME then
            _XIUI_DEV_HOT_RELOAD_LAST_RELOAD_TIME = currentTime;
        end
        if currentTime - _XIUI_DEV_HOT_RELOAD_LAST_RELOAD_TIME > _XIUI_DEV_HOT_RELOAD_POLL_TIME_SECONDS then
            _check_hot_reload();
            _XIUI_DEV_HOT_RELOAD_LAST_RELOAD_TIME = currentTime;
        end
    end
end);

ashita.events.register('load', 'load_cb', function ()
    UpdateUserSettings();

    -- Reset the applied-positions guard so every window re-applies its saved
    -- position once after a load/reload. ApplyWindowPosition() (handlers/
    -- helpers.lua) flips each entry to true after applying; without this reset
    -- the guard stays true across reloads and hotbar windows never restore.
    if gConfig then gConfig.appliedPositions = {}; end

    -- Auto update. When enabled, this diffs against the repo manifest on load
    -- and downloads any changed files, then reloads the addon so the new code
    -- actually takes effect.
    --
    -- Timing note: by the time this load event fires, every .lua is already
    -- loaded into memory. Overwriting them now does NOT change the running
    -- session -- which is exactly why the reload at the end is required, not
    -- optional. Without it you'd be running old code against new files until
    -- the next manual reload.
    --
    -- The _XIUI_AUTOUPDATE_DONE global guards against a reload loop: it
    -- survives the addon reload (Ashita globals persist for the session), so
    -- the second pass skips the check entirely.
    if gConfig and gConfig.autoUpdateCheck and not _XIUI_AUTOUPDATE_DONE then
        _XIUI_AUTOUPDATE_DONE = true;

        local ok, updater = pcall(require, 'libs.updater');
        if ok and updater then
            pcall(function()
                -- Check() is a blocking HTTPS call; it returns true only when
                -- the remote version is newer AND files actually differ.
                if updater.Check() and updater.updateReady then
                    print(chat.header('XIUI'):append(chat.message(
                        'Auto update: ' .. tostring(updater.message))));

                    if updater.Update() then
                        print(chat.header('XIUI'):append(chat.message(
                            'Auto update complete, reloading...')));
                        AshitaCore:GetChatManager():QueueCommand(-1, '/addon reload xiui');
                    else
                        print(chat.header('XIUI'):append(chat.error(
                            'Auto update failed: ' .. tostring(updater.message))));
                    end
                end
            end);
        end
    end

    -- Populate the ImGui font atlas now, before the first d3d_present, so no
    -- font selection in the hotbar/config has to mutate the atlas mid-frame
    -- (which crashes on Ashita 4.16). See libs/imtext.lua PrewarmFonts notes.
    if imtext and imtext.PrewarmFonts then
        pcall(imtext.PrewarmFonts, components.available_fonts);
    end

    uiModules.InitializeAll(gAdjustedSettings);

    -- Load mob data for current zone
    local party = AshitaCore:GetMemoryManager():GetParty();
    if party then
        local currentZone = party:GetMemberZone(0);
        if currentZone and currentZone > 0 then
            mobInfo.data.LoadZone(currentZone);
        end
    end

    bInitialized = true;
end);

ashita.events.register('unload', 'unload_cb', function ()
    ashita.events.unregister('d3d_present', 'present_cb');
    ashita.events.unregister('packet_in', 'packet_in_cb');
    ashita.events.unregister('command', 'command_cb');
    ashita.events.unregister('key', 'key_cb');
    ashita.events.unregister('xinput_state', 'xinput_state_cb');
    ashita.events.unregister('xinput_button', 'xinput_button_cb');
    ashita.events.unregister('dinput_button', 'dinput_button_cb');
    ashita.events.unregister('dinput_state', 'dinput_state_cb');

    -- Persist any pending hotbar/palette edits before teardown.
    if macropalette and macropalette.IsHotbarDirty and macropalette.IsHotbarDirty() then
        SaveSettingsToDisk();
        macropalette.ClearHotbarDirty();
    end
    if palette and palette.IsPaletteStateDirty and palette.IsPaletteStateDirty() then
        SaveSettingsToDisk();
        palette.ClearPaletteStateDirty();
    end

    statusHandler.clear_cache();
    progressbar.Cleanup();
    TextureManager.clear();
    if ClearDebuffFontCache then ClearDebuffFontCache(); end

    uiModules.CleanupAll();

    if mobInfo.data and mobInfo.data.Cleanup then
        mobInfo.data.Cleanup();
    end

    gdi:destroy_interface();
end);

ashita.events.register('command', 'command_cb', function (e)
    local command_args = e.command:lower():args()
    if table.contains({'/xiui', '/hui', '/hxui', '/horizonxiui'}, command_args[1]) then
        e.blocked = true;

        if (#command_args == 1) then
            showConfig[1] = not showConfig[1];
            return;
        end

        if (#command_args == 2 and command_args[2]:any('partylist')) then
            gConfig.showPartyList = not gConfig.showPartyList;
            CheckVisibility();
            return;
        end

        -- Lot all unlotted items: /xiui lotall or /xiui lot
        if (#command_args == 2 and command_args[2]:any('lotall', 'lot')) then
            treasurePool.LotAll();
            return;
        end

        -- Pass all unlotted items: /xiui passall or /xiui pass
        if (#command_args == 2 and command_args[2]:any('passall', 'pass')) then
            treasurePool.PassAll();
            return;
        end

        -- Toggle treasure pool window: /xiui tp
        if (#command_args == 2 and command_args[2]:any('tp', 'treasurepool', 'pool')) then
            treasurePool.ToggleForceShow();
            return;
        end

        -- BovineLooty auto-pass: /xiui bvl toggles the window;
        -- /xiui bvl start|stop|toggle controls the auto-pass run state.
        if (#command_args >= 2 and command_args[2]:any('bvl', 'bovinelooty', 'loot')) then
            if (#command_args >= 3 and command_args[3]:any('start', 'on')) then
                treasurePool.BovineLootyStart();
                print('[XIUI] BovineLooty STARTED');
            elseif (#command_args >= 3 and command_args[3]:any('stop', 'off')) then
                treasurePool.BovineLootyStop();
                print('[XIUI] BovineLooty STOPPED');
            elseif (#command_args >= 3 and command_args[3]:any('toggle')) then
                local nowRun = treasurePool.BovineLootyToggleRun();
                print('[XIUI] BovineLooty ' .. (nowRun and 'STARTED' or 'STOPPED'));
            elseif (#command_args >= 3 and command_args[3]:any('load')) then
                treasurePool.BovineLootyLoad();
            elseif (#command_args >= 3 and command_args[3]:any('save')) then
                treasurePool.BovineLootySave();
            elseif (#command_args >= 4 and command_args[3]:any('addlot')) then
                local id = tonumber(command_args[4]);
                if id then treasurePool.BovineLootyAddLot(id); print('[XIUI] added ' .. id .. ' to Auto-Lot'); end
            elseif (#command_args >= 4 and command_args[3]:any('addpass')) then
                local id = tonumber(command_args[4]);
                if id then treasurePool.BovineLootyAddPass(id); print('[XIUI] added ' .. id .. ' to Auto-Pass'); end
            elseif (#command_args >= 4 and command_args[3]:any('rm', 'remove')) then
                local id = tonumber(command_args[4]);
                if id then treasurePool.BovineLootyRemove(id); print('[XIUI] removed ' .. id); end
            else
                local open = treasurePool.BovineLootyToggleWindow();
                print('[XIUI] BovineLooty window ' .. (open and 'shown' or 'hidden'));
            end
            return;
        end

        -- Test notification command: /xiui testnotif [type]
        -- Pet buff pipeline diagnostic: /xiui petbuff
        -- Reports whether the handler is loaded, whether it sees the pet, and
        -- what effects it's currently tracking. Use when the pet status row
        -- isn't updating to narrow down what's missing.
        if (command_args[2] == 'petbuff') then
            print('[XIUI] --- Pet buff pipeline ---');
            print(('  petBuffHandler  : %s'):format(petBuffHandler and 'LOADED' or 'MISSING'));
            local pe = GetPlayerEntity and GetPlayerEntity() or nil;
            if pe then
                print(('  PetTargetIndex  : %s'):format(tostring(pe.PetTargetIndex)));
                if pe.PetTargetIndex and pe.PetTargetIndex ~= 0 and GetEntity then
                    local petEnt = GetEntity(pe.PetTargetIndex);
                    if petEnt then
                        print(('  pet Name/Server : %s / %s'):format(tostring(petEnt.Name), tostring(petEnt.ServerId)));
                    end
                end
            else
                print('  GetPlayerEntity : unavailable');
            end
            if petBuffHandler and petBuffHandler.GetActiveEffects then
                local ok, ids, times = pcall(petBuffHandler.GetActiveEffects);
                if ok and ids then
                    print(('  active effects  : %d'):format(#ids));
                    for i = 1, #ids do
                        print(('    #%d id=%d time=%s'):format(i, ids[i], tostring(times and times[i] or 'nil')));
                    end
                else
                    print('  active effects  : 0 (or error)');
                end
            end
            return;
        end

        -- Test notification command: /xiui testnotif [type]
        if (command_args[2] == 'testnotif') then
            local testType = tonumber(command_args[3]) or 5;  -- default to ITEM_OBTAINED
            notifications.TestNotification(testType, {
                itemId = 4096,  -- Hi-Potion
                itemName = 'Hi-Potion',
                quantity = 1,
                playerName = 'TestPlayer',
                amount = 5000,
            });
            return;
        end

        -- Test treasure pool with 10 items: /xiui testpool10
        if (command_args[2] == 'testpool10') then
            notifications.TestTreasurePool10();
            return;
        end

        -- Stress test treasure pool with 25 items: /xiui testpool25
        if (command_args[2] == 'testpool25') then
            notifications.TestTreasurePool25();
            return;
        end

        -- Test pool only (no toasts) - for crash isolation: /xiui testpoolonly
        if (command_args[2] == 'testpoolonly') then
            notifications.TestPoolOnly();
            return;
        end

        -- Test toasts only (no pool) - for crash isolation: /xiui testtoastsonly
        if (command_args[2] == 'testtoastsonly') then
            notifications.TestToastsOnly();
            return;
        end

        -- Reset gil tracking: /xiui gil reset (or legacy: /xiui resetgil)
        if (command_args[2] == 'gil' and command_args[3] == 'reset') or (command_args[2] == 'resetgil') then
            gilTracker.ResetTracking();
            return;
        end

        -- ============================================
        -- Hotbar Commands
        -- ============================================

        -- Toggle the native macro palette: /xiui macro
        if (#command_args == 2 and command_args[2]:any('macro', 'macros')) then
            macropalette.TogglePalette();
            return;
        end

        -- Open the keybind editor: /xiui keybinds [bar]
        if (#command_args >= 2 and command_args[2]:any('keybinds', 'keybind', 'binds', 'bind')) then
            local hotbarConfig = require('config.hotbar');
            local barIndex = tonumber(command_args[3]) or 1;
            hotbarConfig.OpenKeybindEditor(barIndex);
            return;
        end

        -- Execute a hotbar slot (invoked by the Ashita /bind system):
        --   /xiui hotbar <bar> <slot>
        if (command_args[2] == 'hotbar' and #command_args >= 4) then
            local barIndex = tonumber(command_args[3]);
            local slotIndex = tonumber(command_args[4]);
            if barIndex and slotIndex then
                local hotbarActions = require('modules.hotbar.actions');
                hotbarActions.HandleKeybind(barIndex, slotIndex);
            end
            return;
        end

        -- Palette commands: /xiui palette <name|next|prev|list|first> [bar|all|crossbar]
        -- Hotbar palettes (bars 1-6) and the crossbar have separate palette pools;
        -- "all" spans both, "crossbar"/"cb"/"xb" targets the crossbar only, a bar
        -- number targets one hotbar.
        if (command_args[2] == 'palette' or command_args[2] == 'pal') then
            local paletteModule = require('modules.hotbar.palette');
            local hotbarData = require('modules.hotbar.data');
            local jobId = hotbarData.jobId or 1;
            local subjobId = hotbarData.subjobId or 0;

            -- Bare "/xiui palette" opens the palette manager.
            if #command_args < 3 then
                require('config.palettemanager').Open();
                return;
            end

            if command_args[3] == 'help' then
                print('[XIUI] Palette commands:');
                print('  /xiui palette                            - Open the palette manager');
                print('  /xiui palette help                       - Show this help');
                print('  /xiui palette <name> [bar|all|crossbar] - Switch to a named palette');
                print('  /xiui palette next [crossbar]            - Cycle to next palette');
                print('  /xiui palette prev [crossbar]            - Cycle to previous palette');
                print('  /xiui palette list [crossbar]            - List available palettes');
                print('  /xiui palette first [crossbar]           - Switch to first palette');
                print('');
                print('Target: omit for hotbars + crossbar, "crossbar"/"cb"/"xb" for crossbar only,');
                print('or a bar number 1-6 to target a single hotbar.');
                print('Keybinds: Ctrl+Up/Down (configure in Hotbar > Palette Cycling)');
                print('Controller: RB + Dpad Up/Down cycles palettes');
                return;
            end

            local action = command_args[3];
            local barArg = command_args[4];

            local function isCrossbarTarget(arg)
                if not arg then return false; end
                local lower = arg:lower();
                return lower == 'crossbar' or lower == 'cb' or lower == 'xb';
            end

            local affectAll = (barArg == 'all');
            local affectCrossbar = isCrossbarTarget(barArg);
            local barIndex = (affectAll or affectCrossbar) and 1 or (tonumber(barArg) or 1);

            if action == 'next' or action == 'prev' or action == 'previous' then
                local direction = (action == 'next') and 1 or -1;
                local results = {};

                if not affectCrossbar then
                    local hotbarResult = paletteModule.CyclePalette(1, direction, jobId, subjobId);
                    if hotbarResult then
                        table.insert(results, 'Hotbar: ' .. hotbarResult);
                    end
                end

                local crossbarResult = paletteModule.CyclePaletteForCombo(nil, direction, jobId, subjobId);
                if crossbarResult then
                    table.insert(results, 'Crossbar: ' .. crossbarResult);
                end

                if #results > 0 then
                    print('[XIUI] Palette -> ' .. table.concat(results, ', '));
                else
                    print('[XIUI] No palettes to cycle');
                end
            elseif action == 'list' then
                if not affectCrossbar then
                    local palettes = paletteModule.GetAvailablePalettes(barIndex, jobId, subjobId);
                    local currentPalette = paletteModule.GetActivePaletteDisplayName(barIndex);
                    print('[XIUI] Bar ' .. barIndex .. ' palettes:');
                    for _, name in ipairs(palettes) do
                        local marker = (name == currentPalette) and ' *' or '';
                        print('  - ' .. name .. marker);
                    end
                end

                if affectCrossbar or not tonumber(barArg) then
                    local crossbarPalettes = paletteModule.GetCrossbarAvailablePalettes(jobId, subjobId);
                    local activeCrossbar = paletteModule.GetActivePaletteDisplayNameForCombo();
                    print('[XIUI] Crossbar palettes:');
                    if #crossbarPalettes == 0 then
                        print('  (none defined)');
                    else
                        for _, name in ipairs(crossbarPalettes) do
                            local marker = (name == activeCrossbar) and ' *' or '';
                            print('  - ' .. name .. marker);
                        end
                    end
                end
            elseif action == 'base' or action == 'reset' or action == 'first' then
                local firstNames = {};

                if not affectCrossbar then
                    local palettes = paletteModule.GetAvailablePalettes(1, jobId, subjobId);
                    if #palettes > 0 then
                        for i = 1, 6 do
                            paletteModule.SetActivePalette(i, palettes[1]);
                        end
                        table.insert(firstNames, 'Hotbar: ' .. palettes[1]);
                    end
                end

                local crossbarPalettes = paletteModule.GetCrossbarAvailablePalettes(jobId, subjobId);
                if #crossbarPalettes > 0 then
                    paletteModule.SetActivePaletteForCombo(nil, crossbarPalettes[1]);
                    table.insert(firstNames, 'Crossbar: ' .. crossbarPalettes[1]);
                end

                if #firstNames > 0 then
                    print('[XIUI] Palette -> ' .. table.concat(firstNames, ', '));
                else
                    print('[XIUI] No palettes available');
                end
            else
                -- Switch to a named palette. Use the ORIGINAL-case args so palette
                -- names with capitals/spaces resolve (command_args is lowercased).
                local originalArgs = e.command:args();
                local paletteName = originalArgs[3];
                local targetIsAll = false;
                local targetIsCrossbar = false;

                if #originalArgs >= 4 then
                    local lastArg = originalArgs[#originalArgs];
                    local lastLower = lastArg:lower();
                    local isAllSuffix = (lastLower == 'all');
                    local isCrossbarSuffix = isCrossbarTarget(lastArg);
                    local isBarSuffix = tonumber(lastArg) ~= nil;

                    if isAllSuffix then
                        targetIsAll = true;
                    elseif isCrossbarSuffix then
                        targetIsCrossbar = true;
                    elseif isBarSuffix then
                        barIndex = tonumber(lastArg);
                    end

                    if isAllSuffix or isCrossbarSuffix or isBarSuffix then
                        if #originalArgs > 4 then
                            local nameParts = {};
                            for i = 3, #originalArgs - 1 do
                                table.insert(nameParts, originalArgs[i]);
                            end
                            paletteName = table.concat(nameParts, ' ');
                        end
                    else
                        local nameParts = {};
                        for i = 3, #originalArgs do
                            table.insert(nameParts, originalArgs[i]);
                        end
                        paletteName = table.concat(nameParts, ' ');
                    end
                end

                if targetIsCrossbar then
                    if paletteModule.CrossbarPaletteExists(paletteName, jobId, subjobId) then
                        paletteModule.SetActivePaletteForCombo(nil, paletteName);
                        print('[XIUI] Crossbar palette: ' .. paletteName);
                    else
                        print('[XIUI] Crossbar palette "' .. paletteName .. '" not found');
                    end
                elseif targetIsAll then
                    local anyFound = false;
                    for i = 1, 6 do
                        if paletteModule.PaletteExists(i, paletteName, jobId, subjobId) then
                            paletteModule.SetActivePalette(i, paletteName);
                            anyFound = true;
                        end
                    end
                    if paletteModule.CrossbarPaletteExists(paletteName, jobId, subjobId) then
                        paletteModule.SetActivePaletteForCombo(nil, paletteName);
                        anyFound = true;
                    end
                    if anyFound then
                        print('[XIUI] All bars palette: ' .. paletteName);
                    else
                        print('[XIUI] Palette "' .. paletteName .. '" not found');
                    end
                else
                    if paletteModule.PaletteExists(barIndex, paletteName, jobId, subjobId) then
                        paletteModule.SetActivePalette(barIndex, paletteName);
                        print('[XIUI] Bar ' .. barIndex .. ' palette: ' .. paletteName);
                    else
                        print('[XIUI] Palette "' .. paletteName .. '" not found for bar ' .. barIndex);
                    end
                end
            end
            return;
        end

        -- Hotbar debug toggles: /xiui debug <hotbar|subtarget|macroblock|rawinput|palette>
        if (command_args[2] == 'debug') then
            local moduleName = command_args[3];
            if moduleName == 'hotbar' then
                hotbar.SetDebugEnabled(not hotbar.IsDebugEnabled());
            elseif moduleName == 'subtarget' then
                hotbar.SetSubtargetDebugEnabled(not hotbar.IsSubtargetDebugEnabled());
            elseif moduleName == 'macroblock' then
                local macrosLib = require('libs.ffxi.macros');
                local controller = require('modules.hotbar.controller');
                local newState = not macrosLib.is_debug_enabled();
                macrosLib.set_debug_enabled(newState);
                controller.SetMacroBlockDebugEnabled(newState);
            elseif moduleName == 'rawinput' then
                DEBUG_RAW_INPUT = not DEBUG_RAW_INPUT;
                print('[XIUI] Raw input debug: ' .. (DEBUG_RAW_INPUT and 'ON' or 'OFF'));
                print('[XIUI] Logs ALL xinput/dinput events before hotbar processing.');
            elseif moduleName == 'palette' then
                hotbar.SetPaletteDebugEnabled(not hotbar.IsPaletteDebugEnabled());
            else
                print('[XIUI] Debug modules: hotbar, subtarget, macroblock, rawinput, palette');
                print('[XIUI] Usage: /xiui debug <module>');
            end
            return;
        end

        -- ============================================
        -- Cache Debug Commands
        -- ============================================

        -- Show progressbar cache statistics: /xiui cachestats
        if (command_args[2] == 'cachestats') then
            progressbar.PrintCacheStats();
            return;
        end

        -- Show texture cache statistics: /xiui texturestats
        if (command_args[2] == 'texturestats') then
            TextureManager.printStats();
            return;
        end

        -- Clear texture cache: /xiui textureclear
        if (command_args[2] == 'textureclear') then
            TextureManager.clear();
            print('[XIUI] TextureManager cache cleared');
            return;
        end

        -- Clear all caches: /xiui clearcache
        if (command_args[2] == 'clearcache') then
            progressbar.ForceClearCache();
            TextureManager.clear();
            statusHandler.clear_cache();
            print('[XIUI] All texture caches cleared');
            return;
        end

        -- Stress test gradient cache: /xiui stresscache [count]
        if (command_args[2] == 'stresscache') then
            local count = tonumber(command_args[3]) or 100;
            progressbar.StressTestCache(count);
            return;
        end

        -- Stress test texture manager: /xiui stresstextures [count]
        if (command_args[2] == 'stresstextures') then
            local count = tonumber(command_args[3]) or 150;
            print(string.format('[XIUI] Stress testing TextureManager with %d status icons...', count));
            local statsBefore = TextureManager.getStats();
            local beforeEvictions = statsBefore.categories.status_icons.evictions;

            -- Request many status icons (valid IDs are 0-640)
            for i = 0, count - 1 do
                TextureManager.getStatusIcon(i, nil);
            end

            local statsAfter = TextureManager.getStats();
            local afterEvictions = statsAfter.categories.status_icons.evictions;
            local newEvictions = afterEvictions - beforeEvictions;

            print(string.format('[XIUI] Created %d status icons, %d evictions triggered',
                statsAfter.categories.status_icons.size, newEvictions));
            TextureManager.printStats();
            return;
        end

        -- Force garbage collection: /xiui gc
        if (command_args[2] == 'gc') then
            local before = collectgarbage('count');
            collectgarbage('collect');
            local after = collectgarbage('count');
            print(string.format('[XIUI] Garbage collection: %.1f KB -> %.1f KB (freed %.1f KB)',
                before, after, before - after));
            return;
        end
    end
end);

ashita.events.register('packet_in', 'packet_in_cb', function (e)
    expBar.HandlePacket(e)

    -- Pet bar packet handling (0x0028 Action, 0x0068 Pet Sync)
    if gConfig.showPetBar then
        petBar.HandlePacket(e);
    end

    -- Hotbar pet palette sync (0x0068 Pet Sync) - rebinds pet-aware bars/combos.
    if e.id == 0x0068 and gConfig.hotbarEnabled then
        hotbar.HandlePetSyncPacket();
    end

    if (e.id == 0x0028) then
        local actionPacket = ParseActionPacket(e);
        if actionPacket then
            if gConfig.showEnemyList then enemyList.HandleActionPacket(actionPacket); end
            if gConfig.showCastBar then castBar.HandleActionPacket(actionPacket); end
            if gConfig.showTargetBar and gConfig.showTargetBarCastBar and not HzLimitedMode then
                targetBar.HandleActionPacket(actionPacket);
            end
            if gConfig.showPartyList then partyList.HandleActionPacket(actionPacket); end
            debuffHandler.HandleActionPacket(actionPacket);
            if gConfig.showPetBar then petBuffHandler.HandleActionPacket(actionPacket); end
            actionTracker.HandleActionPacket(actionPacket);
            if gConfig.showNotifications then notifications.HandleActionPacket(actionPacket); end
            -- Skillchain tracking for hotbar/crossbar WS slot highlighting.
            if gConfig.hotbarEnabled then
                skillchainModule.HandleActionPacket(actionPacket);
            end
        end
    elseif (e.id == 0x00E) then
        local mobUpdatePacket = ParseMobUpdatePacket(e);
        if gConfig.showEnemyList then enemyList.HandleMobUpdatePacket(mobUpdatePacket); end
    elseif (e.id == 0x00A) then
        -- Note: We do NOT clear treasure pool on zone - items persist across zones
        -- The server will send 0x00D2 packets to sync pool state after zoning
        notifications.HandleZonePacket();
        treasurePool.HandleZonePacket();
        enemyList.HandleZonePacket(e);
        partyList.HandleZonePacket(e);
        debuffHandler.HandleZonePacket(e);
        petBuffHandler.HandleZonePacket();
        actionTracker.HandleZonePacket();
        mobInfo.data.HandleZonePacket(e);
        gilTracker.HandleZoneInPacket();  -- Only reset on fresh login, not zone changes (issue #111)
        TextureManager.clearOnZone();
        MarkPartyCacheDirty();
        ClearEntityCache();
        bLoggedIn = true;
        -- Initialize hotbar for the current job on zone-in (covers initial login
        -- and job changes that happened during the zone transition).
        if gConfig.hotbarEnabled then
            hotbar.HandleJobChangePacket(e);
        end
    elseif (e.id == 0x0029) then
        local messagePacket = ParseMessagePacket(e.data);
        if messagePacket then
            debuffHandler.HandleMessagePacket(messagePacket);
            if gConfig.showPetBar then petBuffHandler.HandleMessagePacket(messagePacket); end
            if gConfig.showNotifications then
                notifications.HandleMessagePacket(e, messagePacket, 0x0029);
            end
        end
    elseif (e.id == 0x002D) then
        -- Kill message packet (item/gil rewards from defeating mobs)
        -- Same structure as 0x0029, used for post-combat notifications
        local messagePacket = ParseMessagePacket(e.data);
        if messagePacket then
            if gConfig.showNotifications then
                notifications.HandleMessagePacket(e, messagePacket, 0x002D);
            end
        end
    elseif (e.id == 0x002A) then
        -- Message Standard packet (zone/container messages)
        -- Different structure than 0x0029 - use ParseMessageStandardPacket
        local messagePacket = ParseMessageStandardPacket(e.data);
        if messagePacket then
            if gConfig.showNotifications then
                notifications.HandleMessagePacket(e, messagePacket, 0x002A);
            end
        end
    elseif (e.id == 0x00B) then
        -- Persist pending hotbar/palette edits before the loading screen masks
        -- the disk write.
        if gConfig.hotbarEnabled then
            if macropalette.IsHotbarDirty and macropalette.IsHotbarDirty() then
                SaveSettingsToDisk();
                macropalette.ClearHotbarDirty();
            end
            if palette.IsPaletteStateDirty and palette.IsPaletteStateDirty() then
                SaveSettingsToDisk();
                palette.ClearPaletteStateDirty();
            end
        end
        notifications.HandleZonePacket();
        treasurePool.HandleZonePacket();
        gilTracker.HandleZoneOutPacket();  -- Track zone-out time for login detection (issue #111)
        TextureManager.clearOnZone();
        bLoggedIn = false;
        -- Notify hotbar of zone (clears transient state) and reset skillchains.
        if gConfig.hotbarEnabled then
            hotbar.HandleZonePacket();
            skillchainModule.ClearState();
        end
    elseif (e.id == 0x001B) then
        -- Job change packet - rebind hotbar to the new job's actions/palettes.
        if gConfig.hotbarEnabled then
            hotbar.HandleJobChangePacket(e);
        end
    elseif (e.id == 0x076) then
        statusHandler.ReadPartyBuffsFromPacket(e);
    elseif (e.id == 0x0DD) then
        MarkPartyCacheDirty();
        -- Detect party leave and clear treasure pool
        local currentlyInParty = IsInParty();
        if wasInParty and not currentlyInParty then
            -- Player left party - clear treasure pool (forfeited)
            notifications.ClearTreasurePool();
        end
        wasInParty = currentlyInParty;
    elseif (e.id == 0x00DC) then
        -- Party invite packet
        if gConfig.showNotifications and gConfig.notificationsShowPartyInvite then
            notifications.HandlePartyInvite(e);
        end
    elseif (e.id == 0x0021) then
        -- Trade request packet
        if gConfig.showNotifications and gConfig.notificationsShowTradeInvite then
            notifications.HandleTradeRequest(e);
        end
    elseif (e.id == 0x0022) then
        -- Trade response packet (cancel, complete, error, etc.)
        if gConfig.showNotifications then
            notifications.HandleTradeResponse(e);
        end
    elseif (e.id == 0x0020) then
        -- Inventory item update packet (item added to inventory)
        if gConfig.showNotifications and gConfig.notificationsShowItems then
            notifications.HandleInventoryUpdate(e);
        end
    elseif (e.id == 0x00D2) then
        -- Treasure pool update packet (item dropped to pool)
        if gConfig.showNotifications and gConfig.notificationsShowTreasure then
            notifications.HandleTreasurePool(e);
        end
    elseif (e.id == 0x00D3) then
        -- Treasure lot/drop packet (party member lotted or item awarded)
        -- Parse packet for treasure pool lot tracking (always, not just for notifications)
        local winnerServerId = struct.unpack('I4', e.data, 0x04 + 1);
        local entryServerId = struct.unpack('I4', e.data, 0x08 + 1);
        local winnerLot = struct.unpack('H', e.data, 0x0E + 1);
        local entryActIndexAndFlag = struct.unpack('H', e.data, 0x10 + 1);
        local entryFlg = bit.band(bit.rshift(entryActIndexAndFlag, 15), 1);
        local entryLot = struct.unpack('h', e.data, 0x12 + 1);  -- signed
        local slot = struct.unpack('B', e.data, 0x14 + 1);
        local judgeFlg = struct.unpack('B', e.data, 0x15 + 1);
        -- Extract names (16-byte null-terminated strings)
        local winnerNameRaw = struct.unpack('c16', e.data, 0x16 + 1);
        local entryNameRaw = struct.unpack('c16', e.data, 0x26 + 1);
        local winnerName = winnerNameRaw and winnerNameRaw:match('^[^%z]+') or '';
        local entryName = entryNameRaw and entryNameRaw:match('^[^%z]+') or '';

        -- Route to treasure pool module for lot history tracking
        if gConfig.treasurePoolEnabled then
            treasurePool.HandleLotPacket(slot, entryServerId, entryName, entryFlg, entryLot,
                                         winnerServerId, winnerName, winnerLot, judgeFlg);
        end

        -- Route to notifications handler
        if gConfig.showNotifications and gConfig.notificationsShowTreasure then
            notifications.HandleTreasureLot(e);
        end
    end
end);

-- ============================================
-- Outgoing Packet Handler
-- ============================================

ashita.events.register('packet_out', 'packet_out_cb', function (e)
    if (e.id == 0x0074) then
        -- Party invite response (accept/decline)
        if gConfig.showNotifications then
            notifications.HandlePartyInviteResponse(e);
        end
    end
end);

-- ============================================
-- Keyboard Input Handler (hotbar keybinds)
-- ============================================
-- Fires for WNDPROC keyboard input. hotbar.HandleKey gates itself on
-- gConfig.hotbarEnabled internally, so no outer guard is needed.
ashita.events.register('key', 'key_cb', function (event)
    hotbar.HandleKey(event);
end);

-- ============================================
-- Controller Input Handlers (crossbar mode)
-- ============================================

-- XInput controller state (analog triggers). Fires every frame; not logged.
ashita.events.register('xinput_state', 'xinput_state_cb', function (e)
    hotbar.HandleXInputState(e);
end);

-- XInput button (blocks native game macros while the crossbar owns the combo).
ashita.events.register('xinput_button', 'xinput_button_cb', function (e)
    if DEBUG_RAW_INPUT then
        print(string.format('[XIUI RawInput] xinput_button: button=%d state=%d', e.button or -1, e.state or -1));
    end
    local shouldBlock = hotbar.HandleXInputButton(e);
    if shouldBlock then
        e.blocked = true;
    end
end);

-- DirectInput button (DualSense / Switch Pro / Stadia controllers).
ashita.events.register('dinput_button', 'dinput_button_cb', function (e)
    if DEBUG_RAW_INPUT then
        print(string.format('[XIUI RawInput] dinput_button: button=%d state=%d', e.button or -1, e.state or -1));
    end
    local shouldBlock = hotbar.HandleDInputButton(e);
    if shouldBlock then
        e.blocked = true;
    end
end);

-- DirectInput state (D-pad POV on DirectInput controllers). Fires every frame.
ashita.events.register('dinput_state', 'dinput_state_cb', function (e)
    hotbar.HandleDInputState(e);
end);