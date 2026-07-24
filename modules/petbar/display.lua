--[[
* XIUI Pet Bar - Display Module
* Handles rendering of the main pet bar window
]]--

require('common');
require('handlers.helpers');
local imgui = require('imgui');
local ffi = require('ffi');
local progressbar = require('libs.progressbar');
local modulefont = require('libs.modulefont');

local data = require('modules.petbar.data');
local color = require('libs.color');

local display = {};

-- ============================================================================
-- Text routing.
-- The pet bar panel is an imgui window. gdifont text renders in a separate d3d
-- pass BEHIND imgui, so it would get covered by the panel. We draw the text via
-- imgui (drawOutlinedText) so it lands on the imgui layer (on top of the
-- panel/bars), and keep the gdifont primitive hidden.
-- ============================================================================

-- 1px black 4-direction outline, drawn via imgui so it's on the imgui layer.
-- Font height for this frame's text, set in the draw entry point.
local petFontHeight = nil;

-- Routed through libs/modulefont (which wraps libs/imtext) so the pet bar's
-- Text Size slider and font settings apply. The previous implementation drew
-- five imgui.TextColored passes to fake an outline, which meant the text was
-- locked to imgui's built-in font at its default size -- imtext draws the
-- outline itself at the requested size.
--
-- No '%' escaping needed any more: that was only required because
-- TextColored treats its argument as a printf format string.
local function drawOutlinedText(x, y, text, fillColor, size)
    if text == nil or text == '' then return; end
    local dl = imgui.GetForegroundDrawList();
    modulefont.DrawText(dl, x, y, text, fillColor, size or petFontHeight);
end

-- Convert a U32 ARGB color (e.g. 0xFFRRGGBB) to an imgui {r,g,b,a} float table.
local function u32ToRGBA(c)
    if c == nil then return {1, 1, 1, 1}; end
    local a = bit.band(bit.rshift(c, 24), 0xFF) / 255;
    local r = bit.band(bit.rshift(c, 16), 0xFF) / 255;
    local g = bit.band(bit.rshift(c,  8), 0xFF) / 255;
    local b = bit.band(c, 0xFF) / 255;
    if a == 0 then a = 1; end  -- treat missing alpha as opaque
    return {r, g, b, a};
end

-- Unified text draw: route through imgui (on top of the panel), keep the
-- gdifont hidden.
-- alignment: 0 = left (x is left edge), 2 = right (x is right edge).
local function petText(font, text, x, y, colorU32, height, alignment)
    if font == nil then return; end
    font:set_visible(false);
    if text == nil or text == '' then return; end
    local drawX = x;
    if alignment == 2 then
        local tw = modulefont.Measure(text, height or petFontHeight);
        drawX = x - (tw or 0);
    end
    drawOutlinedText(drawX, y, text, u32ToRGBA(colorU32), height);
end

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
-- Per-Pet-Type Settings Helpers
-- ============================================

-- Get the current pet type settings (e.g., gConfig.petBarAvatar)
local function GetPetTypeSettings()
    local petTypeKey = data.GetPetTypeKey();
    local settingsKey = 'petBar' .. petTypeKey:gsub("^%l", string.upper);  -- 'petBarAvatar', etc.
    return gConfig[settingsKey] or {};
end

-- Get the current pet type color config (e.g., gConfig.colorCustomization.petBarAvatar)
local function GetPetTypeColors()
    local petTypeKey = data.GetPetTypeKey();
    local settingsKey = 'petBar' .. petTypeKey:gsub("^%l", string.upper);  -- 'petBarAvatar', etc.
    if gConfig.colorCustomization and gConfig.colorCustomization[settingsKey] then
        return gConfig.colorCustomization[settingsKey];
    end
    -- Fall back to legacy petBar colors
    return gConfig.colorCustomization and gConfig.colorCustomization.petBar or {};
end

-- Helper to get a setting with fallback to per-type, then flat legacy, then default
local function GetPetBarSetting(settingName, defaultValue)
    local typeSettings = GetPetTypeSettings();
    if typeSettings[settingName] ~= nil then
        return typeSettings[settingName];
    end
    -- Fall back to legacy flat settings
    local legacyKey = 'petBar' .. settingName:gsub("^%l", string.upper);
    if gConfig[legacyKey] ~= nil then
        return gConfig[legacyKey];
    end
    return defaultValue;
end

