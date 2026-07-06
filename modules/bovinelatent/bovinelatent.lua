--[[
* XIUI module: bovinelatent
* Latent trial WS/skillchain point tracker.
*
* Counts YOUR weapon skills while a trial weapon ("... of Trials") is in the
* main slot. Points per https://horizonffxi.wiki/Weapon_Skill_Points:
*     Solo WS               -> 1 pt
*     Close Lv1 skillchain  -> 2 pts
*     Close Lv2 skillchain  -> 3 pts
*     Close Lv3 skillchain  -> 5 pts
* PLAYER-ONLY: the action packet's actor must be this character's server id.
* Someone else closing a chain on your mob counts nothing.
*
* Per-weapon counts persist in current_trial.json IN THIS MODULE'S FOLDER
* (modules/bovinelatent/), reloading on init.
*
* Registry contract (core_modulesregistry.lua): Initialize, DrawWindow,
* UpdateVisuals, SetHidden, Cleanup. Packet watching is self-contained via
* this module's own packet_in registration (removed in Cleanup).
]]--

local imgui = require('imgui');

local M = {};

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------

local player_id = 0;
local trials = {};              -- ['Dagger of Trials'] = {solo=,lvl1=,lvl2=,lvl3=}
local current_weapon = '';
local current_is_trial = false;
local weapon_checked_at = 0.0;
local hidden = false;
local packet_event_registered = false;

local module_settings = nil;    -- gAdjustedSettings slice, from Initialize

-- Trial completion. Once a weapon's total reaches this, we fire the flash
-- and echo, one time only per weapon (finished[name] = true means the echo
-- has already gone out; the flash keeps playing as long as the total stays
-- at/above the threshold).
local FINISH_THRESHOLD = 300;
local finished = {};            -- ['Dagger of Trials'] = true (echo fired)

-- Chaosbringer trial: DRK weapon. Kill counter goes up by 1 when the player
-- LAST-HIT (melee) a mob, defeats it, and gains XP -- DoT-only, WS, or
-- pet/party kills don't count. State machine below cross-checks three chat
-- lines that must arrive in order within short windows.
local CHAOSBRINGER_NAME = 'Chaosbringer';
local chaos_kills = 0;

-- Chaosbringer trial milestones. Each fires a rainbow /echo the first time
-- kills crosses the mark; the flag is cleared when Reset is used so re-runs
-- announce again.
local CHAOS_MILESTONE_DRK   = 100;    -- "DRK Unlocked!"
local CHAOS_MILESTONE_BLADE = 200;    -- "Blade of Death Unlocked!"
local chaos_milestone_hit = {};       -- [100]=true, [200]=true (one-shot flags)

local KILL_WINDOW_SEC = 6.0;                 -- last melee hit -> defeat window
local XP_WINDOW_SEC   = 5.0;                 -- defeat -> XP line window

-- Per-mob credit state: last_melee_hit[<Mob Name>] = { at=<time>, weapon=<name> }.
-- Weapon captured AT HIT TIME so a swap between hit and defeat can't count.
local last_melee_hit = {};
local pending_kill_at     = 0.0;         -- time we saw "Player defeats" with a valid melee credit
local pending_kill_mob    = '';          -- mob name from that defeat line
local pending_kill_weapon = '';          -- weapon that landed the killing hit
local escaped_name        = '';          -- cached pattern-escaped player name

---------------------------------------------------------------------
-- SKILLCHAIN PROPERTY TABLES (from the chains addon)
---------------------------------------------------------------------

local SKILL_PROP_NAMES = {
    [1]  = 'Light',
    [2]  = 'Darkness',
    [3]  = 'Gravitation',
    [4]  = 'Fragmentation',
    [5]  = 'Distortion',
    [6]  = 'Fusion',
    [7]  = 'Compression',
    [8]  = 'Liquefaction',
    [9]  = 'Induration',
    [10] = 'Reverberation',
    [11] = 'Transfixion',
    [12] = 'Scission',
    [13] = 'Detonation',
    [14] = 'Impaction',
    [15] = 'Radiance',
    [16] = 'Umbra',
};

