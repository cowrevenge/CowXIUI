--[[
* XIUI Enemy List - WINDOWLESS REBUILD
*
* Draws entirely onto the FOREGROUND draw list. No imgui.Begin window for the
* enemy list -- opening one corrupts the party-list window draw list on this
* Ashita build and blanks the party bars. Everything here is AddRectFilled /
* AddRect / AddText / AddImage on the global foreground list, which is immune
* to that interaction.
*
* Look matches the original: name drawn ON TOP of the HP bar.
*
* Features wired from gConfig:
*   showEnemyList                      master on/off
*   enemyListPreview                   mock enemies when config open
*   showEnemyDistance                  distance text (right)
*   showEnemyHPPText                   HP% text (right)
*   showEnemyListBorders               entry border
*   showEnemyListBordersUseNameColor   border uses name color
*   showEnemyListDebuffs               debuff icons
*   enemyListDebuffsAnchor             'left' | 'right'
*   enableEnemyListClickTarget         click row to target (foreground hit-test)
*   lockPositions                      (kept for parity; no draggable window)
*   enemyListRowsPerColumn             rows before wrapping to next column
*   enemyListMaxColumns                max columns
*   enemyListRowSpacing                vertical gap between rows
*   enemyListColumnSpacing             horizontal gap between columns
*   enemyListDebuffOffsetX/Y           debuff icon offset
*   enemyListSortOrder                 'asc' | 'desc'  (NEW: order by entry time)
*   enemyListX / enemyListY            anchor position (no window to drag)
]]--

require('common');
require('handlers.helpers');
local imgui = require('imgui');
local modulefont = require('libs.modulefont');
local debuffHandler = require('handlers.debuffhandler');
local statusHandler = require('handlers.statushandler');
local colorLib = require('libs.color');
local hex2rgb = colorLib.hex2rgb;

-- Claimed-target set. Keyed by entity index. Value is a monotonically
-- increasing sequence number = entry order (used for asc/desc sorting).
local allClaimedTargets = {};
local entrySeq = 0;

local enemylist = {};

-- Per-element text size for this frame's draws.
--
-- The enemy list used bare imgui.AddText, which is locked to imgui's built-in
-- font -- so the Name/Distance/HP%/Target size sliders did nothing. Text now
-- goes through libs/modulefont (which wraps libs/imtext) so those sliders
-- apply, and 'Default' remains selectable to keep the original crisp look.
local elSize = nil;
local function setElSize(sz) elSize = sz; end

-- Draw at the current element size. Takes an RGBA float table; the call sites
-- here all use plain white, so a single shared constant covers them.
local EL_WHITE = { 1, 1, 1, 1 };
-- 'shadow' style: the original drew a single black copy at +1/+1, not a
-- 4-direction outline. Using the outline here thickens every glyph and loses
-- the crispness this list is meant to have.
local function elText(dl, x, y, text, rgba, size)
    modulefont.DrawText(dl, x, y, text, rgba or EL_WHITE, size or elSize, 'shadow');
end

-- Measure at the size the text will be drawn at.
local function elMeasure(text, size)
    return modulefont.Measure(text, size or elSize);
end
local isHidden = false;

-- Shift-drag move state.
local dragging = false;
local dragDX, dragDY = 0, 0;

-- Preview mock enemies (config screen). previewDebuffs gives each a sample
-- debuff so the debuff icon path is exercised in preview.
local previewEnemies = {
	[9001] = { Name = 'Test Enemy 1', HPPercent = 100, Distance = 72.25 },
	[9002] = { Name = 'Goblin Smithy', HPPercent = 75, Distance = 234.09 },
	[9003] = { Name = 'Yagudo Templar', HPPercent = 50, Distance = 488.41 },
	[9004] = { Name = 'Orcish Warlord', HPPercent = 25, Distance = 900 },
	[9005] = { Name = 'Quadav Veteran', HPPercent = 10, Distance = 100 },
};
-- Sample debuff status ids per preview enemy (e.g. 3=Poison, 13=Slow, 10=Stun,
-- 2=Sleep, 5=Paralyze). Used only in preview mode.
local previewDebuffs = {
	[9001] = 3,
	[9002] = 13,
	[9003] = 10,
	[9004] = 2,
	[9005] = 5,
};
-- Preview "current target" name, shown on the FIRST preview mob only when
-- Show Enemy Targets is enabled.
local previewTargetName = 'Cowrevenge';

