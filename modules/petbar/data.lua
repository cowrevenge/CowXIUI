--[[
* XIUI Pet Bar - Data Module
* Handles state, caches, font objects, primitives, and helper functions
]]--

require('common');
require('handlers.helpers');
local ffi = require('ffi');
local windowBg = require('libs.windowbackground');
local packets = require('libs.packets');
local abilityRecast = require('libs.abilityrecast');

local data = {};

-- ============================================
-- Constants
-- ============================================
data.PADDING = 8;
data.JOB_SMN = 15;
data.JOB_BST = 9;
data.JOB_DRG = 14;
data.JOB_PUP = 18;

data.MAX_RECAST_SLOTS = 6;
data.RECAST_ICON_SIZE = 24;

-- Ready charge system constants
data.READY_DEFAULT_BASE_SECONDS = 45;  -- HorizonXI: 45s per charge (retail is 30s). Override via petBarReadyBaseRecast.
data.READY_MAX_CHARGES = 3;

data.bgImageKeys = { 'bg', 'tl', 'tr', 'br', 'bl' };

-- Preview type constants
data.PREVIEW_WYVERN = 1;
data.PREVIEW_AVATAR = 2;
data.PREVIEW_AUTOMATON = 3;
data.PREVIEW_JUG = 4;
data.PREVIEW_CHARMED = 5;

-- Preview type names for config dropdown
data.previewTypeNames = {
    [data.PREVIEW_WYVERN] = 'Wyvern (DRG)',
    [data.PREVIEW_AVATAR] = 'Avatar (SMN)',
    [data.PREVIEW_AUTOMATON] = 'Automaton (PUP)',
    [data.PREVIEW_JUG] = 'Jug Pet (BST)',
    [data.PREVIEW_CHARMED] = 'Charmed Pet (BST)',
};

-- Pet name to image file mapping
-- Maps in-game pet names to their image file paths
data.petImageMap = {
    -- Avatars
    ['Carbuncle'] = 'avatars/carbuncle.png',
    ['Ifrit'] = 'avatars/ifrit.png',
    ['Shiva'] = 'avatars/shiva.png',
    ['Garuda'] = 'avatars/garuda.png',
    ['Titan'] = 'avatars/titan.png',
    ['Ramuh'] = 'avatars/ramuh.png',
    ['Leviathan'] = 'avatars/leviathan.png',
    ['Fenrir'] = 'avatars/fenrir.png',
    ['Diabolos'] = 'avatars/diabolos.png',
    ['Atomos'] = 'avatars/atomos.png',
    ['Odin'] = 'avatars/odin.png',
    ['Alexander'] = 'avatars/alexander.png',
    ['Cait Sith'] = 'avatars/caitsith.png',
    ['Siren'] = 'avatars/siren.png',
    -- Spirits
    ['Fire Spirit'] = 'spirits/firespirit.png',
    ['Ice Spirit'] = 'spirits/icespirit.png',
    ['Air Spirit'] = 'spirits/windspirit.png',
    ['Earth Spirit'] = 'spirits/earthspirit.png',
    ['Thunder Spirit'] = 'spirits/thunderspirit.png',
    ['Water Spirit'] = 'spirits/waterspirit.png',
    ['Light Spirit'] = 'spirits/lightspirit.png',
    ['Dark Spirit'] = 'spirits/darkspirit.png',
    -- DRG Wyvern
    ['Wyvern'] = 'drg_wyvern.png',
};

-- Ordered list of avatars/spirits for config dropdown (SMN pets only)
data.avatarList = {
    'Carbuncle', 'Ifrit', 'Shiva', 'Garuda', 'Titan', 'Ramuh',
    'Leviathan', 'Fenrir', 'Diabolos', 'Atomos', 'Odin', 'Alexander',
    'Cait Sith', 'Siren',
    'Fire Spirit', 'Ice Spirit', 'Air Spirit', 'Earth Spirit',
    'Thunder Spirit', 'Water Spirit', 'Light Spirit', 'Dark Spirit',
};

-- Full list of all pets with images (used for primitive creation)
data.allPetsWithImages = {
    'Carbuncle', 'Ifrit', 'Shiva', 'Garuda', 'Titan', 'Ramuh',
    'Leviathan', 'Fenrir', 'Diabolos', 'Atomos', 'Odin', 'Alexander',
    'Cait Sith', 'Siren',
    'Fire Spirit', 'Ice Spirit', 'Air Spirit', 'Earth Spirit',
    'Thunder Spirit', 'Water Spirit', 'Light Spirit', 'Dark Spirit',
    'Wyvern',
};

-- ============================================
-- Jug Pet Database (from PetMe addon)
-- ============================================
-- Each entry: name (in-game), maxLevel, duration (minutes)
data.jugPets = {
    -- 90 minute pets (lower level)
    {name = 'FunguarFamiliar', maxLevel = 35, duration = 90},
    {name = 'CourierCarrie', maxLevel = 23, duration = 90},
    {name = 'SheepFamiliar', maxLevel = 35, duration = 90},
    {name = 'TigerFamiliar', maxLevel = 40, duration = 90},
    {name = 'FlytrapFamiliar', maxLevel = 40, duration = 90},
    {name = 'LizardFamiliar', maxLevel = 45, duration = 90},
    {name = 'MayflyFamiliar', maxLevel = 45, duration = 90},

    -- 60 minute pets (mid level)
    {name = 'EftFamiliar', maxLevel = 50, duration = 60},
    {name = 'BeetleFamiliar', maxLevel = 55, duration = 60},
    {name = 'AntlionFamiliar', maxLevel = 55, duration = 60},
    {name = 'MiteFamiliar', maxLevel = 55, duration = 60},
    {name = 'KeenearedSteffi', maxLevel = 75, duration = 60},
    {name = 'LullabyMelodia', maxLevel = 75, duration = 60},
    {name = 'FlowerpotBen', maxLevel = 75, duration = 60},
    {name = 'FlowerpotBill', maxLevel = 75, duration = 60},
    {name = 'Homunculus', maxLevel = 75, duration = 60},
    {name = 'VoraciousAudrey', maxLevel = 75, duration = 60},
    {name = 'AmbusherAllie', maxLevel = 75, duration = 60},
    {name = 'LifedrinkerLars', maxLevel = 75, duration = 60},
    {name = 'PanzerGalahad', maxLevel = 75, duration = 60},
    {name = 'ChopsueyChucky', maxLevel = 75, duration = 60},
    {name = 'AmigoSabotender', maxLevel = 75, duration = 60},

    -- 30 minute pets (high level)
    {name = 'CraftyClyvonne', maxLevel = 75, duration = 30},
    {name = 'BloodclawShasra', maxLevel = 75, duration = 30},
    {name = 'GorefangHobs', maxLevel = 75, duration = 30},
    {name = 'DipperYuly', maxLevel = 75, duration = 30},
    {name = 'SunburstMalfik', maxLevel = 75, duration = 30},
    {name = 'WarlikePatrick', maxLevel = 75, duration = 30},
    {name = 'ScissorlegXerin', maxLevel = 75, duration = 30},
    {name = 'BouncingBertha', maxLevel = 75, duration = 30},
    {name = 'RhymingShizuna', maxLevel = 75, duration = 30},
    {name = 'AttentiveIbuki', maxLevel = 75, duration = 30},
    {name = 'SwoopingZhivago', maxLevel = 75, duration = 30},
    {name = 'GenerousArthur', maxLevel = 75, duration = 30},
    {name = 'ThreestarLynn', maxLevel = 75, duration = 30},
    {name = 'BrainyWaluis', maxLevel = 75, duration = 30},
    {name = 'FaithfulFalcorr', maxLevel = 75, duration = 30},
    {name = 'SharpwitHermes', maxLevel = 99, duration = 30},
    {name = 'HeadbreakerKen', maxLevel = 99, duration = 30},
    {name = 'RedolentCandi', maxLevel = 99, duration = 30},
    {name = 'AlluringHoney', maxLevel = 99, duration = 30},
    {name = 'CaringKiyomaro', maxLevel = 99, duration = 30},
    {name = 'VivaciousVickie', maxLevel = 99, duration = 30},
    {name = 'HurlerPercival', maxLevel = 99, duration = 30},
    {name = 'BlackbeardRandy', maxLevel = 99, duration = 30},
    {name = 'FleetReinhard', maxLevel = 99, duration = 30},
    {name = 'GooeyGerard', maxLevel = 99, duration = 30},
    {name = 'CrudeRaphie', maxLevel = 99, duration = 30},
    {name = 'DroopyDortwin', maxLevel = 99, duration = 30},
    {name = 'SunburstMalfik', maxLevel = 99, duration = 30},
    {name = 'PonderingPeter', maxLevel = 99, duration = 30},
    {name = 'MosquitoFamilia', maxLevel = 99, duration = 30},
    {name = 'Left-HandedYoko', maxLevel = 99, duration = 30},
};

-- ============================================
-- Charm Calculation Constants (from PetMe)
-- ============================================

