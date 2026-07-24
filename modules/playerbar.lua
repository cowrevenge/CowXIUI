require('common');
require('handlers.helpers');
local imgui = require('imgui');
local gdi = require('submodules.gdifonts.include');
local progressbar = require('libs.progressbar');
local buffTable = require('libs.bufftable');
local castcostShared = require('modules.castcost.shared');
local imtext = require('libs.imtext');

-- Local imgui-based outlined text helper. Bars use imgui; gdifont primitives
-- render BEFORE imgui in Ashita's pipeline and end up UNDER the bars - which
-- prevents positioning text inside the bars. Drawing via the foreground draw
-- list puts the text ON TOP of everything, so text-offset settings can move
-- the labels inside the bar area without being covered.
--
-- argbIntToRgba converts the integer colors stored in gConfig (signed 32-bit
-- ARGB, e.g. -16777216 == 0xFF000000) into {r,g,b,a} float tables that
-- imgui.GetColorU32 expects.
local function argbIntToRgba(c)
    if c == nil then return {1, 1, 1, 1}; end
    local a = bit.band(bit.rshift(c, 24), 0xFF) / 255;
    local r = bit.band(bit.rshift(c, 16), 0xFF) / 255;
    local g = bit.band(bit.rshift(c, 8),  0xFF) / 255;
    local b = bit.band(c, 0xFF) / 255;
    -- Treat 0 alpha as opaque (Ashita's color pickers sometimes save the
    -- alpha byte stripped). Avoids invisible text after settings reset.
    if a == 0 then a = 1; end
    return {r, g, b, a};
end

-- Font height for the player bar's HP/MP/TP text.
--
-- Comes from playerBarFontSize via core/settings/updater.lua, which writes it
-- into playerBarSettings.font_settings.font_height. Set once per frame in
-- DrawWindow so the helpers below don't each have to reach for settings.
local playerBarFontHeight = nil;

-- Text was previously drawn with imgui's AddText and no font argument, which
-- pins it to imgui's default size -- so the Text Size slider and the global
-- font family/outline settings had no effect at all.
--
-- imtext.Draw takes the size and applies the configured family, weight and
-- outline width, matching how the party list and hotbar render their text.
local function drawOutlinedText(x, y, text, fillColor)
    if text == nil or text == '' then return; end
    text = tostring(text);
    local dl = imgui.GetForegroundDrawList();
    if dl == nil then return; end

    -- imtext wants an ARGB int; this file works in RGBA float tables.
    local c = fillColor or {1, 1, 1, 1};
    local argb = bit.bor(
        bit.lshift(math.floor((c[4] or 1) * 255), 24),
        bit.lshift(math.floor(c[1] * 255), 16),
        bit.lshift(math.floor(c[2] * 255), 8),
        math.floor(c[3] * 255));

    imtext.Draw(dl, text, x, y, argb, playerBarFontHeight);
end

-- Given an alignment anchor X and the text width, return the imgui-friendly
-- top-left X (drawOutlinedText draws from top-left, not from an alignment
-- anchor like gdifont).
local function alignToLeftX(anchorX, textW, alignment)
    if alignment == 'center' then return anchorX - textW / 2; end
    if alignment == 'right'  then return anchorX - textW;     end
    return anchorX;  -- left
end

local hpText;
local mpText;
local tpText;
local allFonts; -- Table for batch visibility operations
local resetPosNextFrame = false;

-- Cache last set colors to avoid expensive SetColor() calls every frame
local lastHpTextColor;
local lastMpTextColor;
local lastTpTextColor;

-- Reference text height for baseline alignment (prevents text jumping)
local referenceTextHeight = 0;

-- Cached interpolation colors (updated when config changes)
local cachedInterpColors = nil;
local lastInterpColorConfig = nil;

-- Cached window flags (constant, computed once)
local baseWindowFlags = nil;

local playerbar = {
	interpolation = {},
	-- Resting tick tracker. Per LSB, the Healing effect ticks every 10s but the
	-- cycle is synced to the first observed MP gain, then runs every 10s.
	-- startTime is the os.clock() when resting began;
	-- wasResting gates the reset so we only stamp startTime on the rising edge.
	restingTicker = {
		startTime = 0,
		wasResting = false,
	},
};

