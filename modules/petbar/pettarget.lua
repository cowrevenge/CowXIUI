--[[
* XIUI Pet Bar - Pet Target Module
* Displays information about what the pet is targeting
* Separate window that appears below the main pet bar
]]--

require('common');
require('handlers.helpers');
local imgui = require('imgui');
local gdi = require('submodules.gdifonts.include');
local windowBg = require('libs.windowbackground');
local progressbar = require('libs.progressbar');

local data = require('modules.petbar.data');

local pettarget = {};

-- ============================================
-- Text routing (see petbar display.lua for rationale).
-- The panel is an imgui window; gdifont text renders behind it. Route text
-- through imgui so it lands on top, keep the gdifont hidden.
-- ============================================
local function drawOutlinedText(x, y, text, fillColor)
    if text == nil or text == '' then return; end
    -- imgui.TextColored treats text as a printf format string; escape '%' so
    -- strings like '100%' render the percent sign instead of eating it.
    text = tostring(text):gsub('%%', '%%%%');
    local saveX, saveY = imgui.GetCursorScreenPos();
    local black = {0, 0, 0, 1};
    imgui.SetCursorScreenPos({x - 1, y - 1}); imgui.TextColored(black, text);
    imgui.SetCursorScreenPos({x + 1, y - 1}); imgui.TextColored(black, text);
    imgui.SetCursorScreenPos({x - 1, y + 1}); imgui.TextColored(black, text);
    imgui.SetCursorScreenPos({x + 1, y + 1}); imgui.TextColored(black, text);
    imgui.SetCursorScreenPos({x, y});         imgui.TextColored(fillColor, text);
    imgui.SetCursorScreenPos({saveX, saveY});
end

local function u32ToRGBA(c)
    if c == nil then return {1, 1, 1, 1}; end
    local a = bit.band(bit.rshift(c, 24), 0xFF) / 255;
    local r = bit.band(bit.rshift(c, 16), 0xFF) / 255;
    local g = bit.band(bit.rshift(c,  8), 0xFF) / 255;
    local b = bit.band(c, 0xFF) / 255;
    if a == 0 then a = 1; end
    return {r, g, b, a};
end

-- alignment: 0 = left (x is left edge), 2 = right (x is right edge).
local function petText(font, text, x, y, colorU32, height, alignment)
    if font == nil then return; end
    font:set_visible(false);
    if text == nil or text == '' then return; end
    local drawX = x;
    if alignment == 2 then
        local tw = imgui.CalcTextSize(text);
        drawX = x - (tw or 0);
    end
    drawOutlinedText(drawX, y, text, u32ToRGBA(colorU32));
end

-- ============================================
-- State Variables
-- ============================================

-- Font objects
local targetNameText = nil;
local targetHpText = nil;
local targetDistanceText = nil;
local lastTargetColor = nil;
local lastHpColor = nil;
local lastDistanceColor = nil;

-- Background primitives (using windowbackground library)
local backgroundPrim = nil;
local loadedBgName = nil;

-- ============================================
-- Background Helpers
-- ============================================

local function HideBackground()
    if backgroundPrim then
        windowBg.hide(backgroundPrim);
    end
end

local function UpdateBackground(x, y, width, height, settings)
    if not backgroundPrim then return; end

    -- Get scale from active pet type settings (same pattern as petbar data.lua)
    local petTypeKey = data.GetPetTypeKey();
    local settingsKey = 'petBar' .. petTypeKey:gsub("^%l", string.upper);  -- 'petBarAvatar', etc.
    local typeSettings = gConfig[settingsKey] or {};
    local bgScale = typeSettings.bgScale or 1.0;
    local borderScale = typeSettings.borderScale or 1.0;

    local bgTheme = gConfig.petTargetBackgroundTheme or gConfig.petBarBackgroundTheme or 'Window1';
    local bgOpacity = gConfig.petTargetBackgroundOpacity or gConfig.petBarBackgroundOpacity or 1.0;
    local bgColor = gConfig.colorCustomization and gConfig.colorCustomization.petTarget and gConfig.colorCustomization.petTarget.bgColor or 0xFFFFFFFF;
    local borderColor = gConfig.colorCustomization and gConfig.colorCustomization.petTarget and gConfig.colorCustomization.petTarget.borderColor or 0xFFFFFFFF;
    local borderOpacity = gConfig.petTargetBorderOpacity or gConfig.petBarBorderOpacity or 1.0;

    -- Common options for windowbackground library
    local bgOptions = {
        theme = bgTheme,
        padding = 0,    -- match Plain size; theme only changes fill
        paddingY = 0,
        bgScale = bgScale,
        borderScale = borderScale,
        bgOpacity = bgOpacity,
        bgColor = bgColor,
        borderSize = (settings and settings.borderSize) or 21,
        bgOffset = (settings and settings.bgOffset) or 1,
        borderOpacity = borderOpacity,
        borderColor = borderColor,
    };

    -- Update background and borders using windowbackground library
    windowBg.update(backgroundPrim, x, y, width, height, bgOptions);
