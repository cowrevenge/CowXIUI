require('common');
local imgui = require('imgui');
local ffi = require('ffi');
local fonts = require('fonts');
local primitives = require('primitives');
local statusHandler = require('statushandler');
local buffTable = require('bufftable');
local progressbar = require('progressbar');
local encoding = require('gdifonts.encoding');
local ashita_settings = require('settings');

---------------------------------------------------------------------------------

local fullMenuWidth = {};
local fullMenuHeight = {};
local buffWindowX = {};
local debuffWindowX = {};

local partyWindowPrim = {};
partyWindowPrim[1] = { background = {}, }
partyWindowPrim[2] = { background = {}, }
partyWindowPrim[3] = { background = {}, }

local selectionPrim;
local arrowPrim;
local partyTargeted;
local partySubTargeted;
local memberText = {};
local partyMaxSize = 6;
local memberTextCount = partyMaxSize * 3;

local borderConfig = {1, '#243e58'};

local bgImageKeys = { 'bg', 'tl', 'tr', 'br', 'bl' };
local bgTitleAtlasItemCount = 4;
local bgTitleItemHeight;
local loadedBg = nil;

local partyList = {};
local targetText = {};
local partyList1Pos = { x = 0, y = 0 };
local targetWindowPrevH = 0;
local treasurePoolActive = false;  -- tracked via incoming packets (see partyList.HandleIncomingPacket)

-- ============================================================================
-- CAST COST: Inlined spell/ability/mount highlight detection and info panel.
-- Anchors above the Target preview (or where it would be if target is hidden).
-- ============================================================================

local cc_ptrs = T{
    ability_sel     = ashita.memory.find('FFXiMain.dll', 0, '81EC80000000568B35????????8BCE8B463050E8', 0x09, 0),
    magic_sel       = ashita.memory.find('FFXiMain.dll', 0, '81EC80000000568B35????????578BCE8B7E3057', 0x09, 0),
    mount_sel       = ashita.memory.find('FFXiMain.dll', 0, '8B4424048B0D????????50E8????????8B0D????????C7411402000000C3', 0x06, 0),
    getitem_ability = ashita.memory.find('FFXiMain.dll', 0, '8B44240485C07C??3B41447D??8B49208D04C185C075??83C8FFC204008B108B', 0, 0),
    getitem_spell   = ashita.memory.find('FFXiMain.dll', 0, '8B44240485C07C??3B41447D??8B49208D04C185C075??83C8FFC204008B108B', 0, 1),
    getitem         = ashita.memory.find('FFXiMain.dll', 0, '8B44240485C07C??3B41447D??8B49208D04C185C075??83C8FFC204008B00C20400', 0, 0),
};
local cc_pGameMenu = ashita.memory.find('FFXiMain.dll', 0, "8B480C85C974??8B510885D274??3B05", 16, 0);
local castCostPrevH = 0;

pcall(function()
    ffi.cdef[[
        typedef int32_t (__thiscall* KaListBox_GetItem_f)(uint32_t, int32_t);
    ]];
end);

local function cc_GetMenuName()
    if cc_pGameMenu == 0 then return ''; end
    local subPointer = ashita.memory.read_uint32(cc_pGameMenu);
    local subValue   = ashita.memory.read_uint32(subPointer);
    if subValue == 0 then return ''; end
    local menuHeader = ashita.memory.read_uint32(subValue + 4);
    local menuName   = ashita.memory.read_string(menuHeader + 0x46, 16);
    return string.gsub(menuName, '\x00', '');
end

local function cc_GetKaMenu(basePtr)
    if basePtr == 0 then return 0; end
    local ptr = ashita.memory.read_uint32(basePtr);
    if ptr == 0 then return 0; end
    return ashita.memory.read_uint32(ptr) or 0;
end

local function cc_GetSelectedId(basePtr, getitemFuncPtr)
    if getitemFuncPtr == 0 then return -1; end
    local obj = cc_GetKaMenu(basePtr);
    if obj == 0 then return -1; end
    if ashita.memory.read_int32(obj + 0x40) <= 0 then return -1; end
    local idx  = ashita.memory.read_int32(obj + 0x30);
    local func = ffi.cast('KaListBox_GetItem_f', getitemFuncPtr);
    return func(obj, idx);
end

local function cc_GetCurrentSelection()
    local menuName = cc_GetMenuName();
    local resMgr   = AshitaCore:GetResourceManager();
    if resMgr == nil then return nil; end

    if menuName:find('magic') then
        local id = cc_GetSelectedId(cc_ptrs.magic_sel, cc_ptrs.getitem_spell ~= 0 and cc_ptrs.getitem_spell or cc_ptrs.getitem_ability);
        if id < 0 then return nil; end
        local spell = resMgr:GetSpellById(id);
        if spell == nil then return nil; end
        return {
            type        = 'spell',
            id          = id,
            name        = spell.Name[1] or 'Unknown',
            mpCost      = spell.ManaCost or 0,
            recastDelay = spell.RecastDelay or 0,
        };
    elseif menuName:find('ability') then
        local id = cc_GetSelectedId(cc_ptrs.ability_sel, cc_ptrs.getitem_ability);
        if id < 0 then return nil; end
        local ab = resMgr:GetAbilityById(id);
        if ab == nil then return nil; end
        return {
            type          = 'ability',
            id            = id,
            name          = ab.Name[1] or 'Unknown',
            isWeaponSkill = id >= 1 and id <= 255,
            recastDelay   = ab.RecastDelay or 0,
        };
    elseif menuName:find('mount') then
        local id = cc_GetSelectedId(cc_ptrs.mount_sel, cc_ptrs.getitem);
        if id < 0 then return nil; end
        local mountName = resMgr:GetString('mounts.names', id);
        if mountName == nil then return nil; end
        return { type = 'mount', name = mountName };
    end
    return nil;
end

local function cc_GetPlayerStats()
    local party = AshitaCore:GetMemoryManager():GetParty();
    if party == nil then return 0, 0; end
    return party:GetMemberMP(0) or 0, party:GetMemberTP(0) or 0;
end

local function cc_FormatRecastDelay(raw)
    if raw == nil or raw <= 0 then return ''; end
    local secs = raw / 4;  -- RecastDelay is in 1/4 seconds
    if secs >= 60 then
        return string.format('%dm %ds', math.floor(secs / 60), math.floor(secs) % 60);
    end
    return string.format('%ds', math.floor(secs));
end

local function cc_FormatSeconds(secs)
    if secs == nil or secs <= 0 then return '0'; end
    secs = math.floor(secs);
    if secs >= 60 then
        return string.format('%dm %ds', math.floor(secs / 60), secs % 60);
    end
    return string.format('%ds', secs);
end

-- Modern-theme imgui style helpers (shared by cast cost, party windows, and target preview).
-- When Modern Theme is on, windows get this dark-blue rounded panel instead of primitive-textured backgrounds.
local function BeginModernStyle()
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0, 0.06, 0.16, 0.9 });
    imgui.PushStyleColor(ImGuiCol_Border,   { 0.3, 0.3, 0.5, 0.8 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding,  { 10, 6 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 4);
end

local function EndModernStyle()
    imgui.PopStyleVar(2);
    imgui.PopStyleColor(2);
end

-- Live recast remaining for a spell (in seconds; 0 = ready)
local function cc_GetSpellRecast(spellId)
    if spellId == nil or spellId <= 0 then return 0; end
    local recast = AshitaCore:GetMemoryManager():GetRecast();
    if recast == nil then return 0; end
    local timer = recast:GetSpellTimer(spellId);
    if timer == nil or timer <= 0 then return 0; end
    return timer / 60;  -- frames -> seconds
end

-- Live recast remaining for an ability (in seconds; 0 = ready).
-- Scans recast slots 0-31 looking for a matching ability ID.
local function cc_GetAbilityRecast(abilityId)
    if abilityId == nil or abilityId <= 0 then return 0; end
    local recast = AshitaCore:GetMemoryManager():GetRecast();
    if recast == nil then return 0; end
    for i = 0, 31 do
        local id = recast:GetAbilityTimerId(i);
        if id == abilityId then
            local timer = recast:GetAbilityTimer(i);
            if timer and timer > 0 then
                return timer;  -- already in seconds
            end
        end
    end
    return 0;
end

-- ============================================================================

local function getScale(partyIndex)
    if (partyIndex == 3) then
        return {
            x = gConfig.partyList3ScaleX,
            y = gConfig.partyList3ScaleY,
            icon = 1,
        }
    elseif (partyIndex == 2) then
        return {
            x = gConfig.partyList2ScaleX,
            y = gConfig.partyList2ScaleY,
            icon = 1,
        }
    else
        return {
            x = gConfig.partyListScaleX,
            y = gConfig.partyListScaleY,
            icon = 1,
        }
    end
end

local function GetPartyVisualScales()
    local master = gConfig.partyListMasterScale or 1;
    return {
        master = master,
        job = master * (gConfig.partyListJobIconScale or 1),
        buff = master * (gConfig.partyListStatusIconScale or 1),
        cure = master * (gConfig.partyListCureButtonScale or 1),
    };
end

local function showPartyTP(partyIndex)
    if (partyIndex == 3) then
        return gConfig.partyList3TP
    elseif (partyIndex == 2) then
        return gConfig.partyList2TP
    else
        return gConfig.partyListTP
    end
end

local function ShowPartyCureButtons(partyIndex)
    return gConfig.partyListCureButtons == true and partyIndex == 1;
end

local function SuperCompactOverrideEnabled()
    return gConfig.partyListSuperCompactOverride == true;
end

local function GetPartyCureButtonMetrics(settings, partyIndex)
    if not ShowPartyCureButtons(partyIndex) then
        return 0, 0, 0;
    end

    local visualScale = GetPartyVisualScales();
    local btnScale = SuperCompactOverrideEnabled() and 0.90 or 1.15;
    local btnSize = math.max(14, math.floor((settings.iconSize or 16) * visualScale.cure * btnScale));
    local blockWidth = btnSize * 2;
    local blockHeight = SuperCompactOverrideEnabled() and btnSize or (btnSize * 2);
    return btnSize, blockWidth, blockHeight;
end

local function QueuePartyCure(spellName, targetName)
    if (targetName == nil or targetName == '') then
        return;
    end

    local cmd = string.format('/ma "%s" %s', spellName, targetName);
    AshitaCore:GetChatManager():QueueCommand(1, cmd);
end

local debuffCureMap = {
    [3]  = 'Poisona',    -- Poison
    [4]  = 'Paralyna',   -- Paralysis
    [5]  = 'Blindna',    -- Blindness
    [6]  = 'Silena',     -- Silence
    [7]  = 'Stona',      -- Petrification
    [8]  = 'Viruna',     -- Disease
    [9]  = 'Cursna',     -- Curse I
    [20] = 'Cursna',     -- Curse II
};

local function ClickDebuff(buffId, targetName)
    if (targetName == nil or targetName == '') then return; end
    local spell = debuffCureMap[buffId];
    if (spell == nil) then return; end
    AshitaCore:GetChatManager():QueueCommand(1, string.format('/ma "%s" %s', spell, targetName));
end

local function DrawPartyCureButtons(memIdx, memInfo, partyIndex, settings, hpStartX, hpStartY, entryHeight)
    if (not ShowPartyCureButtons(partyIndex) or not memInfo.inzone) then
        return;
    end

    local btnSize, blockWidth, blockHeight = GetPartyCureButtonMetrics(settings, partyIndex);
    if (btnSize <= 0) then
        return;
    end

    local superCompact = SuperCompactOverrideEnabled();
    local scMode = gConfig.partyListSuperCompactMode or 1;

    local extraLeft;
    if (superCompact) then
        if (scMode == 2) then
            extraLeft = math.floor(btnSize * 0.9);
        else
            extraLeft = math.floor(btnSize * 0.85);
        end
    else
        extraLeft = math.floor(btnSize * 1.5);
    end

    local posX = hpStartX - blockWidth - extraLeft;
    local posY = hpStartY + math.floor((entryHeight - blockHeight) / 2);

    imgui.SetNextWindowPos({ posX, posY }, ImGuiCond_Always);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {0, 0});
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {0, 0});
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 0.0);
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, {0, 0});

    if (imgui.Begin('PartyCureButtons' .. memIdx, true, bit.bor(
        ImGuiWindowFlags_NoDecoration,
        ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoBackground,
        ImGuiWindowFlags_NoSavedSettings
    ))) then
        imgui.PushStyleColor(ImGuiCol_Button,        {0.00, 0.00, 0.00, 0.92});
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, {0.12, 0.12, 0.12, 0.96});
        imgui.PushStyleColor(ImGuiCol_ButtonActive,  {0.22, 0.22, 0.22, 1.00});
        imgui.PushStyleColor(ImGuiCol_Text,          {1.00, 1.00, 1.00, 1.00});
        imgui.PushStyleColor(ImGuiCol_Border,        {0.35, 0.35, 0.35, 1.00});

        if (imgui.Button('1##cure1_' .. memIdx, { btnSize, btnSize })) then
            QueuePartyCure('Cure', memInfo.name);
        end
        imgui.SameLine();
        if (imgui.Button('2##cure2_' .. memIdx, { btnSize, btnSize })) then
            QueuePartyCure('Cure II', memInfo.name);
        end

        if (not superCompact) then
            if (imgui.Button('3##cure3_' .. memIdx, { btnSize, btnSize })) then
                QueuePartyCure('Cure III', memInfo.name);
            end
            imgui.SameLine();
            if (imgui.Button('4##cure4_' .. memIdx, { btnSize, btnSize })) then
                QueuePartyCure('Cure IV', memInfo.name);
            end
        end

        imgui.PopStyleColor(5);
    end
    imgui.End();

    imgui.PopStyleVar(4);
end

local function UpdateTextVisibilityByMember(memIdx, visible)
    memberText[memIdx].hp:SetVisible(visible);
    memberText[memIdx].mp:SetVisible(visible);
    memberText[memIdx].tp:SetVisible(visible);
    memberText[memIdx].name:SetVisible(visible);
end

local function UpdateTextVisibility(visible, partyIndex)
    if partyIndex == nil then
        for i = 0, memberTextCount - 1 do
            UpdateTextVisibilityByMember(i, visible);
        end
    else
        local firstPlayerIndex = (partyIndex - 1) * partyMaxSize;
        local lastPlayerIndex = firstPlayerIndex + partyMaxSize - 1;
        for i = firstPlayerIndex, lastPlayerIndex do
            UpdateTextVisibilityByMember(i, visible);
        end
    end

    for i = 1, 3 do
        if (partyIndex == nil or i == partyIndex) then
            partyWindowPrim[i].bgTitle.visible = visible and gConfig.showPartyListTitle;
            local backgroundPrim = partyWindowPrim[i].background;
            for _, k in ipairs(bgImageKeys) do
                backgroundPrim[k].visible = visible and backgroundPrim[k].exists;
            end
        end
    end