-- ============================================
-- Get Timer Gradients Based on Individual Ability
-- ============================================
-- Each ability has its own unique gradient for better visual distinction
-- Returns: readyGradient, recastGradient (each is {start, stop} hex strings)
local function GetTimerGradients(abilityName, colorConfig)
    local name = abilityName or '';
    local cc = colorConfig or {};

    -- Default gradients
    local defaultReadyGradient = {'#aaaaaae6', '#cccccce6'};
    local defaultRecastGradient = {'#ccccccd9', '#ddddddd9'};

    -- Helper to get gradient as table
    local function getGradient(gradient, default)
        if gradient and gradient.start and gradient.stop then
            return {gradient.start, gradient.stop};
        end
        return default;
    end

    -- Pet duration timers (jug / charm) — colored like their indicators.
    if name == 'Jug Left' then
        return getGradient(cc.jugTimerGradient, {'#9abb5ae6', '#bfe07de6'}),
               getGradient(cc.jugTimerGradient, {'#9abb5ad9', '#bfe07dd9'});
    elseif name == 'Charmed' then
        return getGradient(cc.charmTimerGradient, {'#ff6699e6', '#ff99bbe6'}),
               getGradient(cc.charmTimerGradient, {'#ff6699d9', '#ff99bbd9'});
    end

    -- SMN abilities
    if name:find('Blood Pact') then
        if name:find('Rage') then
            return getGradient(cc.timerBPRageReadyGradient, {'#ff3333e6', '#ff6666e6'}),
                   getGradient(cc.timerBPRageRecastGradient, {'#ff6666d9', '#ff9999d9'});
        elseif name:find('Ward') then
            return getGradient(cc.timerBPWardReadyGradient, {'#00cccce6', '#66dddde6'}),
                   getGradient(cc.timerBPWardRecastGradient, {'#66ddddd9', '#99eeeed9'});
        end
        return getGradient(cc.timerBPRageReadyGradient, {'#ff3333e6', '#ff6666e6'}),
               getGradient(cc.timerBPRageRecastGradient, {'#ff6666d9', '#ff9999d9'});
    end
    if name == 'Apogee' then
        return getGradient(cc.timerApogeeReadyGradient, {'#ffcc00e6', '#ffdd66e6'}),
               getGradient(cc.timerApogeeRecastGradient, {'#ffdd66d9', '#ffee99d9'});
    end
    if name == 'Mana Cede' then
        return getGradient(cc.timerManaCedeReadyGradient, {'#009999e6', '#66bbbbe6'}),
               getGradient(cc.timerManaCedeRecastGradient, {'#66bbbbd9', '#99ccccd9'});
    end

    -- BST abilities
    if name == 'Ready' then
        return getGradient(cc.timerReadyReadyGradient, {'#ff6600e6', '#ff9933e6'}),
               getGradient(cc.timerReadyRecastGradient, {'#ff9933d9', '#ffbb66d9'});
    end
    if name == 'Reward' then
        return getGradient(cc.timerRewardReadyGradient, {'#00cc66e6', '#66dd99e6'}),
               getGradient(cc.timerRewardRecastGradient, {'#66dd99d9', '#99eebbd9'});
    end
    if name == 'Call Beast' then
        return getGradient(cc.timerCallBeastReadyGradient, {'#3399ffe6', '#66bbffe6'}),
               getGradient(cc.timerCallBeastRecastGradient, {'#66bbffd9', '#99ccffd9'});
    end
    if name == 'Bestial Loyalty' then
        return getGradient(cc.timerBestialLoyaltyReadyGradient, {'#9966ffe6', '#bb99ffe6'}),
               getGradient(cc.timerBestialLoyaltyRecastGradient, {'#bb99ffd9', '#ccaaffd9'});
    end

    -- DRG abilities
    if name == 'Call Wyvern' then
        return getGradient(cc.timerCallWyvernReadyGradient, {'#3366ffe6', '#6699ffe6'}),
               getGradient(cc.timerCallWyvernRecastGradient, {'#6699ffd9', '#99bbffd9'});
    end
    if name == 'Spirit Link' then
        return getGradient(cc.timerSpiritLinkReadyGradient, {'#33cc33e6', '#66dd66e6'}),
               getGradient(cc.timerSpiritLinkRecastGradient, {'#66dd66d9', '#99ee99d9'});
    end
    if name == 'Deep Breathing' then
        return getGradient(cc.timerDeepBreathingReadyGradient, {'#ffff33e6', '#ffff99e6'}),
               getGradient(cc.timerDeepBreathingRecastGradient, {'#ffff99d9', '#ffffc0d9'});
    end
    if name == 'Steady Wing' then
        return getGradient(cc.timerSteadyWingReadyGradient, {'#cc66ffe6', '#dd99ffe6'}),
               getGradient(cc.timerSteadyWingRecastGradient, {'#dd99ffd9', '#eeaaffd9'});
    end

    -- PUP abilities
    if name == 'Activate' then
        return getGradient(cc.timerActivateReadyGradient, {'#3399ffe6', '#66bbffe6'}),
               getGradient(cc.timerActivateRecastGradient, {'#66bbffd9', '#99ccffd9'});
    end
    if name == 'Repair' then
        return getGradient(cc.timerRepairReadyGradient, {'#33cc66e6', '#66dd99e6'}),
               getGradient(cc.timerRepairRecastGradient, {'#66dd99d9', '#99eebbd9'});
    end
    if name == 'Deploy' then
        return getGradient(cc.timerDeployReadyGradient, {'#ff9933e6', '#ffbb66e6'}),
               getGradient(cc.timerDeployRecastGradient, {'#ffbb66d9', '#ffcc99d9'});
    end
    if name == 'Deactivate' then
        return getGradient(cc.timerDeactivateReadyGradient, {'#999999e6', '#bbbbbbe6'}),
               getGradient(cc.timerDeactivateRecastGradient, {'#bbbbbbd9', '#ccccccd9'});
    end
    if name == 'Retrieve' then
        return getGradient(cc.timerRetrieveReadyGradient, {'#66ccffe6', '#99ddffe6'}),
               getGradient(cc.timerRetrieveRecastGradient, {'#99ddffd9', '#bbeeffd9'});
    end
    if name == 'Deus Ex Automata' then
        return getGradient(cc.timerDeusExAutomataReadyGradient, {'#ffcc33e6', '#ffdd66e6'}),
               getGradient(cc.timerDeusExAutomataRecastGradient, {'#ffdd66d9', '#ffee99d9'});
    end

    -- Two-Hour abilities
    if name == 'Astral Flow' or name == 'Familiar' or name == 'Spirit Surge' or name == 'Overdrive' then
        return getGradient(cc.timer2hReadyGradient, {'#ff00ffe6', '#ff66ffe6'}),
               getGradient(cc.timer2hRecastGradient, {'#ff66ffd9', '#ff99ffd9'});
    end

    -- Fallback for unknown abilities
    return defaultReadyGradient, defaultRecastGradient;
end

-- ============================================
-- Format recast time for display
-- rawTimer is in 60ths of a second (60 units = 1 second)
-- ============================================
local function FormatRecastTime(rawTimer)
    local seconds = rawTimer / 60;
    if seconds <= 0 then
        return 'Ready';
    elseif seconds < 60 then
        return string.format('%ds', math.ceil(seconds));
    else
        local mins = math.floor(seconds / 60);
        local secs = math.ceil(seconds % 60);
        if secs == 60 then
            mins = mins + 1;
            secs = 0;
        end
        return string.format('%d:%02d', mins, secs);
    end
end

-- ============================================
-- Draw Recast - Full Display Mode
-- Shows name and recast timer with progress bar using GdiFonts
-- fontIndex: 1-based index for which font slot to use
-- ============================================
local function DrawRecastFull(drawList, x, y, timerInfo, colorConfig, fullSettings, fontIndex)
    local showName = fullSettings.showName;
    local showRecast = fullSettings.showRecast;
    local nameFontSize = fullSettings.nameFontSize or 10;
    local recastFontSize = fullSettings.recastFontSize or 10;

    -- Get font objects from data module
    local nameFont = data.recastNameFonts and data.recastNameFonts[fontIndex];
    local recastFont = data.recastTimerFonts and data.recastTimerFonts[fontIndex];

    -- Get gradients based on ability category
    local readyGradient, recastGradient = GetTimerGradients(timerInfo.name, colorConfig);
    local barGradient = timerInfo.isReady and readyGradient or recastGradient;

    -- Get text color from gradient start (convert hex to ARGB for GdiFonts)
    local textColorHex = color.GetGradientTextColor(barGradient[1]);

    -- Prepare text content
    local nameText = timerInfo.name or 'Unknown';
    local recastText = FormatRecastTime(timerInfo.timer or 0);
    -- Two-click confirm for 2hr abilities: once armed (first click), the row
    -- shows a prompt for ~5s until the confirming second click.
    if timerInfo.name and data.IsAbilityArmed and data.IsAbilityArmed(timerInfo.name) then
        nameText = 'Click again to confirm';
        recastText = '';
    end

    -- Calculate the max font size for vertical positioning
    local maxFontSize = 0;
    if showName then maxFontSize = math.max(maxFontSize, nameFontSize); end
    if showRecast then maxFontSize = math.max(maxFontSize, recastFontSize); end
    if maxFontSize == 0 then maxFontSize = 10; end

    -- Text Y position at top of row
    local textY = y;

    -- Hide fonts by default, will show if needed
    if nameFont then nameFont:set_visible(false); end
    if recastFont then recastFont:set_visible(false); end

    -- Calculate progress for bar (0 = just started cooldown, 1 = ready)
    local progress = 1.0;
    if not timerInfo.isReady and timerInfo.timer > 0 and timerInfo.maxTimer and timerInfo.maxTimer > 0 then
        progress = 1.0 - (timerInfo.timer / timerInfo.maxTimer);
        progress = math.max(0, math.min(1, progress));
    end

    -- Progress bar settings (configurable)
    local barHeight = fullSettings.barHeight or 4;
    local barWidth = fullSettings.barWidth or 150;
    local barY = textY + maxFontSize + 2;  -- Position below the text

    -- Track where text/bar should start
    local barStartX = x;

    -- Name - left-aligned at start of bar
    if showName and nameFont then
        petText(nameFont, nameText, barStartX, textY, textColorHex, nameFontSize, 0);
    end

    -- Recast timer - right-aligned at far right of progress bar
    if showRecast and recastFont then
        petText(recastFont, recastText, barStartX + barWidth, textY, textColorHex, recastFontSize, 2);
    end

    -- Draw progress bar using the progressbar library with custom drawList
    local showBookends = fullSettings.showBookends;
    if showBookends == nil then showBookends = false; end

    progressbar.ProgressBar(
        {{progress, barGradient}},
        {barWidth, barHeight},
        {
            decorate = showBookends,
            absolutePosition = {barStartX, barY},
            drawList = drawList,
        }
    )

    -- Return the bar height for layout purposes
    return barHeight;
