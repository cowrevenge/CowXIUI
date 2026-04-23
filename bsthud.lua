--[[
Copyright © 2025, Nalfey of Asura
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of bst_hud nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL Nalfey BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-- HXUI module port --
Originally a standalone Ashita v4 addon. Now bundled as an HXUI module so it
shares HXUI's settings store and configmenu UI. The module exposes the
standard HXUI interface (Initialize / DrawWindow / SetHidden / HandlePacket /
HandleOutgoingPacket / HandleCommand / Cleanup) and is dispatched from
HXUI.lua's central event handlers.
]]

require('common')
local imgui    = require('imgui')
local ffi      = require('ffi')
local d3d      = require('d3d8')

local pet_mappings        = require('pet_image_mappings')

-- Optional XIUI-style pet buff handler. Loaded under pcall so bsthud keeps
-- running even if handlers/helpers.lua or libs/bufftable.lua aren't in this
-- HXUI build. When this loads successfully, the "Effects:" HUD row uses its
-- proper packet-driven tracking (with buff timers). When it fails, the row
-- falls back to the best-effort memory-read stub defined later in this file.
-- Dependency chain required for a successful load:
--   * handlers/helpers.lua  (for GetPlayerEntity, GetEntity globals)
--   * libs/bufftable.lua    (for buffTable.GetBuffIdBySpellId - spell fallback only)
-- We also save the require error into _petBuffLoadErr so `/bsthud diag` can
-- tell the user exactly why the load failed instead of just "MISSING".
local petBuff = nil
local _petBuffLoadErr = nil
do
    local ok, mod = pcall(require, 'handlers.petbuffhandler')
    if ok and type(mod) == 'table' then
        petBuff = mod
    else
        _petBuffLoadErr = tostring(mod)
    end
end

-- Optional XIUI packet parser. Needed to dispatch parsed 0x028 action packets
-- into petBuff.HandleActionPacket (pet-ability self-buffs like Scissor Guard,
-- Rage, Secretion all come through the action packet, not a 0x029 message).
-- Standalone - only requires 'common' - so it drops into libs/ without deps.
-- If missing, the 0x028 dispatch silently skips and pet buff tracking works
-- only for the 0x029 message path.
local packets = nil
local _packetsLoadErr = nil
do
    local ok, mod = pcall(require, 'libs.packets')
    if ok and type(mod) == 'table' then
        packets = mod
    else
        _packetsLoadErr = tostring(mod)
    end
end
local ready_move_mappings = require('ready_move_mappings')

local d3d8dev  = d3d.get_device()

local bsthud = {}

-------------------------------------------------------------------------------
-- Module-internal config
-- These were previously persisted via the standalone addon's settings file.
-- For the HXUI port we keep them as in-memory defaults; if any of them get
-- exposed in the configmenu later, swap the relevant reads to gConfig.
-------------------------------------------------------------------------------
local config = {
    pos                  = { x = 1400.0, y = 400.0 },
    size                 = { width  = 340.0, height = 420.0 },
    show_image           = true,
    show_bars            = true,
    show_moves           = true,
    show_icons           = true,
    show_target          = true,
    image_size           = 100,
    bg_alpha             = 0.30,
    charge_base_override = 0,    -- 0 = auto, otherwise fixed seconds per charge
    verbose              = false,
    debug_mode           = false,
}

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local SIC_RECAST_ID = 102

-- Jobs that have a pet. The HUD is only drawn when main or sub is one of
-- these. BST=9, DRG=14, SMN=15.
local PET_JOBS = T{
    [9]  = 'BST',
    [14] = 'DRG',
    [15] = 'SMN',
}
local JOB_NAMES = T{
    [0]='NON',  [1]='WAR',  [2]='MNK',  [3]='WHM',  [4]='BLM',  [5]='RDM',
    [6]='THF',  [7]='PLD',  [8]='DRK',  [9]='BST',  [10]='BRD', [11]='RNG',
    [12]='SAM', [13]='NIN', [14]='DRG', [15]='SMN', [16]='BLU', [17]='COR',
    [18]='PUP', [19]='DNC', [20]='SCH', [21]='GEO', [22]='RUN',
}

local ICON_TYPES = T{
    'blunt', 'slashing', 'piercing', 'magic', 'dark', 'water',
    'earth', 'fire', 'ice', 'wind', 'lightning', 'light',
    'buff', 'debuff',
}

-- Colors as ImVec4 {r,g,b,a} in 0..1
local COLOR = {
    white       = { 0.94, 1.00, 1.00, 1.00 },
    yellow      = { 0.95, 0.95, 0.49, 1.00 },
    orange      = { 0.97, 0.73, 0.50, 1.00 },
    red         = { 0.99, 0.51, 0.51, 1.00 },
    tp_full     = { 0.31, 0.71, 0.98, 1.00 },
    tp_normal   = { 0.56, 0.70, 0.98, 1.00 },
    ready       = { 0.20, 0.95, 0.20, 1.00 },
    not_ready   = { 0.60, 0.60, 0.60, 1.00 },
    hp_bar      = { 1.00, 0.58, 0.59, 1.00 },
    tp_bar      = { 0.56, 0.70, 0.98, 1.00 },
    header      = { 1.00, 0.85, 0.40, 1.00 },
}

