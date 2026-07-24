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
* Files land in the addon's settings folder as:
*     presets/2560x1440.lua
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
    return string.format('%sconfig\\addons\\XIUI\\presets\\',
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

    setStatus(string.format('Saved %dx%d', w, h), false);
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

    -- LOAD: only offered when a preset exists for the CURRENT resolution.
    --
    -- Loading a layout built for another resolution is what this module exists
    -- to prevent -- absolute pixel positions would land things off-screen. So
    -- rather than listing every resolution and letting you pick the wrong one,
    -- the button only appears when there is a matching file.
    local canLoad = curW ~= nil and presetExists(curW, curH);

    if canLoad then
        if imgui.Button(string.format('Load Preset (%dx%d)##presetLoad', curW, curH), { 220, 0 }) then
            loadPreset(curW, curH);
        end
        imgui.ShowHelp('Replaces the current config with the saved layout for this resolution.');
    else
        imgui.TextDisabled('No preset saved for this resolution.');
    end

    -- SAVE: author only. See PRESET_AUTHOR above.
    if isAuthor() then
        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        if curW then
            if imgui.Button(string.format('Save Preset (%dx%d)##presetSave', curW, curH), { 220, 0 }) then
                savePreset(curW, curH);
            end
            imgui.ShowHelp('Writes the current config to presets\\' .. curW .. 'x' .. curH .. '.lua, overwriting any existing file for this resolution.');
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

function M.DrawColorSettings()
end

return M;
