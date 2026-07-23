--[[
* XIUI Config Menu - Global Settings
* Contains settings and color settings for Global configuration
]]--

require('common');
require('handlers.helpers');
local components = require('config.components');
local statusHandler = require('handlers.statushandler');
local updater = require('libs.updater');
local imgui = require('imgui');

local M = {};

-- Section: Global Settings (combines General, Font, and Bar settings)
function M.DrawSettings()
    if components.CollapsingSection('General##global') then
        -- Updates first: this is the thing people come looking for, and it was
        -- easy to miss buried under the theme pickers.
        --
        -- Both buttons are BLOCKING network calls (LuaSocket), so they only
        -- ever run on an explicit click, never on a timer or during render.
        components.DrawCheckbox('Auto update', 'autoUpdateCheck');
        imgui.ShowHelp('On load, check GitHub and download any changed files, then reload the addon automatically. The game freezes briefly while it downloads.');

        -- Check Updates: reports status only, never writes anything.
        --
        -- Note there's no "Checking..." label: Check() blocks, and ImGui is
        -- immediate mode, so the frame never presents while it runs. A
        -- transient label would be unreachable and just imply the call is
        -- async when it isn't. The game visibly hitches instead.
        if imgui.Button('Check Updates##xiuiCheck', { 110, 0 }) then
            updater.Check();
        end
        imgui.ShowHelp('Asks GitHub whether a newer version exists. Does not download or change anything. The game freezes for a moment while it asks.');

        -- Update Now is always drawn so the pair is visibly a pair, but it's
        -- disabled until a check has actually found something to download.
        imgui.SameLine();
        if updater.updateReady then
            if imgui.Button('Update Now##xiuiUpdate', { 110, 0 }) then
                updater.Update();
            end
            imgui.ShowHelp('Downloads the changed files and reloads the addon automatically. The game freezes briefly while it downloads.');
        else
            imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.4);
            imgui.Button('Update Now##xiuiUpdateOff', { 110, 0 });
            imgui.PopStyleVar();
            imgui.ShowHelp('Nothing to download. Run Check Updates first.');
        end

        if updater.message ~= nil and updater.message ~= '' then
            if updater.status == 'error' then
                imgui.TextColored({ 1.0, 0.45, 0.45, 1.0 }, updater.message);
            elseif updater.updateReady then
                imgui.TextColored({ 1.0, 0.85, 0.4, 1.0 }, updater.message);
            else
                imgui.TextColored({ 0.6, 0.9, 0.6, 1.0 }, updater.message);
            end
        end

        imgui.Separator();

        components.DrawCheckbox('Lock HUD Position', 'lockPositions');

        -- Status Icon Theme
        local status_theme_paths = statusHandler.get_status_theme_paths();
        components.DrawComboBox('Status Icon Theme', gConfig.statusIconTheme, status_theme_paths, function(newValue)
            gConfig.statusIconTheme = newValue;
            SaveSettingsOnly();
            DeferredUpdateVisuals();
        end);
        imgui.ShowHelp('The folder to pull status icons from. [XIUI\\assets\\status]');

        -- Job Icon Theme
        local job_theme_paths = statusHandler.get_job_theme_paths();
        components.DrawComboBox('Job Icon Theme', gConfig.jobIconTheme, job_theme_paths, function(newValue)
            gConfig.jobIconTheme = newValue;
            SaveSettingsOnly();
            DeferredUpdateVisuals();
        end);
        imgui.ShowHelp('The folder to pull job icons from. [XIUI\\assets\\jobs]');

        components.DrawSlider('Tooltip Scale', 'tooltipScale', 0.1, 3.0, '%.2f');
        imgui.ShowHelp('Scales the size of the tooltip. Note that text may appear blured if scaled too large.');

        components.DrawCheckbox('Hide During Events', 'hideDuringEvents');
    end

    if components.CollapsingSection('Text Settings##global') then
        -- Font Family Selector
        components.DrawComboBox('Font Family', gConfig.fontFamily, components.available_fonts, function(newValue)
            gConfig.fontFamily = newValue;
            ClearDebuffFontCache();
            UpdateSettings();
        end);
        imgui.ShowHelp('The font family to use for all text in XIUI. Fonts must be installed on your system.');

        -- Font Weight Selector
        components.DrawComboBox('Font Weight', gConfig.fontWeight, {'Normal', 'Bold'}, function(newValue)
            gConfig.fontWeight = newValue;
            ClearDebuffFontCache();
            UpdateSettings();
        end);
        imgui.ShowHelp('The font weight (boldness) to use for all text in XIUI.');

        -- Font Outline Width Slider
        -- Uses lightweight UpdateAllFontOutlineWidths instead of DeferredUpdateVisuals
        -- to avoid expensive font recreation on every slider tick
        components.DrawSlider('Font Outline Width', 'fontOutlineWidth', 0, 5, nil, function()
            ClearDebuffFontCache();
            UpdateAllFontOutlineWidths(gConfig.fontOutlineWidth);
        end);
        imgui.ShowHelp('The thickness of the text outline/stroke for all text in XIUI.');
    end

    if components.CollapsingSection('Bar Settings##global') then
        -- Global bookends toggle - sets all individual module bookend settings
        if (imgui.Checkbox('Show Bookends', { gConfig.showBookends })) then
            gConfig.showBookends = not gConfig.showBookends;
            -- Update all individual module bookend settings
            gConfig.showPlayerBarBookends = gConfig.showBookends;
            gConfig.showTargetBarBookends = gConfig.showBookends;
            gConfig.showEnemyListBookends = gConfig.showBookends;
            gConfig.showExpBarBookends = gConfig.showBookends;
            gConfig.showPartyListBookends = gConfig.showBookends;
            gConfig.showCastBarBookends = gConfig.showBookends;
            gConfig.petBarShowBookends = gConfig.showBookends;
            -- Update party A/B/C settings
            if gConfig.partyA then gConfig.partyA.showBookends = gConfig.showBookends; end
            if gConfig.partyB then gConfig.partyB.showBookends = gConfig.showBookends; end
            if gConfig.partyC then gConfig.partyC.showBookends = gConfig.showBookends; end
            -- Update pet bar type settings
            if gConfig.petBarTypeSettings then
                for _, petType in pairs(gConfig.petBarTypeSettings) do
                    if petType then petType.showBookends = gConfig.showBookends; end
                end
            end
            SaveSettingsOnly();
        end
        if gConfig.showBookends then
            imgui.SameLine();
            imgui.SetNextItemWidth(100);
            components.DrawSlider('Size##bookendSize', 'bookendSize', 5, 20);
        end
        imgui.ShowHelp('Toggle bookends on/off for all bars. Individual modules can still override.');

        components.DrawCheckbox('Health Bar Flash Effects', 'healthBarFlashEnabled');
        imgui.ShowHelp('Flash effect when taking damage on health bars.');

        components.DrawSlider('Bar Roundness', 'noBookendRounding', 0, 10);
        imgui.ShowHelp('Corner roundness for bars without bookends (0 = square corners, 10 = very rounded).');

        components.DrawSlider('Bar Border Thickness', 'barBorderThickness', 0, 5);
        imgui.ShowHelp('Thickness of the border around all progress bars.');
    end
