--[[
* XIUI Config Menu - Preset
*
* Saves and loads the entire UI configuration per screen resolution.
*
* Window positions are stored in absolute pixels, so a config built at 2560x1440
* puts elements off-screen (or bunched in a corner) at 1920x1080. Rather than
* rescale -- which never quite works, since font sizes and bar widths do not
* scale linearly with the viewport -- each resolution gets its own saved file
* and you switch between them.
*
* Files land beside this module as:
*     modules/presets/2560x1440.lua
* and are plain Lua tables, so they can be edited by hand or shared.
]]--

require('common');
require('handlers.helpers');
local components = require('config.components');
local imgui = require('imgui');

local M = {};

-- Resolutions listed in the author's "saved presets" summary.
--
-- NOT a whitelist: saving uses whatever resolution you are actually running,
-- and loading only ever offers the matching file. This list just decides which
-- ones get reported as present or absent in that summary.
local COMMON_RESOLUTIONS = {
    { w = 1920, h = 1080 },
    { w = 2560, h = 1440 },
    { w = 3840, h = 2160 },
    { w = 1600, h = 900 },
    { w = 1280, h = 720 },
};

-- Author gate for the Save button.
--
-- Presets are shipped as curated layouts, so Save is only exposed to the
-- author -- it would otherwise be easy to overwrite a shipped preset by
-- accident while experimenting. Loading is unrestricted.
--
-- This is a convenience guard, not a security boundary: it is trivially
-- bypassed by editing this file, and that is fine. The point is to keep the
-- destructive button out of the way for everyone else.
local PRESET_AUTHOR = 'Cowrevenge';

local function getPlayerName()
    local ok, name = pcall(function()
        local p = AshitaCore:GetMemoryManager():GetParty();
        if p == nil then return ''; end
        return tostring(p:GetMemberName(0) or '');
    end);
    if not ok then return ''; end
    return name;
end

local function isAuthor()
    return getPlayerName():lower() == PRESET_AUTHOR:lower();
end

-- Transient status line shown under the buttons.
local statusText = '';
local statusIsError = false;

local function setStatus(text, isError)
    statusText = text or '';
    statusIsError = isError == true;
end

-- Current screen resolution.
--
-- Uses imgui's DisplaySize, the same source modules/hotbar/display.lua reads,
-- so the number here matches what the UI is actually laid out against.
local function getCurrentResolution()
    local ok, w, h = pcall(function()
        local io = imgui.GetIO();
        return io.DisplaySize.x, io.DisplaySize.y;
    end);
    if ok and w and h and w > 0 and h > 0 then
        return math.floor(w), math.floor(h);
    end
    return nil, nil;
end

local function presetDir()
    -- Saved presets live beside this module so the code and its data ship
    -- together and are easy to find, edit and share.
    return string.format('%saddons\\XIUI\\modules\\presets\\',
        AshitaCore:GetInstallPath());
end

local function presetPath(w, h)
    return string.format('%s%dx%d.lua', presetDir(), w, h);
end

-- Companion file holding the imgui window geometry for a preset.
local function presetIniPath(w, h)
    return string.format('%s%dx%d.ini', presetDir(), w, h);
end

local function imguiIniPath()
    -- Ashita keeps imgui.ini under config\\, not the game root.
    return string.format('%sconfig\\imgui.ini', AshitaCore:GetInstallPath());
end

-- XIUI's imgui windows.
--
-- Only the hotbar routes through SaveWindowPosition (which lands in
-- gConfig.windowPositions and so is already in the preset). Every other window
-- is positioned by imgui itself and persisted to imgui.ini, which lives
-- outside gConfig -- so without this the preset restores every setting and
-- colour but leaves the windows wherever they happen to be.
--
-- Matching is exact on the [Window][Name] section header, except for the
-- prefix entries below which cover the numbered/dynamic windows.
local XIUI_WINDOWS = {
    ['PlayerBar'] = true,
    ['TargetBar'] = true,
    ['TargetOfTargetBar'] = true,
    ['SubtargetBar'] = true,
    ['EnemyList'] = true,
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
    ['InventoryTrackerText'] = true,
    ['InventoryTrackerFloatingText'] = true,
};