data.charmGear = {
    [17936] = 1, --De Saintre's Axe
    [17950] = 2, --Marid Ancus
    [12517] = 4, --Beast Helm
    [15157] = 5, --Bison Warbonnet
    [15158] = 6, --Brave's Warbonnet
    [16104] = 5, --Khimaira Bonnet
    [16105] = 6, --Stout Bonnet
    [15080] = 5, --Monster Helm
    [15233] = 4, --Beast Helm +1
    [15253] = 5, --Monster Helm +1
    [12646] = 5, --Beast Jackcoat
    [14418] = 5, --Bison Jacket
    [14419] = 6, --Brave's Jacket
    [14566] = 5, --Khimaira Jacket
    [14567] = 6, --Stout Jacket
    [15095] = 6, --Monster Jackcoat
    [14481] = 6, --Beast Jackcoat +1
    [14508] = 7, --Monster Jackcoat +1
    [13969] = 3, --Beast Gloves
    [14850] = 5, --Bison Wristbands
    [14851] = 6, --Brave's Wristbands
    [14981] = 5, --Khimaira Wristbands
    [14982] = 6, --Stout Wristbands
    [14898] = 3, --Beast Gloves +1
    [15110] = 4, --Monster Gloves
    [14917] = 4, --Monster Gloves +1
    [14222] = 6, --Beast Trousers
    [14319] = 5, --Bison Kecks
    [14320] = 6, --Brave's Kecks
    [15645] = 5, --Khimaira Kecks
    [15646] = 6, --Stout Kecks
    [15125] = 2, --Monster Trousers
    [15569] = 6, --Beast Trousers +1
    [15588] = 2, --Monster Trousers +1
    [14097] = 2, --Beast Gaiters
    [15307] = 5, --Bison Gamashes
    [15308] = 6, --Brave's Gamashes
    [15731] = 5, --Khimaira Gamashes
    [15732] = 6, --Stout Gamashes
    [15360] = 2, --Beast Gaiters +1
    [15140] = 3, --Monster Gaiters
    [15673] = 3, --Monster Gaiters +1
    [14658] = 4, --Atlaua's Ring
    [13667] = 5, --Trimmer's Mantle (HorizonXI only, when /BST)
};

data.dLevel = {
    {ld = -6, chg = 0.04},
    {ld = -5, chg = 0.08},
    {ld = -4, chg = 0.12},
    {ld = -3, chg = 0.16},
    {ld = -2, chg = 0.33},
    {ld = -1, chg = 0.66},
    {ld =  0, chg = 1.00},
    {ld =  1, chg = 1.40},
    {ld =  2, chg = 1.80},
    {ld =  3, chg = 2.20},
    {ld =  4, chg = 2.60},
    {ld =  5, chg = 3.00},
    {ld =  6, chg = 3.40},
    {ld =  7, chg = 4.00},
    {ld =  8, chg = 5.00},
    {ld =  9, chg = 6.00},
};

data.PacketID = {
    OUT_ACTION = 0x01A,
    OUT_CHECK = 0x0DD,
    IN_CHECK = 0x029,
};

data.ActionID = {
    CHARM = 0x34,
};

data.CharmState = {
    NONE = 0,
    SENDING_PACKET = 1,
    CHECK_PACKET = 2,
};

-- Build a lookup table for faster access
data.jugPetLookup = {};
for _, pet in ipairs(data.jugPets) do
    data.jugPetLookup[pet.name] = pet;
end

-- Get jug pet info by name
function data.GetJugPetInfo(petName)
    if petName == nil then return nil; end
    return data.jugPetLookup[petName];
end

-- Check if a pet name is a jug pet
function data.IsJugPet(petName)
    return data.GetJugPetInfo(petName) ~= nil;
end

-- Get pet level based on player level and pet type
function data.GetPetLevel(petName, playerLevel)
    if petName == nil or playerLevel == nil then return nil; end

    -- For jug pets, level is min(playerLevel, petMaxLevel)
    local jugInfo = data.GetJugPetInfo(petName);
    if jugInfo then
        return math.min(playerLevel, jugInfo.maxLevel);
    end

    -- For avatars/spirits, they match player's SMN level (main or sub)
    if data.petImageMap[petName] then
        return playerLevel;
    end

    -- For charmed pets, we can't know the level without tracking the charm action
    return nil;
end

-- ============================================
-- Pet Timer Tracking Functions
-- ============================================

