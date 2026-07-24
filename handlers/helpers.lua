--[[
* XIUI Helpers
* Main helper module that re-exports all utility functions
* This file maintains backwards compatibility while utilities are modularized
*
* New code should prefer importing from libs/ directly:
*   local colorLib = require('libs.color');
*   local memoryLib = require('libs.memory');
*   etc.
]]--

require('common');

-- ========================================
-- Import Modular Libraries
-- ========================================
local memoryLib = require('libs.memory');
local entityLib = require('libs.entity');
local partyLib = require('libs.party');
local targetLib = require('libs.target');
local fontsLib = require('libs.fonts');
local drawingLib = require('libs.drawing');
local packetsLib = require('libs.packets');
local TextureManager = require('libs.texturemanager');
local hpLib = require('libs.hp');
local fastcastLib = require('libs.fastcast');
local formatLib = require('libs.format');
local colorLib = require('libs.color');
local statusIconsLib = require('libs.statusicons');
local windowBackgroundLib = require('libs.windowbackground');

-- Handler imports (still in handlers/)
local statusHandler = require('handlers.statushandler');
local buffTable = require('libs.bufftable');

-- imgui is needed by the window-position helpers below (Save/ApplyWindowPosition).
local imgui = require('imgui');

-- ========================================
-- Global Exports for Backwards Compatibility
-- ========================================
-- These expose functions globally so existing code continues to work

-- ========================================
-- Window Positioning Helpers (ported from upstream XIUI, tirem/XIUI)
-- Required by modules/hotbar/display.lua and crossbar.lua, which persist and
-- restore per-window positions via these globals. Self-contained: only touch
-- gConfig and imgui.
-- ========================================

-- Apply a saved window position ONCE (before imgui.Begin) per window name.
-- Returns true if a position was applied this call.
function ApplyWindowPosition(windowName)
    if (gConfig and gConfig.windowPositions and gConfig.windowPositions[windowName]) then
        if (not gConfig.appliedPositions) then gConfig.appliedPositions = {}; end

        if (not gConfig.appliedPositions[windowName]) then
            local pos = gConfig.windowPositions[windowName];
            imgui.SetNextWindowPos({ pos.x, pos.y }, ImGuiCond_Always);
            gConfig.appliedPositions[windowName] = true;
            return true;
        end
    end
    return false;
end

-- Pending flush state for window positions.
--
-- SaveWindowPosition fires every frame a window is visible, so writing to disk
-- on every change would hammer the filesystem while dragging. Instead we mark
-- the config dirty and let FlushWindowPositions (called from d3d_present) do
-- the write once the position has been stable for a moment.
local windowPosDirty = false;
local windowPosDirtyAt = 0;
local WINDOW_POS_FLUSH_DELAY = 1.0;  -- seconds of stability before writing

-- Capture the current window position into the profile. Call AFTER imgui.Begin().
-- Only writes when the position actually changed (reduces settings churn).
--
-- First render of a window with no saved entry captures wherever imgui put it,
-- so every window ends up with a position on file whether or not the user has
-- ever dragged it.
function SaveWindowPosition(windowName)
    if (not gConfig) then return; end

    local x, y = imgui.GetWindowPos();

    if (not gConfig.windowPositions) then gConfig.windowPositions = {}; end

    local saved = gConfig.windowPositions[windowName];

    if (not saved) then
        gConfig.windowPositions[windowName] = { x = x, y = y };
        windowPosDirty = true;
        windowPosDirtyAt = os.clock();
    elseif (saved.x ~= x or saved.y ~= y) then
        saved.x = x;
        saved.y = y;
        windowPosDirty = true;
        windowPosDirtyAt = os.clock();
    end
end

