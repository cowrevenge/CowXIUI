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
* All window positions live in gConfig.windowPositions, populated by
* SaveWindowPosition() calls in every module. The preset .lua file captures
* them alongside every other setting, so no companion .ini files are needed.
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
    return string.format('%saddons\\XIUI\\modules\\presets\\',
        AshitaCore:GetInstallPath());
end

local function presetPath(w, h)
    return string.format('%s%dx%d.lua', presetDir(), w, h);
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

    -- Count saved window positions for the status message.
    local posCount = 0;
    if gConfig.windowPositions then
        for _ in pairs(gConfig.windowPositions) do posCount = posCount + 1; end
    end
    setStatus(string.format('Saved %dx%d (%d windows)', w, h, posCount), false);
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

    -- Clear the one-shot guard so every module re-applies its saved position
    -- from gConfig.windowPositions on the next frame via ApplyWindowPosition().
    gConfig.appliedPositions = {};

    -- Trigger a visual refresh so modules pick up the new settings immediately.
    if DeferredUpdateVisuals then
        DeferredUpdateVisuals();
    end

    setStatus(string.format('Loaded %dx%d', w, h), false);
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

    local CONFIRM_LOAD = 'Load Preset?##presetConfirmLoad';
    local CONFIRM_SAVE = 'Overwrite Preset?##presetConfirmSave';

    local canLoad = curW ~= nil and presetExists(curW, curH);

    if canLoad then
        if imgui.Button(string.format('Load Preset (%dx%d)##presetLoad', curW, curH), { 220, 0 }) then
            imgui.OpenPopup(CONFIRM_LOAD);
        end
        imgui.ShowHelp('Replaces the current config with the saved layout for this resolution. All settings and window positions are applied immediately.');
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
            imgui.ShowHelp('Writes the current config (including all window positions) to modules\\presets\\' .. curW .. 'x' .. curH .. '.lua, overwriting any existing file for this resolution.');

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

function M.DrawColorSettings()
end

return M;