end

local function GetMemberInformation(memIdx)
    if (showConfig[1] and gConfig.partyListPreview) then
        local memInfo = {};
        memInfo.hpp = memIdx == 4 and 0.1 or memIdx == 2 and 0.5 or memIdx == 0 and 0.75 or 1;
        memInfo.maxhp = 1250;
        memInfo.hp = math.floor(memInfo.maxhp * memInfo.hpp);
        memInfo.mpp = memIdx == 1 and 0.1 or 0.75;
        memInfo.maxmp = 1000;
        memInfo.mp = math.floor(memInfo.maxmp * memInfo.mpp);
        memInfo.tp = 1500;
        memInfo.job = memIdx + 1;
        memInfo.level = 99;
        memInfo.targeted = memIdx == 4;
        memInfo.serverid = 0;
        memInfo.buffs = {3, 4, 5, 6, 33, 41, 57, 68};  -- 4 debuffs (Poison/Paralysis/Blind/Silence) + 4 buffs
        memInfo.sync = memIdx == 4;  -- Player 5 is synced (preview)
        memInfo.subTargeted = false;
        memInfo.zone = 100;
        memInfo.inzone = memIdx ~= 3;
        memInfo.name = 'Player ' .. (memIdx + 1);
        memInfo.leader = memIdx == 0 or memIdx == 6 or memIdx == 12;
        return memInfo
    end

    local party = AshitaCore:GetMemoryManager():GetParty();
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player == nil or party == nil or party:GetMemberIsActive(memIdx) == 0) then
        return nil;
    end

    local playerTarget = AshitaCore:GetMemoryManager():GetTarget();

    local partyIndex = math.ceil((memIdx + 1) / partyMaxSize);
    local partyLeaderId = nil
    if (partyIndex == 3) then
        partyLeaderId = party:GetAlliancePartyLeaderServerId3();
    elseif (partyIndex == 2) then
        partyLeaderId = party:GetAlliancePartyLeaderServerId2();
    else
        partyLeaderId = party:GetAlliancePartyLeaderServerId1();
    end

    local memberInfo = {};
    memberInfo.zone = party:GetMemberZone(memIdx);
    memberInfo.inzone = memberInfo.zone == party:GetMemberZone(0);
    memberInfo.name = party:GetMemberName(memIdx);
    memberInfo.leader = partyLeaderId == party:GetMemberServerId(memIdx);

    if (memberInfo.inzone == true) then
        memberInfo.hp = party:GetMemberHP(memIdx);
        memberInfo.hpp = party:GetMemberHPPercent(memIdx) / 100;
        memberInfo.maxhp = memberInfo.hp / memberInfo.hpp;
        memberInfo.mp = party:GetMemberMP(memIdx);
        memberInfo.mpp = party:GetMemberMPPercent(memIdx) / 100;
        memberInfo.maxmp = memberInfo.mp / memberInfo.mpp;
        memberInfo.tp = party:GetMemberTP(memIdx);
        memberInfo.job = party:GetMemberMainJob(memIdx);
        memberInfo.level = party:GetMemberMainJobLevel(memIdx);
        memberInfo.serverid = party:GetMemberServerId(memIdx);
        if (playerTarget ~= nil) then
            local t1, t2 = GetTargets();
            local sActive = GetSubTargetActive();
            local thisIdx = party:GetMemberTargetIndex(memIdx);
            memberInfo.targeted = (t1 == thisIdx and not sActive) or (t2 == thisIdx and sActive);
            memberInfo.subTargeted = (t1 == thisIdx and sActive);
        else
            memberInfo.targeted = false;
            memberInfo.subTargeted = false;
        end
        if (memIdx == 0) then
            memberInfo.buffs = player:GetBuffs();
        else
            memberInfo.buffs = statusHandler.get_member_status(memberInfo.serverid);
        end
        memberInfo.sync = bit.band(party:GetMemberFlagMask(memIdx), 0x100) == 0x100;
    else
        memberInfo.hp = 0;
        memberInfo.hpp = 0;
        memberInfo.maxhp = 0;
        memberInfo.mp = 0;
        memberInfo.mpp = 0;
        memberInfo.maxmp = 0;
        memberInfo.tp = 0;
        memberInfo.job = '';
        memberInfo.level = '';
        memberInfo.targeted = false;
        memberInfo.serverid = 0;
        memberInfo.buffs = nil;
        memberInfo.sync = false;
        memberInfo.subTargeted = false;
    end

    return memberInfo;
end

local function DrawMemberBuffs(memIdx, memInfo, partyIndex, settings, hpBarX, hpStartY, mpStartX, mpStartY)
    if (partyIndex ~= 1 or memInfo.buffs == nil or #memInfo.buffs == 0) then
        return;
    end

    local theme            = gConfig.partyListStatusTheme;
    local isStacked        = gConfig.stackedBars;
    local isCompact        = gConfig.partyListSuperCompactOverride == true;
    local superCompact     = SuperCompactOverrideEnabled();
    local superCompactMode = gConfig.partyListSuperCompactMode or 1;

    -- Compact mode forces single-row (mode 1) - 2 rows don't fit compact bar layout
    if (isCompact) then
        superCompactMode = 1;
    end

    local visualScale = GetPartyVisualScales();
    local iconSize    = math.floor(settings.iconSize * visualScale.buff);
    local paddingX    = imgui.GetStyle().WindowPadding.x * 2;
    local winX, _     = imgui.GetWindowPos();

    buffWindowX[memIdx]   = buffWindowX[memIdx] or 0;
    debuffWindowX[memIdx] = debuffWindowX[memIdx] or 0;

    local btnSize, cureBlockWidth, _ = GetPartyCureButtonMetrics(settings, partyIndex);
    local cureExtraLeft = 0;
    if (ShowPartyCureButtons(partyIndex) and btnSize > 0) then
        cureExtraLeft = superCompact and 0 or math.floor(btnSize);
    end
    local LeftOffset = settings.buffOffset + (ShowPartyCureButtons(partyIndex) and (cureBlockWidth + cureExtraLeft) or 0);

    local SpacingX = 3;

    local function SplitBuffs()
        local buffs, debuffs = {}, {};
        for i = 1, #memInfo.buffs do
            local id = memInfo.buffs[i];
            if id ~= nil and id > 0 and id ~= 0xFF then
                if buffTable.IsBuff(id) then table.insert(buffs, id);
                else                          table.insert(debuffs, id); end
            end
        end
        return buffs, debuffs;
    end

    local function DrawDebuffClicks(rowName, debuffs, sz, sx)
        local sx0, sy0 = imgui.GetCursorScreenPos();
        DrawStatusIcons(debuffs, sz, 32, 1, true);
        for i, id in ipairs(debuffs) do
            imgui.SetCursorScreenPos({ sx0 + (i-1)*(sz+sx), sy0 });
            if imgui.InvisibleButton(rowName..'_db_'..memIdx..'_'..i, {sz, sz}) then
                ClickDebuff(id, memInfo.name);
            end
        end
    end

    local function BeginBuffWindow(name, posX, posY)
        imgui.SetNextWindowPos({posX, posY}, ImGuiCond_Always);
        return imgui.Begin(name..memIdx, true, bit.bor(
            ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize,
            ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav,
            ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoSavedSettings
        ));
    end

    -- Icon size: SuperCompact shrinks icons, normal uses full size
    local drawIconSize = superCompact and math.max(6, math.floor(iconSize * 0.6)) or iconSize;

    -- CureX = cure buttons block width (0 if cure buttons are off)
    -- buffOffset = 0 (reserved for future user config)
    -- posX right edge = winX - CureX - buffOffset = winX - LeftOffset
    -- posX left edge  = winX - LeftOffset - actualWindowWidth

    -- Mode 1: single merged row
    if (superCompactMode == 1) then
        local buffs, debuffs = SplitBuffs();
        local row = {};
        for _, id in ipairs(debuffs) do table.insert(row, id); end
        for _, id in ipairs(buffs)   do table.insert(row, id); end
        if #row == 0 then return; end

        local topAlign = superCompact and 0.6 or (isStacked and 0.7 or 1.2);
        local rowY     = hpStartY - math.floor(drawIconSize * topAlign);
        local estW     = #row * drawIconSize + paddingX;
        local posX     = winX - LeftOffset - ((buffWindowX[memIdx] > 0) and buffWindowX[memIdx] or estW);

        if BeginBuffWindow('PlayerStatusM1_', posX, rowY) then
            imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {0, 0});
            local sx0, sy0 = imgui.GetCursorScreenPos();
            DrawStatusIcons(row, drawIconSize, 32, 1, true);
            for i = 1, #debuffs do
                imgui.SetCursorScreenPos({ sx0 + (i-1)*drawIconSize, sy0 });
                if imgui.InvisibleButton('##m1_db_'..memIdx..'_'..i, {drawIconSize, drawIconSize}) then
                    ClickDebuff(debuffs[i], memInfo.name);
                end
            end
            imgui.PopStyleVar(1);
        end
        local bwx, _ = imgui.GetWindowSize(); buffWindowX[memIdx] = bwx;
        imgui.End();
        return;
    end

    -- Mode 2: two rows, buffs on top / debuffs below
    if (superCompactMode == 2) then
        local buffs, debuffs = SplitBuffs();
        if (isStacked) then drawIconSize = math.max(6, math.floor(drawIconSize * 0.8)); end
        local topAlign = isStacked and 0.7 or 1.2;
        local topY     = hpStartY - math.floor(drawIconSize * topAlign);
        local botY     = topY + drawIconSize;
        local debuffXOffset = isStacked and math.floor(drawIconSize * 0.5) or 0;

        if #buffs > 0 then
            local estW = #buffs * (drawIconSize + SpacingX) + paddingX;
            local posX = winX - LeftOffset - ((buffWindowX[memIdx] > 0) and buffWindowX[memIdx] or estW);
            if BeginBuffWindow('PlayerBuffsM2_', posX, topY) then
                imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {SpacingX, 0});
                DrawStatusIcons(buffs, drawIconSize, 32, 1, true);
                imgui.PopStyleVar(1);
            end
            local bwx, _ = imgui.GetWindowSize(); buffWindowX[memIdx] = bwx;
            imgui.End();
        end
        if #debuffs > 0 then
            local estW = #debuffs * (drawIconSize + SpacingX) + paddingX;
            local posX = winX - LeftOffset - debuffXOffset - ((debuffWindowX[memIdx] > 0) and debuffWindowX[memIdx] or estW);
            if BeginBuffWindow('PlayerDebuffsM2_', posX, botY) then
                imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {SpacingX, 0});
                DrawDebuffClicks('m2', debuffs, drawIconSize, SpacingX);
                imgui.PopStyleVar(1);
            end
            local dwx, _ = imgui.GetWindowSize(); debuffWindowX[memIdx] = dwx;
            imgui.End();
        end
        return;
    end

    -- Theme 4: disabled
    if (theme == 4) then return; end

    -- Themes 0 & 1: 2 rows (buffs on top, debuffs below), left or right of window.
    -- Stacked vs non-stacked only changes the Y anchor fraction; draw logic is identical.
    if (theme == 0 or theme == 1) then
        local buffs, debuffs = SplitBuffs();

        local topAlign = isStacked and 0.7 or 1.2;
        local topY = hpStartY - math.floor(iconSize * topAlign);
        local botY = topY + iconSize;

        if #buffs > 0 then
            local bw   = (buffWindowX[memIdx] > 0) and buffWindowX[memIdx] or (#buffs * iconSize + paddingX);
            local posX = (theme == 0) and (winX - bw - LeftOffset) or (winX + (fullMenuWidth[partyIndex] or 0));
            if BeginBuffWindow('PlayerBuffs01_', posX, topY) then
                imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {SpacingX, 0});
                DrawStatusIcons(buffs, iconSize, 32, 1, true);
                imgui.PopStyleVar(1);
            end
            local bwx, _ = imgui.GetWindowSize(); buffWindowX[memIdx] = bwx;
            imgui.End();
        end

        if #debuffs > 0 then
            local dw   = (debuffWindowX[memIdx] > 0) and debuffWindowX[memIdx] or (#debuffs * iconSize + paddingX);
            local posX = (theme == 0) and (winX - dw - LeftOffset) or (winX + (fullMenuWidth[partyIndex] or 0));
            if BeginBuffWindow('PlayerDebuffs01_', posX, botY) then
                imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {SpacingX, 0});
                DrawDebuffClicks('t01', debuffs, iconSize, SpacingX);
                imgui.PopStyleVar(1);
            end
            local dwx, _ = imgui.GetWindowSize(); debuffWindowX[memIdx] = dwx;
            imgui.End();
        end
        return;
    end

    -- Theme 2: XIV 1.0 - single row above MP bar
    if (theme == 2) then
        local resetX, resetY = imgui.GetCursorScreenPos();
        imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {0, 0});
        imgui.SetNextWindowPos({mpStartX, mpStartY - iconSize - settings.xivBuffOffsetY}, ImGuiCond_Always);
        if imgui.Begin('XIVStatus2_'..memIdx, true, bit.bor(
            ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize,
            ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav,
            ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoSavedSettings
        )) then
            imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {0, 0});
            DrawStatusIcons(memInfo.buffs, iconSize, 32, 1);
            imgui.PopStyleVar(1);
        end
        imgui.PopStyleVar(1);
        imgui.End();
        imgui.SetCursorScreenPos({resetX, resetY});
        return;
    end

    -- Theme 3: grid (7 cols x 3 rows)
    if (theme == 3) then
        local posX = winX - buffWindowX[memIdx] - LeftOffset;
        local posY = memberText[memIdx].name:GetPositionY() - iconSize / 2;
        imgui.SetNextWindowPos({posX, posY}, ImGuiCond_Always);
        if imgui.Begin('PlayerBuffs3_'..memIdx, true, bit.bor(
            ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize,
            ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav,
            ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoSavedSettings
        )) then
            imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {0, 3});
            DrawStatusIcons(memInfo.buffs, iconSize, 7, 3);
            imgui.PopStyleVar(1);
        end
        local bwx, _ = imgui.GetWindowSize(); buffWindowX[memIdx] = bwx;
        imgui.End();
        return;
    end