end

-- Section: Global Color Settings
function M.DrawColorSettings()
    if components.CollapsingSection('Background Color##globalColor') then
        components.DrawGradientPicker("Bar Background", gConfig.colorCustomization.shared.backgroundGradient, "Background color for all progress bars");
    end

    if components.CollapsingSection('Bookend Gradient##globalColor') then
        components.DrawThreeStepGradientPicker("Bookend", gConfig.colorCustomization.shared.bookendGradient, "3-step gradient for progress bar bookends (top -> middle -> bottom)");
    end

    if components.CollapsingSection('Entity Name Colors##globalColor') then
        components.DrawTextColorPicker("Party/Alliance Player", gConfig.colorCustomization.shared, 'playerPartyTextColor', "Color for party/alliance member names");
        components.DrawTextColorPicker("Other Player", gConfig.colorCustomization.shared, 'playerOtherTextColor', "Color for other player names");
        components.DrawTextColorPicker("NPC", gConfig.colorCustomization.shared, 'npcTextColor', "Color for NPC names");
        components.DrawTextColorPicker("Unclaimed Mob", gConfig.colorCustomization.shared, 'mobUnclaimedTextColor', "Color for unclaimed mob names");
        components.DrawTextColorPicker("Party-Claimed Mob", gConfig.colorCustomization.shared, 'mobPartyClaimedTextColor', "Color for mobs claimed by your party");
        components.DrawTextColorPicker("Other-Claimed Mob", gConfig.colorCustomization.shared, 'mobOtherClaimedTextColor', "Color for mobs claimed by others");
    end

    if components.CollapsingSection('HP Bar Effects##globalColor') then
        components.DrawHPEffectsRow(gConfig.colorCustomization.shared, "##shared");
    end
end

return M;