-- Windows whose names carry a number or a ## suffix.
--
-- Verified against a real imgui.ini rather than guessed: PartyList/2/3,
-- Hotbar1..3, WardrobeTracker_1/_2/_8, Notifications_Group1, and the bovine
-- windows which use '##' identifiers.
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
    'Combat Timers',
    'Dedication',
    'Latent Trial',
};

-- Never persist these, even though they match the rules above.
--
-- Modal dialogs and config windows are transient -- imgui records wherever
-- they last opened, and restoring that is noise at best. 'XIUI Config' in
-- particular would drag the settings window to a fixed spot every load.
local XIUI_WINDOW_EXCLUDE = {
    ['XIUI Config'] = true,
    ['Overwrite Preset?##presetConfirmSave'] = true,
    ['Load Preset?##presetConfirmLoad'] = true,
    ['Confirm Reset Settings'] = true,
    ['Confirm Action Storage Change##jobSpecificConfirm'] = true,
    ['###MacroPalette'] = true,
    ['Rest Tick Test'] = true,
};

local function isXiuiWindow(name)
    if name == nil then return false; end
    if XIUI_WINDOW_EXCLUDE[name] then return false; end
    if XIUI_WINDOWS[name] then return true; end
    for _, prefix in ipairs(XIUI_WINDOW_PREFIXES) do
        if name:sub(1, #prefix) == prefix then return true; end
    end
    return false;
end

-- Read imgui.ini into an ordered list of { header, name, lines }.
local function readIniSections(path)
    local f = io.open(path, 'r');
    if f == nil then return nil; end

    local sections = {};
    local current = nil;
    for line in f:lines() do
        local header = line:match('^%[Window%]%[(.+)%]%s*$');
        if header ~= nil then
            current = { header = line, name = header, lines = {} };
            table.insert(sections, current);
        elseif current ~= nil then
            table.insert(current.lines, line);
        else
            -- Anything before the first section (blank lines, other tables).
            current = { header = nil, name = nil, lines = { line } };
            table.insert(sections, current);
            current = nil;
        end
    end
    f:close();
    return sections;
end

-- Save only XIUI's window sections to the preset's .ini companion.
--
-- CAVEAT: imgui writes imgui.ini on its own schedule (typically on shutdown or
-- after a settings-dirty timer), not when we ask. So this captures the last
-- state imgui flushed, which may lag a window you just dragged. Moving a
-- window and immediately saving can therefore miss that move -- the UI says as
-- much next to the Save button.
local function saveWindowLayout(w, h)
    local sections = readIniSections(imguiIniPath());
    if sections == nil then return false, 'imgui.ini not found'; end

    local out = io.open(presetIniPath(w, h), 'w');
    if out == nil then return false, 'could not write preset .ini'; end

    local count = 0;
    for _, sec in ipairs(sections) do
        if sec.name ~= nil and isXiuiWindow(sec.name) then
            count = count + 1;
            out:write(sec.header, '\n');
            for _, l in ipairs(sec.lines) do
                out:write(l, '\n');
            end
        end
    end
    out:close();
    return true, count;
end

-- MERGE the preset's window sections into the live imgui.ini.
--
-- Deliberately a merge rather than a copy: the user's imgui.ini also holds
-- windows from every other addon they run, and replacing the file wholesale
-- would reset all of those. Sections we own are overwritten, sections we do
-- not are passed through untouched, and any of ours the file lacks are
-- appended.
local function loadWindowLayout(w, h)
    local presetSections = readIniSections(presetIniPath(w, h));
    if presetSections == nil then return false, 'no window layout saved'; end

    -- Index the preset's sections by window name.
    local incoming = {};
    local order = {};
    for _, sec in ipairs(presetSections) do
        if sec.name ~= nil then
            incoming[sec.name] = sec;
            table.insert(order, sec.name);
        end
    end

    local live = readIniSections(imguiIniPath()) or {};
    local out = io.open(imguiIniPath(), 'w');
    if out == nil then return false, 'could not write imgui.ini'; end

    local written = {};
    local replaced = 0;

    for _, sec in ipairs(live) do
        if sec.name ~= nil and incoming[sec.name] ~= nil then
            -- Ours: write the preset's version instead.
            local src = incoming[sec.name];
            out:write(src.header, '\n');
            for _, l in ipairs(src.lines) do out:write(l, '\n'); end
            written[sec.name] = true;
            replaced = replaced + 1;
        else
            -- Someone else's, or a non-window section: pass through.
            if sec.header ~= nil then out:write(sec.header, '\n'); end
            for _, l in ipairs(sec.lines) do out:write(l, '\n'); end
        end
    end

    -- Windows in the preset that the live file has never seen.
    for _, name in ipairs(order) do
        if not written[name] then
            local src = incoming[name];
            out:write(src.header, '\n');
            for _, l in ipairs(src.lines) do out:write(l, '\n'); end
            replaced = replaced + 1;
        end
    end

    out:close();
    return true, replaced;
end

-- Serialize a table to a Lua source string.
--
-- Deliberately simple: gConfig is plain data (numbers, strings, booleans and
-- nested tables), so this does not need to handle functions, userdata or
-- cycles. Keys are sorted so a re-save produces a stable diff rather than
-- reshuffling every line.
local function serialize(value, indent)
    indent = indent or '    ';
    local t = type(value);

    if t == 'number' or t == 'boolean' then
        return tostring(value);
    elseif t == 'string' then
        return string.format('%q', value);
    elseif t ~= 'table' then
        return 'nil';  -- functions/userdata are not config data
    end

    local keys = {};
    for k in pairs(value) do
        if type(k) == 'string' or type(k) == 'number' then
            table.insert(keys, k);
        end
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return tostring(a) < tostring(b); end
        return type(a) == 'number';
    end);

    local parts = { '{\r\n' };
    local inner = indent .. '    ';
    for _, k in ipairs(keys) do
        local keyStr;
        if type(k) == 'number' then
            keyStr = string.format('[%d]', k);
        else
            keyStr = string.format('[%q]', k);
        end
        table.insert(parts, string.format('%s%s = %s,\r\n',
            inner, keyStr, serialize(value[k], inner)));
    end
    table.insert(parts, indent .. '}');
    return table.concat(parts);