-- Detect and track a new pet summon
function data.TrackPetSummon(petName, petJob)
    if petName == nil then
        -- Pet dismissed - clear tracking. Log the charm measurement first
        -- (uses petType/charmStartTime/lastPetHpPct before they're wiped).
        data.LogCharmMeasurement();
        data.petSummonTime = nil;
        data.petExpireTime = nil;
        data.petType = nil;
        data.lastTrackedPetName = nil;
        data.charmMobLevel = nil;
        data.charmMobCon = nil;
        data.charmReleased = false;
        data.lastPetHpPct = 0;

        -- Reset charm state only if we're not currently processing a charm
        if (data.charmState == data.CharmState.NONE) then
            data.charmTarget = nil;
            data.charmTargetIdx = nil;
        end

        -- NOTE: deliberately do NOT clear persisted jug timer data here. This
        -- branch fires whenever the pet ENTITY vanishes, which includes brief
        -- desyncs, zoning, and logout where the server keeps the jug alive and
        -- hands it back. Clearing here wiped a still-valid timer. The restore
        -- path's (savedExp > os.time()) guard already refuses stale records,
        -- so leaving them is safe and lets a surviving jug be restored. Charm
        -- timers are cleared above (charm pets never survive d/c anyway).
        return;
    end

    -- Only track if pet name changed (new summon)
    if petName == data.lastTrackedPetName then
        return;
    end

    data.lastTrackedPetName = petName;
    data.petSummonTime = os.time();

    -- Determine pet type and calculate expiration
    local jugInfo = data.GetJugPetInfo(petName);
    if jugInfo then
        data.petType = 'jug';
        -- Try to restore a saved timer (handles /reload, logout, brief d/c
        -- where the server kept the jug alive). Restore only if the saved
        -- name matches AND the saved expire is still in the future; otherwise
        -- compute fresh. Back-derive summon time so elapsed displays stay
        -- continuous rather than resetting to "just now".
        local savedName, savedExp = data.LoadJugState();
        if savedName == petName and savedExp and savedExp > os.time() then
            data.petExpireTime = savedExp;
            data.petSummonTime = savedExp - (jugInfo.duration * 60);
        else
            data.petExpireTime = data.petSummonTime + (jugInfo.duration * 60);
            data.SaveJugState(petName, data.petExpireTime);
        end
        data.charmExpireTime = nil;
    elseif petJob == data.JOB_BST and not data.petImageMap[petName] then
        -- BST pet that isn't an avatar = charmed pet
        data.petType = 'charm';
        data.petExpireTime = nil;
        -- data.charmExpireTime set via packet interception (calculateCharmTime)
        -- If we missed the packet (e.g. reload), we might not have a timer.
        if data.charmExpireTime == nil then
             -- Fallback or indicate unknown?
        end
    elseif petJob == data.JOB_SMN then
        data.petType = 'avatar';
        data.petExpireTime = nil;  -- Avatars don't expire on timer
        data.charmExpireTime = nil;
    elseif petJob == data.JOB_DRG then
        data.petType = 'wyvern';
        data.petExpireTime = nil;  -- Wyverns don't expire on timer
        data.charmExpireTime = nil;
    elseif petJob == data.JOB_PUP then
        data.petType = 'automaton';
        data.petExpireTime = nil;  -- Automatons don't expire on timer
        data.charmExpireTime = nil;
    else
        data.petType = nil;
        data.petExpireTime = nil;
        data.charmExpireTime = nil;
    end

    -- Persist timer data for session survival
    if gConfig then
        gConfig.petBarPetSummonTime = data.petSummonTime;
        gConfig.petBarPetExpireTime = data.petExpireTime;
        gConfig.petBarPetType = data.petType;
        gConfig.petBarPetName = petName;
        gConfig.petBarCharmExpireTime = data.charmExpireTime;
    end
end

-- Restore timers from persisted config (called on addon load)
function data.RestoreTimersFromConfig()
    if gConfig == nil then return; end

    -- Check if we have persisted timer data
    if gConfig.petBarPetSummonTime and gConfig.petBarPetName then
        local now = os.time();

        -- For jug pets, check if timer hasn't expired
        if gConfig.petBarPetExpireTime then
            if gConfig.petBarPetExpireTime > now then
                 -- Timer still valid, restore it
                data.petSummonTime = gConfig.petBarPetSummonTime;
                data.petExpireTime = gConfig.petBarPetExpireTime;
                data.petType = gConfig.petBarPetType;
                data.lastTrackedPetName = gConfig.petBarPetName;
                data.lastTrackedPetName = gConfig.petBarPetName;
                data.charmExpireTime = gConfig.petBarCharmExpireTime;
            else
                -- Timer expired, clear persisted data
                gConfig.petBarPetSummonTime = nil;
                gConfig.petBarPetExpireTime = nil;
                gConfig.petBarPetType = nil;
                gConfig.petBarPetName = nil;
                gConfig.petBarCharmExpireTime = nil;
            end
        elseif gConfig.petBarCharmExpireTime then
            -- Charm timer - restore if valid
            if gConfig.petBarCharmExpireTime > now then
                data.petSummonTime = gConfig.petBarPetSummonTime;
                data.petType = gConfig.petBarPetType;
                data.lastTrackedPetName = gConfig.petBarPetName;
                data.charmExpireTime = gConfig.petBarCharmExpireTime;
            else
                 -- Too old, clear
                gConfig.petBarPetSummonTime = nil;
                gConfig.petBarPetExpireTime = nil;
                gConfig.petBarPetType = nil;
                gConfig.petBarPetName = nil;
                gConfig.petBarCharmExpireTime = nil;
            end
        end
    end
end

-- Get remaining time for jug pet (in seconds)
function data.GetJugTimeRemaining()
    if data.petType ~= 'jug' or data.petExpireTime == nil then
        return nil;
    end
    local remaining = data.petExpireTime - os.time();
    return math.max(0, remaining);
end

-- Get remaining time for charm (in seconds)
function data.GetCharmTimeRemaining()
    if data.petType ~= 'charm' or data.charmExpireTime == nil then
        return nil;
    end
    local remaining = data.charmExpireTime - os.time();
    return math.max(0, remaining);
end

-- Format seconds to MM:SS string
function data.FormatTimeMMSS(seconds)
    if seconds == nil then return nil; end
    local mins = math.floor(seconds / 60);
    local secs = math.floor(seconds % 60);
    return string.format('%d:%02d', mins, secs);
end

-- Get settings key for a pet name (converts to lowercase, removes spaces)
function data.GetPetSettingsKey(petName)
    if petName == nil then return nil; end
    return petName:lower():gsub(' ', '');
end

-- Get the image path for a pet by name
function data.GetPetImagePath(petName)
    if petName == nil then return nil; end
    local imageFile = data.petImageMap[petName];
    if imageFile then
        return string.format('%s/assets/pets/%s', addon.path, imageFile);
    end
    return nil;
end

-- ============================================
-- State Variables
-- ============================================

-- Font objects (main pet bar)
data.nameText = nil;
data.distanceText = nil;
data.hpText = nil;
data.mpText = nil;
data.tpText = nil;
data.allFonts = nil;

-- Cached colors
data.lastNameColor = nil;
data.lastDistanceColor = nil;
data.lastHpColor = nil;
data.lastMpColor = nil;
data.lastTpColor = nil;

-- Pet target tracking (from packet data)
data.petTargetServerId = nil;

-- Current pet name (for image loading)
data.currentPetName = nil;

-- Pet timer tracking (jug pets and charm)
data.petSummonTime = nil;       -- os.time() when pet was summoned
data.petExpireTime = nil;       -- os.time() when pet will despawn (jug only)
data.petType = nil;             -- 'jug', 'charm', 'avatar', 'wyvern', 'automaton'
data.lastTrackedPetName = nil;  -- Track pet name changes to detect new summons
data.charmExpireTime = nil;     -- os.time() when charm expires
data.charmState = 0;            -- Packet interception state
data.charmTarget = nil;         -- Target ID for charm check
data.charmTargetIdx = nil;      -- Target Index for charm check
data.charmMobLevel = nil;       -- mob level captured from /check (nil if unknown)
data.charmMobCon = nil;         -- con type byte 0x40-0x47 from /check param2
data.charmReleased = false;     -- set when player issues Release
data.lastPetHpPct = 0;          -- last nonzero pet HP% (for death detection)
data.widescanLevels = {};       -- target index -> level, from 0x0F4 widescan

-- Background primitives
data.backgroundPrim = {};
data.loadedBgName = nil;

-- Pet image primitive (overlay on background)
data.petImagePrim = nil;

-- Pet image textures for ImGui rendering (used when clip mode enabled)
data.petImageTextures = {};

-- Clipped pet image render info (set by UpdateBackground, rendered by display)
data.clippedPetImageInfo = nil;

-- Recast timer tracking
data.recastMaxTimers = {};

-- Window positioning (shared with pet target)
data.lastMainWindowPosX = 0;
data.lastMainWindowBottom = 0;
data.lastTotalRowWidth = 150;
data.lastWindowFlags = nil;
data.lastColorConfig = nil;
data.lastSettings = nil;

-- Cached window flags
local baseWindowFlags = nil;

-- ============================================
-- Helper Functions
-- ============================================

-- Get cached base window flags
function data.getBaseWindowFlags()
    if baseWindowFlags == nil then
        baseWindowFlags = bit.bor(
            ImGuiWindowFlags_NoDecoration,
            ImGuiWindowFlags_AlwaysAutoResize,
            ImGuiWindowFlags_NoFocusOnAppearing,
            ImGuiWindowFlags_NoNav,
            ImGuiWindowFlags_NoBackground,
            ImGuiWindowFlags_NoBringToFrontOnFocus,
            ImGuiWindowFlags_NoDocking
        );
    end
    return baseWindowFlags;
end

-- Get pet entity from player's pet target index
function data.GetPetEntity()
    local playerEntity = GetPlayerEntity();
    if playerEntity == nil or playerEntity.PetTargetIndex == 0 then
        return nil;
    end
    return GetEntity(playerEntity.PetTargetIndex);
end

-- Get entity by server ID (optimized using packets.GetIndexFromId)
function data.GetEntityByServerId(sid)
    if sid == nil or sid == 0 then return nil; end
    local index = packets.GetIndexFromId(sid);
    if index == 0 then return nil; end
    return GetEntity(index);
end

-- Get primary pet job (main takes precedence)
function data.GetPetJob()
    local player = GetPlayerSafe();
    if player == nil then return nil; end

    local mainJob = player:GetMainJob();
    local subJob = player:GetSubJob();

    if mainJob == data.JOB_SMN or mainJob == data.JOB_BST or mainJob == data.JOB_DRG or mainJob == data.JOB_PUP then
        return mainJob;
    elseif subJob == data.JOB_SMN or subJob == data.JOB_BST or subJob == data.JOB_DRG or subJob == data.JOB_PUP then
        return subJob;
    end
    return nil;
end

-- Get pet type key for per-type settings lookup
-- Returns: 'avatar', 'charm', 'jug', 'automaton', 'wyvern' (defaults to 'avatar')
function data.GetPetTypeKey()
    -- Preview mode: derive from preview type
    if showConfig and showConfig[1] and gConfig.petBarPreview then
        local previewType = gConfig.petBarPreviewType or data.PREVIEW_AVATAR;
        if previewType == data.PREVIEW_WYVERN then
            return 'wyvern';
        elseif previewType == data.PREVIEW_AVATAR then
            return 'avatar';
        elseif previewType == data.PREVIEW_AUTOMATON then
            return 'automaton';
        elseif previewType == data.PREVIEW_JUG then
            return 'jug';
        elseif previewType == data.PREVIEW_CHARMED then
            return 'charm';
        end
        return 'avatar';
    end

    -- Real mode: use tracked pet type
    if data.petType then
        return data.petType;
    end

    -- Fallback: try to determine from current job
    local petJob = data.GetPetJob();
    if petJob == data.JOB_SMN then
        return 'avatar';
    elseif petJob == data.JOB_DRG then
        return 'wyvern';
    elseif petJob == data.JOB_PUP then
        return 'automaton';
    elseif petJob == data.JOB_BST then
        -- Default BST to jug (charm requires tracking)
        return 'jug';
    end

    return 'avatar';  -- Default fallback
end

-- Get pet data - single entry point for both preview and real data
-- This follows the partylist pattern where preview is handled inside the data function
function data.GetPetData()
    -- Preview check inside data function (like partylist's GetMemberInformation)
    if showConfig[1] and gConfig.petBarPreview then
        local previewType = gConfig.petBarPreviewType or data.PREVIEW_AVATAR;
        return data.GetPreviewPetData(previewType);
    end

    -- Real data
    local player = GetPlayerSafe();
    local party = GetPartySafe();
    local playerEnt = GetPlayerEntity();

    if player == nil or party == nil or playerEnt == nil then
        -- No pet - clear tracking
        data.TrackPetSummon(nil, nil);
        return nil;
    end

    if player.isZoning or player:GetMainJob() == 0 then
        return nil;
    end

    local pet = data.GetPetEntity();
    if pet == nil then
        -- No pet - clear tracking
        data.TrackPetSummon(nil, nil);
        return nil;
    end

    local petJob = data.GetPetJob();
    -- Only PUP automatons use MP in era (avatars don't)
    local showMp = petJob == data.JOB_PUP;
    local petName = pet.Name or 'Pet';

    -- Track pet summon for timer tracking
    data.TrackPetSummon(petName, petJob);

    -- Calculate pet level
    local playerLevel = player:GetMainJobLevel();
    if petJob and petJob ~= player:GetMainJob() then
        playerLevel = player:GetSubJobLevel();
    end
    local petLevel = data.GetPetLevel(petName, playerLevel);
    -- Charmed pets have no inherent level from GetPetLevel; use the level we
    -- captured from the /check fired on Charm (or widescan fallback).
    if data.petType == 'charm' and data.charmMobLevel then
        petLevel = data.charmMobLevel;
    end

    -- Check pet type and get timer info
    local isJug = data.IsJugPet(petName);
    local isCharmed = (data.petType == 'charm');
    local jugTimeRemaining = data.GetJugTimeRemaining();
    local charmElapsed = data.GetCharmElapsedTime();

    -- Track last nonzero pet HP% for charm death-vs-expiry detection.
    local petHp = pet.HPPercent or 0;
    if petHp > 0 then data.lastPetHpPct = petHp; end

    local petStatusIds, petStatusTimes = data.GetPetStatusEffects();

    return {
        name = petName,
        hpPercent = petHp,
        distance = math.sqrt(pet.Distance),
        mpPercent = player:GetPetMPPercent() or 0,
        tp = player:GetPetTP() or 0,
        job = petJob,
        showMp = showMp,
        -- New fields
        level = petLevel,
        isJug = isJug,
        isCharmed = isCharmed,
        jugTimeRemaining = jugTimeRemaining,
        charmElapsed = charmElapsed,
        charmTimeRemaining = data.GetCharmTimeRemaining(),
        isCharmCountDown = true,
        petType = data.petType,
        statusEffects = petStatusIds,
        statusEffectTimes = petStatusTimes,
    };
end

-- Format timer from raw recast value to readable string (mm:ss format)
-- Raw recast values are in 60ths of a second (60 units = 1 second)
function data.FormatTimer(rawTimer)
    if rawTimer <= 0 then return 'Ready'; end
    local totalSeconds = math.floor(rawTimer / 60);
    local mins = math.floor(totalSeconds / 60);
    local secs = totalSeconds % 60;
    if mins > 0 then
        return string.format('%d:%02d', mins, secs);
    else
        return string.format('%ds', secs);
    end
end

-- Format seconds into mm:ss
function data.FormatTimeMMSS(seconds)
    if (seconds == nil) then
        return '0:00';
    end
    local mins = math.floor(seconds / 60);
    local secs = seconds % 60;
    return string.format('%d:%02d', mins, secs);
end

-- Check if an ability should be shown based on config settings
local function ShouldShowAbility(name, petJob)
    if petJob == data.JOB_SMN then
        if name:find('Blood Pact') then
            if name:find('Rage') then
                return gConfig.petBarSmnShowBPRage ~= false;
            elseif name:find('Ward') then
                return gConfig.petBarSmnShowBPWard ~= false;
            else
                return gConfig.petBarSmnShowBPRage ~= false or gConfig.petBarSmnShowBPWard ~= false;
            end
        elseif name == 'Astral Flow' then return gConfig.petBarSmnShowAstralFlow ~= false;
        elseif name == 'Apogee' then return gConfig.petBarSmnShowApogee ~= false;
        elseif name == 'Mana Cede' then return gConfig.petBarSmnShowManaCede ~= false;
        end
    elseif petJob == data.JOB_BST then
        -- Ready and Sic share the same timer (ID 102), so we track as "Ready"
        if name == 'Ready' then return gConfig.petBarBstShowReady ~= false;
        elseif name == 'Reward' then return gConfig.petBarBstShowReward ~= false;
        elseif name == 'Call Beast' then return gConfig.petBarBstShowCallBeast ~= false;
        elseif name == 'Bestial Loyalty' then return gConfig.petBarBstShowBestialLoyalty ~= false;
        elseif name == 'Familiar' then return gConfig.petBarBstShowFamiliar ~= false;
        end
    elseif petJob == data.JOB_DRG then
        if name == 'Call Wyvern' then return gConfig.petBarDrgShowCallWyvern ~= false;
        elseif name == 'Spirit Link' then return gConfig.petBarDrgShowSpiritLink ~= false;
        elseif name == 'Deep Breathing' then return gConfig.petBarDrgShowDeepBreathing ~= false;
        elseif name == 'Steady Wing' then return gConfig.petBarDrgShowSteadyWing ~= false;
        elseif name == 'Spirit Surge' then return gConfig.petBarDrgShowSpiritSurge ~= false;
        end
    elseif petJob == data.JOB_PUP then
        if name == 'Activate' then return gConfig.petBarPupShowActivate ~= false;
        elseif name == 'Repair' then return gConfig.petBarPupShowRepair ~= false;
        elseif name == 'Deus Ex Automata' then return gConfig.petBarPupShowDeusExAutomata ~= false;
        elseif name == 'Deploy' then return gConfig.petBarPupShowDeploy ~= false;
        elseif name == 'Deactivate' then return gConfig.petBarPupShowDeactivate ~= false;
        elseif name == 'Retrieve' then return gConfig.petBarPupShowRetrieve ~= false;
        elseif name == 'Overdrive' then return gConfig.petBarPupShowOverdrive ~= false;
        end
    end
    return false;
end

-- Mock ability data for preview mode
local mockAbilities = {
    [data.JOB_SMN] = {
        {name = 'Astral Flow', timer = 0, maxTimer = 3600, isReady = true},
        {name = 'Blood Pact: Rage', timer = 0, maxTimer = 60, isReady = true},
        {name = 'Blood Pact: Ward', timer = 30, maxTimer = 60, isReady = false},
        {name = 'Apogee', timer = 0, maxTimer = 60, isReady = true},
        {name = 'Mana Cede', timer = 45, maxTimer = 60, isReady = false},
    },
    [data.JOB_BST] = {
        {name = 'Familiar', timer = 0, maxTimer = 3600, isReady = true},
        {name = 'Ready', timer = 2400, maxTimer = 5400, isReady = false,
            isChargeAbility = true, maxCharges = 3, charges = 2, nextChargeTimer = 600, chargeValue = 1800},
        {name = 'Reward', timer = 15, maxTimer = 90, isReady = false},
        {name = 'Call Beast', timer = 0, maxTimer = 60, isReady = true},
        {name = 'Bestial Loyalty', timer = 20, maxTimer = 60, isReady = false},
    },
    [data.JOB_DRG] = {
        {name = 'Spirit Surge', timer = 0, maxTimer = 3600, isReady = true},
        {name = 'Call Wyvern', timer = 0, maxTimer = 20, isReady = true},
        {name = 'Spirit Link', timer = 30, maxTimer = 120, isReady = false},
        {name = 'Deep Breathing', timer = 0, maxTimer = 60, isReady = true},
        {name = 'Steady Wing', timer = 40, maxTimer = 120, isReady = false},
    },
    [data.JOB_PUP] = {
        {name = 'Overdrive', timer = 0, maxTimer = 3600, isReady = true},
        {name = 'Activate', timer = 0, maxTimer = 60, isReady = true},
        {name = 'Repair', timer = 15, maxTimer = 180, isReady = false},
        {name = 'Deploy', timer = 0, maxTimer = 60, isReady = true},
        {name = 'Deactivate', timer = 25, maxTimer = 60, isReady = false},
        {name = 'Retrieve', timer = 10, maxTimer = 30, isReady = false},
        {name = 'Deus Ex Automata', timer = 0, maxTimer = 60, isReady = true},
    },
};

-- ============================================
-- Ability Recast (using shared library)
-- ============================================

-- Wrapper for shared library (maintains existing interface)
local function GetAbilityTimerById(timerId)
    return abilityRecast.GetAbilityTimerByTimerId(timerId);
end

-- Get job from preview type (for preview mode)
local function GetPreviewJob(previewType)
    if previewType == data.PREVIEW_WYVERN then
        return data.JOB_DRG;
    elseif previewType == data.PREVIEW_AVATAR then
        return data.JOB_SMN;
    elseif previewType == data.PREVIEW_AUTOMATON then
        return data.JOB_PUP;
    else -- PREVIEW_JUG or PREVIEW_CHARMED
        return data.JOB_BST;
    end
end

-- Get pet recasts - single entry point for both preview and real data
-- This follows the partylist pattern where preview is handled inside the data function
function data.GetPetRecasts()
    local timers = {};

    -- Preview check FIRST (before getting real job) - like partylist's GetMemberInformation
    if showConfig[1] and gConfig.petBarPreview then
        -- Derive job from preview type, not real player job
        local previewType = gConfig.petBarPreviewType or data.PREVIEW_AVATAR;
        local petJob = GetPreviewJob(previewType);

        local mockData = mockAbilities[petJob];
        if mockData then
            for _, ability in ipairs(mockData) do
                if ShouldShowAbility(ability.name, petJob) then
                    table.insert(timers, ability);
                end
            end
        end
        return timers;
    end

    -- Real mode: get actual pet job
    local petJob = data.GetPetJob();
    if not petJob then return timers; end

    -- Pet ability IDs for direct memory reading
    -- These are the ability recast timer IDs used by the game
    -- Reference: Windower Resources ability_recasts.lua
    local petAbilityIds = {
        [data.JOB_SMN] = {
            {id = 0, name = 'Astral Flow', maxTimer = 3600},        -- Timer ID 0 (shared 2hr/SP slot, all jobs)
            {id = 173, name = 'Blood Pact: Rage', maxTimer = 3600},  -- Timer ID 173
            {id = 174, name = 'Blood Pact: Ward', maxTimer = 3600},  -- Timer ID 174
            {id = 108, name = 'Apogee', maxTimer = 3600},           -- Timer ID 108
            {id = 71, name = 'Mana Cede', maxTimer = 3600},         -- Timer ID 71
        },
        [data.JOB_BST] = {
            {id = 0, name = 'Familiar', maxTimer = 3600},           -- Timer ID 0 (shared 2hr/SP slot)
            {id = 102, name = 'Ready', maxTimer = 1800},            -- Timer ID 102 (Ready/Sic share timer)
            {id = 103, name = 'Reward', maxTimer = 5400},           -- Timer ID 103
            {id = 104, name = 'Call Beast', maxTimer = 3600},       -- Timer ID 104
            {id = 104, name = 'Bestial Loyalty', maxTimer = 3600},  -- Timer ID 104 (shares with Call Beast)
        },
        [data.JOB_DRG] = {
            {id = 0, name = 'Spirit Surge', maxTimer = 3600},       -- Timer ID 0 (shared 2hr/SP slot)
            {id = 163, name = 'Call Wyvern', maxTimer = 72000},     -- Timer ID 163
            {id = 162, name = 'Spirit Link', maxTimer = 7200},      -- Timer ID 162
            {id = 164, name = 'Deep Breathing', maxTimer = 3600},   -- Timer ID 164
            {id = 70, name = 'Steady Wing', maxTimer = 7200},       -- Timer ID 70
        },
        [data.JOB_PUP] = {
            {id = 0, name = 'Overdrive', maxTimer = 3600},          -- Timer ID 0 (shared 2hr/SP slot)
            {id = 205, name = 'Activate', maxTimer = 3600},         -- Timer ID 205
            {id = 206, name = 'Repair', maxTimer = 10800},          -- Timer ID 206
            {id = 207, name = 'Deploy', maxTimer = 3600},           -- Timer ID 207
            {id = 208, name = 'Deactivate', maxTimer = 3600},       -- Timer ID 208
            {id = 209, name = 'Retrieve', maxTimer = 3600},         -- Timer ID 209
            {id = 115, name = 'Deus Ex Automata', maxTimer = 3600}, -- Timer ID 115
        },
    };

    local abilityList = petAbilityIds[petJob];
    if not abilityList then return timers; end

    -- Use direct memory reading to get ability timers (like PetMe)
    for _, abilityInfo in ipairs(abilityList) do
        local name = abilityInfo.name;

        if ShouldShowAbility(name, petJob) then
            local timer = GetAbilityTimerById(abilityInfo.id);
            if timer ~= nil then
                local maxTimer = abilityInfo.maxTimer;
                if timer > 0 then
                    if data.recastMaxTimers[name] == nil or timer > data.recastMaxTimers[name] then
                        data.recastMaxTimers[name] = timer;
                    end
                    maxTimer = data.recastMaxTimers[name] or maxTimer;
                else
                    data.recastMaxTimers[name] = nil;
                end

                local timerEntry = {
                    name = name,
                    timer = timer,
                    maxTimer = maxTimer,
                    formatted = data.FormatTimer(timer),
                    isReady = timer <= 0,
                };

                -- Add charge info for Ready ability
                if name == 'Ready' then
                    timerEntry.isChargeAbility = true;
                    timerEntry.maxCharges = data.READY_MAX_CHARGES;

                    -- Get timer data with modifier for accurate charge calculation
                    local timerData = abilityRecast.GetAbilityTimerDataByTimerId(abilityInfo.id);
                    local modifier = timerData.Modifier or 0;

                    -- Calculate base recast using config value and modifier (like PetMe)
                    -- Formula: baseRecast = 60 * (totalBaseSeconds + modifier) where totalBaseSeconds = perChargeSeconds * 3
                    local configBasePerCharge = gConfig.petBarReadyBaseRecast or data.READY_DEFAULT_BASE_SECONDS;
                    local totalBaseSeconds = configBasePerCharge * data.READY_MAX_CHARGES;
                    local baseRecast = 60 * (totalBaseSeconds + modifier);  -- In 1/60ths, modifier-adjusted
                    local chargeValue = baseRecast / data.READY_MAX_CHARGES;  -- Per-charge time in 1/60ths

                    -- Store chargeValue for progress bar calculations in display.lua
                    timerEntry.chargeValue = chargeValue;

                    -- Calculate current charges from timer
                    if timer <= 0 then
                        timerEntry.charges = data.READY_MAX_CHARGES;
                        timerEntry.nextChargeTimer = 0;
                    else
                        -- Charges available = max - ceil(timer / chargeValue)
                        local chargesRecharging = math.ceil(timer / chargeValue);
                        timerEntry.charges = math.max(0, data.READY_MAX_CHARGES - chargesRecharging);
                        -- Time until next charge = timer mod chargeValue (or timer if less than chargeValue)
                        timerEntry.nextChargeTimer = ((timer - 1) % chargeValue) + 1;
                    end
                end

                table.insert(timers, timerEntry);
            end
        end
    end

    return timers;
end

-- ============================================
-- Background Primitive Helpers
-- ============================================

-- Hide all background primitives
function data.HideBackground(bgOnly)
    -- Hide background and borders using windowbackground library
    windowBg.hide(data.backgroundPrim);

    -- bgOnly only suppresses the textured window background prims (imgui draws
    -- the panel/portrait), skipping the pet image primitives.
    if bgOnly then return; end

    -- Hide all pet image primitives (petbar-specific) - both layers
    if data.petImagePrims then
        for _, prim in pairs(data.petImagePrims) do
            if prim then
                prim.visible = false;
            end
        end
    end
    if data.petImagePrimsTop then
        for _, prim in pairs(data.petImagePrimsTop) do
            if prim then
                prim.visible = false;
            end
        end
    end
end

-- Update background primitives position and visibility.
-- bgOnly: only update the textured bg/border prims, skip the prim-based pet
-- portrait section (the portrait is drawn via imgui in data.DrawPetImage).
function data.UpdateBackground(x, y, width, height, settings, bgOnly)
    -- Get per-pet-type settings
    local petTypeKey = data.GetPetTypeKey();
    local settingsKey = 'petBar' .. petTypeKey:gsub("^%l", string.upper);  -- 'petBarAvatar', etc.
    local typeSettings = gConfig[settingsKey] or {};
    local typeColors = gConfig.colorCustomization and gConfig.colorCustomization[settingsKey] or {};

    -- Background theme/opacity from per-type settings with legacy fallback
    local bgTheme = typeSettings.backgroundTheme or gConfig.petBarBackgroundTheme or 'Window1';
    local bgOpacity = typeSettings.backgroundOpacity or gConfig.petBarBackgroundOpacity or 1.0;
    local borderOpacity = typeSettings.borderOpacity or gConfig.petBarBorderOpacity or 1.0;

    -- Colors from per-type settings with legacy fallback
    local bgColor = typeColors.bgColor or (gConfig.colorCustomization and gConfig.colorCustomization.petBar and gConfig.colorCustomization.petBar.bgColor) or 0xFFFFFFFF;
    local borderColor = typeColors.borderColor or (gConfig.colorCustomization and gConfig.colorCustomization.petBar and gConfig.colorCustomization.petBar.borderColor) or 0xFFFFFFFF;

    -- Get scale from per-type settings (like bgTheme, bgOpacity)
    local bgScale = typeSettings.bgScale or 1.0;
    local borderScale = typeSettings.borderScale or 1.0;

    -- Check if theme changed and reload textures if needed
    if data.loadedBgName ~= bgTheme then
        data.loadedBgName = bgTheme;
        windowBg.setTheme(data.backgroundPrim, bgTheme, bgScale, borderScale);
    end

    -- Common options for windowbackground library
    local bgOptions = {
        theme = bgTheme,
        -- padding/paddingY forced to 0 so the textured prim renders within
        -- the imgui window bounds, same footprint as the Plain theme. The
        -- theme selector only changes the fill, not the panel size.
        padding = 0,
        paddingY = 0,
        bgScale = bgScale,
        borderScale = borderScale,
        bgOpacity = bgOpacity,
        bgColor = bgColor,
        borderSize = settings.borderSize or 21,
        bgOffset = settings.bgOffset or 1,
        borderOpacity = borderOpacity,
        borderColor = borderColor,
    };

    -- Update background and borders using windowbackground library
    windowBg.update(data.backgroundPrim, x, y, width, height, bgOptions);

    if bgOnly then return; end

    -- Pet image overlay (petbar-specific - show correct avatar based on current pet)
    -- Clear clipped image info
    data.clippedPetImageInfo = nil;

    -- First hide all pet image primitives (both clipped and unclipped sets)
    if data.petImagePrims then
        for _, prim in pairs(data.petImagePrims) do
            if prim then
                prim.visible = false;
            end
        end
    end
    if data.petImagePrimsTop then
        for _, prim in pairs(data.petImagePrimsTop) do
            if prim then
                prim.visible = false;
            end
        end
    end

    -- Show current pet's image if we have one
    -- Check if image should be shown based on pet type settings
    local showImage = false;
    local petImageScale, petImageOpacity, petImageOffsetX, petImageOffsetY, clipToBackground;

    if data.currentPetName and data.petImagePrims then
        local petKey = data.GetPetSettingsKey(data.currentPetName);
        local petTypeKey = data.GetPetTypeKey();  -- Get type by job, not name

        -- For wyvern, use wyvern-specific settings from petBarWyvern
        -- Use petTypeKey (job-based) instead of petKey (name-based) to handle renamed wyverns
        if petTypeKey == 'wyvern' then
            -- Override petKey to 'wyvern' for primitive lookup (handles renamed wyverns)
            petKey = 'wyvern';
            local wyvernSettings = gConfig.petBarWyvern or {};
            showImage = wyvernSettings.showImage or false;
            petImageScale = wyvernSettings.imageScale or 0.4;
            petImageOpacity = wyvernSettings.imageOpacity or 0.3;
            petImageOffsetX = wyvernSettings.imageOffsetX or 0;
            petImageOffsetY = wyvernSettings.imageOffsetY or 0;
            clipToBackground = wyvernSettings.imageClipToBackground or false;
        else
            -- For avatars/spirits, use the existing avatar settings system
            showImage = gConfig.petBarShowImage or false;
            local avatarSettings = gConfig.petBarAvatarSettings and gConfig.petBarAvatarSettings[petKey];

            if avatarSettings then
                petImageScale = avatarSettings.scale or 0.4;
                petImageOpacity = avatarSettings.opacity or 0.3;
                petImageOffsetX = avatarSettings.offsetX or 0;
                petImageOffsetY = avatarSettings.offsetY or 0;
                clipToBackground = avatarSettings.clipToBackground or false;
            else
                -- Fall back to legacy global settings
                petImageScale = gConfig.petBarImageScale or 0.4;
                petImageOpacity = gConfig.petBarImageOpacity or 0.3;
                petImageOffsetX = gConfig.petBarImageOffsetX or 0;
                petImageOffsetY = gConfig.petBarImageOffsetY or 0;
                clipToBackground = false;
            end
        end
    end

    if showImage and data.currentPetName and data.petImagePrims then
        local petKey = data.GetPetSettingsKey(data.currentPetName);
        local petTypeKey = data.GetPetTypeKey();
        -- For wyvern, use 'wyvern' key to handle renamed wyverns
        if petTypeKey == 'wyvern' then
            petKey = 'wyvern';
        end
        local primMiddle = data.petImagePrims[petKey];  -- Middle layer (for clipped)
        local primTop = data.petImagePrimsTop and data.petImagePrimsTop[petKey];  -- Top layer (for unclipped)

        -- Use middle layer prim for dimensions, but choose which to show based on clip setting
        local prim = primMiddle;
        if prim and prim.exists then

            -- Calculate base image position and dimensions
            local imgX = x + petImageOffsetX;
            local imgY = y + petImageOffsetY;
            local baseWidth = prim.baseWidth or 256;
            local baseHeight = prim.baseHeight or 256;

            -- Convert 0-1 opacity to alpha byte (0x00-0xFF), keep RGB as white
            local alphaByte = math.floor(petImageOpacity * 255);
            local primColor = bit.bor(bit.lshift(alphaByte, 24), 0x00FFFFFF);

            if clipToBackground then
                -- Use middle layer primitive (renders behind borders), clipped to background
                local clipBounds = windowBg.getClipBounds(x, y, width, height, {
                    theme = bgTheme,
                    padding = 0,    -- match Plain size; theme only changes fill
                    paddingY = 0,
                    bgOffset = settings.bgOffset or 1,
                });

                local clipped = windowBg.clipImageToBounds(imgX, imgY, baseWidth * petImageScale, baseHeight * petImageScale, clipBounds, petImageScale);

                if clipped then
                    primMiddle.visible = true;
                    primMiddle.position_x = clipped.x;
                    primMiddle.position_y = clipped.y;
                    primMiddle.texture_offset_x = clipped.texOffsetX;
                    primMiddle.texture_offset_y = clipped.texOffsetY;
                    primMiddle.width = clipped.width;
                    primMiddle.height = clipped.height;
                    primMiddle.scale_x = clipped.scaleX;
                    primMiddle.scale_y = clipped.scaleY;
                    primMiddle.color = primColor;
                end
            else
                -- Use top layer primitive (renders on top of borders), no clipping
                if primTop then
                    primTop.visible = true;
                    primTop.position_x = imgX;
                    primTop.position_y = imgY;
                    primTop.texture_offset_x = 0;
                    primTop.texture_offset_y = 0;
                    primTop.width = baseWidth;
                    primTop.height = baseHeight;
                    primTop.scale_x = petImageScale;
                    primTop.scale_y = petImageScale;
                    primTop.color = primColor;
                end
            end
        end
    end
end

-- ============================================
-- Pet Portrait (imgui draw)
-- ============================================
-- Draws the pet portrait via imgui AddImage on the supplied draw list so it
-- shows on the panel. Resolves the same per-pet settings as UpdateBackground
-- (unclipped/top-layer behavior only).
function data.DrawPetImage(drawList, x, y, width, height)
    if drawList == nil then return; end
    if not (data.currentPetName and data.petImageTextures) then return; end

    local petKey = data.GetPetSettingsKey(data.currentPetName);
    local petTypeKey = data.GetPetTypeKey();
    local showImage, scale, opacity, offX, offY, clip = false, 0.4, 0.3, 0, 0, false;

    if petTypeKey == 'wyvern' then
        petKey = 'wyvern';
        local ws = gConfig.petBarWyvern or {};
        showImage = ws.showImage or false;
        scale     = ws.imageScale or 0.4;
        opacity   = ws.imageOpacity or 0.3;
        offX      = ws.imageOffsetX or 0;
        offY      = ws.imageOffsetY or 0;
        clip      = ws.imageClipToBackground or false;
    else
        showImage = gConfig.petBarShowImage or false;
        local av = gConfig.petBarAvatarSettings and gConfig.petBarAvatarSettings[petKey];
        if av then
            scale   = av.scale or 0.4;
            opacity = av.opacity or 0.3;
            offX    = av.offsetX or 0;
            offY    = av.offsetY or 0;
            clip    = av.clipToBackground or false;
        else
            scale   = gConfig.petBarImageScale or 0.4;
            opacity = gConfig.petBarImageOpacity or 0.3;
            offX    = gConfig.petBarImageOffsetX or 0;
            offY    = gConfig.petBarImageOffsetY or 0;
        end
    end

    if not showImage then return; end

    local tex = data.petImageTextures[petKey];
    if not (tex and tex.image) then return; end

    -- Match the prim's base dimensions for parity with classic rendering.
    local prim = data.petImagePrims and data.petImagePrims[petKey];
    local baseW = (prim and prim.baseWidth) or 256;
    local baseH = (prim and prim.baseHeight) or 256;
    local imgX = x + offX;
    local imgY = y + offY;
    local drawW = baseW * scale;
    local drawH = baseH * scale;

    local alphaByte = math.floor(math.max(0, math.min(1, opacity)) * 255);
    local imgColor = bit.bor(bit.lshift(alphaByte, 24), 0x00FFFFFF);

    -- UV coords (default full texture).
    local u0, v0, u1, v1 = 0, 0, 1, 1;
    local x0, y0, x1, y1 = imgX, imgY, imgX + drawW, imgY + drawH;

    -- Clip-to-background: the "background" is the imgui panel (the window
    -- rect x,y,width,height). Intersect the image rect with the window rect and
    -- adjust UVs proportionally so the portrait is cropped to the panel instead of
    -- overflowing it. (imgui PushClipRect binding isn't available here, so clip by
    -- math.) Requires a valid width/height to clip against.
    if clip and width and height and width > 0 and height > 0 then
        local wx0, wy0, wx1, wy1 = x, y, x + width, y + height;
        local cx0 = math.max(x0, wx0);
        local cy0 = math.max(y0, wy0);
        local cx1 = math.min(x1, wx1);
        local cy1 = math.min(y1, wy1);
        if cx1 <= cx0 or cy1 <= cy0 then return; end  -- fully outside
        -- Remap UVs to the cropped rectangle.
        u0 = (cx0 - x0) / drawW;
        v0 = (cy0 - y0) / drawH;
        u1 = (cx1 - x0) / drawW;
        v1 = (cy1 - y0) / drawH;
        x0, y0, x1, y1 = cx0, cy0, cx1, cy1;
    end

    drawList:AddImage(
        tonumber(ffi.cast("uint32_t", tex.image)),
        {x0, y0},
        {x1, y1},
        {u0, v0}, {u1, v1},
        imgColor
    );
end

-- ============================================
-- Font Visibility Helper
-- ============================================

function data.SetAllFontsVisible(visible)
    if data.allFonts then
        SetFontsVisible(data.allFonts, visible);
    end
end

-- ============================================
-- Clear Cached Colors
-- ============================================

function data.ClearColorCache()
    data.lastNameColor = nil;
    data.lastDistanceColor = nil;
    data.lastHpColor = nil;
    data.lastMpColor = nil;
    data.lastTpColor = nil;
    data.lastBstTimerColor = nil;
    data.lastPetStatusColor = nil;
end

-- ============================================
-- Preview Mock Data
-- ============================================

-- Returns mock pet data for preview mode
-- Returns values that match what DrawWindow expects from real pet data
function data.GetPreviewPetData(previewType)
    local mockData = {
        name = 'Pet',
        hpPercent = 85,
        distance = 5.2,
        mpPercent = 75,
        tp = 1200,
        job = nil,
        showMp = false,
        isCharmed = false,
        isJug = false,
        level = nil,
        jugTimeRemaining = nil,
        charmElapsed = nil,
        petType = nil,
    };

    if previewType == data.PREVIEW_WYVERN then
        mockData.name = 'Wyvern';
        mockData.hpPercent = 85;
        mockData.distance = 5.2;
        mockData.mpPercent = 0;
        mockData.tp = 1200;
        mockData.job = data.JOB_DRG;
        mockData.showMp = false;
        mockData.level = 75;
        mockData.petType = 'wyvern';
    elseif previewType == data.PREVIEW_AVATAR then
        -- Use selected avatar from config, default to first in list (Carbuncle)
        mockData.name = gConfig.petBarPreviewAvatar or data.avatarList[1];
        mockData.hpPercent = 100;
        mockData.distance = 8.5;
        mockData.mpPercent = 0;
        mockData.tp = 800;
        mockData.job = data.JOB_SMN;
        mockData.showMp = false;  -- Avatars don't use MP in era
        mockData.level = 75;
        mockData.petType = 'avatar';
    elseif previewType == data.PREVIEW_AUTOMATON then
        mockData.name = 'Automaton';
        mockData.hpPercent = 90;
        mockData.distance = 3.1;
        mockData.mpPercent = 60;
        mockData.tp = 1500;
        mockData.job = data.JOB_PUP;
        mockData.showMp = true;
        mockData.level = 75;
        mockData.petType = 'automaton';
    elseif previewType == data.PREVIEW_JUG then
        mockData.name = 'FunguarFamiliar';
        mockData.hpPercent = 70;
        mockData.distance = 6.8;
        mockData.mpPercent = 0;
        mockData.tp = 500;
        mockData.job = data.JOB_BST;
        mockData.showMp = false;
        mockData.isJug = true;
        mockData.level = 35;  -- FunguarFamiliar max level
        mockData.jugTimeRemaining = 213;  -- preview: static 3:33 sample
        mockData.petType = 'jug';
    elseif previewType == data.PREVIEW_CHARMED then
        mockData.name = 'Forest Hare';
        mockData.hpPercent = 45;
        mockData.distance = 4.5;
        mockData.mpPercent = 0;
        mockData.tp = 2000;
        mockData.job = data.JOB_BST;
        mockData.showMp = false;
        mockData.isCharmed = true;
        mockData.level = nil;  -- Unknown for charmed pets
        mockData.petType = 'charm';
        mockData.charmTimeRemaining = 213;  -- preview: static 3:33 countdown sample
        mockData.isCharmCountDown = true;
    end

    return mockData;
end

-- ============================================
-- State Reset
-- ============================================

function data.Reset()
    data.nameText = nil;
    data.distanceText = nil;
    data.hpText = nil;
    data.mpText = nil;
    data.tpText = nil;
    data.petStatusText = nil;
    data.allFonts = nil;
    data.backgroundPrim = {};
    data.petImagePrim = nil;
    data.petImageTextures = {};
    data.clippedPetImageInfo = nil;
    data.petTargetServerId = nil;
    data.currentPetName = nil;
    data.recastMaxTimers = {};
    data.loadedBgName = nil;
    -- Pet timer tracking reset
    data.petSummonTime = nil;
    data.petExpireTime = nil;
    data.petType = nil;
    data.lastTrackedPetName = nil;
    data.charmStartTime = nil;
    data.charmExpireTime = nil;
    data.ClearColorCache();
end

-- ============================================
-- Charm Calculation Functions
-- ============================================

function data.GetCharmElapsedTime()
    if (data.charmStartTime == nil) then
        return 0;
    end
    return os.time() - data.charmStartTime;
end



function data.getCharmEquipValue()
    local charmValue = 0;

    for i = 0, 15 do
        local equippedItem = AshitaCore:GetMemoryManager():GetInventory():GetEquippedItem(i);
        local index = bit.band(equippedItem.Index, 0x00FF);
        if index > 0 then
            local container = bit.rshift(bit.band(equippedItem.Index, 0xFF00), 8);
            local item = AshitaCore:GetMemoryManager():GetInventory():GetContainerItem(container, index);
            if (item ~= nil and data.charmGear[item.Id] ~= nil) then
                charmValue = charmValue + data.charmGear[item.Id];
            end
        end
    end

    return charmValue;
end

-- LSB charm-duration level multiplier (continuous quintic fit). Replaces the
-- old discrete data.dLevel table lookup. Validated against HorizonXI live data:
-- CHR 24, char level 21, Lv.18 mob -> ~393s; observed ~6 min in-game. Horizon
-- uses the player's MAIN/character level for the dLvl (BST level only affects
-- charm *chance*, not duration).
--   dLvl <= -7 : 1/24
--   -6..8      : quintic fit (r^2 > 0.999, from BG-wiki data)
--   dLvl >= 9  : 6.0 cap
function data.CharmDLvlMultiplier(d)
    if (d <= -7) then
        return 1 / 24;
    elseif (d >= 9) then
        return 6.0;
    end
    return 0.9997336 + 0.3652882 * d + 0.02097742 * d ^ 2
         - 0.004106429 * d ^ 3 + 0.000007231037 * d ^ 4
         + 0.00005102634 * d ^ 5;
end

function data.calculateCharmTime(mobLevel)
    -- Set base values
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    local playerLvl = player:GetMainJobLevel();
    local baseChr   = player:GetStat(6);

    -- Stash the mob level so the HUD can display it and the logger can record
    -- it. Stored even if 0/unknown; callers treat <=0 as "unknown".
    data.charmMobLevel = (mobLevel and mobLevel > 0) and mobLevel or nil;

    -- calculate level difference between player & pet (continuous, clamped
    -- inside the multiplier function rather than here).
    local levelDifference = playerLvl - (mobLevel or 0);
    local lvlModifier = data.CharmDLvlMultiplier(levelDifference);

    --Base Charm Duration (seconds) = floor(1.25 × CHR + 150 )
    local baseCharmDuration = math.floor(1.25 * baseChr + 150);
    --Pre-Gear Charm Duration = Base Charm Duration × multiplier
    local preGearDuration = baseCharmDuration * lvlModifier;
    --Charm Duration = Pre-gear Charm Duration × ( 1 + 0.05×(Charm+ in gear) )
    local charmDuration = preGearDuration * (1 + (0.05 * data.getCharmEquipValue()));

    return os.time() + math.floor(charmDuration);
end

-- ============================================
-- Charm Duration Measurement Logger
-- ============================================
-- Appends one line per charm that ends to <addon>/chartdebug.txt, to verify
-- the formula against live behavior. Outcome inferred:
--   died     -> last seen pet HP was 0 (killed)
--   released -> player issued Release
--   expired  -> vanished with HP > 0 and no release = charm timer ran out
-- Only logs charm-type pets with a real start time.
function data.LogCharmMeasurement()
    if data.petType ~= 'charm' then return; end
    if data.charmStartTime == nil or data.charmStartTime <= 0 then return; end

    local elapsed = os.time() - data.charmStartTime;
    local outcome;
    if data.charmReleased then
        outcome = 'released';
    elseif (data.lastPetHpPct or 0) <= 0 then
        outcome = 'died';
    else
        outcome = 'expired';
    end

    -- Predicted duration for comparison (formula when level known).
    local predicted = '?';
    if data.charmMobLevel then
        local exp = data.calculateCharmTime(data.charmMobLevel);
        predicted = tostring(exp - os.time());
    end

    local conNames = {
        [0x40] = 'TooWeak', [0x41] = 'IncrEasyPrey', [0x42] = 'EasyPrey',
        [0x43] = 'DecentChallenge', [0x44] = 'EvenMatch', [0x45] = 'Tough',
        [0x46] = 'VeryTough', [0x47] = 'IncrTough',
    };
    local conName = conNames[data.charmMobCon or -1] or 'unknown';

    local line = string.format(
        '%s,%s,con=%s,lvl=%s,measured_s=%d,predicted_s=%s,outcome=%s,last_hp=%d\n',
        os.date('%Y-%m-%d %H:%M:%S'),
        tostring(data.lastTrackedPetName or '?'),
        conName,
        tostring(data.charmMobLevel or '?'),
        elapsed,
        predicted,
        outcome,
        data.lastPetHpPct or 0);

    local ok, path = pcall(function() return ('%s/chartdebug.txt'):format(addon.path); end);
    if not ok or not path then path = 'chartdebug.txt'; end
    local f = io.open(path, 'a');
    if f then
        f:write(line);
        f:close();
    end
end

-- Familiar (BST 2-hour). Per HorizonXI: while active, a charmed pet stays for
-- a total of 30 minutes FROM THE START OF THE CHARM, regardless of level
-- difference. So this is a hard SET to start+1800s, NOT an additive bonus on
-- top of the level-diff formula. Falls back to now+1800 if start is unknown.
function data.ApplyFamiliarCharmExtension()
    if data.petType ~= 'charm' then return; end
    local base = data.charmStartTime or os.time();
    data.charmExpireTime = base + 1800;
    if gConfig then
        gConfig.petBarCharmExpireTime = data.charmExpireTime;
    end
end

-- ============================================
-- Pet Status Effects Reader
-- ============================================
-- Primary path: the packet-driven petBuffHandler (handlers.petbuffhandler),
-- which tracks pet buffs (with durations) and debuffs (icon-only) from action
-- and message packets. Returns (ids, times) where times[i] is remaining secs
-- for buffs or nil for debuffs. Falls back to a direct memory probe of the
-- pet status array if the handler isn't present on this build.
local petBuffHandler;
do
    local ok, mod = pcall(require, 'handlers.petbuffhandler');
    if ok then petBuffHandler = mod; end
end

function data.GetPetStatusEffects()
    -- Primary: handler state (packet-tracked, has durations).
    if petBuffHandler and petBuffHandler.GetActiveEffects then
        local ok, ids, times = pcall(petBuffHandler.GetActiveEffects);
        if ok then return ids or {}, times or {}; end
    end

    -- Fallback: probe pet status array directly from memory (no durations).
    local ids = {};
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if player == nil then return ids, {}; end

    local ok, icons = pcall(function()
        if player.GetPetStatusIcons ~= nil then return player:GetPetStatusIcons(); end
        if player.GetPetBuffs      ~= nil then return player:GetPetBuffs(); end
        return nil;
    end);
    if not ok or icons == nil then return ids, {}; end

    for i = 0, 31 do
        local v;
        if type(icons) == 'table' then
            v = icons[i + 1] or icons[i];
        else
            v = icons[i];
        end
        if v and v ~= 255 and v ~= 0xFFFF and v ~= 0 then
            ids[#ids + 1] = v;
        end
    end
    return ids, {};
end

-- Resolve a status-effect id to its display name (cached). Tries the resource
-- manager's status-icon table, then the older GetString path; falls back to
-- '#<id>' if neither resolves. Ported from bsthud.status_name.
local statusNameCache = {};
function data.GetStatusEffectName(id)
    if id == nil then return ''; end
    local cached = statusNameCache[id];
    if cached ~= nil then return cached; end
    local name;
    local resMgr = AshitaCore and AshitaCore:GetResourceManager() or nil;
    if resMgr ~= nil then
        local ok, buff = pcall(function() return resMgr:GetStatusIconByIndex(id); end);
        if ok and buff and buff.Name and buff.Name[1] then
            name = buff.Name[1];
        else
            local ok2, s = pcall(function() return resMgr:GetString('buffs.names', id); end);
            if ok2 and s and s ~= '' then name = s; end
        end
    end
    name = name or ('#' .. tostring(id));
    statusNameCache[id] = name;
    return name;
end

-- ============================================
-- Per-Character Jug Persistence (ported from bsthud)
-- ============================================
-- XIUI's stock persistence keyed jug timers to gConfig (one slot, shared
-- across every character on the install) and cleared them the instant the pet
-- entity vanished -- which wipes a still-valid jug on a brief desync, zone, or
-- logout where the server keeps the jug alive. This adds a per-character file
-- ({addon}/bsthud_jug_<serverId>.dat) that survives those events, restored
-- only when the saved name matches and the expire is still in the future.
-- Charm pets are intentionally NOT persisted (they always despawn on d/c).

function data.JugPersistPath()
    local sid = nil;
    pcall(function()
        local party = GetPartySafe and GetPartySafe() or AshitaCore:GetMemoryManager():GetParty();
        if party then sid = party:GetMemberServerId(0); end
    end);
    if sid == nil or sid == 0 then return nil; end
    return string.format('%s/bsthud_jug_%d.dat', addon.path, sid);
end

function data.SaveJugState(name, expireTime)
    local path = data.JugPersistPath();
    if not path then return; end
    local f = io.open(path, 'w');
    if not f then return; end
    f:write(tostring(name), '\n', tostring(math.floor(expireTime)), '\n');
    f:close();
end

function data.LoadJugState()
    local path = data.JugPersistPath();
    if not path then return nil; end
    local f = io.open(path, 'r');
    if not f then return nil; end
    local name = f:read('*l');
    local expS = f:read('*l');
    f:close();
    if not name or not expS then return nil; end
    local exp = tonumber(expS);
    if not exp then return nil; end
    return name, exp;
end

function data.ClearJugState()
    local path = data.JugPersistPath();
    if not path then return; end
    local ok = os.remove(path);
    if ok then return; end
    -- Deletion failed (locked / sync tool reverting). Overwrite with an
    -- expired sentinel so a later LoadJugState can't restore stale data.
    local f = io.open(path, 'w');
    if f then
        f:write('__cleared__\n0\n');
        f:close();
    end
end

-- ============================================
-- Clickable Ability Commands (ported from bsthud)
-- ============================================
-- Maps an ability display name to the chat command that fires it. Most are
-- static strings; SMN Blood Pacts resolve at click time from per-avatar
-- favorites (gConfig.petBarSmnBloodPacts[avatarName].{rage,ward}), returning
-- nil when no favorite is set (row then isn't clickable). 2-hour abilities
-- are flagged confirm=true so display requires a two-click arm/fire.
data.ABILITY_COMMANDS = {
    -- SMN
    ['Blood Pact: Rage'] = { confirm = false, resolve = function()
        local pet = data.currentPetName;
        if not pet then return nil; end
        local fav = gConfig.petBarSmnBloodPacts and gConfig.petBarSmnBloodPacts[pet];
        local bp = fav and fav.rage and fav.rage:match('^%s*(.-)%s*$') or nil;
        if not bp or bp == '' then return nil; end
        return string.format('/pet "%s" <t>', bp);
    end },
    ['Blood Pact: Ward'] = { confirm = false, resolve = function()
        local pet = data.currentPetName;
        if not pet then return nil; end
        local fav = gConfig.petBarSmnBloodPacts and gConfig.petBarSmnBloodPacts[pet];
        local bp = fav and fav.ward and fav.ward:match('^%s*(.-)%s*$') or nil;
        if not bp or bp == '' then return nil; end
        return string.format('/pet "%s" <me>', bp);
    end },
    ['Apogee']       = { cmd = '/ja "Apogee" <me>' },
    ['Mana Cede']    = { cmd = '/ja "Mana Cede" <me>' },
    ['Astral Flow']  = { cmd = '/ja "Astral Flow" <me>', confirm = true },
    -- BST
    ['Reward']           = { cmd = '/ja "Reward" <t>' },
    ['Call Beast']       = { cmd = '/ja "Call Beast" <me>' },
    ['Bestial Loyalty']  = { cmd = '/ja "Bestial Loyalty" <me>' },
    ['Familiar']         = { cmd = '/ja "Familiar" <me>', confirm = true },
    -- DRG
    ['Call Wyvern']    = { cmd = '/ja "Call Wyvern" <me>' },
    ['Spirit Link']    = { cmd = '/ja "Spirit Link" <me>' },
    ['Deep Breathing'] = { cmd = '/ja "Deep Breathing" <me>' },
    ['Steady Wing']    = { cmd = '/ja "Steady Wing" <me>' },
    ['Spirit Surge']   = { cmd = '/ja "Spirit Surge" <me>', confirm = true },
    -- PUP
    ['Activate']           = { cmd = '/ja "Activate" <me>' },
    ['Repair']             = { cmd = '/ja "Repair" <me>' },
    ['Deus Ex Automata']   = { cmd = '/ja "Deus Ex Automata" <me>' },
    ['Deploy']             = { cmd = '/ja "Deploy" <t>' },
    ['Deactivate']         = { cmd = '/ja "Deactivate" <me>' },
    ['Retrieve']           = { cmd = '/ja "Retrieve" <me>' },
    ['Overdrive']          = { cmd = '/ja "Overdrive" <me>', confirm = true },
};

-- Two-click confirm state for 2-hour abilities. Keyed by ability name; armed
-- entries auto-disarm after 4 seconds.
data.clickConfirmName = nil;
data.clickConfirmTime = 0;

-- Resolve an ability name to (command, needsConfirm). Returns nil command when
-- the ability isn't clickable (unknown, or a BP with no favorite set).
function data.ResolveAbilityCommand(name)
    local entry = data.ABILITY_COMMANDS[name];
    if not entry then return nil, false; end
    local cmd = entry.cmd;
    if entry.resolve then
        local ok, r = pcall(entry.resolve);
        cmd = ok and r or nil;
    end
    return cmd, (entry.confirm == true);
end

-- Handle a click on an ability row. Returns true if a command was fired (so
-- the caller can give feedback). For confirm abilities: first click arms,
-- second click within 4s fires.
function data.FireAbilityClick(name)
    local cmd, needsConfirm = data.ResolveAbilityCommand(name);
    if not cmd then return false; end

    if needsConfirm then
        if data.clickConfirmName == name and (os.clock() - data.clickConfirmTime) <= 5.0 then
            AshitaCore:GetChatManager():QueueCommand(-1, cmd);
            data.clickConfirmName = nil;
            return true;
        else
            data.clickConfirmName = name;
            data.clickConfirmTime = os.clock();
            return false;  -- armed, not fired
        end
    end

    AshitaCore:GetChatManager():QueueCommand(-1, cmd);
    return true;
end

-- Is this ability currently armed (for display highlight)?
function data.IsAbilityArmed(name)
    if data.clickConfirmName ~= name then return false; end
    if (os.clock() - data.clickConfirmTime) > 5.0 then
        data.clickConfirmName = nil;
        return false;
    end
    return true;
end

-- ============================================
-- Per-Avatar Blood Pact Lists (HorizonXI, level <=75)
-- ============================================
-- Sourced from https://horizonffxi.wiki/Blood_Pact (read, not guessed).
-- Split into Rage (damage/enfeeble offensive) and Ward (restoring/enhancing/
-- support) to match the in-game pet command menu. Used to populate the BP
-- favorite dropdowns in config. Astral Flow pacts and >75 abilities excluded.
data.bloodPacts = {
    ['Carbuncle'] = {
        rage = { 'Poison Nails', 'Meteorite' },
        ward = { 'Healing Ruby', 'Shining Ruby', 'Glittering Ruby', 'Healing Ruby II' },
    },
    ['Fenrir'] = {
        rage = { 'Moonlit Charge', 'Crescent Fang', 'Lunar Cry', 'Lunar Roar', 'Eclipse Bite' },
        ward = { 'Ecliptic Growl', 'Ecliptic Howl' },
    },
    ['Ifrit'] = {
        rage = { 'Punch', 'Fire II', 'Burning Strike', 'Double Punch', 'Fire IV', 'Flaming Crush', 'Meteor Strike' },
        ward = { 'Crimson Howl' },
    },
    ['Titan'] = {
        rage = { 'Rock Throw', 'Stone II', 'Rock Buster', 'Megalith Throw', 'Stone IV', 'Mountain Buster', 'Geocrush' },
        ward = { 'Earthen Ward' },
    },
    ['Leviathan'] = {
        rage = { 'Barracuda Dive', 'Water II', 'Tail Whip', 'Slowga', 'Water IV', 'Spinning Dive', 'Grand Fall' },
        ward = { 'Spring Water' },
    },
    ['Garuda'] = {
        rage = { 'Claw', 'Aero II', 'Aero IV', 'Predator Claws', 'Wind Blade' },
        ward = { 'Aerial Armor', 'Whispering Wind', 'Hastega' },
    },
    ['Shiva'] = {
        rage = { 'Axe Kick', 'Blizzard II', 'Sleepga', 'Double Slap', 'Blizzard IV', 'Rush', 'Heavenly Strike' },
        ward = { 'Frost Armor' },
    },
    ['Ramuh'] = {
        rage = { 'Shock Strike', 'Thunder II', 'Thunderspark', 'Thunder IV', 'Chaotic Strike', 'Thunderstorm' },
        ward = { 'Rolling Thunder', 'Lightning Armor' },
    },
    ['Diabolos'] = {
        rage = { 'Camisado', 'Somnolence', 'Nightmare', 'Ultimate Terror', 'Nether Blast' },
        ward = { 'Noctoshield', 'Dream Shroud' },
    },
};

-- Returns the rage/ward BP name lists for an avatar, each prefixed with a
-- '(none)' option so a favorite can be cleared. Empty tables for non-avatars.
function data.GetBloodPactChoices(avatarName)
    local bp = data.bloodPacts[avatarName];
    local rage = { '(none)' };
    local ward = { '(none)' };
    if bp then
        for _, n in ipairs(bp.rage) do rage[#rage + 1] = n; end
        for _, n in ipairs(bp.ward) do ward[#ward + 1] = n; end
    end
    return rage, ward;
end

-- Returns summon info for the player's pet job when NO pet is out, so the bar
-- can show a clickable "[ Call Beast ]" style row with a live recast. Returns
-- nil if the player isn't a pet job. SMN is skipped (avatars are summoned via
-- individual spells, not a single JA). timerId/maxTimer mirror the values in
-- the petAbilityIds table above (sourced from Windower ability_recasts.lua).
function data.GetNoPetSummonInfo()
    local petJob = data.GetPetJob();
    if petJob == data.JOB_BST then
        return { label = 'Call Beast', cmd = '/ja "Call Beast" <me>', timerId = 104, maxTimer = 3600 };
    elseif petJob == data.JOB_DRG then
        return { label = 'Call Wyvern', cmd = '/ja "Call Wyvern" <me>', timerId = 163, maxTimer = 72000 };
    elseif petJob == data.JOB_PUP then
        return { label = 'Activate', cmd = '/ja "Activate" <me>', timerId = 205, maxTimer = 3600 };
    end
    return nil;
end

-- Remaining recast (seconds) for a summon timer id, for the no-pet row.
-- Returns 0 when ready/unknown. Uses the same recast wrapper as GetPetRecasts.
function data.GetSummonRecast(timerId)
    if not timerId then return 0; end
    local ok, t = pcall(GetAbilityTimerById, timerId);
    if ok and type(t) == 'number' and t > 0 then return t; end
    return 0;
end

return data;