end

-- Returns (hasTreasure, hasTrade) for the local player.
-- hasTreasure is driven by treasurePoolActive, which is set/cleared by
-- partyList.HandleIncomingPacket (wire that up in the main hxui.lua).
-- hasTrade uses entity action-status as a best-effort check.
local function GetPlayerStatusIcons()
    -- Preview: treasure pool active so the top-of-party gold dot renders.
    -- Trade is shown in real play only (via entity status 4).
    if (showConfig and showConfig[1] and gConfig.partyListPreview) then
        return true, false;
    end

    -- Re-check actual treasure pool memory every frame instead of trusting the cached
    -- treasurePoolActive flag (packets can be missed; lots/passes don't always emit 0xD3).
    local hasTreasure = false;
    pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory();
        if inv == nil then return; end
        for slot = 0, 9 do
            local item = inv:GetTreasurePoolItem(slot);
            if item ~= nil and item.ItemId and item.ItemId > 0 and item.ItemId ~= 65535 then
                hasTreasure = true;
                return;
            end
        end
    end);
    treasurePoolActive = hasTreasure;  -- keep cache in sync

    local hasTrade = false;
    pcall(function()
        local ent = AshitaCore:GetMemoryManager():GetEntity();
        if ent ~= nil then
            -- Entity action status 4 may indicate a trade/event menu is open.
            -- Verify and adjust the value if it doesn't trigger correctly on your server.
            local st = ent:GetStatus(0);
            hasTrade = (st ~= nil and st == 4);
        end
    end);

    return hasTreasure, hasTrade;
end