end

local function savePreset(w, h)
    if w == nil or h == nil then
        setStatus('Could not read the screen resolution.', true);
        return;
    end

    -- Make sure the folder exists before writing into it.
    pcall(ashita.fs.create_directory, presetDir());

    local path = presetPath(w, h);
    local f = io.open(path, 'w');
    if f == nil then
        setStatus('Could not write ' .. path, true);
        return;
    end

    f:write('-- XIUI preset\r\n');
    f:write(string.format('-- resolution: %dx%d\r\n', w, h));
    f:write(string.format('-- saved: %s\r\n\r\n', os.date('%Y-%m-%d %H:%M:%S')));
    f:write('return ');
    f:write(serialize(gConfig, ''));
    f:write('\r\n');
    f:close();

    -- Window geometry lives in imgui.ini, not gConfig, so it needs its own
    -- companion file -- see saveWindowLayout.
    local okIni, iniInfo = saveWindowLayout(w, h);
    if okIni then
        setStatus(string.format('Saved %dx%d (%d windows)', w, h, iniInfo), false);
    else
        setStatus(string.format('Saved %dx%d -- settings only (%s)', w, h, tostring(iniInfo)), false);
    end
end

local function loadPreset(w, h)
    local path = presetPath(w, h);
    local chunk, err = loadfile(path);
    if chunk == nil then
        setStatus(string.format('No preset for %dx%d', w, h), true);
        return;
    end

    local ok, loaded = pcall(chunk);
    if not ok or type(loaded) ~= 'table' then
        setStatus('Preset file is corrupt: ' .. tostring(loaded), true);
        return;
    end

    -- Overwrite in place rather than replacing gConfig.
    --
    -- gConfig IS config.userSettings (XIUI.lua:302) -- the table the settings
    -- library persists. Swapping it for a new one would leave both that
    -- library and every module holding a reference to the old table, so the
    -- save would write the wrong data and modules would read stale values.
    --
    -- Keys present in gConfig but absent from the preset are left ALONE rather
    -- than cleared. A preset saved before some setting existed would otherwise
    -- nil it out, and the module reading it would fall over or silently lose
    -- its default. This way an older preset applies what it knows about and
    -- anything newer keeps its current value.
    for k, v in pairs(loaded) do
        gConfig[k] = v;
    end

    SaveSettingsToDisk();
    UpdateUserSettings();

    -- Window positions are re-applied from the loaded config on the next
    -- frame; clearing the guard makes that happen immediately rather than
    -- after a reload.
    gConfig.appliedPositions = {};

    -- Window geometry cannot be merged here.
    --
    -- imgui keeps window positions in memory and writes config\\imgui.ini when
    -- the addon unloads. Merging now would be overwritten moments later by
    -- that flush -- the layout would appear to load and then silently revert.
    --
    -- So the merge is deferred: flag it, trigger a reload, and apply the merge
    -- from XIUI.lua's unload handler AFTER imgui has flushed but BEFORE the
    -- addon loads again and reads the file.
    -- A GLOBAL, not a module field: the reload re-requires this file, so
    -- anything stored on M is gone by the time the unload handler runs.
    -- Ashita globals persist for the session.
    _XIUI_PENDING_PRESET_LAYOUT = { w = w, h = h };

    setStatus(string.format('Loaded %dx%d -- reloading to apply layout...', w, h), false);
    AshitaCore:GetChatManager():QueueCommand(-1, '/addon reload xiui');
