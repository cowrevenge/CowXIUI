--[[---------------------------------------------------------------------------
  XIUI hideparty config tab
  Maps to: xiui/config/hideparty.lua

  Sidebar tab module for the Hideparty native-UI suppression module. Provides
  per-element checkboxes for the five primitives that modules/hideparty.lua
  controls: party0 / party1 / party2 / target / castinfo.

  The "castinfo" primitive is the native spell-info window (MP cost, recast,
  "Next: 0:00"). It's a single primitive that handles BOTH spell info and
  job-ability info, so this one checkbox hides both windows.
-----------------------------------------------------------------------------]]

local imgui = require('imgui');

local hidepartyConfigUI = {};

-- Backfills gConfig.hideStockUI with defaults so older XIUI configs (or fresh
-- installs) get every key set without losing other settings. Safe to call
-- repeatedly; only fills keys that don't already exist.
function hidepartyConfigUI.EnsureDefaults()
    if gConfig == nil then return; end
    if gConfig.hideStockUI == nil then gConfig.hideStockUI = {}; end
    local h = gConfig.hideStockUI;
    if h.enabled  == nil then h.enabled  = true; end
    if h.party0   == nil then h.party0   = true; end
    if h.party1   == nil then h.party1   = true; end
    if h.party2   == nil then h.party2   = true; end
    if h.target   == nil then h.target   = true; end
    if h.castinfo == nil then h.castinfo = true; end
end

function hidepartyConfigUI.DrawSettings()
    hidepartyConfigUI.EnsureDefaults();
    local h = gConfig.hideStockUI;

    if imgui.CollapsingHeader('Hide Native UI', ImGuiTreeNodeFlags_DefaultOpen) then
        local enabled = { h.enabled };
        if imgui.Checkbox('Enable', enabled) then
            h.enabled = enabled[1];
        end
        imgui.SameLine();
        imgui.TextDisabled('(master toggle; off shows everything)');

        imgui.Separator();

        local party0 = { h.party0 };
        if imgui.Checkbox('Hide Main Party (members 1-6)', party0) then
            h.party0 = party0[1];
        end

        local party1 = { h.party1 };
        if imgui.Checkbox('Hide Alliance 1 (members 7-12)', party1) then
            h.party1 = party1[1];
        end

        local party2 = { h.party2 };
        if imgui.Checkbox('Hide Alliance 2 (members 13-18)', party2) then
            h.party2 = party2[1];
        end

        local target = { h.target };
        if imgui.Checkbox('Hide Target Box', target) then
            h.target = target[1];
        end
        imgui.SameLine();
        imgui.TextDisabled('(also hides the arrow above the target)');

        local castinfo = { h.castinfo };
        if imgui.Checkbox('Hide Spell/Ability Info Window', castinfo) then
            h.castinfo = castinfo[1];
        end
        imgui.SameLine();
        imgui.TextDisabled('(MP cost / recast tooltip)');
    end
end

function hidepartyConfigUI.DrawColorSettings()
    imgui.TextDisabled('No color settings for Hideparty.');
end

return hidepartyConfigUI;