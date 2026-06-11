--[[
* XIUI Cast Cost Display Layer
* Handles rendering of cast cost information with GDI fonts and window backgrounds
]]--

require('common');
require('handlers.helpers');
local imgui = require('imgui');
local gdi = require('submodules.gdifonts.include');
local windowBg = require('libs.windowbackground');
local progressbar = require('libs.progressbar');
local shared = require('modules.castcost.shared');

local M = {};

-- Font handles
local nameFont;
local costFont;
local timeFont;
local recastFont;    -- Right-aligned for timer on cooldown bar
local cooldownFont;  -- Left-aligned for "Next: ready" text
local allFonts;

-- Background handle
local bgHandle;

-- Cached colors (avoid expensive set_font_color calls)
local lastNameColor;
local lastCostColor;
local lastTimeColor;
local lastRecastColor;
local lastCooldownColor;

-- Reference text heights for baseline alignment (prevents text jumping with descenders)
-- Using strings with descender characters (y, g, j, p, q) to get maximum line height
local nameRefHeight = 0;
local costRefHeight = 0;
local timeRefHeight = 0;
local recastRefHeight = 0;
local cooldownRefHeight = 0;
local lastNameFontHeight = 0;
local lastCostFontHeight = 0;
local lastTimeFontHeight = 0;
local lastRecastFontHeight = 0;
local lastCooldownFontHeight = 0;

-- Window state for bottom alignment
local windowState = {
    x = nil,
    y = nil,
    height = nil,
};

-- Position saving state
local hasAppliedSavedPosition = false;
local lastSavedPosX = nil;
local lastSavedPosY = nil;

-- ============================================
-- Initialization
-- ============================================

function M.Initialize(settings)
    -- Create fonts via FontManager
    nameFont = FontManager.create(settings.name_font_settings);
    costFont = FontManager.create(settings.cost_font_settings);
    timeFont = FontManager.create(settings.time_font_settings);
    recastFont = FontManager.create(settings.recast_font_settings);
    cooldownFont = FontManager.create(settings.cooldown_font_settings);
    allFonts = { nameFont, costFont, timeFont, recastFont, cooldownFont };

    -- Create window background (read scale directly from gConfig like partylist does)
    local cc = gConfig.castCost or {};
    bgHandle = windowBg.create(settings.prim_data, cc.backgroundTheme or 'Window1', cc.bgScale or 1.0, cc.borderScale or 1.0);
end

-- ============================================
-- Update Visuals (font/theme changes)
-- ============================================

function M.UpdateVisuals(settings)
    -- Recreate fonts when family/weight changes
    nameFont = FontManager.recreate(nameFont, settings.name_font_settings);
    costFont = FontManager.recreate(costFont, settings.cost_font_settings);
    timeFont = FontManager.recreate(timeFont, settings.time_font_settings);
    recastFont = FontManager.recreate(recastFont, settings.recast_font_settings);
    cooldownFont = FontManager.recreate(cooldownFont, settings.cooldown_font_settings);
    allFonts = { nameFont, costFont, timeFont, recastFont, cooldownFont };

    -- Reset cached colors and reference heights
    lastNameColor = nil;
    lastCostColor = nil;
    lastTimeColor = nil;
    lastRecastColor = nil;
    lastCooldownColor = nil;
    nameRefHeight = 0;
    costRefHeight = 0;
    timeRefHeight = 0;
    recastRefHeight = 0;
    cooldownRefHeight = 0;
    lastNameFontHeight = 0;
    lastCostFontHeight = 0;
    lastTimeFontHeight = 0;
    lastRecastFontHeight = 0;
    lastCooldownFontHeight = 0;

    -- Update background theme (read scale directly from gConfig like partylist does)
    local cc = gConfig.castCost or {};
    if bgHandle then
        windowBg.setTheme(bgHandle, cc.backgroundTheme or 'Window1', cc.bgScale or 1.0, cc.borderScale or 1.0);
    end
end

-- ============================================
-- Visibility Control
-- ============================================

function M.SetHidden(hidden)
    SetFontsVisible(allFonts, not hidden);
    if bgHandle then
        windowBg.hide(bgHandle);
    end
    -- Reset window state when hidden so bottom alignment starts fresh
    if hidden then
        windowState.x = nil;
        windowState.y = nil;
        windowState.height = nil;
        -- Clear shared state when hidden
        shared.Clear();
    end
end

-- ============================================
-- Cleanup
-- ============================================

