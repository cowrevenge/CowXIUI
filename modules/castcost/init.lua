--[[
* XIUI Cast Cost Module
* Displays information about the currently selected spell, ability, or mount
* in the game's selection menus (MP cost, cast time, recast, etc.)
]]--

require('common');
require('handlers.helpers');

local data = require('modules.castcost.data');
local display = require('modules.castcost.display');

local castcost = {};

-- ============================================
-- Module Lifecycle
-- ============================================

function castcost.Initialize(settings)
    display.Initialize(settings);
end

function castcost.UpdateVisuals(settings)
    display.UpdateVisuals(settings);
end

function castcost.SetHidden(hidden)
    display.SetHidden(hidden);
end

function castcost.Cleanup()
    display.Cleanup();
end

-- ============================================
-- Main Render
-- ============================================

function castcost.DrawWindow(settings)
    -- Check if player is valid
    local player = GetPlayerSafe();
    if player == nil then
        display.SetHidden(true);
        return;
    end

    if player.isZoning then
        display.SetHidden(true);
        return;
    end

    -- ===== PREVIEW MODE =====
    -- When the config menu is open, render a fake "Cure IV" selection through
    -- the real display path so the window is visible and can be positioned,
    -- without needing a live spell menu open in-game.
    local isPreview = showConfig and showConfig[1];
    if isPreview then
        local previewInfo = {
            id           = 0,
            name         = 'Cure IV (Preview)',
            mpCost       = 88,
            castTime     = 0,
            recastDelay  = 40,   -- 1/4s units -> 10s
            skill        = 0,
            maxRecast    = 10,
            currentRecast= 7,    -- show a partial cooldown so "Next" appears
        };
        local colors = gConfig.colorCustomization.castCost or {};
        display.Render(previewInfo, 'spell', settings, colors);
        return;
    end

    -- Get current selection from active menu
    local itemInfo, itemType = data.GetCurrentSelection();

    -- If no menu is open or no selection, hide
    if itemInfo == nil then
        display.SetHidden(true);
        return;
    end

    -- Get color settings
    local colors = gConfig.colorCustomization.castCost or {};

    -- Render the display
    display.Render(itemInfo, itemType, settings, colors);
end

return castcost;