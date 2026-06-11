--[[
* XIUI Config Menu - Treasure Pool Settings
* Contains settings for Treasure Pool module
]]--

require('common');
require('handlers.helpers');
local components = require('config.components');
local imgui = require('imgui');
local treasurePool = require('modules.treasurepool.init');

local M = {};

-- Preview toggle callback. The actual SetPreview is driven each frame by the
-- main loop from (config-menu-open AND this checkbox); here we only persist.
local function onPreviewChanged()
    SaveSettingsOnly();
end

-- Ensure defaults exist before drawing (config may draw before module init)
local function ensureDefaults()
    if gConfig.treasurePoolEnabled == nil then gConfig.treasurePoolEnabled = true; end
    if gConfig.treasurePoolShowTimerBar == nil then gConfig.treasurePoolShowTimerBar = true; end
    if gConfig.treasurePoolShowTimerText == nil then gConfig.treasurePoolShowTimerText = true; end
    if gConfig.treasurePoolShowLots == nil then gConfig.treasurePoolShowLots = true; end
    -- Font size MUST be valid (slider min is 8)
    if gConfig.treasurePoolFontSize == nil or gConfig.treasurePoolFontSize < 8 then
        gConfig.treasurePoolFontSize = 10;
    end
    if gConfig.treasurePoolScaleX == nil or gConfig.treasurePoolScaleX < 0.5 then
        gConfig.treasurePoolScaleX = 1.0;
    end
    if gConfig.treasurePoolScaleY == nil or gConfig.treasurePoolScaleY < 0.5 then
        gConfig.treasurePoolScaleY = 1.0;
    end
    -- Split background/border settings (like petbar)
    if gConfig.treasurePoolBgScale == nil or gConfig.treasurePoolBgScale < 0.1 then
        gConfig.treasurePoolBgScale = 1.0;
    end
    if gConfig.treasurePoolBorderScale == nil or gConfig.treasurePoolBorderScale < 0.1 then
        gConfig.treasurePoolBorderScale = 1.0;
    end
    if gConfig.treasurePoolBackgroundOpacity == nil then gConfig.treasurePoolBackgroundOpacity = 0.87; end
    if gConfig.treasurePoolBorderOpacity == nil then gConfig.treasurePoolBorderOpacity = 1.0; end
    if gConfig.treasurePoolBackgroundTheme == nil then gConfig.treasurePoolBackgroundTheme = 'Plain'; end
    if gConfig.treasurePoolExpanded == nil then gConfig.treasurePoolExpanded = false; end
    if gConfig.treasurePoolShowButtonsInCollapsed == nil then gConfig.treasurePoolShowButtonsInCollapsed = true; end
    if gConfig.treasurePoolAutoHideWhenEmpty == nil then gConfig.treasurePoolAutoHideWhenEmpty = true; end
end

-- Get available background themes
local function getBackgroundThemes()
    local themes = { '-None-', 'Plain' };
    for i = 1, 8 do
        table.insert(themes, 'Window' .. i);
    end
    return themes;
end

