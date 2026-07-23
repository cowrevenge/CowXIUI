--[[
    Party List Display Module
    Handles rendering of party members and windows
]]

require('common');
require('handlers.helpers');
local ffi = require('ffi');
local imgui = require('imgui');
local statusHandler = require('handlers.statushandler');
local buffTable = require('libs.bufftable');
local statusIcons = require('libs.statusicons');
local progressbar = require('libs.progressbar');
local windowBg = require('libs.windowbackground');
local TextureManager = require('libs.texturemanager');
local encoding = require('submodules.gdifonts.encoding');
local ashita_settings = require('settings');
local castcostShared = require('modules.castcost.shared');

local data = require('modules.partylist.data');

local display = {};

-- ============================================================================
-- Layout 1 (HXUI-style Compact Vertical) developer defaults.
-- These are intentionally DECOUPLED from each other:
--   * HX_ICON_SIZE_MULT scales ONLY the job icon. It does NOT move the bars.
--   * HX_BAR_INSET is the fixed left gap the bars sit at, independent of icon
--     size — so changing the icon never shifts the bars.
--   * HX_BAR_WIDTH_MULT shortens the HP/MP bars in this layout only.
-- Changing these affects layout 1 only; layouts 0 and 2 never read them.
-- ============================================================================
local HX_ICON_SIZE_MULT = 1.6;   -- job icon size multiplier (developer default)
local HX_BAR_INSET      = 4;     -- gap between the job icon and the bars (px, * scale.x)
local HX_BAR_WIDTH_MULT = 0.82;  -- HP/MP bar length in layout 1
-- Per-player alternating background band (layout 1 only, both themes). Every
-- other PLAYER (keyed on member index) gets a DARK REDDISH tint, a warm counter
-- to the cool blue-ish theme, so alternating players read at a glance. Drawn on
-- the layer between the panel background and the bars/text (window draw list in
-- (imgui paints WindowBg first, then our band, then the bars on top), so
-- it tints only the background, not the bars. RGB is a dark red; alpha per theme.
local HX_BAND_COLOR_R          = 0.45;  -- dark red tint (R)
local HX_BAND_COLOR_G          = 0.05;  -- (G)
local HX_BAND_COLOR_B          = 0.08;  -- (B)
local HX_BAND_ALPHA            = 0.30;  -- band alpha on the panel

-- Selection box tuning (layout 1 only). The box width is anchored
-- to the actual bar edges (no fudge); only the bottom edge needs a small trim
-- because the box draws on the foreground list.
local HX_SEL_TRIM_H         = 6;    -- trim off the BOTTOM edge only (px, * scale.y)
-- Layout 1 (HXUI) buff/debuff rows sit too low because their Y is anchored to
-- the HP bar top (hpStartY) like layout 0, but layout 1 has no name row above,
-- so the player's visual block is higher. Lift both rows up by this many px
-- (* scale.y) in layout 1 only.
local HX_STATUS_LIFT = 14;

-- Status icon textures (lazy-loaded). Same naming scheme as XIUI's
-- targetbar — TextureManager.getFileTexture('lock'/'arrow'/'status_lfp'/...)
-- returns nil if the asset isn't shipped, in which case the renderer falls
-- back to a text label automatically.
local targetStatusIcons = nil;
local function ensureTargetStatusIcons()
    if targetStatusIcons ~= nil then return; end
    targetStatusIcons = {};
    local names = {'lfp','bazaar','mentor','new','away','sync'};
    for _, n in ipairs(names) do
        local ok, tex = pcall(function()
            return TextureManager.getFileTexture('status_' .. n);
        end);
        if ok and tex ~= nil then
            -- Same dimension-query pattern as targetbar.lua's lock texture.
            pcall(function()
                local texPtr   = ffi.cast('IDirect3DTexture8*', tex.image);
                local _, desc  = texPtr:GetLevelDesc(0);
                tex.width  = (desc and desc.Width)  or 16;
                tex.height = (desc and desc.Height) or 16;
            end);
            tex.width  = tex.width  or 16;
            tex.height = tex.height or 16;
            targetStatusIcons[n] = tex;
        end
    end
end

-- Helper: Set font text only if changed (avoids texture regeneration)
local function setCachedText(memIdx, fontKey, font, text)
    if not data.memberTextCache[memIdx] then
        data.memberTextCache[memIdx] = {};
    end
    if data.memberTextCache[memIdx][fontKey] ~= text then
        font:set_text(text);
        data.memberTextCache[memIdx][fontKey] = text;
    end
end

-- Helper: Draw text with a 1-pixel black 4-direction outline.
-- Uses the FOREGROUND draw list's AddText (not imgui.TextColored). TextColored
-- submits through imgui's widget path, which on this Ashita build can land on a
-- different channel than the bar's AddImageRounded/AddRectFilled and end up
-- UNDER the bar. Drawing directly onto the foreground draw list guarantees the
-- overlay text composites on top of the bars. The {r,g,b,a} 0-1 color table is
-- converted to a U32 via imgui.GetColorU32. Cursor is left untouched.
local function drawOutlinedText(x, y, text, fillColor)
    if text == nil or text == '' then return; end
    text = tostring(text);
    local dl = imgui.GetForegroundDrawList();
    if dl == nil then return; end
    local blackU32 = imgui.GetColorU32({0, 0, 0, 1});
    local fillU32  = imgui.GetColorU32(fillColor or {1, 1, 1, 1});
    -- 4-direction black outline
    dl:AddText({x - 1, y - 1}, blackU32, text);
    dl:AddText({x + 1, y - 1}, blackU32, text);
    dl:AddText({x - 1, y + 1}, blackU32, text);
    dl:AddText({x + 1, y + 1}, blackU32, text);
    -- fill on top
    dl:AddText({x, y}, fillU32, text);
end

-- Helper: shorten an FFXI zone name for the cramped partylist out-of-zone
-- display. Rules (preserve the older XIUI behavior):
--   1. Strip apostrophes first ("Ru'Hmet" -> "RuHmet").
--   2. "X of Y" -> Y with internal spaces stripped
--      ("Grand Palace of Hu'Xzoi" -> "HuXzoi").
--   3. Two words -> first 2 chars of word 1 + word 2 concatenated
--      ("Empyreal Paradox" -> "EmParadox").
--   4. Three+ words -> first letter of each word except the last,
--      then last word in full ("Lower Delkfutt's Tower" -> "LDTower").
--   5. Single word / empty / fallback -> as-is.
local function shortenZoneName(name)
    if name == nil or name == '' then return ''; end
    name = tostring(name):gsub("'", "");
    local afterOf = name:match(".*%sof%s(.+)$");
    if afterOf ~= nil then
        return (afterOf:gsub("%s", ""));
    end
    local words = {};
    for w in name:gmatch("%S+") do words[#words + 1] = w; end
    if #words == 0 then return name; end
    if #words == 1 then return words[1]; end
    if #words == 2 then return words[1]:sub(1, 2) .. words[2]; end
    local out = '';
    for i = 1, #words - 1 do
        out = out .. words[i]:sub(1, 1);
    end
    return out .. words[#words];
end

-- Draw the per-player alternating band for one entry. Called by every layout
-- (0/1/2) with that layout's own row rectangle. The band tints the row
-- background BEHIND the bars/text on the window draw list (imgui paints the
-- panel bg first, then this band, then the bars on top). Only every other
-- PLAYER (memIdx parity) and only when the setting is on.
local function drawAlternatingBand(memIdx, cache, left, top, right, bottom)
    if not cache.alternatingColors then return; end
    if (memIdx % 2) ~= 1 then return; end
    local bandList = imgui.GetWindowDrawList();
    local bandColor = imgui.GetColorU32({HX_BAND_COLOR_R, HX_BAND_COLOR_G, HX_BAND_COLOR_B, HX_BAND_ALPHA});
    bandList:AddRectFilled({left, top}, {right, bottom}, bandColor, 4);
end

-- ============================================
-- Click-to-Cure Debuff Mapping
-- ============================================
-- Maps FFXI debuff status IDs to the white-magic spell that cures them.
-- IDs are the standard client-visible status IDs (bg-wiki / Darkstar conventions):
--   2=Sleep_I  3=Poison    4=Paralysis  5=Blindness  6=Silence
--   7=Petrification         9=Curse_I   13=Slow      15=Doom
--   19=Sleep_II 20=Curse_II 29=Mute     31=Plague
-- Sleep (2) and Sleep_II (19) resolve to Cure — Cure wakes sleep in FFXI even at
-- the lowest tier, the standard cure-wake healer play when the party eats a sleepga.
-- Slow (13) resolves to Erase — Erase removes the slow directly so the GCD
-- is spent solving the actual problem (Haste was the older default but the
-- recasts didn't line up; clicking a Slow icon now casts Erase).
--
-- Anything NOT in this table gets no click handler. We deliberately don't fall
-- back to Erase for unknown IDs — too many "debuff" rows are short-lived /
-- uncurable / not worth the GCD, and a blanket Erase fallback was firing on
-- icons the user didn't intend to cure.
local DEBUFF_CURES = {
    [2]  = 'Cure',
    [3]  = 'Poisona',
    [4]  = 'Paralyna',
    [5]  = 'Blindna',
    [6]  = 'Silena',
    [7]  = 'Stona',
    [9]  = 'Cursna',
    [13] = 'Erase',
    [15] = 'Cursna',
    [19] = 'Cure',
    [20] = 'Cursna',
    [29] = 'Silena',
    [31] = 'Viruna',
};

-- Resolve a debuff status ID to its cure spell, or nil if we don't handle it
-- (no Erase fallback by design — see DEBUFF_CURES comment above).
local function GetDebuffCure(debuffId)
    return DEBUFF_CURES[debuffId];
end

-- ============================================
-- Click-to-Cure: deferred hit-test model
-- ============================================
-- InvisibleButton placed via SetCursorScreenPos on top of already-submitted
-- icon items does NOT activate in this imgui build (the icon items own the
-- hit-test slot; only hover passes through). Doing the release-check INSIDE the
-- child status windows also failed. So instead, every debuff icon that resolves
-- to a cure spell records its screen-rect into this per-frame list while it is
-- being drawn. After ALL windows are submitted, ResolveCureClicks() runs once at
-- the top level (same context where click-to-target works) and fires the spell
-- for whichever zone the release landed in. Hover/tooltip is handled immediately
-- at record time since tooltips must render during the owning window.
local cureClickZones = {};
local cureZoneCount = 0;

local function BeginCureFrame()
    cureZoneCount = 0;
end

-- Record one cure target. Draws the hover tooltip immediately (must happen in the
-- owning window). Defers the actual click resolution to ResolveCureClicks().
local function RecordCureZone(x, y, size, cureSpell, targetName)
    local mx, my = imgui.GetMousePos();
    if mx >= x and mx <= x + size and my >= y and my <= y + size then
        imgui.SetMouseCursor(ImGuiMouseCursor_Hand);
        imgui.BeginTooltip();
        imgui.Text(cureSpell .. ' -> ' .. targetName);
        imgui.EndTooltip();
    end
    cureZoneCount = cureZoneCount + 1;
    local z = cureClickZones[cureZoneCount];
    if z == nil then
        z = {};
        cureClickZones[cureZoneCount] = z;
    end
    z.x = x; z.y = y; z.size = size;
    z.spell = cureSpell; z.target = targetName;
end

-- Resolve a click against recorded zones. Manual click-vs-drag detection mirrors
-- the click-to-target logic. Runs once per frame at the top level.
local function ResolveCureClicks()
    if cureZoneCount == 0 then return; end
    if not imgui.IsMouseReleased(0) then return; end
    local dx, dy = imgui.GetMouseDragDelta(0, 4);
    if dx ~= 0 or dy ~= 0 then return; end   -- was a drag, not a click
    local mx, my = imgui.GetMousePos();
    for i = 1, cureZoneCount do
        local z = cureClickZones[i];
        if mx >= z.x and mx <= z.x + z.size and my >= z.y and my <= z.y + z.size then
            AshitaCore:GetChatManager():QueueCommand(-1,
                string.format('/ma "%s" %s', z.spell, z.target));
            return;   -- one cast per click
        end
    end
end

-- ============================================
-- Super Compact Layout (Layout 2)
-- ============================================
-- Pixels the MP bar shifts up relative to the HP bar's bottom edge, so the HP
-- bar visually covers the top sliver of the MP bar (the "slight overlap" look
-- from the old XIUI). Tuned so the HP bar's outline reads as the divider.
local LAYOUT_SUPERCOMPACT_OVERLAP = 3;

-- Pixels the player-name / HP-value text row dips DOWN into the top of the HP
-- bar. With 10 px overlap the text row is mostly INSIDE the bar's vertical
-- extent — the top sliver pokes above the bar, the rest covers the bar's top.
local SC_NAME_BAR_OVERLAP = 10;

-- Global base-width multiplier applied to HP/MP/TP bar widths BEFORE the per-party
-- scale.x is applied. The HXUI-era templates render 25% wider than they should at
-- scale 1.0 on Shane's setup, so we shrink the base footprint uniformly across
-- every layout and theme (horizontal, compact, super compact). Per-party scaleX
-- and per-bar hpBarScaleX/mpBarScaleX/tpBarScaleX continue to multiply on top of
-- this, so user-configured scaling still works as expected.
local PARTY_BAR_BASE_WIDTH_MULT = 0.8;

-- Compute the TP text color (handles the >= 1000 flash pulse). Mirrors the
-- layout 1 implementation at the old call site — extracted here so super
-- compact can reuse it without copying the arithmetic. Returns ARGB uint32.
local function computeTpColorARGB(memInfo, cache)
    local fullColor  = cache.colors.tpFullTextColor  or 0xFFFFFFFF;
    local emptyColor = cache.colors.tpEmptyTextColor or 0xFF888888;
    if memInfo.tp < 1000 then return emptyColor; end

    -- Rainbow mode: cycles full-saturation hues over ~3s. Overrides flash
    -- when both are enabled. Layouts 1 (Compact) and 2 (SuperCompact) honor
    -- this via the call sites in DrawMember and DrawMemberSuperCompact.
    if cache.rainbowTP then
        local cycle = 3;
        local h = (os.clock() % cycle) / cycle;        -- 0..1
        local h6 = h * 6;
        local c  = 1.0;                                 -- chroma at S=1, V=1
        local x  = c * (1 - math.abs((h6 % 2) - 1));
        local r, g, b;
        if     h6 < 1 then r, g, b = c, x, 0;
        elseif h6 < 2 then r, g, b = x, c, 0;
        elseif h6 < 3 then r, g, b = 0, c, x;
        elseif h6 < 4 then r, g, b = 0, x, c;
        elseif h6 < 5 then r, g, b = x, 0, c;
        else                r, g, b = c, 0, x;
        end
        return bit.bor(
            bit.lshift(0xFF, 24),
            bit.lshift(math.floor(r * 255), 16),
            bit.lshift(math.floor(g * 255), 8),
                       math.floor(b * 255)
        );
    end

    if not cache.flashTP then return fullColor; end

    local flashColor = cache.colors.tpFlashColor or 0xFF3ECE00;
    local timePerPulse = 1;
    local phase = os.clock() % timePerPulse;
    local pulseAlpha = (2 / timePerPulse) * phase;
    if pulseAlpha > 1 then pulseAlpha = 2 - pulseAlpha; end

    local baseA = bit.band(bit.rshift(fullColor, 24), 0xFF);
    local baseR = bit.band(bit.rshift(fullColor, 16), 0xFF);
    local baseG = bit.band(bit.rshift(fullColor,  8), 0xFF);
    local baseB = bit.band(fullColor, 0xFF);
    local flashA = bit.band(bit.rshift(flashColor, 24), 0xFF);
    local flashR = bit.band(bit.rshift(flashColor, 16), 0xFF);
    local flashG = bit.band(bit.rshift(flashColor,  8), 0xFF);
    local flashB = bit.band(flashColor, 0xFF);
    return bit.bor(
        bit.lshift(math.floor(baseA + (flashA - baseA) * pulseAlpha), 24),
        bit.lshift(math.floor(baseR + (flashR - baseR) * pulseAlpha), 16),
        bit.lshift(math.floor(baseG + (flashG - baseG) * pulseAlpha),  8),
                   math.floor(baseB + (flashB - baseB) * pulseAlpha)
    );
end

-- Convert ARGB uint32 → {r,g,b,a} float table for drawOutlinedText.
local function argbToRgbaTable(argb)
    return {
        bit.band(bit.rshift(argb, 16), 0xFF) / 255,
        bit.band(bit.rshift(argb,  8), 0xFF) / 255,
        bit.band(argb, 0xFF) / 255,
        bit.band(bit.rshift(argb, 24), 0xFF) / 255,
    };
end

-- Format HP/MP value text per the display mode. Matches layout 0's formatter at the
-- equivalent call site — same five modes (number, percent, both, both_percent_first,
-- current_max) and same '%' / '(...)' / '/' separators — so the config-menu dropdown
-- value picked by the user produces consistent output across every layout.
local function formatBarValueText(curValue, maxValue, percent, mode)
    if mode == 'percent' then
        return tostring(percent) .. '%';
    elseif mode == 'both' then
        return tostring(curValue) .. ' (' .. tostring(percent) .. '%)';
    elseif mode == 'both_percent_first' then
        return tostring(percent) .. '% (' .. tostring(curValue) .. ')';
    elseif mode == 'current_max' then
        return tostring(curValue) .. '/' .. tostring(maxValue);
    end
    return tostring(curValue);
end

-- Render the combined buffs+debuffs window for Super Compact: single horizontal
-- row, debuffs first then buffs. Click-to-cure overlay sits on top of the debuff
-- icons only. Returns the window's measured width so the caller can persist it.
local function drawSuperCompactStatus(memIdx, memInfo, partyIndex, cache, settings, hpStartX, hpStartY)
    if memInfo.buffs == nil or #memInfo.buffs <= 0 then return; end
    if cache.statusTheme ~= 0 and cache.statusTheme ~= 1 then return; end

    -- Reuse the data module's scratch tables to avoid per-frame allocations.
    for k in pairs(data.reusableBuffs)   do data.reusableBuffs[k]   = nil; end
    for k in pairs(data.reusableDebuffs) do data.reusableDebuffs[k] = nil; end

    local buffCount, debuffCount = 0, 0;
    for i = 0, #memInfo.buffs do
        if buffTable.IsBuff(memInfo.buffs[i]) then
            buffCount = buffCount + 1;
            data.reusableBuffs[buffCount] = memInfo.buffs[i];
        else
            debuffCount = debuffCount + 1;
            data.reusableDebuffs[debuffCount] = memInfo.buffs[i];
        end
    end
    if buffCount + debuffCount == 0 then return; end

    -- One combined ordered list (debuffs first, then buffs) so DrawStatusIcons
    -- renders the row left-to-right with pink debuff frames before green buff
    -- frames. buffTable.IsBuff inside DrawStatusIcons decides the frame color
    -- per icon, so we don't need to flag the lists ourselves.
    local combined = {};
    for i = 1, debuffCount do combined[#combined + 1] = data.reusableDebuffs[i]; end
    for i = 1, buffCount   do combined[#combined + 1] = data.reusableBuffs[i];   end

    local statusOffsetX = cache.statusOffsetX or 0;
    local statusOffsetY = cache.statusOffsetY or 0;
    if cache.statusSide == 0 then
        local prevWidth = data.buffWindowX[memIdx] or 0;
        if prevWidth > 0 then
            imgui.SetNextWindowPos({hpStartX - prevWidth - settings.buffOffset + statusOffsetX, hpStartY + statusOffsetY});
        end
    else
        if data.fullMenuWidth[partyIndex] ~= nil then
            local thisPosX, _ = imgui.GetWindowPos();
            imgui.SetNextWindowPos({thisPosX + data.fullMenuWidth[partyIndex] + statusOffsetX, hpStartY + statusOffsetY});
        end
    end

    local winFlags = bit.bor(
        ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoSavedSettings,
        ImGuiWindowFlags_NoDocking
    );
    if imgui.Begin('PlayerStatus' .. memIdx, true, winFlags) then
        imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {3, 1});

        local rowX, rowY = imgui.GetCursorScreenPos();
        DrawStatusIcons(combined, settings.iconSize, 32, 1, true);

        -- Click-to-cure overlay on the debuff icons only (first `debuffCount`
        -- positions). Records each icon's screen-rect; resolution is deferred to
        -- ResolveCureClicks() at the top level (InvisibleButton doesn't activate
        -- when overlaid on already-drawn icons in this imgui build).
        if (gConfig.partyListClickCureDebuffs ~= false)
           and memInfo.name and memInfo.name ~= '' then
            local stride = settings.iconSize + 3;
            local cureTarget = (memIdx == 0) and '<me>' or memInfo.name;
            for i = 1, debuffCount do
                local cureSpell = GetDebuffCure(data.reusableDebuffs[i]);
                if cureSpell ~= nil then
                    RecordCureZone(rowX + (i - 1) * stride, rowY, settings.iconSize, cureSpell, cureTarget);
                end
            end
        end

        imgui.PopStyleVar(1);
    end
    local statusWindowX, _ = imgui.GetWindowSize();
    data.buffWindowX[memIdx]   = statusWindowX;
    data.debuffWindowX[memIdx] = 0;   -- merged window — no separate debuff anchor
    imgui.End();
end

-- DrawMemberSuperCompact: layout 2 render path. Self-contained; the caller
-- (display.DrawMember) early-returns here when cache.layout == 2 so the
-- existing layout 0/1 code is bypassed entirely.
--
-- Visual structure per member:
--   Row 1 (HP bar full width): [player name (left overlay)] ............ [HP value (right overlay)]
--   Row 2 (MP bar, shifted UP by OVERLAP px so HP bar covers its top):
--          [job icon] [TP text] ............ [MP bar with MP value right overlay]
-- Cast bars are not rendered in this layout — the player name stays on the
-- HP bar at all times (no spell-name replacement). Out of zone collapses to
-- a black block with the zone name centered across both rows.
function display.DrawMemberSuperCompact(memIdx, settings, isLastVisibleMember)
    local memInfo = data.GetMemberInformation(memIdx);
    if memInfo == nil then
        memInfo = {
            hp = 0, hpp = 0, maxhp = 0, mp = 0, mpp = 0, maxmp = 0,
            tp = 0, job = '', level = '', subjob = '', subjoblevel = '',
            targeted = false, serverid = 0, buffs = nil, sync = false,
            subTargeted = false, zone = '', inzone = false, name = '', leader = false, allianceLeader = false,
        };
    end

    local partyIndex = math.ceil((memIdx + 1) / data.partyMaxSize);
    local cache       = data.partyConfigCache[partyIndex];
    local scale       = data.getScale(partyIndex);
    local barScales   = data.getBarScales(partyIndex);
    local layoutTpl   = data.getLayoutTemplate(partyIndex);
    local _, hpGradient = GetCustomHpColors(memInfo.hpp, cache.colors);

    -- Bar dimensions
    local baseHpW = (layoutTpl.hpBarWidth or 135) * PARTY_BAR_BASE_WIDTH_MULT;
    local baseMpW = (layoutTpl.mpBarWidth or 80)  * PARTY_BAR_BASE_WIDTH_MULT;
    local baseBarH = layoutTpl.barHeight or 12;
    local hpBarWidth  = baseHpW * scale.x * ((barScales and barScales.hpBarScaleX) or 1);
    local mpBarWidth  = baseMpW * scale.x * ((barScales and barScales.mpBarScaleX) or 1);
    local hpBarHeight = baseBarH * scale.y * ((barScales and barScales.hpBarScaleY) or 1);
    local mpBarHeight = baseBarH * scale.y * ((barScales and barScales.mpBarScaleY) or 1);

    -- Entry/box width — clamp to at least hpBarWidth so layout math doesn't break
    -- on tiny custom values. The text row spans entryWidth; bars stay at hpBarWidth.
    local baseEntryW = (layoutTpl.entryWidth or 160) * PARTY_BAR_BASE_WIDTH_MULT;
    local entryWidth = math.max(baseEntryW * scale.x, hpBarWidth);

    local jobIconSize = cache.showJobIcon and (settings.baseIconSize * 1.1 * scale.icon) or 0;

    -- Entry vertical layout (super compact):
    --   entryTop  → one text row containing [name LEFT] ... [HP value RIGHT].
    --               The row dips SC_NAME_BAR_OVERLAP px into the HP bar's top,
    --               so the text reads as a header attached to the bar.
    --   hpStartY  → HP bar (full width); its top edge is `SC_NAME_BAR_OVERLAP`
    --               px under the text row's bottom.
    --   mpRowY    → MP bar, shifted up by LAYOUT_SUPERCOMPACT_OVERLAP px so the
    --               HP bar visually covers its top sliver.
    -- Reserve the selector's side padding INSIDE the window content so the
    -- auto-resized window (and its background) grows to span the full selector
    -- on BOTH sides. The selector runs from hpStartX-cursorPaddingX1 to
    -- hpStartX+entryWidth+cursorPaddingX2; without this, the window content ends
    -- at hpStartX+entryWidth and the background stops short of the selector.
    -- Indent the cursor right by cursorPaddingX1 (left gap) before capturing
    -- hpStartX, then emit a right Dummy of cursorPaddingX2 after the entry.
    imgui.Indent(settings.cursorPaddingX1);
    local hpStartX, entryTop = imgui.GetCursorScreenPos();
    local _, nameRowH = imgui.CalcTextSize('A');
    local hpStartY = entryTop + nameRowH - SC_NAME_BAR_OVERLAP;
    local entryHeight = (nameRowH - SC_NAME_BAR_OVERLAP) + hpBarHeight + mpBarHeight - LAYOUT_SUPERCOMPACT_OVERLAP;

    -- Bar render X: shifted RIGHT inside the entry by (entryWidth - hpBarWidth)
    -- pixels, i.e. the slack from the wider box becomes LEFT padding on the bar.
    -- Bar's right edge ends at the entry's right edge (= hpStartX + entryWidth).
    -- Name overlay, dots, status window etc. STAY anchored on hpStartX so the name
    -- floats on the left of the entry, the bar floats on the right of the entry,
    -- and they don't share an X anchor. Must come after hpStartX is declared.
    local barAreaLeft = hpStartX + (entryWidth - hpBarWidth);

    -- ============================================
    -- Leader / Alliance / Sync dot drawing
    -- ============================================
    -- Closure (captures hpStartX, entryWidth, entryTop, entryHeight, hpStartY,
    -- memInfo, settings via upvalues). Called from inside each in-zone /
    -- out-of-zone branch BEFORE the player name draw so the name — drawn after
    -- this on the same FOREGROUND list — covers the dot's overlap with the name.
    -- Foreground list (not window) so dots aren't clipped against the window
    -- rect — that's what was hiding the sync dot at the bar's right edge.
    local function drawMemberDots()
        local leaderR     = settings.dotRadius * 1.5;
        local barsCenterY = (hpStartY + (entryTop + entryHeight)) / 2;
        local LEADER_SHIFT_X = 3;
        local fg = imgui.GetForegroundDrawList();
        if memInfo.allianceLeader then
            draw_circle({hpStartX - leaderR * 3 + LEADER_SHIFT_X, barsCenterY}, leaderR, {1, 1, 0.5, 1}, leaderR * 3, true, nil, fg);
            draw_circle({hpStartX - leaderR     + LEADER_SHIFT_X, barsCenterY}, leaderR, {1, 1, 0.5, 1}, leaderR * 3, true, nil, fg);
        elseif memInfo.leader then
            draw_circle({hpStartX + LEADER_SHIFT_X, barsCenterY}, leaderR, {1, 1, 0.5, 1}, leaderR * 3, true, nil, fg);
        end
        if memInfo.sync then
            draw_circle({hpStartX + entryWidth + leaderR * 2, barsCenterY}, leaderR, {1, 0.3, 0.3, 1}, leaderR * 3, true, nil, fg);
        end
    end

    -- Per-player alternating band (layout 2 / SuperCompact): full entry width,
    -- drawn BEFORE the icon/bars/text so it tints only the row background.
    drawAlternatingBand(memIdx, cache,
        hpStartX, entryTop,
        hpStartX + entryWidth, entryTop + entryHeight);

    -- Job icon: drawn at the entry's TOP-LEFT corner, vertically centered on the
    -- FULL entry height (spans both name row and bar rows visually). Drawn on
    -- the WINDOW draw list, BEFORE the name and TP — so subsequent text
    -- (drawOutlinedText on the same window draw list) layers ON TOP of the icon
    -- and visually covers its right portion. The icon's left edge stays visible,
    -- the rest peeks through gaps between text glyphs. Matches the retail look.
    if cache.showJobIcon then
        local jobIcon = statusHandler.GetJobIcon(memInfo.job);
        if jobIcon ~= nil then
            local jobIconY   = entryTop + (entryHeight - jobIconSize) / 2;
            local jobIconPtr = tonumber(ffi.cast('uint32_t', jobIcon));
            local draw_list  = imgui.GetWindowDrawList();
            draw_list:AddImage(
                jobIconPtr,
                {hpStartX, jobIconY},
                {hpStartX + jobIconSize, jobIconY + jobIconSize},
                {0, 0}, {1, 1},
                IM_COL32_WHITE
            );
        end
    end

    -- Name + TP anchor at hpStartX + N (entry's left padding). The job icon
    -- sits BEHIND them at hpStartX, so both overlap and cover the icon.
    local nameStartX = hpStartX + 4;

    -- Gdifont primitives aren't used in this layout — everything renders via
    -- drawOutlinedText / progressbar / imgui draw lists. Hide them so leftover
    -- text from a prior layout doesn't ghost behind our overlays.
    local mt = data.memberText[memIdx];
    if mt then
        mt.hp:set_visible(false);
        mt.mp:set_visible(false);
        mt.tp:set_visible(false);
        mt.name:set_visible(false);
        mt.distance:set_visible(false);
        mt.zone:set_visible(false);
        mt.job:set_visible(false);
    end

    -- Selection / subtarget box (same gradient + border treatment as layout 0/1,
    -- but topOfMember = hpStartY since super compact has no name row above the bar).
    if memInfo.targeted or memInfo.subTargeted then
        -- The panel is the imgui window, so a background-list box would be hidden
        -- behind it — use the global foreground list so it shows and stays
        -- unclipped (matching layout 1's selection).
        local drawList         = imgui.GetForegroundDrawList();
        -- Selector spans the full entry with symmetric cursor padding on both
        -- sides, exactly like layout 1: from (hpStartX - paddingX1) to
        -- (hpStartX + entryWidth + paddingX2). entryWidth is the content extent.
        local selectionWidth   = entryWidth + settings.cursorPaddingX1 + settings.cursorPaddingX2;
        local selectionScaleY  = cache.selectionBoxScaleY or 1;
        local selectionOffsetY = cache.selectionBoxOffsetY or 0;
        local unscaledHeight   = entryHeight + settings.cursorPaddingY1 + settings.cursorPaddingY2;
        local selectionHeight  = unscaledHeight * selectionScaleY;
        local centerOffsetY    = (selectionHeight - unscaledHeight) / 2;
        local selTL = {hpStartX - settings.cursorPaddingX1, entryTop - settings.cursorPaddingY1 - centerOffsetY + selectionOffsetY};
        local selBR = {selTL[1] + selectionWidth, selTL[2] + selectionHeight};

        local selectionGradient, borderColorARGB;
        if memInfo.subTargeted then
            selectionGradient = GetCustomGradient(cache.colors, 'subtargetGradient') or {'#d9a54d', '#edcf78'};
            borderColorARGB   = cache.colors.subtargetBorderColor or 0xFFfdd017;
        else
            selectionGradient = GetCustomGradient(cache.colors, 'selectionGradient') or {'#4da5d9', '#78c0ed'};
            borderColorARGB   = cache.colors.selectionBorderColor;
        end
        local startColor = HexToImGui(selectionGradient[1]);
        local endColor   = HexToImGui(selectionGradient[2]);

        if cache.showSelectionBox then
            local gradientSteps = 4;
            local stepHeight = selectionHeight / gradientSteps;
            for i = 1, gradientSteps do
                local t = (i - 1) / (gradientSteps - 1);
                local r = startColor[1] + (endColor[1] - startColor[1]) * t;
                local g = startColor[2] + (endColor[2] - startColor[2]) * t;
                local b = startColor[3] + (endColor[3] - startColor[3]) * t;
                local a = 0.35 - t * 0.25;
                local stepColor = imgui.GetColorU32({r, g, b, a});
                local stepTLy = selTL[2] + (i - 1) * stepHeight;
                local stepBRy = stepTLy + stepHeight;
                if i == 1 then
                    drawList:AddRectFilled({selTL[1], stepTLy}, {selBR[1], stepBRy}, stepColor, 6, 3);
                elseif i == gradientSteps then
                    drawList:AddRectFilled({selTL[1], stepTLy}, {selBR[1], stepBRy}, stepColor, 6, 12);
                else
                    drawList:AddRectFilled({selTL[1], stepTLy}, {selBR[1], stepBRy}, stepColor, 0);
                end
            end
            local borderColor = ARGBToU32(borderColorARGB);
            drawList:AddRect({selTL[1], selTL[2]}, {selBR[1], selBR[2]}, borderColor, 6, 15, 2);
        end
        data.partyTargeted = true;
    end

    -- Render either the out-of-zone block OR the in-zone HP/MP rows. Common
    -- end logic (sync/leader/target arrow/status/click-to-target/spacing) runs
    -- after this branch regardless.
    if not memInfo.inzone then
        -- Out-of-zone: bar rows replaced with a solid black block; player name
        -- + abbreviated zone overlay it as a single line "Name (ShortZone)".
        -- Entry height is unchanged so subsequent members align vertically.
        --
        -- Zone abbreviation rules (matches older XIUI behavior):
        --   "X of Y"           -> Y with apostrophes stripped
        --                        ("Grand Palace of Hu'Xzoi" -> "HuXzoi")
        --   "First Second ..."  -> first 2 chars of first word + rest joined
        --                        ("Empyreal Paradox" -> "EmParadox")
        --   single word         -> as-is

        -- (1) Black block over the bar-row area
        local barsTop    = hpStartY;
        local barsBottom = entryTop + entryHeight;
        local barsHeight = barsBottom - barsTop;
        local fillCol    = imgui.GetColorU32({0, 0, 0, 1});
        local wDraw      = imgui.GetWindowDrawList();
        wDraw:AddRectFilled({hpStartX, barsTop}, {hpStartX + entryWidth, barsBottom}, fillCol);

        -- (2) Resolve + abbreviate zone name via shared helper.
        local zoneShort = '';
        if memInfo.zone and AshitaCore then
            local zoneName = AshitaCore:GetResourceManager():GetString('zones.names', memInfo.zone) or '';
            zoneShort = shortenZoneName(zoneName);
        end

        -- (3) Leader / Alliance / Sync dots BEFORE the name so the name (added
        -- after this on the foreground list) covers any overlap.
        drawMemberDots();

        -- (4) "Name (ShortZone)" left-aligned on the name row.
        do
            local nameStr = tostring(memInfo.name or '');
            if #nameStr > 10 then
                nameStr = nameStr:sub(1, 8) .. '..';
            end
            local fullLine = nameStr;
            if zoneShort ~= '' then
                fullLine = fullLine .. ' (' .. zoneShort .. ')';
            end
            drawOutlinedText(nameStartX, entryTop, fullLine, {1, 1, 1, 1});
        end

        imgui.SetCursorScreenPos({hpStartX, entryTop + entryHeight});
        imgui.Dummy({entryWidth + settings.cursorPaddingX2, 0});
    else
        -- ---- Draw order (back to front, per spec):
        --   1. Job icon  (already drawn above this block)
        --   2. MP bar
        --   3. HP bar    (covers MP bar's top sliver due to LAYOUT_SUPERCOMPACT_OVERLAP)
        --   4. MP value  (overlay on MP bar)
        --   5. Name      (overlay on HP bar — partially covers the bar's top + job icon's right portion)
        --   6. HP value  (overlay on HP bar's right edge)
        --   7. TP        (LAST — top of stack, overlays MP bar's left)
        local mpRowY        = hpStartY + hpBarHeight - LAYOUT_SUPERCOMPACT_OVERLAP;
        local _, mpRowTextH = imgui.CalcTextSize('A');
        local mpBarStartX   = barAreaLeft + hpBarWidth - mpBarWidth;
        local showMpBar     = cache.alwaysShowMpBar or JobHasMP(memInfo.job, memInfo.subjob);

        -- MP value text + width computed upfront so TP positioning can reference
        -- mpValueLeftX. 'both' / 'both_percent_first' modes use SPLIT rendering
        -- with the same SC_VALUE_BOTH_OFFSET (+6) push as HP value; other modes
        -- use SC_VALUE_NUM_OFFSET (+2).
        local mpMode      = cache.mpDisplayMode or 'number';
        local mpPercent   = math.floor(memInfo.mpp * 100);
        local mpSplit     = (mpMode == 'both' or mpMode == 'both_percent_first');
        local mpText, mpValStr, mpSuffStr, mpValX, mpSuffX, mpValueLeftX;
        if mpSplit then
            if mpMode == 'both' then
                mpValStr  = tostring(memInfo.mp);
                mpSuffStr = '(' .. tostring(mpPercent) .. '%)';
            else
                mpValStr  = tostring(mpPercent) .. '%';
                mpSuffStr = '(' .. tostring(memInfo.mp) .. ')';
            end
            local valW  = imgui.CalcTextSize(mpValStr);
            local suffW = imgui.CalcTextSize(mpSuffStr);
            mpSuffX     = hpStartX + entryWidth - suffW + 6;   -- SC_VALUE_BOTH_OFFSET
            mpValX      = mpSuffX - 2 - valW;
            mpValueLeftX = mpValX;
        else
            mpText = formatBarValueText(memInfo.mp, memInfo.maxmp, mpPercent, mpMode);
            local mpW = imgui.CalcTextSize(mpText);
            mpValX = hpStartX + entryWidth - mpW + 2;          -- SC_VALUE_NUM_OFFSET
            mpValueLeftX = mpValX;
        end

        -- (2) MP bar — drawn FIRST so HP bar can layer over its top
        if showMpBar then
            imgui.SetCursorScreenPos({mpBarStartX, mpRowY});
            local mpGradient = GetCustomGradient(cache.colors, 'mpGradient') or {'#9abb5a', '#bfe07d'};
            progressbar.ProgressBar(
                {{memInfo.mpp, mpGradient}},
                {mpBarWidth, mpBarHeight},
                {
                    decorate                  = cache.showBookends,
                    backgroundGradientOverride = data.getBarBackgroundOverride(partyIndex),
                    borderColorOverride       = data.getBarBorderOverride(partyIndex),
                }
            );
        end

        -- (3) HP bar — drawn AFTER MP bar; its bottom covers MP bar's top sliver
        imgui.SetCursorScreenPos({barAreaLeft, hpStartY});
        progressbar.ProgressBar(
            {{memInfo.hpp, hpGradient}},
            {hpBarWidth, hpBarHeight},
            {
                decorate                  = cache.showBookends,
                backgroundGradientOverride = data.getBarBackgroundOverride(partyIndex),
                borderColorOverride       = data.getBarBorderOverride(partyIndex),
            }
        );

        -- (4) MP value overlay (right edge of entry, vertically centered on MP bar)
        if showMpBar then
            local mpY = mpRowY + (mpBarHeight - mpRowTextH) / 2;
            if mpSplit then
                drawOutlinedText(mpValX,  mpY, mpValStr,  {1, 1, 1, 1});
                drawOutlinedText(mpSuffX, mpY, mpSuffStr, {1, 1, 1, 1});
            else
                drawOutlinedText(mpValX, mpY, mpText, {1, 1, 1, 1});
            end
        end

        -- (5) Name overlay + (6) HP value overlay — same Y (entryTop). Both sit
        -- above the HP bar but dip SC_NAME_BAR_OVERLAP px into the bar's top.
        -- Name renders before HP value so HP value layers on top if they collide.
        --
        -- HP value rendering: 'both' and 'both_percent_first' modes use SPLIT
        -- rendering — value and "(NN%)" drawn as two separate texts with a
        -- ~2 px gap between (visually a half-space). The suffix bbox is pushed
        -- past content-right by SC_VALUE_BOTH_OFFSET to compensate for the ')'
        -- glyph's trailing whitespace AND to bring the visible ')' near the
        -- panel border. 'number'-style modes use SC_VALUE_NUM_OFFSET for the
        -- same visual right-edge.
        do
            local SC_VALUE_NUM_OFFSET  = 2;   -- 'number' mode: push 2 px past content_right
            local SC_VALUE_BOTH_OFFSET = 6;   -- 'both' mode: push suffix 6 px past content_right
            local hpMode = cache.hpDisplayMode or 'number';
            local hpPercent = math.floor(memInfo.hpp * 100);
            local hpColor = {1, 1, 1, 1};

            if hpMode == 'both' or hpMode == 'both_percent_first' then
                local valStr, suffStr;
                if hpMode == 'both' then
                    valStr  = tostring(memInfo.hp);
                    suffStr = '(' .. tostring(hpPercent) .. '%)';
                else
                    valStr  = tostring(hpPercent) .. '%';
                    suffStr = '(' .. tostring(memInfo.hp) .. ')';
                end
                local valW  = imgui.CalcTextSize(valStr);
                local suffW = imgui.CalcTextSize(suffStr);
                local suffX = hpStartX + entryWidth - suffW + SC_VALUE_BOTH_OFFSET;
                local valX  = suffX - 2 - valW;
                drawOutlinedText(valX,  entryTop, valStr,  hpColor);
                drawOutlinedText(suffX, entryTop, suffStr, hpColor);
            else
                local hpText = formatBarValueText(memInfo.hp, memInfo.maxhp, hpPercent, hpMode);
                local hpW = imgui.CalcTextSize(hpText);
                drawOutlinedText(hpStartX + entryWidth - hpW + SC_VALUE_NUM_OFFSET, entryTop, hpText, hpColor);
            end

            -- Leader / Alliance / Sync dots BEFORE the name so the name (added
            -- next on the same foreground list) covers any overlap with the
            -- player name's first letter / right edge.
            drawMemberDots();

            -- Name truncation: 10 chars or fewer render in full (so "Cowrevenge"
            -- fits as-is); 11+ render as the first 8 chars + '..'.
            local nameStr = tostring(memInfo.name or '');
            if #nameStr > 10 then
                nameStr = nameStr:sub(1, 8) .. '..';
            end
            drawOutlinedText(nameStartX, entryTop, nameStr, hpColor);
        end

        -- (7) TP — drawn LAST so it sits on top of everything. Right-aligned 2 px
        -- LEFT of whichever comes first: the MP bar's left edge OR the MP value
        -- text's left edge. For wide MP values that extend past the bar's left
        -- edge, TP still stays clear of the text — no more "062" smush in alliance.
        --
        -- Color: blue below 1000 (low TP), white at 1000+, flash color if TP is
        -- at 1000+ AND flashTP is enabled.
        do
            local tpText = tostring(memInfo.tp or 0);
            local tpW    = imgui.CalcTextSize(tpText);
            local tpColor;
            if memInfo.tp >= 1000 and (cache.flashTP or cache.rainbowTP) then
                tpColor = argbToRgbaTable(computeTpColorARGB(memInfo, cache));
            elseif memInfo.tp < 1000 then
                tpColor = {0.4, 0.7, 1.0, 1.0};  -- blue
            else
                tpColor = {1, 1, 1, 1};          -- white at 1000+ without flash
            end
            local tpAnchor = (showMpBar and math.min(mpBarStartX, mpValueLeftX)) or mpBarStartX;
            drawOutlinedText(tpAnchor - tpW - 2, mpRowY + (mpBarHeight - mpRowTextH) / 2, tpText, tpColor);
        end

        -- Advance imgui cursor past the entry block so the next member draws below.
        imgui.SetCursorScreenPos({hpStartX, entryTop + entryHeight});
        imgui.Dummy({entryWidth + settings.cursorPaddingX2, 0});
    end

    -- Target arrow cursor (subtarget / target). Same texture and tint logic as
    -- layout 0/1 — vertical center of the entry, left of the selection box.
    if (memInfo.targeted and not GetSubTargetActive()) or memInfo.subTargeted then
        local cursorTexture = data.cursorTextures[cache.cursor];
        if cursorTexture ~= nil then
            local cursorImage  = tonumber(ffi.cast('uint32_t', cursorTexture.image));
            local cursorWidth  = cursorTexture.width  * settings.arrowSize;
            local cursorHeight = cursorTexture.height * settings.arrowSize;
            local cursorX_     = hpStartX - settings.cursorPaddingX1 - cursorWidth;
            local cursorY_     = entryTop + (entryHeight / 2) - (cursorHeight / 2);
            local tintColor;
            if memInfo.subTargeted then
                tintColor = ARGBToABGR(cache.subtargetArrowTint);
            else
                tintColor = ARGBToABGR(cache.targetArrowTint);
            end
            GetUIDrawList():AddImage(
                cursorImage,
                {cursorX_, cursorY_},
                {cursorX_ + cursorWidth, cursorY_ + cursorHeight},
                {0, 0}, {1, 1},
                tintColor
            );
            data.partySubTargeted = true;
        end
    end

    -- Combined buffs+debuffs window (Party A only — alliance parties don't show status).
    -- Status window docks on the LEFT of the bars when statusSide == 0; hpStartX
    -- is the bar's left edge, so the icons sit just left of the bar/panel.
    if partyIndex == 1 then
        drawSuperCompactStatus(memIdx, memInfo, partyIndex, cache, settings, hpStartX, hpStartY);
    end

    -- Click-to-target: manual click-vs-drag detection (no InvisibleButton, so
    -- window-drag isn't blocked). On mouse release, GetMouseDragDelta(0, 4)
    -- returns (0,0) if the user didn't drag past 4 px during the press → click
    -- → fire /target if cursor is inside the entry bbox. If the user dragged,
    -- ImGui handled the window-drag and we don't interfere.
    if memInfo.inzone and not showConfig[1] and gConfig.enablePartyListClickTarget ~= false then
        if imgui.IsMouseReleased(0) then
            local dx, dy = imgui.GetMouseDragDelta(0, 4);
            if (dx == 0 and dy == 0) then
                local mx, my = imgui.GetMousePos();
                if mx >= hpStartX and mx <= hpStartX + entryWidth
                   and my >= entryTop and my <= entryTop + entryHeight then
                    -- Sub-target mode (e.g., /ma "Cure" <stpc>): don't fire
                    -- /target - it would cancel the sub-target context and
                    -- rebind main. Instead, simulate arrow-key presses to
                    -- walk the game's own sub-target cursor to this row.
                    -- Player still presses Enter themselves to confirm.
                    if data.frameCache.subTargetActive then
                        st_walk_to(memIdx);
                    else
                        AshitaCore:GetChatManager():QueueCommand(-1, '/target ' .. memInfo.serverid);
                    end
                end
            end
        end
    end

    imgui.Unindent(settings.cursorPaddingX1);

    -- Inter-member spacing (same convention as layout 0/1).
    if not isLastVisibleMember then
        local BASE_MEMBER_SPACING = 4;
        imgui.Dummy({0, BASE_MEMBER_SPACING + (settings.entrySpacing and settings.entrySpacing[partyIndex] or 0)});
    end
end

-- ============================================
-- DrawMember - Render a single party member
-- ============================================
function display.DrawMember(memIdx, settings, isLastVisibleMember)
    local memInfo = data.GetMemberInformation(memIdx);
    if (memInfo == nil) then
        memInfo = {
            hp = 0, hpp = 0, maxhp = 0,
            mp = 0, mpp = 0, maxmp = 0,
            tp = 0, job = '', level = '',
            subjob = '', subjoblevel = '',
            targeted = false, serverid = 0,
            buffs = nil, sync = false,
            subTargeted = false, zone = '',
            inzone = false, name = '', leader = false, allianceLeader = false
        };
    end

    local partyIndex = math.ceil((memIdx + 1) / data.partyMaxSize);
    local cache = data.partyConfigCache[partyIndex];
    local scale = data.getScale(partyIndex);
    local showTP = data.showPartyTP(partyIndex);

    -- Check if this job has MP (considers main job and sub job)
    local jobHasMP = JobHasMP(memInfo.job, memInfo.subjob);

    local subTargetActive = GetSubTargetActive();

    -- Get HP colors
    local hpNameColor, hpGradient = GetCustomHpColors(memInfo.hpp, cache.colors);

    local layout = cache.layout or 0;

    -- Layout 2 (Super Compact) has its own self-contained render path. Branch out
    -- before any of the layout 0/1-specific setup so we don't allocate fonts /
    -- color caches / interpolation state that the super compact path doesn't use.
    if layout == 2 then
        return display.DrawMemberSuperCompact(memIdx, settings, isLastVisibleMember);
    end

    local barScales = data.getBarScales(partyIndex);
    local layoutTemplate = data.getLayoutTemplate(partyIndex);
    local textOffsets = data.getTextOffsets(partyIndex);

    -- Layout 1 (Compact Vertical) overlays HP/MP/TP text on the bars. Force those text
    -- colors to white so the values stay legible against the gradient. Other color keys
    -- (name, cast, gradients, etc.) fall through to the user-configured values.
    if layout == 1 then
        local origColors = cache.colors;
        cache = setmetatable({}, {__index = cache});
        cache.colors = setmetatable({
            hpTextColor      = 0xFFFFFFFF,
            mpTextColor      = 0xFFFFFFFF,
            tpFullTextColor  = 0xFFFFFFFF,
            tpEmptyTextColor = 0xFFFFFFFF,
        }, {__index = origColors});
    end

    -- Get base bar dimensions
    local baseHpBarWidth = (layoutTemplate.hpBarWidth or settings.hpBarWidth or 150) * PARTY_BAR_BASE_WIDTH_MULT;
    local baseMpBarWidth = (layoutTemplate.mpBarWidth or settings.mpBarWidth or 100) * PARTY_BAR_BASE_WIDTH_MULT;
    local baseTpBarWidth = (layoutTemplate.tpBarWidth or settings.tpBarWidth or 100) * PARTY_BAR_BASE_WIDTH_MULT;
    local baseBarHeight = layoutTemplate.barHeight or settings.barHeight or 20;

    -- Apply bar scales
    local hpBarWidth, mpBarWidth, tpBarWidth, hpBarHeight, mpBarHeight, tpBarHeight;
    if barScales then
        hpBarWidth = baseHpBarWidth * scale.x * barScales.hpBarScaleX;
        mpBarWidth = baseMpBarWidth * scale.x * barScales.mpBarScaleX;
        tpBarWidth = baseTpBarWidth * scale.x * barScales.tpBarScaleX;
        hpBarHeight = baseBarHeight * scale.y * barScales.hpBarScaleY;
        mpBarHeight = baseBarHeight * scale.y * barScales.mpBarScaleY;
        tpBarHeight = baseBarHeight * scale.y * barScales.tpBarScaleY;
    else
        hpBarWidth = baseHpBarWidth * scale.x;
        mpBarWidth = baseMpBarWidth * scale.x;
        tpBarWidth = baseTpBarWidth * scale.x;
        hpBarHeight = baseBarHeight * scale.y;
        mpBarHeight = baseBarHeight * scale.y;
        tpBarHeight = baseBarHeight * scale.y;
    end
    local barHeight = baseBarHeight * scale.y;

    -- Layout 1 (HXUI): shorten the HP/MP bars (developer default). Done HERE,
    -- before allBarsLengths / selection-box / overlay geometry is derived, so
    -- everything downstream uses the shortened widths consistently.
    --   MP bar gets an additional 10% trim on top of HX_BAR_WIDTH_MULT so it
    -- reads visually shorter than the HP bar (per user preference).
    if layout == 1 then
        hpBarWidth = hpBarWidth * HX_BAR_WIDTH_MULT;
        mpBarWidth = mpBarWidth * HX_BAR_WIDTH_MULT * 0.9;
    end

    local hpStartX, hpStartY = imgui.GetCursorScreenPos();

    local fontSizes = data.getFontSizes(partyIndex);

    -- Set font heights
    data.memberText[memIdx].hp:set_font_height(fontSizes.hp);
    data.memberText[memIdx].mp:set_font_height(fontSizes.mp);
    data.memberText[memIdx].name:set_font_height(fontSizes.name);
    data.memberText[memIdx].tp:set_font_height(fontSizes.tp);
    data.memberText[memIdx].distance:set_font_height(fontSizes.distance);
    data.memberText[memIdx].zone:set_font_height(fontSizes.zone);

    -- Get reference heights
    local refHeights = data.partyRefHeights[partyIndex];
    local hpRefHeight = refHeights.hpRefHeight;
    local mpRefHeight = refHeights.mpRefHeight;
    local tpRefHeight = refHeights.tpRefHeight;
    local nameRefHeight = refHeights.nameRefHeight;

    -- Calculate text sizes (use cached text to avoid texture regeneration)
    local nameText = tostring(memInfo.name);
    setCachedText(memIdx, 'name', data.memberText[memIdx].name, nameText);
    local nameWidth, nameHeight = data.memberText[memIdx].name:get_text_size();

    -- Format HP text based on display mode
    local hpDisplayText;
    local hpDisplayMode = cache.hpDisplayMode or 'number';
    local hpPercent = math.floor(memInfo.hpp * 100);
    if hpDisplayMode == 'percent' then
        hpDisplayText = tostring(hpPercent) .. '%';
    elseif hpDisplayMode == 'both' then
        hpDisplayText = tostring(memInfo.hp) .. ' (' .. tostring(hpPercent) .. '%)';
    elseif hpDisplayMode == 'both_percent_first' then
        hpDisplayText = tostring(hpPercent) .. '% (' .. tostring(memInfo.hp) .. ')';
    elseif hpDisplayMode == 'current_max' then
        hpDisplayText = tostring(memInfo.hp) .. '/' .. tostring(memInfo.maxhp);
    else
        hpDisplayText = tostring(memInfo.hp);
    end
    setCachedText(memIdx, 'hp', data.memberText[memIdx].hp, hpDisplayText);
    local hpTextWidth, hpHeight = data.memberText[memIdx].hp:get_text_size();

    -- Format MP text based on display mode
    local mpDisplayText;
    local mpDisplayMode = cache.mpDisplayMode or 'number';
    local mpPercent = math.floor(memInfo.mpp * 100);
    if mpDisplayMode == 'percent' then
        mpDisplayText = tostring(mpPercent) .. '%';
    elseif mpDisplayMode == 'both' then
        mpDisplayText = tostring(memInfo.mp) .. ' (' .. tostring(mpPercent) .. '%)';
    elseif mpDisplayMode == 'both_percent_first' then
        mpDisplayText = tostring(mpPercent) .. '% (' .. tostring(memInfo.mp) .. ')';
    elseif mpDisplayMode == 'current_max' then
        mpDisplayText = tostring(memInfo.mp) .. '/' .. tostring(memInfo.maxmp);
    else
        mpDisplayText = tostring(memInfo.mp);
    end
    setCachedText(memIdx, 'mp', data.memberText[memIdx].mp, mpDisplayText);
    local mpTextWidth, mpHeight = data.memberText[memIdx].mp:get_text_size();

    local tpText = tostring(memInfo.tp);
    setCachedText(memIdx, 'tp', data.memberText[memIdx].tp, tpText);
    local tpTextWidth, tpHeight = data.memberText[memIdx].tp:get_text_size();

    -- Calculate max TP text width for Layout 1 (cached per party to avoid per-frame texture regen)
    local maxTpTextWidth = tpTextWidth;
    if layout == 1 then
        if not data.maxTpTextWidthCache[partyIndex] then
            -- Calculate once: temporarily set to "3000", get width, restore
            data.memberText[memIdx].tp:set_text("3000");
            data.maxTpTextWidthCache[partyIndex], _ = data.memberText[memIdx].tp:get_text_size();
            data.memberText[memIdx].tp:set_text(tpText);
        end
        maxTpTextWidth = data.maxTpTextWidthCache[partyIndex];
    end

    -- Calculate allBarsLengths based on layout
    -- This should be consistent across all party members for uniform zone bar/selection width
    local allBarsLengths;
    if layout == 1 then
        -- Layout 1: TP and MP text are overlaid on the MP bar (which is right-aligned with
        -- the HP bar), so both rows occupy at most hpBarWidth of horizontal space.
        allBarsLengths = hpBarWidth;
    else
        -- Always include HP + MP + TP space for consistent width across all members
        allBarsLengths = hpBarWidth + mpBarWidth + imgui.GetStyle().FramePadding.x + imgui.GetStyle().ItemSpacing.x;
        if (showTP) then
            allBarsLengths = allBarsLengths + tpBarWidth + imgui.GetStyle().FramePadding.x + imgui.GetStyle().ItemSpacing.x;
        end
    end

    -- Calculate layout dimensions
    local jobIconSize = cache.showJobIcon and (settings.baseIconSize * 1.1 * scale.icon) or 0;
    -- Layout 1 uses a fixed developer-default icon size, INDEPENDENT of the bar
    -- position (so a bigger icon never pushes the bars). The icon overflows to
    -- the left / overlaps as needed; the name is drawn on top of it.
    local hxIconSize = 0;
    if layout == 1 and cache.showJobIcon then
        hxIconSize = settings.baseIconSize * HX_ICON_SIZE_MULT * scale.icon;
    end

    local offsetSize = nameRefHeight > settings.baseIconSize and nameRefHeight or settings.baseIconSize;
    local nameIconAreaHeight = math.max(jobIconSize, nameRefHeight);

    -- HXUI-style Compact Vertical (layout 1): the bars start just to the RIGHT
    -- of the job icon so the icon never renders under them. The inset is the
    -- icon width plus a small gap. (The icon size itself is a fixed developer
    -- default; the bars simply begin after it.)
    local hpDrawX = hpStartX;
    if layout == 1 then
        local iconClear = (hxIconSize > 0) and hxIconSize or 0;
        hpDrawX = hpStartX + iconClear + (HX_BAR_INSET * scale.x);
    end

    -- Stash the player slot's HP bar screen geometry so the target window
    -- (DrawCurrentTarget) can align its HP bar to exactly the same pixels.
    -- Computed from the actual draw positions, so it stays correct across
    -- layout changes / anchor moves / scale changes without us having to
    -- duplicate the math. Only the player slot (memIdx 0) is needed since
    -- the target window always anchors above party 1.
    if memIdx == 0 then
        data.frameCache.playerHpBarLeft  = hpDrawX;
        data.frameCache.playerHpBarRight = hpDrawX + hpBarWidth;
    end

    -- Calculate entryHeight based on layout
    local entryHeight;
    if layout == 1 then
        -- HXUI look: name is overlaid ON the HP bar (no separate name row above),
        -- so the entry is just the two bars stacked.
        entryHeight = hpBarHeight + 1 + mpBarHeight;
    else
        entryHeight = nameRefHeight + settings.nameTextOffsetY + hpBarHeight + settings.hpTextOffsetY + hpRefHeight;
    end

    -- Per-player alternating band (layout 1 only). Every other PLAYER (memIdx
    -- parity) gets a subtle lighter overlay across the full entry, behind the
    -- selection box and bars. Same edge geometry as the selection box: from the
    -- icon's left to the bar's right edge, spanning the bar stack.
    -- Per-player alternating band (layout 1): full entry, icon-left to bar-right.
    if layout == 1 then
        drawAlternatingBand(memIdx, cache,
            hpStartX - settings.cursorPaddingX1, hpStartY,
            hpDrawX + hpBarWidth + settings.cursorPaddingX2, hpStartY + entryHeight);
    elseif layout == 0 then
        -- Layout 0 (Horizontal): entry spans the full bar row; the name row sits
        -- above (topOfMember). Cover from the left edge across allBarsLengths.
        local l0Top = hpStartY - nameRefHeight - settings.nameTextOffsetY;
        drawAlternatingBand(memIdx, cache,
            hpStartX - settings.cursorPaddingX1, l0Top,
            hpStartX + allBarsLengths + settings.cursorPaddingX2, l0Top + entryHeight);
    end

    -- Draw selection box
    if (memInfo.targeted == true or memInfo.subTargeted) then
        -- Layout 1: use the global foreground draw list so the box is unclipped
        -- (the window draw list clips to the content rect and cuts the box's side
        -- halo). Other layouts keep the background list, which lines up correctly.
        local drawList = (layout == 1) and imgui.GetForegroundDrawList() or imgui.GetBackgroundDrawList();

        local selectionWidth = allBarsLengths + settings.cursorPaddingX1 + settings.cursorPaddingX2;
        local selectionScaleY = cache.selectionBoxScaleY or 1;
        local selectionOffsetY = cache.selectionBoxOffsetY or 0;
        local unscaledHeight = entryHeight + settings.cursorPaddingY1 + settings.cursorPaddingY2;
        local selectionHeight = unscaledHeight * selectionScaleY;
        local selBottomTrim = 0;  -- layout 1: pull ONLY the bottom edge up
        local topOfMember, selLeftX;
        if layout == 1 then
            -- HXUI: no name row above; entry spans just the bar stack from hpStartY.
            -- Anchor the box to the KNOWN edges instead of building width additively:
            --   left  = icon left edge - left padding
            --   right = bar right edge (hpDrawX + hpBarWidth) + right padding
            -- This makes the box exactly fit the drawn content with no guesswork.
            topOfMember = hpStartY;
            selLeftX = hpStartX - settings.cursorPaddingX1;
            local selRightX = hpDrawX + hpBarWidth + settings.cursorPaddingX2;
            selectionWidth = selRightX - selLeftX;
            -- Trim the BOTTOM only (top edge is correct); applied after
            -- centerOffsetY below so it doesn't move the top.
            selBottomTrim = HX_SEL_TRIM_H * scale.y;
        else
            topOfMember = hpStartY - nameRefHeight - settings.nameTextOffsetY;
            selLeftX = hpStartX - settings.cursorPaddingX1;
        end
        local centerOffsetY = (selectionHeight - unscaledHeight) / 2;
        -- Apply the bottom-only trim AFTER centering so only the bottom edge moves up.
        selectionHeight = selectionHeight - selBottomTrim;
        local selectionTL = {selLeftX, topOfMember - settings.cursorPaddingY1 - centerOffsetY + selectionOffsetY};
        local selectionBR = {selectionTL[1] + selectionWidth, selectionTL[2] + selectionHeight};

        local selectionGradient;
        local borderColorARGB;
        if memInfo.subTargeted then
            selectionGradient = GetCustomGradient(cache.colors, 'subtargetGradient') or {'#d9a54d', '#edcf78'};
            borderColorARGB = cache.colors.subtargetBorderColor or 0xFFfdd017;
        else
            selectionGradient = GetCustomGradient(cache.colors, 'selectionGradient') or {'#4da5d9', '#78c0ed'};
            borderColorARGB = cache.colors.selectionBorderColor;
        end
        local startColor = HexToImGui(selectionGradient[1]);
        local endColor = HexToImGui(selectionGradient[2]);

        -- Draw selection box (gradient + border) if enabled
        if cache.showSelectionBox then
            -- Draw gradient effect (4 steps for performance, reuse tables)
            local gradientSteps = 4;
            local stepHeight = selectionHeight / gradientSteps;
            local selX1 = selectionTL[1];
            local selX2 = selectionBR[1];
            local selY1 = selectionTL[2];
            for i = 1, gradientSteps do
                local t = (i - 1) / (gradientSteps - 1);
                local r = startColor[1] + (endColor[1] - startColor[1]) * t;
                local g = startColor[2] + (endColor[2] - startColor[2]) * t;
                local b = startColor[3] + (endColor[3] - startColor[3]) * t;
                -- Layout 1 draws the box ON TOP of the bars (foreground list), so use
                -- a much lighter fill or it washes the bars out. Other layouts draw
                -- behind, so it keeps the stronger fill.
                local alpha;
                if layout == 1 then
                    alpha = 0.18 - t * 0.13;
                else
                    alpha = 0.35 - t * 0.25;
                end

                local stepColor = imgui.GetColorU32({r, g, b, alpha});
                local stepTL_y = selY1 + (i - 1) * stepHeight;
                local stepBR_y = stepTL_y + stepHeight;

                if i == 1 then
                    drawList:AddRectFilled({selX1, stepTL_y}, {selX2, stepBR_y}, stepColor, 6, 3);
                elseif i == gradientSteps then
                    drawList:AddRectFilled({selX1, stepTL_y}, {selX2, stepBR_y}, stepColor, 6, 12);
                else
                    drawList:AddRectFilled({selX1, stepTL_y}, {selX2, stepBR_y}, stepColor, 0);
                end
            end

            -- Draw border
            local borderColor;
            if memInfo.subTargeted then
                if data.cachedSubtargetBorderColorARGB ~= borderColorARGB then
                    data.cachedSubtargetBorderColorARGB = borderColorARGB;
                    data.cachedSubtargetBorderColorU32 = ARGBToU32(borderColorARGB);
                end
                borderColor = data.cachedSubtargetBorderColorU32;
            else
                if data.cachedBorderColorARGB ~= borderColorARGB then
                    data.cachedBorderColorARGB = borderColorARGB;
                    data.cachedBorderColorU32 = ARGBToU32(borderColorARGB);
                end
                borderColor = data.cachedBorderColorU32;
            end
            drawList:AddRect({selectionTL[1], selectionTL[2]}, {selectionBR[1], selectionBR[2]}, borderColor, 6, 15, 2);
        end

        data.partyTargeted = true;
    end

    -- Draw job icon
    local namePosX = hpStartX;
    local distanceBaseX = hpStartX; -- Base X for distance text (independent of name offsets)
    if cache.showJobIcon then
        local jobIcon = statusHandler.GetJobIcon(memInfo.job);
        if (jobIcon ~= nil) then
            local jobIconPtr = tonumber(ffi.cast("uint32_t", jobIcon));
            -- Draw order target: Background -> Bars -> Job icon -> Text -> Status
            -- circles. The job icon goes on the WINDOW draw list (not foreground).
            -- Bars are also on the window list and submitted earlier in the frame,
            -- so the icon composites ABOVE the bars. The name/HP text and the
            -- status circles (foreground list) composite ABOVE the icon.
            local draw_list = imgui.GetWindowDrawList();
            if layout == 1 then
                -- HXUI Compact Vertical: bigger fixed-size icon (hxIconSize),
                -- vertically centered against the HP+MP bar stack. Positioned so
                -- it sits at the far left and is allowed to overlap; the name is
                -- drawn ON TOP of it (below). Icon size does NOT affect the bars.
                local iconSz = (hxIconSize > 0) and hxIconSize or jobIconSize;
                local barsStackH = hpBarHeight + 1 + mpBarHeight;
                local iconY = hpStartY + (barsStackH - iconSz) / 2;
                draw_list:AddImage(
                    jobIconPtr,
                    {hpStartX, iconY},
                    {hpStartX + iconSz, iconY + iconSz},
                    {0, 0}, {1, 1},
                    IM_COL32_WHITE
                );
            else
                local offsetStartY = hpStartY - jobIconSize - settings.nameTextOffsetY;
                namePosX = namePosX + jobIconSize + settings.nameTextOffsetX;
                distanceBaseX = distanceBaseX + jobIconSize; -- Only add job icon width, not name offset
                draw_list:AddImage(
                    jobIconPtr,
                    {hpStartX, offsetStartY},
                    {hpStartX + jobIconSize, offsetStartY + jobIconSize},
                    {0, 0}, {1, 1},
                    IM_COL32_WHITE
                );
            end
        end
    end

    -- Update HP text color
    if not data.memberTextColorCache[memIdx] then data.memberTextColorCache[memIdx] = {}; end
    if (data.memberTextColorCache[memIdx].hp ~= cache.colors.hpTextColor) then
        data.memberText[memIdx].hp:set_font_color(cache.colors.hpTextColor);
        data.memberTextColorCache[memIdx].hp = cache.colors.hpTextColor;
    end

    -- HP Interpolation logic
    local currentTime = os.clock();
    local hppPercent = memInfo.hpp * 100;

    if not data.memberInterpolation[memIdx] then
        data.memberInterpolation[memIdx] = {
            currentHpp = hppPercent,
            interpolationDamagePercent = 0,
            interpolationHealPercent = 0
        };
    end

    local interp = data.memberInterpolation[memIdx];

    -- Handle damage
    if hppPercent < interp.currentHpp then
        local previousInterpolationDamagePercent = interp.interpolationDamagePercent;
        local damageAmount = interp.currentHpp - hppPercent;

        interp.interpolationDamagePercent = interp.interpolationDamagePercent + damageAmount;

        if previousInterpolationDamagePercent > 0 and interp.lastHitAmount and damageAmount > interp.lastHitAmount then
            interp.lastHitTime = currentTime;
            interp.lastHitAmount = damageAmount;
        elseif previousInterpolationDamagePercent == 0 then
            interp.lastHitTime = currentTime;
            interp.lastHitAmount = damageAmount;
        end

        if not interp.lastHitTime or currentTime > interp.lastHitTime + (settings.hitFlashDuration * 0.25) then
            interp.lastHitTime = currentTime;
            interp.lastHitAmount = damageAmount;
        end

        if previousInterpolationDamagePercent == 0 then
            interp.hitDelayStartTime = currentTime;
        end

        interp.interpolationHealPercent = 0;
        interp.healDelayStartTime = nil;
    elseif hppPercent > interp.currentHpp then
        -- Handle healing
        local previousInterpolationHealPercent = interp.interpolationHealPercent;
        local healAmount = hppPercent - interp.currentHpp;

        interp.interpolationHealPercent = interp.interpolationHealPercent + healAmount;

        if previousInterpolationHealPercent > 0 and interp.lastHealAmount and healAmount > interp.lastHealAmount then
            interp.lastHealTime = currentTime;
            interp.lastHealAmount = healAmount;
        elseif previousInterpolationHealPercent == 0 then
            interp.lastHealTime = currentTime;
            interp.lastHealAmount = healAmount;
        end

        if not interp.lastHealTime or currentTime > interp.lastHealTime + (settings.hitFlashDuration * 0.25) then
            interp.lastHealTime = currentTime;
            interp.lastHealAmount = healAmount;
        end

        if previousInterpolationHealPercent == 0 then
            interp.healDelayStartTime = currentTime;
        end

        interp.interpolationDamagePercent = 0;
        interp.hitDelayStartTime = nil;
    end

    interp.currentHpp = hppPercent;

    local interpolationOverlayAlpha = 0;
    local healInterpolationOverlayAlpha = 0;

    local hasDamageInterp = interp.interpolationDamagePercent > 0;
    local hasHealInterp = interp.interpolationHealPercent > 0;
    local hasActiveFlash = gConfig.healthBarFlashEnabled and (
        (interp.lastHitTime and currentTime < interp.lastHitTime + settings.hitFlashDuration) or
        (interp.lastHealTime and currentTime < interp.lastHealTime + settings.hitFlashDuration)
    );

    if hasDamageInterp or hasHealInterp or hasActiveFlash then
        if hasDamageInterp and interp.hitDelayStartTime and currentTime > interp.hitDelayStartTime + settings.hitDelayDuration then
            if interp.lastFrameTime then
                local deltaTime = currentTime - interp.lastFrameTime;
                local animSpeed = 0.1 + (0.9 * (interp.interpolationDamagePercent / 100));
                interp.interpolationDamagePercent = math.max(0, interp.interpolationDamagePercent - (settings.hitInterpolationDecayPercentPerSecond * deltaTime * animSpeed));
            end
        end

        if hasHealInterp and interp.healDelayStartTime and currentTime > interp.healDelayStartTime + settings.hitDelayDuration then
            if interp.lastFrameTime then
                local deltaTime = currentTime - interp.lastFrameTime;
                local animSpeed = 0.1 + (0.9 * (interp.interpolationHealPercent / 100));
                interp.interpolationHealPercent = math.max(0, interp.interpolationHealPercent - (settings.hitInterpolationDecayPercentPerSecond * deltaTime * animSpeed));
            end
        end

        if gConfig.healthBarFlashEnabled and interp.lastHitTime and currentTime < interp.lastHitTime + settings.hitFlashDuration then
            local hitFlashTime = currentTime - interp.lastHitTime;
            local hitFlashTimePercent = hitFlashTime / settings.hitFlashDuration;
            local maxAlphaHitPercent = 20;
            local maxAlpha = math.min(interp.lastHitAmount, maxAlphaHitPercent) / maxAlphaHitPercent;
            maxAlpha = math.max(maxAlpha * 0.6, 0.4);
            interpolationOverlayAlpha = math.pow(1 - hitFlashTimePercent, 2) * maxAlpha;
        end

        if gConfig.healthBarFlashEnabled and interp.lastHealTime and currentTime < interp.lastHealTime + settings.hitFlashDuration then
            local healFlashTime = currentTime - interp.lastHealTime;
            local healFlashTimePercent = healFlashTime / settings.hitFlashDuration;
            local maxAlphaHealPercent = 20;
            local maxAlpha = math.min(interp.lastHealAmount, maxAlphaHealPercent) / maxAlphaHealPercent;
            maxAlpha = math.max(maxAlpha * 0.6, 0.4);
            healInterpolationOverlayAlpha = math.pow(1 - healFlashTimePercent, 2) * maxAlpha;
        end
    end

    interp.lastFrameTime = currentTime;

    -- HXUI Compact Vertical: shift the bar draw cursor right past the left job
    -- icon. Only layout 1; other layouts keep drawing at hpStartX.
    if layout == 1 and hpDrawX ~= hpStartX then
        imgui.SetCursorScreenPos({hpDrawX, hpStartY});
    end

    -- Build HP bar data
    local baseHpp = memInfo.hpp;
    if interp.interpolationHealPercent and interp.interpolationHealPercent > 0 then
        local hppInPercent = memInfo.hpp * 100;
        hppInPercent = hppInPercent - interp.interpolationHealPercent;
        hppInPercent = math.max(0, hppInPercent);
        baseHpp = hppInPercent / 100;
    end

    local hpPercentData = {{baseHpp, hpGradient}};
    local interpColors = GetHpInterpolationColors();

    if interp.interpolationDamagePercent and interp.interpolationDamagePercent > 0 then
        local interpolationOverlay;
        if gConfig.healthBarFlashEnabled and interpolationOverlayAlpha > 0 then
            interpolationOverlay = {
                interpColors.damageFlashColor,
                interpolationOverlayAlpha
            };
        end
        table.insert(hpPercentData, {
            interp.interpolationDamagePercent / 100,
            interpColors.damageGradient,
            interpolationOverlay
        });
    end

    if interp.interpolationHealPercent and interp.interpolationHealPercent > 0 then
        local healInterpolationOverlay;
        if gConfig.healthBarFlashEnabled and healInterpolationOverlayAlpha > 0 then
            healInterpolationOverlay = {
                interpColors.healFlashColor,
                healInterpolationOverlayAlpha
            };
        end
        table.insert(hpPercentData, {
            interp.interpolationHealPercent / 100,
            interpColors.healGradient,
            healInterpolationOverlay
        });
    end

    -- Draw HP bar
    if (memInfo.inzone) then
        progressbar.ProgressBar(hpPercentData, {hpBarWidth, hpBarHeight}, {decorate = cache.showBookends, backgroundGradientOverride = data.getBarBackgroundOverride(partyIndex), borderColorOverride = data.getBarBorderOverride(partyIndex)});
        -- Layout 1: overlay HP text on the bar. Drawn AFTER the bar so it renders on top
        -- (gdifont primitive for HP is hidden in layout 1; see set_visible block below).
        if layout == 1 then
            local hpW, hpH2 = imgui.CalcTextSize(hpDisplayText);
            local hpOvX = hpDrawX + hpBarWidth - hpW - 4;
            local hpOvY = hpStartY + (hpBarHeight - hpH2) / 2;
            drawOutlinedText(hpOvX, hpOvY, hpDisplayText, {1, 1, 1, 1});
        end
        data.memberText[memIdx].zone:set_visible(false);
    elseif (memInfo.zone == '' or memInfo.zone == nil) then
        local zoneBarWidth = allBarsLengths;
        local zoneBarHeight;
        if layout == 1 then
            zoneBarHeight = hpBarHeight + 1 + mpBarHeight;
        else
            zoneBarHeight = hpBarHeight;
        end
        imgui.Dummy({zoneBarWidth, zoneBarHeight});
        data.memberText[memIdx].zone:set_visible(false);
    else
        local zoneBarWidth = allBarsLengths;
        local zoneBarHeight;
        if layout == 1 then
            zoneBarHeight = hpBarHeight + 1 + mpBarHeight;
        else
            zoneBarHeight = hpBarHeight;
        end

        local zoneBarStartX, zoneBarStartY = imgui.GetCursorScreenPos();
        imgui.Dummy({zoneBarWidth, zoneBarHeight});

        local zoneName = encoding:ShiftJIS_To_UTF8(AshitaCore:GetResourceManager():GetString("zones.names", memInfo.zone), true);
        -- Abbreviate to fit the cramped bar area; full names like
        -- "Lower Delkfutt's Tower" overflow the HP+MP bar block.
        zoneName = shortenZoneName(zoneName);
        -- The imgui window background sits over gdifont primitives and washes
        -- the zone name out. Draw it via imgui so it lands on top of the bg.
        -- Guarded: GetString can return nil for an unknown zone id, and
        -- CalcTextSize(nil) throws — which inside this window's push/Begin
        -- scope would corrupt the shared imgui state for every addon.
        if zoneName ~= nil and zoneName ~= '' then
            local zW, zH = imgui.CalcTextSize(zoneName);
            drawOutlinedText(zoneBarStartX + (zoneBarWidth - zW) / 2, zoneBarStartY + (zoneBarHeight - zH) / 2, zoneName, {1, 1, 1, 1});
        end
        data.memberText[memIdx].zone:set_visible(false);
    end

    -- Position HP text
    local hpBaselineOffset = hpRefHeight - hpHeight;
    local nameBaselineOffset = nameRefHeight - nameHeight;

    -- Layout 0 (Horizontal) draws all of its text through imgui, the same way
    -- layout 1 and the player/target bars do. gdifont primitives render UNDER
    -- imgui, so anything left on the gdi layer is covered by the window
    -- background. Positions are collected here and drawn at the end of
    -- DrawMember, after every bar and background, via drawOutlinedText.
    --
    -- NOTE: imgui positions text by its top-left corner and has no baseline
    -- correction, so these use imgui.CalcTextSize rather than the gdifont
    -- *RefHeight / *BaselineOffset values used by the old primitive path.
    local pendingL0 = (layout == 0) and {} or nil;

    if layout == 1 then
        -- Layout 1: overlay HP text on HP bar, right-aligned and vertically centered.
        data.memberText[memIdx].hp:set_position_x(hpDrawX + hpBarWidth - hpTextWidth - 4 + textOffsets.hpX);
        data.memberText[memIdx].hp:set_position_y(hpStartY + (hpBarHeight - hpHeight) / 2 + textOffsets.hpY);
    else
        -- Layout 0: HP value sits below the HP bar, left-aligned at the bar's
        -- right edge offset. Queued for the imgui pass at the end.
        -- Layout 0: HP value sits below the HP bar. The gdifont primitive used
        -- Right alignment (see hp_font_settings), meaning the X it was given
        -- was the RIGHT edge of the text. imgui draws from the left, so the
        -- text width has to be subtracted to land in the same place.
        local imguiHpW = imgui.CalcTextSize(tostring(hpDisplayText or ''));
        pendingL0.hp = {
            x = hpStartX + hpBarWidth + settings.hpTextOffsetX + textOffsets.hpX - imguiHpW,
            y = hpStartY + hpBarHeight + settings.hpTextOffsetY + textOffsets.hpY,
            text = hpDisplayText,
        };
    end

    -- Draw leader icon (yellow). Layout 1 (compact): retail-style — enlarged,
    -- to the LEFT of the name, vertically centered on the name line. Other
    -- layouts keep the original top-left-of-bar dot. Alliance leader (P1 leader
    -- when alliance is formed) gets two yellow dots side by side.
    if (memInfo.allianceLeader) then
        if layout == 1 then
            local leaderR = settings.dotRadius * 1.5;
            local dotY = hpStartY + hpBarHeight / 2;
            -- Foreground list so dots aren't clipped by the window rect. Name
            -- (foreground, drawn LATER in code) ends up on top of any overlap.
            local fg = imgui.GetForegroundDrawList();
            local LEADER_SHIFT_X = 3;
            -- Both alliance dots shifted RIGHT by one diameter (2*leaderR) from
            -- their old positions — outer was at -3r, inner at -r. New: outer
            -- sits where the single-leader dot does (-r, overlapping bar's left
            -- edge), inner moves one diameter to the right (+r, INSIDE the bar).
            -- Net effect: dot pair reads as "inside" the bar instead of trailing
            -- off to the left over the icon area.
            draw_circle({hpStartX - leaderR - 2 + LEADER_SHIFT_X, dotY}, leaderR, {1, 1, .5, 1}, leaderR * 3, true, nil, fg);
            draw_circle({hpStartX + leaderR - 2 + LEADER_SHIFT_X, dotY}, leaderR, {1, 1, .5, 1}, leaderR * 3, true, nil, fg);
        else
            -- Other layouts: small dots at the top-left of the bar. Keep the
            -- inner dot at the same corner anchor as the single-leader dot so
            -- single→alliance doesn't visually jump; place the second dot
            -- OUTSIDE the bar to the left (used to be +r*2 which put it on
            -- top of the player name).
            local r  = settings.dotRadius;
            draw_circle({hpStartX + r/2,         hpStartY + r/2}, r, {1, 1, .5, 1}, r * 3, true, nil, GetUIDrawList());
            draw_circle({hpStartX - r * 2 + r/2, hpStartY + r/2}, r, {1, 1, .5, 1}, r * 3, true, nil, GetUIDrawList());
        end
    elseif (memInfo.leader) then
        if layout == 1 then
            local leaderR = settings.dotRadius * 1.5;
            local dotY = hpStartY + hpBarHeight / 2;   -- bar vertical center
            -- Foreground list so the dot isn't clipped; the name draws after
            -- this on the same list and covers the dot's right edge.
            local LEADER_SHIFT_X = 3;
            draw_circle({hpStartX - leaderR - 2 + LEADER_SHIFT_X, dotY}, leaderR, {1, 1, .5, 1}, leaderR * 3, true, nil, imgui.GetForegroundDrawList());
        else
            draw_circle({hpStartX + settings.dotRadius/2, hpStartY + settings.dotRadius/2}, settings.dotRadius, {1, 1, .5, 1}, settings.dotRadius * 3, true, nil, GetUIDrawList());
        end
    end

    -- Position name text
    local desiredNameColor = cache.colors.nameTextColor;
    if (data.memberTextColorCache[memIdx].name ~= desiredNameColor) then
        data.memberText[memIdx].name:set_font_color(desiredNameColor);
        data.memberTextColorCache[memIdx].name = desiredNameColor;
    end
    if layout == 1 then
        -- HXUI: name overlays the HP bar, left-aligned with a small inset,
        -- vertically centered on the HP bar.
        -- Name shifted LEFT to overlay the job icon (drawn on top of it).
        data.memberText[memIdx].name:set_position_x(hpStartX + 2 + textOffsets.nameX);
        -- Straddle the top edge of the HP bar (HXUI look), not centered in it.
        data.memberText[memIdx].name:set_position_y(hpStartY - nameHeight / 2 + textOffsets.nameY);
    else
        data.memberText[memIdx].name:set_position_x(namePosX + textOffsets.nameX);
        data.memberText[memIdx].name:set_position_y(hpStartY - nameRefHeight - settings.nameTextOffsetY + nameBaselineOffset + textOffsets.nameY);
    end
    -- The imgui window background draws ON TOP of gdifont primitives, which
    -- washes the name out. Hide the gdifont here and draw the name via imgui at the bottom
    -- of DrawMember (consumed via pendingLayout1Name) so it lands on top of the bg.
    -- Layout 1 (HXUI) ALSO draws its name on top via drawOutlinedText in BOTH themes,
    -- because the name overlays the (big) job icon and bars and must render above them;
    -- the gdifont layer renders behind those, so hide it for layout 1 regardless of theme.
    if layout == 1 then
        data.memberText[memIdx].name:set_visible(false);
    else
        data.memberText[memIdx].name:set_visible(false);
    end

    -- Handle cast bars - determine if casting and calculate progress
    local castData = nil;
    local isCasting = false;
    local castProgress = 0;
    local castBarStyle = cache.castBarStyle or 'name';
    if (cache.showCastBars and memInfo.inzone and memInfo.serverid ~= nil) then
        castData = data.partyCasts[memInfo.serverid];
        if (castData ~= nil and castData.spellName ~= nil and castData.castTime ~= nil and castData.startTime ~= nil) then
            isCasting = true;

            -- Calculate cast progress
            if (memIdx == 0) then
                local castBar = GetCastBarSafe();
                if (castBar ~= nil) then
                    local percent = castBar:GetPercent();
                    local fastCast = CalculateFastCast(
                        castData.job, castData.subjob, castData.spellType,
                        castData.spellName, castData.jobLevel, castData.subjobLevel
                    );
                    if fastCast > 0 then
                        local totalCast = (1 - fastCast) * 0.75;
                        castProgress = math.min(percent / totalCast, 1.0);
                    else
                        castProgress = percent;
                    end
                end
            else
                local elapsed = os.clock() - castData.startTime;
                local effectiveCastTime = castData.castTime;
                local fastCast = CalculateFastCast(
                    castData.job, castData.subjob, castData.spellType,
                    castData.spellName, castData.jobLevel, castData.subjobLevel
                );
                if fastCast > 0 then
                    effectiveCastTime = castData.castTime * (1 - fastCast);
                end
                castProgress = math.min(elapsed / effectiveCastTime, 1.0);
            end

            -- Check if cast is complete (for player only)
            if (memIdx == 0 and castProgress >= 1.0) then
                data.partyCasts[memInfo.serverid] = nil;
                isCasting = false;
            end

            -- Handle 'name' style cast bar rendering
            if isCasting and castBarStyle == 'name' then
                setCachedText(memIdx, 'name', data.memberText[memIdx].name, castData.spellName);
                -- Set name text to cast text color
                local castTextColor = cache.colors.castTextColor or 0xFFFFCC44;
                if (data.memberTextColorCache[memIdx].name ~= castTextColor) then
                    data.memberText[memIdx].name:set_font_color(castTextColor);
                    data.memberTextColorCache[memIdx].name = castTextColor;
                end
                local spellNameWidth, _ = data.memberText[memIdx].name:get_text_size();

                local castBarWidth = hpBarWidth * 0.6 * cache.castBarScaleX;
                local castBarHeight = math.max(6, nameRefHeight * 0.8 * cache.castBarScaleY);
                local castBarOffsetX = cache.castBarOffsetX or 0;
                local castBarOffsetY = cache.castBarOffsetY or 0;
                -- Layout 1 (HXUI): the spell name sits ON the HP bar's top edge (the
                -- name line), so the cast bar rides that same line, right-aligned to
                -- the (shifted) HP bar's right edge. Layout 0 keeps the original
                -- "next to spell name", above-the-bar anchor.
                local castBarX, castBarY;
                if layout == 1 then
                    castBarX = hpDrawX + hpBarWidth - castBarWidth + castBarOffsetX;
                    castBarY = (hpStartY - nameHeight / 2) + (nameHeight - castBarHeight) / 2 + castBarOffsetY;
                else
                    castBarX = namePosX + spellNameWidth + 4 + castBarOffsetX;
                    castBarY = hpStartY - nameRefHeight - settings.nameTextOffsetY + (nameRefHeight - castBarHeight) / 2 + castBarOffsetY;
                end
                local castGradient = GetCustomGradient(cache.colors, 'castBarGradient') or {'#ffaa00', '#ffcc44'};
                progressbar.ProgressBar(
                    {{castProgress, castGradient}},
                    {castBarWidth, castBarHeight},
                    {
                        decorate = false,
                        absolutePosition = {castBarX, castBarY},
                        borderColorOverride = data.getBarBorderOverride(partyIndex)
                    }
                );
            end
        end
    end

    -- Distance text
    local showDistance = false;
    local highlightDistance = false;
    -- Layout 1 (Compact Vertical) defers distance drawing to the end of DrawMember so it
    -- renders on top of every other imgui draw in this row (window background, bars, etc).
    -- This local is consumed at the bottom of the function via drawOutlinedText.
    local pendingLayout1Distance = nil;
    -- Only hide name/distance when casting with 'name' style (which replaces name with spell)
    -- When using 'mp' or 'tp' bar styles, name and distance should remain visible
    local hidingNameForCast = isCasting and castBarStyle == 'name';
    if (not hidingNameForCast) then
        setCachedText(memIdx, 'name', data.memberText[memIdx].name, nameText);
    end
    if (not hidingNameForCast and cache.showDistance and memInfo.inzone) then
        local distance = nil;
        if memInfo.previewDistance then
            distance = memInfo.previewDistance;
        elseif memInfo.index then
            local entity = data.frameCache.entity;
            if entity ~= nil then
                distance = math.sqrt(entity:GetDistance(memInfo.index))
            end
        end
        if (distance ~= nil and distance > 0 and distance <= 50) then
            local distanceText = ('%.1f'):fmt(distance);
            -- Position distance relative to HP bar right edge (stable anchor)
            -- Distance uses right alignment - position is the fixed right edge anchor
            local distancePosX = hpStartX + hpBarWidth;
            local distancePosY = hpStartY - nameRefHeight + nameBaselineOffset + textOffsets.distanceY;
            if (cache.distanceHighlight > 0 and distance <= cache.distanceHighlight) then
                highlightDistance = true;
            end
            if layout == 1 then
                -- Layout 1 (HXUI): distance shares the NAME's line (straddling the
                -- HP bar's top edge), right-aligned to the bar's right edge — so it
                -- doesn't take its own row and grow the entry. Uses hpDrawX (the
                -- shifted bar origin) and the name's Y, not the old name-row Y.
                pendingLayout1Distance = {
                    text  = distanceText,
                    rightX = hpDrawX + hpBarWidth + textOffsets.distanceX,
                    y     = hpStartY - nameHeight / 2 + textOffsets.distanceY,
                    color = highlightDistance and {0, 1, 1, 1} or {1, 1, 1, 1},
                };
            else
                -- Layout 0: distance sits on the name row, right-aligned to the
                -- HP bar's right edge. Drawn via imgui like the rest of this
                -- layout's text so the window background can't cover it.
                local imguiDistW, imguiDistH = imgui.CalcTextSize(tostring(distanceText or ''));
                pendingL0.distance = {
                    x = distancePosX + textOffsets.distanceX - imguiDistW,
                    y = hpStartY - imguiDistH + textOffsets.distanceY,
                    text = distanceText,
                    color = highlightDistance and {0, 1, 1, 1} or nil,
                };
                showDistance = true;
            end
        end
    end

    -- Layout 1 hides the gdifont distance primitive (drawn manually at end via drawOutlinedText).
    data.memberText[memIdx].distance:set_visible(false);
    if showDistance then
        local desiredDistanceColor = highlightDistance and 0xFF00FFFF or cache.colors.nameTextColor;
        if (data.memberTextColorCache[memIdx].distance ~= desiredDistanceColor) then
            data.memberText[memIdx].distance:set_font_color(desiredDistanceColor);
            data.memberTextColorCache[memIdx].distance = desiredDistanceColor;
        end
    end

    -- Job text (Layout 1 only)
    local showJobText = false;
    if cache.showJob and layout == 0 and memInfo.inzone and memInfo.job ~= '' and memInfo.job ~= nil and memInfo.job > 0 then
        local jobStr = '';
        if cache.showMainJob then
            local mainJobAbbr = AshitaCore:GetResourceManager():GetString('jobs.names_abbr', memInfo.job) or '';
            jobStr = mainJobAbbr;
            if cache.showMainJobLevel then
                jobStr = jobStr .. tostring(memInfo.level);
            end
        end
        if cache.showSubJob and memInfo.subjob ~= nil and memInfo.subjob ~= '' and memInfo.subjob > 0 then
            local subJobAbbr = AshitaCore:GetResourceManager():GetString('jobs.names_abbr', memInfo.subjob) or '';
            jobStr = jobStr .. '/' .. subJobAbbr;
            if cache.showSubJobLevel then
                jobStr = jobStr .. tostring(memInfo.subjoblevel);
            end
        end
        if jobStr ~= '' then
            setCachedText(memIdx, 'job', data.memberText[memIdx].job, jobStr);
            data.memberText[memIdx].job:set_font_height(fontSizes.job);
            -- Layout 0: job text sits on the name row, right-aligned to the far
            -- edge of the bars. Measured and drawn with imgui (job text is only
            -- shown in layout 0 -- see the showJob check above).
            local imguiJobW, imguiJobH = imgui.CalcTextSize(tostring(jobStr or ''));
            local jobPosX = hpStartX + allBarsLengths - imguiJobW;
            pendingL0.job = {
                x = jobPosX + textOffsets.jobX,
                y = hpStartY - imguiJobH - settings.nameTextOffsetY + textOffsets.jobY,
                text = jobStr,
                color = cache.colors.nameTextColor,
            };
            showJobText = true;
        end
    end
    data.memberText[memIdx].job:set_visible(false);

    -- Layout 1: draw distance (e.g. "18.3") on the name's line, right-aligned,
    -- BEFORE the MP/TP/cast bars so that when the member is casting the cast bar
    -- overlaps the distance (draw distance, then castbar on top).
    if pendingLayout1Distance ~= nil then
        local dW, _ = imgui.CalcTextSize(pendingLayout1Distance.text);
        drawOutlinedText(pendingLayout1Distance.rightX - dW, pendingLayout1Distance.y, pendingLayout1Distance.text, pendingLayout1Distance.color);
    end

    -- MP/TP bars
    -- Calculate where MP bar would be positioned (after HP bar) for consistent status icon placement
    local mpStartX = hpDrawX + hpBarWidth + imgui.GetStyle().FramePadding.x + imgui.GetStyle().ItemSpacing.x;
    local mpStartY = hpStartY;
    local tpStartX, tpStartY; -- Track TP bar position

    -- Determine if we should show the MP bar slot
    -- Show if: alwaysShowMpBar is enabled, OR job has MP, OR we're casting and cast bar style is 'mp'
    local showingCastInMpSlot = isCasting and castBarStyle == 'mp' and castData;
    local showMpBar = cache.alwaysShowMpBar or jobHasMP or showingCastInMpSlot;

    -- Determine if we should show the cast bar in the TP slot
    local showingCastInTpSlot = isCasting and castBarStyle == 'tp' and castData;

    if (memInfo.inzone) then
        if layout == 1 then
            -- Vertical layout: MP/TP row under the HP bar.
            imgui.Dummy({0, 1});
            local rowStartX, rowStartY = imgui.GetCursorScreenPos();
            -- The cursor snaps back to the line's left margin (hpStartX) after the
            -- HP bar, but in the HXUI look the bars are shifted right to hpDrawX.
            -- Re-anchor the MP row to hpDrawX so the MP bar sits flush under the
            -- HP bar (right edges aligned) instead of drifting left by the icon.
            rowStartX = hpDrawX;

            -- TP text (or spell name if casting with 'tp' style)
            if showingCastInTpSlot then
                -- Show spell name instead of TP when casting with 'tp' style
                setCachedText(memIdx, 'tp', data.memberText[memIdx].tp, castData.spellName);
                local castTextColor = cache.colors.castTextColor or 0xFFFFCC44;
                if (data.memberTextColorCache[memIdx].tp ~= castTextColor) then
                    data.memberText[memIdx].tp:set_font_color(castTextColor);
                    data.memberTextColorCache[memIdx].tp = castTextColor;
                end
            else
                -- Normal TP text color with optional flashing
                local desiredTpColor;
                if memInfo.tp >= 1000 and cache.flashTP then
                    local flashTime = os.clock();
                    local timePerPulse = 1;
                    local phase = flashTime % timePerPulse;
                    local pulseAlpha = (2 / timePerPulse) * phase;
                    if pulseAlpha > 1 then pulseAlpha = 2 - pulseAlpha; end
                    local baseColor = cache.colors.tpFullTextColor or 0xFFFFFFFF;
                    local flashColor = cache.colors.tpFlashColor or 0xFF3ECE00;
                    local baseA = bit.band(bit.rshift(baseColor, 24), 0xFF);
                    local baseR = bit.band(bit.rshift(baseColor, 16), 0xFF);
                    local baseG = bit.band(bit.rshift(baseColor, 8), 0xFF);
                    local baseB = bit.band(baseColor, 0xFF);
                    local flashA = bit.band(bit.rshift(flashColor, 24), 0xFF);
                    local flashR = bit.band(bit.rshift(flashColor, 16), 0xFF);
                    local flashG = bit.band(bit.rshift(flashColor, 8), 0xFF);
                    local flashB = bit.band(flashColor, 0xFF);
                    local interpA = math.floor(baseA + (flashA - baseA) * pulseAlpha);
                    local interpR = math.floor(baseR + (flashR - baseR) * pulseAlpha);
                    local interpG = math.floor(baseG + (flashG - baseG) * pulseAlpha);
                    local interpB = math.floor(baseB + (flashB - baseB) * pulseAlpha);
                    desiredTpColor = bit.bor(bit.lshift(interpA, 24), bit.lshift(interpR, 16), bit.lshift(interpG, 8), interpB);
                    if (data.memberTextColorCache[memIdx].tp ~= desiredTpColor) then
                        data.memberText[memIdx].tp:set_font_color(desiredTpColor);
                        data.memberTextColorCache[memIdx].tp = desiredTpColor;
                    end
                else
                    desiredTpColor = (memInfo.tp >= 1000) and cache.colors.tpFullTextColor or cache.colors.tpEmptyTextColor;
                    if (data.memberTextColorCache[memIdx].tp ~= desiredTpColor) then
                        data.memberText[memIdx].tp:set_font_color(desiredTpColor);
                        data.memberTextColorCache[memIdx].tp = desiredTpColor;
                    end
                end
            end

            local tpBaselineOffset = tpRefHeight - tpHeight;

            -- Right-align MP bar with HP bar's right edge. TP text sits in the
            -- empty gap to the LEFT of the (narrower) MP bar.
            local mpBarStartX = rowStartX + hpBarWidth - mpBarWidth;
            mpStartX = mpBarStartX;
            mpStartY = rowStartY;

            -- TP text: in the gap left of the MP bar, right-aligned to its left edge.
            data.memberText[memIdx].tp:set_position_x(mpBarStartX - tpTextWidth - 4 + textOffsets.tpX);
            data.memberText[memIdx].tp:set_position_y(mpStartY + (mpBarHeight - tpHeight) / 2 + textOffsets.tpY);

            imgui.SetCursorScreenPos({mpStartX, mpStartY});

            -- Render cast bar or MP bar based on style and job type
            if showMpBar then
                if showingCastInMpSlot then
                    local castGradient = GetCustomGradient(cache.colors, 'castBarGradient') or {'#ffaa00', '#ffcc44'};
                    progressbar.ProgressBar({{castProgress, castGradient}}, {mpBarWidth, mpBarHeight}, {decorate = cache.showBookends, backgroundGradientOverride = data.getBarBackgroundOverride(partyIndex), borderColorOverride = data.getBarBorderOverride(partyIndex)});
                    -- Layout 1: overlay spell name centered on cast bar (drawn AFTER bar)
                    if castData and castData.spellName then
                        local sn = castData.spellName;
                        local snW, snH = imgui.CalcTextSize(sn);
                        drawOutlinedText(mpStartX + (mpBarWidth - snW) / 2, mpStartY + (mpBarHeight - snH) / 2, sn, {1, 0.8, 0.27, 1});
                    end
                    -- Set MP text to spell name with cast text color
                    setCachedText(memIdx, 'mp', data.memberText[memIdx].mp, castData.spellName);
                    local castTextColor = cache.colors.castTextColor or 0xFFFFCC44;
                    if (data.memberTextColorCache[memIdx].mp ~= castTextColor) then
                        data.memberText[memIdx].mp:set_font_color(castTextColor);
                        data.memberTextColorCache[memIdx].mp = castTextColor;
                    end
                else
                    local mpGradient = GetCustomGradient(cache.colors, 'mpGradient') or {'#9abb5a', '#bfe07d'};

                    -- Check for spell cost preview (only for player - memIdx 0)
                    local mpPercentData;
                    if memIdx == 0 and gConfig.showMpCostPreview ~= false then
                        local spellMpCost, hasEnoughMp, isSpellActive = castcostShared.GetMpCost();
                        if isSpellActive and spellMpCost > 0 and memInfo.maxmp > 0 then
                            local costPercent = spellMpCost / memInfo.maxmp;
                            local remainingMpPercent = math.max(0, memInfo.mpp - costPercent);

                            -- Get cost preview colors from castCost settings
                            local castCostColors = gConfig.colorCustomization.castCost;
                            local costGradient;
                            local costColorSetting = castCostColors and castCostColors.mpCostPreviewGradient;
                            if costColorSetting then
                                if costColorSetting.enabled and costColorSetting.start and costColorSetting.stop then
                                    costGradient = {costColorSetting.start, costColorSetting.stop};
                                elseif costColorSetting.start then
                                    costGradient = {costColorSetting.start, costColorSetting.start};
                                else
                                    costGradient = {'#9abb5a', '#bfe07d'};
                                end
                            else
                                costGradient = {'#9abb5a', '#bfe07d'};
                            end

                            -- Calculate pulsing overlay for cost preview
                            local costOverlay = nil;
                            local flashColor = castCostColors and castCostColors.mpCostPreviewFlashColor or '#FFFFFF';
                            local pulseSpeed = castCostColors and castCostColors.mpCostPreviewPulseSpeed or 1.0;
                            if pulseSpeed > 0 then
                                local pulseTime = os.clock();
                                local phase = pulseTime % pulseSpeed;
                                local pulseAlpha = (2 / pulseSpeed) * phase;
                                if pulseAlpha > 1 then
                                    pulseAlpha = 2 - pulseAlpha;
                                end
                                pulseAlpha = pulseAlpha * 0.6;
                                costOverlay = {flashColor, pulseAlpha};
                            end

                            mpPercentData = {
                                {remainingMpPercent, mpGradient},
                                {costPercent, costGradient, costOverlay},
                            };
                        else
                            mpPercentData = {{memInfo.mpp, mpGradient}};
                        end
                    else
                        mpPercentData = {{memInfo.mpp, mpGradient}};
                    end

                    progressbar.ProgressBar(mpPercentData, {mpBarWidth, mpBarHeight}, {decorate = cache.showBookends, backgroundGradientOverride = data.getBarBackgroundOverride(partyIndex), borderColorOverride = data.getBarBorderOverride(partyIndex)});
                    -- Layout 1: MP overlay right-aligned ON the MP bar (drawn AFTER bar
                    -- to stay on top in the same imgui draw list). TP overlay is rendered
                    -- below the showMpBar block so no-MP jobs still show TP.
                    do
                        local mpW, mpH2 = imgui.CalcTextSize(mpDisplayText);
                        drawOutlinedText(mpStartX + mpBarWidth - mpW - 4, mpStartY + (mpBarHeight - mpH2) / 2, mpDisplayText, {1, 1, 1, 1});
                    end
                    if (data.memberTextColorCache[memIdx].mp ~= cache.colors.mpTextColor) then
                        data.memberText[memIdx].mp:set_font_color(cache.colors.mpTextColor);
                        data.memberTextColorCache[memIdx].mp = cache.colors.mpTextColor;
                    end
                end

                local mpBaselineOffset = mpRefHeight - mpHeight;
                -- Layout 1: overlay MP text on MP bar, right-aligned. Y stays centered on the bar.
                data.memberText[memIdx].mp:set_position_x(mpStartX + mpBarWidth - mpTextWidth - 4 + textOffsets.mpX);
                data.memberText[memIdx].mp:set_position_y(mpStartY + (mpBarHeight - mpRefHeight) / 2 + mpBaselineOffset + textOffsets.mpY);
            end

            -- Layout 1: TP overlay in the EMPTY SPACE to the LEFT of the MP bar position.
            -- Drawn regardless of showMpBar so jobs without MP (WAR, MNK, SAM, etc.) still
            -- show TP. Color: at >= 1000, honors flashTP and rainbowTP (computed via
            -- computeTpColorARGB - rainbow overrides flash); otherwise solid green at
            -- 1000+ and white below 1000.
            if showTP and memInfo.inzone then
                local tpStr = tostring(memInfo.tp);
                local tpW, tpH2 = imgui.CalcTextSize(tpStr);
                local tpColor;
                if memInfo.tp >= 1000 and (cache.flashTP or cache.rainbowTP) then
                    tpColor = argbToRgbaTable(computeTpColorARGB(memInfo, cache));
                elseif memInfo.tp >= 1000 then
                    tpColor = {0.243, 0.808, 0, 1};   -- green (weapon-skill ready)
                else
                    tpColor = {1, 1, 1, 1};
                end
                -- TP value sits in the empty gap to the LEFT of the (narrower,
                -- right-aligned) MP bar, right-aligned against the bar's left edge.
                drawOutlinedText(mpStartX - tpW - 4, mpStartY + (mpBarHeight - tpH2) / 2, tpStr, tpColor);
            end
        else
            -- Layout 0: Horizontal layout
            -- Render MP bar/cast bar if job has MP or is casting with 'mp' style
            if showMpBar then
                imgui.SameLine();
                imgui.SetCursorPosX(imgui.GetCursorPosX());
                mpStartX, mpStartY = imgui.GetCursorScreenPos();

                -- Render cast bar or MP bar based on style and job type
                if showingCastInMpSlot then
                    local castGradient = GetCustomGradient(cache.colors, 'castBarGradient') or {'#ffaa00', '#ffcc44'};
                    progressbar.ProgressBar({{castProgress, castGradient}}, {mpBarWidth, mpBarHeight}, {decorate = cache.showBookends, backgroundGradientOverride = data.getBarBackgroundOverride(partyIndex), borderColorOverride = data.getBarBorderOverride(partyIndex)});
                    -- Set MP text to spell name with cast text color
                    setCachedText(memIdx, 'mp', data.memberText[memIdx].mp, castData.spellName);
                    local castTextColor = cache.colors.castTextColor or 0xFFFFCC44;
                    if (data.memberTextColorCache[memIdx].mp ~= castTextColor) then
                        data.memberText[memIdx].mp:set_font_color(castTextColor);
                        data.memberTextColorCache[memIdx].mp = castTextColor;
                    end
                else
                    local mpGradient = GetCustomGradient(cache.colors, 'mpGradient') or {'#9abb5a', '#bfe07d'};

                    -- Check for spell cost preview (only for player - memIdx 0)
                    local mpPercentData;
                    if memIdx == 0 and gConfig.showMpCostPreview ~= false then
                        local spellMpCost, hasEnoughMp, isSpellActive = castcostShared.GetMpCost();
                        if isSpellActive and spellMpCost > 0 and memInfo.maxmp > 0 then
                            local costPercent = spellMpCost / memInfo.maxmp;
                            local remainingMpPercent = math.max(0, memInfo.mpp - costPercent);

                            -- Get cost preview colors from castCost settings
                            local castCostColors = gConfig.colorCustomization.castCost;
                            local costGradient;
                            local costColorSetting = castCostColors and castCostColors.mpCostPreviewGradient;
                            if costColorSetting then
                                if costColorSetting.enabled and costColorSetting.start and costColorSetting.stop then
                                    costGradient = {costColorSetting.start, costColorSetting.stop};
                                elseif costColorSetting.start then
                                    costGradient = {costColorSetting.start, costColorSetting.start};
                                else
                                    costGradient = {'#9abb5a', '#bfe07d'};
                                end
                            else
                                costGradient = {'#9abb5a', '#bfe07d'};
                            end

                            -- Calculate pulsing overlay for cost preview
                            local costOverlay = nil;
                            local flashColor = castCostColors and castCostColors.mpCostPreviewFlashColor or '#FFFFFF';
                            local pulseSpeed = castCostColors and castCostColors.mpCostPreviewPulseSpeed or 1.0;
                            if pulseSpeed > 0 then
                                local pulseTime = os.clock();
                                local phase = pulseTime % pulseSpeed;
                                local pulseAlpha = (2 / pulseSpeed) * phase;
                                if pulseAlpha > 1 then
                                    pulseAlpha = 2 - pulseAlpha;
                                end
                                pulseAlpha = pulseAlpha * 0.6;
                                costOverlay = {flashColor, pulseAlpha};
                            end

                            mpPercentData = {
                                {remainingMpPercent, mpGradient},
                                {costPercent, costGradient, costOverlay},
                            };
                        else
                            mpPercentData = {{memInfo.mpp, mpGradient}};
                        end
                    else
                        mpPercentData = {{memInfo.mpp, mpGradient}};
                    end

                    progressbar.ProgressBar(mpPercentData, {mpBarWidth, mpBarHeight}, {decorate = cache.showBookends, backgroundGradientOverride = data.getBarBackgroundOverride(partyIndex), borderColorOverride = data.getBarBorderOverride(partyIndex)});
                    if (data.memberTextColorCache[memIdx].mp ~= cache.colors.mpTextColor) then
                        data.memberText[memIdx].mp:set_font_color(cache.colors.mpTextColor);
                        data.memberTextColorCache[memIdx].mp = cache.colors.mpTextColor;
                    end
                end

                -- Layout 0: MP value sits below the MP bar, right-aligned to the
                -- bar's right edge. mp_font_settings is Left-aligned, so the
                -- original code right-aligned it manually by subtracting the
                -- text width -- reproduced here with the imgui width so it
                -- matches the text actually drawn.
                --
                -- The text may be the MP value or a spell name (cast style
                -- 'mp'), so prefer whatever setCachedText last wrote. But that
                -- only writes when the value CHANGES, so fall back to
                -- mpDisplayText rather than drawing nothing if the cache is
                -- empty. Forced to a string: the cache can hold a number and
                -- imgui applies string methods to its argument.
                local mpCached = (data.memberTextCache[memIdx] or {}).mp;
                local mpDrawText = tostring(mpCached or mpDisplayText or '');
                local imguiMpW = imgui.CalcTextSize(mpDrawText);
                pendingL0.mp = {
                    x = mpStartX + mpBarWidth - imguiMpW + textOffsets.mpX,
                    y = mpStartY + mpBarHeight + settings.mpTextOffsetY + textOffsets.mpY,
                    text = mpDrawText,
                    color = cache.colors.mpTextColor,
                };
            end

            -- TP bar (or cast bar if castBarStyle == 'tp')
            if (showTP or showingCastInTpSlot) then
                imgui.SameLine();
                imgui.SetCursorPosX(imgui.GetCursorPosX());
                tpStartX, tpStartY = imgui.GetCursorScreenPos();

                if showingCastInTpSlot then
                    -- Render cast bar in TP slot
                    local castGradient = GetCustomGradient(cache.colors, 'castBarGradient') or {'#ffaa00', '#ffcc44'};
                    progressbar.ProgressBar({{castProgress, castGradient}}, {tpBarWidth, tpBarHeight}, {decorate = cache.showBookends, backgroundGradientOverride = data.getBarBackgroundOverride(partyIndex), borderColorOverride = data.getBarBorderOverride(partyIndex)});
                    -- Set TP text to spell name with cast text color
                    setCachedText(memIdx, 'tp', data.memberText[memIdx].tp, castData.spellName);
                    local castTextColor = cache.colors.castTextColor or 0xFFFFCC44;
                    if (data.memberTextColorCache[memIdx].tp ~= castTextColor) then
                        data.memberText[memIdx].tp:set_font_color(castTextColor);
                        data.memberTextColorCache[memIdx].tp = castTextColor;
                    end
                else
                    -- Render normal TP bar
                    local tpGradient = GetCustomGradient(cache.colors, 'tpGradient') or {'#3898ce', '#78c4ee'};
                    local tpOverlayGradient = {'#0078CC', '#0078CC'};
                    local mainPercent;
                    local tpOverlay;

                    if (memInfo.tp >= 1000) then
                        mainPercent = (memInfo.tp - 1000) / 2000;
                        -- Rainbow and Flash both tint the 1000+ overlay. Rainbow
                        -- takes precedence (same rule as the TP text), and its
                        -- current hue comes from the shared helper so bar and
                        -- text stay in sync through the cycle.
                        if (cache.rainbowTP or cache.flashTP) then
                            local overlayARGB;
                            if cache.rainbowTP then
                                overlayARGB = computeTpColorARGB(memInfo, cache);
                            else
                                overlayARGB = cache.colors.tpFlashColor or 0xFF3ECE00;
                            end
                            local overlayHex = string.format('#%06X', bit.band(overlayARGB, 0xFFFFFF));
                            tpOverlay = {{1, tpOverlayGradient}, math.ceil(tpBarHeight * 5/7), 0, { overlayHex, 1 }};
                        else
                            tpOverlay = {{1, tpOverlayGradient}, math.ceil(tpBarHeight * 2/7), 1};
                        end
                    else
                        mainPercent = memInfo.tp / 1000;
                    end

                    progressbar.ProgressBar({{mainPercent, tpGradient}}, {tpBarWidth, tpBarHeight}, {overlayBar=tpOverlay, decorate = cache.showBookends, backgroundGradientOverride = data.getBarBackgroundOverride(partyIndex), borderColorOverride = data.getBarBorderOverride(partyIndex)});

                    -- Use the shared helper so Horizontal honors rainbowTP and
                    -- flashTP exactly like Compact / Super Compact do. It also
                    -- applies the rainbow-over-flash precedence, instead of the
                    -- old flat full/empty pick that ignored both settings.
                    local desiredTpColor = computeTpColorARGB(memInfo, cache);
                    if (data.memberTextColorCache[memIdx].tp ~= desiredTpColor) then
                        data.memberText[memIdx].tp:set_font_color(desiredTpColor);
                        data.memberTextColorCache[memIdx].tp = desiredTpColor;
                    end
                    setCachedText(memIdx, 'tp', data.memberText[memIdx].tp, tpText);
                end

                -- Layout 0: TP value sits below the TP bar, right-aligned to the
                -- bar's right edge (the original manually right-aligned it by
                -- subtracting the text width, so do the same with the imgui
                -- width). Read tpText directly rather than via the text cache:
                -- setCachedText only writes when the value CHANGES, so the
                -- cache can legitimately be empty on the first frame and the
                -- number would silently not draw.
                local tpDrawText = tostring(tpText or '');
                local imguiTpW = imgui.CalcTextSize(tpDrawText);
                pendingL0.tp = {
                    x = tpStartX + tpBarWidth - imguiTpW + textOffsets.tpX,
                    y = tpStartY + tpBarHeight + settings.tpTextOffsetY + textOffsets.tpY,
                    text = tpDrawText,
                    color = computeTpColorARGB(memInfo, cache),
                };
            end
        end

        -- Draw cursor
        if ((memInfo.targeted == true and not subTargetActive) or memInfo.subTargeted) then
            local cursorTexture = data.cursorTextures[cache.cursor];
            if (cursorTexture ~= nil) then
                local cursorImage = tonumber(ffi.cast("uint32_t", cursorTexture.image));
                local cursorWidth = cursorTexture.width * settings.arrowSize;
                local cursorHeight = cursorTexture.height * settings.arrowSize;

                local selectionScaleY = cache.selectionBoxScaleY or 1;
                local selectionOffsetY = cache.selectionBoxOffsetY or 0;
                local unscaledHeight = entryHeight + settings.cursorPaddingY1 + settings.cursorPaddingY2;
                local selectionHeight = unscaledHeight * selectionScaleY;
                -- Match the selection box's vertical anchor per layout: layout 1
                -- (HXUI) has no name row above the bar, so topOfMember = hpStartY;
                -- other layouts anchor above the name row.
                local topOfMember;
                if layout == 1 then
                    topOfMember = hpStartY;
                else
                    topOfMember = hpStartY - nameRefHeight - settings.nameTextOffsetY;
                end
                local centerOffsetY = (selectionHeight - unscaledHeight) / 2;
                -- Layout 1 trims the bottom edge; account for it so the arrow
                -- centers on the visible box, not the untrimmed one.
                if layout == 1 then
                    selectionHeight = selectionHeight - (HX_SEL_TRIM_H * scale.y);
                end
                local selectionTL_X = hpStartX - settings.cursorPaddingX1;
                local selectionTL_Y = topOfMember - settings.cursorPaddingY1 - centerOffsetY + selectionOffsetY;

                local cursorX = selectionTL_X - cursorWidth;
                local cursorY = selectionTL_Y + (selectionHeight / 2) - (cursorHeight / 2);

                local tintColor;
                if (memInfo.subTargeted) then
                    tintColor = ARGBToABGR(cache.subtargetArrowTint);
                else
                    tintColor = ARGBToABGR(cache.targetArrowTint);
                end

                local draw_list = (layout == 1) and imgui.GetForegroundDrawList() or GetUIDrawList();
                draw_list:AddImage(
                    cursorImage,
                    {cursorX, cursorY},
                    {cursorX + cursorWidth, cursorY + cursorHeight},
                    {0, 0}, {1, 1},
                    tintColor
                );

                data.partySubTargeted = true;
            end
        end

        -- Draw buffs/debuffs
        if (partyIndex == 1 and memInfo.buffs ~= nil and #memInfo.buffs > 0) then
            if (cache.statusTheme == 0 or cache.statusTheme == 1) then
                for k in pairs(data.reusableBuffs) do data.reusableBuffs[k] = nil; end
                for k in pairs(data.reusableDebuffs) do data.reusableDebuffs[k] = nil; end

                local buffCount = 0;
                local debuffCount = 0;
                for i = 0, #memInfo.buffs do
                    if (buffTable.IsBuff(memInfo.buffs[i])) then
                        buffCount = buffCount + 1;
                        data.reusableBuffs[buffCount] = memInfo.buffs[i];
                    else
                        debuffCount = debuffCount + 1;
                        data.reusableDebuffs[debuffCount] = memInfo.buffs[i];
                    end
                end

                -- Debuffs row (closest to party frame, at HP bar level)
                local statusOffsetX = cache.statusOffsetX or 0;
                local statusOffsetY = cache.statusOffsetY or 0;
                -- Layout 1: move the buff/debuff rows DOWN by 0.75 icon-size.
                if layout == 1 then
                    statusOffsetY = statusOffsetY + (settings.iconSize * 0.75);
                end
                -- Debuffs are shifted LEFT by 0.5 × iconSize so they don't sit directly
                -- under the buffs row above them — provides a visual stagger between rows.
                local debuffXShift = settings.iconSize * 0.5;
                if (debuffCount > 0) then
                    if cache.statusSide == 0 then
                        if data.debuffWindowX[memIdx] ~= nil then
                            imgui.SetNextWindowPos({hpStartX - data.debuffWindowX[memIdx] - settings.buffOffset + statusOffsetX - debuffXShift - 10, hpStartY + statusOffsetY});
                        end
                    else
                        if data.fullMenuWidth[partyIndex] ~= nil then
                            local thisPosX, _ = imgui.GetWindowPos();
                            imgui.SetNextWindowPos({ thisPosX + data.fullMenuWidth[partyIndex] + statusOffsetX - debuffXShift, hpStartY + statusOffsetY });
                        end
                    end
                    if (imgui.Begin('PlayerDebuffs'..memIdx, true, bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_NoMove, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoDocking))) then
                        imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {3, 1});

                        -- Capture the icon-row's screen position BEFORE DrawStatusIcons
                        -- so we can overlay invisible click-to-cure buttons at each icon's
                        -- exact location after the existing render. This keeps the visual
                        -- (pink-bordered debuff frames, spacing, status theme) untouched.
                        local debuffRowX, debuffRowY = imgui.GetCursorScreenPos();

                        DrawStatusIcons(data.reusableDebuffs, settings.iconSize, 32, 1, true);

                        -- Click-to-cure overlay. Default-on unless gConfig flag is explicitly
                        -- false. Only fires while live (not in config preview), and only for
                        -- debuffs that resolve to a cure spell — uncurable IDs (Charm, Stun,
                        -- Terror, Disease, KO) get no button so the click passes through.
                        -- Horizontal stride matches the ItemSpacing.x (3) pushed above.
                        if (gConfig.partyListClickCureDebuffs ~= false)
                           and memInfo.name and memInfo.name ~= '' then
                            -- Match the rendered icon size/stride, which scale with
                            -- the party list scale (raw settings.iconSize is base).
                            local zoneSize = settings.iconSize * scale.x;
                            local stride = zoneSize + 3;
                            -- The player (memIdx 0) is you — target <me>, not the name
                            -- (in preview the name is "Player 1", which isn't castable).
                            local cureTarget = (memIdx == 0) and '<me>' or memInfo.name;
                            -- This theme draws the icons one slot left of the captured
                            -- row origin; offset the zones left to match.
                            local startX = debuffRowX - stride;
                            for i = 1, debuffCount do
                                local cureSpell = GetDebuffCure(data.reusableDebuffs[i]);
                                if cureSpell ~= nil then
                                    RecordCureZone(startX + (i - 1) * stride, debuffRowY, zoneSize, cureSpell, cureTarget);
                                end
                            end
                        end

                        imgui.PopStyleVar(1);
                    end
                    local debuffWindowSizeX, _ = imgui.GetWindowSize();
                    data.debuffWindowX[memIdx] = debuffWindowSizeX;
                    imgui.End();
                end

                -- Buffs row (above debuffs, further from party frame)
                if (buffCount > 0) then
                    if cache.statusSide == 0 then
                        if data.buffWindowX[memIdx] ~= nil then
                            imgui.SetNextWindowPos({hpStartX - data.buffWindowX[memIdx] - settings.buffOffset + statusOffsetX - 10, hpStartY - settings.iconSize*1.2 + statusOffsetY});
                        end
                    else
                        if data.fullMenuWidth[partyIndex] ~= nil then
                            local thisPosX, _ = imgui.GetWindowPos();
                            imgui.SetNextWindowPos({ thisPosX + data.fullMenuWidth[partyIndex] + statusOffsetX, hpStartY - settings.iconSize * 1.2 + statusOffsetY });
                        end
                    end
                    if (imgui.Begin('PlayerBuffs'..memIdx, true, bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_NoMove, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoDocking))) then
                        imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {3, 1});
                        DrawStatusIcons(data.reusableBuffs, settings.iconSize, 32, 1, true);
                        imgui.PopStyleVar(1);
                    end
                    local buffWindowSizeX, _ = imgui.GetWindowSize();
                    data.buffWindowX[memIdx] = buffWindowSizeX;
                    imgui.End();
                end
            end
        end
    end

    -- Sync indicator. RED dot directly RIGHT of the HP bar's right edge.
    -- IMPORTANT: in layout 1 the HP bar is NOT drawn at hpStartX — it's drawn
    -- at `hpDrawX` (hpStartX + icon clearance + HX_BAR_INSET) so the icon
    -- doesn't sit under the bar. The bar's actual right edge is therefore
    -- `hpDrawX + hpBarWidth`, NOT `hpStartX + hpBarWidth`. Using the wrong
    -- anchor lands the dot inside the visible bar.
    -- For layout 0, hpDrawX == hpStartX so the same formula works.
    -- Foreground list so the dot isn't clipped by the window's right edge.
    if (memInfo.sync) then
        if layout == 1 or layout == 0 then
            local syncR = settings.dotRadius * 1.5;
            local dotY  = hpStartY + hpBarHeight / 2;
            local barRightX = hpDrawX + hpBarWidth;
            draw_circle({barRightX + syncR + 2, dotY}, syncR, {1, 0.3, 0.3, 1}, syncR * 3, true, nil, imgui.GetForegroundDrawList());
        end
    end

    -- Set text visibility
    -- HP/MP/TP gdifont primitives are not used in layout 1 (Compact Vertical) — text is
    -- drawn directly into the imgui draw list via drawOutlinedText so it appears on top
    -- of the bars. Layout 0 continues to use the gdifont primitives.
    -- Every layout now draws its text through imgui (gdifont primitives render
    -- UNDER imgui, so anything left on that layer is covered by the window
    -- background). The primitives are kept around for text measurement and
    -- caching, but are never shown.
    data.memberText[memIdx].hp:set_visible(false);
    data.memberText[memIdx].mp:set_visible(false);
    data.memberText[memIdx].tp:set_visible(false);

    -- Reserve space for layout
    if layout == 1 and memInfo.inzone then
        -- Layout 1: TP/MP text overlay the MP bar; row width is just hpBarWidth.
        imgui.Dummy({hpBarWidth, 0});
    end

    local bottomSpacing;
    if layout == 1 then
        bottomSpacing = math.max(0, tpRefHeight - mpBarHeight);
    else
        bottomSpacing = settings.hpTextOffsetY + hpRefHeight;
    end
    imgui.Dummy({0, bottomSpacing});

    if (not isLastVisibleMember) then
        local BASE_MEMBER_SPACING = 6;
        imgui.Dummy({0, BASE_MEMBER_SPACING + settings.entrySpacing[partyIndex]});
    end

    -- Click-to-target: manual click-vs-drag detection. We DON'T use an
    -- InvisibleButton here — it would consume the click and block ImGui's
    -- window-drag initiation (the bug that made solo undraggable, since the
    -- single entry covered the whole window). Instead, on mouse release we
    -- check GetMouseDragDelta(0, 4): if it returns (0,0) the user didn't drag
    -- past the 4 px threshold during the press → it was a click → fire /target
    -- if the cursor is inside the entry bbox. If the user did drag, ImGui has
    -- already handled the window-drag without any interference from us.
    if (memInfo.inzone and not showConfig[1] and gConfig.enablePartyListClickTarget ~= false) then
        if imgui.IsMouseReleased(0) then
            local dx, dy = imgui.GetMouseDragDelta(0, 4);
            if (dx == 0 and dy == 0) then
                local mx, my = imgui.GetMousePos();
                local entryStartX, entryStartY, entryW, entryH;
                if layout == 1 then
                    -- HXUI: clickable region = the whole drawn entry. Left edge at
                    -- the job icon (hpStartX), right edge at the bar's right edge
                    -- (hpDrawX + hpBarWidth), top at hpStartY (name straddles above
                    -- but the body starts here), bottom at the MP bar's bottom.
                    entryStartX = hpStartX;
                    entryStartY = hpStartY;
                    entryW = (hpDrawX - hpStartX) + hpBarWidth;
                    entryH = entryHeight;
                else
                    entryStartX = hpStartX;
                    entryStartY = hpStartY - nameRefHeight - settings.nameTextOffsetY;
                    entryW = allBarsLengths;
                    entryH = entryHeight;
                end
                if mx >= entryStartX and mx <= entryStartX + entryW
                   and my >= entryStartY and my <= entryStartY + entryH then
                    -- See first click handler above for the sub-target rationale.
                    if data.frameCache.subTargetActive then
                        st_walk_to(memIdx);
                    else
                        AshitaCore:GetChatManager():QueueCommand(-1, '/target ' .. memInfo.serverid);
                    end
                end
            end
        end
    end

    -- (Layout 1 distance is drawn earlier, before the MP/TP/cast bars, so the
    -- cast bar overlaps it when casting — see the pendingLayout1Distance draw above.)

    -- Draw the player name (or spell name when casting with 'name' style) via
    -- imgui so it lands on top of the window background. The gdifont primitive
    -- was hidden earlier via set_visible(false). Cast color when casting+name,
    -- white otherwise (matches the rest of the imgui overlays).
    do
        local nameToDraw, nameColor;
        if isCasting and castBarStyle == 'name' and castData and castData.spellName then
            nameToDraw = castData.spellName;
            nameColor  = {1, 0.8, 0.27, 1};
        else
            nameToDraw = nameText;
            nameColor  = {1, 1, 1, 1};
        end
        local nameX, nameY;
        if layout == 1 then
            nameX = hpStartX + 2 + textOffsets.nameX;
            nameY = hpStartY - nameHeight / 2 + textOffsets.nameY;
        else
            -- Layout 0: name sits on its own row directly above the HP bar.
            -- Measured with imgui, not the gdifont nameRefHeight/baseline pair
            -- the primitive path used -- imgui positions from the top-left with
            -- no baseline correction, so mixing the two metrics pushed the text
            -- out of the row entirely.
            local _, imguiNameH = imgui.CalcTextSize(tostring(nameToDraw or ''));
            nameX = namePosX + textOffsets.nameX;
            nameY = hpStartY - imguiNameH - settings.nameTextOffsetY + textOffsets.nameY;
        end
        drawOutlinedText(nameX, nameY, nameToDraw, nameColor);
    end

    -- Layout 0 (Horizontal): draw the queued HP / MP / TP / job / distance text.
    -- Done here, at the very end of DrawMember, so it lands on top of the window
    -- background and every bar -- the same approach layout 1 and the player bar
    -- use. Colors are ARGB ints from the config, converted for imgui.
    if pendingL0 ~= nil then
        local function drawPending(p, defaultColor)
            if p == nil or p.text == nil then return; end
            -- Values coming out of the text cache can be numbers; everything
            -- downstream (CalcTextSize, AddText) expects a string.
            local txt = tostring(p.text);
            if txt == '' then return; end
            local col = defaultColor;
            if p.color ~= nil then
                if type(p.color) == 'table' then
                    col = p.color;
                elseif type(p.color) == 'number' then
                    col = ARGBToImGui(p.color);
                end
            end
            drawOutlinedText(p.x, p.y, txt, col);
        end

        local white = {1, 1, 1, 1};
        drawPending(pendingL0.hp, white);
        drawPending(pendingL0.mp, white);
        drawPending(pendingL0.tp, white);
        drawPending(pendingL0.job, white);
        drawPending(pendingL0.distance, white);
    end

end

-- ============================================
-- DrawPartyWindow - Render a single party window
-- ============================================
function display.DrawPartyWindow(settings, party, partyIndex)
    local firstPlayerIndex = (partyIndex - 1) * data.partyMaxSize;
    local lastPlayerIndex = firstPlayerIndex + data.partyMaxSize - 1;

    local cache = data.partyConfigCache[partyIndex];
    local partyMemberCount = data.frameCache.activeMemberCount[partyIndex];
    local windowKey = 'party' .. partyIndex;

    if (partyIndex == 1 and not gConfig.showPartyListWhenSolo and partyMemberCount <= 1) then
        data.UpdateTextVisibility(false);
        data.invalidateWindowRect(windowKey);
        return;
    end

    if(partyIndex > 1 and partyMemberCount == 0) then
        data.UpdateTextVisibility(false, partyIndex);
        data.invalidateWindowRect(windowKey);
        return;
    end

    local backgroundPrim = data.partyWindowPrim[partyIndex].background;

    local titleUV;
    if (partyIndex == 1) then
        titleUV = partyMemberCount == 1 and data.titleUVs.solo or data.titleUVs.party;
    elseif (partyIndex == 2) then
        titleUV = data.titleUVs.partyB;
    else
        titleUV = data.titleUVs.partyC;
    end

    local imguiPosX, imguiPosY;

    -- Plain theme = clean imgui-drawn panel. All other themes are textured and
    -- use the windowBg prim for the fill. The theme dropdown is the only control.
    local plainBg = cache.backgroundName == 'Plain';

    local windowFlags = bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBringToFrontOnFocus, ImGuiWindowFlags_NoDocking);
    if not plainBg then
        windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoBackground);
    end

    -- ============================================
    -- Anchor resolution (party 2 / party 3)
    -- ============================================
    -- Party 1 is the chain root and never auto-anchors. Party B/C look up
    -- their configured parent in data.windowRects. Resolved here (before
    -- windowFlags is finalized and before Begin) so we can both add NoMove
    -- and queue SetNextWindowPos with the parent's rect.
    --
    -- Cross-module parent (castcost) reads last frame's rect since castcost
    -- renders after partylist this frame — one-frame lag, not visually noticeable.
    local anchoredPos = nil;
    if partyIndex >= 2 then
        local parentRect, anchorCfg = data.getAnchorParentRect(windowKey);
        if parentRect ~= nil then
            local selfRect = data.windowRects[windowKey];
            local selfH = (selfRect and selfRect.h) or 0;

            -- X: align child's left to parent's left. Both windows are designed
            -- around the same content width, so left-edge match looks natural.
            local newX = parentRect.x;
            local newY;
            if (anchorCfg.edge or 'above') == 'below' then
                newY = parentRect.y + parentRect.h + (anchorCfg.offsetY or 0);
            else
                -- 'above': child bottom kisses parent top + offsetY. Pull child
                -- up by its own height. offsetY is usually negative/zero so the
                -- child sits a few px above the parent.
                newY = parentRect.y - selfH + (anchorCfg.offsetY or 0);
            end
            anchoredPos = { newX, newY };
        end
    end

    -- Shift-gated drag: when partyListShiftDrag is on (default) the window only moves while
    -- the user is holding Shift. This prevents accidentally yanking the window when clicking
    -- on members (the row-wide click-to-target InvisibleButton overlaps the whole entry).
    -- Set gConfig.partyListShiftDrag = false to restore classic always-drag behavior.
    -- Anchored windows are NEVER user-movable (the anchor system owns position).
    local shiftDragActive = (gConfig.partyListShiftDrag ~= false) and not imgui.GetIO().KeyShift;
    if (gConfig.lockPositions or shiftDragActive or anchoredPos ~= nil) then
        windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoMove);
    end

    local windowName = 'PartyList';
    if (partyIndex > 1) then
        windowName = windowName .. partyIndex
    end

    local scale = data.getScale(partyIndex);
    local iconSize = 0;

    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, {0,0});
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { settings.barSpacing * scale.x, 0 });
    -- Panel style. Pushed unconditionally — the NoBackground window flag (set
    -- above when the theme is not Plain) is what actually controls whether imgui
    -- draws the WindowBg/Border.
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0, 0.06, 0.16, 0.9 });
    imgui.PushStyleColor(ImGuiCol_Border, { 0.3, 0.3, 0.5, 0.8 });
    -- Super compact uses tighter window padding so HP/MP values sit close to
    -- the visible panel border. The default {10, 6} leaves a 10 px dead zone
    -- between content right edge and visible panel right — looks like a "gap"
    -- between values and the panel edge.
    local winPad = (cache.layout == 2) and { 3, 3 } or { 10, 6 };
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, winPad);
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 4);

    -- Push the anchored position now that all StyleVars are set up.
    if anchoredPos ~= nil then
        imgui.SetNextWindowPos(anchoredPos, ImGuiCond_Always);
    end

    if (imgui.Begin(windowName, true, windowFlags)) then
        imguiPosX, imguiPosY = imgui.GetWindowPos();
        -- Capture Party 1's screen position so anchored sub-windows
        -- (Target Bar / Cast Cost) can be placed above it.
        if partyIndex == 1 then
            data.partyList1Pos.x = imguiPosX;
            data.partyList1Pos.y = imguiPosY;
        end

        -- Silver highlight lines on the top & bottom edges of the panel.
        -- Always drawn regardless of theme (decoration, not background fill).
        -- Anchored to the actual imgui window rect (includes WindowPadding).
        -- Uses the foreground draw list so imgui's own Border can't paint over it.
        do
            local _silverW, _silverH = imgui.GetWindowSize();
            local _silverX2 = imguiPosX + (_silverW or 0);
            local _silverY2 = imguiPosY + (_silverH or 0);
            local _silverCol = imgui.GetColorU32({ 0.75, 0.78, 0.85, 0.95 });
            local _silverFg = imgui.GetForegroundDrawList();
            _silverFg:AddLine({ imguiPosX + 3, imguiPosY + 1 }, { _silverX2 - 3, imguiPosY + 1 }, _silverCol, 1.0);
            _silverFg:AddLine({ imguiPosX + 3, _silverY2 - 1 }, { _silverX2 - 3, _silverY2 - 1 }, _silverCol, 1.0);
        end

        if cache.layout == 2 then
            -- Super compact draws the name INSIDE each entry (at the row's
            -- entryTop), so the negative-Y "above-the-bar" reserve that layout
            -- 0 needs doesn't apply here. A tiny top pad keeps the first row
            -- from kissing the title texture / panel border.
            imgui.Dummy({0, 2});
        elseif cache.layout == 1 then
            -- HXUI Compact Vertical also draws the name ON the bar (no row above),
            -- so it gets a small top pad rather than the name-row reserve that
            -- layout 0 uses. The name straddles the HP bar's TOP edge, so reserve
            -- about half the name height as headroom so it doesn't clip the panel
            -- top. This removes the big dead gap while keeping the name visible.
            local nameRefHeight = data.partyRefHeights[partyIndex].nameRefHeight;
            imgui.Dummy({0, math.floor(nameRefHeight / 2) + 2});
        else
            local nameRefHeight = data.partyRefHeights[partyIndex].nameRefHeight;
            local offsetSize = nameRefHeight > iconSize and nameRefHeight or iconSize;
            imgui.Dummy({0, settings.nameTextOffsetY + offsetSize});
        end

        data.UpdateTextVisibility(true, partyIndex);

        -- Per-party sizing: Dynamic (cache.expandHeight=false, default) draws
        -- only the live members. Expand Height (cache.expandHeight=true) forces
        -- all 6 slots like retail. Used to be gated on partyIndex==1 — that's
        -- the long-standing bug where B/C ignored their own Expand Height
        -- checkbox. minRows is the per-party floor for either mode.
        local expandThis = cache.expandHeight == true;
        local minRowsThis = cache.minRows or 1;

        local lastVisibleMemberIdx = firstPlayerIndex;
        for i = firstPlayerIndex, lastPlayerIndex do
            local relIndex = i - firstPlayerIndex
            if (expandThis or relIndex < partyMemberCount or relIndex < minRowsThis) then
                lastVisibleMemberIdx = i;
            end
        end

        for i = firstPlayerIndex, lastPlayerIndex do
            local relIndex = i - firstPlayerIndex
            if (expandThis or relIndex < partyMemberCount or relIndex < minRowsThis) then
                display.DrawMember(i, settings, i == lastVisibleMemberIdx);
            else
                data.UpdateTextVisibilityByMember(i, false);
            end
        end
    end

    local menuWidth, menuHeight = imgui.GetWindowSize();

    local layout = cache.layout or 0;
    if layout == 0 then
        local barScales = data.getBarScales(partyIndex);
        local layoutTemplate = data.getLayoutTemplate(partyIndex);
        local showTP = data.showPartyTP(partyIndex);
        local hpScaleX = barScales and barScales.hpBarScaleX or 1;
        local mpScaleX = barScales and barScales.mpBarScaleX or 1;
        local tpScaleX = barScales and barScales.tpBarScaleX or 1;
        local baseHpWidth = (layoutTemplate.hpBarWidth or 150) * PARTY_BAR_BASE_WIDTH_MULT;
        local baseMpWidth = (layoutTemplate.mpBarWidth or 100) * PARTY_BAR_BASE_WIDTH_MULT;
        local baseTpWidth = (layoutTemplate.tpBarWidth or 100) * PARTY_BAR_BASE_WIDTH_MULT;
        local baseBarSpacing = layoutTemplate.barSpacing or 8;
        local minWidth = baseHpWidth * scale.x * hpScaleX;
        -- Only include MP bar width if alwaysShowMpBar is enabled
        if cache.alwaysShowMpBar then
            minWidth = minWidth + baseBarSpacing * scale.x + baseMpWidth * scale.x * mpScaleX;
        end
        if showTP then
            minWidth = minWidth + baseBarSpacing * scale.x + baseTpWidth * scale.x * tpScaleX;
        end
        menuWidth = math.max(menuWidth, minWidth);
    end

    data.fullMenuWidth[partyIndex] = menuWidth;
    data.fullMenuHeight[partyIndex] = menuHeight;

    -- Calculate background dimensions (needed for title positioning)
    local bgWidth = data.fullMenuWidth[partyIndex] + (settings.bgPadding * 2);

    -- Update background and borders using windowbackground library. The textured
    -- prim only shows for non-Plain themes; Plain hides it (imgui draws instead).
    local bgOptions = {
        theme = cache.backgroundName,
        -- padding/paddingY forced to 0 so the textured prim renders within
        -- the imgui window bounds, same footprint as the Plain theme. The
        -- theme selector only changes the fill, not the panel size.
        padding = 0,
        paddingY = 0,
        bgScale = cache.bgScale,
        borderScale = cache.borderScale,
        bgOpacity = plainBg and 0 or cache.backgroundOpacity,
        bgColor = cache.colors.bgColor,
        borderSize = settings.borderSize,
        bgOffset = settings.bgOffset,
        borderOpacity = plainBg and 0 or cache.borderOpacity,
        borderColor = cache.colors.borderColor,
    };
    windowBg.update(backgroundPrim, imguiPosX, imguiPosY, data.fullMenuWidth[partyIndex], data.fullMenuHeight[partyIndex], bgOptions);

    -- Draw title (skip foreground rendering when modal is open to respect dim overlay)
    if (cache.showTitle and data.partyTitlesTexture ~= nil and not _XIUI_MODAL_OPEN) then
        local titleImage = tonumber(ffi.cast("uint32_t", data.partyTitlesTexture.image));
        local titleWidth = data.partyTitlesTexture.width;
        local titleHeight = data.partyTitlesTexture.height / 4;
        -- Super compact panels are much narrower than horizontal/compact, so the
        -- regular 0.8 title texture reads as oversized. Use a smaller scale for
        -- layout 2 so the title doesn't dominate the panel visually.
        local titleScale = (cache.layout == 2) and 0.5 or 0.8;
        titleWidth = titleWidth * titleScale;
        titleHeight = titleHeight * titleScale;
        local titlePosX = imguiPosX + math.floor((bgWidth / 2) - (titleWidth / 2));
        -- Center the title vertically on the panel's top border (half above, half
        -- below) without affecting the panel's content area.
        local titlePosY = imguiPosY - math.floor(titleHeight / 2);
        local draw_list = imgui.GetForegroundDrawList();
        draw_list:AddImage(
            titleImage,
            {titlePosX, titlePosY},
            {titlePosX + titleWidth, titlePosY + titleHeight},
            {titleUV[1], titleUV[2]}, {titleUV[3], titleUV[4]},
            IM_COL32_WHITE
        );

        -- Status indicators flanking the title.
        --   LEFT  (gold): "Treas." - lit when the pool has any items.
        --   RIGHT (cyan): "Trade" / "Invite" - split out individually so a
        --                 trade request and an invite are distinguishable.
        --                 If both fire at once, both labels render stacked.
        -- Party 1 only (never on alliance parties B/C). No showConfig gate -
        -- the indicators are live state, not preview-only. The previous version
        -- accidentally gated on showConfig[1] which meant they only rendered
        -- while the config window was open. Preview mode is handled per-label
        -- below via gConfig.partyListPreview.
        if partyIndex == 1 then
            -- Match the codebase convention: preview only counts when the
            -- config window is open AND the preview toggle is on. Using
            -- gConfig.partyListPreview alone leaves the labels showing after
            -- the config window is closed (the toggle persists). Mirrors
            -- previewActive at line 2871 and the data.lua preview gate.
            local previewMode = (showConfig and showConfig[1] and gConfig.partyListPreview) == true;

            -- Real pool state via the treasurepool module. pcall'd so a missing
            -- treasurepool module doesn't crash the partylist render - the icon
            -- just won't appear.
            local hasTreasure = false;
            local ok, tpData = pcall(require, 'modules.treasurepool.data');
            if ok and tpData ~= nil and type(tpData.HasItems) == 'function' then
                local ok2, result = pcall(tpData.HasItems);
                if ok2 then hasTreasure = (result == true); end
            end

            local hasInvite = false;
            if type(data.HasPendingInvite) == 'function' then
                local ok3, result3 = pcall(data.HasPendingInvite);
                if ok3 then hasInvite = (result3 == true); end
            end
            local hasTrade = false;
            if type(data.HasTradeRequest) == 'function' then
                local ok4, result4 = pcall(data.HasTradeRequest);
                if ok4 then hasTrade = (result4 == true); end
            end

            -- Use the existing drawOutlinedText helper (file-local at line 103)
            -- which is the same path every other label in the addon uses (HP%,
            -- TP, names). Earlier hand-rolled AddText calls here may have hit
            -- a font context issue on the foreground draw list - this version
            -- goes through the proven helper.
            local GOLD = {1.0, 0.84, 0.0, 1.0};
            local CYAN = {0.20, 0.80, 1.0, 1.0};

            -- Treasure (left) - gold "Treas." Right-aligned so the text grows
            -- away from the title.
            if previewMode or hasTreasure then
                local label = 'Treas.';
                local tw, th = imgui.CalcTextSize(label);
                local tx = titlePosX - tw - 6;
                local ty = titlePosY + math.floor((titleHeight - th) / 2);
                drawOutlinedText(tx, ty, label, GOLD);
            end

            -- Trade / Invite (right) - cyan, each on its own line so you can
            -- see both when they fire at once. Left-aligned so they grow away
            -- from the title; vertically centered as a block.
            local rightLabels = {};
            if previewMode or hasTrade  then rightLabels[#rightLabels + 1] = 'Trade';  end
            if previewMode or hasInvite then rightLabels[#rightLabels + 1] = 'Invite'; end
            if #rightLabels > 0 then
                local _, lineH = imgui.CalcTextSize('Ag');
                local blockH = lineH * #rightLabels;
                local startY = titlePosY + math.floor((titleHeight - blockH) / 2);
                local rx = titlePosX + titleWidth + 6;
                for i, label in ipairs(rightLabels) do
                    drawOutlinedText(rx, startY + (i - 1) * lineH, label, CYAN);
                end
            end
        end
    end

    imgui.End();
    imgui.PopStyleVar(4);     -- FramePadding, ItemSpacing, WindowPadding, WindowRounding
    imgui.PopStyleColor(2);   -- WindowBg, Border

    -- Handle bottom alignment. Skipped while the window is anchored — the
    -- anchor system owns position and a competing SetWindowPos here would
    -- flicker the window between two locations every frame.
    if (settings.alignBottom and imguiPosX ~= nil and anchoredPos == nil) then
        if (partyIndex == 1 and gConfig.partyListState ~= nil and gConfig.partyListState.x ~= nil) then
            local oldValues = gConfig.partyListState;
            gConfig.partyListState = {};
            gConfig.partyListState[partyIndex] = oldValues;
            ashita_settings.save();
        end

        if (gConfig.partyListState == nil) then
            gConfig.partyListState = {};
        end

        local partyListState = gConfig.partyListState[partyIndex];

        if (partyListState ~= nil) then
            if (menuHeight ~= partyListState.height) then
                local newPosY = partyListState.y + partyListState.height - menuHeight;
                imguiPosY = newPosY;
                imgui.SetWindowPos(windowName, { imguiPosX, imguiPosY });
            end
        end

        if (partyListState == nil or
                imguiPosX ~= partyListState.x or imguiPosY ~= partyListState.y or
                menuWidth ~= partyListState.width or menuHeight ~= partyListState.height) then
            gConfig.partyListState[partyIndex] = {
                x = imguiPosX,
                y = imguiPosY,
                width = menuWidth,
                height = menuHeight,
            };
            data.lastSettingsSaveTime = os.clock();
            data.pendingSettingsSave = true;
        end
    end

    -- ============================================
    -- Rect capture (for anchor system)
    -- ============================================
    -- Publish the final rect so other windows in the anchor chain can stack
    -- against this one. Includes any alignBottom Y adjustment above.
    if imguiPosX ~= nil and menuWidth and menuHeight then
        data.captureWindowRect(windowKey, imguiPosX, imguiPosY, menuWidth, menuHeight);
    else
        data.invalidateWindowRect(windowKey);
    end
end

-- ============================================
-- Anchored Target Bar
-- ============================================
-- Renders the current target's HP/name in a small window anchored above
-- Party 1. Toggled by gConfig.showPartyListTarget. Always anchored — there
-- is no separate position option (matches HXUI behaviour).
--
-- Includes the same activity-flag status icons HXUI exposes:
--   LFP (Looking for Party / Seeking)   - entityActionStatus 47
--   Baz (Bazaar)                         - entityActionStatus 85
--   Away                                 - entitySearchFlags bit 0x01
--   Mtr (Mentor)                         -                  bit 0x02
--   New (New Adventurer)                 -                  bit 0x04
--   LFG (Looking for Group, in party)    -                  bit 0x08
-- Also draws a yellow Level Sync dot (buff 233) on the top-right corner.
function display.DrawCurrentTarget(settings)
    if not gConfig.showPartyListTarget then
        if data.targetWindowPrim.background then windowBg.hide(data.targetWindowPrim.background); end
        data.invalidateWindowRect('target', true);  -- hard: feature disabled, no layout
        return;
    end
    if data.partyList1Pos.x == 0 and data.partyList1Pos.y == 0 then
        if data.targetWindowPrim.background then windowBg.hide(data.targetWindowPrim.background); end
        data.invalidateWindowRect('target', true);  -- hard: no party 1 anchor source
        return;
    end

    local cache     = data.partyConfigCache[1];        -- target attaches to Party 1
    local scale     = data.getScale(1);
    -- Plain theme = clean imgui-drawn panel. All other themes use the textured prim.
    local plainBg   = cache.backgroundName == 'Plain';

    -- Lazily create the target bg primitive (used by non-Plain themes), mirroring
    -- party 1's textured-bg theme so the target window visually matches the party
    -- panel. Refresh the theme when party 1's bg changes.
    if data.targetWindowPrim.background == nil then
        data.targetWindowPrim.background = windowBg.create(
            settings.prim_data,
            cache.backgroundName,
            cache.bgScale or 1.0,
            cache.borderScale or 1.0
        );
        data.targetLoadedBg = cache.backgroundName;
    elseif cache.backgroundName ~= data.targetLoadedBg then
        windowBg.setTheme(
            data.targetWindowPrim.background,
            cache.backgroundName,
            cache.bgScale or 1.0,
            cache.borderScale or 1.0
        );
        data.targetLoadedBg = cache.backgroundName;
    end

    local barHeight = settings.barHeight * scale.y;
    local padding   = 4;
    local rowGap    = 1;
    local textGap   = 2;
    -- WindowPadding is {10, 6} instead of `padding`, so the usable bar width
    -- shrinks by the extra horizontal padding.
    local padExtra = 12;  -- (10 - padding) * 2
    -- The party PANEL background is drawn at fullMenuWidth + bgPadding*2 (see the
    -- party render's bgWidth). The target box previously used only fullMenuWidth,
    -- so it was bgPadding*2 narrower than the party panel below it. Add the same
    -- bgPadding*2 so the target box width matches the party panel exactly.
    local bgPad      = settings.bgPadding or 8;
    local winW       = (data.fullMenuWidth[1] or (settings.hpBarWidth * scale.x + padding * 2)) + (bgPad * 2);
    -- The target window uses WindowPadding {10,6}. To match the party panel,
    -- the bar fills the usable width = winW - 2*winPadX (winPadX=10 below).
    local barWidth   = winW - 20;

    -- Title overhang above imguiPosY: half the title texture height (the title
    -- is drawn centered on the panel's top border).
    local titleOverhang = 0;
    if cache.showTitle and data.partyTitlesTexture ~= nil then
        local titleScale = (cache.layout == 2) and 0.5 or 0.8;
        local rawTitleH = (data.partyTitlesTexture.height / 4) * titleScale;
        titleOverhang = math.floor(rawTitleH / 2);
    end

    -- ----------- Preview mode: set fake values, then fall through to the SAME
    -- render path as a live target so they always match (locked styling, arrows,
    -- edge labels, etc. are identical). -----------
    local previewActive = (showConfig and showConfig[1] and gConfig.partyListPreview) == true;

    -- ----------- Real mode: actual current target -----------
    local entity, playerTarget, t1, targetName, targetHPP, isLocked;

    if previewActive then
        targetName = 'Player 1';
        targetHPP  = 0.75;
        isLocked   = true;          -- show the locked styling in preview
    else
        entity       = AshitaCore:GetMemoryManager():GetEntity();
        playerTarget = AshitaCore:GetMemoryManager():GetTarget();
        if entity == nil or playerTarget == nil then
            data.invalidateWindowRect('target', true);  -- hard: API gone
            if data.targetWindowPrim.background then windowBg.hide(data.targetWindowPrim.background); end
            return;
        end

        -- During sub-target (e.g., /ma "Cure" <stpc>, /ja "Provoke" <stnpc>),
        -- swap the target bar to show the sub-target cursor selection instead
        -- of the held main target. frameCache.t2 is the cursor selection when
        -- sub-targeting is active; frameCache.t1 stays on the original main
        -- target so the bar snaps back automatically when sub-targeting ends.
        -- Falls back to t1 if t2 is nil/0 (defensive: sub-target flag set but
        -- cursor index not yet populated this frame).
        if data.frameCache.subTargetActive and data.frameCache.t2 ~= nil and data.frameCache.t2 ~= 0 then
            t1 = data.frameCache.t2;
        else
            t1 = data.frameCache.t1;
        end
        if t1 == nil or t1 == 0 then
            -- Soft invalidate: no target held this frame, but the bar's last
            -- known dimensions stay usable so the enemy list (and anything
            -- else anchored to target) doesn't snap to its absolute position
            -- between targets. Cast cost still stacks flush because it
            -- checks .visible, which we just cleared.
            data.invalidateWindowRect('target');
            if data.targetWindowPrim.background then windowBg.hide(data.targetWindowPrim.background); end
            return;
        end

        targetName = entity:GetName(t1);
        targetHPP  = entity:GetHPPercent(t1) / 100;
        if targetName == nil or targetName == '' then
            -- Soft invalidate: transient race condition (target index set but
            -- name not loaded this frame). Same reasoning as no-target above.
            data.invalidateWindowRect('target');
            if data.targetWindowPrim.background then windowBg.hide(data.targetWindowPrim.background); end
            return;
        end

        -- Target lock-on (player /lockon).
        isLocked = GetIsTargetLockedOn() == true;
    end


    -- Distance to target (square-rooted; entity:GetDistance returns squared).
    local distance = nil;
    pcall(function()
        local dSq = entity:GetDistance(t1);
        if dSq and dSq > 0 then distance = math.sqrt(dSq); end
    end);

    local spawnType = 0;
    pcall(function() spawnType = entity:GetSpawnFlags(t1); end);

    -- entityActionStatus: action status. 47=Seeking(LFP), 85=Bazaar. This is
    -- the "what is the player doing" enum, not the name-flag bitfield.
    local entityActionStatus = 0;
    pcall(function()
        local s = entity:GetStatus(t1);
        if s ~= nil then entityActionStatus = s; end
    end);

    -- entityRenderFlags1: Name flags (Party / Away / Anon / Mentor / New / etc).
    -- entityRenderFlags2: Name flags (Bazaar / GM Icon / etc).
    -- These come from the FFXI entity struct's render_t.Flags1 and Flags2
    -- fields - the bits that control which icons FFXI itself draws next to
    -- the target's name. Reading them via Ashita's GetRenderFlags1/2 (NOT
    -- GetStatusServer, which is action status - a different field entirely).
    local entityRenderFlags1 = 0;
    local entityRenderFlags2 = 0;
    local entityRenderFlags4 = 0;
    pcall(function()
        local f = entity:GetRenderFlags1(t1);
        if f ~= nil then entityRenderFlags1 = f; end
    end);
    pcall(function()
        local f = entity:GetRenderFlags2(t1);
        if f ~= nil then entityRenderFlags2 = f; end
    end);
    pcall(function()
        local f = entity:GetRenderFlags4(t1);
        if f ~= nil then entityRenderFlags4 = f; end
    end);

    -- Sync detection is now a single bit check in the constants block below
    -- (F4_SYNC). All the party API / IPlayer buff / statushandler fallback
    -- chain is gone - render flags are the source of truth, same as the icon
    -- the game itself draws above the player's head.
    local targetIsSynced = false;

    -- Preview overrides (entity reads above are no-ops in preview).
    if previewActive then
        distance       = 3.0;
        targetIsSynced = true;
    end


    -- =========================================================================
    -- FFXI name flag decoding.
    -- =========================================================================
    -- Flags1 byte 2 (bits 16-23) is a BIT FIELD, not an enum. Multiple flags
    -- can be set at the same time (e.g. /sea on + /away = 0x10 | 0x40 = 0x50).
    -- Flags2 holds the bazaar/GM bits separately.
    -- Flags4 holds the sync / "in any party" bits (the latter drives the
    -- blue name color in native FFXI for any party member regardless of
    -- whether they're in your party or someone else's).
    --
    -- TO UPDATE A GUESS: target a player with the known status, target a clean
    -- baseline (no status), and XOR the two captures - the differing bit IS
    -- the bit. Update the constant here, no other change needed.
    -- =========================================================================
    local statusByte = bit.band(bit.rshift(entityRenderFlags1, 16), 0xFF);

    -- Flags1 bits (Party / Away / Anon block):
    local FB_LFP_BIT     = 0x10;  -- CONFIRMED  /sea on, seeking party
    local FB_AWAY_BIT    = 0x40;  -- CONFIRMED  /away toggle
    local FB_NAME_BLUE   = 0x80;  -- CONFIRMED  client says "render name BLUE".
                                  --            Confirmed triggers: /anon (Luan).
                                  --            Possibly also fires in other
                                  --            party-related states. Treat as
                                  --            a black box: bit set = blue.
                                  --            Note Autoshot (party leader of
                                  --            another party, not /anon) had
                                  --            this bit CLEAR and rendered
                                  --            white - so "in another party"
                                  --            is NOT a reliable trigger.
    local FB_MENTOR_BIT  = 0x20;  -- GUESS      mentor icon - confirm with M-flagged target

    -- Flags2 bits (Bazaar / GM / GMDev block):
    local F2_BAZAAR      = 0x00000200;  -- CONFIRMED  /bazaar item set up
    -- HorizonXI staff detection - CONFIRMED via 4-way capture XOR:
    --   Cow (self, no flags): Flags2 0xA0020001
    --   Dwingvatt (random):   Flags2 0xA0020001
    --   Gildas (GM, hard red): Flags2 0xA0023001  -> +0x3000 vs normal
    --   Ceodon (GMDev, lt red): Flags2 0xA0023801 -> +0x3800 vs normal
    -- The 0x1000 bit is set on BOTH staff and NEITHER normal player -> that's
    -- the clean "is staff" discriminator. The 0x800 bit is set only on Ceodon
    -- (GMDev), so it splits GMDev from plain GM.
    local F2_STAFF       = 0x00001000;  -- CONFIRMED  set on GM and GMDev, not normals
    local F2_GMDEV       = 0x00000800;  -- CONFIRMED  GMDev only (Ceodon), splits from GM

    local isStaff = bit.band(entityRenderFlags2, F2_STAFF) ~= 0;
    local isGMDev = isStaff and bit.band(entityRenderFlags2, F2_GMDEV) ~= 0;
    local isGM    = isStaff and not isGMDev;

    -- Flags4 bits.
    --   F4_SYNC (0x00800000)    - Level Sync. CONFIRMED.
    --   F4_NEW_ADV (0x00002000) - New Adventurer "?" icon. CONFIRMED via Jinada
    --     (sb=0x00 f4=0x40002000) vs baseline Cow (f4=0x40000000).
    --   0x01000000 - previously guessed as "in MY party" but Fru (HzXI hardcore
    --     stranger, NOT in user party) and Autoshot (party leader of another
    --     party, NOT in user party) also had this bit set, so the guess was
    --     wrong. Likely tied to action state or some other render condition.
    --     Demoted to unknown.
    --   POSSIBLE: f0 bit 0x80000000 may be "party leader" - Autoshot (leader)
    --     showed f0=0x80000200 while non-leaders show 0x00000200. Needs more
    --     data to confirm.
    local F4_SYNC      = 0x00800000;  -- CONFIRMED
    local F4_NEW_ADV   = 0x00002000;  -- CONFIRMED

    local isLFP        = bit.band(statusByte, FB_LFP_BIT)     ~= 0;
    local isAway       = bit.band(statusByte, FB_AWAY_BIT)    ~= 0;
    local isNameBlue   = bit.band(statusByte, FB_NAME_BLUE)   ~= 0;
    local isMentor     = bit.band(statusByte, FB_MENTOR_BIT)  ~= 0;
    local isNew        = bit.band(entityRenderFlags4, F4_NEW_ADV) ~= 0 and not isStaff;
    local hasBazaar    = bit.band(entityRenderFlags2, F2_BAZAAR) ~= 0;
    local hasGmIcon    = isStaff;   -- GM or GMDev (see F2_STAFF above)

    -- Wire sync into the shared targetIsSynced flag (declared above before
    -- preview override). Preview already forces targetIsSynced=true.
    -- PC guard: the F4_SYNC bit also fires on NPCs for unrelated reasons,
    -- so only honor it for player-character targets. (The proper isPC local
    -- is computed in the name color block below; we recompute the bit here
    -- so we don't have to hoist the whole block.)
    if not previewActive
        and bit.band(spawnType, 0x01) ~= 0
        and bit.band(entityRenderFlags4, F4_SYNC) ~= 0
    then
        targetIsSynced = true;
    end
    -- NOTE: members of YOUR OWN party have statusByte 0x00 (FFXI doesn't set
    -- the byte for your own party because you can already see them in your
    -- party list - no marker needed). The 0x80 byte fires only for members
    -- of OTHER parties, which is the case native FFXI colors blue.
    -- NOTE: bazaar is NOT in this byte either. Don't try to use 0x80 for
    -- the bazaar icon. Bazaar lives in a different field we haven't isolated.

    -- Name color logic mirroring FFXI conventions:
    --   PC in MY party       : blue (via party API)
    --   PC in other party    : blue (via Flags1 statusByte 0x80)
    --   PC alone             : white
    --   NPC (spawnType 0x02) : green
    --   Mob, claimed         : red
    --   Mob, unclaimed       : yellow
    --
    -- Party members go blue (yours via party API, others via 0x80 byte).
    -- EXCEPTION: targeting yourself stays white - you don't get marked as
    -- a party member of yourself. Skip the blue logic when the target's
    -- serverId matches the player's own serverId.
    local nameColor = {1, 1, 1, 1};
    local isPC  = bit.band(spawnType, 0x01) ~= 0;
    local isNPC = bit.band(spawnType, 0x02) ~= 0;
    local isMob = bit.band(spawnType, 0x10) ~= 0;
    if isPC then
        local mySid = 0;
        pcall(function()
            mySid = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0) or 0;
        end);
        local tid = 0;
        pcall(function() tid = entity:GetServerId(t1) or 0; end);
        local isSelf = (mySid ~= 0 and tid == mySid);

        -- /anon (and other 0x80 triggers) recolor the name blue for ANY PC,
        -- including yourself. Applied unconditionally so targeting your own
        -- /anon'd character still goes blue, matching native FFXI behavior.
        if isNameBlue then
            nameColor = {0.45, 0.70, 1.0, 1.0};
        end

        -- MY party member via the party API. Same blue. Skip the lookup when
        -- targeting self - you're not in your own party API list.
        if not isSelf then
            local party = AshitaCore:GetMemoryManager():GetParty();
            if party ~= nil then
                for i = 0, 17 do
                    if party:GetMemberIsActive(i) ~= 0 and party:GetMemberServerId(i) == tid then
                        nameColor = {0.45, 0.70, 1.0, 1.0};
                        break;
                    end
                end
            end
        end
        -- LFP also recolors the name in native FFXI (matches the LFP icon).
        -- Applied last so LFP overrides plain party blue when both are set.
        -- Applies even when targeting yourself - native FFXI recolors your
        -- own name too when /sea is on.
        if isLFP then
            nameColor = {0.45, 0.70, 1.00, 1.0};
        end

        -- Staff name colors (highest priority - override party/LFP blue).
        -- Matches HorizonXI: GM = hard red, GMDev = lighter red/pink.
        if isGM then
            nameColor = {1.00, 0.20, 0.20, 1.0};   -- GM hard red
        elseif isGMDev then
            nameColor = {1.00, 0.50, 0.50, 1.0};   -- GMDev light red
        end
    elseif isNPC then
        nameColor = {0.45, 0.95, 0.45, 1.0};   -- NPC green
    elseif isMob then
        local claimed = false;
        pcall(function()
            local cs = entity:GetClaimStatus(t1);
            if cs ~= nil and cs ~= 0 then claimed = true; end
        end);
        if claimed then
            nameColor = {1.0, 0.35, 0.35, 1.0};       -- Claimed red
        else
            nameColor = {1.0, 0.85, 0.30, 1.0};       -- Unclaimed yellow
        end
    end

    -- Pick the single status icon to show (mirrors retail FFXI's player
    -- icon priority: only one icon at a time per player).
    --   Mentor > NewAdv > Sync > Away > LFP
    --
    -- The status byte (Flags1 bits 16-23) is an ENUM, not OR'd bit flags.
    -- Constants are defined above (hoisted for the name color block).
    -- Confirmed values:
    --   0x00 = no flag (alone OR in MY party - FFXI omits the byte for
    --          your own party members since they're in your party list)
    --   0x10 = LFP    (Derezz:     0x0A100800) - "party flag" / searching
    --   0x50 = Away   (Cowrevenge: 0x0A500800) - /away toggle
    --   0x80 = In another party (Doublesoul: 0x0A800800) - drives the blue
    --          name above. Does NOT mean bazaar.
    -- Still unknown (debug print logs every target so we'll spot them):
    --   Mentor, NewAdventurer, Bazaar.
    --   - NewAdv: Xeen was 0x00 while in-my-party + new-adv + on chocobo,
    --     so the new-adv signal likely lives in another field (Flags0/3/4
    --     or StatusServer) - the wide debug print will catch it.
    --   - Bazaar: Ozn showed 0x80 same as in-other-party Doublesoul, so
    --     bazaar isn't separable on this byte either.
    --   - Mentor: untested, still a guess.

    local statusIconKey, statusIconLabel, statusIconColor = nil, nil, nil;
    -- Link-dead (D/C) is the HIGHEST priority status: bit 0x10000000 in Flags1
    -- (confirmed via Meenners D/C capture 0x1A800800 vs normal 0x0A000000).
    -- Drawn even when LFP/Away/Bazaar/etc are also set.
    local isLinkDead = isPC and bit.band(entityRenderFlags1, 0x10000000) ~= 0;
    if isLinkDead then
        statusIconKey, statusIconLabel, statusIconColor = 'lfp',  'D/C',   {0.60, 0.60, 0.60, 1.0};
    elseif isPC and isGMDev then
        -- HorizonXI GMDev (light red name). Distinct from plain GM.
        statusIconKey, statusIconLabel, statusIconColor = 'gm',  'GMDev', {1.00, 0.50, 0.50, 1.0};
    elseif isPC and isGM then
        -- HorizonXI GM (hard red name).
        statusIconKey, statusIconLabel, statusIconColor = 'gm',  'GM',    {1.00, 0.20, 0.20, 1.0};
    elseif isPC and isMentor then
        statusIconKey, statusIconLabel, statusIconColor = 'mentor', 'Mtr',  {1.00, 0.85, 0.30, 1.0};
    elseif isPC and isNew then
        statusIconKey, statusIconLabel, statusIconColor = 'new',    'New',  {0.40, 0.90, 0.40, 1.0};
    elseif targetIsSynced then
        statusIconKey, statusIconLabel, statusIconColor = 'sync',   'Sync', {1.00, 0.92, 0.20, 1.0};
    elseif isPC and isAway then
        statusIconKey, statusIconLabel, statusIconColor = 'away',   'Away', {0.55, 0.55, 0.55, 1.0};
    elseif isPC and isLFP then
        statusIconKey, statusIconLabel, statusIconColor = 'lfp',    'LFP',  {0.45, 0.70, 1.00, 1.0};
    elseif isPC and hasBazaar then
        statusIconKey, statusIconLabel, statusIconColor = 'bazaar', 'Baz',  {1.00, 0.80, 0.20, 1.0};
    end
    if statusIconKey ~= nil then ensureTargetStatusIcons(); end

    local _, hpGradient    = GetCustomHpColors(targetHPP, cache.colors);
    local bgGradOverride   = {'#000813', '#000813'};

    local anchorX = data.partyList1Pos.x - (settings.bgPadding or 8);
    -- Gap between the target window and the party list. Pull the target DOWN by
    -- half the title overhang to halve the visible gap, then bump UP a few px so
    -- it sits slightly off the "Party" title / Player row below it.
    local targetBumpUp = 4;  -- px to lift the target off the party title
    local targetPartyGap = -(titleOverhang * 0.5);
    local anchorY = data.partyList1Pos.y - titleOverhang - 0 - data.targetWindowPrevH - targetPartyGap - targetBumpUp;

    imgui.SetNextWindowPos({anchorX, anchorY}, ImGuiCond_Always);
    imgui.SetNextWindowSize({winW, 0}, ImGuiCond_Always);
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding,  {0, 0});
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing,   {settings.barSpacing * scale.x, 0});
    -- Match the party panel's WindowPadding so the bar lands centered.
    -- padExtra (12) was sized for {10,6}, so the padding push has to match.
    local winPadX = 10;
    local winPadY = 6;
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {winPadX, winPadY});

    local windowFlags = bit.bor(
        ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoMove,
        ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse,
        ImGuiWindowFlags_NoBringToFrontOnFocus
    );
    -- The visible panel is hand-drawn at the REAL box size below (or supplied
    -- by the textured prim for non-Plain themes). The
    -- imgui window itself must be transparent (NoBackground) so the oversized
    -- invisible content area doesn't render as a big blue box.
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0, 0, 0, 0 });
    imgui.PushStyleColor(ImGuiCol_Border,   { 0, 0, 0, 0 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 4);
    windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoBackground);

    local wX, wY, wW, wH = anchorX, anchorY, winW, 0;
    -- Real-box rect (the visible box, smaller than the oversized invisible
    -- content). Exported from the Begin block so the textured bg can
    -- be sized to it instead of the oversized content (which wastes space).
    local realBoxY1, realBoxY2 = nil, nil;

    if imgui.Begin('PartyListTarget', true, windowFlags) then
        wX, wY = imgui.GetWindowPos();

        local function outlined(x, y, col, text)
            -- Draw on the FOREGROUND list so text composites ON TOP of the HP bar
            -- (imgui.TextColored landed on the window list UNDER the bar). 4-dir
            -- black outline + colored fill via AddText.
            local dl = imgui.GetForegroundDrawList();
            local s = tostring(text);
            local blackU = imgui.GetColorU32({0, 0, 0, 1});
            local fillU  = imgui.GetColorU32(col);
            dl:AddText({x - 1, y}, blackU, s);
            dl:AddText({x + 1, y}, blackU, s);
            dl:AddText({x, y - 1}, blackU, s);
            dl:AddText({x, y + 1}, blackU, s);
            dl:AddText({x, y}, fillU, s);
        end

        local _, lineH = imgui.CalcTextSize('A');
        -- Vertical margins of the INVISIBLE (content) box that extend past the
        -- visible panel, so "Target" can straddle the top edge and "Locked" the
        -- bottom edge (retail look) without being clipped.
        local edgeOverhang = math.floor(lineH / 2) + 1;

        -- (1) INVISIBLE BOX FIRST: claim the full content rect = top overhang +
        -- name row + bar + bottom overhang. This extends the clip region so the
        -- edge labels aren't cut. Nothing visible is drawn by the Dummy.
        local originX, originY = imgui.GetCursorScreenPos();
        local contentTop   = originY;
        local nameRowY     = contentTop + edgeOverhang;        -- name row
        local barTopY      = nameRowY + lineH + 2;             -- bar below name
        local realBoxTop   = nameRowY;                         -- visible panel top
        local realBoxBot   = barTopY + barHeight;              -- visible panel bottom
        local contentBot   = realBoxBot + edgeOverhang;        -- + bottom overhang
        imgui.SetCursorScreenPos({ originX, contentTop });
        imgui.Dummy({ winW, contentBot - contentTop });

        -- Real-box rect (the visible panel), inset from the content box by the
        -- overhang on top and bottom. +2px on each edge for a slightly taller box.
        local rbX1, rbY1 = wX, realBoxTop - winPadY - 2;
        local rbX2, rbY2 = wX + winW, realBoxBot + winPadY + 2;
        realBoxY1, realBoxY2 = rbY1, rbY2;   -- export for textured bg sizing

        -- (2) REAL BOX: the visible background panel at the smaller real size.
        -- Only the FILL is gated — silver edges and border outline are panel
        -- decorations, not background fill, so they stay regardless of theme.
        if plainBg then
            imgui.GetWindowDrawList():AddRectFilled(
                { rbX1, rbY1 }, { rbX2, rbY2 },
                imgui.GetColorU32({ 0, 0.06, 0.16, 0.9 }), 4
            );
        end
        -- Silver highlight lines on the top & bottom edges. Drawn on the
        -- FOREGROUND draw list so the textured background primitive (separate
        -- pass, drawn later) cannot paint over them — previously the bottom
        -- silver line was getting covered/clipped by the bg prim.
        local silver = imgui.GetColorU32({ 0.75, 0.78, 0.85, 0.85 });
        local fgSilver = imgui.GetForegroundDrawList();
        fgSilver:AddLine({ rbX1 + 3, rbY1 + 1 }, { rbX2 - 3, rbY1 + 1 }, silver, 1.0);
        fgSilver:AddLine({ rbX1 + 3, rbY2 - 1 }, { rbX2 - 3, rbY2 - 1 }, silver, 1.0);
        imgui.GetWindowDrawList():AddRect(
            { rbX1, rbY1 }, { rbX2, rbY2 },
            imgui.GetColorU32({ 0.3, 0.3, 0.5, 0.8 }), 4, 0, 1.0
        );

        -- HP bar matches the party HP bar's screen position EXACTLY by reading
        -- the bar geometry captured during DrawMember for the player slot (see
        -- data.frameCache.playerHpBar{Left,Right}). Falls back to the recomputed
        -- formula on the first frame before the player row has drawn yet, or
        -- if party 1 isn't visible.
        local barLeft  = data.frameCache.playerHpBarLeft;
        local barRight = data.frameCache.playerHpBarRight;
        local tbarWidth;
        local barX;
        if barLeft and barRight and barRight > barLeft then
            -- Captured geometry available - align pixel-perfect.
            tbarWidth = barRight - barLeft;
            barX      = barLeft;
        else
            -- Fallback: recompute using the same formula DrawMember uses.
            local partyLayoutTpl = data.getLayoutTemplate(1);
            local partyBarScales = data.getBarScales(1);
            local partyBaseHpW   = (partyLayoutTpl.hpBarWidth or settings.hpBarWidth or 150)
                                   * PARTY_BAR_BASE_WIDTH_MULT;
            tbarWidth = partyBaseHpW * scale.x
                * ((partyBarScales and partyBarScales.hpBarScaleX) or 1);
            if cache.layout == 1 then
                tbarWidth = tbarWidth * HX_BAR_WIDTH_MULT;
            end
            local rightInsetBar = 10;
            barX = wX + winW - rightInsetBar - tbarWidth;
        end

        local barY = barTopY;
        imgui.SetCursorScreenPos({ barX, barY });
        progressbar.ProgressBar(
            {{targetHPP, hpGradient}}, {tbarWidth, barHeight},
            {decorate = cache.showBookends, backgroundGradientOverride = bgGradOverride}
        );

        local textY = barY + math.floor((barHeight - lineH) / 2);

        -- HP% to the LEFT of the bar. White by default; if the per-party
        -- "Target HP Color" config is on, color the text by HP threshold
        -- (matches partylist member name-color via GetCustomHpColors at
        -- 100% / 50% / 33% / 25% / 0%).
        local pctColor = {1, 1, 1, 1};
        if cache.targetHpColor then
            local hpNameColor, _ = GetCustomHpColors(targetHPP, cache.colors);
            if hpNameColor then pctColor = hpNameColor; end
        end
        local pctStr  = string.format('%d', math.floor(targetHPP * 100));
        local pctW, _ = imgui.CalcTextSize(pctStr);
        outlined(barX - pctW - 6, textY, pctColor, pctStr);

        -- Name row ABOVE the bar (pushed in from the edge). Distance on the right.
        local nameRowStr = tostring(targetName);
        local namePad    = padding + 6;
        outlined(wX + namePad, nameRowY, nameColor, nameRowStr);
        if distance ~= nil and distance > 0 and distance <= 50 then
            local distanceText = string.format('%.1f', distance);
            local distColor    = {1, 1, 1, 1};
            if cache.distanceHighlight and cache.distanceHighlight > 0
               and distance <= cache.distanceHighlight then
                distColor = {0.20, 1.00, 1.00, 1.0};   -- in-range cyan
            end
            local dW, _      = imgui.CalcTextSize(distanceText);
            local rightInset = 10;
            outlined(wX + winW - dW - rightInset, nameRowY, distColor, distanceText);
        end

        -- (barWidth kept as the full inner width for the selector below.)
        local barWidth = tbarWidth;

        -- Status icon for this target (LFP / Bazaar / Mentor / Away / Sync /
        -- New) is drawn next to the "Target" title below, matching native
        -- FFXI's positioning. The icon priority and texture lookup are done
        -- once above (statusIconKey resolved at scan time,
        -- ensureTargetStatusIcons() pre-loaded). Search this file for
        -- "statusIconKey" further down to see where the title draw consumes it.

        -- Foreground outline helper (for elements that must sit ON TOP of the
        -- selector, which is itself on the foreground list).
        local function outlinedFg(dl, x, y, col, text)
            local b = imgui.GetColorU32({0,0,0,1});
            dl:AddText({x-1, y}, b, text);
            dl:AddText({x+1, y}, b, text);
            dl:AddText({x, y-1}, b, text);
            dl:AddText({x, y+1}, b, text);
            dl:AddText({x, y}, imgui.GetColorU32(col), text);
        end

        -- Lock-on selector + edge labels, all on the foreground list and in the
        -- correct order (selector first, labels on top). The selector hugs the
        -- bar (slightly inset from the full window width) and the side arrows are
        -- stretched to the full selector height, pointing inward.
        local fg = imgui.GetForegroundDrawList();
        -- Selector brackets the visible box. Inset only in WIDTH so the orange
        -- hugs the sides; keep FULL box height (it covers the silver edges, which
        -- is intended).
        local selInset = 3;
        local selX1 = rbX1 + selInset;
        local selX2 = rbX2 - selInset;
        local selY1 = rbY1;
        local selY2 = rbY2;

        if isLocked then
            local selCol = imgui.GetColorU32({ 1.0, 0.55, 0.10, 1.0 });
            fg:AddRect({ selX1, selY1 }, { selX2, selY2 }, selCol, 4, 0, 2.0);
            local aW   = math.floor(lineH * 0.55);
            local midY = math.floor((selY1 + selY2) / 2);

            -- OUTSIDE arrows flank the BOX, pointing OUTWARD (full selector height).
            -- Left outside arrow ◄ (apex left).
            fg:AddTriangleFilled(
                { selX1, selY1 }, { selX1, selY2 },
                { selX1 - aW - 2, midY }, selCol);
            -- Right outside arrow ► (apex right).
            fg:AddTriangleFilled(
                { selX2, selY1 }, { selX2, selY2 },
                { selX2 + aW + 2, midY }, selCol);
        end

        -- "Target" centered on the TOP edge of the box (on top of the selector).
        do
            local titleStr   = 'Target';
            local titleW, tH = imgui.CalcTextSize(titleStr);
            local titleX     = wX + math.floor((winW - titleW) / 2);
            local titleY     = rbY1 - math.floor(tH / 2);
            outlinedFg(fg, titleX, titleY, {0.75, 0.83, 0.90, 1.0}, titleStr);
        end

        -- Status icon (LFP / Bazaar / Mentor / Away / Sync / New) sits at the
        -- top-right of the window border, centered ON the top border line (so
        -- half overhangs above, half sits inside the box - same vertical
        -- treatment as the "Target" title). Anchored to the WINDOW right edge,
        -- not to the title, with a small inset so it doesn't clip against the
        -- frame. Drawn on the foreground draw list (fg), which isn't clipped
        -- by the imgui window, so overhanging the top border is safe.
        if statusIconKey ~= nil then
            local _, titleH    = imgui.CalcTextSize('Target');
            local iconSize     = titleH + 4;       -- a touch bigger than title text
            local rightInset   = 8;                -- gap from the window's right edge
            local iconX        = wX + winW - iconSize - rightInset;
            local iconY        = rbY1 - math.floor(iconSize / 2);  -- center on top border
            local tex          = targetStatusIcons and targetStatusIcons[statusIconKey] or nil;
            if tex ~= nil then
                fg:AddImage(
                    tonumber(ffi.cast('uint32_t', tex.image)),
                    { iconX, iconY },
                    { iconX + iconSize, iconY + iconSize },
                    { 0, 0 }, { 1, 1 },
                    imgui.GetColorU32({ 1, 1, 1, 1 })
                );
            else
                -- Texture missing - fall back to the colored 2-3 letter label
                -- so the indicator still works before icon assets ship.
                local lblW, lblH = imgui.CalcTextSize(statusIconLabel);
                local lblX = wX + winW - lblW - rightInset;
                local lblY = rbY1 - math.floor(lblH / 2);
                outlinedFg(fg, lblX, lblY, statusIconColor, statusIconLabel);
            end
        end

        -- "Locked" centered on the BOTTOM edge of the box, flanked by a pair of
        -- inward-pointing arrows ►Locked◄ (the second arrow set, on the text).
        if isLocked then
            local lockText      = 'Locked';
            local lockW, lockTH = imgui.CalcTextSize(lockText);
            local lockX         = wX + math.floor((winW - lockW) / 2);
            local lockY         = rbY2 - math.floor(lockTH / 2);
            local selCol        = imgui.GetColorU32({ 1.0, 0.55, 0.10, 1.0 });
            local laH           = math.floor(lockTH * 0.45);
            local laW           = math.floor(laH * 0.9);
            local lacY          = lockY + math.floor(lockTH / 2);
            -- Left arrow ► (apex right, toward the text), just left of "Locked".
            fg:AddTriangleFilled(
                { lockX - laW - 4, lacY - laH }, { lockX - laW - 4, lacY + laH },
                { lockX - 4, lacY }, selCol);
            -- Right arrow ◄ (apex left, toward the text), just right of "Locked".
            fg:AddTriangleFilled(
                { lockX + lockW + laW + 4, lacY - laH }, { lockX + lockW + laW + 4, lacY + laH },
                { lockX + lockW + 4, lacY }, selCol);
            outlinedFg(fg, lockX, lockY, {1.0, 0.55, 0.10, 1.0}, lockText);
        end

        wW, wH = imgui.GetWindowSize();
        -- Use a DETERMINISTIC height for the next-frame anchor so the window
        -- never shifts when the lock selector / edge labels toggle on. The
        -- content rect (and thus measured wH) is already lock-independent, but
        -- pin it explicitly from the known layout to be safe.
        wH = (contentBot - contentTop) + (winPadY * 2);
    end

    imgui.End();
    imgui.PopStyleVar(4);    -- FramePadding, ItemSpacing, WindowPadding, WindowRounding
    imgui.PopStyleColor(2);  -- WindowBg, Border
    data.targetWindowPrevH = wH;

    -- Publish target rect for the anchor chain. The "visible" rect is what
    -- matters for stacking (oversized invisible content would create huge
    -- gaps), so use realBox bounds when available.
    do
        local rectX = wX;
        local rectY = realBoxY1 or wY;
        local rectW = wW;
        local rectH = (realBoxY1 and realBoxY2) and (realBoxY2 - realBoxY1) or wH;
        if rectW and rectH and rectW > 0 and rectH > 0 then
            data.captureWindowRect('target', rectX, rectY, rectW, rectH);
        else
            data.invalidateWindowRect('target');
        end
    end

    -- Update / hide the target's textured bg primitive to match party 1.
    if not plainBg then
        -- Size the textured bg to the REAL box, not the oversized invisible
        -- content (which would waste vertical space). Fall back to wY/wH if the
        -- real-box rect wasn't captured (window collapsed).
        local bgY = realBoxY1 or wY;
        local bgH = (realBoxY1 and realBoxY2) and (realBoxY2 - realBoxY1) or wH;
        windowBg.update(data.targetWindowPrim.background, wX, bgY, wW, bgH, {
            theme         = cache.backgroundName,
            padding       = 0,    -- match Plain size; theme only changes fill
            paddingY      = 0,
            bgScale       = cache.bgScale,
            borderScale   = cache.borderScale,
            bgOpacity     = cache.backgroundOpacity,
            bgColor       = cache.colors.bgColor,
            borderSize    = settings.borderSize,
            bgOffset      = settings.bgOffset,
            borderOpacity = cache.borderOpacity,
            borderColor   = cache.colors.borderColor,
        });
    else
        windowBg.hide(data.targetWindowPrim.background);
    end
end

-- ============================================
-- Cast Cost anchor export
-- ============================================
-- Returns the screen position + width that an externally-managed Cast Cost
-- bar should snap to when gConfig.partyListAnchorCastCost is enabled.
-- castcost.lua reads this each frame; if not anchored, castcost.lua falls
-- back to its own configured position.
--
-- Returns: { x = X, y = Y, width = W, valid = bool }
-- The cast cost bar's BOTTOM should sit at `y` (cast cost is unaware of
-- its own height ahead of time, so it positions its window with bottom-Y
-- at this anchor and grows upward via SetNextWindowSize).
function display.GetCastCostAnchor(settings)
    if not gConfig.partyListAnchorCastCost then
        return { valid = false };
    end
    if data.partyList1Pos.x == 0 and data.partyList1Pos.y == 0 then
        return { valid = false };
    end

    local cache = data.partyConfigCache[1];

    local titleOverhang = 0;
    if cache.showTitle and data.partyTitlesTexture ~= nil then
        local titleScale = (cache.layout == 2) and 0.5 or 0.8;
        local rawTitleH = (data.partyTitlesTexture.height / 4) * titleScale;
        titleOverhang = math.floor(rawTitleH / 2);
    end

    local gap         = 4;
    local castCostGap = 14;  -- clears the "Target" label overhanging the target box top
    local bottomY;

    -- Pair this with data.invalidateWindowRect not zeroing targetWindowPrevH.
    -- We need to know whether the target is ACTUALLY drawing this frame, not
    -- whether it's enabled in config. Config-on + no-current-target means the
    -- target rect is invalid this frame and castcost should stack flush to the
    -- party panel, not leave a phantom gap where the (invisible) target would
    -- have lived.
    local targetVisibleThisFrame = (
        gConfig.showPartyListTarget
        and data.windowRects.target
        and data.windowRects.target.visible  -- .visible = drawing right now,
        -- not .valid (which stays true between targets so other consumers can
        -- still read the bar's last-known layout position). See
        -- data.invalidateWindowRect comments for the soft/hard split.
    );

    if targetVisibleThisFrame then
        -- Target window IS shown: castcost anchors just above the VISIBLE target
        -- box. targetWindowPrevH is the FULL target content height, which
        -- includes the "Target"/"Locked" edge-label overhang on top AND bottom
        -- (edgeOverhang each) plus winPadY padding. Anchoring above the full
        -- height overshoots and leaves a large gap, so trim that overshoot.
        local _, lineH = imgui.CalcTextSize('A');
        local edgeOverhang = math.floor(lineH / 2) + 1;
        local winPadY = 6;
        local targetTrim = edgeOverhang + (winPadY * 2);
        local targetH = math.max(0, (data.targetWindowPrevH or 0) - targetTrim);
        local targetGap = gap;
        bottomY = data.partyList1Pos.y - titleOverhang - targetGap - targetH - castCostGap;
    else
        -- Target window is DISABLED: castcost anchors directly to the PARTY LIST
        -- (flush above the party panel, at the title overhang). No target height
        -- or target gap in the stack.
        bottomY = data.partyList1Pos.y - titleOverhang - castCostGap;
    end

    local winW = data.fullMenuWidth[1] or 280;

    return {
        valid  = true,
        x      = data.partyList1Pos.x,
        y      = bottomY,             -- cast cost window's bottom edge anchors here
        width  = winW,
    };
end

-- ============================================
-- DrawWindow - Main entry point for rendering
-- ============================================
-- ============================================================
-- Sub-target cursor auto-walker
-- ============================================================
-- When the player clicks a partymember while sub-target mode is active
-- (e.g., /ma "Cure" <stpc>), Ashita's /target command can't be used - it
-- would cancel the sub-target context and rebind main target. Instead we
-- simulate arrow-key presses through Ashita's keyboard interface to walk
-- the game's own sub-target cursor to the clicked row. The player still
-- presses Enter to confirm; this only POSITIONS the cursor.
--
-- Wrap-aware shortest path: with N active partymembers, going from row A
-- to row B costs `(B-A+N)%N` down-taps or `(A-B+N)%N` up-taps, whichever
-- is fewer.
--
-- Tap pacing: each tap is press for HOLD frames, release for GAP frames.
-- Press/release pair must span multiple frames so FFXI's input poll
-- registers it as a discrete tap rather than a held key. Queue is driven
-- one phase-step per frame from the top of DrawWindow.

local DIK_UPARROW   = 0xC8;
local DIK_DOWNARROW = 0xD0;
local TAP_HOLD_FRAMES    = 2;
local TAP_RELEASE_FRAMES = 2;

local stKeyQueue = {};
local stPhase    = 'idle';   -- 'idle' | 'pressed' | 'released'
local stCurKey   = nil;
local stFrames   = 0;

-- Send a DirectInput key press/release. pcall'd because the input API
-- shape can differ across Ashita builds; if it's wrong we abort silently
-- rather than crashing the partylist render.
local function st_set_key(scancode, pressed)
    pcall(function()
        local kb = AshitaCore:GetInputManager():GetKeyboard();
        if kb ~= nil then
            kb:SetKey(scancode, pressed);
        end
    end);
end

local function st_abort_queue()
    if stCurKey ~= nil then
        st_set_key(stCurKey, false);  -- release whatever's still held
    end
    stKeyQueue = {};
    stPhase    = 'idle';
    stCurKey   = nil;
    stFrames   = 0;
end

-- Drive the queue one phase per frame. Called from the top of DrawWindow.
local function st_process_queue()
    -- Sub-target ended mid-walk (player canceled, cursor moved off-party,
    -- spell resolved, etc.) - abort and release any held key.
    if not data.frameCache.subTargetActive then
        st_abort_queue();
        return;
    end

    if stPhase == 'idle' then
        local nextKey = table.remove(stKeyQueue, 1);
        if nextKey == nil then return; end
        st_set_key(nextKey, true);
        stCurKey = nextKey;
        stPhase  = 'pressed';
        stFrames = TAP_HOLD_FRAMES;
    elseif stPhase == 'pressed' then
        stFrames = stFrames - 1;
        if stFrames <= 0 then
            st_set_key(stCurKey, false);
            stPhase  = 'released';
            stFrames = TAP_RELEASE_FRAMES;
        end
    elseif stPhase == 'released' then
        stFrames = stFrames - 1;
        if stFrames <= 0 then
            stCurKey = nil;
            stPhase  = 'idle';
        end
    end
end

-- Click handler entry: queue the right number of UP or DOWN taps to walk
-- the sub-target cursor from its current row to the clicked memIdx.
-- memIdx is the absolute partylist index (0..17). Sub-target party cursor
-- only walks the user's own party (memIdx 0..5), so other indices are
-- ignored. /stnpc, /stmob etc. don't have a useful stPartyIndex so we
-- skip those modes silently.
local function st_walk_to(memIdx)
    local curRow = data.frameCache.stPartyIndex;
    if curRow == nil then return; end
    if memIdx < 0 or memIdx > 5 then return; end
    local tgtRow = memIdx;

    local pSize = data.frameCache.activeMemberCount and
                  data.frameCache.activeMemberCount[1] or 0;
    if pSize <= 1 or curRow == tgtRow then return; end

    local fwd = (tgtRow - curRow + pSize) % pSize;
    local bwd = (curRow - tgtRow + pSize) % pSize;

    -- Replace any in-flight walk - the latest click wins.
    st_abort_queue();

    local key, count;
    if fwd <= bwd then
        key, count = DIK_DOWNARROW, fwd;
    else
        key, count = DIK_UPARROW, bwd;
    end
    for _ = 1, count do
        table.insert(stKeyQueue, key);
    end
end

function display.DrawWindow(settings)
    -- Tick the sub-target cursor auto-walker one phase per frame. Has to
    -- run BEFORE the early-out for zoning/no-party so a queued walk can
    -- complete cleanly (or be aborted) regardless of party state.
    st_process_queue();

    -- Reset the per-frame click-to-cure zone list before any member renders.
    BeginCureFrame();

    -- Rebuild config cache if settings version changed
    -- This is more efficient than rebuilding every frame but still catches config UI changes
    data.checkAndUpdateConfigCache();

    -- Cache game state
    data.frameCache.party = GetPartySafe();
    data.frameCache.player = GetPlayerSafe();
    data.frameCache.entity = GetEntitySafe();
    data.frameCache.playerTarget = GetTargetSafe();

    local party = data.frameCache.party;
    local player = data.frameCache.player;

    if (party == nil or player == nil or player.isZoning or player:GetMainJob() == 0) then
        data.UpdateTextVisibility(false);
        return;
    end

    -- Cache target info
    if data.frameCache.playerTarget ~= nil then
        data.frameCache.t1, data.frameCache.t2 = GetTargets();
        data.frameCache.stPartyIndex = GetStPartyIndex();
        data.frameCache.subTargetActive = GetSubTargetActive();
    else
        data.frameCache.t1 = nil;
        data.frameCache.t2 = nil;
        data.frameCache.stPartyIndex = nil;
        data.frameCache.subTargetActive = false;
    end

    -- Pre-calculate active member counts
    for partyIndex = 1, 3 do
        local firstIdx = (partyIndex - 1) * data.partyMaxSize;
        local count = 0;
        data.frameCache.activeMemberList[partyIndex] = {};

        if showConfig[1] and gConfig.partyListPreview then
            count = data.partyMaxSize;
            for i = 0, data.partyMaxSize - 1 do
                data.frameCache.activeMemberList[partyIndex][i] = true;
            end
        else
            for i = 0, data.partyMaxSize - 1 do
                local memIdx = firstIdx + i;
                if party:GetMemberIsActive(memIdx) ~= 0 then
                    count = count + 1;
                    data.frameCache.activeMemberList[partyIndex][i] = true;
                else
                    break;
                end
            end
        end
        data.frameCache.activeMemberCount[partyIndex] = count;
    end

    -- Handle debounced settings save
    if data.pendingSettingsSave then
        local now = os.clock();
        if now - data.lastSettingsSaveTime >= data.SETTINGS_SAVE_DEBOUNCE then
            ashita_settings.save();
            data.pendingSettingsSave = false;
        end
    end

    data.partyTargeted = false;
    data.partySubTargeted = false;

    -- Main party window
    display.DrawPartyWindow(settings, party, 1);

    -- Anchored Target Bar (above Party 1) — only renders when enabled.
    -- Must run after Party 1 so partyList1Pos is current; runs every frame
    -- regardless of alliance state because the target is single-window only.
    display.DrawCurrentTarget(settings);

    -- Alliance party windows
    if (gConfig.partyListAlliance) then
        display.DrawPartyWindow(settings, party, 2);
        display.DrawPartyWindow(settings, party, 3);
    else
        data.UpdateTextVisibility(false, 2);
        data.UpdateTextVisibility(false, 3);
    end

    -- Resolve click-to-cure once, after every party/status window is submitted.
    -- Runs in the top-level imgui frame context (same place click-to-target works).
    ResolveCureClicks();
end

-- ============================================================
-- DEBUG BUILD: error traps. Any error inside a render function
-- prints ONE chat line with the exact file:line instead of
-- silently killing the rest of the frame (which is what hides
-- the config menu / job icons / later addons). Remove once the
-- root cause is identified.
-- ============================================================
local _dbgSeen = {};
local function _dbgwrap(name, fn)
    if type(fn) ~= 'function' then return fn; end
    return function(...)
        local ok, a, b, c, d = pcall(fn, ...);
        if ok then return a, b, c, d; end
        local msg = '[XIUI DEBUG] partylist.' .. name .. ' ERROR: ' .. tostring(a);
        if not _dbgSeen[msg] then
            _dbgSeen[msg] = true;
            print(msg);
        end
    end
end
display.DrawMember             = _dbgwrap('DrawMember', display.DrawMember);
display.DrawMemberSuperCompact = _dbgwrap('DrawMemberSuperCompact', display.DrawMemberSuperCompact);
display.DrawPartyWindow        = _dbgwrap('DrawPartyWindow', display.DrawPartyWindow);
display.DrawCurrentTarget      = _dbgwrap('DrawCurrentTarget', display.DrawCurrentTarget);
display.GetCastCostAnchor      = _dbgwrap('GetCastCostAnchor', display.GetCastCostAnchor);
display.DrawWindow             = _dbgwrap('DrawWindow', display.DrawWindow);

return display;