-- Write pending window positions to disk once they have settled.
--
-- Called every frame from d3d_present. Does nothing unless a position changed
-- and has since been stable for WINDOW_POS_FLUSH_DELAY, which keeps a drag
-- from producing one disk write per frame.
function FlushWindowPositions()
    if (not windowPosDirty) then return; end
    if ((os.clock() - windowPosDirtyAt) < WINDOW_POS_FLUSH_DELAY) then return; end

    windowPosDirty = false;
    if (SaveSettingsToDisk) then
        SaveSettingsToDisk();
    end
end

-- XIUI's own imgui windows.
--
-- The seeder reads imgui.ini, which holds windows from EVERY addon the user
-- runs plus transient dialogs. Without this filter we would store and restore
-- other addons' layouts, which is not ours to touch, and drag modals back to
-- fixed spots every load.
--
-- Matching is exact on the [Window][Name] section header, except for the
-- prefix entries below which cover the numbered/dynamic windows.
local XIUI_WINDOWS = {
    ['PlayerBar'] = true,
    ['TargetBar'] = true,
    ['TargetOfTargetBar'] = true,
    ['SubtargetBar'] = true,
    ['CastBar'] = true,
    ['CastCost'] = true,
    ['ExpBar'] = true,
    ['GilTracker'] = true,
    ['PetBar'] = true,
    ['PetBarTarget'] = true,
    ['TreasurePool'] = true,
    ['MobInfo'] = true,
    ['Crossbar'] = true,
    ['NQ Jug Caps'] = true,
    ['Jug Pets'] = true,
    ['Spell Grid'] = true,
};

-- Windows whose names carry a number or a ## suffix.
local XIUI_WINDOW_PREFIXES = {
    'PartyList',
    'Hotbar',
    'InventoryTracker',
    'LockerTracker',
    'SafeTracker',
    'SatchelTracker',
    'StorageTracker',
    'WardrobeTracker',
    'Notifications_',
    'Combat Timers##bovinecombat',
    'Dedication##bovinededication',
    'Latent Trial##bovinelatent',
    'BovineLooty##bovinelooty',
};

-- Never seed these, even though they match the rules above.
--
-- Modal dialogs and config windows are transient -- imgui records wherever they
-- last opened, and restoring that is noise at best. 'XIUI Config' in particular
-- would drag the settings window to a fixed spot every load.
local XIUI_WINDOW_EXCLUDE = {
    ['XIUI Config'] = true,
    ['Overwrite Preset?##presetConfirmSave'] = true,
    ['Load Preset?##presetConfirmLoad'] = true,
    ['Confirm Reset Settings'] = true,
    ['Confirm Action Storage Change##jobSpecificConfirm'] = true,
    ['###MacroPalette'] = true,
    ['Rest Tick Test'] = true,
    ['Debug##Default'] = true,
    -- EnemyList draws straight onto the foreground draw list and has no imgui
    -- window at all. Its position lives in gConfig.enemyListX/Y, so any
    -- windowPositions entry for it is a leftover from a stale imgui.ini and
    -- does nothing.
    ['EnemyList'] = true,
    -- Legacy HXUI names, superseded by the XIUI equivalents above.
    ['HXUICastCost'] = true,
    ['HXUITreasurePool'] = true,
};