local function DrawMember(memIdx, settings)
    local memInfo = GetMemberInformation(memIdx);
    if (memInfo == nil) then
        memInfo = {};
        memInfo.hp = 0; memInfo.hpp = 0; memInfo.maxhp = 0;
        memInfo.mp = 0; memInfo.mpp = 0; memInfo.maxmp = 0;
        memInfo.tp = 0; memInfo.job = ''; memInfo.level = '';
        memInfo.targeted = false; memInfo.serverid = 0; memInfo.buffs = nil;
        memInfo.sync = false; memInfo.subTargeted = false;
        memInfo.zone = ''; memInfo.inzone = false;
        memInfo.name = ''; memInfo.leader = false;
    end

    local partyIndex = math.ceil((memIdx + 1) / partyMaxSize);
    local scale      = getScale(partyIndex);
    local showTP     = showPartyTP(partyIndex);
    local compact    = gConfig.compactPartyList == true;
    local stacked    = gConfig.stackedBars == true;
    local superCompact = SuperCompactOverrideEnabled();

    local subTargetActive = GetSubTargetActive();
    local nameSize = SIZE.new();
    local hpSize   = SIZE.new();
    memberText[memIdx].name:GetTextSize(nameSize);
    memberText[memIdx].hp:GetTextSize(hpSize);

    local hpNameColor, hpGradient = GetHpColors(memInfo.hpp);
    local bgGradientOverride = {'#000813', '#000813'};

    local hpBarWidth = settings.hpBarWidth * scale.x;
    local mpBarWidth = settings.mpBarWidth * scale.x;
    local tpBarWidth = settings.tpBarWidth * scale.x;
    local barHeight  = settings.barHeight * scale.y;

    if (superCompact) then
        barHeight = math.max(7, math.floor(barHeight * 0.62));
    elseif (compact and not stacked) then
        local barScale = gConfig.compactBarScale or 0.55;
        hpBarWidth = math.floor(hpBarWidth * barScale);
        mpBarWidth = math.floor(mpBarWidth * barScale);
        tpBarWidth = math.floor(tpBarWidth * barScale);
    end

    local compactBorderConfig = superCompact and { 1, '#243e58' } or borderConfig;
    local hpStartX, hpStartY = imgui.GetCursorScreenPos();

    if (stacked) then
        -- Stacked layout draws all text via imgui.TextColored (see outlined() below),
        -- which uses the default imgui font and therefore ignores the per-party font
        -- offset we apply to memberText[*] primitives via SetFontHeight. Scale the
        -- current window's imgui font so the offset is reflected here too, and so
        -- imgui.CalcTextSize returns matching widths for positioning.
        local fontOffset = gConfig.partyListFontOffset;
        if (partyIndex == 2) then
            fontOffset = gConfig.partyList2FontOffset;
        elseif (partyIndex == 3) then
            fontOffset = gConfig.partyList3FontOffset;
        end
        local baseFontH    = settings.hp_font_settings.font_height;
        local stackedScale = (baseFontH > 0) and ((baseFontH + (fontOffset or 0)) / baseFontH) or 1;
        if (stackedScale <= 0) then stackedScale = 1; end
        imgui.SetWindowFontScale(stackedScale);

        local barGap         = -3;
        local hpBarDrawWidth = math.floor(hpBarWidth * 0.80);
        local mpBarDrawWidth = math.floor(hpBarDrawWidth * 0.75);

        local visualScale = GetPartyVisualScales();
        local jobIconSize = settings.iconSize * 1.1 * visualScale.job;
        if (superCompact) then
            jobIconSize = math.max(10, math.floor(jobIconSize * 1));
        end
        local jobIcon = statusHandler.GetJobIcon(memInfo.job);

        local iconOffset = superCompact and 6 or settings.nameTextOffsetX;
        local barStartX  = hpStartX + jobIconSize + iconOffset;
        local totalBarsH = barHeight * 2 + barGap;
        if (jobIcon ~= nil) then
            local iconY = hpStartY + math.floor((totalBarsH - jobIconSize) / 2);
            imgui.SetCursorScreenPos({hpStartX, iconY});
            imgui.Image(jobIcon, {jobIconSize, jobIconSize});
        end

        -- outlined and textH shared by both inzone and out-of-zone paths
        local function outlined(x, y, color, text)
            imgui.SetCursorScreenPos({x - 2, y - 2}); imgui.TextColored({0, 0, 0, 1}, text);
            imgui.SetCursorScreenPos({x + 2, y - 2}); imgui.TextColored({0, 0, 0, 1}, text);
            imgui.SetCursorScreenPos({x - 2, y + 2}); imgui.TextColored({0, 0, 0, 1}, text);
            imgui.SetCursorScreenPos({x + 2, y + 2}); imgui.TextColored({0, 0, 0, 1}, text);
            imgui.SetCursorScreenPos({x - 2, y});     imgui.TextColored({0, 0, 0, 1}, text);
            imgui.SetCursorScreenPos({x + 2, y});     imgui.TextColored({0, 0, 0, 1}, text);
            imgui.SetCursorScreenPos({x, y - 2});     imgui.TextColored({0, 0, 0, 1}, text);
            imgui.SetCursorScreenPos({x, y + 2});     imgui.TextColored({0, 0, 0, 1}, text);
            imgui.SetCursorScreenPos({x, y});         imgui.TextColored(color, text);
        end
        local white  = {1, 1, 1, 1};
        local _, textH = imgui.CalcTextSize(superCompact and '.' or 'A');

        if (memInfo.inzone) then
            imgui.SetCursorScreenPos({barStartX, hpStartY});
            local hpBarX, hpBarY = imgui.GetCursorScreenPos();
            progressbar.ProgressBar(
                {{memInfo.hpp, hpGradient}}, {hpBarDrawWidth, barHeight},
                {borderConfig=compactBorderConfig, backgroundGradientOverride=bgGradientOverride,
                 decorate=gConfig.showPartyListBookends});

            local mpBarX = barStartX + (hpBarDrawWidth - mpBarDrawWidth);
            local mpBarY = hpBarY + barHeight + barGap;
            imgui.SetCursorScreenPos({mpBarX, mpBarY});
            local mpStartX, mpStartY = mpBarX, mpBarY;
            progressbar.ProgressBar(
                {{memInfo.mpp, {'#9abb5a', '#bfe07d'}}}, {mpBarDrawWidth, barHeight},
                {borderConfig=compactBorderConfig, backgroundGradientOverride=bgGradientOverride,
                 decorate=gConfig.showPartyListBookends});

            local hpTextY  = hpBarY + math.floor((barHeight - textH) / 2);
            local mpTextY  = mpBarY + math.floor((barHeight - textH) / 2);

            local rawName = tostring(memInfo.name);
            local nameStr = (#rawName > 10) and (string.sub(rawName, 1, 8) .. '..') or rawName;
            outlined(hpStartX, hpBarY - math.floor(textH / 2), white, nameStr);

            local hpStr  = tostring(memInfo.hp);
            local hpTW,_ = imgui.CalcTextSize(hpStr);
            local hpNumColor = memInfo.hpp >= 0.75 and white
                            or memInfo.hpp >= 0.50 and {1.0, 0.9, 0.2, 1.0}
                            or {1.0, 0.3, 0.3, 1.0};
            outlined(hpBarX + hpBarDrawWidth - hpTW - settings.dotRadius - 2, hpTextY, hpNumColor, hpStr);

            local mpStr  = tostring(memInfo.mp);
            local mpTW,_ = imgui.CalcTextSize(mpStr);
            outlined(mpBarX + mpBarDrawWidth - mpTW - settings.dotRadius - 2, mpTextY, white, mpStr);

            if (showTP) then
                local tpStr      = tostring(memInfo.tp);
                local tpTW, tpTH = imgui.CalcTextSize(tpStr);
                local tpColor    = memInfo.tp >= 1000 and {0.3, 1.0, 0.3, 1.0} or {0.7, 0.7, 0.7, 1.0};
                local tpX = barStartX + math.floor(((mpBarX - barStartX) - tpTW) / 2);
                local tpY        = mpBarY + math.floor((barHeight - tpTH) / 2);
                outlined(tpX, tpY, tpColor, tpStr);
            end

            memberText[memIdx].name:SetVisible(false);
            memberText[memIdx].hp:SetVisible(false);
            memberText[memIdx].mp:SetVisible(false);
            memberText[memIdx].tp:SetVisible(false);

            local totalBarsH = barHeight * 2 + barGap;

            -- Draw buffs first so cure button window renders on top
            DrawMemberBuffs(memIdx, memInfo, partyIndex, settings, hpStartX, hpStartY, mpStartX, mpStartY);

            DrawPartyCureButtons(memIdx, memInfo, partyIndex, settings, hpStartX, hpBarY, totalBarsH)

            local fullWidth   = (barStartX - hpStartX) + hpBarDrawWidth;
            if (superCompact) then
                fullWidth = fullWidth - 10;
            end
            local entrySize   = totalBarsH + settings.cursorPaddingY1 + settings.cursorPaddingY2;
            if (memInfo.targeted == true) then
                selectionPrim.visible    = true;
                selectionPrim.position_x = hpStartX - settings.cursorPaddingX1;
                selectionPrim.position_y = hpBarY   - settings.cursorPaddingY1;
                selectionPrim.scale_x    = (fullWidth + settings.cursorPaddingX1 + settings.cursorPaddingX2) / 346;
                selectionPrim.scale_y    = entrySize / 108;
                partyTargeted = true;
            end

            if ((memInfo.targeted == true and not subTargetActive) or memInfo.subTargeted) then
                arrowPrim.visible    = true;
                arrowPrim.position_x = hpStartX - arrowPrim:GetWidth() - 2;
                arrowPrim.position_y = hpBarY + math.floor(totalBarsH / 2) - arrowPrim:GetHeight() / 2;
                arrowPrim.scale_x    = settings.arrowSize;
                arrowPrim.scale_y    = settings.arrowSize;
                arrowPrim.color      = subTargetActive and settings.subtargetArrowTint or 0xFFFFFFFF;
                partySubTargeted = true;

                -- Modern theme: primitive arrow renders below imgui windows. Draw on foreground.
                if gConfig.modernTheme then
                    local arrowH    = 12;
                    local arrowW    = 10;
                    local arrowEndX = hpStartX - 4;
                    local arrowCY   = hpBarY + math.floor(totalBarsH / 2);
                    local col       = subTargetActive and imgui.GetColorU32({ 0.99, 0.82, 0.09, 1.0 })
                                                       or imgui.GetColorU32({ 1.00, 1.00, 1.00, 1.0 });
                    imgui.GetForegroundDrawList():AddTriangleFilled(
                        { arrowEndX - arrowW, arrowCY - arrowH / 2 },
                        { arrowEndX - arrowW, arrowCY + arrowH / 2 },
                        { arrowEndX,          arrowCY              },
                        col);
                end
            end

            -- Leader dot (yellow) to LEFT of job icon, Sync dot (red) at RIGHT edge of member row.
            -- Drawn AFTER the arrow so dots render on top of targeting arrow/selector.
            if (memInfo.leader or memInfo.sync) then
                local dotR        = settings.dotRadius;
                local iconLeftX   = hpStartX;
                local rowRightX   = hpStartX + (hpBarX - hpStartX) + hpBarDrawWidth;
                local iconCenterY = hpStartY + math.floor((totalBarsH - jobIconSize) / 2) + math.floor(jobIconSize / 2);

                local fgList = imgui.GetForegroundDrawList();
                if (memInfo.leader) then
                    fgList:AddCircleFilled({ iconLeftX - dotR - 2, iconCenterY }, dotR,
                        imgui.GetColorU32({1.00, 0.92, 0.20, 1.0}), dotR * 3);
                end
                if (memInfo.sync) then
                    fgList:AddCircleFilled({ rowRightX + dotR + 2, iconCenterY }, dotR,
                        imgui.GetColorU32({1.00, 0.25, 0.25, 1.0}), dotR * 3);
                end
            end

            imgui.SetCursorScreenPos({hpStartX, hpBarY});
            local entryW = (hpBarX - hpStartX) + hpBarDrawWidth;
            if (imgui.GetIO().KeyShift) then
                imgui.Dummy({entryW, totalBarsH});
            else
                imgui.InvisibleButton('##target_' .. memIdx, {entryW, totalBarsH});
                if (imgui.IsItemClicked(0) and memInfo.name ~= '') then
                    -- Click-to-target. /target works only when the player
                    -- is not engaged - FFXI blocks main-target changes
                    -- to allies mid-combat. Attempts to set sub-target
                    -- via direct memory writes or FFI-calling the game's
                    -- SetTarget function have either crashed the client
                    -- or caused sub-target to resync to the main target.
                    -- Leaving this as a plain /target until we understand
                    -- the target state machine better.
                    AshitaCore:GetChatManager():QueueCommand(1, '/target ' .. memInfo.name);
                end
            end

            local memberH    = totalBarsH;
            local fullWidthW = (barStartX - hpStartX) + hpBarDrawWidth;
            if (superCompact) then
                fullWidthW = fullWidthW - 10;
            end
            imgui.SetCursorScreenPos({hpStartX, hpBarY + memberH});
            if (superCompact) then
                imgui.Dummy({fullWidthW, -4});
            else
                imgui.Dummy({fullWidthW, math.max(-2, math.floor(settings.entrySpacing[partyIndex] * 0.125))});
            end
        else
            memberText[memIdx].name:SetVisible(false);
            memberText[memIdx].hp:SetVisible(false);
            memberText[memIdx].mp:SetVisible(false);
            memberText[memIdx].tp:SetVisible(false);
            imgui.SetCursorScreenPos({hpStartX, hpStartY});
            local barW = barStartX - hpStartX + hpBarDrawWidth;
            if (memInfo.zone == '' or memInfo.zone == nil) then
                imgui.Dummy({barW, totalBarsH});
            else
                local zoneName = encoding:ShiftJIS_To_UTF8(AshitaCore:GetResourceManager():GetString("zones.names", memInfo.zone), true);
                -- Truncate zone name if it would overflow the bar
                local zoneW, _ = imgui.CalcTextSize(zoneName);
                if zoneW > barW - 10 then
                    while #zoneName > 0 and zoneW > barW - 10 do
                        zoneName = zoneName:sub(1, -2);
                        zoneW, _ = imgui.CalcTextSize(zoneName .. '..');
                    end
                    zoneName = zoneName .. '..';
                end
                imgui.ProgressBar(0, {barW, totalBarsH}, zoneName);
            end
            -- Draw name AFTER the bar so it renders on top
            local rawName = tostring(memInfo.name);
            local nameStr = (#rawName > 10) and (string.sub(rawName, 1, 8) .. '..') or rawName;
            outlined(hpStartX, hpStartY - math.floor(textH / 2), white, nameStr);

            -- Leader / Sync dots for out-of-zone members.
            -- Center on the bar's middle (no job icon to anchor to in this branch).
            if (memInfo.leader or memInfo.sync) then
                local dotR        = settings.dotRadius;
                local iconLeftX   = hpStartX;
                local rowRightX   = hpStartX + barW;
                local iconCenterY = hpStartY + math.floor(totalBarsH / 2);

                local fgList = imgui.GetForegroundDrawList();
                if (memInfo.leader) then
                    fgList:AddCircleFilled({ iconLeftX - dotR - 2, iconCenterY }, dotR,
                        imgui.GetColorU32({1.00, 0.92, 0.20, 1.0}), dotR * 3);
                end
                if (memInfo.sync) then
                    fgList:AddCircleFilled({ rowRightX + dotR + 2, iconCenterY }, dotR,
                        imgui.GetColorU32({1.00, 0.25, 0.25, 1.0}), dotR * 3);
                end
            end

            -- Reset cursor to end of bar so spacing Dummies are placed correctly
            imgui.SetCursorScreenPos({hpStartX, hpStartY + totalBarsH});
            if (superCompact) then
                local compactSpacing = math.max(-2, math.floor(settings.entrySpacing[partyIndex] * 0.125));
                imgui.Dummy({0, compactSpacing});
            else
                imgui.Dummy({0, math.max(-2, math.floor(settings.entrySpacing[partyIndex] * 0.125))});
            end
        end

        local lastPlayerIndex = (partyIndex * 6) - 1;
        if (memIdx + 1 <= lastPlayerIndex) then
            if (superCompact) then
                imgui.Dummy({0, -4});
            else
                imgui.Dummy({0, math.max(-2, math.floor(settings.entrySpacing[partyIndex] * 0.125))});
            end
        end
        imgui.SetWindowFontScale(1.0);
        return;
    end

    local allBarsLengths = hpBarWidth + mpBarWidth + imgui.GetStyle().FramePadding.x + imgui.GetStyle().ItemSpacing.x;
    if (showTP) then
        allBarsLengths = allBarsLengths + tpBarWidth + imgui.GetStyle().FramePadding.x + imgui.GetStyle().ItemSpacing.x;
    end

    local namePosX = hpStartX;
    local visualScale = GetPartyVisualScales();
    local jobIconSize = settings.iconSize * 1.1 * visualScale.job;
    if (superCompact) then
        jobIconSize = math.max(10, math.floor(jobIconSize * 0.25));
    end
    local jobIcon = statusHandler.GetJobIcon(memInfo.job);
    imgui.SetCursorScreenPos({namePosX, hpStartY - jobIconSize - settings.nameTextOffsetY});
    if (jobIcon ~= nil) then
        namePosX = namePosX + jobIconSize + settings.nameTextOffsetX;
        imgui.Image(jobIcon, {jobIconSize, jobIconSize});
    end
    imgui.SetCursorScreenPos({hpStartX, hpStartY});

    memberText[memIdx].hp:SetColor(hpNameColor);
    memberText[memIdx].hp:SetPositionX(hpStartX + hpBarWidth + settings.hpTextOffsetX);
    memberText[memIdx].hp:SetPositionY(hpStartY + barHeight + settings.hpTextOffsetY);
    memberText[memIdx].hp:SetText(tostring(memInfo.hp));

    if (memInfo.inzone) then
        progressbar.ProgressBar({{memInfo.hpp, hpGradient}}, {hpBarWidth, barHeight},
            {borderConfig=compactBorderConfig, backgroundGradientOverride=bgGradientOverride,
             decorate=gConfig.showPartyListBookends});
    elseif (memInfo.zone == '' or memInfo.zone == nil) then
        imgui.Dummy({allBarsLengths, barHeight});
    else
        imgui.ProgressBar(0, {allBarsLengths, barHeight},
            encoding:ShiftJIS_To_UTF8(AshitaCore:GetResourceManager():GetString("zones.names", memInfo.zone), true));
    end

    memberText[memIdx].name:SetColor(0xFFFFFFFF);
    memberText[memIdx].name:SetPositionX(namePosX);
    memberText[memIdx].name:SetPositionY(hpStartY - nameSize.cy - settings.nameTextOffsetY);
    memberText[memIdx].name:SetText(tostring(memInfo.name));

    memberText[memIdx].name:GetTextSize(nameSize);
    local offsetSize = nameSize.cy > settings.iconSize and nameSize.cy or settings.iconSize;

    if (memInfo.inzone) then
        imgui.SameLine();

        local mpStartX, mpStartY;
        imgui.SetCursorPosX(imgui.GetCursorPosX());
        mpStartX, mpStartY = imgui.GetCursorScreenPos();
        progressbar.ProgressBar({{memInfo.mpp, {'#9abb5a', '#bfe07d'}}}, {mpBarWidth, barHeight},
            {borderConfig=compactBorderConfig, backgroundGradientOverride=bgGradientOverride,
             decorate=gConfig.showPartyListBookends});

        memberText[memIdx].mp:SetColor(gAdjustedSettings.mpColor);
        memberText[memIdx].mp:SetPositionX(mpStartX + mpBarWidth + settings.mpTextOffsetX);
        memberText[memIdx].mp:SetPositionY(mpStartY + barHeight + settings.mpTextOffsetY);
        memberText[memIdx].mp:SetText(tostring(memInfo.mp));

        if (showTP) then
            imgui.SameLine();
            local tpStartX, tpStartY;
            imgui.SetCursorPosX(imgui.GetCursorPosX());
            tpStartX, tpStartY = imgui.GetCursorScreenPos();

            local tpGradient = memInfo.tp >= 1000 and {'#22cc22', '#44ee44'} or {'#3898ce', '#78c4ee'};
            local tpOverlayGradient = {'#00aa00', '#00aa00'};
            local mainPercent;
            local tpOverlay;
            if (memInfo.tp >= 1000) then
                mainPercent = (memInfo.tp - 1000) / 2000;
                tpOverlay = {{1, tpOverlayGradient}, math.ceil(barHeight * 2 / 7), 1};
            else
                mainPercent = memInfo.tp / 1000;
            end
            progressbar.ProgressBar({{mainPercent, tpGradient}}, {tpBarWidth, barHeight},
                {overlayBar=tpOverlay, borderConfig=compactBorderConfig,
                 backgroundGradientOverride=bgGradientOverride, decorate=gConfig.showPartyListBookends});

            memberText[memIdx].tp:SetColor(
                memInfo.tp >= 1000 and gAdjustedSettings.tpFullColor or gAdjustedSettings.tpEmptyColor);
            memberText[memIdx].tp:SetPositionX(tpStartX + tpBarWidth + settings.tpTextOffsetX);
            memberText[memIdx].tp:SetPositionY(tpStartY + barHeight + settings.tpTextOffsetY);
            memberText[memIdx].tp:SetText(tostring(memInfo.tp));
        end

        local entrySize = hpSize.cy + offsetSize + settings.hpTextOffsetY + barHeight + settings.cursorPaddingY1 + settings.cursorPaddingY2;
        local entryHeight = hpSize.cy + offsetSize + settings.hpTextOffsetY + barHeight;

        -- Draw buffs first so cure button window renders on top
        DrawMemberBuffs(memIdx, memInfo, partyIndex, settings, hpStartX, hpStartY, mpStartX, mpStartY);

        DrawPartyCureButtons(memIdx, memInfo, partyIndex, settings, hpStartX, hpStartY - offsetSize, entryHeight)

        if (memInfo.targeted == true) then
            selectionPrim.visible    = true;
            selectionPrim.position_x = hpStartX - settings.cursorPaddingX1;
            selectionPrim.position_y = hpStartY - offsetSize - settings.cursorPaddingY1;
            selectionPrim.scale_x    = (allBarsLengths + settings.cursorPaddingX1 + settings.cursorPaddingX2) / 346;
            selectionPrim.scale_y    = entrySize / 108;
            partyTargeted = true;
        end

        if ((memInfo.targeted == true and not subTargetActive) or memInfo.subTargeted) then
            arrowPrim.visible = true;
            local newArrowX = memberText[memIdx].name:GetPositionX() - arrowPrim:GetWidth();
            if (jobIcon ~= nil) then newArrowX = newArrowX - jobIconSize; end
            arrowPrim.position_x = newArrowX;
            arrowPrim.position_y = (hpStartY - offsetSize - settings.cursorPaddingY1) + (entrySize / 2) - arrowPrim:GetHeight() / 2;
            arrowPrim.scale_x = settings.arrowSize;
            arrowPrim.scale_y = settings.arrowSize;
            arrowPrim.color   = subTargetActive and settings.subtargetArrowTint or 0xFFFFFFFF;
            partySubTargeted = true;

            -- Modern theme: primitive arrow renders below imgui windows. Draw on foreground.
            if gConfig.modernTheme then
                local arrowH    = 12;
                local arrowW    = 10;
                local arrowEndX = hpStartX - 4;
                local arrowCY   = (hpStartY - offsetSize - settings.cursorPaddingY1) + (entrySize / 2);
                local col       = subTargetActive and imgui.GetColorU32({ 0.99, 0.82, 0.09, 1.0 })
                                                   or imgui.GetColorU32({ 1.00, 1.00, 1.00, 1.0 });
                imgui.GetForegroundDrawList():AddTriangleFilled(
                    { arrowEndX - arrowW, arrowCY - arrowH / 2 },
                    { arrowEndX - arrowW, arrowCY + arrowH / 2 },
                    { arrowEndX,          arrowCY              },
                    col);
            end
        end
    end

    if (memInfo.sync) then
        -- sync dot now drawn beside name above, not here
    end

    -- Leader dot (yellow) to LEFT of job icon, Sync dot (red) at RIGHT edge of member row.
    -- Drawn AFTER the arrow so dots render on top of targeting arrow/selector.
    if (memInfo.leader or memInfo.sync) then
        local dotR        = settings.dotRadius;
        local iconLeftX   = hpStartX;
        local rowRightX   = hpStartX + allBarsLengths;
        -- For in-zone members the job icon sits above the bar - center dot on the icon.
        -- For out-of-zone members no icon is drawn, so center dot on the bar's vertical middle
        -- (otherwise the dot floats above the row in dead space and looks missing).
        local iconCenterY;
        if (jobIcon ~= nil) then
            iconCenterY = (hpStartY - jobIconSize - settings.nameTextOffsetY) + math.floor(jobIconSize / 2);
        else
            iconCenterY = hpStartY + math.floor(barHeight / 2);
        end

        -- TEMP DEBUG: print once per second to confirm path reached for out-of-zone leader
        if not memInfo.inzone and memInfo.leader then
            local now = os.clock();
            _G.__hxui_dotdbg = _G.__hxui_dotdbg or 0;
            if now - _G.__hxui_dotdbg > 1 then
                _G.__hxui_dotdbg = now;
                print(string.format('[dotdbg] OOZ leader %s: hpStartX=%d iconCenterY=%d barHeight=%d jobIcon=%s',
                    tostring(memInfo.name), math.floor(hpStartX), math.floor(iconCenterY),
                    math.floor(barHeight), tostring(jobIcon)));
            end
        end

        local fgList = imgui.GetForegroundDrawList();
        if (memInfo.leader) then
            fgList:AddCircleFilled({ iconLeftX - dotR - 2, iconCenterY }, dotR,
                imgui.GetColorU32({1.00, 0.92, 0.20, 1.0}), dotR * 3);
        end
        if (memInfo.sync) then
            fgList:AddCircleFilled({ rowRightX + dotR + 2, iconCenterY }, dotR,
                imgui.GetColorU32({1.00, 0.25, 0.25, 1.0}), dotR * 3);
        end
    end

    memberText[memIdx].hp:SetVisible(memInfo.inzone and not compact);
    memberText[memIdx].mp:SetVisible(memInfo.inzone and not compact);
    memberText[memIdx].tp:SetVisible(memInfo.inzone and showTP and not compact);
    memberText[memIdx].name:SetVisible(true);

    if (superCompact) then
        local compactSpacing = math.max(-2, math.floor(settings.entrySpacing[partyIndex] * 0.25));
        imgui.Dummy({0, compactSpacing});
    elseif (memInfo.inzone) then
        imgui.Dummy({0, settings.entrySpacing[partyIndex] + hpSize.cy + settings.hpTextOffsetY + settings.nameTextOffsetY});
    else
        imgui.Dummy({0, settings.entrySpacing[partyIndex] + hpSize.cy + settings.hpTextOffsetY + settings.nameTextOffsetY});
    end

    local lastPlayerIndex = (partyIndex * 6) - 1;
    if (memIdx + 1 <= lastPlayerIndex) then
        if (superCompact) then
            local compactSpacing = math.max(-2, math.floor(settings.entrySpacing[partyIndex] * 0.25));
            imgui.Dummy({0, compactSpacing});
        else
            imgui.Dummy({0, offsetSize});
        end
    end
end

local function DrawCurrentTarget(settings)
    if targetText.name ~= nil then targetText.name:SetVisible(false); end
    if targetText.hp   ~= nil then targetText.hp:SetVisible(false);   end

    for _, k in ipairs(bgImageKeys) do
        partyWindowPrim[4].background[k].visible = false;
    end

    if (SuperCompactOverrideEnabled()) then
        return;
    end

    local function hideBg()
        for _, k in ipairs(bgImageKeys) do
            partyWindowPrim[4].background[k].visible = false;
        end
    end

    if (showConfig[1] and gConfig.partyListPreview) then
        -- Show a fake self-target in preview so the target window is visible
        local scale     = getScale(1);
        local barHeight = settings.barHeight * scale.y;
        local padding   = 4;
        local winW      = (fullMenuWidth[1] or (settings.hpBarWidth * scale.x + padding * 2));
        local isModernPrev = gConfig.modernTheme;
        local modernExtra  = isModernPrev and 12 or 0;
        local barWidth  = winW - padding * 2 - modernExtra;
        local _, hpGrad = GetHpColors(0.75);
        local bgGrad    = {'#000813', '#000813'};

        local titleOverhang = 0;
        local partyTitlePrim = partyWindowPrim[1] and partyWindowPrim[1].bgTitle or nil;
        if (partyTitlePrim ~= nil and gConfig.showPartyListTitle) then
            titleOverhang = math.floor((partyTitlePrim.height * partyTitlePrim.scale_y / 2) + (2 / partyTitlePrim.scale_y));
        end
        local anchorX = partyList1Pos.x;
        local anchorY = partyList1Pos.y - titleOverhang - 10 - 40;

        imgui.SetNextWindowPos({anchorX, anchorY}, ImGuiCond_Always);
        imgui.SetNextWindowSize({winW, 0}, ImGuiCond_Always);
        imgui.PushStyleVar(ImGuiStyleVar_FramePadding,  {0, 0});
        imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing,   {settings.barSpacing * scale.x, 0});
        imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {padding, 3});

        if isModernPrev then BeginModernStyle(); end

        local wX, wY, wW, wH = anchorX, anchorY, winW, 0;
        local wflags = bit.bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_NoFocusOnAppearing,
            ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoMove,
            ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse,
            ImGuiWindowFlags_NoBringToFrontOnFocus);
        if not isModernPrev then
            wflags = bit.bor(wflags, ImGuiWindowFlags_NoBackground);
        end

        local function outlined(x, y, col, text)
            imgui.SetCursorScreenPos({x-1,y}); imgui.TextColored({0,0,0,1}, text);
            imgui.SetCursorScreenPos({x+1,y}); imgui.TextColored({0,0,0,1}, text);
            imgui.SetCursorScreenPos({x,y-1}); imgui.TextColored({0,0,0,1}, text);
            imgui.SetCursorScreenPos({x,y+1}); imgui.TextColored({0,0,0,1}, text);
            imgui.SetCursorScreenPos({x,y});   imgui.TextColored(col, text);
        end

        if imgui.Begin('PartyListTargetPreview', true, wflags) then
            wX, wY = imgui.GetWindowPos();

            -- Scale imgui font to respect partyListFontOffset (same rationale as stacked).
            -- All text here is imgui.TextColored, which uses the default imgui font.
            local _fontOffset = gConfig.partyListFontOffset or 0;
            local _baseFontH  = settings.hp_font_settings.font_height;
            local _fontScale  = (_baseFontH > 0) and ((_baseFontH + _fontOffset) / _baseFontH) or 1;
            if (_fontScale <= 0) then _fontScale = 1; end
            imgui.SetWindowFontScale(_fontScale);

            local titleW, _ = imgui.CalcTextSize('Target');
            imgui.SetCursorPosX(math.floor((winW - titleW) / 2));
            imgui.TextColored({0.75, 0.83, 0.90, 1.0}, 'Target');
            local barX, barY = imgui.GetCursorScreenPos();
            progressbar.ProgressBar({{0.75, hpGrad}}, {barWidth, barHeight},
                {borderConfig=borderConfig, backgroundGradientOverride=bgGrad,
                 decorate=gConfig.showPartyListBookends});
            local _, textH = imgui.CalcTextSize('A');
            local textY = barY + math.floor((barHeight - textH) / 2);
            outlined(barX + 3, textY, {0.45, 0.70, 1.0, 1.0}, 'Player 1');

            local pctStr = '75';
            local pctW, _ = imgui.CalcTextSize(pctStr);
            outlined(barX + barWidth - pctW - 2, textY, {1,1,1,1}, pctStr);
            imgui.SetCursorScreenPos({barX, barY + barHeight + 1});
            imgui.Dummy({barWidth, 1});
            wW, wH = imgui.GetWindowSize();
            imgui.SetWindowFontScale(1.0);
        end
        imgui.PopStyleVar(3);
        imgui.End();
        if isModernPrev then EndModernStyle(); end
        targetWindowPrevH = wH;

        -- Preview: yellow Level Sync dot on top-right edge of target window
        do
            local dotR = settings.dotRadius * 2;
            imgui.GetForegroundDrawList():AddCircleFilled(
                { wX + wW - math.floor(wW * 0.10), wY }, dotR,
                imgui.GetColorU32({ 1.00, 0.92, 0.20, 1.0 }), dotR * 3);
        end

        local bgPrim  = partyWindowPrim[4].background;
        if isModernPrev then
            for _, k in ipairs(bgImageKeys) do
                bgPrim[k].visible = false;
            end
        else
        local bgWidth  = wW + settings.bgPadding * 2;
        local bgHeight = wH + settings.bgPadding * 2;
        bgPrim.bg.visible    = bgPrim.bg.exists;
        bgPrim.bg.position_x = wX - settings.bgPadding;
        bgPrim.bg.position_y = wY - settings.bgPadding;
        bgPrim.bg.width      = math.ceil(bgWidth  / gConfig.partyListBgScale);
        bgPrim.bg.height     = math.ceil(bgHeight / gConfig.partyListBgScale);
        bgPrim.br.visible    = bgPrim.br.exists;
        bgPrim.br.position_x = bgPrim.bg.position_x + bgWidth  - math.floor((settings.borderSize * gConfig.partyListBgScale) - (settings.bgOffset * gConfig.partyListBgScale));
        bgPrim.br.position_y = bgPrim.bg.position_y + bgHeight - math.floor((settings.borderSize * gConfig.partyListBgScale) - (settings.bgOffset * gConfig.partyListBgScale));
        bgPrim.br.width      = settings.borderSize; bgPrim.br.height = settings.borderSize;
        bgPrim.tr.visible    = bgPrim.tr.exists;
        bgPrim.tr.position_x = bgPrim.br.position_x;
        bgPrim.tr.position_y = bgPrim.bg.position_y - settings.bgOffset * gConfig.partyListBgScale;
        bgPrim.tr.width      = bgPrim.br.width;
        bgPrim.tr.height     = math.ceil((bgPrim.br.position_y - bgPrim.tr.position_y) / gConfig.partyListBgScale);
        bgPrim.tl.visible    = bgPrim.tl.exists;
        bgPrim.tl.position_x = bgPrim.bg.position_x - settings.bgOffset * gConfig.partyListBgScale;
        bgPrim.tl.position_y = bgPrim.tr.position_y;
        bgPrim.tl.width      = math.ceil((bgPrim.tr.position_x - bgPrim.tl.position_x) / gConfig.partyListBgScale);
        bgPrim.tl.height     = bgPrim.tr.height;
        bgPrim.bl.visible    = bgPrim.bl.exists;
        bgPrim.bl.position_x = bgPrim.tl.position_x; bgPrim.bl.position_y = bgPrim.br.position_y;
        bgPrim.bl.width      = bgPrim.tl.width;      bgPrim.bl.height     = bgPrim.br.height;
        end
        return;
    end
    if (not gConfig.showPartyListTarget)             then hideBg(); return; end

    local entity       = AshitaCore:GetMemoryManager():GetEntity();
    local playerTarget = AshitaCore:GetMemoryManager():GetTarget();
    if (entity == nil or playerTarget == nil) then hideBg(); return; end

    local t1, _ = GetTargets();
    if (t1 == nil or t1 == 0) then hideBg(); return; end

    local targetName = entity:GetName(t1);
    local targetHPP  = entity:GetHPPercent(t1) / 100;
    if (targetName == nil or targetName == '') then hideBg(); return; end

    -- Target cursor lock: player has manually locked their cursor to this target (NumPad 0 / /lockon).
    -- This is the player's UI lock, NOT mob claim status or engagement.
    local isLocked = false;
    pcall(function()
        local locked = playerTarget:GetIsLocked();
        if locked then isLocked = true; end
    end);

    local nameColor = {1, 1, 1, 1};
    local spawnType = 0;
    pcall(function() spawnType = entity:GetSpawnFlags(t1); end);

    -- Entity action status for status icon display.
    -- Known values: 0=Idle, 1=Engaged, 2=Dead, 33=KO, 47=Seeking(LFP), 85=Bazaar
    local entityActionStatus = 0;
    pcall(function()
        local s = entity:GetStatus(t1);
        if s ~= nil then entityActionStatus = s; end
    end);
    -- Social/search flags (Away, Mentor, New Adventurer, LFG-while-in-party).
    -- NOTE: method name may differ by Ashita4 build; adjust 'GetStatusServer' if needed.
    local entitySearchFlags = 0;
    pcall(function()
        local f = entity:GetStatusServer(t1);
        if f ~= nil then entitySearchFlags = f; end
    end);
    -- Level Sync detection: buff ID 233 on the target.
    -- statushandler exposes buffs for any nearby player by server ID (pulled from 0x076 packets).
    local targetIsSynced = false;
    pcall(function()
        local tid = entity:GetServerId(t1);
        if tid ~= nil and tid ~= 0 then
            local buffs = statusHandler.get_member_status(tid);
            if buffs ~= nil then
                for i = 1, #buffs do
                    if buffs[i] == 233 then
                        targetIsSynced = true;
                        break;
                    end
                end
            end
        end
    end);

    if bit.band(spawnType, 0x01) ~= 0 then
        local party = AshitaCore:GetMemoryManager():GetParty();
        local tid   = 0;
        pcall(function() tid = entity:GetServerId(t1); end);
        if party ~= nil then
            for i = 0, 17 do
                if party:GetMemberIsActive(i) ~= 0 and party:GetMemberServerId(i) == tid then
                    nameColor = {0.45, 0.70, 1.0, 1.0};
                    break;
                end
            end
        end
    else
        -- Non-PC: red name if mob is claimed (by us or anyone)
        local claimed = false;
        pcall(function()
            local cs = entity:GetClaimStatus(t1);
            if cs ~= nil and cs ~= 0 then claimed = true; end
        end);
        if claimed then
            nameColor = {1.0, 0.35, 0.35, 1.0};
        end
    end

    local scale     = getScale(1);
    local barHeight = settings.barHeight * scale.y;
    local padding   = 4;
    local rowGap    = 1;
    local textGap   = 2;
    local gap       = 10;

    local winW      = (fullMenuWidth[1] or (settings.hpBarWidth * scale.x + padding * 2));
    local isModern  = gConfig.modernTheme;
    -- Modern theme uses WindowPadding {10, 6} instead of the local 'padding' (4),
    -- so subtract the extra horizontal space from the bar width.
    local modernExtra = isModern and 12 or 0;  -- (10 - 4) * 2
    local barWidth  = winW - padding * 2 - modernExtra;

    local _, hpGradient      = GetHpColors(targetHPP);
    local bgGradientOverride = {'#000813', '#000813'};

    local titleOverhang = 0;
    local partyTitlePrim = partyWindowPrim[1] and partyWindowPrim[1].bgTitle or nil;
    if (partyTitlePrim ~= nil and gConfig.showPartyListTitle) then
        titleOverhang = math.floor((partyTitlePrim.height * partyTitlePrim.scale_y / 2) + (2 / partyTitlePrim.scale_y));
    end

    local anchorX = partyList1Pos.x;
    local anchorY = partyList1Pos.y - titleOverhang - gap - targetWindowPrevH;

    imgui.SetNextWindowPos({anchorX, anchorY}, ImGuiCond_Always);
    imgui.SetNextWindowSize({winW, 0}, ImGuiCond_Always);

    local windowFlags = bit.bor(
        ImGuiWindowFlags_NoDecoration,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoSavedSettings,
        ImGuiWindowFlags_NoMove,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoScrollWithMouse,
        ImGuiWindowFlags_NoBringToFrontOnFocus
    );
    if not isModern then
        windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoBackground);
    end

    local function outlined(x, y, col, text)
        imgui.SetCursorScreenPos({x - 1, y}); imgui.TextColored({0,0,0,1}, text);
        imgui.SetCursorScreenPos({x + 1, y}); imgui.TextColored({0,0,0,1}, text);
        imgui.SetCursorScreenPos({x, y - 1}); imgui.TextColored({0,0,0,1}, text);
        imgui.SetCursorScreenPos({x, y + 1}); imgui.TextColored({0,0,0,1}, text);
        imgui.SetCursorScreenPos({x, y});     imgui.TextColored(col, text);
    end

    imgui.PushStyleVar(ImGuiStyleVar_FramePadding,  {0, 0});
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing,   {settings.barSpacing * scale.x, 0});
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {padding, 3});
    if isModern then BeginModernStyle(); end

    local wX, wY, wW, wH = anchorX, anchorY, winW, 0;

    if imgui.Begin('PartyListTarget', true, windowFlags) then
        wX, wY = imgui.GetWindowPos();

        -- Scale imgui font to respect partyListFontOffset (same rationale as stacked).
        -- The target window draws all text via imgui.TextColored / outlined().
        local _fontOffset = gConfig.partyListFontOffset or 0;
        local _baseFontH  = settings.hp_font_settings.font_height;
        local _fontScale  = (_baseFontH > 0) and ((_baseFontH + _fontOffset) / _baseFontH) or 1;
        if (_fontScale <= 0) then _fontScale = 1; end
        imgui.SetWindowFontScale(_fontScale);

        local titleW, _ = imgui.CalcTextSize('Target');
        imgui.SetCursorPosX(math.floor((winW - titleW) / 2));
        imgui.TextColored({0.75, 0.83, 0.90, 1.0}, 'Target');

        -- Status icon: top-right of title row for PC targets.
        -- Shows the target's current activity/search status (LFP, Bazaar, Away, Mentor, New).
        -- entityActionStatus 47 = LFP/Seeking, 85 = Bazaar.
        -- entitySearchFlags bits: 0x01=Away, 0x02=Mentor, 0x04=NewAdv, 0x08=LFG-in-party.
        do
            local isPC = bit.band(spawnType, 0x01) ~= 0;
            local iconLabel, iconColor;
            if isPC then
                if     entityActionStatus == 47 then
                    iconLabel = 'LFP';  iconColor = {0.45, 0.70, 1.00, 1.0};
                elseif entityActionStatus == 85 then
                    iconLabel = 'Baz';  iconColor = {1.00, 0.80, 0.20, 1.0};
                elseif bit.band(entitySearchFlags, 0x01) ~= 0 then
                    iconLabel = 'Away'; iconColor = {0.55, 0.55, 0.55, 1.0};
                elseif bit.band(entitySearchFlags, 0x02) ~= 0 then
                    iconLabel = 'Mtr';  iconColor = {1.00, 0.85, 0.30, 1.0};
                elseif bit.band(entitySearchFlags, 0x04) ~= 0 then
                    iconLabel = 'New';  iconColor = {0.40, 0.90, 0.40, 1.0};
                elseif bit.band(entitySearchFlags, 0x08) ~= 0 then
                    iconLabel = 'LFG';  iconColor = {0.45, 1.00, 0.65, 1.0};
                end
            end
            if iconLabel ~= nil then
                local iconW, _ = imgui.CalcTextSize(iconLabel);
                imgui.SameLine();
                -- In modern mode, WindowPadding is {10,6}, so offset accordingly to keep the
                -- icon on the right edge of the visible content area.
                local rightInset = isModern and 10 or padding;
                imgui.SetCursorPosX(winW - iconW - rightInset);
                imgui.TextColored(iconColor, iconLabel);
            end
        end

        local barX, barY = imgui.GetCursorScreenPos();
        progressbar.ProgressBar(
            {{targetHPP, hpGradient}},
            {barWidth, barHeight},
            {borderConfig=borderConfig, backgroundGradientOverride=bgGradientOverride,
             decorate=gConfig.showPartyListBookends}
        );

        local _, textH = imgui.CalcTextSize('A');
        local textY = barY + math.floor((barHeight - textH) / 2);

        local leftPad  = 3
        local rightPad = 2
        local minGap   = 4   -- minimum pixels between name and HP%

        local nameStr = tostring(targetName)
        local pctStr  = string.format('%d', math.floor(targetHPP * 100))
        local pctW, _ = imgui.CalcTextSize(pctStr)

        -- If the full name would collide with the HP%, truncate with an ellipsis.
        -- Budget = bar width - leftPad - rightPad - pctW - minGap
        local nameBudget = barWidth - leftPad - rightPad - pctW - minGap
        local nameW, _   = imgui.CalcTextSize(nameStr)
        if nameW > nameBudget and #nameStr > 1 then
            -- Shrink one char at a time until it fits (names are short enough
            -- that this is cheap; avoids needing to measure a per-char width).
            local trimmed = nameStr
            while #trimmed > 1 do
                trimmed = trimmed:sub(1, #trimmed - 1)
                local w, _ = imgui.CalcTextSize(trimmed .. '…')
                if w <= nameBudget then
                    nameStr = trimmed .. '…'
                    break
                end
            end
        end

        outlined(barX + leftPad, textY, nameColor, nameStr)
        outlined(barX + barWidth - pctW - rightPad, textY, {1, 1, 1, 1}, pctStr)

        if (isLocked) then
            local rowY = barY + barHeight + textGap;
            local red     = {1.0, 0.25, 0.25, 1.0};
            local lockCol = {1.0, 0.45, 0.45, 1.0};

            local leftArrow  = '◀';
            local rightArrow = '▶';
            local lockText   = 'Locked';

            local rightArrowW, _      = imgui.CalcTextSize(rightArrow);
            local lockW, rowTextH     = imgui.CalcTextSize(lockText);

            outlined(barX + 3, rowY, red, leftArrow);
            outlined(barX + barWidth - rightArrowW - 3, rowY, red, rightArrow);
            outlined(barX + math.floor((barWidth - lockW) / 2), rowY, lockCol, lockText);

            imgui.SetCursorScreenPos({barX, rowY + rowTextH + rowGap});
            imgui.Dummy({barWidth, 1});
        else
            imgui.SetCursorScreenPos({barX, barY + barHeight + rowGap});
            imgui.Dummy({barWidth, 1});
        end

        wW, wH = imgui.GetWindowSize();
        imgui.SetWindowFontScale(1.0);
    end

    imgui.PopStyleVar(3);
    imgui.End();
    if isModern then EndModernStyle(); end
    targetWindowPrevH = wH;

    -- Level Sync indicator: yellow dot centered on the top-right corner of the target window
    -- (same visual style as treasure/trade dots on the party window).
    if targetIsSynced then
        local dotR = settings.dotRadius * 2;
        imgui.GetForegroundDrawList():AddCircleFilled(
            { wX + wW - math.floor(wW * 0.10), wY }, dotR,
            imgui.GetColorU32({ 1.00, 0.92, 0.20, 1.0 }), dotR * 3);
    end

    local bgPrim   = partyWindowPrim[4].background;
    if isModern then
        for _, k in ipairs(bgImageKeys) do
            bgPrim[k].visible = false;
        end
    else
        local bgWidth  = wW + settings.bgPadding * 2;
        local bgHeight = wH + settings.bgPadding * 2;

        bgPrim.bg.visible    = bgPrim.bg.exists;
        bgPrim.bg.position_x = wX - settings.bgPadding;
        bgPrim.bg.position_y = wY - settings.bgPadding;
    bgPrim.bg.width      = math.ceil(bgWidth  / gConfig.partyListBgScale);
    bgPrim.bg.height     = math.ceil(bgHeight / gConfig.partyListBgScale);

    bgPrim.br.visible    = bgPrim.br.exists;
    bgPrim.br.position_x = bgPrim.bg.position_x + bgWidth  - math.floor((settings.borderSize * gConfig.partyListBgScale) - (settings.bgOffset * gConfig.partyListBgScale));
    bgPrim.br.position_y = bgPrim.bg.position_y + bgHeight - math.floor((settings.borderSize * gConfig.partyListBgScale) - (settings.bgOffset * gConfig.partyListBgScale));
    bgPrim.br.width      = settings.borderSize;
    bgPrim.br.height     = settings.borderSize;

    bgPrim.tr.visible    = bgPrim.tr.exists;
    bgPrim.tr.position_x = bgPrim.br.position_x;
    bgPrim.tr.position_y = bgPrim.bg.position_y - settings.bgOffset * gConfig.partyListBgScale;
    bgPrim.tr.width      = bgPrim.br.width;
    bgPrim.tr.height     = math.ceil((bgPrim.br.position_y - bgPrim.tr.position_y) / gConfig.partyListBgScale);

    bgPrim.tl.visible    = bgPrim.tl.exists;
    bgPrim.tl.position_x = bgPrim.bg.position_x - settings.bgOffset * gConfig.partyListBgScale;
    bgPrim.tl.position_y = bgPrim.tr.position_y;
    bgPrim.tl.width      = math.ceil((bgPrim.tr.position_x - bgPrim.tl.position_x) / gConfig.partyListBgScale);
    bgPrim.tl.height     = bgPrim.tr.height;

    bgPrim.bl.visible    = bgPrim.bl.exists;
    bgPrim.bl.position_x = bgPrim.tl.position_x;
    bgPrim.bl.position_y = bgPrim.br.position_y;
    bgPrim.bl.width      = bgPrim.tl.width;
    bgPrim.bl.height     = bgPrim.br.height;
    end
end

-- Helper: hide cast cost bg primitives.
local function HideCastCostBg()
    for _, k in ipairs(bgImageKeys) do
        partyWindowPrim[5].background[k].visible = false;
    end
end

-- Renders the Cast Cost info panel, anchored above the Target preview.
-- Width matches party window width. Uses party-style background by default;
-- Modern mode uses a clean imgui-based dark-blue theme.
local function DrawCastCost(settings)
    if not gConfig.showCastCost then HideCastCostBg(); return; end
    if partyList1Pos.x == 0 and partyList1Pos.y == 0 then HideCastCostBg(); return; end

    local info = cc_GetCurrentSelection();
    local isPreview = false;

    if info == nil then
        if showConfig and showConfig[1] then
            info = { type = 'spell', id = 0, name = 'Cure IV (Preview)', mpCost = 88, recastDelay = 40 };
            isPreview = true;
        else
            HideCastCostBg();
            return;
        end
    end

    local playerMp, playerTp = cc_GetPlayerStats();

    -- First line right side: MP (spells) or TP (weapon skills)
    local firstLineRight = nil;   -- { text, color } or nil
    if info.type == 'spell' then
        local hasEnoughMp = playerMp >= info.mpCost;
        firstLineRight = {
            text  = string.format('MP: %d', info.mpCost),
            color = hasEnoughMp and { 0.83, 1.0, 0.59, 1.0 } or { 1.0, 0.4, 0.4, 1.0 },
        };
    elseif info.type == 'ability' and info.isWeaponSkill then
        local hasEnoughTp = playerTp >= 1000;
        firstLineRight = {
            text  = string.format('TP: %d / 1000', playerTp),
            color = hasEnoughTp and { 1.0, 0.8, 0.0, 1.0 } or { 1.0, 0.4, 0.4, 1.0 },
        };
    end

    -- Second line: Recast (max) + Next (live countdown)
    local segments = {};
    local function addSeg(text, color)
        table.insert(segments, { text = text, color = color });
    end

    if info.type == 'spell' then
        local rcMax = cc_FormatRecastDelay(info.recastDelay);
        if rcMax ~= '' then
            addSeg('Recast: ' .. rcMax, { 0.8, 0.8, 0.8, 1.0 });
        end
        local nextSecs = isPreview and 7 or cc_GetSpellRecast(info.id);
        if nextSecs > 0 then
            addSeg('Next: ' .. cc_FormatSeconds(nextSecs), { 1.0, 0.7, 0.3, 1.0 });
        else
            addSeg('Next: 0', { 0.5, 1.0, 0.5, 1.0 });
        end
    elseif info.type == 'ability' and not info.isWeaponSkill then
        local rcMax = cc_FormatRecastDelay(info.recastDelay);
        if rcMax ~= '' then
            addSeg('Recast: ' .. rcMax, { 0.8, 0.8, 0.8, 1.0 });
        end
        local nextSecs = isPreview and 0 or cc_GetAbilityRecast(info.id);
        if nextSecs > 0 then
            addSeg('Next: ' .. cc_FormatSeconds(nextSecs), { 1.0, 0.7, 0.3, 1.0 });
        else
            addSeg('Next: 0', { 0.5, 1.0, 0.5, 1.0 });
        end
    elseif info.type == 'mount' then
        addSeg('Mount', { 0.8, 0.8, 0.8, 1.0 });
    end

    -- Match party width
    local winW = fullMenuWidth[1] or 280;

    -- Compute anchor Y (above target preview, or where it would be)
    local titleOverhang = 0;
    local partyTitlePrim = partyWindowPrim[1] and partyWindowPrim[1].bgTitle or nil;
    if (partyTitlePrim ~= nil and gConfig.showPartyListTitle) then
        titleOverhang = math.floor((partyTitlePrim.height * partyTitlePrim.scale_y / 2) + (2 / partyTitlePrim.scale_y));
    end

    local gap          = 10;
    local castCostGap  = 4;
    local targetH      = gConfig.showPartyListTarget and targetWindowPrevH or 0;
    local targetGap    = gConfig.showPartyListTarget and gap or 0;

    local bottomY = partyList1Pos.y - titleOverhang - targetGap - targetH - castCostGap;
    local topY    = bottomY - (castCostPrevH > 0 and castCostPrevH or 44);
    local anchorX = partyList1Pos.x;

    imgui.SetNextWindowPos({ anchorX, topY }, ImGuiCond_Always);
    imgui.SetNextWindowSize({ winW, 0 }, ImGuiCond_Always);

    local isModern = gConfig.modernTheme;
    local padding  = 4;

    local windowFlags = bit.bor(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoCollapse,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoMove,
        ImGuiWindowFlags_NoBringToFrontOnFocus,
        ImGuiWindowFlags_NoSavedSettings
    );
    if not isModern then
        -- Party mode: imgui draws no bg, primitives provide the party-style texture
        windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoBackground);
    end

    if isModern then
        imgui.PushStyleColor(ImGuiCol_WindowBg, { 0, 0.06, 0.16, 0.9 });
        imgui.PushStyleColor(ImGuiCol_Border,   { 0.3, 0.3, 0.5, 0.8 });
        imgui.PushStyleVar(ImGuiStyleVar_WindowPadding,  { 10, 6 });
        imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 4);
    else
        imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { padding, 3 });
    end

    local wX, wY, wW, wH = anchorX, topY, winW, 0;

    if imgui.Begin('HXUICastCost', true, windowFlags) then
        wX, wY = imgui.GetWindowPos();

        -- Scale imgui font to respect partyListFontOffset (same rationale as stacked).
        -- Cast cost panel draws all text via imgui.TextColored.
        local _fontOffset = gConfig.partyListFontOffset or 0;
        local _baseFontH  = settings.hp_font_settings.font_height;
        local _fontScale  = (_baseFontH > 0) and ((_baseFontH + _fontOffset) / _baseFontH) or 1;
        if (_fontScale <= 0) then _fontScale = 1; end
        imgui.SetWindowFontScale(_fontScale);

        -- Line 1: name (left) + optional right-aligned MP/TP
        imgui.TextColored({ 1, 1, 1, 1 }, info.name);
        if firstLineRight ~= nil then
            imgui.SameLine();
            local tw, _ = imgui.CalcTextSize(firstLineRight.text);
            local rightX = winW - tw - padding - 8;
            if rightX > 0 then imgui.SetCursorPosX(rightX); end
            imgui.TextColored(firstLineRight.color, firstLineRight.text);
        end

        -- Line 2: segments with `|` separators
        for i, seg in ipairs(segments) do
            if i > 1 then
                imgui.SameLine();
                imgui.TextColored({ 0.45, 0.45, 0.5, 1.0 }, '|');
                imgui.SameLine();
            end
            imgui.TextColored(seg.color, seg.text);
        end

        wW, wH = imgui.GetWindowSize();
        castCostPrevH = wH;
        imgui.SetWindowFontScale(1.0);
    end
    imgui.End();

    if isModern then
        imgui.PopStyleVar(2);
        imgui.PopStyleColor(2);
    else
        imgui.PopStyleVar(1);
    end

    -- Position party-style background primitives (only in non-Modern mode)
    local bgPrim = partyWindowPrim[5].background;
    if isModern then
        for _, k in ipairs(bgImageKeys) do
            bgPrim[k].visible = false;
        end
    else
        local bgWidth  = wW + settings.bgPadding * 2;
        local bgHeight = wH + settings.bgPadding * 2;

        bgPrim.bg.visible    = bgPrim.bg.exists;
        bgPrim.bg.position_x = wX - settings.bgPadding;
        bgPrim.bg.position_y = wY - settings.bgPadding;
        bgPrim.bg.width      = math.ceil(bgWidth  / gConfig.partyListBgScale);
        bgPrim.bg.height     = math.ceil(bgHeight / gConfig.partyListBgScale);

        bgPrim.br.visible    = bgPrim.br.exists;
        bgPrim.br.position_x = bgPrim.bg.position_x + bgWidth  - math.floor((settings.borderSize * gConfig.partyListBgScale) - (settings.bgOffset * gConfig.partyListBgScale));
        bgPrim.br.position_y = bgPrim.bg.position_y + bgHeight - math.floor((settings.borderSize * gConfig.partyListBgScale) - (settings.bgOffset * gConfig.partyListBgScale));
        bgPrim.br.width      = settings.borderSize;
        bgPrim.br.height     = settings.borderSize;

        bgPrim.tr.visible    = bgPrim.tr.exists;
        bgPrim.tr.position_x = bgPrim.br.position_x;
        bgPrim.tr.position_y = bgPrim.bg.position_y - settings.bgOffset * gConfig.partyListBgScale;
        bgPrim.tr.width      = bgPrim.br.width;
        bgPrim.tr.height     = math.ceil((bgPrim.br.position_y - bgPrim.tr.position_y) / gConfig.partyListBgScale);

        bgPrim.tl.visible    = bgPrim.tl.exists;
        bgPrim.tl.position_x = bgPrim.bg.position_x - settings.bgOffset * gConfig.partyListBgScale;
        bgPrim.tl.position_y = bgPrim.tr.position_y;
        bgPrim.tl.width      = math.ceil((bgPrim.tr.position_x - bgPrim.tl.position_x) / gConfig.partyListBgScale);
        bgPrim.tl.height     = bgPrim.tr.height;

        bgPrim.bl.visible    = bgPrim.bl.exists;
        bgPrim.bl.position_x = bgPrim.tl.position_x;
        bgPrim.bl.position_y = bgPrim.br.position_y;
        bgPrim.bl.width      = bgPrim.tl.width;
        bgPrim.bl.height     = bgPrim.br.height;
    end