end

-- ============================================
-- DrawWindow
-- ============================================
function pettarget.DrawWindow(settings)
    -- Only show if pet target tracking is enabled and we have a target
    if gConfig.petBarShowTarget == false or data.petTargetServerId == nil then
        if targetNameText then
            targetNameText:set_visible(false);
        end
        if targetHpText then
            targetHpText:set_visible(false);
        end
        if targetDistanceText then
            targetDistanceText:set_visible(false);
        end
        HideBackground();
        return;
    end

    -- Check if pet is targeting itself (e.g., after self-buff like Aerial Armor)
    local petEntity = data.GetPetEntity();
    if petEntity and petEntity.ServerId and data.petTargetServerId == petEntity.ServerId then
        if targetNameText then
            targetNameText:set_visible(false);
        end
        if targetHpText then
            targetHpText:set_visible(false);
        end
        if targetDistanceText then
            targetDistanceText:set_visible(false);
        end
        HideBackground();
        return;
    end

    local targetEnt = data.GetEntityByServerId(data.petTargetServerId);
    if targetEnt == nil or targetEnt.ActorPointer == 0 or targetEnt.HPPercent <= 0 then
        if targetNameText then
            targetNameText:set_visible(false);
        end
        if targetHpText then
            targetHpText:set_visible(false);
        end
        if targetDistanceText then
            targetDistanceText:set_visible(false);
        end
        HideBackground();
        data.petTargetServerId = nil;
        return;
    end

    -- Use cached values from main pet bar
    local windowFlags = data.lastWindowFlags or data.getBaseWindowFlags();
    local petBarColorConfig = data.lastColorConfig or {};
    local totalRowWidth = data.lastTotalRowWidth or 150;

    -- Get pet target specific color config
    local colorConfig = gConfig.colorCustomization and gConfig.colorCustomization.petTarget or {};

    -- Handle snap to petbar positioning
    local snapEnabled = gConfig.petTargetSnapToPetBar;
    if snapEnabled and data.lastMainWindowPosX and data.lastMainWindowBottom then
        local snapOffsetX = gConfig.petTargetSnapOffsetX or 0;
        local snapOffsetY = gConfig.petTargetSnapOffsetY or 4;
        local snapX = data.lastMainWindowPosX + snapOffsetX;
        local snapY = data.lastMainWindowBottom + snapOffsetY;
        imgui.SetNextWindowPos({snapX, snapY}, ImGuiCond_Always);
    end

    if gConfig.lockPositions or snapEnabled then
        windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoMove);
    end

    -- Plain theme = clean imgui-drawn panel. All other themes use the windowBg
    -- textured prim. Pushes are unconditional — NoBackground (inherited from
    -- the main pet bar) controls whether imgui draws the WindowBg/Border.
    local bgTheme = gConfig.petTargetBackgroundTheme or gConfig.petBarBackgroundTheme or 'Window1';
    local plainBg = bgTheme == 'Plain';
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0, 0.06, 0.16, 0.9 });
    imgui.PushStyleColor(ImGuiCol_Border, { 0.3, 0.3, 0.5, 0.8 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 4);
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1);

    if imgui.Begin('PetBarTarget', true, windowFlags) then
        local targetWinPosX, targetWinPosY = imgui.GetWindowPos();
        local targetStartX, targetStartY = imgui.GetCursorScreenPos();

        local targetName = targetEnt.Name or 'Unknown';
        local targetHp = targetEnt.HPPercent;
        local targetDistance = math.sqrt(targetEnt.Distance or 0);
        local targetIndex = targetEnt.TargetIndex or 0;

        local targetFontSize = gConfig.petBarTargetFontSize or gConfig.petBarVitalsFontSize or settings.vitals_font_settings.font_height;
        local vitalsFontSize = gConfig.petBarVitalsFontSize or settings.vitals_font_settings.font_height;
        local distanceFontSize = gConfig.petBarDistanceFontSize or settings.distance_font_settings.font_height;

        -- Bar dimensions with scale settings
        local barScaleX = gConfig.petTargetBarScaleX or 1.0;
        local barScaleY = gConfig.petTargetBarScaleY or 1.0;
        local barWidth = totalRowWidth * barScaleX;
        local barHeight = (settings.barHeight or 12) * barScaleY;

        -- Get positioning settings
        local nameAbsolute = gConfig.petTargetNameAbsolute;
        local nameOffsetX = gConfig.petTargetNameOffsetX or 0;
        local nameOffsetY = gConfig.petTargetNameOffsetY or 0;
        local hpAbsolute = gConfig.petTargetHpAbsolute;
        local hpOffsetX = gConfig.petTargetHpOffsetX or 0;
        local hpOffsetY = gConfig.petTargetHpOffsetY or 0;
        local distanceAbsolute = gConfig.petTargetDistanceAbsolute;
        local distanceOffsetX = gConfig.petTargetDistanceOffsetX or 0;
        local distanceOffsetY = gConfig.petTargetDistanceOffsetY or 0;

        -- Row 1: Target Name (left)
        local nameX, nameY;
        if nameAbsolute then
            nameX = targetWinPosX + nameOffsetX;
            nameY = targetWinPosY + nameOffsetY;
        else
            nameX = targetStartX + nameOffsetX;
            nameY = targetStartY + nameOffsetY;
        end
        local targetColor = colorConfig.targetTextColor or petBarColorConfig.targetTextColor or 0xFFFFFFFF;
        petText(targetNameText, targetName, nameX, nameY, targetColor, targetFontSize, 0);

        -- HP% text (right-aligned by default)
        local hpX, hpY;
        if hpAbsolute then
            hpX = targetWinPosX + hpOffsetX;
            hpY = targetWinPosY + hpOffsetY;
        else
            hpX = targetStartX + barWidth + hpOffsetX;
            hpY = targetStartY + (targetFontSize - vitalsFontSize) / 2 + hpOffsetY;
        end
        local hpColor = colorConfig.hpTextColor or petBarColorConfig.hpTextColor or 0xFFFFA7A7;
        petText(targetHpText, tostring(targetHp) .. '%', hpX, hpY, hpColor, vitalsFontSize, 2);

        -- Only add space for name row if name or HP are inline (not absolute)
        if not nameAbsolute or not hpAbsolute then
            imgui.Dummy({barWidth, targetFontSize + 4});
        end

        -- Row 2: HP Bar with interpolation
        local currentTime = os.clock();
        local hpGradient = GetCustomGradient(colorConfig, 'hpGradient') or {'#e26c6c', '#fb9494'};
        local hpPercentData = HpInterpolation.update('pettarget', targetHp, targetIndex, settings, currentTime, hpGradient);

        progressbar.ProgressBar(hpPercentData, {barWidth, barHeight}, {decorate = gConfig.petTargetShowBookends or gConfig.petBarShowBookends});

        -- Distance text positioning
        local distX, distY;
        if distanceAbsolute then
            distX = targetWinPosX + distanceOffsetX;
            distY = targetWinPosY + distanceOffsetY;
        else
            local distanceY = targetStartY + targetFontSize + 4 + barHeight + 2;
            distX = targetStartX + distanceOffsetX;
            distY = distanceY + distanceOffsetY;
            -- Add dummy for inline layout
            imgui.Dummy({totalRowWidth, distanceFontSize + 2});
        end
        local distanceColor = colorConfig.distanceTextColor or petBarColorConfig.distanceTextColor or 0xFFFFFFFF;
        petText(targetDistanceText, string.format('%.1f', targetDistance), distX, distY, distanceColor, distanceFontSize, 0);

        -- Update background
        local targetWinWidth, targetWinHeight = imgui.GetWindowSize();
        if plainBg then
            HideBackground();
        else
            UpdateBackground(targetWinPosX, targetWinPosY, targetWinWidth, targetWinHeight, settings);
        end

        -- Silver highlight lines on the top & bottom edges of the panel.
        -- Always drawn regardless of background mode (decoration, not background fill).
        -- Uses the foreground draw list so imgui's own Border can't paint over it.
        do
            local silver = imgui.GetColorU32({ 0.75, 0.78, 0.85, 0.95 });
            local fg = imgui.GetForegroundDrawList();
            fg:AddLine({ targetWinPosX + 3, targetWinPosY + 1 }, { targetWinPosX + targetWinWidth - 3, targetWinPosY + 1 }, silver, 1.0);
            fg:AddLine({ targetWinPosX + 3, targetWinPosY + targetWinHeight - 1 }, { targetWinPosX + targetWinWidth - 3, targetWinPosY + targetWinHeight - 1 }, silver, 1.0);
        end
    end
    imgui.End();

    imgui.PopStyleVar(2);    -- WindowRounding, WindowBorderSize
    imgui.PopStyleColor(2);  -- WindowBg, Border
