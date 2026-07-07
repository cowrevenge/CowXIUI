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
        -- Live tracker status -- visible here even with Hidden Window on.
        local ok, mod = pcall(require, 'modules.bovinededication.bovinededication');
        if not ok then mod = nil; end
        local st = nil;
        if mod and type(mod.GetStatus) == 'function' then
            local ok2, res = pcall(mod.GetStatus);
            if ok2 then st = res; end
        end
        if st and st.item ~= '' then
            imgui.Text(string.format('Tracking: %s (+%d%%)', st.item, st.pct or 0));
            imgui.Text(string.format('Used %d / %d   Remaining %d',
                st.used or 0, st.cap or 0, st.remaining or 0));
            if st.buff_up then
                imgui.TextColored({ 0.55, 1.0, 0.65, 1.0 }, 'Dedication active');
            else
                imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 }, 'Dedication not active');
            end
        else
            imgui.TextDisabled('Nothing tracked yet.');
        end
        imgui.Spacing();

        if imgui.Button('Reset Tracker##bovinededication_reset') then
            if mod and type(mod.Reset) == 'function' then
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
        imgui.TextDisabled('Force = arm tracker as if you just used it.');
        imgui.Spacing();

        -- Per-item row: readable label + Force button. Force is useful when
        -- the addon loaded mid-buff, the chat detection missed the use, or
        -- you want to manually resync after a mistake.
        local ok, mod = pcall(require, 'modules.bovinededication.bovinededication');
        if not ok then mod = nil; end

        local rows = {
            { 'Empress Band',                 '+50%   1,000 cap'  },
            { 'Emperor Band',                 '+75%   2,250 cap'  },
            { 'Chariot Band',                 '+100%  4,000 cap'  },
            { 'Tale of the Wandering Heroes', '+75%  10,000 cap'  },
            { 'Anniversary Ring',             '+100%  3,000 cap'  },
        };
        for i = 1, #rows do
            local name, meta = rows[i][1], rows[i][2];
            imgui.Text(string.format('%-30s %s', name, meta));
            imgui.SameLine();
            if imgui.Button('Force##bovinededication_force_' .. tostring(i)) then
                if mod and type(mod.ForceItem) == 'function' then
                    pcall(mod.ForceItem, name);
                end
            end
        end
    end
end

function M.DrawColorSettings()
end

return M;