end

-- ============================================
-- Draw Recast - Full Display Mode for Charge Abilities
-- Shows name and recast timer with 3 segmented progress bars
-- fontIndex: 1-based index for which font slot to use
-- ============================================
local function DrawRecastFullCharged(drawList, x, y, timerInfo, colorConfig, fullSettings, fontIndex)
    local showName = fullSettings.showName;
    local showRecast = fullSettings.showRecast;
    local nameFontSize = fullSettings.nameFontSize or 10;
    local recastFontSize = fullSettings.recastFontSize or 10;

    local charges = timerInfo.charges or 0;
    local maxCharges = timerInfo.maxCharges or 3;
    local nextChargeTimer = timerInfo.nextChargeTimer or 0;
    local chargeValue = timerInfo.chargeValue or 1800;  -- Default 30s per charge (in 1/60ths)

    -- Get font objects from data module
    local nameFont = data.recastNameFonts and data.recastNameFonts[fontIndex];
    local recastFont = data.recastTimerFonts and data.recastTimerFonts[fontIndex];

    -- Get gradients based on ability category
    local readyGradient, recastGradient = GetTimerGradients(timerInfo.name, colorConfig);

    -- Determine text color based on charge state
    local barGradient = (charges > 0) and readyGradient or recastGradient;

    -- Get text color from gradient start (convert hex to ARGB for GdiFonts)
    local textColorHex = color.GetGradientTextColor(barGradient[1]);

    -- Prepare text content
    local nameText = timerInfo.name or 'Unknown';
    -- For charges, show "[charges]" or timer to next charge
    local recastText;
    if charges >= maxCharges then
        recastText = string.format('[%d]', charges);
    elseif charges > 0 then
        recastText = string.format('[%d] %s', charges, FormatRecastTime(nextChargeTimer));
    else
        recastText = FormatRecastTime(nextChargeTimer);
    end

    -- Calculate the max font size for vertical positioning
    local maxFontSize = 0;
    if showName then maxFontSize = math.max(maxFontSize, nameFontSize); end
    if showRecast then maxFontSize = math.max(maxFontSize, recastFontSize); end
    if maxFontSize == 0 then maxFontSize = 10; end

    -- Text Y position at top of row
    local textY = y;

    -- Hide fonts by default, will show if needed
    if nameFont then nameFont:set_visible(false); end
    if recastFont then recastFont:set_visible(false); end

    -- Progress bar settings (configurable)
    local barHeight = fullSettings.barHeight or 4;
    local barWidth = fullSettings.barWidth or 150;
    local barY = textY + maxFontSize + 2;  -- Position below the text

    -- Track where text/bar should start
    local barStartX = x;

    -- Name - left-aligned at start of bar
    if showName and nameFont then
        petText(nameFont, nameText, barStartX, textY, textColorHex, nameFontSize, 0);
    end

    -- Recast timer - right-aligned at far right of progress bar
    if showRecast and recastFont then
        petText(recastFont, recastText, barStartX + barWidth, textY, textColorHex, recastFontSize, 2);
    end

    -- Draw 3 segmented progress bars using progressbar library
    local showBookends = fullSettings.showBookends;
    if showBookends == nil then showBookends = false; end

    local segmentGap = 3;
    local totalGapWidth = (maxCharges - 1) * segmentGap;
    local segmentWidth = (barWidth - totalGapWidth) / maxCharges;

    for i = 1, maxCharges do
        local segmentX = barStartX + (i - 1) * (segmentWidth + segmentGap);

        local segmentProgress;
        local segmentGradient;

        if i <= charges then
            -- Full charge available
            segmentProgress = 1.0;
            segmentGradient = readyGradient;
        elseif i == charges + 1 and nextChargeTimer > 0 then
            -- Recharging charge - show progress
            segmentProgress = 1.0 - (nextChargeTimer / chargeValue);
            segmentProgress = math.max(0, math.min(1, segmentProgress));
            segmentGradient = recastGradient;
        else
            -- Empty charge
            segmentProgress = 0;
            segmentGradient = recastGradient;
        end

        progressbar.ProgressBar(
            {{segmentProgress, segmentGradient}},
            {segmentWidth, barHeight},
            {
                decorate = showBookends,
                absolutePosition = {segmentX, barY},
                drawList = drawList,
            }
        );
    end

    -- Return the bar height for layout purposes
    return barHeight;
end