end

-- ============================================
-- Initialize
-- ============================================
function pettarget.Initialize(settings)
    -- Create fonts
    targetNameText = FontManager.create(settings.vitals_font_settings);

    targetHpText = FontManager.create(settings.vitals_font_settings);
    targetHpText:set_font_alignment(gdi.Alignment.Right);

    targetDistanceText = FontManager.create(settings.distance_font_settings);

    -- Initialize background primitives using windowbackground library
    local prim_data = settings.prim_data or {
        visible = false,
        can_focus = false,
        locked = true,
        width = 100,
        height = 100,
    };

    -- Load background textures (use petTarget theme if set, otherwise petBar theme)
    local backgroundName = gConfig.petTargetBackgroundTheme or gConfig.petBarBackgroundTheme or 'Window1';
    loadedBgName = backgroundName;

    -- Get scale from active pet type settings
    local petTypeKey = data.GetPetTypeKey();
    local settingsKey = 'petBar' .. petTypeKey:gsub("^%l", string.upper);
    local typeSettings = gConfig[settingsKey] or {};
    local bgScale = typeSettings.bgScale or 1.0;
    local borderScale = typeSettings.borderScale or 1.0;

    -- Create combined background + borders (no middle layer needed for pettarget)
    backgroundPrim = windowBg.create(prim_data, backgroundName, bgScale, borderScale);