local function isXiuiWindow(name)
    if (name == nil) then return false; end
    if (XIUI_WINDOW_EXCLUDE[name]) then return false; end
    if (XIUI_WINDOWS[name]) then return true; end
    for _, prefix in ipairs(XIUI_WINDOW_PREFIXES) do
        if (name:sub(1, #prefix) == prefix) then return true; end
    end
    return false;
end

-- Pull a position back on screen.
--
-- Values come out of imgui.ini, which can hold coordinates from a larger
-- monitor, a since-changed resolution, or a window that was dragged off the
-- edge. A window whose top-left is outside the viewport cannot be grabbed, so
-- there is no way to recover it from in-game.
--
-- Clamps the top-left to the viewport, leaving a small margin so the title bar
-- is always reachable.
local CLAMP_MARGIN = 8;

local function clampToScreen(x, y)
    local ok, sw, sh = pcall(function()
        local io = imgui.GetIO();
        return io.DisplaySize.x, io.DisplaySize.y;
    end);
    if (not ok or not sw or not sh or sw <= 0 or sh <= 0) then
        return x, y, false;
    end

    local cx = math.max(CLAMP_MARGIN, math.min(x, sw - CLAMP_MARGIN));
    local cy = math.max(CLAMP_MARGIN, math.min(y, sh - CLAMP_MARGIN));

    return cx, cy, (cx ~= x or cy ~= y);
end

-- Seed gConfig.windowPositions from imgui.ini for any window that has no entry.
--
-- Called once at load, before anything renders. imgui.ini holds the last known
-- position of EVERY window imgui has ever placed, including ones that are not
-- currently visible -- so a window that has not drawn since the position system
-- went in still has a known location on disk. Reading it here means every
-- window has an entry from frame one, rather than only appearing in the config
-- after it happens to render.
--
-- Only XIUI's own windows are seeded; see isXiuiWindow above. Off-screen
-- coordinates are clamped back into the viewport on the way in, since a stale
-- ini can easily carry positions from another resolution.
--
-- Existing entries always win: gConfig is authoritative once it has a value,
-- and this only fills gaps.
function SeedWindowPositions()
    if (not gConfig) then return 0; end
    if (not gConfig.windowPositions) then gConfig.windowPositions = {}; end

    local path = string.format('%sconfig\\imgui.ini', AshitaCore:GetInstallPath());
    local f = io.open(path, 'r');
    if (f == nil) then return 0; end

    local seeded = 0;
    local currentName = nil;

    for line in f:lines() do
        local header = line:match('^%[Window%]%[(.+)%]%s*$');
        if (header ~= nil) then
            currentName = header;
        elseif (currentName ~= nil) then
            local px, py = line:match('^Pos=(-?%d+),(-?%d+)');
            if (px ~= nil) then
                if (isXiuiWindow(currentName)
                    and gConfig.windowPositions[currentName] == nil) then
                    local x, y = clampToScreen(tonumber(px), tonumber(py));
                    gConfig.windowPositions[currentName] = { x = x, y = y };
                    seeded = seeded + 1;
                end
                -- Pos is the only line we want out of each section.
                currentName = nil;
            end
        end
    end

    f:close();

    if (seeded > 0) then
        windowPosDirty = true;
        windowPosDirtyAt = os.clock();
    end

    return seeded;
end

-- Strip non-XIUI and transient entries from gConfig.windowPositions.
--
-- Cleanup for configs polluted by an earlier unfiltered seed, and a guard
-- against modules that pass a dialog name to SaveWindowPosition. Runs at load
-- right before the seed.
function PruneWindowPositions()
    if (not gConfig or not gConfig.windowPositions) then return 0; end

    local drop = {};
    for name in pairs(gConfig.windowPositions) do
        if (not isXiuiWindow(name)) then
            table.insert(drop, name);
        end
    end

    for _, name in ipairs(drop) do
        gConfig.windowPositions[name] = nil;
    end

    if (#drop > 0) then
        windowPosDirty = true;
        windowPosDirtyAt = os.clock();
    end

    return #drop;
end

-- Entity Constants (from entity.lua)
SPAWN_FLAG_PLAYER = entityLib.SPAWN_FLAG_PLAYER;
SPAWN_FLAG_NPC = entityLib.SPAWN_FLAG_NPC;
RENDER_FLAG_VISIBLE = entityLib.RENDER_FLAG_VISIBLE;
RENDER_FLAG_HIDDEN = entityLib.RENDER_FLAG_HIDDEN;

-- Fast Cast Constants (from fastcast.lua)
CURE_SPELLS = fastcastLib.CURE_SPELLS;

-- Memory Accessors (from memory.lua)
GetD3D8Device = memoryLib.GetD3D8Device;
GetPlayerSafe = memoryLib.GetPlayerSafe;
GetPartySafe = memoryLib.GetPartySafe;
GetEntitySafe = memoryLib.GetEntitySafe;
GetTargetSafe = memoryLib.GetTargetSafe;
GetInventorySafe = memoryLib.GetInventorySafe;
GetCastBarSafe = memoryLib.GetCastBarSafe;
GetRecastSafe = memoryLib.GetRecastSafe;
GetPetSafe = memoryLib.GetPetSafe;

-- Entity Utilities (from entity.lua)
GetIsMob = entityLib.GetIsMob;
GetIsMobByIndex = entityLib.GetIsMobByIndex;
JobHasMP = entityLib.JobHasMP;
JOBS_WITH_MP = entityLib.JOBS_WITH_MP;

-- Wrappers for entity color functions that inject dependencies
function GetEntityNameColorRGBA(targetEntity, targetIndex, colorConfig)
    return entityLib.GetEntityNameColorRGBA(targetEntity, targetIndex, colorConfig, partyLib, colorLib);
end

function GetEntityNameColor(targetEntity, targetIndex, colorConfig)
    return entityLib.GetEntityNameColor(targetEntity, targetIndex, colorConfig, partyLib, colorLib);
end

-- Wrapper for backwards compatibility - uses shared entity colors
function GetColorOfTargetRGBA(targetEntity, targetIndex)
    if gConfig and gConfig.colorCustomization and gConfig.colorCustomization.shared then
        return GetEntityNameColorRGBA(targetEntity, targetIndex, gConfig.colorCustomization.shared);
    end
    return {1,1,1,1}; -- Default white RGBA
end

-- Wrapper function that returns ARGB format (for backwards compatibility)
function GetColorOfTarget(targetEntity, targetIndex)
    local rgba = GetColorOfTargetRGBA(targetEntity, targetIndex);
    return colorLib.RGBAToARGB(rgba);
end

-- Party Utilities (from party.lua)
MarkPartyCacheDirty = partyLib.MarkPartyCacheDirty;
IsMemberOfParty = partyLib.IsMemberOfParty;
IsPartyMemberByServerId = partyLib.IsPartyMemberByServerId;

-- Target Utilities (from target.lua)
GetStPartyIndex = targetLib.GetStPartyIndex;
GetSubTargetActive = targetLib.GetSubTargetActive;
GetTargets = targetLib.GetTargets;
GetIsTargetLockedOn = targetLib.GetIsTargetLockedOn;

-- Font Utilities (from fonts.lua)
GetFontWeightFlags = fontsLib.GetFontWeightFlags;
FontManager = fontsLib.FontManager;
ColorCachedFont = fontsLib.ColorCachedFont;
SetFontsVisible = fontsLib.SetFontsVisible;
UpdateAllFontOutlineWidths = fontsLib.UpdateAllOutlineWidths;

-- Drawing Utilities (from drawing.lua)
draw_rect = drawingLib.draw_rect;
draw_rect_background = drawingLib.draw_rect_background;
draw_circle = drawingLib.draw_circle;
GetUIDrawList = drawingLib.GetUIDrawList;

-- Packet Utilities (from packets.lua)
GetIndexFromId = packetsLib.GetIndexFromId;
ParseActionPacket = packetsLib.ParseActionPacket;
ParseMobUpdatePacket = packetsLib.ParseMobUpdatePacket;
ClearEntityCache = packetsLib.ClearEntityCache;
PopulateEntityCache = packetsLib.PopulateEntityCache;
ParseMessagePacket = packetsLib.ParseMessagePacket;
ParseMessageStandardPacket = packetsLib.ParseMessageStandardPacket;
valid_server_id = packetsLib.valid_server_id;

-- Texture Utilities (from texturemanager.lua)
LoadTexture = TextureManager.getFileTexture;
GetTextureDimensions = TextureManager.getTextureDimensions;

-- HP Utilities (from hp.lua)
HpInterpolation = hpLib.HpInterpolation;
GetHpInterpolationColors = hpLib.GetHpInterpolationColors;
InvalidateInterpolationColorCache = hpLib.InvalidateInterpolationColorCache;
GetHpColors = hpLib.GetHpColors;
GetCustomHpColors = hpLib.GetCustomHpColors;
GetCustomGradient = hpLib.GetCustomGradient;
easeOutPercent = hpLib.easeOutPercent;

-- Fast Cast Utilities (from fastcast.lua)
CalculateFastCast = fastcastLib.CalculateFastCast;

-- Format Utilities (from format.lua)
SeparateNumbers = formatLib.SeparateNumbers;
FormatInt = formatLib.FormatInt;
deep_copy_table = formatLib.deep_copy_table;
GetJobStr = formatLib.GetJobStr;

-- Color Utilities (from color.lua)
ARGBToRGBA = colorLib.ARGBToRGBA;
RGBAToARGB = colorLib.RGBAToARGB;
ARGBToImGui = colorLib.ARGBToImGui;
ImGuiToARGB = colorLib.ImGuiToARGB;
ARGBToABGR = colorLib.ARGBToABGR;
HexToImGui = colorLib.HexToImGui;
ImGuiToHex = colorLib.ImGuiToHex;
HexToARGB = colorLib.HexToARGB;
InvalidateColorCaches = colorLib.InvalidateColorCaches;
GetColorSetting = colorLib.GetColorSetting;
GetGradientSetting = colorLib.GetGradientSetting;

-- Color Helper Utilities (from color.lua)
GetGradientTextColor = colorLib.GetGradientTextColor;
HexToU32 = colorLib.HexToU32;
ARGBToU32 = colorLib.ARGBToU32;
ColorTableToARGB = colorLib.ColorTableToARGB;

-- Legacy color functions (also from color.lua)
rgbToHsv = colorLib.rgbToHsv;
hsvToRgb = colorLib.hsvToRgb;
hex2rgb = colorLib.hex2rgb;
hex2rgba = colorLib.hex2rgba;
rgb2hex = colorLib.rgb2hex;
shiftSaturationAndBrightness = colorLib.shiftSaturationAndBrightness;
shiftGradient = colorLib.shiftGradient;

-- Status Icons (from statusicons.lua)
-- Wrapper that injects dependencies
function DrawStatusIcons(statusIds, iconSize, maxColumns, maxRows, drawBg, xOffset, buffTimes, settings)
    return statusIconsLib.DrawStatusIcons(statusIds, iconSize, maxColumns, maxRows, drawBg, xOffset, buffTimes, settings, statusHandler, buffTable);
end

ClearDebuffFontCache = statusIconsLib.ClearDebuffFontCache;

-- Legacy debuffTable global (for backwards compatibility)
debuffTable = statusIconsLib.GetDebuffTable();

-- Window Background Utilities (from windowbackground.lua)
WindowBackground = windowBackgroundLib;

-- ========================================
-- Window Utilities
-- ========================================

-- Cached base window flags (computed once)
local baseWindowFlagsCache = nil;

-- Get base window flags for UI modules
-- Optionally adds NoMove flag based on lockPositions parameter
function GetBaseWindowFlags(lockPositions)
    if baseWindowFlagsCache == nil then
        baseWindowFlagsCache = bit.bor(
            ImGuiWindowFlags_NoDecoration or 0,
            ImGuiWindowFlags_AlwaysAutoResize or 0,
            ImGuiWindowFlags_NoFocusOnAppearing or 0,
            ImGuiWindowFlags_NoNav or 0,
            ImGuiWindowFlags_NoBackground or 0,
            ImGuiWindowFlags_NoBringToFrontOnFocus or 0,
            ImGuiWindowFlags_NoDocking or 0
        );
    end

    if lockPositions then
        return bit.bor(baseWindowFlagsCache, ImGuiWindowFlags_NoMove or 0);
    end

    return baseWindowFlagsCache;
end