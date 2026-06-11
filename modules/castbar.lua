require('common');
require('handlers.helpers');
local imgui = require('imgui');
local fonts = require('fonts');
local progressbar = require('libs.progressbar');
local gdi = require('submodules.gdifonts.include');
local encoding = require('submodules.gdifonts.encoding');

local spellText;
local percentText;
local allFonts; -- Table for batch visibility operations

-- Cache last set colors to avoid expensive SetColor() calls every frame
local lastSpellTextColor;
local lastPercentTextColor;

-- Draw text with a 1-pixel black outline so it stays readable on top of the
-- progress bar fill. Draws on the FOREGROUND draw list via AddText so the text
-- composites ON TOP of the progress bar (imgui.TextColored lands on the window
-- draw list, which on this build renders UNDER the bar fill — the reason the
-- castbar text wasn't showing). '%' no longer needs escaping since AddText is
-- not a printf format.
local function drawOutlinedText(x, y, text, fillColor)
	if text == nil or text == '' then return; end
	local s = tostring(text);
	local dl = imgui.GetForegroundDrawList();
	local blackU = imgui.GetColorU32({0, 0, 0, 1});
	local fillU  = imgui.GetColorU32(fillColor or {1, 1, 1, 1});
	dl:AddText({x - 1, y - 1}, blackU, s);
	dl:AddText({x + 1, y - 1}, blackU, s);
	dl:AddText({x - 1, y + 1}, blackU, s);
	dl:AddText({x + 1, y + 1}, blackU, s);
	dl:AddText({x, y}, fillU, s);
end

-- Convert a u32 ARGB color (as stored in gConfig.colorCustomization) into the
-- {r, g, b, a} 0-1 table that drawOutlinedText expects.
local function u32ToRGBA(c)
	if c == nil then return {1, 1, 1, 1}; end
	local a = bit.band(bit.rshift(c, 24), 0xFF) / 255;
	local r = bit.band(bit.rshift(c, 16), 0xFF) / 255;
	local g = bit.band(bit.rshift(c,  8), 0xFF) / 255;
	local b = bit.band(c, 0xFF) / 255;
	if a == 0 then a = 1; end  -- treat missing alpha as opaque
	return {r, g, b, a};
end

local castbar = {
	previousPercent = 0,
	currentSpellId = nil,
	currentItemId = nil,
	-- Cached spell data (set once at cast start, avoids per-frame resource lookups)
	currentSpellType = nil,
	currentSpellName = nil,
};

-- CureSpells moved to helpers.lua as CURE_SPELLS (shared global)

castbar.GetSpellName = function(spellId)
	return AshitaCore:GetResourceManager():GetSpellById(spellId).Name[1];
end

castbar.GetSpellType = function(spellId)
	return AshitaCore:GetResourceManager():GetSpellById(spellId).Skill;
end

castbar.GetItemName = function(itemId)
	return AshitaCore:GetResourceManager():GetItemById(itemId).Name[1];
end

castbar.GetLabelText = function()
	if (castbar.currentSpellId) then
		return encoding:ShiftJIS_To_UTF8(castbar.GetSpellName(castbar.currentSpellId), true);
	elseif (castbar.currentItemId) then
		return encoding:ShiftJIS_To_UTF8(castbar.GetItemName(castbar.currentItemId), true);
	else
		return '';
	end
end

castbar.DrawWindow = function(settings)
	local castBar = GetCastBarSafe();
	if castBar == nil then
		return;
	end
	local percent = castBar:GetPercent();

	local totalCast = 1

	-- Use shared fast cast calculation
	local player = GetPlayerSafe();
	if player ~= nil then
		local fastCast = CalculateFastCast(
			player:GetMainJob(),
			player:GetSubJob(),
			castbar.currentSpellType,
			castbar.currentSpellName,
			player:GetMainJobLevel(),
			player:GetSubJobLevel()
		);
		if fastCast > 0 then
			-- The 0.75 factor corrects for how GetCastBarSafe():GetPercent() reports progress
			totalCast = (1 - fastCast) * 0.75;
		end
	end

	percent = percent / totalCast

	if ((percent < 1 and percent ~= castbar.previousPercent) or showConfig[1]) then
		imgui.SetNextWindowSize({settings.barWidth, -1});

		local windowFlags = GetBaseWindowFlags(gConfig.lockPositions);
		if (imgui.Begin('CastBar', true, windowFlags)) then
			local startX, startY = imgui.GetCursorScreenPos();

			-- Calculate bookend width and text padding (same as exp bar)
			local bookendWidth = gConfig.showCastBarBookends and (settings.barHeight / 2) or 0;
			local textPadding = 8;

			-- Create progress bar
			--[[
			imgui.PushStyleColor(ImGuiCol_PlotHistogram, {0.2, 0.75, 1, 1});

			imgui.ProgressBar(showConfig[1] and 0.5 or percent, {-1, settings.barHeight}, '');

			imgui.PopStyleColor(1);
			]]--

			local castGradient = GetCustomGradient(gConfig.colorCustomization.castBar, 'barGradient') or {'#3798ce', '#78c5ee'};
			progressbar.ProgressBar({{showConfig[1] and 0.5 or percent, castGradient}}, {-1, settings.barHeight}, {decorate = gConfig.showCastBarBookends});

			-- Hide the gdifont primitives — text is drawn via imgui below so it
			-- lands ON TOP of the progress bar fill (gdifont renders in a separate
			-- d3d pass BEHIND imgui, which is why text was being covered by the bar).
			spellText:set_visible(false);
			percentText:set_visible(false);

			-- Text geometry
			local spellFontH   = settings.spell_font_settings.font_height;
			local percentFontH = settings.percent_font_settings.font_height;
			local leftTextX    = startX + bookendWidth + textPadding;
			local spellY       = startY + (settings.barHeight - spellFontH) / 2 + settings.spellOffsetY;
			local progressBarWidth = settings.barWidth - imgui.GetStyle().FramePadding.x * 2;
			local rightTextX   = startX + progressBarWidth - bookendWidth - textPadding;
			local percentY     = startY + (settings.barHeight - percentFontH) / 2 + settings.percentOffsetY;

			-- Spell/Item name — left-aligned, overlaid on the bar.
			local spellTextStr = showConfig[1] and 'Configuration Mode' or castbar.GetLabelText();
			drawOutlinedText(leftTextX, spellY, spellTextStr, u32ToRGBA(gConfig.colorCustomization.castBar.spellTextColor));

			-- Percent — right-aligned, overlaid on the bar.
			local percentStr = showConfig[1] and '50%' or math.floor(percent * 100) .. '%';
			local pw = imgui.CalcTextSize(percentStr);
			drawOutlinedText(rightTextX - (pw or 0), percentY, percentStr, u32ToRGBA(gConfig.colorCustomization.castBar.percentTextColor));
		end

		imgui.End();
	else
		SetFontsVisible(allFonts,false);
	end

	castbar.previousPercent = percent;
end

castbar.UpdateVisuals = function(settings)
	-- Use FontManager for cleaner font recreation
	spellText = FontManager.recreate(spellText, settings.spell_font_settings);
	percentText = FontManager.recreate(percentText, settings.percent_font_settings);
	allFonts = {spellText, percentText};

	-- Reset cached colors when fonts are recreated
	lastSpellTextColor = nil;
	lastPercentTextColor = nil;
end

castbar.SetHidden = function(hidden)
	if (hidden == true) then
		SetFontsVisible(allFonts, false);
	end
end

castbar.Initialize = function(settings)
	-- Use FontManager for cleaner font creation
	spellText = FontManager.create(settings.spell_font_settings);
	percentText = FontManager.create(settings.percent_font_settings);
	allFonts = {spellText, percentText};
end

castbar.HandleActionPacket = function(actionPacket)
	local party = GetPartySafe();
	if party == nil then
		return;
	end
	local localPlayerId = party:GetMemberServerId(0);

	-- We only care about:
	-- - Actions originating from the player
	-- - Actions that are spell or item casts
	-- - The aforementioned action is starting
	if (actionPacket.UserId == localPlayerId and (actionPacket.Type == 8 or actionPacket.Type == 9) and actionPacket.Param == 0x6163) then
		castbar.currentSpellId = nil;
		castbar.currentItemId = nil;
		castbar.currentSpellType = nil;
		castbar.currentSpellName = nil;

		if (actionPacket.Type == 8) then
			castbar.currentSpellId = actionPacket.Targets[1].Actions[1].Param;
			-- Cache spell type and name at cast start (avoids per-frame resource lookups)
			castbar.currentSpellType = castbar.GetSpellType(castbar.currentSpellId);
			castbar.currentSpellName = castbar.GetSpellName(castbar.currentSpellId);
		else
			castbar.currentItemId = actionPacket.Targets[1].Actions[1].Param;
		end
	end
end

castbar.Cleanup = function()
	-- Use FontManager for cleaner font destruction
	spellText = FontManager.destroy(spellText);
	percentText = FontManager.destroy(percentText);
	allFonts = nil;
end

return castbar;