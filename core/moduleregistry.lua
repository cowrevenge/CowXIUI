--[[
* XIUI UI Module Registry
* Data-driven module management for initialization, rendering, cleanup, and visibility
*
* All per-module entry points (Initialize, UpdateVisuals, DrawWindow, Cleanup,
* SetHidden) are pcall-wrapped so a single broken module cannot:
*   1. brick startup (init pcall keeps bInitialized able to flip true)
*   2. cause the present loop to die before configMenu.DrawWindow runs
*   3. spam chat (errors logged once per (module, phase, message))
* A module that errors more than MAX_ERRORS_PER_MODULE times in a session is
* auto-flagged disabled until the user fixes it via /xiui.
]]--

local chat = require('chat');

local M = {};

local registry = {};

-- Error tracking ------------------------------------------------------------
local loggedErrors = {};        -- dedupe key -> true
local moduleErrorCounts = {};   -- name -> int
local disabledModules = {};     -- name -> true (auto-disabled for session)
local MAX_ERRORS_PER_MODULE = 5;

local function logModuleError(name, phase, err)
    local key = (name or '?') .. '|' .. (phase or '?') .. '|' .. tostring(err);
    if loggedErrors[key] then return; end
    loggedErrors[key] = true;
    print(chat.header('XIUI'):append(chat.error(
        ('[%s] %s error: %s'):format(tostring(name), tostring(phase), tostring(err)))));
end

-- Returns true if module should be skipped on future frames
local function bumpErrorCount(name)
    moduleErrorCounts[name] = (moduleErrorCounts[name] or 0) + 1;
    if moduleErrorCounts[name] >= MAX_ERRORS_PER_MODULE and not disabledModules[name] then
        disabledModules[name] = true;
        print(chat.header('XIUI'):append(chat.error(
            ('[%s] auto-disabled after %d errors. Open /xiui to disable manually or fix.')
            :format(tostring(name), MAX_ERRORS_PER_MODULE))));
    end
    return disabledModules[name] == true;
end

local function safeCall(name, phase, fn, ...)
    if fn == nil then return true; end
    local ok, err = pcall(fn, ...);
    if not ok then
        logModuleError(name, phase, err);
        bumpErrorCount(name);
        return false;
    end
    return true;
end

-- Expose error state so the config menu / commands can introspect it
function M.IsDisabled(name)
    return disabledModules[name] == true;
end

function M.GetErrorStats()
    return moduleErrorCounts, disabledModules;
end

function M.ClearErrors(name)
    if name then
        moduleErrorCounts[name] = nil;
        disabledModules[name] = nil;
    else
        moduleErrorCounts = {};
        disabledModules = {};
        loggedErrors = {};
    end
end

-- Registry API --------------------------------------------------------------
function M.Register(name, config)
    -- Guard against a nil module. This happens when XIUI.lua registers a module
    -- (module = uiMods.X) but modules/init.lua wasn't updated to require it, so
    -- uiMods.X is nil. Without this guard the nil module survives into
    -- InitializeAll and every entry.module.X deref crashes. Skip + warn instead
    -- so a partial file copy fails loud but soft, naming the culprit.
    if config == nil or config.module == nil then
        print(string.format(
            '[XIUI] Skipping module registration for "%s": module is nil. '
            .. 'Likely a partial file copy -- make sure modules/init.lua '
            .. 'requires it and the module file is present.',
            tostring(name)));
        return;
    end
    registry[name] = config;
end

function M.Get(name)
    return registry[name];
end

function M.GetAll()
    return registry;
end

-- Initialize all registered modules
function M.InitializeAll(gAdjustedSettings)
    for name, entry in pairs(registry) do
        if entry.module.Initialize then
            safeCall(name, 'Initialize', entry.module.Initialize, gAdjustedSettings[entry.settingsKey]);
        end
    end
end

-- Update visuals for all registered modules
function M.UpdateVisualsAll(gAdjustedSettings)
    for name, entry in pairs(registry) do
        if entry.module.UpdateVisuals and not disabledModules[name] then
            safeCall(name, 'UpdateVisuals', entry.module.UpdateVisuals, gAdjustedSettings[entry.settingsKey]);
        end
    end
end

-- Cleanup all registered modules
function M.CleanupAll()
    for name, entry in pairs(registry) do
        if entry.module.Cleanup then
            safeCall(name, 'Cleanup', entry.module.Cleanup);
        end
    end
end

-- Hide all modules that support SetHidden
function M.HideAll()
    for name, entry in pairs(registry) do
        if entry.hasSetHidden and entry.module.SetHidden and not disabledModules[name] then
            safeCall(name, 'SetHidden', entry.module.SetHidden, true);
        end
    end
end

-- Check visibility based on config and hide if needed
function M.CheckVisibility(gConfig)
    for name, entry in pairs(registry) do
        if entry.configKey and entry.hasSetHidden and not disabledModules[name] then
            if gConfig[entry.configKey] == false then
                safeCall(name, 'SetHidden', entry.module.SetHidden, true);
            end
        end
    end
end

-- Render a single module
-- Returns true if rendered, false if hidden / errored / disabled
function M.RenderModule(name, gConfig, gAdjustedSettings, eventSystemActive)
    local entry = registry[name];
    if not entry then return false; end
    if disabledModules[name] then return false; end

    -- Check if module should be shown
    local shouldShow = true;
    if entry.configKey then
        shouldShow = gConfig[entry.configKey] ~= false;
    end

    -- Check event hiding
    if shouldShow and entry.hideOnEventKey and eventSystemActive then
        shouldShow = not gConfig[entry.hideOnEventKey];
    end

    if shouldShow then
        -- Restore visibility if module was previously hidden
        if entry.hasSetHidden and entry.module.SetHidden then
            safeCall(name, 'SetHidden', entry.module.SetHidden, false);
        end
        if entry.module.DrawWindow then
            local settings = gAdjustedSettings[entry.settingsKey];
            return safeCall(name, 'DrawWindow', entry.module.DrawWindow, settings);
        end
        return true;
    else
        if entry.hasSetHidden and entry.module.SetHidden then
            safeCall(name, 'SetHidden', entry.module.SetHidden, true);
        end
        return false;
    end
end

-- Create a visual updater function for a specific module
function M.CreateVisualUpdater(name, saveSettingsFunc, gAdjustedSettings)
    local entry = registry[name];
    if not entry then return function() end; end

    return function()
        saveSettingsFunc();
        if entry.module.UpdateVisuals then
            safeCall(name, 'UpdateVisuals', entry.module.UpdateVisuals, gAdjustedSettings[entry.settingsKey]);
        end
    end
end

return M;