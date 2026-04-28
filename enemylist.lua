require('common');
require('helpers');
local imgui = require('imgui');
local debuffHandler = require('debuffhandler');
local statusHandler = require('statushandler');
local progressbar = require('progressbar');

-- TODO: Calculate these instead of manually setting them
local bgAlpha = 0.4;
local bgRadius = 3;
local allClaimedTargets = {};
local enemylist = {};

-- State for "Stack Entries Upward" mode (bottom-anchored window). ImGui
-- only lets us pin the top-left corner, so we track the desired bottom Y
-- ourselves and each frame compute top = anchorBottomY - lastHeight via
-- SetNextWindowPos. While the user is dragging we skip the override and
-- recapture the anchor from the new position so dragging still works.
local stackUpAnchorX = nil;
local stackUpAnchorBottomY = nil;
local stackUpLastHeight = 0;

local function GetIsValidMob(mobIdx)
	-- Check if we are valid, are above 0 hp, and are rendered

    local renderflags = AshitaCore:GetMemoryManager():GetEntity():GetRenderFlags0(mobIdx);
    if bit.band(renderflags, 0x200) ~= 0x200 or bit.band(renderflags, 0x4000) ~= 0 then
        return false;
    end
	return true;
end

local function GetPartyMemberIds()
	local partyMemberIds = T{};
	local party = AshitaCore:GetMemoryManager():GetParty();
	for i = 0, 17 do
		if (party:GetMemberIsActive(i) == 1) then
			table.insert(partyMemberIds, party:GetMemberServerId(i));
		end
	end
	return partyMemberIds;
end