-- Addon / image paths. As an HXUI module these live under HXUI's folder.
local addon_path  = ('%s\\addons\\HXUI\\'):format(AshitaCore:GetInstallPath())
local images_path = addon_path .. 'assets\\petimages\\'

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------
local state = {
    pet_active         = false,
    pet_name           = nil,
    pet_target_index   = nil,
    pet_server_id      = nil,
    pet_target_server_id = nil,
    current_hp_pct     = 0,
    current_mp_pct     = 0,
    current_tp         = 0,
    stored_tp          = 0,
    last_valid_tp_time = 0,
    charges            = 0,
    next_ready_recast  = 0,
    ability_ids        = T{},
    merits             = 0,
    jobpoints          = 0,
    equip_reduction    = 0,
    pet_image_tex      = nil,
    pet_image_current  = nil,
    damage_textures    = T{},
    expect_ready_move  = false,
    window_open        = { true },
    last_frame_time    = 0,
    scan_timer         = 0,
    -- Job gate
    main_job           = 0,
    sub_job            = 0,
    paused_for_job     = true,   -- Start paused until we confirm a pet job
    job_announced      = false,  -- Have we already echoed the current state?
    -- Debug overrides
    force_hud          = false,  -- Bypass the job-gate pause
    force_fake_pet     = false,  -- Inject fake pet data for testing
    -- Misc one-shot flags
    image_missing_logged = T{},  -- Set of image basenames we've already warned about

    -- Pet duration tracking (BST only). XIUI-style: classify at summon time,
    -- jug timers come from a fixed per-jug table, charm timer is computed by
    -- intercepting /check on the charmed mob and plugging its level into the
    -- PetMe duration formula (CHR + level diff + charm+ gear).
    pet_origin           = nil,  -- 'jug' | 'charm' | 'wyvern' | 'avatar' | nil
    pet_summon_time      = 0,    -- os.time() when the current pet showed up
    pet_expire_time      = nil,  -- absolute os.time() when pet despawns (jug only)
    charm_expire_time    = nil,  -- absolute os.time() when charm breaks
    charm_start_time     = nil,  -- os.time() when charm successfully started
    last_tracked_pet_name = nil, -- so we only classify once per spawn
    -- Charm packet state-machine (matches XIUI's data.CharmState)
    charm_state          = 0,    -- 0=NONE, 1=SENDING_PACKET, 2=CHECK_PACKET
    charm_target_id      = 0,
    charm_target_idx     = 0,
}

-------------------------------------------------------------------------------
-- Jug pet database & charm-duration tables (ported from XIUI petbar/data.lua).
-- duration values below are in MINUTES.
-------------------------------------------------------------------------------
-- Jug pet database (HorizonXI-accurate, sourced from the HzXI wiki's
-- Category:Familiars page on 2026-04-23). HzXI has 27 familiars total,
-- and HzXI-specific change: all HQ jugs cap at player level 75 (vs 99
-- on retail). "duration" is in MINUTES. Keys are the raw entity-name
-- (CamelCase, no space) which is what FFXI returns for jug entities.
-- Retail-era 76-99 jugs (BouncingBertha, FatsoFargann, LuckyLulush, etc.)
-- intentionally omitted since they don't exist on HzXI.
-------------------------------------------------------------------------------
local JUG_PETS = {
    -- 90-minute pets (Hare line)
    { name = 'HareFamiliar',        maxLevel = 35, duration = 90 },  -- WAR
    { name = 'KeenearedSteffi',     maxLevel = 75, duration = 90 },  -- WAR, HQ Hare

    -- 60-minute pets (the bulk)
    { name = 'SheepFamiliar',       maxLevel = 35, duration = 60 },  -- WAR
    { name = 'LullabyMelodia',      maxLevel = 75, duration = 60 },  -- DRK, HQ Sheep
    { name = 'FlowerpotBill',       maxLevel = 40, duration = 60 },  -- MNK
    { name = 'FlowerpotBen',        maxLevel = 75, duration = 60 },  -- MNK, HQ Bill
    { name = 'TigerFamiliar',       maxLevel = 40, duration = 60 },  -- WAR
    { name = 'SaberSiravarde',      maxLevel = 75, duration = 60 },  -- WAR, HQ Tiger
    { name = 'FlytrapFamiliar',     maxLevel = 40, duration = 60 },  -- WAR
    { name = 'VoraciousAudrey',     maxLevel = 75, duration = 60 },  -- WAR, HQ Flytrap
    { name = 'LizardFamiliar',      maxLevel = 45, duration = 60 },  -- WAR
    { name = 'ColdbloodComo',       maxLevel = 75, duration = 60 },  -- WAR, HQ Lizard
    { name = 'MayflyFamiliar',      maxLevel = 45, duration = 60 },  -- WAR
    { name = 'ShellbusterOrob',     maxLevel = 75, duration = 60 },  -- WAR, HQ Mayfly
    { name = 'EftFamiliar',         maxLevel = 45, duration = 60 },  -- WAR
    { name = 'AmbusherAllie',       maxLevel = 75, duration = 60 },  -- WAR, HQ Eft
    { name = 'BeetleFamiliar',      maxLevel = 45, duration = 60 },  -- PLD
    { name = 'PanzerGalahad',       maxLevel = 75, duration = 60 },  -- PLD, HQ Beetle
    { name = 'AntlionFamiliar',     maxLevel = 50, duration = 60 },  -- WAR
    { name = 'ChopsueyChucky',      maxLevel = 75, duration = 60 },  -- WAR, HQ Antlion
    { name = 'MiteFamiliar',        maxLevel = 55, duration = 60 },  -- WAR
    { name = 'LifedrinkerLars',     maxLevel = 75, duration = 60 },  -- DRK, HQ Mite
    { name = 'FunguarFamiliar',     maxLevel = 65, duration = 60 },  -- WAR
    { name = 'Homunculus',          maxLevel = 75, duration = 60 },  -- MNK (Korrigan alt)

    -- 30-minute pets
    { name = 'CrabFamiliar',        maxLevel = 55, duration = 30 },  -- PLD
    { name = 'CourierCarrie',       maxLevel = 75, duration = 30 },  -- PLD, HQ Crab
    { name = 'AmigoSabotender',     maxLevel = 75, duration = 30 },  -- WAR

    -- ========================================================================
    -- Retail-era 76-99 jug familiars (NOT in HzXI - out-of-era on this
    -- server). Retained so the addon remains compatible with retail / other
    -- private servers that include them. Harmless dead entries on HzXI since
    -- the game will never spawn pets by these names. None of them share a
    -- key with the HzXI list above.
    -- ========================================================================
    { name = 'CraftyClyvonne',   maxLevel = 75, duration = 30 },
    { name = 'BloodclawShasra',  maxLevel = 75, duration = 30 },
    { name = 'GorefangHobs',     maxLevel = 75, duration = 30 },
    { name = 'DipperYuly',       maxLevel = 75, duration = 30 },
    { name = 'SunburstMalfik',   maxLevel = 75, duration = 30 },
    { name = 'WarlikePatrick',   maxLevel = 75, duration = 30 },
    { name = 'ScissorlegXerin',  maxLevel = 75, duration = 30 },
    { name = 'BouncingBertha',   maxLevel = 75, duration = 30 },
    { name = 'RhymingShizuna',   maxLevel = 75, duration = 30 },
    { name = 'AttentiveIbuki',   maxLevel = 75, duration = 30 },
    { name = 'SwoopingZhivago',  maxLevel = 75, duration = 30 },
    { name = 'GenerousArthur',   maxLevel = 75, duration = 30 },
    { name = 'ThreestarLynn',    maxLevel = 75, duration = 30 },
    { name = 'BrainyWaluis',     maxLevel = 75, duration = 30 },
    { name = 'FaithfulFalcorr',  maxLevel = 75, duration = 30 },
    { name = 'SharpwitHermes',   maxLevel = 99, duration = 30 },
    { name = 'HeadbreakerKen',   maxLevel = 99, duration = 30 },
    { name = 'RedolentCandi',    maxLevel = 99, duration = 30 },
    { name = 'AlluringHoney',    maxLevel = 99, duration = 30 },
    { name = 'CaringKiyomaro',   maxLevel = 99, duration = 30 },
    { name = 'VivaciousVickie',  maxLevel = 99, duration = 30 },
    { name = 'HurlerPercival',   maxLevel = 99, duration = 30 },
    { name = 'BlackbeardRandy',  maxLevel = 99, duration = 30 },
    { name = 'FleetReinhard',    maxLevel = 99, duration = 30 },
    { name = 'GooeyGerard',      maxLevel = 99, duration = 30 },
    { name = 'CrudeRaphie',      maxLevel = 99, duration = 30 },
    { name = 'DroopyDortwin',    maxLevel = 99, duration = 30 },
    { name = 'PonderingPeter',   maxLevel = 99, duration = 30 },
    { name = 'MosquitoFamilia',  maxLevel = 99, duration = 30 },
    { name = 'Left-HandedYoko',  maxLevel = 99, duration = 30 },
}
local JUG_PET_LOOKUP = {}
for _, p in ipairs(JUG_PETS) do JUG_PET_LOOKUP[p.name] = p end

-- Item ID -> "Charm+" gear bonus (same values PetMe / XIUI use).
local CHARM_GEAR = {
    [17936] = 1,  -- De Saintre's Axe
    [17950] = 2,  -- Marid Ancus
    [12517] = 4,  -- Beast Helm
    [15157] = 5,  -- Bison Warbonnet
    [15158] = 6,  -- Brave's Warbonnet
    [16104] = 5,  -- Khimaira Bonnet
    [16105] = 6,  -- Stout Bonnet
    [15080] = 5,  -- Monster Helm
    [15233] = 4,  -- Beast Helm +1
    [15253] = 5,  -- Monster Helm +1
    [12646] = 5,  -- Beast Jackcoat
    [14418] = 5,  -- Bison Jacket
    [14419] = 6,  -- Brave's Jacket
    [14566] = 5,  -- Khimaira Jacket
    [14567] = 6,  -- Stout Jacket
    [15095] = 6,  -- Monster Jackcoat
    [14481] = 6,  -- Beast Jackcoat +1
    [14508] = 7,  -- Monster Jackcoat +1
    [13969] = 3,  -- Beast Gloves
    [14850] = 5,  -- Bison Wristbands
    [14851] = 6,  -- Brave's Wristbands
    [14981] = 5,  -- Khimaira Wristbands
    [14982] = 6,  -- Stout Wristbands
    [14898] = 3,  -- Beast Gloves +1
    [15110] = 4,  -- Monster Gloves
    [14917] = 4,  -- Monster Gloves +1
    [14222] = 6,  -- Beast Trousers
    [14319] = 5,  -- Bison Kecks
    [14320] = 6,  -- Brave's Kecks
    [15645] = 5,  -- Khimaira Kecks
    [15646] = 6,  -- Stout Kecks
    [15125] = 2,  -- Monster Trousers
    [15569] = 6,  -- Beast Trousers +1
    [15588] = 2,  -- Monster Trousers +1
    [14097] = 2,  -- Beast Gaiters
    [15307] = 5,  -- Bison Gamashes
    [15308] = 6,  -- Brave's Gamashes
    [15731] = 5,  -- Khimaira Gamashes
    [15732] = 6,  -- Stout Gamashes
    [15360] = 2,  -- Beast Gaiters +1
    [15140] = 3,  -- Monster Gaiters
    [15673] = 3,  -- Monster Gaiters +1
    [14658] = 4,  -- Atlaua's Ring
    [13667] = 5,  -- Trimmer's Mantle (HorizonXI only, when /BST)
}

-- Level-difference modifier from PetMe/XIUI. chg multiplies base charm duration.
local D_LEVEL = {
    { ld = -6, chg = 0.04 },
    { ld = -5, chg = 0.08 },
    { ld = -4, chg = 0.12 },
    { ld = -3, chg = 0.16 },
    { ld = -2, chg = 0.33 },
    { ld = -1, chg = 0.66 },
    { ld =  0, chg = 1.00 },
    { ld =  1, chg = 1.40 },
    { ld =  2, chg = 1.80 },
    { ld =  3, chg = 2.20 },
    { ld =  4, chg = 2.60 },
    { ld =  5, chg = 3.00 },
    { ld =  6, chg = 3.40 },
    { ld =  7, chg = 4.00 },
    { ld =  8, chg = 5.00 },
    { ld =  9, chg = 6.00 },
}

-- Charm packet constants from XIUI.
local CHARM_STATE_NONE            = 0
local CHARM_STATE_SENDING_PACKET  = 1
local CHARM_STATE_CHECK_PACKET    = 2
local CHARM_ACTION_ID             = 0x34   -- ability id 52 = Charm
local PKT_OUT_ACTION              = 0x01A
local PKT_OUT_CHECK               = 0x0DD
local PKT_IN_CHECK                = 0x029
local FAMILIAR_ACTION_INFO        = 0x618  -- Familiar extends charm by 25 min

-------------------------------------------------------------------------------
-- Per-job ability recast table (ported from XIUI petbar/data.lua).
-- Timer id = recast-block id used by the game's recast manager.
-- Ready (id 102) is intentionally excluded here because it's already
-- surfaced as the "Charges" line above the ability list.
-- `cmd` is the chat command queued when the user clicks the ability row.
-- nil means the ability doesn't have a simple one-shot command (e.g. SMN
-- Blood Pacts require picking a specific BP, so clicking does nothing).
-------------------------------------------------------------------------------
local PET_ABILITIES = {
    [9] = {   -- BST
        { id = 103, name = 'Reward',           cmd = '/ja "Reward" <me>'          },
        { id = 104, name = 'Call Beast',       cmd = '/ja "Call Beast" <me>'      },
    },
    [14] = {  -- DRG
        { id = 163, name = 'Call Wyvern',      cmd = '/ja "Call Wyvern" <me>'     },
        { id = 162, name = 'Spirit Link',      cmd = '/ja "Spirit Link" <me>'     },
        { id = 164, name = 'Deep Breathing',   cmd = '/ja "Deep Breathing" <me>'  },
        { id = 70,  name = 'Steady Wing',      cmd = '/ja "Steady Wing" <me>'     },
    },
    [15] = {  -- SMN
        -- Blood Pacts: per-avatar favorite stored in
        -- gConfig.smnBloodPacts[<avatarName>].{rage,ward}. Resolved at
        -- click-time so the row fires the BP appropriate for whatever
        -- avatar is currently out. Returns nil when the favorite isn't
        -- set (or no pet is out), which makes the row non-clickable.
        -- Set favorites in /hxui -> Pet HUD -> SMN Blood Pacts.
        { id = 173, name = 'Blood Pact: Rage', cmd = function()
            local pet = state.pet_name
            if not pet then return nil end
            local entries = gConfig.smnBloodPacts
            if not entries or not entries[pet] then return nil end
            local bp = (entries[pet].rage or ''):match('^%s*(.-)%s*$')
            if bp == '' then return nil end
            return ('/pet "%s" <t>'):format(bp)
        end },
        { id = 174, name = 'Blood Pact: Ward', cmd = function()
            local pet = state.pet_name
            if not pet then return nil end
            local entries = gConfig.smnBloodPacts
            if not entries or not entries[pet] then return nil end
            local bp = (entries[pet].ward or ''):match('^%s*(.-)%s*$')
            if bp == '' then return nil end
            return ('/pet "%s" <me>'):format(bp)
        end },
        { id = 108, name = 'Apogee',           cmd = '/ja "Apogee" <me>'       },
        { id = 71,  name = 'Mana Cede',        cmd = '/ja "Mana Cede" <me>'    },
        -- Astral Flow (2-hour). In FFXI the 2-hour recast sits at timer-id
        -- 0 in the recast table. `always_show = true` forces the row to
        -- render even when the recast slot isn't populated (e.g. 2-hour
        -- never used this login). Value falls back to the game reporting
        -- "unable to use" if the player clicks while it's on cooldown.
        { id = 0,   name = 'Astral Flow',      cmd = '/ja "Astral Flow" <me>',
          always_show = true },
    },
}

-- Format a recast value (seconds) for display. "Ready" when 0, "m:ss" when
-- >= 60, "Xs" otherwise. Matches XIUI's data.FormatTimer output.
local function fmt_recast(secs)
    if not secs or secs <= 0 then return 'Ready' end
    if secs >= 60 then
        return ('%d:%02d'):format(math.floor(secs / 60), secs % 60)
    end
    return ('%ds'):format(secs)