end

partyList.DrawWindow = function(settings)
    local party  = AshitaCore:GetMemoryManager():GetParty();
    local player = AshitaCore:GetMemoryManager():GetPlayer();

    if (party == nil or player == nil or player.isZoning or player:GetMainJob() == 0) then
        UpdateTextVisibility(false);
        for _, k in ipairs(bgImageKeys) do
            partyWindowPrim[4].background[k].visible = false;
        end
        return;
    end

    local partyMemberCount = 0;
    if (showConfig[1] and gConfig.partyListPreview) then
        partyMemberCount = partyMaxSize;
    else
        for i = 0, partyMaxSize - 1 do
            if (party:GetMemberIsActive(i) ~= 0) then
                partyMemberCount = partyMemberCount + 1;
            else
                break;
            end
        end
    end

    local superCompact  = SuperCompactOverrideEnabled();
    local showMainParty = superCompact or gConfig.showPartyListWhenSolo or partyMemberCount > 1;

    if (not showMainParty) then
        UpdateTextVisibility(false);
        UpdateTextVisibility(false, 2);
        UpdateTextVisibility(false, 3);
        selectionPrim.visible = false;
        arrowPrim.visible = false;
        for _, k in ipairs(bgImageKeys) do
            partyWindowPrim[4].background[k].visible = false;
        end
        return;
    end

    partyTargeted    = false;
    partySubTargeted = false;

    DrawCurrentTarget(settings);
    DrawCastCost(settings);

    partyList.DrawPartyWindow(settings, party, 1);

    if (gConfig.partyListAlliance) then
        partyList.DrawPartyWindow(settings, party, 2);
        partyList.DrawPartyWindow(settings, party, 3);
    else
        UpdateTextVisibility(false, 2);
        UpdateTextVisibility(false, 3);
    end

    selectionPrim.visible = partyTargeted;
    arrowPrim.visible     = partySubTargeted;