-- Radiance/Umbra are the level-4 ultimates; count as level 3 for trials.
local PROP_LEVEL = {
    Light         = 3,
    Darkness      = 3,
    Radiance      = 3,
    Umbra         = 3,
    Gravitation   = 2,
    Fragmentation = 2,
    Distortion    = 2,
    Fusion        = 2,
    Compression   = 1,
    Liquefaction  = 1,
    Induration    = 1,
    Reverberation = 1,
    Transfixion   = 1,
    Scission      = 1,
    Detonation    = 1,
    Impaction     = 1,
};

---------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------

local function now_sec()
    return os.clock();
end

local function counts_for(weapon)
    local c = trials[weapon];
    if c == nil then
        c = { solo = 0, lvl1 = 0, lvl2 = 0, lvl3 = 0 };
        trials[weapon] = c;
    end
    return c;
end

local function total_points(c)
    return c.solo * 1 + c.lvl1 * 2 + c.lvl2 * 3 + c.lvl3 * 5;
end

-- Emit a private, safe /echo. Everything after the leading `/echo ` is
-- treated as a PRIVATE local message by FFXI, so we can NEVER accidentally
-- leak it to /say. QueueCommand mode 1 = command (not chat). The color
-- escapes are Ashita's rainbow byte sequences (`\x1F<byte>`), which change
-- the color of subsequent text within the echo.
local function safe_echo(text)
    local ok, cm = pcall(function() return AshitaCore:GetChatManager(); end);
    if ok and cm then
        pcall(function() cm:QueueCommand(1, '/echo ' .. text); end);
    end
end