enemylist.DrawWindow = function(settings)

	imgui.SetNextWindowSize({ settings.barWidth, -1, }, ImGuiCond_Always);

	-- Bottom-anchor: pin the window's bottom edge by overriding its top
	-- position from our stored anchor and last frame's height. We skip the
	-- override while a drag is in progress so the user can still reposition
	-- the window; the new anchor is recaptured below inside Begin.
	local stackUp = gConfig.enemyListStackUpward;
	local userIsDragging = imgui.IsMouseDragging(0);
	if (stackUp and stackUpAnchorBottomY ~= nil and not userIsDragging) then
		imgui.SetNextWindowPos({stackUpAnchorX, stackUpAnchorBottomY - stackUpLastHeight}, ImGuiCond_Always);
	end

	-- Draw the main target window
	local windowFlags = bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoBringToFrontOnFocus);
	if (gConfig.lockPositions) then
		windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoMove);
	end
	if (imgui.Begin('EnemyList', true, windowFlags)) then
		imgui.SetWindowFontScale(settings.textScale);
		local winStartX, winStartY = imgui.GetWindowPos();
		local playerTarget = AshitaCore:GetMemoryManager():GetTarget();
		local targetIndex;
		local subTargetIndex;
		local subTargetActive = false;
		if (playerTarget ~= nil) then
			subTargetActive = GetSubTargetActive();
			targetIndex, subTargetIndex = GetTargets();
			if (subTargetActive) then
				local tempTarget = targetIndex;
				targetIndex = subTargetIndex;
				subTargetIndex = tempTarget;
			end
		end
		
		-- First pass: walk allClaimedTargets in pairs() order, collecting
		-- keys that should be rendered and dropping any that are no longer
		-- valid. Splitting the cleanup from the render lets us iterate the
		-- render pass forward or in reverse below.
		local renderOrder = {};
		for k,v in pairs(allClaimedTargets) do
			local ent = GetEntity(k);
			if (v ~= nil and ent ~= nil and GetIsValidMob(k) and ent.HPPercent > 0 and ent.Name ~= nil) then
				table.insert(renderOrder, k);
			else
				allClaimedTargets[k] = nil;
			end
		end

		-- Render pass: forward normally, or reversed when stacking upward
		-- so the first (oldest) entry sits at the bottom of the list and
		-- newer entries appear above it.
		local startIdx, endIdx, step = 1, #renderOrder, 1;
		if (stackUp) then
			startIdx, endIdx, step = #renderOrder, 1, -1;
		end

		local numTargets = 0;
		for i = startIdx, endIdx, step do
			local k = renderOrder[i];
			local ent = GetEntity(k);
			do
				-- Obtain and prepare target information..
				local targetNameText = ent.Name;
				-- if (targetNameText ~= nil) then

					local color = GetColorOfTargetRGBA(ent, k);
					imgui.Dummy({0,settings.entrySpacing});
					local rectLength = imgui.GetColumnWidth() + imgui.GetStyle().FramePadding.x;
					
					-- draw background to entry
					local winX, winY  = imgui.GetCursorScreenPos();

					-- Figure out sizing on the background
					local cornerOffset = settings.bgTopPadding;
					local _, yDist = imgui.CalcTextSize(targetNameText);
					if (yDist > settings.barHeight) then
						yDist = yDist + yDist;
					else
						yDist = yDist + settings.barHeight;
					end

					draw_rect({winX + cornerOffset , winY + cornerOffset}, {winX + rectLength, winY + yDist + settings.bgPadding}, {0,0,0,bgAlpha}, bgRadius, true);

					-- Draw outlines for our target and subtarget
					if (subTargetIndex ~= nil and k == subTargetIndex) then
						draw_rect({winX + cornerOffset, winY + cornerOffset}, {winX + rectLength - 1, winY + yDist + settings.bgPadding}, {.5,.5,1,1}, bgRadius, false);
					elseif (targetIndex ~= nil and k == targetIndex) then
						draw_rect({winX + cornerOffset, winY + cornerOffset}, {winX + rectLength - 1, winY + yDist + settings.bgPadding}, {1,1,1,1}, bgRadius, false);
					end

					-- Display the targets information..
					imgui.TextColored(color, targetNameText);
					local percentText  = ('%.f'):fmt(ent.HPPercent);
					local x, _  = imgui.CalcTextSize(percentText);
					local fauxX, _  = imgui.CalcTextSize('100');

					-- Draw buffs and debuffs
					local buffIds = debuffHandler.GetActiveDebuffs(AshitaCore:GetMemoryManager():GetEntity():GetServerId(k));
					if (buffIds ~= nil and #buffIds > 0) then
						local debuffX;
						if (gConfig.enemyListDebuffsLeft) then
							-- Estimate the debuff window width so we can pin its right
							-- edge to the left of the bar. Icons use ItemSpacing {1,1}
							-- (set below) and the window keeps its default WindowPadding
							-- (~8px each side ⇒ +16). Close enough; users can fine-tune
							-- with debuffOffsetX.
							local iconCount = math.min(#buffIds, settings.maxIcons);
							local debuffWidth = iconCount * settings.iconSize + math.max(0, iconCount - 1) + 16;
							debuffX = winStartX - debuffWidth - settings.debuffOffsetX;
						else
							debuffX = winStartX + settings.barWidth + settings.debuffOffsetX;
						end
						imgui.SetNextWindowPos({debuffX, winY + settings.debuffOffsetY});
						if (imgui.Begin('EnemyDebuffs'..k, true, bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoSavedSettings))) then
							imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {1, 1});
							DrawStatusIcons(buffIds, settings.iconSize, settings.maxIcons, 1);
							imgui.PopStyleVar(1);
						end 
						imgui.End();
					end

					imgui.SetCursorPosX(imgui.GetCursorPosX() + fauxX - x);
					imgui.Text(percentText);
					imgui.SameLine();
					imgui.SetCursorPosX(imgui.GetCursorPosX() - 3);
					-- imgui.ProgressBar(ent.HPPercent / 100, { -1, settings.barHeight}, '');
					progressbar.ProgressBar({{ent.HPPercent / 100, {'#e16c6c', '#fb9494'}}}, {-1, settings.barHeight}, {decorate = gConfig.showEnemyListBookends});
					imgui.SameLine();

					imgui.Separator();

					numTargets = numTargets + 1;
					if (numTargets >= gConfig.maxEnemyListEntries) then
						break;
					end
				-- end
			end
		end

		-- Capture geometry for next frame's bottom-anchor calculation. On
		-- first activation (or while the user is actively dragging this
		-- window) we update the anchor from the live position; otherwise
		-- we just remember the height so the override can pin the bottom.
		if (stackUp) then
			local px, py = imgui.GetWindowPos();
			local _, ph = imgui.GetWindowSize();
			if (stackUpAnchorBottomY == nil or (userIsDragging and imgui.IsWindowHovered())) then
				stackUpAnchorX = px;
				stackUpAnchorBottomY = py + ph;
			end
			stackUpLastHeight = ph;
		else
			stackUpAnchorBottomY = nil;
		end
	end
	imgui.End();
end

-- If a mob performns an action on us or a party member add it to the list
enemylist.HandleActionPacket = function(e)
	if (e == nil) then 
		return; 
	end
	if (GetIsMobByIndex(e.UserIndex) and GetIsValidMob(e.UserIndex)) then
		local partyMemberIds = GetPartyMemberIds();
		for i = 0, #e.Targets do
			if (e.Targets[i] ~= nil and (partyMemberIds:contains(e.Targets[i].Id))) then
				allClaimedTargets[e.UserIndex] = 1;
			end
		end
	end
end

-- if a mob updates its claimid to be us or a party member add it to the list
enemylist.HandleMobUpdatePacket = function(e)
	if (e == nil) then 
		return; 
	end
	if (e.newClaimId ~= nil and GetIsValidMob(e.monsterIndex)) then	
		local partyMemberIds = GetPartyMemberIds();
		if ((partyMemberIds:contains(e.newClaimId))) then
			allClaimedTargets[e.monsterIndex] = 1;
		end
	end
end

enemylist.HandleZonePacket = function(e)
	-- Empty all our claimed targets on zone
	allClaimedTargets = T{};
end

return enemylist;