-- ============================================================
-- Validity (same render-flag check as original)
-- ============================================================
local function GetIsValidMob(mobIdx, cachedEntityMgr)
	local entity = cachedEntityMgr or GetEntitySafe();
	if entity == nil then return false; end
	local renderflags = entity:GetRenderFlags0(mobIdx);
	if bit.band(renderflags, RENDER_FLAG_VISIBLE) ~= RENDER_FLAG_VISIBLE
		or bit.band(renderflags, RENDER_FLAG_HIDDEN) ~= 0 then
		return false;
	end
	return true;
end

-- u32 ARGB -> {r,g,b,a} 0-1, with opaque fallback.
local function argbToTable(c)
	if c == nil then return {1, 1, 1, 1}; end
	local a = bit.band(bit.rshift(c, 24), 0xFF) / 255;
	local r = bit.band(bit.rshift(c, 16), 0xFF) / 255;
	local g = bit.band(bit.rshift(c,  8), 0xFF) / 255;
	local b = bit.band(c, 0xFF) / 255;
	if a == 0 then a = 1; end
	return {r, g, b, a};
end

-- ============================================================
-- DrawWindow (windowless; foreground draw list)
-- ============================================================
enemylist.DrawWindow = function(settings)
	if isHidden then return; end
	if not gConfig.showEnemyList then return; end

	-- Font config for this frame. Applied here rather than per element because
	-- imtext holds family/weight as module-level state shared with every other
	-- caller -- without this the enemy list would inherit whatever the hotbar or
	-- party list configured last.
	-- Outline width defaults to 1 here, matching the original +1/+1 shadow
	-- offset. The global default of 2 is tuned for the 4-direction outline the
	-- other modules use and is too heavy for a single shadow.
	modulefont.Apply(
		gConfig.enemyListOverrideFont,
		gConfig.enemyListFontFamily,
		gConfig.enemyListFontWeight,
		gConfig.enemyListFontOutlineWidth or 1,
		settings and settings.name_font_settings);

	-- Per-element sizes, from the existing Text Size sliders. These were
	-- previously ignored entirely because the draws used bare AddText.
	local sizes = {
		name     = (settings and settings.name_font_settings and settings.name_font_settings.font_height) or 10,
		distance = (settings and settings.distance_font_settings and settings.distance_font_settings.font_height) or 8,
		percent  = (settings and settings.percent_font_settings and settings.percent_font_settings.font_height) or 8,
		target   = (settings and settings.target_font_settings and settings.target_font_settings.font_height) or 8,
	};
	setElSize(sizes.name);

	local isPreviewMode = showConfig[1] and gConfig.enemyListPreview;
	local entityMgr = GetEntitySafe();

	-- Build the ordered list of valid rows.
	local rows = {};  -- { key=, ent=, seq= }
	if isPreviewMode then
		-- Deterministic order by mob key so seq is stable (pairs() is unordered).
		local keys = {};
		for k in pairs(previewEnemies) do keys[#keys + 1] = k; end
		table.sort(keys);
		for _, k in ipairs(keys) do
			rows[#rows + 1] = { key = k, ent = previewEnemies[k], seq = k, preview = true };
		end
	else
		for k, seq in pairs(allClaimedTargets) do
			local ent = GetEntity(k);
			if ent ~= nil and GetIsValidMob(k, entityMgr)
				and ent.HPPercent ~= nil and ent.HPPercent > 0
				and ent.Name ~= nil then
				rows[#rows + 1] = { key = k, ent = ent, seq = seq };
			else
				-- Mob is no longer valid (dead, out of range, despawned, claim
				-- lost). Remove it from the claimed set so it stops showing.
				-- Matches the original file's per-frame cleanup.
				allClaimedTargets[k] = nil;
			end
		end
	end

	if #rows == 0 then return; end

	-- ===== SORT / ORDER =====
	-- The list is BOTTOM-ANCHORED and grows UPWARD. The first mob to enter
	-- (smallest seq) sits at the BOTTOM and never moves; newer mobs stack on
	-- top of it. When a mob dies, the others shift down to fill the gap, but a
	-- living mob's position relative to the bottom is preserved.
	--
	-- We sort 'rows' so that index 1 = TOP row on screen, last index = BOTTOM.
	--   ascending  : oldest (smallest seq) at BOTTOM -> newest at top.
	--                 draw order top->bottom = seq DESC.
	--   descending : newest (largest seq) at BOTTOM -> oldest at top.
	--                 draw order top->bottom = seq ASC.
	local sortOrder = gConfig.enemyListSortOrder or 'asc';
	table.sort(rows, function(a, b)
		if sortOrder == 'desc' then
			return a.seq < b.seq;   -- oldest at top, newest at bottom
		else
			return a.seq > b.seq;   -- newest at top, oldest at bottom
		end
	end);

	-- Layout values. Each entry is now TWO lines:
	--   line 1 (text):  Name ................... Distance
	--   line 2 (bar):   [HP bar] .............. HP%   (% overlaid on bar)
	local rowW         = (settings and settings.barWidth) or 200;
	local barH         = (settings and settings.barHeight and settings.barHeight > 8 and (settings.barHeight + 6)) or 16;
	local textLineH    = 14;   -- top text line height
	local lineGap      = 2;    -- gap between text line and bar line
	local rowH         = textLineH + lineGap + barH;
	local rowSpacing   = gConfig.enemyListRowSpacing or 5;
	local colSpacing   = gConfig.enemyListColumnSpacing or 10;
	local rowsPerCol   = gConfig.enemyListRowsPerColumn or 8;
	local maxCols      = gConfig.enemyListMaxColumns or 1;
	local padX         = 4;

	local baseX = gConfig.enemyListX or 100;
	local baseY = gConfig.enemyListY or 300;

	-- ===== ANCHOR TO PARTY LIST TARGET BAR =====
	-- When gConfig.enemyListAnchorTarget is on, the enemy list latches onto
	-- the partylist's Target Bar so it stacks with the rest of the chain.
	-- Edge is LEFT/RIGHT because the enemy list lives on the SIDE of the
	-- party stack (not above/below it).
	-- gConfig.enemyListAnchorTargetEdge: 'left' (default) or 'right'.
	-- gConfig.enemyListAnchorOffsetX/Y:   fine-tune sliders on top of the baseline.
	-- gConfig.enemyListAnchorGap:         gap between the list and the target bar.
	-- Built-in baseline shifts (-96 X / +50 X / -18 Y) zero the slider start at
	-- a visually correct position; user sliders move from there.
	-- Falls back to the saved absolute position if the target bar isn't
	-- rendering this frame (so the list doesn't snap to (0,0)).
	local anchoredToTarget = false;
	if gConfig.enemyListAnchorTarget then
		local ok, partylistData = pcall(require, 'modules.partylist.data');
		if ok and partylistData and partylistData.windowRects then
			local tRect = partylistData.windowRects.target;
			if tRect and tRect.valid then
				local edge   = gConfig.enemyListAnchorTargetEdge or 'left';
				local offX   = gConfig.enemyListAnchorOffsetX or 0;
				local offY   = gConfig.enemyListAnchorOffsetY or 0;
				local gap    = gConfig.enemyListAnchorGap or 6;

				-- Y baseline: -18 lifts the list bottom above the target bottom
				-- so the visible bottoms align after rounded corners / overhang.
				local Y_BASELINE = -18;
				baseY = tRect.y + tRect.h + Y_BASELINE + offY;

				-- X baselines per edge — built-in starting position so the
				-- slider at 0 looks right. Slider then nudges from there.
				if edge == 'right' then
					local X_BASELINE_RIGHT = 36;
					baseX = tRect.x + tRect.w + gap + X_BASELINE_RIGHT + offX;
				else
					-- 'left': list right edge sits to the LEFT of target.x.
					-- baseX = column-0's left edge, so subtract listW.
					local X_BASELINE_LEFT = -96;
					local listW = maxCols * rowW + math.max(0, maxCols - 1) * colSpacing;
					baseX = tRect.x - listW - gap + X_BASELINE_LEFT + offX;
				end
				anchoredToTarget = true;
			end
		end
	end

	local drawList  = imgui.GetForegroundDrawList();

	-- ===== SHIFT-CLICK DRAG MOVE =====
	-- Hold Shift and drag anywhere over the list's bounding area to move it.
	-- Position is stored in gConfig.enemyListX/Y and saved on release.
	-- Skipped while anchored — the anchor owns position, dragging would fight it.
	if not anchoredToTarget then
		local okDrag = pcall(function()
			local shiftDown = imgui.GetIO and imgui.GetIO().KeyShift;
			if shiftDown == nil then
				-- Fallback: check both shift keys if available
				shiftDown = imgui.IsKeyDown and (imgui.IsKeyDown(0x10));
			end
			local mxp, myp = imgui.GetMousePos();

			-- Bounding box of the whole list. The list is BOTTOM-anchored and
			-- grows UPWARD from baseY, so the box spans (baseY - boundH) .. baseY.
			local totalCols = math.min(maxCols, math.ceil(#rows / rowsPerCol));
			if totalCols < 1 then totalCols = 1; end
			local rowsInFirst = math.min(#rows, rowsPerCol);
			local boundW = totalCols * (rowW + colSpacing);
			local boundH = rowsInFirst * (rowH + rowSpacing) + 4;
			local insideBounds = mxp >= (baseX - 4) and mxp <= (baseX + boundW)
				and myp >= (baseY - boundH) and myp <= (baseY + 4);

			if dragging then
				if imgui.IsMouseDown(0) then
					gConfig.enemyListX = mxp - dragDX;
					gConfig.enemyListY = myp - dragDY;
					baseX = gConfig.enemyListX;
					baseY = gConfig.enemyListY;
				else
					dragging = false;
					if SaveSettingsOnly then SaveSettingsOnly(); end
				end
			elseif shiftDown and imgui.IsMouseClicked(0) and insideBounds then
				dragging = true;
				dragDX = mxp - baseX;
				dragDY = myp - baseY;
			end
		end);
		if not okDrag then dragging = false; end
	else
		-- Ensure no stale drag state persists if user toggled anchor mid-drag.
		dragging = false;
	end

	-- Colors
	local hpTrack   = imgui.GetColorU32({0.15, 0.04, 0.04, 0.9});
	local textCol   = imgui.GetColorU32({1, 1, 1, 1});
	local textBlack = imgui.GetColorU32({0, 0, 0, 1});

	-- HP fill color from enemyList.hpGradient.start
	local gr = gConfig.colorCustomization
		and gConfig.colorCustomization.enemyList
		and gConfig.colorCustomization.enemyList.hpGradient;
	local startHex = (gr and gr.start) or '#e16c6c';
	local fr, fg, fb = hex2rgb(startHex);
	local fillCol = imgui.GetColorU32({ (fr or 225)/255, (fg or 108)/255, (fb or 108)/255, 1.0 });

	-- Border color
	local borderColEnabled = gConfig.showEnemyListBorders;
	local borderColU32;
	if borderColEnabled then
		local bc = gConfig.colorCustomization
			and gConfig.colorCustomization.enemyList
			and gConfig.colorCustomization.enemyList.borderColor;
		borderColU32 = imgui.GetColorU32(argbToTable(bc or 0xFF552020));
	end

	-- Mouse for click-target hit testing.
	local clickEnabled = (not isPreviewMode) and (not showConfig[1]) and gConfig.enableEnemyListClickTarget;
	local mx, my = 0, 0;
	local mclick = false;
	if clickEnabled then
		local ok = pcall(function()
			mx, my = imgui.GetMousePos();
			mclick = imgui.IsMouseClicked(0);
		end);
		if not ok then clickEnabled = false; end
	end

	-- Debuff settings
	local showDebuffs   = gConfig.showEnemyListDebuffs;
	local debuffAnchor  = gConfig.enemyListDebuffsAnchor or 'left';
	local debuffOffX    = (settings and settings.debuffOffsetX) or gConfig.enemyListDebuffOffsetX or 5;
	local debuffOffY    = (settings and settings.debuffOffsetY) or gConfig.enemyListDebuffOffsetY or 0;
	local iconSize      = (settings and settings.iconSize) or 18;

	-- ===== CURRENT-TARGET HIGHLIGHT =====
	-- If the player's current target appears in the enemy list, wrap that row
	-- in an orange selector (matches the partylist target-row styling). In
	-- preview mode we hardcode the SECOND preview enemy (key 9002 = Goblin
	-- Smithy) as the "current target" so the user can see it without holding
	-- a real target while the config menu is open.
	local currentTargetIdx = nil;
	if isPreviewMode then
		currentTargetIdx = 9002;
	else
		pcall(function()
			local tm = AshitaCore:GetMemoryManager():GetTarget();
			if tm then
				local idx = tm:GetTargetIndex(0);   -- slot 0 = primary target
				if idx and idx > 0 then currentTargetIdx = idx; end
			end
		end);
	end

	-- Selector colors. Use the per-list theming knobs already in
	-- gConfig.colorCustomization.enemyList if present, else fall back to the
	-- standard orange used for "Locked" elsewhere in the addon.
	local selectorBorderU32, selectorFillU32;
	do
		local cc = gConfig.colorCustomization and gConfig.colorCustomization.enemyList;
		local borderARGB = (cc and cc.targetBorderColor) or 0xFFff8c1a;  -- bright orange
		local rgba = argbToTable(borderARGB);
		selectorBorderU32 = imgui.GetColorU32(rgba);
		-- Fill = same hue, low alpha so it tints the row without hiding text.
		selectorFillU32 = imgui.GetColorU32({ rgba[1], rgba[2], rgba[3], 0.18 });
	end

	-- Render each row, walking columns.
	for i = 1, #rows do
		local r   = rows[i];
		local ent = r.ent;
		local k   = r.key;

		local col = math.floor((i - 1) / rowsPerCol);
		if col > (maxCols - 1) then col = maxCols - 1; end
		local rowInCol = (i - 1) - (col * rowsPerCol);

		-- Rows in this column. For bottom anchoring we need the count so the
		-- bottom row's bottom edge stays fixed and rows stack upward.
		local rowsThisCol = math.min(rowsPerCol, #rows - (col * rowsPerCol));
		-- baseY is the BOTTOM anchor of the list. The bottom-most row sits with
		-- its bottom edge at baseY; each row above is one (rowH+rowSpacing) up.
		-- rowInCol 0 = top row of the column, (rowsThisCol-1) = bottom row.
		local fromBottom = (rowsThisCol - 1) - rowInCol;  -- 0 = bottom row

		local left   = baseX + col * (rowW + colSpacing);
		local bottom = baseY - fromBottom * (rowH + rowSpacing);
		local top    = bottom - rowH;
		local right  = left + rowW;

		-- ===== CURRENT TARGET SELECTOR =====
		-- Draw FIRST so the row's text and HP bar render on top (translucent
		-- fill won't hide them anyway; this just keeps z-order tidy). The
		-- selector wraps the full row with a small bleed so the border doesn't
		-- clip against the HP bar's edges.
		local isCurrentTarget = (currentTargetIdx ~= nil) and (k == currentTargetIdx);
		if isCurrentTarget then
			local pad = 2;
			local selTL = { left - pad, top - pad };
			local selBR = { right + pad, bottom + pad };
			drawList:AddRectFilled(selTL, selBR, selectorFillU32, 3);
			drawList:AddRect(selTL, selBR, selectorBorderU32, 3, 15, 2.0);
		end

		-- ===== LINE 1: Name (left) ... Distance (right) =====
		local line1Y = top;
		local nx = left + padX;

		-- Distance string + its left edge (right-aligned), computed first so the
		-- name can be capped to not overrun it.
		local dStr, dx;
		if gConfig.showEnemyDistance and ent.Distance ~= nil then
			local yalms = math.sqrt(ent.Distance);
			dStr = ('%.1f'):format(yalms);
			local w = elMeasure(dStr);
			dx = right - padX - (w or 0);
		end

		-- Name available width: from name start to either the distance text's
		-- left edge (with a gap) or the right padding if no distance shown.
		local nameRightLimit = dStr and (dx - 6) or (right - padX);
		local nameMaxW = nameRightLimit - nx;
		if nameMaxW < 8 then nameMaxW = 8; end

		-- Truncate with '..' when too wide (same rule as the target box).
		local name = tostring(ent.Name or '');
		local nameW = elMeasure(name);
		if nameW and nameW > nameMaxW then
			local dotsW = elMeasure('..');
			while #name > 1 do
				name = name:sub(1, #name - 1);
				local w = elMeasure(name);
				if (w + dotsW) <= nameMaxW then break; end
			end
			name = name .. '..';
		end

		-- One call: imtext draws the outline itself, so the separate black
		-- shadow pass these used is no longer needed.
		setElSize(sizes.name);
		elText(drawList, nx, line1Y, name);

		if dStr then
			elText(drawList, dx, line1Y, dStr, nil, sizes.distance);
		end

		-- ===== LINE 2: HP bar (full width) with HP% overlaid right =====
		local barTop    = top + textLineH + lineGap;
		local barBottom = barTop + barH;
		local hpLeft    = left;
		local hpRight   = right;
		local hpFullW   = hpRight - hpLeft;

		local hpp = ent.HPPercent or 0;
		if hpp < 0 then hpp = 0; elseif hpp > 100 then hpp = 100; end

		drawList:AddRectFilled({hpLeft, barTop}, {hpRight, barBottom}, hpTrack, 2);
		if hpp > 0 then
			drawList:AddRectFilled({hpLeft, barTop}, {hpLeft + hpFullW * (hpp / 100), barBottom}, fillCol, 2);
		end
		if borderColEnabled then
			drawList:AddRect({hpLeft, barTop}, {hpRight, barBottom}, borderColU32, 2, 15, 1.5);
		end

		-- HP% overlaid on the bar, right-aligned
		if gConfig.showEnemyHPPText then
			local hpStr = ('%.0f%%'):format(hpp);
			local w, h = elMeasure(hpStr);
			local hx = hpRight - padX - (w or 0);
			local hy = barTop + (barH - (h or 12)) / 2;
			elText(drawList, hx, hy, hpStr, nil, sizes.percent);
		end

		-- Debuff icons (ALL active debuffs), in a row from the anchor edge.
		if showDebuffs then
			local ids = nil;
			if r.preview then
				-- Preview: wrap the single sample id in a list.
				if previewDebuffs[k] ~= nil then ids = { previewDebuffs[k] }; end
			else
				local okD, list = pcall(function()
					local serverId = entityMgr and entityMgr.GetServerId and entityMgr:GetServerId(k) or nil;
					if serverId == nil then return nil; end
					local got = debuffHandler.GetActiveDebuffs(serverId);
					if got ~= nil and #got > 0 then
						-- Copy into a stable plain list.
						local out = {};
						for n = 1, #got do out[n] = got[n]; end
						return out;
					end
					return nil;
				end);
				if okD then ids = list; end
			end

			if ids ~= nil and #ids > 0 then
				local iconSpacing = 1;
				local iy = top + (rowH - iconSize) / 2 + debuffOffY;
				-- Total width of the icon row (for left-anchor positioning).
				local totalW = (#ids * iconSize) + ((#ids - 1) * iconSpacing);
				local startX;
				if debuffAnchor == 'right' then
					startX = right + debuffOffX;
				else
					startX = left - totalW - debuffOffX;
				end
				for di = 1, #ids do
					local okI, iconPtr = pcall(function()
						return statusHandler.get_icon_from_theme(gConfig.statusIconTheme, ids[di]);
					end);
					if okI and iconPtr ~= nil then
						local ix = startX + (di - 1) * (iconSize + iconSpacing);
						drawList:AddImage(
							iconPtr,
							{ix, iy},
							{ix + iconSize, iy + iconSize},
							{0, 0}, {1, 1},
							imgui.GetColorU32({1, 1, 1, 1})
						);
					end
				end
			end
		end

		-- ===== ENEMY TARGET sub-box =====
		-- Real path: the mob's current target (via actionTracker). Preview: show
		-- a sample target on the FIRST preview mob only so the feature is visible.
		if gConfig.showEnemyListTargets then
			local targetName = nil;
			if r.preview then
				-- Show the sample target on the first preview mob (key 9001).
				if k == 9001 then targetName = previewTargetName; end
			else
				local okT, tn = pcall(function()
					local actionTracker = require('handlers.actiontracker');
					local serverId = entityMgr and entityMgr.GetServerId and entityMgr:GetServerId(k) or nil;
					if serverId == nil then return nil; end
					local tIdx = actionTracker.GetLastTarget(serverId);
					if tIdx == nil then return nil; end
					local tEnt = GetEntity(tIdx);
					if tEnt ~= nil and tEnt.Name ~= nil then return tostring(tEnt.Name); end
					return nil;
				end);
				if okT then targetName = tn; end
			end

			if targetName ~= nil then
				local tOffX = (gConfig.enemyListTargetOffsetX or 10) + 6;  -- +6px gap so it doesn't touch the entry
				-- Box width: configured width + room for ~2 extra characters.
				local extraChars = 2;
				local charW = elMeasure('W');  -- approx per-char width
				local tW    = (gConfig.enemyListTargetWidth or 100) + (extraChars * (charW or 8));
				local tx0   = right + tOffX;
				-- Anchor to the EXACT HP bar rectangle Y: same top and bottom as
				-- the bar on line 2. No stored offsetY -- it sits on the bar line.
				local ty0      = barTop;
				local ty1      = barBottom;
				local tH       = ty1 - ty0;
				local tCenterY = ty0 + (tH / 2);

				-- Ellipsis truncation: if the name is wider than the inner box,
				-- trim and append '..' so it fills to the last two slots.
				local innerW = tW - 8;  -- 4px padding each side
				local shown = tostring(targetName);
				local sw = elMeasure(shown);
				if sw and sw > innerW then
					-- Trim characters until "<trimmed>.." fits.
					local dotsW = elMeasure('..');
					while #shown > 1 do
						shown = shown:sub(1, #shown - 1);
						local w = elMeasure(shown);
						if (w + dotsW) <= innerW then break; end
					end
					shown = shown .. '..';
				end

				local tFill = imgui.GetColorU32({0.10, 0.08, 0.04, 0.85});
				local tBord = imgui.GetColorU32(argbToTable(
					(gConfig.colorCustomization and gConfig.colorCustomization.enemyList
						and gConfig.colorCustomization.enemyList.targetNameTextColor) or 0xFFFFAA00));
				drawList:AddRectFilled({tx0, ty0}, {tx0 + tW, ty1}, tFill, 3);
				drawList:AddRect({tx0, ty0}, {tx0 + tW, ty1}, tBord, 3, 15, 1.0);
				-- Target name, vertically centered in the box.
				local _, tnH = elMeasure(shown);
				local tnY = tCenterY - ((tnH or 12) / 2);
				elText(drawList, tx0 + 4, tnY, shown, nil, sizes.target);
			end
		end

		-- Click-to-target hit test (covers the whole entry). Suppressed while
		-- shift-dragging the list.
		if clickEnabled and mclick and not dragging
			and mx >= left and mx <= right and my >= top and my <= bottom then
			pcall(function()
				local serverId = entityMgr and entityMgr.GetServerId and entityMgr:GetServerId(k) or nil;
				if serverId ~= nil then
					AshitaCore:GetChatManager():QueueCommand(1, ('/target <%d>'):format(serverId));
				end
			end);
		end
	end
end

-- ============================================================
-- Packet handlers (same claim filter as original)
-- ============================================================

-- Mob acts on a party member -> claimed.
enemylist.HandleActionPacket = function(e)
	if (e == nil) then return; end
	if (GetIsMobByIndex(e.UserIndex) and GetIsValidMob(e.UserIndex)) then
		for i = 0, #e.Targets do
			if (e.Targets[i] ~= nil and IsPartyMemberByServerId(e.Targets[i].Id)) then
				if allClaimedTargets[e.UserIndex] == nil then
					entrySeq = entrySeq + 1;
					allClaimedTargets[e.UserIndex] = entrySeq;
				end
				break;
			end
		end
	end
end

-- Mob claim id becomes a party member -> claimed.
enemylist.HandleMobUpdatePacket = function(e)
	if (e == nil) then return; end
	if (e.newClaimId ~= nil and e.monsterIndex ~= nil and GetIsValidMob(e.monsterIndex)) then
		if IsPartyMemberByServerId(e.newClaimId) then
			if allClaimedTargets[e.monsterIndex] == nil then
				entrySeq = entrySeq + 1;
				allClaimedTargets[e.monsterIndex] = entrySeq;
			end
		end
	end
end

enemylist.HandleZonePacket = function(e)
	allClaimedTargets = {};
	entrySeq = 0;
end

-- ============================================================
-- Lifecycle
-- ============================================================
enemylist.Initialize = function(settings) end
enemylist.UpdateVisuals = function(settings) end
enemylist.SetHidden = function(hidden) isHidden = (hidden == true); end
enemylist.Cleanup = function()
	allClaimedTargets = {};
	entrySeq = 0;
end

return enemylist;