end

partyList.DrawPartyWindow = function(settings, party, partyIndex)
    local firstPlayerIndex = (partyIndex - 1) * partyMaxSize;
    local lastPlayerIndex  = firstPlayerIndex + partyMaxSize - 1;

    local partyMemberCount = 0;
    if (showConfig[1] and gConfig.partyListPreview) then
        partyMemberCount = partyMaxSize;
    else
        for i = firstPlayerIndex, lastPlayerIndex do
            if (party:GetMemberIsActive(i) ~= 0) then
                partyMemberCount = partyMemberCount + 1
            else
                break
            end
        end
    end

    if (partyIndex == 1 and not gConfig.showPartyListWhenSolo and partyMemberCount <= 1) then
        UpdateTextVisibility(false);
        return;
    end

    if (partyIndex > 1 and partyMemberCount == 0) then
        UpdateTextVisibility(false, partyIndex);
        return;
    end

    local bgTitlePrim    = partyWindowPrim[partyIndex].bgTitle;
    local backgroundPrim = partyWindowPrim[partyIndex].background;

    if (partyIndex == 1) then
        bgTitlePrim.texture_offset_y = partyMemberCount == 1 and 0 or bgTitleItemHeight;
    else
        bgTitlePrim.texture_offset_y = bgTitleItemHeight * partyIndex
    end

    local imguiPosX, imguiPosY;

    local isModern = gConfig.modernTheme;
    local windowFlags = bit.bor(
        ImGuiWindowFlags_NoDecoration,
        ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoBringToFrontOnFocus
    );
    if not isModern then
        windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoBackground);
    end
    if (gConfig.lockPositions) then
        windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoMove);
    end

    local windowName = 'PartyList';
    if (partyIndex > 1) then
        windowName = windowName .. partyIndex
    end

    local scale    = getScale(partyIndex);
    local visualScale = GetPartyVisualScales();
    local iconSize = math.floor(settings.iconSize * 1.1 * visualScale.job);

    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, {0, 0});
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { settings.barSpacing * scale.x, 0 });
    if isModern then BeginModernStyle(); end
    if (imgui.Begin(windowName, true, windowFlags)) then
        imguiPosX, imguiPosY = imgui.GetWindowPos();
        if (partyIndex == 1) then
            partyList1Pos.x = imguiPosX;
            partyList1Pos.y = imguiPosY;
        end

        -- Modern mode: inject centered title text (replaces the hidden primitive title bar)
        if isModern and gConfig.showPartyListTitle then
            local titleText;
            if partyIndex == 1 then
                titleText = (partyMemberCount == 1) and 'Solo' or 'Party';
            elseif partyIndex == 2 then
                titleText = 'Alliance A';
            else
                titleText = 'Alliance B';
            end
            local tw, _ = imgui.CalcTextSize(titleText);
            local ww    = imgui.GetWindowWidth();
            if ww > 0 then imgui.SetCursorPosX((ww - tw) / 2); end
            imgui.TextColored({ 0.75, 0.83, 0.90, 1.0 }, titleText);
        end

        local nameSize = SIZE.new();
        memberText[(partyIndex - 1) * 6].name:GetTextSize(nameSize);
        local offsetSize = nameSize.cy > iconSize and nameSize.cy or iconSize;
        if (not gConfig.stackedBars) then
            imgui.Dummy({0, settings.nameTextOffsetY + offsetSize});
        end

        UpdateTextVisibility(true, partyIndex);

        for i = firstPlayerIndex, lastPlayerIndex do
            local relIndex = i - firstPlayerIndex
            if ((partyIndex == 1 and settings.expandHeight) or relIndex < partyMemberCount or relIndex < settings.minRows) then
                DrawMember(i, settings);
            else
                UpdateTextVisibilityByMember(i, false);
            end
        end
    end

    local menuWidth, menuHeight = imgui.GetWindowSize();

    fullMenuWidth[partyIndex]  = menuWidth;
    fullMenuHeight[partyIndex] = menuHeight;

    if isModern then
        -- Modern mode: primitives hidden, imgui provides the background
        for _, k in ipairs(bgImageKeys) do
            backgroundPrim[k].visible = false;
        end
        bgTitlePrim.visible = false;
    else
        local bgWidth  = fullMenuWidth[partyIndex]  + (settings.bgPadding * 2);
        local bgHeight = fullMenuHeight[partyIndex] + (settings.bgPadding * 2);

        backgroundPrim.bg.visible    = backgroundPrim.bg.exists;
        backgroundPrim.bg.position_x = imguiPosX - settings.bgPadding;
        backgroundPrim.bg.position_y = imguiPosY - settings.bgPadding;
        backgroundPrim.bg.width      = math.ceil(bgWidth  / gConfig.partyListBgScale);
        backgroundPrim.bg.height     = math.ceil(bgHeight / gConfig.partyListBgScale);

        backgroundPrim.br.visible    = backgroundPrim.br.exists;
        backgroundPrim.br.position_x = backgroundPrim.bg.position_x + bgWidth  - math.floor((settings.borderSize * gConfig.partyListBgScale) - (settings.bgOffset * gConfig.partyListBgScale));
        backgroundPrim.br.position_y = backgroundPrim.bg.position_y + bgHeight - math.floor((settings.borderSize * gConfig.partyListBgScale) - (settings.bgOffset * gConfig.partyListBgScale));
        backgroundPrim.br.width      = settings.borderSize;
        backgroundPrim.br.height     = settings.borderSize;

        backgroundPrim.tr.visible    = backgroundPrim.tr.exists;
        backgroundPrim.tr.position_x = backgroundPrim.br.position_x;
        backgroundPrim.tr.position_y = backgroundPrim.bg.position_y - settings.bgOffset * gConfig.partyListBgScale;
        backgroundPrim.tr.width      = backgroundPrim.br.width;
        backgroundPrim.tr.height     = math.ceil((backgroundPrim.br.position_y - backgroundPrim.tr.position_y) / gConfig.partyListBgScale);

        backgroundPrim.tl.visible    = backgroundPrim.tl.exists;
        backgroundPrim.tl.position_x = backgroundPrim.bg.position_x - settings.bgOffset * gConfig.partyListBgScale;
        backgroundPrim.tl.position_y = backgroundPrim.tr.position_y;
        backgroundPrim.tl.width      = math.ceil((backgroundPrim.tr.position_x - backgroundPrim.tl.position_x) / gConfig.partyListBgScale);
        backgroundPrim.tl.height     = backgroundPrim.tr.height;

        backgroundPrim.bl.visible    = backgroundPrim.bl.exists;
        backgroundPrim.bl.position_x = backgroundPrim.tl.position_x;
        backgroundPrim.bl.position_y = backgroundPrim.br.position_y;
        backgroundPrim.bl.width      = backgroundPrim.tl.width;
        backgroundPrim.bl.height     = backgroundPrim.br.height;

        bgTitlePrim.visible    = gConfig.showPartyListTitle;
        bgTitlePrim.position_x = imguiPosX + math.floor((bgWidth / 2) - (bgTitlePrim.width * bgTitlePrim.scale_x / 2));
        bgTitlePrim.position_y = imguiPosY - math.floor((bgTitlePrim.height * bgTitlePrim.scale_y / 2) + (2 / bgTitlePrim.scale_y));
    end

    -- Top-of-party indicators for LOCAL PLAYER ONLY (partyIndex 1):
    --   Gold   = Treasure pool has items (left, 25% mark)
    --   Cyan   = Trade window open       (right, 75% mark)
    -- Leader (yellow) and Sync (red) are drawn per-member beside the job icon — see DrawMember.
    -- Dots sit CENTERED ON the window's top edge so half shows above, half below.
    if (partyIndex == 1) then
        local hasTreasure, hasTrade = GetPlayerStatusIcons();
        if (hasTreasure or hasTrade) then
            local dotR    = settings.dotRadius * 2;
            local dotY    = imguiPosY;  -- right on the top edge line

            local width   = fullMenuWidth[1] or (settings.hpBarWidth or 150);
            local leftX   = imguiPosX + math.floor(width * 0.25);
            local rightX  = imguiPosX + math.floor(width * 0.75);

            local fgList = imgui.GetForegroundDrawList();
            if (hasTreasure) then
                fgList:AddCircleFilled({ leftX,  dotY }, dotR, imgui.GetColorU32({1.00, 0.75, 0.10, 1.0}), dotR * 3);
            end
            if (hasTrade) then
                fgList:AddCircleFilled({ rightX, dotY }, dotR, imgui.GetColorU32({0.25, 0.85, 1.00, 1.0}), dotR * 3);
            end
        end
    end

    imgui.End();
    if isModern then EndModernStyle(); end
    imgui.PopStyleVar(2);

    if (settings.alignBottom and imguiPosX ~= nil) then
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
                x      = imguiPosX,
                y      = imguiPosY,
                width  = menuWidth,
                height = menuHeight,
            };
            ashita_settings.save();
        end
    end
