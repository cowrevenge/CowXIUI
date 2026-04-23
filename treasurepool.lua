--[[
* HXUI Treasure Pool Module (simplified port from XIUI)
* Shows a floating list of current treasure pool items with countdown timers.
*
* Memory-based: reads pool state directly from Ashita's Inventory API every frame.
* No packet handlers, no lot tracking, no history — just the basics.
]]--

require('common');
local imgui = require('imgui');

local treasurepool = {};

-- ============================================
-- Constants
-- ============================================

local MAX_SLOTS = 10;
local POOL_TIMEOUT = 300;  -- 5 minutes (FFXI pool expiration)

-- ============================================
-- State
-- ============================================

local poolItems = {};       -- [slot] = { id, name, expiresAt, winningLot, winningName }
local timestampCache = {};  -- dropTime -> expiresAt (cached so timer doesn't drift)

-- ============================================
-- Helpers
-- ============================================

local function GetItemName(itemId)
    if itemId == nil or itemId == 0 or itemId == 65535 then return 'Unknown'; end
    local item = AshitaCore:GetResourceManager():GetItemById(itemId);
    if item and item.Name and item.Name[1] and item.Name[1] ~= '' then
        return item.Name[1];
    end
    return 'Unknown';
end

local function ReadFromMemory()
    local memMgr = AshitaCore:GetMemoryManager();
    if memMgr == nil then return; end
    local inv = memMgr:GetInventory();
    if inv == nil then return; end

    local now = os.time();
    local active = {};

    for slot = 0, MAX_SLOTS - 1 do
        local item = inv:GetTreasurePoolItem(slot);
        if item ~= nil and item.ItemId and item.ItemId > 0 and item.ItemId ~= 65535 then
            active[slot] = true;

            -- Cache expiration so it doesn't change each frame
            if not timestampCache[item.DropTime] then
                timestampCache[item.DropTime] = now + POOL_TIMEOUT;
            end

            poolItems[slot] = {
                id = item.ItemId,
                name = GetItemName(item.ItemId),
                expiresAt = timestampCache[item.DropTime],
                winningLot = item.WinningLot,
                winningName = item.WinningEntityName or '',
            };
        end
    end

    -- Remove slots that are no longer in memory
    for slot in pairs(poolItems) do
        if not active[slot] then
            poolItems[slot] = nil;
        end
    end
end

local function FormatTime(secs)
    return string.format('%d:%02d', math.floor(secs / 60), math.floor(secs) % 60);
end

-- ============================================
-- Module API
-- ============================================

treasurepool.Initialize = function(settings) end
treasurepool.UpdateFonts = function(settings) end
treasurepool.SetHidden   = function(hidden) end  -- No persistent fonts/primitives to hide

treasurepool.Cleanup = function()
    poolItems = {};
    timestampCache = {};
end

treasurepool.DrawWindow = function(settings)
    ReadFromMemory();

    -- Check if we have any items
    local count = 0;
    for _ in pairs(poolItems) do count = count + 1; end

    -- Preview mode: show dummy pool while config is open so user can see/drag it
    local isPreview = count == 0 and (showConfig and showConfig[1]);
    if count == 0 and not isPreview then return; end

    -- Build display list
    local sorted = {};
    if isPreview then
        local now = os.time();
        sorted = {
            { name = 'Leaping Boots (Preview)',      expiresAt = now + 240, winningLot = 655, winningName = 'You' },
            { name = 'Emperor Hairpin (Preview)',    expiresAt = now + 90,  winningLot = 0,   winningName = ''     },
            { name = 'Beak of the Jaeger (Preview)', expiresAt = now + 45,  winningLot = 512, winningName = 'Xare' },
        };
    else
        for _, item in pairs(poolItems) do
            table.insert(sorted, item);
        end
        table.sort(sorted, function(a, b) return a.expiresAt > b.expiresAt; end);
    end

    local windowFlags = bit.bor(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoBringToFrontOnFocus,
        ImGuiWindowFlags_AlwaysAutoResize
    );
    if gConfig.lockPositions and not isPreview then
        windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoMove);
    end

    -- HXUI dark-blue theme
    imgui.PushStyleColor(ImGuiCol_WindowBg, {0, 0.06, 0.16, 0.9});
    imgui.PushStyleColor(ImGuiCol_Border, {0.3, 0.3, 0.5, 0.8});
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {10, 8});
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 4);

    if imgui.Begin('HXUITreasurePool', true, windowFlags) then
        imgui.TextColored({1.0, 0.83, 0.0, 1.0}, 'Treasure Pool');
        imgui.Separator();

        local now = os.time();
        for _, item in ipairs(sorted) do
            local remaining = math.max(0, item.expiresAt - now);
            local timeStr = FormatTime(remaining);

            -- Color the time by urgency
            local color = {1, 1, 1, 1};
            if remaining < 60 then
                color = {1.0, 0.4, 0.4, 1.0};  -- red
            elseif remaining < 120 then
                color = {1.0, 0.8, 0.4, 1.0};  -- yellow
            end

            imgui.TextColored(color, timeStr);
            imgui.SameLine();
            imgui.Text(item.name);

            -- Show top lot if any
            if item.winningLot and item.winningLot > 0 then
                imgui.SameLine();
                imgui.TextColored({0.5, 1, 0.5, 1}, string.format('(%s: %d)', item.winningName ~= '' and item.winningName or '?', item.winningLot));
            end
        end
    end
    imgui.End();

    imgui.PopStyleVar(2);
    imgui.PopStyleColor(2);
end

return treasurepool;