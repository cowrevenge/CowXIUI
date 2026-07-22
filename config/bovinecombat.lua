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
    end
end

function M.DrawColorSettings()
end

return M;