end

-- Resolve a status-effect id to its display name via Ashita's resource
-- manager. Falls back to the raw id if the lookup fails (e.g. server sent
-- an unknown id). Cached so we don't re-hit the resource manager per frame.
local status_name_cache = {}
local function status_name(id)
    if id == nil then return '' end
    local cached = status_name_cache[id]
    if cached ~= nil then return cached end
    local name
    local resMgr = AshitaCore and AshitaCore:GetResourceManager() or nil
    if resMgr ~= nil then
        local ok, buff = pcall(function() return resMgr:GetStatusIconByIndex(id) end)
        if ok and buff and buff.Name and buff.Name[1] then
            name = buff.Name[1]
        else
            -- Older Ashita builds expose the same data through GetString().
            local ok2, s = pcall(function() return resMgr:GetString('buffs.names', id) end)
            if ok2 and s and s ~= '' then name = s end
        end
    end
    name = name or ('#' .. tostring(id))
    status_name_cache[id] = name
    return name
end

-- Format seconds as "m:ss" (or "h:mm:ss" if >= 1 hour). Compact + readable.
local function fmt_mmss(secs)
    if not secs or secs < 0 then secs = 0 end
    secs = math.floor(secs)
    if secs >= 3600 then
        return ('%d:%02d:%02d'):format(math.floor(secs / 3600),
                                       math.floor((secs % 3600) / 60),
                                       secs % 60)
    end
    return ('%d:%02d'):format(math.floor(secs / 60), secs % 60)
end

-- Forward declarations so earlier functions (make_visible) can reference the
-- charm helpers defined further down the file.
local track_pet_summon

-------------------------------------------------------------------------------
-- Logging helpers
-------------------------------------------------------------------------------
local LOG_PREFIX = '[BST-HUD] '

local function log(msg)
    print(LOG_PREFIX .. tostring(msg))
end

local function err(msg)
    print(LOG_PREFIX .. '[err] ' .. tostring(msg))
end

local function vlog(msg)
    if config.verbose then log(msg) end
end

local function svlog(msg)
    if config.debug_mode then log('[dbg] ' .. tostring(msg)) end
end

-------------------------------------------------------------------------------
-- File / texture helpers
-------------------------------------------------------------------------------
local function file_exists(path)
    local f = io.open(path, 'rb')
    if f then f:close() return true end
    return false
end

local function load_texture(path)
    if not file_exists(path) then return nil end
    local tex_ptr = ffi.new('IDirect3DTexture8*[1]')
    local hr = ffi.C.D3DXCreateTextureFromFileA(d3d8dev, path, tex_ptr)
    if hr < 0 then
        svlog('Failed to load texture: ' .. path)
        return nil
    end
    return d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', tex_ptr[0]))
end

local function load_damage_textures()
    state.damage_textures = T{}
    for _, t in ipairs(ICON_TYPES) do
        local path = ('%srdy_%s.png'):format(images_path, t)
        state.damage_textures[t] = load_texture(path)
    end
end

local function release_pet_texture()
    state.pet_image_tex = nil
    state.pet_image_current = nil
end

local function update_pet_image()
    if not state.pet_active or not state.pet_name then
        release_pet_texture()
        return
    end

    -- Decide which image to look for, in this preference order:
    --   1. BST-overlap failsafe: if the pet name is an EXACT key in the BST
    --      jug pet table, use that portrait regardless of job. (Strict match
    --      only — the partial-match path in get_pet_image would mis-bind
    --      e.g. a wyvern named "Ben" to FlowerpotBen.)
    --   2. DRG main: all wyverns share one portrait.
    --   3. SMN main: look up by exact pet name (Carbuncle.jpg, Garuda.jpg…).
    --      Tries .jpg first then .png; silently skips if neither exists.
    --   4. BST main or sub: full mapping lookup (handles partials + default).
    --   5. Anything else: no portrait.
    local image_name = nil

    if pet_mappings.has_pet_image and pet_mappings.has_pet_image(state.pet_name) then
        image_name = pet_mappings.get_pet_image(state.pet_name)
    elseif state.main_job == 14 then  -- DRG
        -- Wyverns use player-chosen names (Max, Theo, Anna, etc.), so the
        -- entity name will never match anything in pet_image_mappings. All
        -- wyverns share the same portrait regardless of name.
        image_name = 'wyvern.png'
    elseif state.main_job == 15 then  -- SMN
        if file_exists(images_path .. state.pet_name .. '.jpg') then
            image_name = state.pet_name .. '.jpg'
        elseif file_exists(images_path .. state.pet_name .. '.png') then
            image_name = state.pet_name .. '.png'
        end
    elseif state.main_job == 9 or state.sub_job == 9 then  -- BST
        image_name = pet_mappings.get_pet_image(state.pet_name)
    end

    if image_name == nil then
        release_pet_texture()
        return
    end

    -- Already loaded?
    if image_name == state.pet_image_current and state.pet_image_tex ~= nil then
        return
    end

    local image_path = images_path .. image_name
    if not file_exists(image_path) then
        -- Silently skip — the user may not have created this image yet.
        -- Warn at vlog level once per filename so /bsthud verbose can still
        -- surface the issue if they're hunting for it.
        if not state.image_missing_logged[image_name] then
            vlog('Image not found: ' .. image_path .. ' (skipping portrait)')
            state.image_missing_logged[image_name] = true
        end
        release_pet_texture()
        return
    end

    local tex = load_texture(image_path)
    if tex ~= nil then
        state.pet_image_tex = tex
        state.pet_image_current = image_name
    end
end

-------------------------------------------------------------------------------
-- TP handling
-------------------------------------------------------------------------------
local function reset_stored_tp()
    state.stored_tp = 0
    state.current_tp = 0
    state.last_valid_tp_time = 0
    vlog('Reset stored TP values')
end

-- Only accept a new TP value if it's higher than stored, or if enough time
-- has passed since the last valid value, or we have no stored value.
-- Values above 3000 are treated as garbage (stale memory after pet swap /
-- zoning); XIUI does the same clamp.
local function update_pet_tp(new_tp)
    if new_tp == nil or new_tp < 0 then return end
    if new_tp > 3000 then new_tp = 0 end
    local now = os.time()
    if new_tp > state.stored_tp
       or (now - state.last_valid_tp_time) > 3
       or state.stored_tp == 0 then
        state.stored_tp = new_tp
        state.current_tp = new_tp
        state.last_valid_tp_time = now
    else
        state.current_tp = state.stored_tp
    end
end

-- Read pet TP directly from the player memory manager. This is what petinfo
-- and XIUI both use, and it does NOT depend on us having seen a 0x067/0x068
-- packet yet. Called every poll so TP stays live even if sync packets are
-- skipped. Values >3000 are treated as garbage (per XIUI's note that the
-- memory location occasionally spikes), so we drop those instead of letting
-- update_pet_tp's "only accept if higher" path latch them in for 3 seconds.
local function poll_pet_tp_from_memory()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    if player == nil or player.GetPetTP == nil then return end
    local ok, tp = pcall(function() return player:GetPetTP() end)
    if not ok or tp == nil or tp < 0 then return end
    if tp > 3000 then return end  -- garbage spike; ignore this sample
    update_pet_tp(tp)
end

-- Pet MP% straight from the player memory manager (petinfo pattern).
local function poll_pet_mp_from_memory()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    if player == nil or player.GetPetMPPercent == nil then return 0 end
    local ok, mp = pcall(function() return player:GetPetMPPercent() end)
    if ok and mp and mp >= 0 then return mp end
    return 0
end

-------------------------------------------------------------------------------
-- Player / pet access
-------------------------------------------------------------------------------
local function get_player_memory()
    return AshitaCore:GetMemoryManager():GetPlayer()
end

local function get_entity_mgr()
    return AshitaCore:GetMemoryManager():GetEntity()
end

local function get_party_mgr()
    return AshitaCore:GetMemoryManager():GetParty()
end

local function get_player_target_index()
    local party = get_party_mgr()
    return party:GetMemberTargetIndex(0)
end

local function get_player_server_id()
    local party = get_party_mgr()
    return party:GetMemberServerId(0)
end

-- Read the pet's entity index via the PlayerEntity wrapper. This is the same
-- path the stock petinfo addon uses and is reliable across Ashita v4 builds.
-- Falls back to the party / entity-manager methods if the wrapper field is
-- unavailable for any reason.
local function get_pet_target_index()
    local player = GetPlayerEntity and GetPlayerEntity() or nil
    if player ~= nil and player.PetTargetIndex and player.PetTargetIndex ~= 0 then
        return player.PetTargetIndex
    end
    local party = get_party_mgr()
    if party and party.GetMemberPetTargetIndex ~= nil then
        local idx = party:GetMemberPetTargetIndex(0)
        if idx and idx ~= 0 then return idx end
    end
    return nil
end

-- Returns true if main or sub is a pet job (BST/DRG/SMN). Also updates the
-- cached job ids so other code can read them cheaply.
local function refresh_jobs()
    local player = get_player_memory()
    if player == nil then
        return false
    end
    -- Zoning: player struct is mid-rebuild; skip until it's stable. XIUI does
    -- the same thing in data.GetPetData() (see modules/petbar/data.lua:654).
    local ok_z, zoning = pcall(function() return player.isZoning end)
    if ok_z and zoning then
        return false
    end
    local ok_m, mj = pcall(function() return player:GetMainJob() end)
    local ok_s, sj = pcall(function() return player:GetSubJob() end)
    if not ok_m then mj = 0 end
    if not ok_s then sj = 0 end
    state.main_job = mj or 0
    state.sub_job  = sj or 0
    -- Jobs read as 0 during zone transitions; treat that as "unknown/pause".
    if state.main_job == 0 and state.sub_job == 0 then
        return false
    end
    return PET_JOBS[state.main_job] ~= nil or PET_JOBS[state.sub_job] ~= nil
end

-- Call periodically. Announces state transitions in chat.
local function check_job_gate()
    local is_pet_job = refresh_jobs()
    local was_paused = state.paused_for_job
    state.paused_for_job = not is_pet_job

    if not state.job_announced or was_paused ~= state.paused_for_job then
        state.job_announced = true
        local mj = JOB_NAMES[state.main_job] or '?'
        local sj = JOB_NAMES[state.sub_job] or '?'
        if state.paused_for_job then
            log(('Main or Sub is not a Pet Job (%s/%s) - UI Paused (not drawing)'):format(mj, sj))
            -- Drop any pet state we may have been tracking
            if state.pet_active then
                make_invisible()
            end
        else
            log(('Pet job detected (%s/%s) - UI Active'):format(mj, sj))
        end
    end
end