end

partyList.Initialize = function(settings)
    local name_font_settings = deep_copy_table(settings.name_font_settings);
    local hp_font_settings   = deep_copy_table(settings.hp_font_settings);
    local mp_font_settings   = deep_copy_table(settings.mp_font_settings);
    local tp_font_settings   = deep_copy_table(settings.tp_font_settings);

    for i = 0, memberTextCount - 1 do
        local partyIndex = math.ceil((i + 1) / partyMaxSize);

        local partyListFontOffset = gConfig.partyListFontOffset;
        if (partyIndex == 2) then
            partyListFontOffset = gConfig.partyList2FontOffset;
        elseif (partyIndex == 3) then
            partyListFontOffset = gConfig.partyList3FontOffset;
        end

        name_font_settings.font_height = math.max(settings.name_font_settings.font_height + partyListFontOffset, 1);
        hp_font_settings.font_height   = math.max(settings.hp_font_settings.font_height   + partyListFontOffset, 1);
        mp_font_settings.font_height   = math.max(settings.mp_font_settings.font_height   + partyListFontOffset, 1);
        tp_font_settings.font_height   = math.max(settings.tp_font_settings.font_height   + partyListFontOffset, 1);

        memberText[i]      = {};
        memberText[i].name = fonts.new(name_font_settings);
        memberText[i].hp   = fonts.new(hp_font_settings);
        memberText[i].mp   = fonts.new(mp_font_settings);
        memberText[i].tp   = fonts.new(tp_font_settings);
    end

    targetText.name = fonts.new(deep_copy_table(settings.name_font_settings));
    targetText.hp   = fonts.new(deep_copy_table(settings.hp_font_settings));
    targetText.name:SetVisible(false);
    targetText.hp:SetVisible(false);

    loadedBg = nil;

    for i = 1, 3 do
        local backgroundPrim = {};

        for _, k in ipairs(bgImageKeys) do
            backgroundPrim[k]           = primitives:new(settings.prim_data);
            backgroundPrim[k].visible   = false;
            backgroundPrim[k].can_focus = false;
            backgroundPrim[k].exists    = false;
        end

        partyWindowPrim[i].background = backgroundPrim;

        local bgTitlePrim          = primitives.new(settings.prim_data);
        bgTitlePrim.color          = 0xFFC5CFDC;
        bgTitlePrim.texture        = string.format('%s/assets/PartyList-Titles.png', addon.path);
        bgTitlePrim.visible        = false;
        bgTitlePrim.can_focus      = false;
        bgTitleItemHeight          = bgTitlePrim.height / bgTitleAtlasItemCount;
        bgTitlePrim.height         = bgTitleItemHeight;

        partyWindowPrim[i].bgTitle = bgTitlePrim;
    end

    partyWindowPrim[4] = { background = {} };
    for _, k in ipairs(bgImageKeys) do
        local p           = primitives:new(settings.prim_data);
        p.visible         = false;
        p.can_focus       = false;
        p.exists          = false;
        partyWindowPrim[4].background[k] = p;
    end

    -- [5] = Cast Cost background (matches party style when not in Modern mode)
    partyWindowPrim[5] = { background = {} };
    for _, k in ipairs(bgImageKeys) do
        local p           = primitives:new(settings.prim_data);
        p.visible         = false;
        p.can_focus       = false;
        p.exists          = false;
        partyWindowPrim[5].background[k] = p;
    end

    selectionPrim         = primitives.new(settings.prim_data);
    selectionPrim.color   = 0xFFFFFFFF;
    selectionPrim.texture = string.format('%s/assets/Selector.png', addon.path);
    selectionPrim.visible   = false;
    selectionPrim.can_focus = false;

    arrowPrim           = primitives.new(settings.prim_data);
    arrowPrim.color     = 0xFFFFFFFF;
    arrowPrim.visible   = false;
    arrowPrim.can_focus = false;

    partyList.UpdateFonts(settings);