-- Section: Treasure Pool Settings
function M.DrawSettings()
    -- Ensure defaults before drawing sliders
    ensureDefaults();

    components.DrawCheckbox('Enabled', 'treasurePoolEnabled', CheckVisibility);
    components.DrawCheckbox('Preview', 'treasurePoolPreview', onPreviewChanged);

    if components.CollapsingSection('Display Settings', true) then
        if gConfig.treasurePoolEnabled then
            components.DrawCheckbox('Show Timer Bar', 'treasurePoolShowTimerBar');
            imgui.ShowHelp('Show countdown progress bar on pool items');

            components.DrawCheckbox('Show Timer Text', 'treasurePoolShowTimerText');
            imgui.ShowHelp('Show timer text (countdown like "4:32")');

            components.DrawCheckbox('Show Lots', 'treasurePoolShowLots');
            imgui.ShowHelp('Show winning lot info');

            components.DrawCheckbox('Show Buttons In Collapsed View', 'treasurePoolShowButtonsInCollapsed');
            imgui.ShowHelp('Show Lot/Pass buttons even when not in expanded view');

            components.DrawCheckbox('Start Expanded', 'treasurePoolExpanded');
            imgui.ShowHelp('Start with expanded view showing all lot details');

            components.DrawCheckbox('Auto-Hide When Empty', 'treasurePoolAutoHideWhenEmpty');
            imgui.ShowHelp('Hide the treasure pool window when there are no items in the pool');

            -- Size settings
            components.DrawSlider('Text Size', 'treasurePoolFontSize', 8, 16);
            imgui.ShowHelp('Font size for item names, timers, and lot info');
            components.DrawSlider('Scale X', 'treasurePoolScaleX', 0.5, 2.0, '%.1f');
            imgui.ShowHelp('Horizontal scale factor');
            components.DrawSlider('Scale Y', 'treasurePoolScaleY', 0.5, 2.0, '%.1f');
            imgui.ShowHelp('Vertical scale factor');
        end
    end

    if components.CollapsingSection('Background', false) then
        -- Background theme dropdown
        local themes = getBackgroundThemes();
        local currentTheme = gConfig.treasurePoolBackgroundTheme or 'Plain';
        if imgui.BeginCombo('Theme##treasurePoolBg', currentTheme) then
            for _, theme in ipairs(themes) do
                local isSelected = (theme == currentTheme);
                if imgui.Selectable(theme, isSelected) then
                    gConfig.treasurePoolBackgroundTheme = theme;
                    UpdateSettings();
                end
                if isSelected then
                    imgui.SetItemDefaultFocus();
                end
            end
            imgui.EndCombo();
        end
        imgui.ShowHelp('Window background style (Plain = solid, Window1-8 = themed with borders)');

        -- Scale/opacity sliders
        components.DrawSlider('Background Scale##treasurePool', 'treasurePoolBgScale', 0.1, 3.0, '%.2f');
        imgui.ShowHelp('Scale of the background texture.');
        components.DrawSlider('Border Scale##treasurePool', 'treasurePoolBorderScale', 0.1, 3.0, '%.2f');
        imgui.ShowHelp('Scale of the window borders (Window themes only).');
        components.DrawSlider('Background Opacity##treasurePool', 'treasurePoolBackgroundOpacity', 0.0, 1.0, '%.2f');
        imgui.ShowHelp('Opacity of the background.');
        components.DrawSlider('Border Opacity##treasurePool', 'treasurePoolBorderOpacity', 0.0, 1.0, '%.2f');
        imgui.ShowHelp('Opacity of the window borders (Window themes only).');
    end

    if components.CollapsingSection('BovineLooty Auto-Lot/Pass##treasurepool') then
        imgui.TextWrapped('Auto-lot/pass pooled items by ID. Managed in the "Looty" tab of the Treasure Pool window. On the Pool tab, each item shows two boxes: BLUE = Auto-Lot, RED = Auto-Pass. Lists are mutually exclusive (Lot wins). Lots are validated (skips Rare-owned / inventory-full) and fire once per item. Rate limited: one action/second, max 10 per 10s.');
        imgui.Spacing();
        if gConfig.bovineLootyShowBoxes == nil then gConfig.bovineLootyShowBoxes = true; end
        components.DrawCheckbox('Show Add Boxes on Pool Items', 'bovineLootyShowBoxes');
        imgui.ShowHelp('Show the blue/red add-to-list boxes on each pool item.');
        imgui.Spacing();
        local running = treasurePool.BovineLootyIsRunning and treasurePool.BovineLootyIsRunning();
        if running then
            imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, 'Auto-pass: RUNNING');
        else
            imgui.TextColored({ 1.0, 0.6, 0.6, 1.0 }, 'Auto-pass: stopped');
        end
        imgui.ShowHelp('Auto-pass always starts stopped on load and must be started each session. The pass-list itself is saved.');
        imgui.Spacing();
        local locked = treasurePool.BovineLootyIsLocked and treasurePool.BovineLootyIsLocked();
        if imgui.Button((locked and 'Lock Looty Off' or 'Lock Looty Open') .. '##bvlcfg') then
            treasurePool.BovineLootyToggleWindow();
        end
        imgui.ShowHelp('Lock the Treasure Pool window open on the Looty tab (ignores auto-hide) until toggled off.');
    end

    if components.CollapsingSection('Chat Commands##treasurepool') then
        imgui.BulletText('/xiui lotall - Lot on all items');
        imgui.BulletText('/xiui passall - Pass on all items');
        imgui.BulletText('/xiui bvl - Switch to the Looty tab');
        imgui.BulletText('/xiui bvl start|stop|toggle - Control automation');
        imgui.BulletText('/xiui bvl load|save - Load/save a list file');
        imgui.BulletText('/xiui bvl addlot|addpass|rm <id> - Manage lists');
    end
end

-- Section: Treasure Pool Color Settings
function M.DrawColorSettings()
    if components.CollapsingSection('Treasure Pool Colors') then
        imgui.TextDisabled('Color settings coming soon');
    end
end

return M;