--[[
* XIUI Config Menu - Latent Trial Tracker Settings
* Contains settings for the bovinelatent (Latent Trial) tracker.
]]--

require('common');
require('handlers.helpers');
local components = require('config.components');
local imgui = require('imgui');

-- Load the tracker module once, keep the handle for reset actions.
local trackerOk, tracker = pcall(require, 'modules.bovinelatent.bovinelatent');
if not trackerOk then tracker = nil; end

local M = {};

-- Section: Latent Trial Settings
function M.DrawSettings()
    components.DrawCheckbox('Enabled', 'showBovinelatent', CheckVisibility);
    components.DrawCheckbox('Hidden Window', 'bovinelatentHidden', CheckVisibility);
    imgui.ShowHelp('When on, the tracker window stays hidden even with a trial weapon equipped.');
    components.DrawCheckbox('Rainbow Flash on Finish', 'bovinelatentRainbowOnFinish', CheckVisibility);
    imgui.ShowHelp('Flash the window in rainbow colors and echo a completion message on trial milestones.');

    if components.CollapsingSection('WeaponSkill trials##bovinelatent') then
        imgui.Text('Solo WS         1 pt');
        imgui.Text('Close Lv1 SC    2 pts');
        imgui.Text('Close Lv2 SC    3 pts');
        imgui.Text('Close Lv3 SC    5 pts');
        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        -- Per-weapon list, each with its own Reset button.
        local weapons = {};
        if tracker and type(tracker.GetTrials) == 'function' then
            local ok, list = pcall(tracker.GetTrials);
            if ok and type(list) == 'table' then weapons = list; end
        end

        if #weapons == 0 then
            imgui.Text('No trial weapons recorded yet.');
        else
            for i = 1, #weapons do
                local w = weapons[i];
                imgui.Text(string.format('%s', w.name));
                imgui.Text(string.format(
                    '  Solo %d  Lv1 %d  Lv2 %d  Lv3 %d  Total %d / %d',
                    w.solo or 0, w.lvl1 or 0, w.lvl2 or 0, w.lvl3 or 0,
                    w.total or 0, w.threshold or 300));
                imgui.SameLine();
                if imgui.Button('Reset##bovinelatent_reset_' .. tostring(i)) then
                    if tracker and type(tracker.ResetWeapon) == 'function' then
                        pcall(tracker.ResetWeapon, w.name);
                    end
                end
                -- Manual point injectors: bump Solo by 10 / 50 / 100 for the
                -- selected weapon. Use case is catching up counts after
                -- forgetting to track a session, or handing yourself extra
                -- trial credit for offline WS.
                imgui.SameLine();
                if imgui.Button('+10##bovinelatent_add10_' .. tostring(i)) then
                    if tracker and type(tracker.AddSolo) == 'function' then
                        pcall(tracker.AddSolo, w.name, 10);
                    end
                end
                imgui.SameLine();
                if imgui.Button('+50##bovinelatent_add50_' .. tostring(i)) then
                    if tracker and type(tracker.AddSolo) == 'function' then
                        pcall(tracker.AddSolo, w.name, 50);
                    end
                end
                imgui.SameLine();
                if imgui.Button('+100##bovinelatent_add100_' .. tostring(i)) then
                    if tracker and type(tracker.AddSolo) == 'function' then
                        pcall(tracker.AddSolo, w.name, 100);
                    end
                end
                imgui.Spacing();
            end
        end
    end

    if components.CollapsingSection('Dark Knight##bovinelatent') then
        -- Chaosbringer: kill counter. +1 when the player LAST-HITS a mob
        -- with a melee swing, defeats it, and gains XP. DoT-only kills, WS
        -- kills, and non-XP kills do not count.
        local kills = 0;
        if tracker and type(tracker.GetChaosbringerKills) == 'function' then
            local ok, n = pcall(tracker.GetChaosbringerKills);
            if ok then kills = tonumber(n) or 0; end
        end

        imgui.Text(string.format('Chaosbringer kills:  %d', kills));
        imgui.ShowHelp('Counts up only when you MELEE last-hit the mob, defeat it, and gain XP. DoT/WS/pet kills do not count.');

        if imgui.Button('Reset##chaos_reset') then
            if tracker and type(tracker.ResetChaosbringer) == 'function' then
                pcall(tracker.ResetChaosbringer);
            end
        end
        imgui.SameLine();
        if imgui.Button('+10##chaos_add10') then
            if tracker and type(tracker.AddChaosbringerKills) == 'function' then
                pcall(tracker.AddChaosbringerKills, 10);
            end
        end
        imgui.SameLine();
        if imgui.Button('+50##chaos_add50') then
            if tracker and type(tracker.AddChaosbringerKills) == 'function' then
                pcall(tracker.AddChaosbringerKills, 50);
            end
        end
        imgui.SameLine();
        if imgui.Button('+100##chaos_add100') then
            if tracker and type(tracker.AddChaosbringerKills) == 'function' then
                pcall(tracker.AddChaosbringerKills, 100);
            end
        end
    end
end

-- No color-configurable elements yet; stubbed so the config dispatch tables
-- (which run settings + color in lockstep) can hold this module.
function M.DrawColorSettings()
end

return M;