-- Get cached interpolation colors, only recompute when config changes
local function getCachedInterpColors()
	local currentConfig = gConfig.colorCustomization and gConfig.colorCustomization.shared;
	if cachedInterpColors == nil or lastInterpColorConfig ~= currentConfig then
		cachedInterpColors = GetHpInterpolationColors();
		lastInterpColorConfig = currentConfig;
	end
	return cachedInterpColors;
end

-- Note: getBaseWindowFlags moved to handlers/helpers.lua as GetBaseWindowFlags()
-- This local caching is no longer needed but kept for backwards compatibility
local function getBaseWindowFlags()
	return GetBaseWindowFlags(false);
end

local _XIUI_DEV_DEBUG_INTERPOLATION = false;
local _XIUI_DEV_DEBUG_INTERPOLATION_DELAY, _XIUI_DEV_DEBUG_INTERPOLATION_NEXT_TIME;

if _XIUI_DEV_DEBUG_INTERPOLATION then
	_XIUI_DEV_DEBUG_INTERPOLATION_DELAY = 2;
	_XIUI_DEV_DEBUG_INTERPOLATION_NEXT_TIME = os.time() + _XIUI_DEV_DEBUG_INTERPOLATION_DELAY;
end

playerbar.DrawWindow = function(settings)
    -- Font height for this frame's HP/MP/TP text. Sourced from
    -- playerBarFontSize (core/settings/updater.lua writes it into
    -- font_settings.font_height), so the Text Size slider and the global
    -- font family / outline settings now actually apply.
    playerBarFontHeight = settings and settings.font_settings
        and settings.font_settings.font_height or nil;

    -- imtext keeps its font family / weight / outline as MODULE-level state,
    -- and the hotbar sets it from its own settings. Without re-applying ours
    -- here the player bar would inherit whatever the hotbar last configured.
    -- Cheap: SetConfigFromSettings early-outs when nothing changed.
    if settings and settings.font_settings then
        imtext.SetConfigFromSettings(settings.font_settings);
    end

    -- Obtain game state (single call each, cached for this frame)
    local party = GetPartySafe();
    local player = GetPlayerSafe();
	local playerEnt = GetPlayerEntity();

	if (party == nil or player == nil or playerEnt == nil) then
		SetFontsVisible(allFonts, false);
		return;
	end

	local currJob = player:GetMainJob();

    if (player.isZoning or currJob == 0) then
		SetFontsVisible(allFonts, false);
        return;
	end

	local SelfHP = party:GetMemberHP(0);
	local SelfHPMax = player:GetHPMax();
	-- Calculate percentage from actual values to avoid stale party API data (issue #92)
	local SelfHPPercent = (SelfHPMax > 0) and math.clamp((SelfHP / SelfHPMax) * 100, 0, 100) or 0;
	local SelfMP = party:GetMemberMP(0);
	local SelfMPMax = player:GetMPMax();
	local SelfMPPercent = (SelfMPMax > 0) and math.clamp((SelfMP / SelfMPMax) * 100, 0, 100) or 0;
	local SelfTP = party:GetMemberTP(0);

	local currentTime = os.clock();

	-- Initialize interpolation if not set
	if not playerbar.interpolation.currentHpp then
		playerbar.interpolation.currentHpp = SelfHPPercent;
		playerbar.interpolation.interpolationDamagePercent = 0;
		playerbar.interpolation.interpolationHealPercent = 0;
	end

	-- If the player takes damage
	if SelfHPPercent < playerbar.interpolation.currentHpp then
		local previousInterpolationDamagePercent = playerbar.interpolation.interpolationDamagePercent;

		local damageAmount = playerbar.interpolation.currentHpp - SelfHPPercent;

		playerbar.interpolation.interpolationDamagePercent = playerbar.interpolation.interpolationDamagePercent + damageAmount;

		if previousInterpolationDamagePercent > 0 and playerbar.interpolation.lastHitAmount and damageAmount > playerbar.interpolation.lastHitAmount then
			playerbar.interpolation.lastHitTime = currentTime;
			playerbar.interpolation.lastHitAmount = damageAmount;
		elseif previousInterpolationDamagePercent == 0 then
			playerbar.interpolation.lastHitTime = currentTime;
			playerbar.interpolation.lastHitAmount = damageAmount;
		end

		if not playerbar.interpolation.lastHitTime or currentTime > playerbar.interpolation.lastHitTime + (settings.hitFlashDuration * 0.25) then
			playerbar.interpolation.lastHitTime = currentTime;
			playerbar.interpolation.lastHitAmount = damageAmount;
		end

		-- If we previously were interpolating with an empty bar, reset the hit delay effect
		if previousInterpolationDamagePercent == 0 then
			playerbar.interpolation.hitDelayStartTime = currentTime;
		end

		-- Clear healing interpolation when taking damage
		playerbar.interpolation.interpolationHealPercent = 0;
		playerbar.interpolation.healDelayStartTime = nil;
	elseif SelfHPPercent > playerbar.interpolation.currentHpp then
		-- If the player heals
		local previousInterpolationHealPercent = playerbar.interpolation.interpolationHealPercent;

		local healAmount = SelfHPPercent - playerbar.interpolation.currentHpp;

		playerbar.interpolation.interpolationHealPercent = playerbar.interpolation.interpolationHealPercent + healAmount;

		if previousInterpolationHealPercent > 0 and playerbar.interpolation.lastHealAmount and healAmount > playerbar.interpolation.lastHealAmount then
			playerbar.interpolation.lastHealTime = currentTime;
			playerbar.interpolation.lastHealAmount = healAmount;
		elseif previousInterpolationHealPercent == 0 then
			playerbar.interpolation.lastHealTime = currentTime;
			playerbar.interpolation.lastHealAmount = healAmount;
		end

		if not playerbar.interpolation.lastHealTime or currentTime > playerbar.interpolation.lastHealTime + (settings.hitFlashDuration * 0.25) then
			playerbar.interpolation.lastHealTime = currentTime;
			playerbar.interpolation.lastHealAmount = healAmount;
		end

		-- If we previously were interpolating with an empty bar, reset the heal delay effect
		if previousInterpolationHealPercent == 0 then
			playerbar.interpolation.healDelayStartTime = currentTime;
		end

		-- Clear damage interpolation when healing
		playerbar.interpolation.interpolationDamagePercent = 0;
		playerbar.interpolation.hitDelayStartTime = nil;
	end

	playerbar.interpolation.currentHpp = SelfHPPercent;

	-- Reduce the damage HP amount to display based on the time passed since last frame
	if playerbar.interpolation.interpolationDamagePercent > 0 and playerbar.interpolation.hitDelayStartTime and currentTime > playerbar.interpolation.hitDelayStartTime + settings.hitDelayDuration then
		if playerbar.interpolation.lastFrameTime then
			local deltaTime = currentTime - playerbar.interpolation.lastFrameTime;

			local animSpeed = 0.1 + (0.9 * (playerbar.interpolation.interpolationDamagePercent / 100));

			playerbar.interpolation.interpolationDamagePercent = playerbar.interpolation.interpolationDamagePercent - (settings.hitInterpolationDecayPercentPerSecond * deltaTime * animSpeed);

			-- Clamp our percent to 0
			playerbar.interpolation.interpolationDamagePercent = math.max(0, playerbar.interpolation.interpolationDamagePercent);
		end
	end

	-- Reduce the healing HP amount to display based on the time passed since last frame
	if playerbar.interpolation.interpolationHealPercent > 0 and playerbar.interpolation.healDelayStartTime and currentTime > playerbar.interpolation.healDelayStartTime + settings.hitDelayDuration then
		if playerbar.interpolation.lastFrameTime then
			local deltaTime = currentTime - playerbar.interpolation.lastFrameTime;

			local animSpeed = 0.1 + (0.9 * (playerbar.interpolation.interpolationHealPercent / 100));

			playerbar.interpolation.interpolationHealPercent = playerbar.interpolation.interpolationHealPercent - (settings.hitInterpolationDecayPercentPerSecond * deltaTime * animSpeed);

			-- Clamp our percent to 0
			playerbar.interpolation.interpolationHealPercent = math.max(0, playerbar.interpolation.interpolationHealPercent);
		end
	end

	-- Calculate damage flash overlay alpha
	local interpolationOverlayAlpha = 0;
	if gConfig.healthBarFlashEnabled then
		if playerbar.interpolation.lastHitTime and currentTime < playerbar.interpolation.lastHitTime + settings.hitFlashDuration then
			local hitFlashTime = currentTime - playerbar.interpolation.lastHitTime;
			local hitFlashTimePercent = hitFlashTime / settings.hitFlashDuration;

			local maxAlphaHitPercent = 20;
			local maxAlpha = math.min(playerbar.interpolation.lastHitAmount, maxAlphaHitPercent) / maxAlphaHitPercent;

			maxAlpha = math.max(maxAlpha * 0.6, 0.4);

			interpolationOverlayAlpha = math.pow(1 - hitFlashTimePercent, 2) * maxAlpha;
		end
	end

	-- Calculate healing flash overlay alpha
	local healInterpolationOverlayAlpha = 0;
	if gConfig.healthBarFlashEnabled then
		if playerbar.interpolation.lastHealTime and currentTime < playerbar.interpolation.lastHealTime + settings.hitFlashDuration then
			local healFlashTime = currentTime - playerbar.interpolation.lastHealTime;
			local healFlashTimePercent = healFlashTime / settings.hitFlashDuration;

			local maxAlphaHealPercent = 20;
			local maxAlpha = math.min(playerbar.interpolation.lastHealAmount, maxAlphaHealPercent) / maxAlphaHealPercent;

			maxAlpha = math.max(maxAlpha * 0.6, 0.4);

			healInterpolationOverlayAlpha = math.pow(1 - healFlashTimePercent, 2) * maxAlpha;
		end
	end

	playerbar.interpolation.lastFrameTime = currentTime;

	-- Draw the player window
	if (resetPosNextFrame) then
		imgui.SetNextWindowPos({0,0});
		resetPosNextFrame = false;
	end
	
		
	-- Get base window flags with NoMove dynamically added if positions are locked
	local windowFlags = GetBaseWindowFlags(gConfig.lockPositions);
	ApplyWindowPosition('PlayerBar');
    if (imgui.Begin('PlayerBar', true, windowFlags)) then
		SaveWindowPosition('PlayerBar');

		local hpNameColor, hpGradient = GetCustomHpColors(SelfHPPercent/100, gConfig.colorCustomization.playerBar);

		local SelfJob = GetJobStr(party:GetMemberMainJob(0));
		local SelfSubJob = GetJobStr(party:GetMemberSubJob(0));
		local bShowMp = buffTable.IsSpellcaster(SelfJob) or buffTable.IsSpellcaster(SelfSubJob) or gConfig.alwaysShowMpBar;

		-- Draw HP Bar (two bars to fake animation
		local hpX = imgui.GetCursorPosX();
		local barSize = (settings.barWidth / 3) - settings.barSpacing;

		-- Calculate bookend width and text padding (same as exp bar)
		local bookendWidth = gConfig.showPlayerBarBookends and (settings.barHeight / 2) or 0;
		local textPadding = 8;

		-- Calculate base HP for display (subtract healing to show old HP during heal animation)
		local baseHpPercent = SelfHPPercent;
		if playerbar.interpolation.interpolationHealPercent and playerbar.interpolation.interpolationHealPercent > 0 then
			baseHpPercent = SelfHPPercent - playerbar.interpolation.interpolationHealPercent;
			baseHpPercent = math.max(0, baseHpPercent); -- Clamp to 0
		end

		local hpPercentData = {{baseHpPercent / 100, hpGradient}};

		-- Get cached interpolation colors (only recomputed when config changes)
		local interpColors = getCachedInterpColors();

		-- Add interpolation bar for damage taken
		if playerbar.interpolation.interpolationDamagePercent and playerbar.interpolation.interpolationDamagePercent > 0 then
			local interpolationOverlay;

			if gConfig.healthBarFlashEnabled and interpolationOverlayAlpha > 0 then
				interpolationOverlay = {
					interpColors.damageFlashColor,
					interpolationOverlayAlpha
				};
			end

			table.insert(
				hpPercentData,
				{
					playerbar.interpolation.interpolationDamagePercent / 100,
					interpColors.damageGradient,
					interpolationOverlay
				}
			);
		end

		-- Add interpolation bar for healing received
		if playerbar.interpolation.interpolationHealPercent and playerbar.interpolation.interpolationHealPercent > 0 then
			local healInterpolationOverlay;

			if gConfig.healthBarFlashEnabled and healInterpolationOverlayAlpha > 0 then
				healInterpolationOverlay = {
					interpColors.healFlashColor,
					healInterpolationOverlayAlpha
				};
			end

			table.insert(
				hpPercentData,
				{
					playerbar.interpolation.interpolationHealPercent / 100,
					interpColors.healGradient,
					healInterpolationOverlay
				}
			);
		end

		if (bShowMp == false) then
			imgui.Dummy({(barSize + settings.barSpacing) / 2, 0});

			imgui.SameLine();
		end

		-- Capture HP bar start position
		local hpBarStartX, hpBarStartY = imgui.GetCursorScreenPos();
		progressbar.ProgressBar(hpPercentData, {barSize, settings.barHeight}, {decorate = gConfig.showPlayerBarBookends});

		-- Resting tick shimmer + countdown. Player Status 33 == resting/healing.
		-- Cycle syncs to the first observed MP gain, then every 10s. The shimmer is a
		-- gradient wave that sweeps the HP bar as a visual countdown; the numeric
		-- countdown-to-next-tick is drawn as standalone text near the player bar.
		if playerEnt.Status == 33 then
			local ticker = playerbar.restingTicker;
			local tickerTime = os.clock();

			if not ticker.wasResting then
				ticker.startTime = tickerTime;
				ticker.wasResting = true;
			end

			local elapsed = tickerTime - ticker.startTime;
			-- Progress 0..1 through the current tick interval.
			--
			-- Taken from modules/bovinecombat, which watches for the actual MP
			-- gain, anchors the phase to that observation and then runs pure
			-- 10s arithmetic. Sharing its value keeps this shimmer in lockstep
			-- with the numeric countdown -- if both guessed separately they
			-- would visibly drift apart.
			--
			-- The 10s cycle is exact (measured 9.98s over six intervals). The
			-- FIRST gain is not: it landed anywhere from 20.1s to 23.2s across
			-- runs, because resting syncs you into a cycle already in progress.
			-- Hence the estimate below is only a stand-in until a real tick is
			-- seen.
			local progress;
			local okp, bc = pcall(require, 'modules.bovinecombat.bovinecombat');
			if okp and bc ~= nil and type(bc.GetRestTickProgress) == 'function' then
				progress = bc.GetRestTickProgress();
			end
			if progress == nil then
				-- Fallback when the module isn't loaded. Sweeps over 12s rather
				-- than 10 for the same reason the module does: packets land
				-- +-2s around the grid, and finishing at exactly 10 would
				-- restart the wave while a late one was still pending.
				if elapsed < 21 then
					progress = elapsed / 21;
				else
					local intoCycle = (elapsed - 21) % 12;
					progress = intoCycle / 12;
				end
			end

			-- Sweeping shimmer on the HP bar (optional, on by default).
			if gConfig.playerBarRestingTicker ~= false then
				local shimmerBookendWidth = gConfig.showPlayerBarBookends and (settings.barHeight / 2) or 0;
				local padding = 3.0;
				local width = barSize - shimmerBookendWidth * 2 - (padding * 2);
				if width > 0 then
					local waveWidth = width * 0.06;
					local sx = hpBarStartX + shimmerBookendWidth + padding;
					local y1 = hpBarStartY;
					local y2 = hpBarStartY + settings.barHeight;
					local waveLeft = sx + (progress * (width - waveWidth));
					local waveRight = waveLeft + waveWidth;

					local tickerColorInt = (gConfig.colorCustomization
						and gConfig.colorCustomization.playerBar
						and gConfig.colorCustomization.playerBar.restingTickerColor)
						or 0xFF00E6FF;
					local tc = argbIntToRgba(tickerColorInt);
					local r, g, b, a = tc[1], tc[2], tc[3], tc[4];
					local dl = imgui.GetForegroundDrawList();
					if dl then
						dl:AddRectFilledMultiColor(
							{waveLeft, y1}, {waveRight, y2},
							imgui.GetColorU32({r, g, b, 0.0}),
							imgui.GetColorU32({r, g, b, a}),
							imgui.GetColorU32({r, g, b, a}),
							imgui.GetColorU32({r, g, b, 0.0})
						);
					end
				end
			end

			-- Note: the numeric "next tick" countdown lives in the Combat Timers
			-- window (modules/bovinecombat) now, not here. This block only draws
			-- the shimmer.
		else
			playerbar.restingTicker.wasResting = false;
		end

		imgui.SameLine();
		local hpEndX = imgui.GetCursorPosX();	
		if (SelfHPPercent > 0) then
			imgui.SetCursorPosX(hpX);

			imgui.SameLine();
		end

		local mpBarStartX, mpBarStartY;

		if (bShowMp) then
			-- Draw MP Bar
			imgui.SetCursorPosX(hpEndX + settings.barSpacing);
			-- Capture MP bar start position
			mpBarStartX, mpBarStartY = imgui.GetCursorScreenPos();
			local mpGradient = GetCustomGradient(gConfig.colorCustomization.playerBar, 'mpGradient') or {'#9abb5a', '#bfe07d'};

			-- Check for spell cost preview from castcost module
			local mpPercentData;
			local spellMpCost, hasEnoughMp, isSpellActive = castcostShared.GetMpCost();
			if isSpellActive and spellMpCost > 0 and SelfMPMax > 0 and gConfig.showMpCostPreview ~= false then
				-- Calculate the cost as a percentage of max MP
				local costPercent = spellMpCost / SelfMPMax;
				-- Calculate remaining MP after cast
				local remainingMpPercent = math.max(0, (SelfMPPercent / 100) - costPercent);

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
					-- Scale alpha to be subtle (max 0.6)
					pulseAlpha = pulseAlpha * 0.6;
					costOverlay = {flashColor, pulseAlpha};
				end

				-- Build MP bar with cost preview: [remaining MP][cost segment with pulse]
				mpPercentData = {
					{remainingMpPercent, mpGradient},
					{costPercent, costGradient, costOverlay},
				};
			else
				-- Normal MP bar without cost preview
				mpPercentData = {{SelfMPPercent / 100, mpGradient}};
			end

			progressbar.ProgressBar(mpPercentData, {barSize, settings.barHeight}, {decorate = gConfig.showPlayerBarBookends});
			imgui.SameLine();
		end

		-- Draw TP Bars
		imgui.SetCursorPosX(imgui.GetCursorPosX() + settings.barSpacing);

		-- Capture TP bar start position
		local tpBarStartX, tpBarStartY = imgui.GetCursorScreenPos();

		local tpGradient = GetCustomGradient(gConfig.colorCustomization.playerBar, 'tpGradient') or {'#3898ce', '#78c4ee'};
		local mainPercent;
		local tpOverlay;

		if (SelfTP >= 1000) then
			mainPercent = (SelfTP - 1000) / 2000;

			-- Get TP overlay gradient from settings
			local overlaySettings = gConfig.colorCustomization.playerBar.tpOverlayGradient;
			local tpOverlayGradient;
			if overlaySettings and overlaySettings.enabled then
				tpOverlayGradient = {overlaySettings.start, overlaySettings.stop};
			else
				tpOverlayGradient = {overlaySettings and overlaySettings.start or '#0078CC', overlaySettings and overlaySettings.start or '#0078CC'};
			end

		local tpPulseConfig = nil;
		if gConfig.playerBarTpFlashEnabled then
			-- Get flash color from settings (ARGB) and convert to hex string
			local flashColor = gConfig.colorCustomization.playerBar.tpFlashColor or 0xFF2fa9ff;
			local r = bit.band(bit.rshift(flashColor, 16), 0xFF);
			local g = bit.band(bit.rshift(flashColor, 8), 0xFF);
			local b = bit.band(flashColor, 0xFF);
			local flashHex = string.format('#%02x%02x%02x', r, g, b);
			tpPulseConfig = {
				flashHex, -- overlay pulse color
				1 -- overlay pulse seconds
			};
		end

			tpOverlay = {
				{
					1, -- overlay percent
					tpOverlayGradient -- overlay gradient
				},
				math.ceil(settings.barHeight * 2/7), -- overlay height
				1, -- overlay vertical padding
			tpPulseConfig
			};
		else
			mainPercent = SelfTP / 1000;
		end

		progressbar.ProgressBar({{mainPercent, tpGradient}}, {barSize, settings.barHeight}, {overlayBar=tpOverlay, decorate = gConfig.showPlayerBarBookends});

		imgui.SameLine();

		-- Update our HP Text (drawn via imgui foreground draw list so it sits
		-- ON TOP of the bars - the gdi primitive path renders under imgui
		-- bars, which made text inside the bar invisible).
		local hpDisplayMode = gConfig.playerBarHpDisplayMode or 'number';
		local hpDisplayText;
		if hpDisplayMode == 'percent' then
			hpDisplayText = string.format("%.0f", SelfHPPercent) .. '%';
		elseif hpDisplayMode == 'both' then
			hpDisplayText = tostring(SelfHP) .. ' (' .. string.format("%.0f", SelfHPPercent) .. '%)';
		elseif hpDisplayMode == 'both_percent_first' then
			hpDisplayText = string.format("%.0f", SelfHPPercent) .. '% (' .. tostring(SelfHP) .. ')';
		elseif hpDisplayMode == 'current_max' then
			hpDisplayText = tostring(SelfHP) .. '/' .. tostring(SelfHPMax);
		else
			hpDisplayText = tostring(SelfHP);
		end
		local hpW, hpH = imtext.Measure(hpDisplayText, playerBarFontHeight);
		local hpAnchorX;
		local hpAlignment = gConfig.playerBarHpTextAlignment or 'right';
		if hpAlignment == 'left' then
			hpAnchorX = hpBarStartX + bookendWidth + textPadding;
		elseif hpAlignment == 'center' then
			hpAnchorX = hpBarStartX + (barSize / 2);
		else
			hpAnchorX = hpBarStartX + barSize - bookendWidth - textPadding;
		end
		hpAnchorX = hpAnchorX + (gConfig.playerBarHpTextOffsetX or 0);
		local hpTextX = alignToLeftX(hpAnchorX, hpW, hpAlignment);
		local hpTextY = hpBarStartY + settings.barHeight + settings.textYOffset + (gConfig.playerBarHpTextOffsetY or 0);
		drawOutlinedText(hpTextX, hpTextY, hpDisplayText,
			argbIntToRgba(gConfig.colorCustomization.playerBar.hpTextColor));

		-- Keep the gdi primitive hidden permanently; we draw via imgui above.
		hpText:set_visible(false);

		if (bShowMp) then
			local mpDisplayMode = gConfig.playerBarMpDisplayMode or 'number';
			local mpDisplayText;
			if mpDisplayMode == 'percent' then
				mpDisplayText = string.format("%.0f", SelfMPPercent) .. '%';
			elseif mpDisplayMode == 'both' then
				mpDisplayText = tostring(SelfMP) .. ' (' .. string.format("%.0f", SelfMPPercent) .. '%)';
			elseif mpDisplayMode == 'both_percent_first' then
				mpDisplayText = string.format("%.0f", SelfMPPercent) .. '% (' .. tostring(SelfMP) .. ')';
			elseif mpDisplayMode == 'current_max' then
				mpDisplayText = tostring(SelfMP) .. '/' .. tostring(SelfMPMax);
			else
				mpDisplayText = tostring(SelfMP);
			end
			local mpW, _ = imtext.Measure(mpDisplayText, playerBarFontHeight);
			local mpAnchorX;
			local mpAlignment = gConfig.playerBarMpTextAlignment or 'right';
			if mpAlignment == 'left' then
				mpAnchorX = mpBarStartX + bookendWidth + textPadding;
			elseif mpAlignment == 'center' then
				mpAnchorX = mpBarStartX + (barSize / 2);
			else
				mpAnchorX = mpBarStartX + barSize - bookendWidth - textPadding;
			end
			mpAnchorX = mpAnchorX + (gConfig.playerBarMpTextOffsetX or 0);
			local mpTextX = alignToLeftX(mpAnchorX, mpW, mpAlignment);
			local mpTextY = mpBarStartY + settings.barHeight + settings.textYOffset + (gConfig.playerBarMpTextOffsetY or 0);
			drawOutlinedText(mpTextX, mpTextY, mpDisplayText,
				argbIntToRgba(gConfig.colorCustomization.playerBar.mpTextColor));
		end

		-- gdi primitive stays hidden; imgui draws above (when bShowMp).
		mpText:set_visible(false);

		-- TP text (drawn via imgui above the bar).
		local tpDisplayText = tostring(SelfTP);
		local tpW, _ = imtext.Measure(tpDisplayText, playerBarFontHeight);
		local tpAnchorX;
		local tpAlignment = gConfig.playerBarTpTextAlignment or 'right';
		if tpAlignment == 'left' then
			tpAnchorX = tpBarStartX + bookendWidth + textPadding;
		elseif tpAlignment == 'center' then
			tpAnchorX = tpBarStartX + (barSize / 2);
		else
			tpAnchorX = tpBarStartX + barSize - bookendWidth - textPadding;
		end
		tpAnchorX = tpAnchorX + (gConfig.playerBarTpTextOffsetX or 0);
		local tpTextX = alignToLeftX(tpAnchorX, tpW, tpAlignment);
		local tpTextY = tpBarStartY + settings.barHeight + settings.textYOffset + (gConfig.playerBarTpTextOffsetY or 0);
		local desiredTpColor = (SelfTP >= 1000)
			and gConfig.colorCustomization.playerBar.tpFullTextColor
			 or gConfig.colorCustomization.playerBar.tpEmptyTextColor;
		drawOutlinedText(tpTextX, tpTextY, tpDisplayText, argbIntToRgba(desiredTpColor));

		tpText:set_visible(false);
    end
	imgui.End();
end


playerbar.Initialize = function(settings)
	-- Use FontManager for cleaner font creation
    hpText = FontManager.create(settings.font_settings);
	mpText = FontManager.create(settings.font_settings);
	tpText = FontManager.create(settings.font_settings);
	allFonts = {hpText, mpText, tpText};
end

playerbar.UpdateVisuals = function(settings)
	-- Use FontManager for cleaner font recreation
	hpText = FontManager.recreate(hpText, settings.font_settings);
	mpText = FontManager.recreate(mpText, settings.font_settings);
	tpText = FontManager.recreate(tpText, settings.font_settings);
	allFonts = {hpText, mpText, tpText};

	-- Reset cached colors when fonts are recreated
	lastHpTextColor = nil;
	lastMpTextColor = nil;
	lastTpTextColor = nil;

	-- Reset reference height so it gets recalculated with new font
	referenceTextHeight = 0;

	-- Invalidate interpolation color cache (config may have changed)
	cachedInterpColors = nil;
	lastInterpColorConfig = nil;
end

playerbar.SetHidden = function(hidden)
	if (hidden == true) then
		SetFontsVisible(allFonts, false);
	end
end

playerbar.Cleanup = function()
	-- Use FontManager for cleaner font destruction
	hpText = FontManager.destroy(hpText);
	mpText = FontManager.destroy(mpText);
	tpText = FontManager.destroy(tpText);
	allFonts = nil;
end

return playerbar;