end

local function presetExists(w, h)
    local f = io.open(presetPath(w, h), 'r');
    if f == nil then return false; end
    f:close();
    return true;
end

function M.DrawSettings()
    local curW, curH = getCurrentResolution();

    imgui.Text('Current resolution:');
    imgui.SameLine();
    if curW then
        imgui.TextColored({ 0.55, 1.0, 0.65, 1.0 }, string.format('%dx%d', curW, curH));
    else
        imgui.TextColored({ 1.0, 0.45, 0.45, 1.0 }, 'unknown');
    end

    imgui.Spacing();
    imgui.TextWrapped('Applies a complete saved layout -- every setting, '
        .. 'including window positions. Positions are absolute pixels, so a '
        .. 'layout built at one resolution does not fit another; only a preset '
        .. 'matching your resolution is offered.');
    imgui.Spacing();
    imgui.Separator();
    imgui.Spacing();

    -- Both actions are destructive and have no undo -- Load replaces every
    -- setting you have, Save overwrites a stored layout -- so each goes
    -- through a confirmation modal rather than firing on a single click.
    local CONFIRM_LOAD = 'Load Preset?##presetConfirmLoad';
    local CONFIRM_SAVE = 'Overwrite Preset?##presetConfirmSave';

    -- LOAD: only offered when a preset exists for the CURRENT resolution.
    --
    -- Loading a layout built for another resolution is what this module exists
    -- to prevent -- absolute pixel positions would land things off-screen. So
    -- rather than listing every resolution and letting you pick the wrong one,
    -- the button only appears when there is a matching file.
    local canLoad = curW ~= nil and presetExists(curW, curH);

    if canLoad then
        if imgui.Button(string.format('Load Preset (%dx%d)##presetLoad', curW, curH), { 220, 0 }) then
            imgui.OpenPopup(CONFIRM_LOAD);
        end
        imgui.ShowHelp('Replaces the current config with the saved layout for this resolution. Window positions are merged into imgui.ini -- only XIUI windows are touched, other addons are left alone -- and take effect after a reload.');
    else
        imgui.TextDisabled('No preset saved for this resolution.');
    end

    if imgui.BeginPopupModal(CONFIRM_LOAD, nil, ImGuiWindowFlags_AlwaysAutoResize) then
        imgui.TextColored({ 1.0, 0.45, 0.45, 1.0 }, 'Load Preset?');
        imgui.Spacing();
        imgui.Text('This will erase your current config.');
        imgui.TextColored({ 0.6, 0.6, 0.65, 1.0 }, 'This action cannot be undone.');
        imgui.Spacing();
        imgui.Spacing();

        if imgui.Button('Yes', { 100, 24 }) then
            if curW then loadPreset(curW, curH); end
            imgui.CloseCurrentPopup();
        end
        imgui.SameLine();
        if imgui.Button('Abort', { 100, 24 }) then
            imgui.CloseCurrentPopup();
        end
        imgui.EndPopup();
    end

    -- SAVE: author only. See PRESET_AUTHOR above.
    if isAuthor() then
        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        if curW then
            if imgui.Button(string.format('Save Preset (%dx%d)##presetSave', curW, curH), { 220, 0 }) then
                imgui.OpenPopup(CONFIRM_SAVE);
            end
            imgui.ShowHelp('Writes the current config to modules\\presets\\' .. curW .. 'x' .. curH .. '.lua plus a .ini holding window positions, overwriting any existing files for this resolution. Window geometry comes from imgui.ini, which imgui flushes on its own schedule -- if you just moved something, reload first so the move is on disk.');

            if imgui.BeginPopupModal(CONFIRM_SAVE, nil, ImGuiWindowFlags_AlwaysAutoResize) then
                imgui.TextColored({ 1.0, 0.45, 0.45, 1.0 },
                    string.format('Overwrite Save %d by %d?', curW, curH));
                imgui.Spacing();
                if presetExists(curW, curH) then
                    imgui.Text('A preset already exists for this resolution.');
                    imgui.TextColored({ 0.6, 0.6, 0.65, 1.0 }, 'It will be replaced.');
                else
                    imgui.Text('This will create a new preset for this resolution.');
                end
                imgui.Spacing();
                imgui.Spacing();

                if imgui.Button('Yes', { 100, 24 }) then
                    savePreset(curW, curH);
                    imgui.CloseCurrentPopup();
                end
                imgui.SameLine();
                if imgui.Button('Abort', { 100, 24 }) then
                    imgui.CloseCurrentPopup();
                end
                imgui.EndPopup();
            end
        else
            imgui.TextDisabled('Resolution unavailable -- cannot save.');
        end

        -- Which resolutions already have a preset. Only useful to the author,
        -- since everyone else can only load their own resolution anyway.
        imgui.Spacing();
        imgui.TextDisabled('Saved presets:');
        local anySaved = false;
        for _, res in ipairs(COMMON_RESOLUTIONS) do
            if presetExists(res.w, res.h) then
                anySaved = true;
                imgui.TextDisabled(string.format('   %dx%d', res.w, res.h));
            end
        end
        if not anySaved then
            imgui.TextDisabled('   (none)');
        end
    end

    if statusText ~= '' then
        imgui.Spacing();
        if statusIsError then
            imgui.TextColored({ 1.0, 0.45, 0.45, 1.0 }, statusText);
        else
            imgui.TextColored({ 0.6, 0.9, 0.6, 1.0 }, statusText);
        end
    end