-- Read fields off an entity by index. We use the global GetEntity() wrapper
-- (same helper petinfo uses) because it returns a populated entity struct
-- whose properties are reliably up to date. The entity-manager methods
-- (em:GetHPPercent etc.) are not consistent across Ashita v4 builds and were
-- the cause of the "HP stuck at 0 / not updating" bug in earlier versions.
local function get_entity_field(idx, field)
    if not idx or idx == 0 then return nil end
    local ent = GetEntity and GetEntity(idx) or nil
    if ent == nil then return nil end
    if field == 'name'      then return ent.Name
    elseif field == 'hpp'       then return ent.HPPercent
    elseif field == 'server_id' then return ent.ServerId
    elseif field == 'distance'  then return ent.Distance
    end
    return nil
end

-- Look up an entity index from a server id by scanning the entity table.
-- 2304 indices is fast enough to do on demand; we only call this when the
-- pet has a tracked target. Returns nil if not found.
local function get_entity_index_by_server_id(sid)
    if not sid or sid == 0 then return nil end
    if GetEntity == nil then return nil end
    for i = 0, 2303 do
        local ent = GetEntity(i)
        if ent ~= nil and ent.ServerId == sid then
            return i
        end
    end
    return nil
end

-- Locate the Sic recast slot once, return (slot, recast_mgr). The recast
-- block is sparse (slots 0-30) and the timer's slot index can move around,
-- so we scan each call. Cheap.
local function find_sic_slot()
    local rm = AshitaCore:GetMemoryManager():GetRecast()
    if rm == nil then return nil, nil end
    for i = 0, 30 do
        local ok, id = pcall(function() return rm:GetAbilityTimerId(i) end)
        if ok and id == SIC_RECAST_ID then
            return i, rm
        end
    end
    return nil, nil
end

-- Sic recast remaining (seconds).
local function get_sic_recast()
    local slot, rm = find_sic_slot()
    if not slot then return 0 end
    local ok, t = pcall(function() return rm:GetAbilityTimer(slot) end)
    if ok and t then return t end
    return 0
end