-- Rainbow-color a text string using FFXI's \x1F<byte> color codes so it
-- stands out in chat. Used by finish + milestone echoes.
-- Color bytes: 05=red, 06=purple, 07=green, 08=cyan, 09=yellow,
-- 0F=orange-ish yellow, 21=hot pink, 1C=magenta. These are the palette
-- FFXI's own /echo consumes; the ASCII-range bytes I used before were
-- not recognized by the client and rendered as normal text.
local function rainbow_text(text)
    local colors = { 0x05, 0x06, 0x07, 0x08, 0x09, 0x0F, 0x1C, 0x21 };
    local out = '';
    for i = 1, #text do
        out = out .. string.char(0x1F, colors[((i - 1) % #colors) + 1]) .. text:sub(i, i);
    end
    return out .. string.char(0x1F, 0x01);
end

local function fire_finish_echo(weapon)
    safe_echo(rainbow_text(weapon) .. ' -- Weapon Trial has finished!');
end

-- Chaosbringer milestone echoes. Fires once per threshold; the flag resets
-- when Reset zeroes the counter.
local function check_chaos_milestones()
    if chaos_kills >= CHAOS_MILESTONE_DRK and chaos_milestone_hit[CHAOS_MILESTONE_DRK] ~= true then
        chaos_milestone_hit[CHAOS_MILESTONE_DRK] = true;
        safe_echo(rainbow_text('DRK Unlocked!'));
    end
    if chaos_kills >= CHAOS_MILESTONE_BLADE and chaos_milestone_hit[CHAOS_MILESTONE_BLADE] ~= true then
        chaos_milestone_hit[CHAOS_MILESTONE_BLADE] = true;
        safe_echo(rainbow_text('Blade of Death Unlocked!'));
    end
end

local function check_finish(weapon, c)
    if weapon == '' or c == nil then return; end
    if total_points(c) < FINISH_THRESHOLD then return; end
    if finished[weapon] == true then return; end
    finished[weapon] = true;
    -- Respect the "Rainbow Flash on Finish" checkbox for the echo too --
    -- the flash and echo are one feature (the completion notification).
    local cfg = rawget(_G, 'gConfig');
    if cfg and cfg.bovinelatentRainbowOnFinish == false then return; end
    fire_finish_echo(weapon);
end

local function get_player_id()
    local ok, id = pcall(function()
        return AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0);
    end);
    if ok then return tonumber(id) or 0; end
    return 0;
end

---------------------------------------------------------------------
-- EQUIPPED WEAPON (main slot 0), cached ~1/sec
---------------------------------------------------------------------

local function read_equipped_weapon_name()
    local ok, name = pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory();
        if not inv then return ''; end
        local ee = inv:GetEquippedItem(0);   -- slot 0 = main weapon
        if not ee or ee.Index == 0 then return ''; end
        local idx = bit.band(ee.Index, 0x00FF);
        local container = bit.band(bit.rshift(ee.Index, 8), 0x00FF);
        local item = inv:GetContainerItem(container, idx);
        if not item or item.Id == 0 then return ''; end
        local res = AshitaCore:GetResourceManager():GetItemById(item.Id);
        if not res then return ''; end
        return tostring(res.Name[1] or '');
    end);
    if ok and type(name) == 'string' then return name; end
    return '';
end

local function refresh_weapon(force)
    local now = now_sec();
    if not force and (now - weapon_checked_at) < 1.0 then return; end
    weapon_checked_at = now;
    current_weapon = read_equipped_weapon_name();
    current_is_trial = current_weapon:lower():find('of trials', 1, true) ~= nil;
end

---------------------------------------------------------------------
-- JSON PERSISTENCE -- current_trial.json lives in this module's folder
---------------------------------------------------------------------

local function trial_file_path()
    return addon.path .. 'modules/bovinelatent/current_trial.json';
end

local function json_escape(s)
    return tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"');
end

local function save_trials()
    -- Safety: never overwrite an existing populated file with an empty
    -- state. If the loader failed to parse anything but the file was
    -- non-empty, dumping the empty trials table to disk would nuke the
    -- user's data. Only save if we have something to save, OR the file
    -- doesn't already exist.
    local have_any = (chaos_kills or 0) > 0;
    if not have_any then
        for _ in pairs(trials) do have_any = true; break; end
    end
    if not have_any then
        local check = io.open(trial_file_path(), 'r');
        if check then
            local existing = check:read('*a') or '';
            check:close();
            if #existing > 4 then return; end   -- non-trivial file exists, don't clobber
        end
    end

    local f = io.open(trial_file_path(), 'w');
    if not f then return; end
    f:write('{\r\n');
    f:write(string.format('  "chaosbringer_kills": %d,\r\n', chaos_kills));
    f:write('  "weapons": {\r\n');
    local first = true;
    for weapon, c in pairs(trials) do
        if not first then f:write(',\r\n'); end
        first = false;
        f:write(string.format(
            '    "%s": { "solo": %d, "lvl1": %d, "lvl2": %d, "lvl3": %d, "total": %d }',
            json_escape(weapon), c.solo, c.lvl1, c.lvl2, c.lvl3, total_points(c)));
    end
    f:write('\r\n  }\r\n}\r\n');
    f:close();
end

local function load_trials()
    local f = io.open(trial_file_path(), 'r');
    if not f then return; end
    local text = f:read('*a') or '';
    f:close();

    -- Back up the file we're about to load from BEFORE parsing. If parsing
    -- goes sideways we still have the original bytes on disk under .bak.
    if #text > 0 then
        local bak = io.open(trial_file_path() .. '.bak', 'w');
        if bak then bak:write(text); bak:close(); end
    end

    chaos_kills = tonumber(text:match('"chaosbringer_kills"%s*:%s*(%d+)')) or 0;

    -- Two-stage parse for the weapons block:
    --   1. If there's a "weapons": { ... } wrapper (current format), extract
    --      its inner body and parse weapon entries out of THAT. Otherwise
    --      %b{} at the top level consumes the whole wrapper including our
    --      real entries, and gmatch on the outer text sees zero weapons.
    --   2. If there's no "weapons" wrapper (old flat format), parse the
    --      whole file directly.
    local weapons_body = text:match('"weapons"%s*:%s*(%b{})');
    local search_in = weapons_body or text;

    for weapon, body in search_in:gmatch('"([^"]+)"%s*:%s*(%b{})') do
        if weapon ~= 'weapons' then
            local c = counts_for(weapon:gsub('\\"', '"'):gsub('\\\\', '\\'));
            c.solo = tonumber(body:match('"solo"%s*:%s*(%d+)')) or 0;
            c.lvl1 = tonumber(body:match('"lvl1"%s*:%s*(%d+)')) or 0;
            c.lvl2 = tonumber(body:match('"lvl2"%s*:%s*(%d+)')) or 0;
            c.lvl3 = tonumber(body:match('"lvl3"%s*:%s*(%d+)')) or 0;
        end
    end
end

---------------------------------------------------------------------
-- ACTION PACKET PARSE (trimmed chains/tHotBar pattern). Reads only the
-- first target's first action + AdditionalEffect -- sequential bit
-- reads, so stopping early is safe.
---------------------------------------------------------------------

local function parse_ws_action(e)
    local max_bits = e.size * 8;
    local offset = 40;

    local function unpack_bits(len)
        if (offset + len) > max_bits then return nil; end
        local v = ashita.bits.unpack_be(e.data_raw, 0, offset, len);
        offset = offset + len;
        return v;
    end

    local pkt = {};
    pkt.UserId = unpack_bits(32);
    local target_count = unpack_bits(6);
    offset = offset + 4;                     -- unknown
    pkt.Type = unpack_bits(4);
    pkt.Id = unpack_bits(32);
    offset = offset + 32;                    -- recast / unknown

    if pkt.UserId == nil or target_count == nil or target_count < 1 then
        return nil;
    end

    pkt.TargetId = unpack_bits(32);
    local action_count = unpack_bits(4);
    if action_count == nil or action_count < 1 then return nil; end

    local act = {};
    act.Reaction      = unpack_bits(5);
    act.Animation     = unpack_bits(12);
    act.SpecialEffect = unpack_bits(7);
    act.Knockback     = unpack_bits(3);
    act.Param         = unpack_bits(17);
    act.Message       = unpack_bits(10);
    act.Flags         = unpack_bits(31);

    local has_add = unpack_bits(1);
    if has_add == 1 then
        local add = {};
        add.Damage  = unpack_bits(10);       -- {effect[3:0], animation[5:0]}
        add.Param   = unpack_bits(17);
        add.Message = unpack_bits(10);
        act.AdditionalEffect = add;
    end

    pkt.Action = act;
    return pkt;
end

---------------------------------------------------------------------
-- CHAOSBRINGER (DRK) KILL TRACKING via chat lines
---------------------------------------------------------------------

-- Escape lua-magic chars in the player name so it plugs into patterns.
local function pattern_escape_name(name)
    return (name or ''):gsub('([^%w])', '%%%1');
end

local function ensure_player_name_cached()
    if escaped_name ~= '' then return; end
    local ok, name = pcall(function()
        local p = AshitaCore:GetMemoryManager():GetParty();
        if not p then return ''; end
        return tostring(p:GetMemberName(0) or '');
    end);
    if ok and type(name) == 'string' and #name > 0 then
        escaped_name = pattern_escape_name(name);
    end
end

-- Prune stale melee-hit credits so they can't false-positive a later kill.
local function prune_melee_credits(now)
    for mob, entry in pairs(last_melee_hit) do
        if (now - (entry.at or 0)) > KILL_WINDOW_SEC then
            last_melee_hit[mob] = nil;
        end
    end
end

-- Consume a pending kill on the XP line and credit one Chaosbringer kill.
-- The weapon check happens at hit-time / defeat-time (see on_text_in), NOT
-- here -- you could swap weapons between the defeat and the XP line and it
-- must not count.
local function credit_chaos_kill()
    chaos_kills = chaos_kills + 1;
    save_trials();
    check_chaos_milestones();
end

local function on_text_in(e)
    -- Only look at rendered mode (final display text). e.mode filters the
    -- lower-half chat modes; keep it broad and match on text instead.
    local raw = e.message;
    if type(raw) ~= 'string' or #raw == 0 then return; end

    ensure_player_name_cached();
    if escaped_name == '' then return; end

    -- Strip Ashita/FFXI auto-translate + color escape bytes so patterns work
    -- against clean text.
    local text = raw:gsub('\x1E.', ''):gsub('\x1F.', '');
    local now = now_sec();

    prune_melee_credits(now);

    -- Player melee hit: "<Name> hits the <Mob> for N points of damage."
    -- Grab the mob name and stamp it WITH the weapon currently equipped.
    -- The weapon check for Chaosbringer credit happens at defeat-time using
    -- this stamp -- if the player swaps weapons before landing another hit,
    -- the credit is stale/wrong-weapon.
    local mob = text:match('^' .. escaped_name .. ' hits the (.+) for %d+ points? of damage%.')
             or text:match('^' .. escaped_name .. ' hits the (.+) for %d+ point of damage%.');
    if mob then
        refresh_weapon(true);
        last_melee_hit[mob] = { at = now, weapon = current_weapon };
        return;
    end

    -- Player WS use: "<Name> uses <WS>." -- invalidates all pending melee
    -- credits (the next damage line will be WS, not melee). Bare "uses"
    -- also catches JAs and items, which is fine since those don't count
    -- either.
    if text:match('^' .. escaped_name .. ' uses ') then
        last_melee_hit = {};
        return;
    end

    -- Player defeat: "<Name> defeats the <Mob>." -- must have a fresh
    -- melee-hit credit for THIS mob AND that hit must have been with
    -- Chaosbringer to arm the pending kill.
    local defeated = text:match('^' .. escaped_name .. ' defeats the (.+)%.');
    if defeated then
        local entry = last_melee_hit[defeated];
        if entry and entry.at > 0 and (now - entry.at) <= KILL_WINDOW_SEC
           and entry.weapon == CHAOSBRINGER_NAME then
            pending_kill_at = now;
            pending_kill_mob = defeated;
            pending_kill_weapon = entry.weapon;
        end
        last_melee_hit[defeated] = nil;
        return;
    end

    -- XP grant: "<Name> gains N experience points." -- the third gate.
    -- Chaosbringer wiki notes trials require XP-yielding kills, so a mob
    -- that grants nothing (grey con, capped, mission-locked) shouldn't
    -- count and won't produce this line.
    if pending_kill_at > 0 and (now - pending_kill_at) <= XP_WINDOW_SEC then
        if text:match('^' .. escaped_name .. ' gains %d+ experience points?%.') then
            pending_kill_at = 0.0;
            pending_kill_mob = '';
            pending_kill_weapon = '';
            credit_chaos_kill();
        end
    end
end

local function on_packet_in(e)
    if e.id ~= 0x28 then return; end

    -- Quick type check before a full parse: type 3 = Weapon Skill finish.
    local ptype = ashita.bits.unpack_be(e.data_raw, 0, 82, 4);
    if ptype ~= 3 then return; end

    local pkt = parse_ws_action(e);
    if not pkt or pkt.Action == nil then return; end

    -- PLAYER ONLY: the WS actor must be this character. Other players
    -- (or pets) skillchaining on the same mob count nothing.
    if player_id == 0 then player_id = get_player_id(); end
    if player_id == 0 or pkt.UserId ~= player_id then return; end

    -- Only while a trial weapon is equipped; re-read now so a fresh swap
    -- is respected.
    refresh_weapon(true);
    if not current_is_trial then return; end

    local c = counts_for(current_weapon);

    local level = 0;
    local add = pkt.Action.AdditionalEffect;
    if add ~= nil and add.Damage ~= nil then
        local prop = SKILL_PROP_NAMES[bit.band(add.Damage, 0x3F)];
        if prop ~= nil then
            level = PROP_LEVEL[prop] or 0;
        end
    end

    if level >= 3 then
        c.lvl3 = c.lvl3 + 1;
    elseif level == 2 then
        c.lvl2 = c.lvl2 + 1;
    elseif level == 1 then
        c.lvl1 = c.lvl1 + 1;
    else
        c.solo = c.solo + 1;
    end

    save_trials();
    check_finish(current_weapon, c);
end

---------------------------------------------------------------------
-- MODULE INTERFACE (core_modulesregistry contract)
---------------------------------------------------------------------

function M.Initialize(settings)
    module_settings = settings;
    player_id = get_player_id();
    load_trials();
    refresh_weapon(true);

    if not packet_event_registered then
        ashita.events.register('packet_in', 'bovinelatent_packet_in', on_packet_in);
        ashita.events.register('text_in',   'bovinelatent_text_in',   on_text_in);
        packet_event_registered = true;
    end
end

function M.UpdateVisuals(settings)
    module_settings = settings;
end

function M.SetHidden(state)
    hidden = (state == true);
end

function M.Cleanup()
    save_trials();
    if packet_event_registered then
        ashita.events.unregister('packet_in', 'bovinelatent_packet_in');
        ashita.events.unregister('text_in',   'bovinelatent_text_in');
        packet_event_registered = false;
    end
end

-- Reset the currently equipped trial weapon's counts (config menu hook).
function M.ResetCurrent()
    refresh_weapon(true);
    if current_is_trial then
        trials[current_weapon] = { solo = 0, lvl1 = 0, lvl2 = 0, lvl3 = 0 };
        finished[current_weapon] = nil;
        save_trials();
    end
end

-- Zero the named weapon's counts (config menu list button).
function M.ResetWeapon(name)
    if type(name) ~= 'string' or name == '' then return; end
    trials[name] = { solo = 0, lvl1 = 0, lvl2 = 0, lvl3 = 0 };
    finished[name] = nil;
    save_trials();
end

-- Add N solo WS points to a named weapon (config menu +10 / +50 / +100
-- buttons). Creates the weapon entry if it doesn't exist yet.
function M.AddSolo(name, count)
    if type(name) ~= 'string' or name == '' then return; end
    local n = tonumber(count) or 0;
    if n <= 0 then return; end
    local c = counts_for(name);
    c.solo = (c.solo or 0) + n;
    save_trials();
    check_finish(name, c);
end

-- Snapshot of all tracked weapons as an alpha-sorted list, for the config
-- UI. Each entry: { name, solo, lvl1, lvl2, lvl3, total }.
function M.GetTrials()
    local list = {};
    for weapon, c in pairs(trials) do
        list[#list + 1] = {
            name  = weapon,
            solo  = c.solo,
            lvl1  = c.lvl1,
            lvl2  = c.lvl2,
            lvl3  = c.lvl3,
            total = total_points(c),
        };
    end
    table.sort(list, function(a, b) return a.name < b.name; end);
    return list;
end

-- Chaosbringer kill count (Dark Knight trial).
function M.GetChaosbringerKills()
    return chaos_kills or 0;
end

function M.ResetChaosbringer()
    chaos_kills = 0;
    chaos_milestone_hit = {};
    save_trials();
end

function M.AddChaosbringerKills(count)
    local n = tonumber(count) or 0;
    if n <= 0 then return; end
    chaos_kills = (chaos_kills or 0) + n;
    save_trials();
    check_chaos_milestones();
end

function M.DrawWindow(settings)
    if hidden then return; end
    module_settings = settings or module_settings;

    -- Hidden Window: read the shared gConfig checkbox. When on, we skip the
    -- whole draw regardless of whether a trial weapon is equipped.
    local cfg = rawget(_G, 'gConfig');
    if cfg and cfg.bovinelatentHidden == true then return; end
    local rainbow_on = not cfg or cfg.bovinelatentRainbowOnFinish ~= false;

    refresh_weapon(false);

    -- No trial weapon equipped -> nothing to show. Skip the window entirely
    -- (Dedication tracker follows the same pattern -- window hidden when
    -- there's no active context, tracker data persists in memory).
    if not current_is_trial then return; end

    imgui.SetNextWindowSize({ 240, 0 }, ImGuiCond_FirstUseEver);
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 8.0);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 6.0);
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.08, 0.08, 0.10, 0.92 });
    imgui.PushStyleColor(ImGuiCol_TitleBg, { 0.13, 0.12, 0.18, 1.0 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive, { 0.22, 0.18, 0.32, 1.0 });

    -- Window open flag: passing this as the `p_open` arg makes imgui draw an
    -- X (close) button in the title bar. If the user clicks X, imgui sets
    -- the value to false; we detect that and flip bovinelatentHidden ON in
    -- gConfig so the window stays hidden until they turn it back on from
    -- the config menu.
    local win_open = { true };
    local drew = imgui.Begin('Latent Trial##bovinelatent', win_open, ImGuiWindowFlags_NoCollapse);
    if not win_open[1] and cfg then
        cfg.bovinelatentHidden = true;
    end
    if drew then
        if current_is_trial then
            local c = counts_for(current_weapon);
            local tot = total_points(c);
            local is_finished = (tot >= FINISH_THRESHOLD);

            imgui.PushStyleColor(ImGuiCol_Text, { 0.85, 0.75, 1.0, 1.0 });
            imgui.Text(current_weapon);
            imgui.PopStyleColor();
            imgui.Separator();

            local function row(label, count, pts)
                imgui.Text(string.format('%-6s', label));
                imgui.SameLine(70);
                imgui.PushStyleColor(ImGuiCol_Text, { 1.0, 1.0, 1.0, 1.0 });
                imgui.Text(string.format('%4d', count));
                imgui.PopStyleColor();
                imgui.SameLine(130);
                imgui.PushStyleColor(ImGuiCol_Text, { 0.55, 0.55, 0.60, 1.0 });
                imgui.Text(string.format('(%d pts)', count * pts));
                imgui.PopStyleColor();
            end

            row('Solo',  c.solo, 1);
            row('Lvl 1', c.lvl1, 2);
            row('Lvl 2', c.lvl2, 3);
            row('Lvl 3', c.lvl3, 5);

            imgui.Separator();

            -- Rainbow flash on finish: cycle the total's text color through
            -- the spectrum via HSV -> RGB by wall-clock time. Otherwise the
            -- normal green.
            if is_finished and rainbow_on then
                local t = os.clock() * 1.2;                 -- ~cycle speed
                local h = t - math.floor(t);                 -- 0..1
                local i = math.floor(h * 6);
                local f = (h * 6) - i;
                local q = 1 - f;
                local r, g, b = 1, 1, 1;
                if     i == 0 then r,g,b = 1, f, 0;
                elseif i == 1 then r,g,b = q, 1, 0;
                elseif i == 2 then r,g,b = 0, 1, f;
                elseif i == 3 then r,g,b = 0, q, 1;
                elseif i == 4 then r,g,b = f, 0, 1;
                else               r,g,b = 1, 0, q; end
                imgui.PushStyleColor(ImGuiCol_Text, { r, g, b, 1.0 });
                imgui.Text(string.format('Total  %d  (COMPLETE!)', tot));
                imgui.PopStyleColor();
            else
                imgui.PushStyleColor(ImGuiCol_Text, { 0.55, 1.0, 0.65, 1.0 });
                imgui.Text(string.format('Total  %d', tot));
                imgui.PopStyleColor();
            end
        end
    end
    imgui.End();

    imgui.PopStyleColor(3);
    imgui.PopStyleVar(2);
end

return M;