end

-- Called from XIUI.lua's unload handler.
--
-- This is the only safe moment to write imgui.ini: imgui has already flushed
-- its in-memory positions, and the addon has not yet reloaded and re-read the
-- file. Merging any earlier gets clobbered by the flush; any later and the
-- positions are already applied.
function M.ApplyPendingLayout()
    local pending = _XIUI_PENDING_PRESET_LAYOUT;
    if pending == nil then return; end
    pcall(loadWindowLayout, pending.w, pending.h);

    -- Deliberately NOT cleared here.
    --
    -- If Ashita's imgui host flushes config\\imgui.ini AFTER this unload
    -- handler returns, the merge above is overwritten and the layout does not
    -- apply. Leaving the flag set means the load handler re-applies it on the
    -- way back up, which lands after any such flush. Whichever of the two
    -- writes survives, the layout ends up correct.
    --
    -- The load side clears it, so this cannot loop.
end

-- Called from XIUI.lua's load handler, as a second chance at the merge.
function M.ApplyPendingLayoutOnLoad()
    local pending = _XIUI_PENDING_PRESET_LAYOUT;
    if pending == nil then return false; end
    _XIUI_PENDING_PRESET_LAYOUT = nil;

    local ok, info = loadWindowLayout(pending.w, pending.h);
    return ok, info;
end

function M.DrawColorSettings()
end

return M;
