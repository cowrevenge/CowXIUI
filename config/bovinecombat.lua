--[[
* XIUI Config Menu - Combat Timers Settings
* Settings for the bovinecombat module (Time Since Last Attack / Defence).
]]--

require('common');
require('handlers.helpers');
local components = require('config.components');
local imgui = require('imgui');

local M = {};

function M.DrawSettings()
    components.DrawCheckbox('Enabled', 'showBovinecombat', CheckVisibility);
    components.DrawCheckbox('Hidden Window', 'bovinecombatHidden', CheckVisibility);
    imgui.ShowHelp('When on, the timers window stays hidden. Re-enable it here.');
    components.DrawCheckbox('Show Resting Tick Countdown', 'bovinecombatShowRestTick');
    imgui.ShowHelp('Shows "Next Tick" countdown to the next resting HP/MP tick (resets on each tick packet, then counts down from 12s). The tick itself is 10s; the count runs to 12 because packets land +-2s, and it resets the moment one arrives. Only counts while resting.');

    if components.CollapsingSection('Font##bovinecombat') then
        components.DrawCheckbox('Override Font', 'bovinecombatOverrideFont');
        imgui.ShowHelp('Use a different font family and weight here instead of the Global Text Settings.');

        if gConfig.bovinecombatOverrideFont then
            imgui.Indent(20);
            components.DrawComboBox('Font Family##bovinecombat', gConfig.bovinecombatFontFamily or 'Default',
                components.available_fonts, function(newValue)
                    gConfig.bovinecombatFontFamily = newValue;
                    SaveSettingsOnly();
                    UpdateUserSettings();
                end);
            imgui.ShowHelp('Default is imgui built-in bitmap font -- stays crisp at small sizes where the TTF families blur.');

            components.DrawComboBox('Font Weight##bovinecombat', gConfig.bovinecombatFontWeight or 'Normal',
                {'Normal', 'Bold'}, function(newValue)
                    gConfig.bovinecombatFontWeight = newValue;
                    SaveSettingsOnly();
                    UpdateUserSettings();
                end);
            imgui.Unindent(20);
        end
    end

    if components.CollapsingSection('Reset##bovinecombat') then
        if imgui.Button('Reset Timers##bovinecombat_reset') then
            local ok, mod = pcall(require, 'modules.bovinecombat.bovinecombat');
            if ok and mod and type(mod.Reset) == 'function' then
                pcall(mod.Reset);
            end
        end
        imgui.ShowHelp('Zeroes both round timers and counters.');
    end

    if components.CollapsingSection('About##bovinecombat') then
        imgui.Text('Shows how long since your last melee');
        imgui.Text('round landed (Since Attack) and since a');
        imgui.Text('mob last hit or missed you (Since');
        imgui.Text('Defence). Both only count while engaged;');
        imgui.Text('they read -- when not engaged.');
        imgui.Spacing();
        imgui.TextDisabled('Multi-hit rounds (Double/Triple Attack)');
        imgui.TextDisabled('collapse into one round via a 0.35s window.');
        imgui.Spacing();
        imgui.Text('Next Tick counts down to the next resting');
        imgui.Text('HP/MP tick. Estimates ~21s, then locks');
        imgui.Text('to the real gain and runs a 10s cycle.');
    end
end

function M.DrawColorSettings()
end

return M;