end

partyList.UpdateFonts = function(settings)
    for i = 0, memberTextCount - 1 do
        local partyIndex = math.ceil((i + 1) / partyMaxSize);

        local partyListFontOffset = gConfig.partyListFontOffset;
        if (partyIndex == 2) then
            partyListFontOffset = gConfig.partyList2FontOffset;
        elseif (partyIndex == 3) then
            partyListFontOffset = gConfig.partyList3FontOffset;
        end

        memberText[i].name:SetFontHeight(math.max(settings.name_font_settings.font_height + partyListFontOffset, 1));
        memberText[i].hp:SetFontHeight(  math.max(settings.hp_font_settings.font_height   + partyListFontOffset, 1));
        memberText[i].mp:SetFontHeight(  math.max(settings.mp_font_settings.font_height   + partyListFontOffset, 1));
        memberText[i].tp:SetFontHeight(  math.max(settings.tp_font_settings.font_height   + partyListFontOffset, 1));
    end

    local bgChanged  = gConfig.partyListBackgroundName ~= loadedBg;
    loadedBg         = gConfig.partyListBackgroundName;

    local bgColor     = tonumber(string.format('%02x%02x%02x%02x', gConfig.partyListBgColor[4],     gConfig.partyListBgColor[1],     gConfig.partyListBgColor[2],     gConfig.partyListBgColor[3]),     16);
    local borderColor = tonumber(string.format('%02x%02x%02x%02x', gConfig.partyListBorderColor[4], gConfig.partyListBorderColor[1], gConfig.partyListBorderColor[2], gConfig.partyListBorderColor[3]), 16);

    for i = 1, 5 do
        if partyWindowPrim[i].bgTitle ~= nil then
            partyWindowPrim[i].bgTitle.scale_x = gConfig.partyListBgScale / 2.30;
            partyWindowPrim[i].bgTitle.scale_y = gConfig.partyListBgScale / 2.30;
        end

        local backgroundPrim = partyWindowPrim[i].background;

        for _, k in ipairs(bgImageKeys) do
            local file_name          = string.format('%s-%s.png', gConfig.partyListBackgroundName, k);
            backgroundPrim[k].color  = k == 'bg' and bgColor or borderColor;
            if (bgChanged) then
                local width, height          = backgroundPrim[k].width, backgroundPrim[k].height;
                local filepath               = string.format('%s/assets/backgrounds/%s', addon.path, file_name);
                backgroundPrim[k].texture    = filepath;
                backgroundPrim[k].width      = width;
                backgroundPrim[k].height     = height;
                backgroundPrim[k].exists     = ashita.fs.exists(filepath);
            end
            backgroundPrim[k].scale_x = gConfig.partyListBgScale;
            backgroundPrim[k].scale_y = gConfig.partyListBgScale;
        end
    end

    arrowPrim.texture = string.format('%s/assets/cursors/%s', addon.path, gConfig.partyListCursor);
end

partyList.SetHidden = function(hidden)
    if (hidden == true) then
        UpdateTextVisibility(false);
        selectionPrim.visible = false;
        arrowPrim.visible     = false;
        for _, k in ipairs(bgImageKeys) do
            partyWindowPrim[4].background[k].visible = false;
            partyWindowPrim[5].background[k].visible = false;
        end
    end
end

partyList.HandleZonePacket = function(e)
    statusHandler.clear_cache();
    treasurePoolActive = false;  -- clear treasure state on zone change

    -- Re-poll treasure pool memory directly to confirm actual state after zoning
    -- (in case stale 0xD2 packets arrive shortly after zone in).
    pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory();
        if inv == nil then return; end
        local hasItem = false;
        for slot = 0, 9 do
            local item = inv:GetTreasurePoolItem(slot);
            if item ~= nil and item.ItemId and item.ItemId > 0 and item.ItemId ~= 65535 then
                hasItem = true;
                break;
            end
        end
        treasurePoolActive = hasItem;
    end);
end

-- Call this from the main hxui.lua incoming-packet handler:
--   partyList.HandleIncomingPacket(e)
-- Tracks treasure pool state via server packets so the gold dot on the
-- local player's HP bar accurately reflects items awaiting lot/pass.
--
-- Packet 0xD2 = treasure pool update (items arrive, or lots/passes change).
-- Packet 0xD3 = treasure pool closed / all items distributed.
--
-- Packet 0xD2 layout (post-header):
--   10 slots x 0x18 bytes each.  Item ID = uint16 at byte 0 of each slot.
--   If all item IDs are 0 the pool is empty (final clear update).
partyList.HandleIncomingPacket = function(e)
    if e.id == 0xD2 then
        local hasItem = false;
        for slot = 0, 9 do
            local base = 4 + slot * 0x18;         -- 0-indexed byte offset into e.data
            if base + 2 <= #e.data then
                local lo = e.data:byte(base + 1) or 0;   -- Lua strings are 1-indexed
                local hi = e.data:byte(base + 2) or 0;
                if (lo + hi * 256) ~= 0 then
                    hasItem = true;
                    break;
                end
            end
        end
        treasurePoolActive = hasItem;
    elseif e.id == 0xD3 then
        treasurePoolActive = false;
    end
end

-- /tstatus debug command — dumps target's status fields, flags, and treasure pool to chat
ashita.events.register('command', 'partylist_tstatus_cb', function (e)
    local args = e.command:lower():args();
    if args[1] ~= '/tstatus' then return; end
    e.blocked = true;

    local function tohex(n)
        if n == nil then return 'nil'; end
        return string.format('0x%X (%d)', n, n);
    end

    local entity = AshitaCore:GetMemoryManager():GetEntity();
    local target = AshitaCore:GetMemoryManager():GetTarget();
    if entity == nil or target == nil then
        print('[tstatus] no entity/target manager');
        return;
    end

    local t1 = target:GetTargetIndex(0);
    if t1 == nil or t1 == 0 then
        print('[tstatus] no current target');
        return;
    end

    local name     = entity:GetName(t1) or '?';
    local serverId = entity:GetServerId(t1) or 0;
    print(string.format('[tstatus] === %s  (idx=%d, srvId=%d) ===', name, t1, serverId));

    local methods = {
        'GetStatus', 'GetStatusServer', 'GetStatusNpcChat',
        'GetSpawnFlags',
        'GetRenderFlags0', 'GetRenderFlags1', 'GetRenderFlags2', 'GetRenderFlags3', 'GetRenderFlags4',
        'GetClaimStatus', 'GetType', 'GetRace',
        'GetCampaignNameFlag', 'GetLinkshellColor',
    };

    for _, m in ipairs(methods) do
        local ok, val = pcall(function() return entity[m](entity, t1); end);
        if ok then
            print(string.format('[tstatus] %-22s = %s', m, tohex(val)));
        else
            print(string.format('[tstatus] %-22s = ERROR (method missing?)', m));
        end
    end

    -- Buffs from statushandler (works for any nearby PC the 0x076 handler has cached)
    local buffs = nil;
    if serverId ~= 0 then
        pcall(function() buffs = statusHandler.get_member_status(serverId); end);
    end
    if buffs == nil then
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        local meId   = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0);
        if player ~= nil and serverId ~= 0 and meId == serverId then
            buffs = player:GetBuffs();
        end
    end
    if buffs ~= nil then
        local list = {};
        for i = 1, #buffs do
            if buffs[i] ~= nil and buffs[i] ~= 0 and buffs[i] ~= 255 then
                table.insert(list, tostring(buffs[i]));
            end
        end
        print('[tstatus] buffs: ' .. (#list > 0 and table.concat(list, ', ') or '(none)'));
    else
        print('[tstatus] (no buff data available for this target)');
    end

    print('[tstatus] === end ===');

    -- Target lock state dump
    do
        local pt = AshitaCore:GetMemoryManager():GetTarget();
        if pt ~= nil then
            print('[tstatus] === Target Lock State ===');
            local lockMethods = {
                'GetIsLocked',
                'GetLockedOn',
                'GetLockedOnFlag',
                'GetIsLockedOn',
                'GetTargetLocked',
                'GetCurrentTargetIsLocked',
                'GetIsTargetLocked',
            };
            for _, m in ipairs(lockMethods) do
                local ok, val = pcall(function() return pt[m](pt); end);
                if ok then
                    print(string.format('[tstatus] %-32s = %s', m, tostring(val)));
                else
                    print(string.format('[tstatus] %-32s = ERROR (missing)', m));
                end
            end
            print('[tstatus] === end lock ===');
        end
    end

    -- Treasure pool dump
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    if inv ~= nil then
        print('[tstatus] === Treasure Pool (treasurePoolActive=' .. tostring(treasurePoolActive) .. ') ===');
        local count = 0;
        for slot = 0, 9 do
            local ok, item = pcall(function() return inv:GetTreasurePoolItem(slot); end);
            if ok and item ~= nil and item.ItemId and item.ItemId > 0 and item.ItemId ~= 65535 then
                count = count + 1;
                local itemName = '?';
                pcall(function()
                    local res = AshitaCore:GetResourceManager():GetItemById(item.ItemId);
                    if res and res.Name and res.Name[1] then itemName = res.Name[1]; end
                end);
                local dropTime    = item.DropTime    or 0;
                local winningLot  = item.WinningLot  or 0;
                local winningName = item.WinningEntityName or '';
                print(string.format('[tstatus] slot %d: id=%d (%s)  dropTime=%s  winLot=%d  winName=%s',
                    slot, item.ItemId, itemName, tostring(dropTime), winningLot, winningName));
            end
        end
        if count == 0 then
            print('[tstatus] (pool empty)');
        else
            print(string.format('[tstatus] %d item(s) in pool', count));
        end
        print('[tstatus] === end pool ===');
    end

    -- Party leader & alliance roster dump
    local party = AshitaCore:GetMemoryManager():GetParty();
    if party ~= nil then
        print('[tstatus] === Party Leader IDs ===');
        local leaderMethods = {
            'GetAlliancePartyLeaderServerId1',
            'GetAlliancePartyLeaderServerId2',
            'GetAlliancePartyLeaderServerId3',
            'GetAllianceLeaderServerId',
            'GetAllianceLeaderID',
            'GetAllianceParty0LeaderID',
            'GetAllianceParty1LeaderID',
            'GetAllianceParty2LeaderID',
            'GetPartyLeaderServerId',
        };
        for _, m in ipairs(leaderMethods) do
            local ok, val = pcall(function() return party[m](party); end);
            if ok then
                print(string.format('[tstatus] %-36s = %s', m, tohex(val)));
            else
                print(string.format('[tstatus] %-36s = ERROR (missing)', m));
            end
        end

        print('[tstatus] === Alliance Roster ===');
        for i = 0, 17 do
            local active = 0;
            pcall(function() active = party:GetMemberIsActive(i); end);
            if active ~= 0 then
                local memName = '?';
                local memSrv  = 0;
                local memFlag = 0;
                pcall(function() memName = party:GetMemberName(i) or '?'; end);
                pcall(function() memSrv  = party:GetMemberServerId(i) or 0; end);
                pcall(function() memFlag = party:GetMemberFlagMask(i) or 0; end);
                print(string.format('[tstatus] mem[%2d] %-16s srvId=%-10d flagMask=%s',
                    i, memName, memSrv, tohex(memFlag)));
            end
        end
        print('[tstatus] === end roster ===');
    end
end);

return partyList;