function M.Cleanup()
    nameFont = FontManager.destroy(nameFont);
    costFont = FontManager.destroy(costFont);
    timeFont = FontManager.destroy(timeFont);
    recastFont = FontManager.destroy(recastFont);
    cooldownFont = FontManager.destroy(cooldownFont);
    allFonts = nil;

    if bgHandle then
        windowBg.destroy(bgHandle);
        bgHandle = nil;
    end
end

-- ============================================
-- Rendering Helpers
-- ============================================

local function formatTime(seconds)
    if seconds == nil or seconds <= 0 then return ''; end
    if seconds >= 60 then
        local mins = math.floor(seconds / 60);
        local secs = seconds % 60;
        return string.format('%dm %ds', mins, secs);
    end
    return string.format('%ds', seconds);
end

-- Format cooldown time with decimal for short durations
local function formatCooldown(seconds)
    if seconds == nil or seconds <= 0 then return ''; end
    if seconds >= 60 then
        local mins = math.floor(seconds / 60);
        local secs = math.floor(seconds % 60);
        return string.format('%d:%02d', mins, secs);
    elseif seconds >= 10 then
        return string.format('%ds', math.floor(seconds));
    else
        return string.format('%.1fs', seconds);
    end
end

-- Always-M:SS formatter for the row-2 "Next:" timer. Used by BOTH the
-- modern and gdifont paths so Ready ("Next: 0:00") and on-cooldown
-- ("Next: 1:30") rows share the same visual width.
local function formatTimerMSS(seconds)
    if seconds == nil or seconds <= 0 then return '0:00'; end
    local mins = math.floor(seconds / 60);
    local secs = math.floor(seconds % 60);
    return string.format('%d:%02d', mins, secs);
end

-- ============================================
-- Main Render Function
-- ============================================