-- Generic ability-timer reader: finds the recast slot for the given timer id
-- and returns its remaining seconds, or nil if the ability isn't in the recast
-- table (usually means the player doesn't know it yet). Same slot-scan pattern
-- as find_sic_slot. Returns 0 when the ability is known but off cooldown.
local function get_ability_recast_by_id(timer_id)
    if not timer_id then return nil end
    local rm = AshitaCore:GetMemoryManager():GetRecast()
    if rm == nil then return nil end
    for i = 0, 30 do
        local ok, id = pcall(function() return rm:GetAbilityTimerId(i) end)
        if ok and id == timer_id then
            local ok2, t = pcall(function() return rm:GetAbilityTimer(i) end)
            if ok2 then return t or 0 end
            return 0
        end
    end
    return nil
end

-- Best-effort pet status-icons reader. Preferred path is the XIUI-style
-- petbuffhandler module (packet-driven, returns buff timers too); when that
-- isn't loaded — because handlers/helpers.lua or libs/bufftable.lua wasn't
-- on the package path — we fall back to the stub that tries a few Ashita
-- player-memory methods.
-- Returns two arrays: effect ids (0-255) and remaining seconds (may be nil).
local function get_pet_status_effects()
    -- Primary path: use the real handler's state. It returns nil,nil when
    -- no buffs are active; we normalize to empty tables so the caller can
    -- just check `#ids > 0`.
    if petBuff and petBuff.GetActiveEffects then
        local ok, ids, times = pcall(petBuff.GetActiveEffects)
        if ok then return ids or {}, times or {} end
    end

    -- Fallback path (stub): try the Ashita player memory API directly.
    local ids, times = {}, {}
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    if player == nil then return ids, times end

    -- Try a few common method names; ignore anything that errors out.
    local ok, icons = pcall(function()
        if player.GetPetStatusIcons ~= nil then return player:GetPetStatusIcons() end
        if player.GetPetBuffs      ~= nil then return player:GetPetBuffs() end
        return nil
    end)
    if not ok or icons == nil then return ids, times end

    -- Ashita returns either a 0-indexed cdata array or a 1-indexed Lua table.
    -- 255 and 0xFFFF are the sentinel "empty slot" values used by the game.
    for i = 0, 31 do
        local v
        if type(icons) == 'table' then v = icons[i + 1] or icons[i]
        else v = icons[i] end
        if v and v ~= 255 and v ~= 0xFFFF and v ~= 0 then
            ids[#ids + 1] = v
            times[#times + 1] = nil  -- timers need a separate read; left nil for now
        end
    end
    return ids, times
end

-- Try to read the per-recast Modifier field from the recast block. This is
-- the game's own pre-aggregated reduction (in seconds, negative for
-- reductions) and rolls in gear, merits, and JP automatically. If the running
-- Ashita build doesn't expose this accessor we return nil and fall back to
-- the manual gear/merit/JP path below. Cached after first successful read so
-- a missing API doesn't get re-probed every poll.
local sic_modifier_api_ok  -- nil = unknown, true = available, false = not available
local function get_sic_modifier()
    if sic_modifier_api_ok == false then return nil end
    local slot, rm = find_sic_slot()
    if not slot then return nil end
    local got, mod = pcall(function()
        if rm.GetAbilityTimerModifier ~= nil then
            return rm:GetAbilityTimerModifier(slot)
        elseif rm.GetAbilityTimerModifierBySlot ~= nil then
            return rm:GetAbilityTimerModifierBySlot(slot)
        end
        return nil
    end)
    if got and type(mod) == 'number' then
        sic_modifier_api_ok = true
        return mod
    end
    sic_modifier_api_ok = false
    return nil
end

-- Returns per-charge time in seconds (may be fractional). Three sources, in
-- preference order:
--   1. user override via /bsthud chargebase <N>
--   2. the recast block's Modifier (preferred; one source of truth)
--   3. legacy: scan gear + merits + JP and subtract from the 30s base
local function compute_chargebase()
    if config.charge_base_override and config.charge_base_override > 0 then
        return config.charge_base_override
    end
    local mod = get_sic_modifier()
    if mod ~= nil then
        -- Modifier is the reduction (in seconds) applied to the FULL 3-charge
        -- cycle (90s base). Per-charge = (90 + mod) / 3. Modifier is negative
        -- for reductions, e.g. -30 → 60s total → 20s per charge.
        local cb = (90 + mod) / 3
        if cb < 1 then cb = 1 end
        return cb
    end
    return math.max(1, 30 - state.merits - state.jobpoints - state.equip_reduction)
end

local function update_charges()
    local player = get_player_memory()
    if player == nil then return end
    if player:GetMainJob() ~= 9 then return end  -- 9 = BST
    local duration = get_sic_recast()
    local cb = compute_chargebase()
    local total = cb * 3
    state.charges = math.floor((total - duration) / cb)
    if state.charges < 0 then state.charges = 0 end
    if state.charges > 3 then state.charges = 3 end
    state.next_ready_recast = math.floor(math.fmod(duration, cb))
end

-- Try to read Sic Recast merit level. Ashita exposes merits differently
-- depending on version. We iterate common paths and fall back to 0.
local function update_merits_and_jp()
    local player = get_player_memory()
    if player == nil then return end

    -- Job points: BST category is 9. If 100+ JP are spent we get +5 merit worth.
    local spent = 0
    pcall(function()
        if player.GetJobPointsSpent ~= nil then
            spent = player:GetJobPointsSpent(9)
        end
    end)
    state.jobpoints = (spent and spent >= 100) and 5 or 0

    -- Sic recast merit level (0-5) → 0/2/4/6/8/10 seconds off
    local meritLevel = 0
    -- Try common Ashita v4 APIs
    pcall(function()
        if player.GetMeritValue ~= nil then
            -- Some builds expose this with a category id; 0xBC is often Sic Recast
            meritLevel = player:GetMeritValue(0xBC) or 0
        end
    end)
    if meritLevel == 0 then
        pcall(function()
            if player.GetMerits ~= nil then
                local all = player:GetMerits()
                meritLevel = (all and all.sic_recast) or 0
            end
        end)
    end
    state.merits = meritLevel * 2
end

-- Equipment scan for charge-time reductions from gear.
local function update_equip_reduction()
    local inv = AshitaCore:GetMemoryManager():GetInventory()
    local resMgr = AshitaCore:GetResourceManager()
    if inv == nil or resMgr == nil then return end

    local function equipped_name(slot)
        local ok, eq = pcall(function() return inv:GetEquippedItem(slot) end)
        if not ok or eq == nil then return '' end
        local containerSlot = eq.Slot or 0
        local indexInContainer = eq.Index or 0
        if indexInContainer == 0 then return '' end
        local item = inv:GetContainerItem(containerSlot, indexInContainer)
        if item == nil or item.Id == nil or item.Id == 0 then return '' end
        local res = resMgr:GetItemById(item.Id)
        if res == nil then return '' end
        return (res.Name and res.Name[1]) or res.En or ''
    end

    local main = equipped_name(0)  -- Main hand
    local sub  = equipped_name(1)  -- Sub
    local legs = equipped_name(7)  -- Legs

    local r = 0
    if main == "Charmer's Merlin" or sub == "Charmer's Merlin" then
        r = r + 5
    end
    if legs == "Desultor Tassets" or legs == "Gleti's Breeches" then
        r = r + 5
    end
    state.equip_reduction = r

    vlog(('Equip reduction: %d (Main=%s, Sub=%s, Legs=%s)'):format(r, main, sub, legs))
end

-- Refresh the list of BST job abilities known by the player (for ready moves)
local function update_ability_list()
    local player = get_player_memory()
    if player == nil then return end
    local list = T{}
    -- Ashita's Player has GetAbilityArray-style access. We walk IDs and ask
    -- the resource manager which ones are Monster abilities the player knows.
    -- The player's ability list is typically stored in a bit array; simpler:
    -- iterate through job abilities the resource manager exposes and mark
    -- which ones the player has (via the ability list memory field).
    pcall(function()
        for i = 0, 1023 do
            if player:HasAbility(i) then
                list:append(i)
            end
        end
    end)
    state.ability_ids = list
end

-------------------------------------------------------------------------------
-- Pet lifecycle
-------------------------------------------------------------------------------
local function make_invisible()
    if state.pet_active then
        vlog('Pet no longer present; hiding display.')
    end
    state.pet_active       = false
    state.pet_target_index = nil
    state.pet_server_id    = nil
    state.pet_target_server_id = nil
    state.pet_name         = nil
    state.current_hp_pct   = 0
    state.ability_ids      = T{}
    track_pet_summon(nil)    -- clears timer fields
    release_pet_texture()
end

local function make_visible()
    local idx = get_pet_target_index()
    if not idx then
        make_invisible()
        return false
    end
    state.pet_target_index = idx
    state.pet_server_id    = get_entity_field(idx, 'server_id')
    state.pet_name         = get_entity_field(idx, 'name')
    state.current_hp_pct   = get_entity_field(idx, 'hpp') or 0
    state.pet_active       = true
    track_pet_summon(state.pet_name)
    update_ability_list()
    update_pet_image()
    vlog('Pet visible: ' .. (state.pet_name or '?') .. ' (' .. tostring(state.pet_origin) .. ')')
    return true
end

-- Populate state with a fake pet so the full HUD renders without needing to
-- actually summon one. Used by /bsthud force fakepet.
local function apply_fake_pet()
    state.pet_active       = true
    state.pet_target_index = 0  -- sentinel; polling loop skips real lookups
    state.pet_server_id    = 0
    state.pet_name         = 'CourierCarrie'
    state.current_hp_pct   = 72
    state.current_tp       = 850
    state.stored_tp        = 850
    state.charges          = 2
    state.next_ready_recast = 7
    -- Fake a 30-min jug (Courier Carrie is a 30-min HQ Crab) so the
    -- "Stay: m:ss" line renders; pick an elapsed of 4 min so there's
    -- something visible mid-countdown.
    state.pet_origin        = 'jug'
    state.pet_summon_time   = os.time() - 4 * 60
    state.pet_expire_time   = state.pet_summon_time + 30 * 60
    state.last_tracked_pet_name = state.pet_name
    -- A representative Monster-ability set so ready moves render
    state.ability_ids = T{
        636,  -- Foot Kick
        638,  -- Whirl Claws
        639,  -- Blaster
        643,  -- Wild Carrot
        740,  -- Mandibular Bite
    }
    -- Try to load a portrait so the image area isn't empty; fall back silently
    local image_name = pet_mappings.get_pet_image('CourierCarrie')
    local image_path = images_path .. image_name
    if not file_exists(image_path) then
        image_path = images_path .. pet_mappings.get_pet_image('default')
    end
    if file_exists(image_path) then
        local tex = load_texture(image_path)
        if tex ~= nil then
            state.pet_image_tex = tex
            state.pet_image_current = image_name
        end
    end
end

-------------------------------------------------------------------------------
-- Packet helpers
-------------------------------------------------------------------------------
-- Read unsigned byte at 0-based packet offset `off` from Lua string `data`.
local function pkt_u8(data, off)
    local b = data:byte(off + 1)
    return b or 0
end

local function pkt_u16(data, off)
    local lo = data:byte(off + 1) or 0
    local hi = data:byte(off + 2) or 0
    return lo + hi * 256
end

local function pkt_u32(data, off)
    local b1 = data:byte(off + 1) or 0
    local b2 = data:byte(off + 2) or 0
    local b3 = data:byte(off + 3) or 0
    local b4 = data:byte(off + 4) or 0
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

-- Read a zero-terminated string starting at `off` up to `max` bytes.
local function pkt_string(data, off, max)
    max = max or 16
    local ending = off + max
    if ending > #data then ending = #data end
    local s = data:sub(off + 1, ending)
    local nul = s:find('\0', 1, true)
    if nul then s = s:sub(1, nul - 1) end
    return s
end

-------------------------------------------------------------------------------
-- Charm duration math (ported from XIUI petbar/data.lua → PetMe)
-- Called from the /check response handler. Read CHR + main job level + any
-- "Charm+" gear off the player, multiply by the level-difference modifier,
-- and return an absolute os.time() expiry.
-------------------------------------------------------------------------------
local function get_charm_equip_value()
    local inv = AshitaCore:GetMemoryManager():GetInventory()
    if inv == nil then return 0 end
    local total = 0
    for slot = 0, 15 do
        local ok, eq = pcall(function() return inv:GetEquippedItem(slot) end)
        if ok and eq ~= nil then
            -- eq.Index is packed: high byte = container, low byte = index
            local idx = eq.Index and (eq.Index % 256) or 0
            local ctr = eq.Index and math.floor((eq.Index % 65536) / 256) or 0
            if idx > 0 then
                local item = inv:GetContainerItem(ctr, idx)
                if item ~= nil and item.Id and CHARM_GEAR[item.Id] then
                    total = total + CHARM_GEAR[item.Id]
                end
            end
        end
    end
    return total
end

local function calculate_charm_expiry(mob_level)
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    if player == nil then return nil end
    local ok_lvl, player_lvl = pcall(function() return player:GetMainJobLevel() end)
    local ok_chr, chr        = pcall(function() return player:GetStat(6) end)
    if not ok_lvl or not ok_chr or not player_lvl or not chr then return nil end

    local diff = player_lvl - (mob_level or 0)
    if diff < -6 then diff = -6 elseif diff > 9 then diff = 9 end
    local modifier = 0
    for _, row in ipairs(D_LEVEL) do
        if row.ld == diff then modifier = row.chg break end
    end
    if modifier <= 0 then
        -- Unknown level or very negative diff — refuse to compute (would be 0).
        return nil
    end
    local base        = math.floor(1.25 * chr + 150)
    local pre_gear    = base * modifier
    local charm_secs  = pre_gear * (1 + 0.05 * get_charm_equip_value())
    return os.time() + math.floor(charm_secs)
end

-- Classify a new pet by name + job and set the right timer fields.
-- Mirrors XIUI's data.TrackPetSummon, but uses our local state table.
-- Forward-declared above so make_visible() can call it.
track_pet_summon = function(pet_name)
    -- No pet / cleared
    if pet_name == nil or pet_name == '' then
        state.pet_summon_time      = 0
        state.pet_expire_time      = nil
        state.pet_origin           = nil
        state.last_tracked_pet_name = nil
        -- Preserve charm_* fields if a /check response is in flight
        if state.charm_state == CHARM_STATE_NONE then
            state.charm_expire_time = nil
            state.charm_start_time  = nil
            state.charm_target_id   = 0
            state.charm_target_idx  = 0
        end
        return
    end

    -- Only classify on a real name change (prevents resetting timers every frame
    -- when the entity table re-emits the same pet).
    if pet_name == state.last_tracked_pet_name then return end
    state.last_tracked_pet_name = pet_name
    state.pet_summon_time       = os.time()

    local jug = JUG_PET_LOOKUP[pet_name]
    if jug then
        state.pet_origin      = 'jug'
        state.pet_expire_time = state.pet_summon_time + (jug.duration * 60)
        state.charm_expire_time = nil
    elseif state.main_job == 9 then
        -- BST main + not a jug + not an avatar name = charmed mob.
        -- charm_expire_time is populated later by the /check packet handler.
        state.pet_origin      = 'charm'
        state.pet_expire_time = nil
    elseif state.main_job == 14 then
        state.pet_origin      = 'wyvern'
        state.pet_expire_time = nil
    elseif state.main_job == 15 then
        state.pet_origin      = 'avatar'
        state.pet_expire_time = nil
    else
        state.pet_origin      = nil
        state.pet_expire_time = nil
    end
end

-- Familiar on self (BST 2-hr) adds 1500s (25 min) to charm duration.
local function extend_charm_duration(secs)
    if state.charm_expire_time then
        state.charm_expire_time = state.charm_expire_time + secs
    end
end

-------------------------------------------------------------------------------
local function hp_color(pct)
    if pct > 75 then return COLOR.white
    elseif pct > 50 then return COLOR.yellow
    elseif pct > 25 then return COLOR.orange
    else return COLOR.red end
end

local function tp_color(tp)
    if tp >= 1000 then return COLOR.tp_full end
    return COLOR.tp_normal
end

-------------------------------------------------------------------------------
-- ImGui rendering
-------------------------------------------------------------------------------
local function render_ready_move(ability_id)
    local resMgr = AshitaCore:GetResourceManager()
    local ability = resMgr and resMgr:GetAbilityById(ability_id)
    if ability == nil then return end
    local name = (ability.Name and ability.Name[1]) or ability.En or ''
    if name == '' then return end

    -- Filter: only render things we recognize as ready moves. The mappings
    -- module returns "unknown" for moves it has no data for.
    local cost = ready_move_mappings.get_ready_move_cost(name)
    if cost == 'unknown' or cost == nil then return end

    local cost_num = tonumber(cost) or 0
    local can_use = state.charges >= cost_num
    local color = can_use and COLOR.ready or COLOR.not_ready

    -- Render the row inside a group so IsItemClicked/Hovered below can
    -- span the whole line (icon + text). Clicking fires the move on the
    -- current target via /pet; the game silently ignores it if charges
    -- are insufficient or no valid target is selected.
    imgui.BeginGroup()
    if gConfig.bsthudShowIcons then
        local dtype = ready_move_mappings.get_ready_move_type(name)
        local tex = state.damage_textures[dtype]
        if tex ~= nil then
            imgui.Image(tonumber(ffi.cast('uint32_t', tex)), { 14, 14 })
            imgui.SameLine()
        end
    end
    imgui.TextColored(color, ('%s - %s'):format(name, tostring(cost)))
    imgui.EndGroup()

    if gConfig.bsthudClickable ~= false and imgui.IsItemHovered() then
        local cmd = ('/pet "%s" <t>'):format(name)
        if imgui.IsMouseClicked(0) then
            AshitaCore:GetChatManager():QueueCommand(-1, cmd)
        end
        imgui.BeginTooltip()
        imgui.Text(cmd)
        imgui.EndTooltip()
    end
end

local function render_hud()
    -- HXUI gates this module via gConfig.showBstHud; if DrawWindow is being
    -- called, we should render. force_hud still bypasses the job gate pause.
    if state.paused_for_job and not state.force_hud then return end

    imgui.SetNextWindowPos({ gConfig.bsthudPosX, gConfig.bsthudPosY }, ImGuiCond_FirstUseEver)
    imgui.SetNextWindowBgAlpha(gConfig.bsthudBgAlpha)

    -- AlwaysAutoResize makes the window shrink to exactly fit its contents, so
    -- the "no pet summoned" case is just two lines instead of a giant box.
    local flags = bit.bor(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoCollapse,
        ImGuiWindowFlags_AlwaysAutoResize
    )

    if imgui.Begin('BST-HUD', state.window_open, flags) then
        -- Sync position changes back into config so that window drags persist.
        -- Different Ashita builds expose slightly different imgui bindings; we
        -- try each common shape and fall back silently.
        local wx, wy
        local ok, res = pcall(function()
            if imgui.GetWindowPosVec4 ~= nil then return imgui.GetWindowPosVec4() end
            return imgui.GetWindowPos()
        end)
        if ok and res ~= nil then
            if type(res) == 'table' then
                wx, wy = res[1] or res.x, res[2] or res.y
            elseif type(res) == 'number' then
                wx = res
            end
        end
        if wx and wy then
            if math.abs(wx - gConfig.bsthudPosX) > 0.5 or math.abs(wy - gConfig.bsthudPosY) > 0.5 then
                gConfig.bsthudPosX = wx
                gConfig.bsthudPosY = wy
            end
        end

        if state.pet_active and state.pet_name then
            -- Header line: pet name
            imgui.TextColored(COLOR.header, state.pet_name)
            imgui.Separator()

            -- Pet image (shown alongside stats)
            if gConfig.bsthudShowImage and state.pet_image_tex ~= nil then
                imgui.Image(
                    tonumber(ffi.cast('uint32_t', state.pet_image_tex)),
                    { gConfig.bsthudImageSize, gConfig.bsthudImageSize }
                )
                imgui.SameLine()
            end

            imgui.BeginGroup()

            -- HP line
            imgui.Text('HP ')
            imgui.SameLine()
            imgui.TextColored(hp_color(state.current_hp_pct or 0), ('%d%%'):format(state.current_hp_pct or 0))
            if gConfig.bsthudShowBars then
                imgui.PushStyleColor(ImGuiCol_PlotHistogram, COLOR.hp_bar)
                imgui.ProgressBar((state.current_hp_pct or 0) / 100.0, { -1, 10 }, '')
                imgui.PopStyleColor()
            end

            -- TP line
            imgui.Text('TP ')
            imgui.SameLine()
            imgui.TextColored(tp_color(state.current_tp or 0), tostring(state.current_tp or 0))
            if gConfig.bsthudShowBars then
                imgui.PushStyleColor(ImGuiCol_PlotHistogram, COLOR.tp_bar)
                imgui.ProgressBar(math.min(1.0, (state.current_tp or 0) / 1000.0), { -1, 10 }, '')
                imgui.PopStyleColor()
            end

            -- Charges line (BST only). Compact format so "Next: Xs" doesn't
            -- get clipped when the auto-resize uses the pet-name line's width.
            if state.main_job == 9 then
                imgui.Text(('Charges: %d | Next: %ds'):format(state.charges, state.next_ready_recast))

                -- Pet duration line (BST only). XIUI-style:
                --   jug   -> remaining time from summon + jug-table duration
                --   charm -> remaining time from /check-derived expiry,
                --            or elapsed time as a fallback if /check was missed
                if state.pet_origin == 'jug' and state.pet_expire_time then
                    local remaining = state.pet_expire_time - os.time()
                    if remaining < 0 then remaining = 0 end
                    local col = COLOR.ready
                    if remaining <= 60            then col = COLOR.red
                    elseif remaining <= 5 * 60    then col = COLOR.orange
                    elseif remaining <= 15 * 60   then col = COLOR.yellow end
                    imgui.Text('Stay: ')
                    imgui.SameLine()
                    imgui.TextColored(col, fmt_mmss(remaining))
                elseif state.pet_origin == 'charm' then
                    if state.charm_expire_time then
                        local remaining = state.charm_expire_time - os.time()
                        if remaining < 0 then remaining = 0 end
                        local col = COLOR.ready
                        if remaining <= 30            then col = COLOR.red
                        elseif remaining <= 120       then col = COLOR.orange
                        elseif remaining <= 5 * 60    then col = COLOR.yellow end
                        imgui.Text('Charm: ')
                        imgui.SameLine()
                        imgui.TextColored(col, fmt_mmss(remaining))
                    elseif state.pet_summon_time > 0 then
                        local elapsed = os.time() - state.pet_summon_time
                        imgui.Text('Charm: ')
                        imgui.SameLine()
                        imgui.TextColored(COLOR.not_ready, fmt_mmss(elapsed) .. ' (unknown)')
                    end
                end
            end

            imgui.EndGroup()

            -- Pet status effects (buffs/debuffs). Rendered as a single
            -- comma-joined text row under the stats group. Uses Ashita's
            -- ResourceManager for display names; no icon assets required.
            -- NOTE: the reader is a best-effort fallback — XIUI's petbar uses
            -- handlers/petbuffhandler.lua which wasn't in the uploaded files,
            -- so on builds where player:GetPetStatusIcons() isn't exposed this
            -- list will be empty. Drop that module in and we can wire it.
            do
                local ids = get_pet_status_effects()
                if ids and #ids > 0 then
                    imgui.Separator()
                    imgui.Text('Effects:')
                    imgui.SameLine()
                    local parts = {}
                    for i = 1, math.min(#ids, 8) do
                        parts[i] = status_name(ids[i])
                    end
                    if #ids > 8 then parts[#parts + 1] = ('+%d'):format(#ids - 8) end
                    imgui.TextColored(COLOR.yellow, table.concat(parts, ', '))
                end
            end

            -- Job abilities (recast timers). XIUI shows a row per ability with
            -- a filling icon; we use a text list that mirrors the Charges line
            -- style. Entries whose recast slot can't be found (ability not yet
            -- learned, or unsupported by this Ashita build) are hidden.
            -- Each row is wrapped in a BeginGroup so a single mouse click on
            -- name OR recast text fires the ability's cmd (e.g. /ja "Steady
            -- Wing" <me>). Rows with no cmd (SMN Blood Pacts) still render
            -- but aren't clickable.
            local ability_list = PET_ABILITIES[state.main_job]
            if ability_list and #ability_list > 0 then
                imgui.Separator()
                imgui.Text('Abilities:')
                for _, a in ipairs(ability_list) do
                    local recast = get_ability_recast_by_id(a.id)
                    -- Render if we have a recast value, OR the entry opts
                    -- into always_show (used for abilities whose recast
                    -- slot may not always be readable, e.g. 2-hours).
                    if recast ~= nil or a.always_show then
                        imgui.BeginGroup()
                        imgui.Text(a.name .. ': ')
                        imgui.SameLine()
                        if recast == nil then
                            -- No readable recast. Best effort: show a
                            -- neutral dash so the user still sees the
                            -- clickable row. Colour it ready-green since
                            -- most of the time that's what it is.
                            imgui.TextColored(COLOR.ready, '--')
                        elseif recast <= 0 then
                            imgui.TextColored(COLOR.ready, 'Ready')
                        else
                            -- Tint yellow when the recast is close to done
                            -- (last 10 s) so the player can anticipate.
                            local col = COLOR.not_ready
                            if recast <= 10 then col = COLOR.yellow end
                            imgui.TextColored(col, fmt_recast(recast))
                        end
                        imgui.EndGroup()
                        -- Click-to-fire. cmd may be a string or a function
                        -- that returns a string (used for SMN Blood Pacts
                        -- so the favorite-BP config is resolved at click
                        -- time). Click only registers when resolution
                        -- yields a non-empty command.
                        local cmd = a.cmd
                        if type(cmd) == 'function' then
                            local ok, resolved = pcall(cmd)
                            cmd = ok and resolved or nil
                        end
                        if cmd and gConfig.bsthudClickable ~= false and imgui.IsItemHovered() then
                            if imgui.IsMouseClicked(0) then
                                AshitaCore:GetChatManager():QueueCommand(-1, cmd)
                            end
                            imgui.BeginTooltip()
                            imgui.Text(cmd)
                            imgui.EndTooltip()
                        end
                    end
                end
            end

            -- Ready moves (BST-specific: DRG/SMN don't have a charge system)
            if gConfig.bsthudShowMoves and state.main_job == 9 then
                imgui.Separator()
                imgui.Text('Ready Moves:')
                if state.ability_ids and #state.ability_ids > 0 then
                    for _, id in ipairs(state.ability_ids) do
                        render_ready_move(id)
                    end
                else
                    imgui.TextDisabled('(no abilities listed)')
                end
            end

            -- Pet's current target (matches petinfo's bottom panel).
            if gConfig.bsthudShowTarget and state.pet_target_server_id then
                local tidx = get_entity_index_by_server_id(state.pet_target_server_id)
                local tent = tidx and GetEntity and GetEntity(tidx) or nil
                if tent and tent.Name and tent.HPPercent and tent.HPPercent > 0 then
                    imgui.Separator()
                    imgui.TextColored(COLOR.header, tent.Name)
                    -- Right-align distance like petinfo
                    if tent.Distance and tent.Distance > 0 then
                        local dist = ('%.1f'):format(math.sqrt(tent.Distance))
                        local x_size = imgui.CalcTextSize(dist)
                        imgui.SameLine()
                        imgui.SetCursorPosX(imgui.GetCursorPosX() + imgui.GetColumnWidth() - x_size - imgui.GetStyle().FramePadding.x)
                        imgui.Text(dist)
                    end
                    imgui.Text('HP ')
                    imgui.SameLine()
                    imgui.TextColored(hp_color(tent.HPPercent), ('%d%%'):format(tent.HPPercent))
                    if gConfig.bsthudShowBars then
                        imgui.PushStyleColor(ImGuiCol_PlotHistogram, COLOR.hp_bar)
                        imgui.ProgressBar(tent.HPPercent / 100.0, { -1, 10 }, '')
                        imgui.PopStyleColor()
                    end
                else
                    -- Target gone or dead - clear so we don't keep scanning
                    state.pet_target_server_id = nil
                end
            end
        else
            -- No pet active. Surface a job-aware "summon" button so the
            -- player can kick off their pet from the HUD instead of tabbing
            -- out to the menu. Mirrors the clickable-abilities pattern used
            -- further up: BeginGroup + IsItemHovered/Clicked on the whole
            -- row. Respects the gConfig.bsthudClickable toggle - if clicks
            -- are disabled, the row still renders as a status line with the
            -- recast shown but isn't interactive.
            local function render_call_pet(timer_id, label, cmd, no_pet_text)
                local recast = get_ability_recast_by_id(timer_id)
                imgui.BeginGroup()
                imgui.TextDisabled(no_pet_text)
                if recast == nil or recast <= 0 then
                    imgui.TextColored(COLOR.ready, ('[ %s ]'):format(label))
                else
                    imgui.TextColored(COLOR.not_ready, ('[ %s  %s ]'):format(label, fmt_recast(recast)))
                end
                imgui.EndGroup()
                if gConfig.bsthudClickable ~= false and imgui.IsItemHovered() then
                    if imgui.IsMouseClicked(0) then
                        AshitaCore:GetChatManager():QueueCommand(-1, cmd)
                    end
                    imgui.BeginTooltip()
                    imgui.Text(cmd)
                    imgui.EndTooltip()
                end
            end

            if state.main_job == 14 then
                -- DRG: always Call Wyvern (timer id 163).
                render_call_pet(163, 'Call Wyvern', '/ja "Call Wyvern" <me>', 'No wyvern summoned.')
            elseif state.main_job == 9 then
                -- BST: Call Beast (timer id 104) consumes whatever jug is
                -- currently equipped in the ammo slot. No way to pick a
                -- specific jug from one button, so this just fires the
                -- generic /ja and lets the game use the equipped jug.
                render_call_pet(104, 'Call Beast', '/ja "Call Beast" <me>', 'No pet summoned.')
            else
                -- SMN and everyone else: no single "summon" ability makes
                -- sense (SMN has to pick an avatar), so keep the old
                -- passive message.
                imgui.TextDisabled('No pet summoned.')
                imgui.TextDisabled('Summon a pet to see its HUD.')
            end
        end
    end
    imgui.End()
end

-------------------------------------------------------------------------------
-- Module API: lifecycle
-------------------------------------------------------------------------------
function bsthud.Initialize(_settings)
    load_damage_textures()
    update_merits_and_jp()
    update_equip_reduction()
    check_job_gate()  -- Announces current pause state immediately
    -- If we already have a pet at load AND a pet job, detect it
    if not state.paused_for_job and get_pet_target_index() then
        make_visible()
    end
    log('Loaded as HXUI module. Use /bsthud help for power-user commands.')
end

function bsthud.Cleanup()
    release_pet_texture()
    state.damage_textures = T{}
    -- Drag-position is written into gConfig in-memory each frame; ask HXUI's
    -- settings system to flush so it survives a game restart even when the
    -- user only moved the window without touching the menu.
    local ok, settings = pcall(require, 'settings')
    if ok and settings and settings.save then
        pcall(settings.save)
    end
end

-- HXUI calls this in place of DrawWindow whenever the module should not
-- render this frame (e.g. /hxui partylist-style toggle off, or hidden during
-- events). bsthud uses imgui directly, so simply skipping DrawWindow makes
-- the window disappear — there's nothing to actively hide here. We keep the
-- function so HXUI's lifecycle is uniform and so we have a hook if we ever
-- need to release transient resources on hide.
function bsthud.SetHidden(_hidden)
    -- no-op
end

-------------------------------------------------------------------------------
-- Module API: command routing
-- HXUI.lua intercepts /bsthud (and /bst-hud) in its command_cb and forwards
-- the parsed args here. Returns true if the command was handled (so HXUI
-- can set e.blocked).
-------------------------------------------------------------------------------
function bsthud.HandleCommand(args)
    if not args or #args == 0 then return false end
    local cmd0 = (args[1] or ''):lower()
    if cmd0 ~= '/bsthud' and cmd0 ~= '/bst-hud' then return false end

    local sub = (args[2] or ''):lower()

    if sub == '' or sub == 'help' then
        log(':::   BST-HUD (HXUI module)   :::')
        log('Commands (prefix with /bsthud):')
        log('  image on|off             - toggle pet portrait')
        log('  bars on|off              - toggle HP/TP bars')
        log('  moves on|off             - toggle ready moves list')
        log('  icons on|off             - toggle damage-type icons')
        log('  target on|off            - toggle pet target HP panel')
        log('  click on|off             - toggle clickable abilities/ready moves')
        log('  pos <x> <y>              - set HUD position')
        log('  alpha <0..1>             - set background alpha')
        log('  chargebase <N|auto>      - override seconds per charge')
        log('  force hud [on|off]       - bypass the job-gate pause')
        log('  force fakepet [on|off]   - inject a fake pet for testing')
        log('  verbose                  - toggle verbose chat logging')
        log('  debug                    - toggle debug logging')
        log('  reload                   - reload textures')
        log('Note: master enable lives in /hxui -> Pet HUD -> Enabled.')
    elseif sub == 'image' then
        gConfig.bsthudShowImage = (args[3] or 'on'):lower() ~= 'off'
        if UpdateSettings then UpdateSettings() end
    elseif sub == 'bars' then
        gConfig.bsthudShowBars = (args[3] or 'on'):lower() ~= 'off'
        if UpdateSettings then UpdateSettings() end
    elseif sub == 'moves' then
        gConfig.bsthudShowMoves = (args[3] or 'on'):lower() ~= 'off'
        if UpdateSettings then UpdateSettings() end
    elseif sub == 'icons' then
        gConfig.bsthudShowIcons = (args[3] or 'on'):lower() ~= 'off'
        if UpdateSettings then UpdateSettings() end
    elseif sub == 'target' then
        gConfig.bsthudShowTarget = (args[3] or 'on'):lower() ~= 'off'
        if UpdateSettings then UpdateSettings() end
        log('Pet target panel: ' .. tostring(gConfig.bsthudShowTarget))
    elseif sub == 'click' then
        -- Click-to-fire on abilities and ready moves. Defaults to on when
        -- the setting is unset (nil), so /bsthud click off is the only way
        -- to disable it.
        gConfig.bsthudClickable = (args[3] or 'on'):lower() ~= 'off'
        if UpdateSettings then UpdateSettings() end
        log('Clickable HUD: ' .. tostring(gConfig.bsthudClickable))
    elseif sub == 'pos' then
        local x = tonumber(args[3]); local y = tonumber(args[4])
        if x and y then
            gConfig.bsthudPosX = x; gConfig.bsthudPosY = y
            if UpdateSettings then UpdateSettings() end
            log(('Position set to (%d, %d).'):format(x, y))
        else
            err('Usage: /bsthud pos <x> <y>')
        end
    elseif sub == 'alpha' then
        local a = tonumber(args[3])
        if a and a >= 0 and a <= 1 then
            gConfig.bsthudBgAlpha = a
            if UpdateSettings then UpdateSettings() end
        else
            err('Usage: /bsthud alpha <0..1>')
        end
    elseif sub == 'chargebase' then
        local v = args[3] or ''
        if v:lower() == 'auto' then
            config.charge_base_override = 0
        else
            local n = tonumber(v)
            if n and n > 0 then
                config.charge_base_override = n
            else
                err('Usage: /bsthud chargebase <N|auto>')
                return true
            end
        end
        log('Charge base: ' .. (config.charge_base_override == 0 and 'auto' or tostring(config.charge_base_override)))
    elseif sub == 'force' then
        local what = (args[3] or ''):lower()
        local mode = (args[4] or ''):lower()
        if what == 'hud' then
            if mode == 'off' then
                state.force_hud = false
            elseif mode == 'on' then
                state.force_hud = true
            else
                state.force_hud = not state.force_hud
            end
            log('force hud: ' .. tostring(state.force_hud))
        elseif what == 'fakepet' or what == 'pet' then
            if mode == 'off' then
                state.force_fake_pet = false
                make_invisible()
                log('force fakepet: off')
            elseif mode == 'on' then
                state.force_fake_pet = true
                state.force_hud = true
                apply_fake_pet()
                log('force fakepet: on (implies force hud: on)')
            else
                state.force_fake_pet = not state.force_fake_pet
                if state.force_fake_pet then
                    state.force_hud = true
                    apply_fake_pet()
                else
                    make_invisible()
                end
                log('force fakepet: ' .. tostring(state.force_fake_pet))
            end
        else
            err('Usage: /bsthud force hud [on|off]   or   /bsthud force fakepet [on|off]')
        end
    elseif sub == 'verbose' then
        config.verbose = not config.verbose
        log('Verbose: ' .. tostring(config.verbose))
    elseif sub == 'debug' then
        config.debug_mode = not config.debug_mode
        log('Debug: ' .. tostring(config.debug_mode))
    elseif sub == 'diag' then
        -- Report which optional modules loaded and whether the pet buff
        -- pipeline has everything it needs to function. Use this when the
        -- Effects row isn't updating to narrow down what's missing.
        log('--- Pet buff pipeline ---')
        log(('handlers.petbuffhandler: %s'):format(petBuff and 'LOADED' or 'MISSING'))
        if _petBuffLoadErr then
            log(('  reason: %s'):format(_petBuffLoadErr))
        end
        log(('libs.packets         : %s'):format(packets and 'LOADED' or 'MISSING'))
        if _packetsLoadErr then
            log(('  reason: %s'):format(_packetsLoadErr))
        end
        log(('GetPlayerEntity glob : %s'):format((type(GetPlayerEntity) == 'function') and 'present' or 'MISSING'))
        log(('GetEntity global     : %s'):format((type(GetEntity) == 'function') and 'present' or 'MISSING'))
        local ppe = (type(GetPlayerEntity) == 'function') and (pcall(GetPlayerEntity)) or false
        if ppe then
            local ok, pe = pcall(GetPlayerEntity)
            if ok and pe then
                log(('player PetTargetIndex : %s'):format(tostring(pe.PetTargetIndex)))
                if pe.PetTargetIndex and pe.PetTargetIndex ~= 0 and type(GetEntity) == 'function' then
                    local ok2, petEnt = pcall(GetEntity, pe.PetTargetIndex)
                    if ok2 and petEnt then
                        log(('pet ServerId          : %s'):format(tostring(petEnt.ServerId)))
                        log(('pet Name              : %s'):format(tostring(petEnt.Name)))
                    else
                        log('pet entity lookup failed')
                    end
                end
            end
        end
        if petBuff and petBuff.GetActiveEffects then
            local ok, ids, times = pcall(petBuff.GetActiveEffects)
            if ok then
                log(('active pet effects    : %d'):format(ids and #ids or 0))
                if ids then
                    for i = 1, #ids do
                        log(('  #%d id=%d time=%s'):format(i, ids[i], tostring(times and times[i] or 'nil')))
                    end
                end
            else
                log('GetActiveEffects error: ' .. tostring(ids))
            end
        end
    elseif sub == 'reload' then
        load_damage_textures()
        release_pet_texture()
        if state.pet_active then update_pet_image() end
        log('Reloaded textures.')
    else
        err('Unknown command. Try /bsthud help.')
    end
    return true
end

-------------------------------------------------------------------------------
-- Module API: per-frame draw (also runs lightweight polling)
-- HXUI calls this each frame from its own d3d_present handler when
-- gConfig.showBstHud is true. Polling is gated to ~10 Hz so we don't
-- thrash the memory manager every frame.
-------------------------------------------------------------------------------
function bsthud.DrawWindow(_settings)
    -- DRG opt-out: when the player's main job is Dragoon and the user has
    -- chosen to hide the pet HUD for DRG, bail out before any work. We still
    -- run check_job_gate first so state.main_job is accurate.
    check_job_gate()
    if state.main_job == 14 and gConfig and gConfig.bsthudShowOnDrg == false then
        return
    end

    local now = os.clock()
    if now - state.last_frame_time > 0.1 then
        state.last_frame_time = now

        if not state.paused_for_job or state.force_hud then
            if state.force_fake_pet then
                update_charges()
            else
                local idx = get_pet_target_index()
                if idx then
                    if not state.pet_active or state.pet_target_index ~= idx then
                        make_visible()
                    else
                        local newHpp = get_entity_field(idx, 'hpp') or 0
                        if newHpp ~= state.current_hp_pct then
                            state.current_hp_pct = newHpp
                        end
                        local newName = get_entity_field(idx, 'name')
                        if newName and newName ~= state.pet_name then
                            state.pet_name = newName
                            track_pet_summon(newName)
                            update_pet_image()
                        end
                        poll_pet_tp_from_memory()
                        state.current_mp_pct = poll_pet_mp_from_memory()
                    end
                else
                    if state.pet_active then
                        make_invisible()
                    end
                end

                update_charges()

                state.scan_timer = (state.scan_timer or 0) + 0.1
                if state.scan_timer > 2.0 then
                    state.scan_timer = 0
                    if state.pet_active then
                        update_ability_list()
                    end
                end
            end
        end
    end

    render_hud()
end

-- Packet IN handler: watch for pet status messages to catch pet TP (which
-- is not exposed via the entity table).
-------------------------------------------------------------------------------
-- Module API: incoming packets
-- HXUI.lua's packet_in_cb forwards every packet through here. We handle the
-- pet-related ones (0x067/0x068 sync, 0x044 puppet, 0x00E NPC update,
-- 0x028 action, 0x00A zone-in) and ignore the rest.
-------------------------------------------------------------------------------
function bsthud.HandlePacket(e)
    -- 0x067 / 0x068: Pet Sync packets
    if e.id == 0x067 or e.id == 0x068 then
        local msg_type = pkt_u8(e.data, 0x05)
        local pet_idx  = pkt_u16(e.data, 0x06)
        local own_idx  = pkt_u16(e.data, 0x08)

        -- 0x067 and 0x068 use opposite byte order for the two indices;
        -- the original Windower addon swaps them for 0x067.
        if msg_type == 0x04 and e.id == 0x067 then
            pet_idx, own_idx = own_idx, pet_idx
        end

        if msg_type == 0x04 then
            if pet_idx == 0 then
                vlog('Pet despawned (packet).')
                make_invisible()
            else
                if not state.pet_active then
                    make_visible()
                end
                local hp_pct = pkt_u8(e.data, 0x0A)
                local tp_val = pkt_u16(e.data, 0x0C)
                state.current_hp_pct = hp_pct
                update_pet_tp(tp_val)
            end
        elseif msg_type == 0x03 and not state.pet_active then
            local my_idx = get_player_target_index()
            if own_idx == my_idx then
                state.scan_timer = 0
                make_visible()
            end
        end
    end

    -- 0x044: Char Update (sub-type 0x12 is puppet info; kept for puppetmaster
    -- parity with the original). BST pets are handled via 0x067/0x068 above.
    if e.id == 0x044 then
        if pkt_u8(e.data, 0x05) == 0x12 then
            if state.pet_active then
                local cur_hp = pkt_u16(e.data, 0x69)
                local max_hp = pkt_u16(e.data, 0x6B)
                local name   = pkt_string(e.data, 0x59, 16)
                if name and #name > 0 and name ~= state.pet_name then
                    state.pet_name = name
                    update_pet_image()
                end
                if max_hp > 0 then
                    state.current_hp_pct = math.floor(100 * cur_hp / max_hp)
                end
            end
        end
    end

    -- 0x00E: NPC Update. Some pet spawn announcements arrive here.
    if e.id == 0x00E then
        state.scan_timer = 1.9
    end

    -- 0x028: Action packet. Pet target tracking via bit-stream offset 0x96.
    if e.id == 0x028 then
        -- Dispatch to pet buff handler FIRST, before any of the existing
        -- early returns. petBuff cares about packets where the pet is a
        -- target (for self-buffs from its own Ready moves) or where the
        -- player is actor (for buffs the player applies to the pet, like
        -- Steady Wing / Reward). Parsed via XIUI's libs.packets. Both
        -- modules are optional; if either isn't loaded we just skip here.
        if petBuff and packets and petBuff.HandleActionPacket and packets.ParseActionPacket then
            local ok_p, parsed = pcall(packets.ParseActionPacket, e)
            if ok_p and parsed then
                pcall(petBuff.HandleActionPacket, parsed)
            end
        end

        local actor = pkt_u32(e.data, 0x05)
        local me = get_player_server_id() or 0

        if state.pet_active and state.pet_server_id and actor == state.pet_server_id
           and ashita and ashita.bits and ashita.bits.unpack_be then
            local data_buf = e.data_modified or e.data
            local tbl = {}
            for i = 1, #data_buf do tbl[i] = data_buf:byte(i) end
            local ok, tid = pcall(function()
                return ashita.bits.unpack_be(tbl, 0x96, 0x20)
            end)
            if ok and tid and tid ~= 0 then
                state.pet_target_server_id = tid
            end
        end

        -- Familiar (action-info 0x618) used on self while charmed adds 25 min.
        if actor == me and state.pet_origin == 'charm' then
            local action_info = pkt_u16(e.data, 0x0A)
            if action_info == FAMILIAR_ACTION_INFO then
                vlog('Familiar detected -> charm +25 min')
                extend_charm_duration(1500)
            end
        end

        if actor ~= me then return end
        -- (Release detection is still handled in HandleOutgoingPacket via the expect_ready_move flag.)
    end

    -- 0x029: Incoming /check response. If we're mid-Charm, the response
    -- contains the target mob's level in param1; feed that into the PetMe
    -- formula to get an absolute expire time, and suppress the chat output
    -- so the player doesn't see the check line pop into their log.
    if e.id == PKT_IN_CHECK and state.charm_state == CHARM_STATE_CHECK_PACKET then
        -- param1 is a signed int32 at 0x0C, param2 is u32 at 0x10, msg is u16 at 0x18.
        local p1 = pkt_u32(e.data, 0x0C)
        if p1 >= 0x80000000 then p1 = p1 - 0x100000000 end   -- sign-extend
        local p2  = pkt_u32(e.data, 0x10)
        local msg = pkt_u16(e.data, 0x18)
        if (msg >= 0xAA and msg <= 0xB2) or (p2 >= 0x40 and p2 <= 0x47) then
            e.blocked = true
            local expiry = calculate_charm_expiry(p1)
            if expiry then
                state.charm_expire_time = expiry
                state.charm_start_time  = os.time()
                vlog(('Charm duration set: %d sec (mob lvl %d)'):format(expiry - os.time(), p1))
            end
        end
        state.charm_state = CHARM_STATE_NONE
        return
    end

    -- 0x029: Dispatch to pet buff handler (when loaded). Standard 0x029 layout
    -- is actor_id(u32 @ 0x04), target_id(u32 @ 0x08), param1(u32 @ 0x0C),
    -- message(u16 @ 0x18). petbuffhandler uses these to detect buff "gains
    -- effect" / "wears off" notifications on the pet. Wrapped in pcall so a
    -- bad packet or a handler error can never kill the module.
    if petBuff and e.id == PKT_IN_CHECK and petBuff.HandleMessagePacket then
        pcall(petBuff.HandleMessagePacket, {
            sender  = pkt_u32(e.data, 0x04),
            target  = pkt_u32(e.data, 0x08),
            param   = pkt_u32(e.data, 0x0C),
            message = pkt_u16(e.data, 0x18),
        })
    end

    -- 0x068: pet target server-id at offset 0x14 when owner-id at 0x08 is us.
    -- Tracked separately so we don't disturb the pet HP/TP logic above.
    if e.id == 0x068 and state.pet_active then
        local owner_sid = pkt_u32(e.data, 0x08)
        local me = get_player_server_id() or 0
        if owner_sid == me then
            local target_id = pkt_u32(e.data, 0x14)
            if target_id and target_id ~= 0 then
                state.pet_target_server_id = target_id
            end
        end
    end

    -- 0x00A: Zone in. Refresh merits/JP/equip since zoning resets gear state.
    if e.id == 0x00A then
        make_invisible()
        update_merits_and_jp()
        update_equip_reduction()
        if petBuff and petBuff.HandleZonePacket then
            pcall(petBuff.HandleZonePacket)
        end
    end
end

-------------------------------------------------------------------------------
-- Module API: outgoing packets
-- HXUI.lua's packet_out handler (added as part of this module integration)
-- forwards every outgoing packet through here. We watch for Call Beast /
-- Bestial Loyalty / Release / Ready ability uses.
-------------------------------------------------------------------------------
function bsthud.HandleOutgoingPacket(e)
    -- /check packet re-target: if we just used Charm, rewrite the outgoing
    -- /check to point at the mob we tried to charm (not the player's current
    -- target). XIUI fires /check via the chat manager; the packet goes out a
    -- moment later and lands here.
    if e.id == PKT_OUT_CHECK and state.charm_state == CHARM_STATE_SENDING_PACKET then
        -- Layout (1-indexed in Lua strings): bytes 5-6 = target id (u16),
        -- bytes 9-10 = target index (u16). Rewrite those four bytes in place
        -- and set e.data_modified so the server sees the retargeted check.
        local tid, tidx = state.charm_target_id or 0, state.charm_target_idx or 0
        local chars = {}
        for i = 1, #e.data do chars[i] = string.char(e.data:byte(i)) end
        chars[5]  = string.char(tid  % 256)
        chars[6]  = string.char(math.floor(tid / 256) % 256)
        chars[9]  = string.char(tidx % 256)
        chars[10] = string.char(math.floor(tidx / 256) % 256)
        e.data_modified = table.concat(chars)
        state.charm_state = CHARM_STATE_CHECK_PACKET
        return
    end

    if e.id ~= PKT_OUT_ACTION then return end
    local param    = pkt_u16(e.data, 0x0C)
    local category = pkt_u16(e.data, 0x0A)
    local resMgr   = AshitaCore:GetResourceManager()
    if category ~= 9 then return end  -- 9 = Job Ability

    -- Before resolving by name, catch Charm directly by id so we don't miss
    -- it if the resource manager is unavailable.
    if param == CHARM_ACTION_ID and state.pet_origin == nil then
        -- Capture target (what we're trying to charm) and queue a /check.
        -- The outgoing /check packet above will be retargeted at this id.
        state.charm_state      = CHARM_STATE_SENDING_PACKET
        state.charm_target_id  = pkt_u16(e.data, 0x04)
        state.charm_target_idx = pkt_u16(e.data, 0x08)
        vlog(('Charm attempt -> target id=%d idx=%d, firing /check'):format(
             state.charm_target_id, state.charm_target_idx))
        AshitaCore:GetChatManager():QueueCommand(1, '/check')
        return
    end

    local ability = resMgr and resMgr:GetAbilityById(param)
    if ability == nil then return end
    local name = (ability.Name and ability.Name[1]) or ability.En or ''
    if name == 'Call Beast' or name == 'Bestial Loyalty' then
        vlog('BST summon detected: ' .. name)
        make_invisible()
        state.scan_timer = 1.9
    elseif name == 'Release' then
        vlog('Release detected; resetting TP.')
        reset_stored_tp()
    elseif ability.Type and ability.Type == 14 then
        state.expect_ready_move = true
    end
end

return bsthud