-- ============================================
-- DrawWindow - Main Pet Bar Rendering
-- ============================================
function display.DrawWindow(settings)
    -- Font config + size for this frame. imtext holds family/weight as
    -- module-level state shared with every other caller, so this has to be
    -- re-applied here or the pet bar inherits whatever drew last.
    modulefont.Apply(
        gConfig.petBarOverrideFont,
        gConfig.petBarFontFamily,
        gConfig.petBarFontWeight,
        gConfig.petBarFontOutlineWidth,
        settings and settings.name_font_settings);
    petFontHeight = (settings and settings.name_font_settings
        and settings.name_font_settings.font_height) or nil;

    -- Get pet data from data module (handles preview internally)
    local petData = data.GetPetData();

    if petData == nil then
        data.currentPetName = nil;
        data.SetAllFontsVisible(false);

        -- Petless: if the player is a pet job (DRG/BST/PUP), show a clickable
        -- summon row ("Call Wyvern" etc.) with a live recast instead of nothing.
        local summon = data.GetNoPetSummonInfo();
        if summon ~= nil and (gConfig.petBarShowNoPetSummon ~= false) then
            local typeSettings = GetPetTypeSettings();
            local colorConfig = GetPetTypeColors();
            -- Plain theme = clean imgui-drawn panel. All other themes use the
            -- windowBg textured prim. The theme dropdown is the only control.
            local bgTheme = typeSettings.backgroundTheme or gConfig.petBarBackgroundTheme or 'Window1';
            local plainBg = bgTheme == 'Plain';

            local windowFlags = data.getBaseWindowFlags();
            if gConfig.lockPositions and not (showConfig[1] and gConfig.petBarPreview) then
                windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoMove);
            end
            if plainBg then
                windowFlags = bit.band(windowFlags, bit.bnot(ImGuiWindowFlags_NoBackground));
            end
            data.lastWindowFlags = windowFlags;

            -- Pushed unconditionally — NoBackground (above) controls drawing.
            imgui.PushStyleColor(ImGuiCol_WindowBg, { 0, 0.06, 0.16, 0.9 });
            imgui.PushStyleColor(ImGuiCol_Border, { 0.3, 0.3, 0.5, 0.8 });
            imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 4);
            imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1);

            local recastBarWidth = typeSettings.recastFullBarWidth or gConfig.petBarRecastBarWidth or 150;
            local recastBarHeight = typeSettings.recastFullBarHeight or gConfig.petBarRecastBarHeight or 4;

            if imgui.Begin('PetBar', true, windowFlags) then
                data.HideBackground();
                local px, py = imgui.GetCursorScreenPos();
                local recastLeft = data.GetSummonRecast(summon.timerId);
                local ready = (recastLeft <= 0);
                local timerInfo = {
                    name = summon.label,
                    timer = recastLeft,
                    maxTimer = summon.maxTimer,
                    isReady = ready,
                    isChargeAbility = false,
                };
                local fullSettings = {
                    showName = true,
                    showRecast = true,
                    nameFontSize = typeSettings.recastFullNameFontSize or 10,
                    recastFontSize = typeSettings.recastFullTimerFontSize or 10,
                    alignment = 'left',
                    iconSize = data.RECAST_ICON_SIZE,
                    barWidth = recastBarWidth,
                    barHeight = recastBarHeight,
                    showBookends = (typeSettings.showBookends ~= nil) and typeSettings.showBookends or gConfig.petBarShowBookends,
                };
                local drawList = imgui.GetWindowDrawList();
                DrawRecastFull(drawList, px, py, timerInfo, colorConfig, fullSettings, 1);

                -- Reserve layout space for the row.
                local rowH = math.max(fullSettings.nameFontSize, fullSettings.recastFontSize) + 2 + recastBarHeight;
                imgui.Dummy({recastBarWidth, rowH});

                -- Click-to-summon (only when ready, menu closed).
                if ready and not (showConfig and showConfig[1]) then
                    local mX, mY = imgui.GetMousePos();
                    if imgui.IsMouseClicked(0)
                        and mX >= px and mX <= px + recastBarWidth
                        and mY >= py and mY <= py + rowH then
                        AshitaCore:GetChatManager():QueueCommand(-1, summon.cmd);
                    end
                end

                -- Silver highlight lines on the top & bottom edges of the panel.
                do
                    local sumPosX, sumPosY = imgui.GetWindowPos();
                    local sumW, sumH = imgui.GetWindowSize();
                    local silver = imgui.GetColorU32({ 0.75, 0.78, 0.85, 0.95 });
                    local sfg = imgui.GetForegroundDrawList();
                    sfg:AddLine({ sumPosX + 3, sumPosY + 1 }, { sumPosX + sumW - 3, sumPosY + 1 }, silver, 1.0);
                    sfg:AddLine({ sumPosX + 3, sumPosY + sumH - 1 }, { sumPosX + sumW - 3, sumPosY + sumH - 1 }, silver, 1.0);
                end
            end
            imgui.End();

            imgui.PopStyleVar(2);
            imgui.PopStyleColor(2);  -- WindowBg, Border

            -- Hide the unused recast font slots (DrawRecastFull only used slot 1).
            for i = 2, data.MAX_RECAST_SLOTS do
                if data.recastNameFonts and data.recastNameFonts[i] then data.recastNameFonts[i]:set_visible(false); end
                if data.recastTimerFonts and data.recastTimerFonts[i] then data.recastTimerFonts[i]:set_visible(false); end
            end

            windowState.x = nil; windowState.y = nil; windowState.height = nil;
            return false;
        end

        data.HideBackground();
        -- Reset window state when hidden so bottom alignment starts fresh
        windowState.x = nil;
        windowState.y = nil;
        windowState.height = nil;
        return false;
    end

    -- Use petData directly - no preview checks needed
    local petName = petData.name;
    local petHpPercent = petData.hpPercent;
    local petDistance = petData.distance;
    local petMpPercent = petData.mpPercent;
    local petTp = petData.tp;
    local petJob = petData.job;
    local showMp = petData.showMp;
    -- New fields
    local petLevel = petData.level;
    local isJug = petData.isJug;
    local isCharmed = petData.isCharmed;
    local jugTimeRemaining = petData.jugTimeRemaining;
    local charmTimeRemaining = petData.charmTimeRemaining;

    -- Set current pet name for background image rendering
    data.currentPetName = petName;

    local petTpPercent = math.min(petTp / 1000, 1.0);

    -- Build window flags
    -- Only allow movement when config is open and preview is enabled (like partylist)
    local windowFlags = data.getBaseWindowFlags();
    if gConfig.lockPositions and not (showConfig[1] and gConfig.petBarPreview) then
        windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoMove);
    end

    -- Get per-pet-type settings and colors (needed for theme resolution below).
    local typeSettings = GetPetTypeSettings();
    local colorConfig = GetPetTypeColors();

    -- Plain theme = clean imgui-drawn panel. All other themes use the windowBg
    -- textured prim. The theme dropdown is the only control.
    local bgTheme = typeSettings.backgroundTheme or gConfig.petBarBackgroundTheme or 'Window1';
    local plainBg = bgTheme == 'Plain';
    if plainBg then
        windowFlags = bit.band(windowFlags, bit.bnot(ImGuiWindowFlags_NoBackground));
    end

    -- Apply saved position on first render
    if not hasAppliedSavedPosition and gConfig.petBarWindowPosX ~= nil and gConfig.petBarWindowPosY ~= nil then
        imgui.SetNextWindowPos({gConfig.petBarWindowPosX, gConfig.petBarWindowPosY}, ImGuiCond_Once);
        hasAppliedSavedPosition = true;
        lastSavedPosX = gConfig.petBarWindowPosX;
        lastSavedPosY = gConfig.petBarWindowPosY;
    end

    -- Calculate dimensions (base values)
    local barWidth = settings.barWidth;
    local barHeight = settings.barHeight;
    local barSpacing = settings.barSpacing;

    -- Individual bar scales (from per-type settings with legacy fallback)
    local hpScaleX = typeSettings.hpScaleX or gConfig.petBarHpScaleX or 1.0;
    local hpScaleY = typeSettings.hpScaleY or gConfig.petBarHpScaleY or 1.0;
    local mpScaleX = typeSettings.mpScaleX or gConfig.petBarMpScaleX or 1.0;
    local mpScaleY = typeSettings.mpScaleY or gConfig.petBarMpScaleY or 1.0;
    local tpScaleX = typeSettings.tpScaleX or gConfig.petBarTpScaleX or 1.0;
    local tpScaleY = typeSettings.tpScaleY or gConfig.petBarTpScaleY or 1.0;
    local recastScaleX = typeSettings.recastScaleX or 1.0;
    local recastScaleY = typeSettings.recastScaleY or 0.5;  -- Default to half height for recast bars

    -- Calculate scaled bar dimensions
    -- HP bar is full width
    local hpBarWidth = barWidth * hpScaleX;
    local hpBarHeight = barHeight * hpScaleY;
    -- MP and TP bars split the HP bar width (minus spacing between them)
    local halfBarWidth = (hpBarWidth - barSpacing) / 2;
    local mpBarWidth = halfBarWidth * mpScaleX;
    local mpBarHeight = barHeight * mpScaleY;
    local tpBarWidth = halfBarWidth * tpScaleX;
    local tpBarHeight = barHeight * tpScaleY;
    -- Recast bars use full HP bar width by default, scaled height
    local recastBarWidth = hpBarWidth * recastScaleX;
    local recastBarHeight = barHeight * recastScaleY;

    -- Total row width for proper window sizing (based on HP bar width)
    local totalRowWidth = hpBarWidth;

    -- Store for pet target window
    data.lastTotalRowWidth = totalRowWidth;
    data.lastWindowFlags = windowFlags;
    data.lastColorConfig = colorConfig;
    data.lastSettings = settings;

    local windowPosX, windowPosY = 0, 0;
    local petBarW, petBarH = 0, 0;

    -- Panel style. Paired pops after imgui.End(). Pushed unconditionally — the
    -- NoBackground window flag (set above when the theme is not Plain) is what
    -- actually controls whether imgui draws the WindowBg/Border.
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0, 0.06, 0.16, 0.9 });
    imgui.PushStyleColor(ImGuiCol_Border, { 0.3, 0.3, 0.5, 0.8 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 4);
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1);

    if imgui.Begin('PetBar', true, windowFlags) then
        windowPosX, windowPosY = imgui.GetWindowPos();
        local startX, startY = imgui.GetCursorScreenPos();

        -- Draw the pet portrait first (on the window draw list) so it sits
        -- BEHIND the bars/text. Pass the window size (last frame's, for
        -- auto-resize) so clip-to-background works.
        petBarW, petBarH = imgui.GetWindowSize();
        local mw, mh = petBarW, petBarH;
        data.DrawPetImage(imgui.GetWindowDrawList(), windowPosX, windowPosY, mw, mh);

        -- Row 1: Pet Name (with optional level) (left) and HP% (right, same line)
        local nameFontSize = typeSettings.nameFontSize or gConfig.petBarNameFontSize or settings.name_font_settings.font_height;
        local hpFontSize = typeSettings.hpFontSize or typeSettings.vitalsFontSize or gConfig.petBarVitalsFontSize or settings.vitals_font_settings.font_height;
        local mpFontSize = typeSettings.mpFontSize or typeSettings.vitalsFontSize or gConfig.petBarVitalsFontSize or settings.vitals_font_settings.font_height;
        local tpFontSize = typeSettings.tpFontSize or typeSettings.vitalsFontSize or gConfig.petBarVitalsFontSize or settings.vitals_font_settings.font_height;

        -- Format name with level if available and enabled
        local showLevel = typeSettings.showLevel;
        if showLevel == nil then showLevel = gConfig.petBarShowLevel ~= false; end
        local displayName = petName;

        -- For jug pets, append the max level cap (e.g., "CourierCarrie (75)")
        local jugInfo = data.GetJugPetInfo(petName);
        if jugInfo then
            displayName = string.format('%s (%d)', displayName, jugInfo.maxLevel);
        end

        if petLevel and showLevel then
            displayName = string.format('Lv.%d %s', petLevel, displayName);
        end

        local nameColor = colorConfig.nameTextColor or 0xFFFFFFFF;
        petText(data.nameText, displayName, startX, startY, nameColor, nameFontSize, 0);

        -- Click on the name → toggle the jug-pet reference list.
        -- Uses a {bool} table-ref so the popup's X button (handled by imgui)
        -- can write back to the same flag.
        do
            local nameW = math.max(80, #displayName * nameFontSize * 0.55);
            local nameH = nameFontSize + 2;
            local mX, mY = imgui.GetMousePos();
            if imgui.IsMouseClicked(0)
                and mX >= startX and mX <= startX + nameW
                and mY >= startY and mY <= startY + nameH then
                if data.jugListOpen == nil then data.jugListOpen = { false }; end
                data.jugListOpen[1] = not data.jugListOpen[1];
            end
        end

        -- Distance text (anchored to top right edge of background)
        local showDistance = typeSettings.showDistance;
        if showDistance == nil then showDistance = gConfig.petBarShowDistance; end
        local pendingDistance = nil;
        if showDistance then
            local distanceFontSize = typeSettings.distanceFontSize or gConfig.petBarDistanceFontSize or settings.distance_font_settings.font_height;
            local distanceOffsetX = typeSettings.distanceOffsetX or gConfig.petBarDistanceOffsetX or 0;
            local distanceOffsetY = typeSettings.distanceOffsetY or gConfig.petBarDistanceOffsetY or 0;

            local distColor = colorConfig.distanceTextColor or 0xFFFFFFFF;
            -- imgui clips text to the window content rect, so the classic
            -- above-window Y (windowPosY-13) disappears. Defer the draw to the TP
            -- line (computed later): TP stays right-aligned, distance goes LEFT.
            pendingDistance = {
                text  = string.format('%.1f', petDistance),
                color = distColor,
                size  = distanceFontSize,
                offX  = distanceOffsetX,
                offY  = distanceOffsetY,
            };
            data.distanceText:set_visible(false);
        else
            data.distanceText:set_visible(false);
        end

        -- Per-type vitals toggles
        local showHP = typeSettings.showHP;
        if showHP == nil then showHP = gConfig.petBarShowVitals ~= false; end
        local showMP = typeSettings.showMP;
        if showMP == nil then showMP = gConfig.petBarShowVitals ~= false; end
        local showTP = typeSettings.showTP;
        if showTP == nil then showTP = gConfig.petBarShowVitals ~= false; end

        -- HP% text (right-aligned to HP bar width)
        if showHP then
            local hpColor = colorConfig.hpTextColor or 0xFFFFA7A7;
            petText(data.hpText, tostring(petHpPercent) .. '%',
                startX + hpBarWidth, startY + (nameFontSize - hpFontSize) / 2,
                hpColor, hpFontSize, 2);
        else
            data.hpText:set_visible(false);
        end

        imgui.Dummy({totalRowWidth, nameFontSize + 4});

        -- Get bookends setting (shared across all bars)
        local showBookends = typeSettings.showBookends;
        if showBookends == nil then showBookends = gConfig.petBarShowBookends; end

        -- Combine pet capability (showMp from data) with user setting (showMP from config)
        local displayMpBar = showMp and showMP;
        local displayTpBar = showTP;

        -- Track bar positions for text placement
        local barsStartX, barsStartY = imgui.GetCursorScreenPos();
        local mpBarX, mpBarY = barsStartX, barsStartY;
        local tpBarX = barsStartX;
        local textRowY = barsStartY;

        -- Row 2: HP Bar (full width) with interpolation
        if showHP then
            local hpGradient = GetCustomGradient(colorConfig, 'hpGradient') or {'#e26c6c', '#fa9c9c'};

            -- Use HP interpolation for damage/healing animations (with nil check)
            local hpPercentData;
            if HpInterpolation and HpInterpolation.update then
                local currentTime = os.clock();
                local petEntity = data.GetPetEntity();
                local petIndex = petEntity and petEntity.TargetIndex or 0;
                hpPercentData = HpInterpolation.update('petbar', petHpPercent, petIndex, settings, currentTime, hpGradient);
            else
                -- Fallback: no interpolation
                hpPercentData = {{petHpPercent / 100, hpGradient}};
            end

            progressbar.ProgressBar(
                hpPercentData,
                {hpBarWidth, hpBarHeight},
                {decorate = showBookends}
            );

            -- Update position for next row
            mpBarX, mpBarY = imgui.GetCursorScreenPos();
            tpBarX = mpBarX;
        end

        -- Row 3: MP and TP bars side by side (half width each)
        -- Calculate actual widths based on what's displayed
        local actualMpWidth = mpBarWidth;
        local actualTpWidth = tpBarWidth;
        if displayMpBar and not displayTpBar then
            -- MP bar takes full width when no TP bar
            actualMpWidth = hpBarWidth;
        elseif not displayMpBar and displayTpBar then
            -- TP bar takes full width when no MP bar
            actualTpWidth = hpBarWidth;
        end

        if displayMpBar then
            local mpGradient = GetCustomGradient(colorConfig, 'mpGradient') or {'#9abb5a', '#bfe07d'};
            progressbar.ProgressBar(
                {{petMpPercent / 100, mpGradient}},
                {actualMpWidth, mpBarHeight},
                {decorate = showBookends}
            );

            if displayTpBar then
                imgui.SameLine(0, barSpacing);
                tpBarX = imgui.GetCursorScreenPos();
            end
        end

        if displayTpBar then
            local tpGradient = GetCustomGradient(colorConfig, 'tpGradient') or {'#3898ce', '#78c4ee'};
            progressbar.ProgressBar(
                {{petTpPercent, tpGradient}},
                {actualTpWidth, tpBarHeight},
                {decorate = showBookends}
            );
        end

        -- Calculate text Y positions based on respective bar heights
        -- When both bars are shown, use max height for consistent text alignment
        -- When only one bar is shown, use that bar's height
        local mpTextRowY = mpBarY;
        local tpTextRowY = mpBarY;
        if displayMpBar and displayTpBar then
            -- Both bars shown - align text at the same level using max height
            local maxBarHeight = math.max(mpBarHeight, tpBarHeight);
            mpTextRowY = mpBarY + maxBarHeight + 2;
            tpTextRowY = mpBarY + maxBarHeight + 2;
        elseif displayMpBar then
            -- Only MP bar shown
            mpTextRowY = mpBarY + mpBarHeight + 2;
        elseif displayTpBar then
            -- Only TP bar shown
            tpTextRowY = mpBarY + tpBarHeight + 2;
        end

        -- MP text (independent of TP bar visibility)
        if displayMpBar then
            local mpColor = colorConfig.mpTextColor or 0xFFFFFFFF;
            petText(data.mpText, tostring(petMpPercent) .. '%',
                mpBarX + actualMpWidth, mpTextRowY, mpColor, mpFontSize, 2);
        else
            data.mpText:set_visible(false);
        end

        -- TP text (independent of MP bar visibility)
        if displayTpBar then
            local tpColor = colorConfig.tpTextColor or 0xFFFFFFFF;
            petText(data.tpText, tostring(petTp),
                tpBarX + actualTpWidth, tpTextRowY, tpColor, tpFontSize, 2);
        else
            data.tpText:set_visible(false);
        end

        -- Distance: on the TP line, LEFT-aligned at the TP bar's left edge
        -- (TP value is right-aligned on the same line). Deferred from above so it
        -- can use the TP row geometry computed here.
        if pendingDistance ~= nil then
            petText(data.distanceText, pendingDistance.text,
                tpBarX + pendingDistance.offX, tpTextRowY + pendingDistance.offY,
                pendingDistance.color, pendingDistance.size, 0);
        end

        -- Add spacing for text row if any vitals text is shown
        -- recastTopSpacing controls the gap between vitals text and recast section (anchored mode)
        local recastTopSpacing = typeSettings.recastTopSpacing or 2;
        if displayMpBar or displayTpBar then
            local maxVitalsFontSize = math.max(displayMpBar and mpFontSize or 0, displayTpBar and tpFontSize or 0);
            imgui.Dummy({totalRowWidth, maxVitalsFontSize + recastTopSpacing});
        end

        -- Row 4: Ability Icons
        local showTimers = typeSettings.showTimers;
        if showTimers == nil then showTimers = gConfig.petBarShowTimers ~= false; end

        -- Helper to hide all recast fonts
        local function hideAllRecastFonts()
            for i = 1, data.MAX_RECAST_SLOTS do
                if data.recastNameFonts and data.recastNameFonts[i] then
                    data.recastNameFonts[i]:set_visible(false);
                end
                if data.recastTimerFonts and data.recastTimerFonts[i] then
                    data.recastTimerFonts[i]:set_visible(false);
                end
            end
        end

        if showTimers then
            -- Get recasts from data module (handles preview internally)
            local timers = data.GetPetRecasts();
            if #timers > 0 then
                local iconOffsetX = typeSettings.iconsOffsetX or gConfig.petBarIconsOffsetX or 0;
                local iconOffsetY = typeSettings.iconsOffsetY or gConfig.petBarIconsOffsetY or 0;
                local iconsAbsolute = typeSettings.iconsAbsolute;
                if iconsAbsolute == nil then iconsAbsolute = gConfig.petBarIconsAbsolute; end
                local scaledIconSize = data.RECAST_ICON_SIZE;
                local iconSpacing = typeSettings.recastFullSpacing or 4;

                local iconX, iconY;
                local drawList;

                if iconsAbsolute then
                    -- Absolute positioning: relative to window top-left
                    iconX = windowPosX + iconOffsetX;
                    iconY = windowPosY + iconOffsetY;
                    -- Use background draw list: renders behind config menu but not clipped to window bounds
                    drawList = imgui.GetBackgroundDrawList();
                else
                    -- Anchored: flow within the pet bar container
                    -- Use recastTopSpacing for vertical offset, no X offset in anchored mode
                    local topSpacing = typeSettings.recastTopSpacing or 2;
                    iconX, iconY = imgui.GetCursorScreenPos();
                    iconY = iconY + topSpacing;
                    -- Use background draw list for consistency (anchored may also use offsets outside content area)
                    drawList = imgui.GetBackgroundDrawList();
                end

                do
                    -- Full display: vertical list with name and recast timer
                    -- Note: Alignment is forced to 'left' for full mode - right alignment
                    -- doesn't work properly with the stacked vertical layout
                    local recastShowBookends = typeSettings.showBookends;
                    if recastShowBookends == nil then recastShowBookends = gConfig.petBarShowBookends; end

                    local fullSettings = {
                        showName = typeSettings.recastFullShowName ~= false,
                        showRecast = typeSettings.recastFullShowTimer ~= false,
                        nameFontSize = typeSettings.recastFullNameFontSize or 10,
                        recastFontSize = typeSettings.recastFullTimerFontSize or 10,
                        alignment = 'left',
                        iconSize = scaledIconSize,
                        barWidth = recastBarWidth,
                        barHeight = recastBarHeight,
                        showBookends = recastShowBookends,
                    };

                    -- Calculate row height based on what's visible
                    -- Text row height
                    local textRowHeight = 0;
                    if fullSettings.showName then
                        textRowHeight = math.max(textRowHeight, fullSettings.nameFontSize);
                    end
                    if fullSettings.showRecast then
                        textRowHeight = math.max(textRowHeight, fullSettings.recastFontSize);
                    end
                    -- Entry height = text row + gap + bar height
                    local textBarGap = 2;
                    local contentHeight = textRowHeight + textBarGap + recastBarHeight;
                    -- If nothing visible (no text), just use bar height
                    if textRowHeight == 0 then
                        contentHeight = recastBarHeight;
                    end
                    local rowHeight = contentHeight + iconSpacing;

                    for i, timerInfo in ipairs(timers) do
                        if i > data.MAX_RECAST_SLOTS then break; end

                        local posY = iconY + (i - 1) * rowHeight;
                        if timerInfo.isChargeAbility then
                            DrawRecastFullCharged(drawList, iconX, posY, timerInfo, colorConfig, fullSettings, i);
                        else
                            DrawRecastFull(drawList, iconX, posY, timerInfo, colorConfig, fullSettings, i);
                        end

                        -- Click-to-use: rows are drawn on the background draw list (no
                        -- imgui item), so hit-test manually against the row rect. Only
                        -- when clickable abilities are enabled, this window is hovered,
                        -- and not locked-out by the config menu. FireAbilityClick
                        -- resolves the command and handles the two-click 2hr confirm.
                        if timerInfo.name and (gConfig.petBarClickable ~= false) and not (showConfig and showConfig[1]) then
                            local mX, mY = imgui.GetMousePos();
                            local rL = iconX;
                            local rR = iconX + totalRowWidth;
                            local rT = posY;
                            local rB = posY + contentHeight;
                            if imgui.IsMouseClicked(0)
                                and mX >= rL and mX <= rR and mY >= rT and mY <= rB then
                                data.FireAbilityClick(timerInfo.name);
                            end
                        end
                    end

                    -- Hide unused font slots
                    for i = #timers + 1, data.MAX_RECAST_SLOTS do
                        if data.recastNameFonts and data.recastNameFonts[i] then
                            data.recastNameFonts[i]:set_visible(false);
                        end
                        if data.recastTimerFonts and data.recastTimerFonts[i] then
                            data.recastTimerFonts[i]:set_visible(false);
                        end
                    end

                    if not iconsAbsolute then
                        -- Only add spacing between rows, not after the last row
                        local totalHeight = #timers * contentHeight + math.max(0, #timers - 1) * iconSpacing;
                        imgui.Dummy({totalRowWidth, totalHeight});
                    end
                end
            else
                -- No timers to display, hide all fonts
                hideAllRecastFonts();
            end
        else
            -- Timers disabled, hide all fonts
            hideAllRecastFonts();
        end

        -- BST Pet Timer Display (Jug countdown or Charm elapsed)
        local showJugTimer = isJug and gConfig.petBarShowJugTimer ~= false and jugTimeRemaining;
        local showCharmTimer = isCharmed and gConfig.petBarShowCharmIndicator ~= false;

        if showJugTimer or showCharmTimer then
            -- Render the pet timer as an ability-style row (same left-label /
            -- right-time layout, fonts, and bar as the recasts above). No custom
            -- drawing — reuse DrawRecastFull with a synthetic timerInfo.
            local label, secs, maxSecs;
            if showJugTimer then
                label = 'Jug Left';
                secs = jugTimeRemaining or 0;
                maxSecs = 3600;
            else
                label = 'Charmed';
                secs = charmTimeRemaining or 0;
                maxSecs = 600;
            end

            local recastShowBookends = typeSettings.showBookends;
            if recastShowBookends == nil then recastShowBookends = gConfig.petBarShowBookends; end
            local fullSettings = {
                showName = true,
                showRecast = true,
                nameFontSize = typeSettings.recastFullNameFontSize or 10,
                recastFontSize = typeSettings.recastFullTimerFontSize or 10,
                alignment = 'left',
                iconSize = data.RECAST_ICON_SIZE,
                barWidth = recastBarWidth,
                barHeight = recastBarHeight,
                showBookends = recastShowBookends,
            };

            local timerInfo = {
                name = label,
                -- DrawRecastFull formats timer in 60ths of a second; convert.
                timer = secs * 60,
                maxTimer = maxSecs * 60,
                isReady = false,
                isChargeAbility = false,
            };

            local drawList = imgui.GetWindowDrawList();

            -- Match the gap the ability rows use between them, so this row isn't
            -- crammed against the last ability above it.
            local rowSpacing = typeSettings.recastFullSpacing or 4;
            imgui.Dummy({ 1, rowSpacing });

            local px, py = imgui.GetCursorScreenPos();

            -- Icon at the row's left edge (inside the window, no clipping); the
            -- label/time row follows to its right.
            local iconSz = math.max(fullSettings.nameFontSize, fullSettings.recastFontSize) + 2;
            local iconX = px;
            if showJugTimer then
                if data.jugIconTexture and data.jugIconTexture.image then
                    local jugColor = color.ARGBToU32(colorConfig.jugIconColor or 0xFFFFFFFF);
                    drawList:AddImage(
                        tonumber(ffi.cast("uint32_t", data.jugIconTexture.image)),
                        {iconX, py}, {iconX + iconSz, py + iconSz}, {0, 0}, {1, 1}, jugColor
                    );
                end
            else
                local heartColor = color.ARGBToU32(colorConfig.charmHeartColor or 0xFFFF6699);
                local cX, cY, hs = iconX + iconSz / 2, py + iconSz / 2, iconSz / 2;
                local cr = hs * 0.5;
                local cy2 = cY - cr * 0.3;
                drawList:AddCircleFilled({cX - cr * 0.6, cy2}, cr, heartColor, 16);
                drawList:AddCircleFilled({cX + cr * 0.6, cy2}, cr, heartColor, 16);
                drawList:AddTriangleFilled(
                    {cX - hs * 0.9, cY - cr * 0.2}, {cX + hs * 0.9, cY - cr * 0.2},
                    {cX, cY + hs * 0.8}, heartColor
                );
            end

            -- Row to the right of the icon. Shrink the bar width by the icon's
            -- footprint so the right-aligned timer lands at the SAME right edge as
            -- the ability rows above (which start at px with no icon), instead of
            -- one icon-size too far right.
            local rowX = px + iconSz + 3;
            local rowSettings = {};
            for k, v in pairs(fullSettings) do rowSettings[k] = v; end
            rowSettings.barWidth = fullSettings.barWidth - (iconSz + 3);
            DrawRecastFull(drawList, rowX, py, timerInfo, colorConfig, rowSettings, data.MAX_RECAST_SLOTS);

            local rowH = math.max(fullSettings.nameFontSize, fullSettings.recastFontSize) + 2 + fullSettings.barHeight;
            imgui.Dummy({ iconSz + 3 + rowSettings.barWidth, rowH });
        else
            -- Hide BST timer text when not showing
            if data.bstTimerText then
                data.bstTimerText:set_visible(false);
            end
            if data.bstLabelText then
                data.bstLabelText:set_visible(false);
            end
        end

        -- Get final window size for background
        local windowWidth, windowHeight = imgui.GetWindowSize();

        -- Handle bottom alignment
        if typeSettings.alignBottom then
            if windowState.height ~= nil and windowState.height ~= windowHeight then
                -- Height changed, adjust Y to keep bottom edge fixed
                local newPosY = windowState.y + windowState.height - windowHeight;
                imgui.SetWindowPos('PetBar', { windowPosX, newPosY });
                windowPosY = newPosY;
            end

            -- Save current state
            windowState.x = windowPosX;
            windowState.y = windowPosY;
            windowState.height = windowHeight;
        end

        -- Store main window position for pet target window
        data.lastMainWindowPosX = windowPosX;
        data.lastMainWindowBottom = windowPosY + windowHeight + 4;

        -- Update background primitives. Plain theme: imgui paints the WindowBg
        -- (pushed above) and the textured prim stays hidden. Any other theme:
        -- the textured prim supplies the fill (bgOnly leaves the portrait alone
        -- — it's always imgui-drawn, right after Begin, so it sits BEHIND the
        -- bars/text).
        if plainBg then
            data.HideBackground(true);
        else
            data.UpdateBackground(windowPosX, windowPosY, windowWidth, windowHeight, settings, true);
        end

        -- Silver highlight lines on the top & bottom edges of the panel.
        -- Always drawn regardless of theme (decoration, not background fill).
        -- Uses the foreground draw list so imgui's own Border can't paint over it.
        do
            local silver = imgui.GetColorU32({ 0.75, 0.78, 0.85, 0.95 });
            local fg = imgui.GetForegroundDrawList();
            fg:AddLine({ windowPosX + 3, windowPosY + 1 }, { windowPosX + windowWidth - 3, windowPosY + 1 }, silver, 1.0);
            fg:AddLine({ windowPosX + 3, windowPosY + windowHeight - 1 }, { windowPosX + windowWidth - 3, windowPosY + windowHeight - 1 }, silver, 1.0);
        end

        -- Save position when user moves window (check on mouse release)
        local canMove = not gConfig.lockPositions or (showConfig[1] and gConfig.petBarPreview);
        if canMove then
            -- Only save if position changed significantly (avoid floating point noise)
            local posChanged = (lastSavedPosX == nil or lastSavedPosY == nil) or
                               (math.abs(windowPosX - lastSavedPosX) > 1) or
                               (math.abs(windowPosY - lastSavedPosY) > 1);
            if posChanged and not imgui.IsMouseDown(0) then
                -- Mouse released and position changed - save to settings
                gConfig.petBarWindowPosX = windowPosX;
                gConfig.petBarWindowPosY = windowPosY;
                lastSavedPosX = windowPosX;
                lastSavedPosY = windowPosY;
                if SaveSettingsToDisk then
                    SaveSettingsToDisk();
                end
            end
        end
    end
    imgui.End();

    -- Pop the panel style pushed before Begin.
    imgui.PopStyleVar(2);    -- WindowRounding, WindowBorderSize
    imgui.PopStyleColor(2);  -- WindowBg, Border

    -- Jug Pet reference list (toggled by clicking the pet name).
    -- NQ-only: HQs all cap at 75, no point listing them.
    -- Open state is a {bool} table-ref so imgui's title-bar X writes back to it.
    if data.jugListOpen and data.jugListOpen[1] then
        local listFlags = bit.bor(
            ImGuiWindowFlags_NoCollapse,
            ImGuiWindowFlags_AlwaysAutoResize,
            ImGuiWindowFlags_NoFocusOnAppearing
        );
        -- Anchor directly below the pet HUD (uses last-frame window size,
        -- captured before imgui.End() above). FirstUseEver lets the user
        -- drag the popup elsewhere afterwards.
        imgui.SetNextWindowPos({ windowPosX, windowPosY + petBarH + 2 }, ImGuiCond_FirstUseEver);
        if imgui.Begin('NQ Jug Caps', data.jugListOpen, listFlags) then
            for _, pet in ipairs(data.jugPets) do
                if pet.maxLevel < 75 then
                    imgui.Text(string.format('  %-18s %d', pet.name, pet.maxLevel));
                end
            end
        end
        imgui.End();
    end

    return true;  -- Pet exists (or preview mode), target window can render
end

-- DEBUG BUILD: error trap — prints one chat line with file:line on error
-- instead of silently killing the frame. Remove once root cause found.
local _dbgSeen = {};
local function _dbgwrap(name, fn)
    if type(fn) ~= 'function' then return fn; end
    return function(...)
        local ok, a, b, c, d = pcall(fn, ...);
        if ok then return a, b, c, d; end
        local msg = '[XIUI DEBUG] petbar.' .. name .. ' ERROR: ' .. tostring(a);
        if not _dbgSeen[msg] then
            _dbgSeen[msg] = true;
            print(msg);
        end
    end
end
display.DrawWindow = _dbgwrap('DrawWindow', display.DrawWindow);

return display;