function M.Render(itemInfo, itemType, settings, colors)
    if itemInfo == nil then
        SetFontsVisible(allFonts, false);
        if bgHandle then
            windowBg.hide(bgHandle);
        end
        -- Clear shared state when no selection
        shared.Clear();
        return;
    end

    -- Build display strings based on item type
    local nameText = '';
    if settings.showName then
        nameText = itemInfo.name or '';
    end
    local costText = '';
    local timeText = '';
    local hasEnoughMp = true; -- Track if player has enough MP for spells
    local hasEnoughTp = true; -- Track if player has enough TP for weapon skills

    -- Get player's current MP and TP for cost comparison
    local playerMp = 0;
    local playerTp = 0;
    local party = GetPartySafe();
    if party then
        playerMp = party:GetMemberMP(0) or 0;
        playerTp = party:GetMemberTP(0) or 0;
    end

    -- Update shared state for other modules (playerbar, partylist) to consume
    shared.Update(itemInfo, itemType, playerMp);

    -- Check if on cooldown (currentRecast > 0 means spell/ability is on cooldown)
    local isOnCooldown = itemInfo.currentRecast and itemInfo.currentRecast > 0;
    -- For weapon skills, also consider "not ready" if not enough TP
    local isWeaponSkill = itemInfo.isWeaponSkill;
    if isWeaponSkill then
        hasEnoughTp = playerTp >= 1000;  -- WS requires at least 1000 TP
    end
    local cooldownPercent = 0;
    local cooldownText = '';

    if itemType == 'spell' then
        -- Spell: Show MP cost, recast
        -- Always check if player has enough MP (even if not displaying cost)
        if itemInfo.mpCost and itemInfo.mpCost > 0 then
            hasEnoughMp = playerMp >= itemInfo.mpCost;
            if settings.showMpCost then
                costText = string.format('MP: %d', itemInfo.mpCost);
            end
        end
        if settings.showRecast and itemInfo.recastDelay and itemInfo.recastDelay > 0 then
            -- RecastDelay is in 1/4 seconds
            local recastSeconds = itemInfo.recastDelay / 4;
            timeText = string.format('Recast: %s', formatTime(recastSeconds));
        end
        -- Calculate cooldown progress
        if isOnCooldown and itemInfo.maxRecast and itemInfo.maxRecast > 0 then
            -- Bar fills up as cooldown progresses (0% at start, 100% when ready)
            cooldownPercent = 1 - (itemInfo.currentRecast / itemInfo.maxRecast);
            cooldownPercent = math.clamp(cooldownPercent, 0, 1);
            cooldownText = formatCooldown(itemInfo.currentRecast);
        end

    elseif itemType == 'ability' then
        -- Ability: Show TP cost for weapon skills, recast for others
        if isWeaponSkill then
            -- Weapon skill: Show TP cost
            if settings.showTpCost ~= false then
                costText = string.format('TP: %d', playerTp);
            end
        end
        if settings.showRecast and itemInfo.recastDelay and itemInfo.recastDelay > 0 then
            -- RecastDelay is in 1/4 seconds
            local recastSeconds = itemInfo.recastDelay / 4;
            timeText = string.format('Recast: %s', formatTime(recastSeconds));
        end
        -- Calculate cooldown progress
        if isOnCooldown and itemInfo.maxRecast and itemInfo.maxRecast > 0 then
            cooldownPercent = 1 - (itemInfo.currentRecast / itemInfo.maxRecast);
            cooldownPercent = math.clamp(cooldownPercent, 0, 1);
            cooldownText = formatCooldown(itemInfo.currentRecast);
        end

    elseif itemType == 'mount' then
        -- Mount: Just show name
        -- No additional info needed
    end

    -- Set up ImGui window
    local cc = gConfig.castCost or {};

    -- Anchored mode: read position from partylist display module each frame.
    -- partylist.display.GetCastCostAnchor returns { valid, x, y, width } where
    -- y is the BOTTOM edge the cast cost window should snap to.
    local anchor;
    if gConfig.partyListAnchorCastCost then
        local ok, partylistDisplay = pcall(require, 'modules.partylist.display');
        if ok and partylistDisplay and partylistDisplay.GetCastCostAnchor then
            anchor = partylistDisplay.GetCastCostAnchor(settings);
            if not anchor or not anchor.valid then anchor = nil; end
        end
    end

    -- ============================================================
    -- Modern-mode pre-computation (BEFORE imgui.Begin).
    --
    -- Why: with AlwaysAutoResize, the window's clip rect lags one frame
    -- behind the content, so absolute-positioned text on row 2 right was
    -- being clipped — the previous frame's smaller clip rect didn't cover
    -- where the new frame's "Next:" text was being placed. Forcing the
    -- window size via SetNextWindowSize (and dropping AlwaysAutoResize
    -- for modern) means the clip rect matches the content from frame 1,
    -- which is what the partylist target window does for the same reason.
    -- ============================================================
    local mD = {};  -- layout data, always built

        local function hexToImgui(hex)
            if type(hex) ~= 'number' then return {1, 1, 1, 1}; end
            local a = bit.band(bit.rshift(hex, 24), 0xFF) / 255;
            local r = bit.band(bit.rshift(hex, 16), 0xFF) / 255;
            local g = bit.band(bit.rshift(hex, 8),  0xFF) / 255;
            local b = bit.band(hex, 0xFF) / 255;
            if a == 0 then a = 1; end
            return {r, g, b, a};
        end
        mD.hexToImgui = hexToImgui;

        -- Resolve color choices.
        local isNotReady = isOnCooldown or not hasEnoughMp or not hasEnoughTp;
        mD.nameColor = isNotReady
            and hexToImgui(colors.nameOnCooldownColor or 0xFF888888)
            or  hexToImgui(colors.nameTextColor      or 0xFFFFFFFF);

        local costColorHex;
        if itemType == 'spell' and not hasEnoughMp then
            costColorHex = colors.mpNotEnoughColor or 0xFFFF6666;
        elseif isWeaponSkill and not hasEnoughTp then
            costColorHex = colors.tpNotEnoughColor or 0xFFFF6666;
        elseif isWeaponSkill then
            costColorHex = colors.tpCostTextColor or 0xFFFFCC00;
        else
            costColorHex = colors.mpCostTextColor or 0xFFD4FF97;
        end
        mD.costColor = hexToImgui(costColorHex);
        mD.timeColor = hexToImgui(colors.timeTextColor or 0xFFCCCCCC);

        -- Right-side row 2 text + color (status / timer).
        local showCooldown = settings.showCooldown ~= false;
        mD.rightR2Text  = nil;
        mD.rightR2Color = nil;
        if showCooldown then
            if isOnCooldown then
                mD.rightR2Text  = 'Next: ' .. formatTimerMSS(itemInfo.currentRecast);
                -- Hardcoded red so it always reads as "counting down" regardless of
                -- what the user has saved for cooldownTextColor.
                mD.rightR2Color = hexToImgui(0xFFFF4444);
            elseif isWeaponSkill and not hasEnoughTp then
                mD.rightR2Text  = 'Need TP';
                mD.rightR2Color = hexToImgui(colors.tpNotEnoughColor or 0xFFFF6666);
            elseif itemType == 'spell' and not hasEnoughMp then
                mD.rightR2Text  = 'Need MP';
                mD.rightR2Color = hexToImgui(colors.mpNotEnoughColor or 0xFFFF6666);
            else
                mD.rightR2Text  = 'Next: 0:00';
                mD.rightR2Color = hexToImgui(colors.readyTextColor or 0xFF44CC44);
            end
        end

        -- Text widths via CalcTextSize (works outside Begin/End — only
        -- requires an active imgui frame, which we are in).
        mD.nameW    = (nameText ~= '')         and imgui.CalcTextSize(nameText)        or 0;
        mD.costW    = (costText ~= '')         and imgui.CalcTextSize(costText)        or 0;
        mD.timeW    = (timeText ~= '')         and imgui.CalcTextSize(timeText)        or 0;
        mD.rightR2W = (mD.rightR2Text ~= nil)  and imgui.CalcTextSize(mD.rightR2Text)  or 0;

        local horizGap = 12;
        local row1NeedsW = mD.nameW;
        if mD.costW > 0 then row1NeedsW = row1NeedsW + horizGap + mD.costW; end
        local row2NeedsW = mD.timeW;
        if mD.rightR2W > 0 then
            if mD.timeW > 0 then row2NeedsW = row2NeedsW + horizGap; end
            row2NeedsW = row2NeedsW + mD.rightR2W;
        end

        -- forcedContentW: when anchored, match the panel width minus the
        -- modern WindowPadding (10 each side).
        local forcedContentW = anchor and (anchor.width - 20) or nil;
        mD.contentW = forcedContentW or math.max(row1NeedsW, row2NeedsW, settings.minWidth or 100);

        local _, lineH = imgui.CalcTextSize('A');
        mD.lineSpacing = 2;
        mD.row1Height  = lineH;
        mD.row2Height  = lineH;
        mD.hasRow1     = (nameText ~= '' or mD.costW > 0);
        mD.hasRow2     = (timeText ~= '' or mD.rightR2Text ~= nil);

        local totalH = 0;
        if mD.hasRow1 then totalH = mD.row1Height; end
        if mD.hasRow2 then
            if mD.hasRow1 then totalH = totalH + mD.lineSpacing; end
            totalH = totalH + mD.row2Height;
        end
        mD.totalH   = totalH;
        mD.windowW  = mD.contentW + 20;  -- 2 * WindowPadding.x
        mD.windowH  = totalH      + 12;  -- 2 * WindowPadding.y

    -- Window position
    if anchor then
        local h = (mD and mD.windowH) or (windowState and windowState.height) or 100;
        imgui.SetNextWindowPos({anchor.x, anchor.y - h}, ImGuiCond_Always);
    elseif not hasAppliedSavedPosition and cc.windowPosX ~= nil and cc.windowPosY ~= nil then
        -- Apply saved position on first render (existing behaviour).
        imgui.SetNextWindowPos({cc.windowPosX, cc.windowPosY}, ImGuiCond_Once);
        hasAppliedSavedPosition = true;
        lastSavedPosX = cc.windowPosX;
        lastSavedPosY = cc.windowPosY;
    end

    -- Window size: exact size so the clip rect is correct from frame 1.
    imgui.SetNextWindowSize({ mD.windowW, mD.windowH }, ImGuiCond_Always);

    local windowFlags = bit.bor(
        ImGuiWindowFlags_NoDecoration,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoBringToFrontOnFocus,
        ImGuiWindowFlags_NoDocking
    );
    if gConfig.lockPositions or anchor then
        windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoMove);
    end

    -- Dark-blue rounded panel matching the party list.
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0, 0.06, 0.16, 0.9 });
    imgui.PushStyleColor(ImGuiCol_Border,   { 0.3, 0.3, 0.5, 0.8 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding,  { 10, 6 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 4);

    if imgui.Begin('CastCost', true, windowFlags) then
        local cursorX, cursorY = imgui.GetCursorScreenPos();

            -- ====================================================
            -- ====================================================
            -- Modern rendering path: imgui-only.
            -- All layout/colour decisions were made in `mD` BEFORE Begin
            -- so SetNextWindowSize could force the window to its final
            -- size for this frame. Now the window's clip rect is correct
            -- from frame 1 and SetCursorScreenPos+TextColored renders
            -- without clipping (no AlwaysAutoResize lag).
            --
            -- Layout:
            --   Row 1: Name (left)            MP/TP cost (right)
            --   Row 2: Recast: 5s (left)      Next: 0:00 / Need MP/TP (right)
            -- ====================================================
            SetFontsVisible(allFonts, false);
            if bgHandle then windowBg.hide(bgHandle); end

            local originX, originY = imgui.GetCursorScreenPos();
            local row1Y = originY;
            local row2Y = originY + mD.row1Height + mD.lineSpacing;

            local function drawAt(x, y, color, text)
                imgui.SetCursorScreenPos({ x, y });
                imgui.TextColored(color, text);
            end

            -- Row 1: name (left) + cost (right)
            if nameText ~= '' then
                drawAt(originX, row1Y, mD.nameColor, nameText);
            end
            if mD.costW > 0 then
                drawAt(originX + mD.contentW - mD.costW, row1Y, mD.costColor, costText);
            end

            -- Row 2: recast (left) + Next/Need (right)
            if timeText ~= '' then
                drawAt(originX, row2Y, mD.timeColor, timeText);
            end
            if mD.rightR2Text ~= nil then
                drawAt(originX + mD.contentW - mD.rightR2W, row2Y, mD.rightR2Color, mD.rightR2Text);
            end

            -- Silver highlight lines on the top & bottom edges of the modern
            -- panel, matching the party target box. Drawn on the FOREGROUND draw
            -- list so they sit above the imgui WindowBg. Uses the window rect.
            do
                local wpx, wpy = imgui.GetWindowPos();
                local wsx = mD.windowW;
                local wsy = mD.windowH;
                local silver = imgui.GetColorU32({ 0.75, 0.78, 0.85, 0.85 });
                local fg = imgui.GetForegroundDrawList();
                -- Top and bottom silver edges. Inset a few px horizontally to
                -- clear the rounded corners, and pull the BOTTOM line up 2px so
                -- it isn't clipped by the window's bottom border/rounding.
                fg:AddLine({ wpx + 4, wpy + 2 }, { wpx + wsx - 4, wpy + 2 }, silver, 1.0);
                fg:AddLine({ wpx + 4, wpy + wsy - 3 }, { wpx + wsx - 4, wpy + wsy - 3 }, silver, 1.0);
            end

        -- Anchored mode: snap window so its BOTTOM edge sits at anchor.y.
        -- Window size is auto-resized after content; we measure here and
        -- correct the position.
        if anchor then
            local winPosX, _ = imgui.GetWindowPos();
            local _, totalH  = imgui.GetWindowSize();
            local newPosY    = anchor.y - totalH;
            imgui.SetWindowPos('CastCost', { anchor.x, newPosY });
            -- Cache the height so the next frame's initial-position guess
            -- doesn't overshoot.
            windowState.x = anchor.x;
            windowState.y = newPosY;
            windowState.height = totalH;
        elseif settings.alignBottom then
            -- Handle bottom alignment (only when not anchored — anchor mode
            -- already manages the bottom edge).
            local winPosX, winPosY = imgui.GetWindowPos();
            local _, totalHeight   = imgui.GetWindowSize();

            if windowState.height ~= nil and windowState.height ~= totalHeight then
                -- Height changed, adjust Y to keep bottom edge fixed
                local newPosY = windowState.y + windowState.height - totalHeight;
                imgui.SetWindowPos('CastCost', { winPosX, newPosY });
                winPosY = newPosY;
            end

            -- Save current state
            windowState.x = winPosX;
            windowState.y = winPosY;
            windowState.height = totalHeight;
        end

        -- Save position when user moves window (check on mouse release).
        -- Skipped while anchored — the anchor owns the position.
        if not anchor and not gConfig.lockPositions then
            local winPosX, winPosY = imgui.GetWindowPos();
            -- Only save if position changed significantly (avoid floating point noise)
            local posChanged = (lastSavedPosX == nil or lastSavedPosY == nil) or
                               (math.abs(winPosX - lastSavedPosX) > 1) or
                               (math.abs(winPosY - lastSavedPosY) > 1);
            if posChanged and not imgui.IsMouseDown(0) then
                -- Mouse released and position changed - save to settings
                local cc = gConfig.castCost or {};
                cc.windowPosX = winPosX;
                cc.windowPosY = winPosY;
                gConfig.castCost = cc;
                lastSavedPosX = winPosX;
                lastSavedPosY = winPosY;
                if SaveSettingsToDisk then
                    SaveSettingsToDisk();
                end
            end
        end
    end
    imgui.End();

    -- Pair pops for the panel style push above.
    imgui.PopStyleVar(2);   -- WindowPadding, WindowRounding
    imgui.PopStyleColor(2); -- WindowBg, Border
end

return M;