end

-- ============================================
-- UpdateVisuals
-- ============================================
function pettarget.UpdateVisuals(settings)
    -- Recreate fonts
    targetNameText = FontManager.recreate(targetNameText, settings.vitals_font_settings);

    targetHpText = FontManager.recreate(targetHpText, settings.vitals_font_settings);
    targetHpText:set_font_alignment(gdi.Alignment.Right);

    targetDistanceText = FontManager.recreate(targetDistanceText, settings.distance_font_settings);

    -- Clear cached colors
    lastTargetColor = nil;
    lastHpColor = nil;
    lastDistanceColor = nil;

    -- Get scale from active pet type settings
    local petTypeKey = data.GetPetTypeKey();
    local settingsKey = 'petBar' .. petTypeKey:gsub("^%l", string.upper);
    local typeSettings = gConfig[settingsKey] or {};
    local bgScale = typeSettings.bgScale or 1.0;
    local borderScale = typeSettings.borderScale or 1.0;

    -- Update background textures if theme changed (use petTarget theme if set, otherwise petBar theme)
    local backgroundName = gConfig.petTargetBackgroundTheme or gConfig.petBarBackgroundTheme or 'Window1';
    if loadedBgName ~= backgroundName then
        loadedBgName = backgroundName;
        windowBg.setTheme(backgroundPrim, backgroundName, bgScale, borderScale);
    end
end

-- ============================================
-- SetHidden
-- ============================================
function pettarget.SetHidden(hidden)
    if hidden then
        if targetNameText then
            targetNameText:set_visible(false);
        end
        if targetHpText then
            targetHpText:set_visible(false);
        end
        if targetDistanceText then
            targetDistanceText:set_visible(false);
        end
        HideBackground();
    end
end

-- ============================================
-- Cleanup
-- ============================================
function pettarget.Cleanup()
    targetNameText = FontManager.destroy(targetNameText);
    targetHpText = FontManager.destroy(targetHpText);
    targetDistanceText = FontManager.destroy(targetDistanceText);
    lastTargetColor = nil;
    lastHpColor = nil;
    lastDistanceColor = nil;

    -- Cleanup background primitives using windowbackground library
    if backgroundPrim then
        windowBg.destroy(backgroundPrim);
        backgroundPrim = nil;
    end
end

-- DEBUG BUILD: error trap — prints one chat line with file:line on error
-- instead of silently killing the frame. Remove once root cause found.
local _dbgSeen = {};
local function _dbgwrap(name, fn)
    if type(fn) ~= 'function' then return fn; end
    return function(...)
        local ok, a, b, c, d = pcall(fn, ...);
        if ok then return a, b, c, d; end
        local msg = '[XIUI DEBUG] pettarget.' .. name .. ' ERROR: ' .. tostring(a);
        if not _dbgSeen[msg] then
            _dbgSeen[msg] = true;
            print(msg);
        end
    end
end
pettarget.DrawWindow = _dbgwrap('DrawWindow', pettarget.DrawWindow);

return pettarget;