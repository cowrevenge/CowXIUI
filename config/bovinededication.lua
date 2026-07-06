--[[
* XIUI Config Menu - Dedication Tracker Settings
* Contains settings for the bovinededication module.
]]--

require('common');
require('handlers.helpers');
local components = require('config.components');
local imgui = require('imgui');

local M = {};

function M.DrawSettings()
    components.DrawCheckbox('Enabled', 'showBovinededication', CheckVisibility);
    components.DrawCheckbox('Hidden Window', 'bovinededicationHidden', CheckVisibility);
    imgui.ShowHelp('When on, the tracker window stays hidden even while Dedication is active.');

    if components.CollapsingSection('Reset##bovinededication') then
        if imgui.Button('Reset Tracker##bovinededication_reset') then
            local ok, mod = pcall(require, 'modules.bovinededication.bovinededication');
            if ok and mod and type(mod.Reset) == 'function' then
                pcall(mod.Reset);
            end
        end
        imgui.ShowHelp('Wipes the tracker completely. The window stays hidden until you use another EXP-bonus item.');
    end

    if components.CollapsingSection('About##bovinededication') then
        imgui.Text('Tracks EXP bonus rings and scrolls that');
        imgui.Text('grant the Dedication effect. The window');
        imgui.Text('appears when Dedication is active and');
        imgui.Text('disappears when it wears off.');
        imgui.Spacing();
        imgui.Text('Empress Band       +50%%   1,000 cap');
        imgui.Text('Emperor Band       +75%%   2,250 cap');
        imgui.Text('Chariot Band       +100%%  4,000 cap');
        imgui.Text('Wandering Heroes   +75%%  10,000 cap');
        imgui.Text('Anniversary Ring   +100%%  3,000 cap');
    end
end

function M.DrawColorSettings()
end

return M;