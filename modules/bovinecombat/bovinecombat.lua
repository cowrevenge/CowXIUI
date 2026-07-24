--[[
* XIUI module: bovinecombat
* "Time Since Last Attack / Defence" combat-round timers.
*
* Ported from the bovinebattle addon's attack-timing system. Watches the chat
* log via text_in for the player's own melee rounds and for mobs hitting the
* player, stamping a timestamp on each. The window then shows the elapsed time
* since each, so you can eyeball your swing cadence and incoming-hit cadence.
*
* Detection is chat-text based (matching bovinebattle exactly), not packet
* based, so it depends on the combat log format and the player's name. A 0.35s
* burst window collapses multi-hit rounds (Double/Triple Attack, Kick Attacks,
* tight Haste rounds) into a single round so the timer doesn't reset on every
* sub-hit.
*
* Only counts while ENGAGED (player Status == 1), mirroring bovinebattle. When
* not engaged both timers read '--'.
*
* Registry contract (core/moduleregistry.lua): Initialize, DrawWindow,
* UpdateVisuals, SetHidden, Cleanup. text_in watching is self-contained via
* this module's own registration (removed in Cleanup).
]]--

local imgui  = require('imgui');
local imtext = require('libs.imtext');
local struct = require('struct');

local M = {};

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------

local ENTITY_STATUS_ENGAGED = 1;
local ENTITY_STATUS_RESTING = 33;
local BURST_WINDOW_SEC       = 0.35;  -- collapse multi-hit rounds

-- FFXI resting HP/MP tick cadence, per LSB (LandSandBoat) server source:
--   0x0e8_camp.cpp creates the Healing status effect on /heal with
--   tick = map.HEALING_TICK_DELAY (default 10s). The effect then ticks
--   uniformly every 10s.
--
-- MEASURED on HorizonXI with the bovineresttest addon (wall clock):
--   subsequent interval  9.98s over 6 intervals -- a clean 10s
--   first packet         20.1 / 20.6 / 20.97 / 22.2 / 22.7 / 23.2s
--
-- The 10s cycle is exact. The FIRST packet is not, and LSB explains why:
-- scripts/effects/healing.lua wraps its whole body in `if healtime > 1`, so
-- tick #1 does nothing at all -- no HP, no MP, no TP, and therefore no packet.
-- The first packet we can see is tick #2, roughly two cycles in, and where it
-- lands depends on when you sat relative to the server's cycle.
--
-- 21 is the opening estimate only. It is replaced the moment the first packet
-- arrives, so its accuracy matters for a few seconds at most.
local REST_FIRST_TICK_SEC  = 21.0;
local REST_CYCLE_SEC       = 10.0;

-- Both the countdown and the shimmer run over this span rather than
-- REST_CYCLE_SEC.
--
-- Packets land roughly +-2s around the 10s grid. Counting down from 10 would
-- hit zero and wrap while a late packet was still pending -- the readout would
-- restart and the shimmer would begin a second sweep, both implying a tick
-- that hadn't happened. Running to 12 keeps them travelling through the late
-- window instead.
--
-- Showing 12 is not overstating the interval, because an EARLY packet resets
-- the display the moment it lands: the count never actually reaches 12 unless
-- the tick is genuinely that late. It reads as "up to 12s" rather than a
-- promise of 12.
--
-- REST_CYCLE_SEC stays 10 and remains the truth for the anchor grid and the
-- packet plausibility window -- only the DISPLAY uses this span.
local REST_DISPLAY_SPAN_SEC = 12.0;

-- Plausibility windows for accepting an MP gain as a rest tick.
-- FIRST covers the observed 20.1-23.2s spread with margin. CYCLE_TOL is 2.5
-- rather than 2.0 because measured intervals alias to ~9 or ~12 (the frame
-- poll beats against the server's 10s tick) -- a tighter band rejects real
-- ticks at the boundary.
local FIRST_MIN, FIRST_MAX = 19.0, 24.0;
local CYCLE_TOL            = 2.5;

-- Rest tracking state.
local rest_start_ts = 0.0;   -- when resting was detected
local was_resting   = false; -- gates the rising-edge reset
local anchor_ts     = 0.0;   -- phase anchor: set ONCE, corrected only by whole cycles
local tick_seen_ts  = 0.0;   -- when a tick was last actually observed (display only)
local synced        = false; -- true once a real tick has anchored the cycle

local hidden                = false;
local text_event_registered = false;
local module_settings       = nil;

local escaped_name = '';              -- pattern-escaped, lowercased player name

-- Round timestamps + sequence counters (os.clock based).
local last_attack_ts  = 0.0;
local last_defence_ts = 0.0;
local atk_round_seq   = 0;
local def_round_seq   = 0;

---------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------

local function now_sec()
    return os.clock();
end

-- Escape Lua magic characters in the player's name so it can be used inside
-- string.match patterns.
local function pattern_escape_name(name)
    if type(name) ~= 'string' then return ''; end
    return (name:lower():gsub('([^%w])', '%%%1'));
end

-- Cache the player's (escaped, lowercased) name once it's available.
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

local function is_engaged()
    if type(GetPlayerEntity) ~= 'function' then return false; end
    local ent = GetPlayerEntity();
    return ent ~= nil and ent.Status == ENTITY_STATUS_ENGAGED;
end

local function is_resting()
    if type(GetPlayerEntity) ~= 'function' then return false; end
    local ent = GetPlayerEntity();
    return ent ~= nil and ent.Status == ENTITY_STATUS_RESTING;
end

-- Packet-driven tick detection.
--
-- Polling every frame can only see a tick on the next frame after it lands,
-- and the frame rate beats against the server's 10s cycle -- which is why
-- measured intervals aliased to ~9 or ~12 and never 10.
--
-- The server sends GP_SERV_COMMAND_GROUP_ATTR (0x0DF) whenever HP or MP
-- changes. LSB's healing effect calls addHPLeaveSleeping and addMP on every
-- tick, and each sets UPDATE_HP, which is what gates this packet
-- (char_entity.cpp:1202). Timestamping its arrival removes the polling error
-- entirely.
--
-- HandlePacket is called from XIUI.lua's packet_in handler. If it never fires
-- -- wrong packet id on a private server, say -- the polling path below still
-- works, just with the old jitter, so this is an accuracy upgrade rather than
-- a dependency.

-- Previous HP/MP seen in a 0x0DF, for detecting a genuine rise.
local last_hp = nil;
local last_mp = nil;

-- The local player's server id, for matching 0x0DF's UniqueNo field.
local function get_player_server_id()
    local ok, id = pcall(function()
        local party = AshitaCore:GetMemoryManager():GetParty();
        if party == nil then return nil; end
        return party:GetMemberServerId(0);
    end);
    if not ok then return nil; end
    return id;
end

function M.HandlePacket(e)
    if e == nil or e.id ~= 0x0DF then return; end
    if not is_resting() then
        -- Drop the baselines: HP/MP will move freely outside resting, and a
        -- stale pair would make the first packet of the next rest look like a
        -- huge gain.
        last_hp = nil;
        last_mp = nil;
        return;
    end

    -- 0x0DF layout, from LSB src/map/packets/s2c/0x0df_group_attr.h:
    --
    --   GP_SERV_HEADER (base.h): id:9 + size:7 = 2 bytes, sync = 2 bytes
    --   ------------------------------------------------ 4 byte header
    --   0x04  uint32 UniqueNo
    --   0x08  uint32 Hp
    --   0x0C  uint32 Mp
    --   0x10  uint32 Tp
    --
    -- We do NOT care what the values are -- only that the server sent this
    -- while we were resting. LSB only sets UPDATE_HP (which gates this packet)
    -- when something actually moved:
    --
    --   addMP:  if (mp != 0) updatemask |= UPDATE_HP;
    --
    -- so a no-op change sends nothing, and arrival alone means a tick landed.
    --
    -- LIMITATION: with both HP and MP capped, nothing moves and no packet
    -- arrives, so the countdown cannot sync and stays on its estimate. TP does
    -- NOT rescue this -- healing.lua only calls addTP in its non-Signet branch,
    -- so under Signet on continent 1 there is no TP drain either. That case is
    -- accepted rather than worked around: with nothing visibly changing there
    -- is no observable tick for the readout to be wrong about.
    --
    -- UniqueNo confirms the packet is ours: 0x0DF is also sent for TRUST party
    -- members (second constructor taking CTrustEntity) and to the whole
    -- alliance via the ForAlliance push, so without this a trust being healed
    -- would register as our tick.
    --
    -- Hp and Mp are read because packet ARRIVAL alone is not a tick. 0x0DF is
    -- gated on UPDATE_HP, and plenty of things set that mask without any rest
    -- gain -- battle_entity.cpp:285 (UpdateHealth, which fires on gear swaps,
    -- food, buffs and status changes), OnEngage/disengage at 4025/3635, plus
    -- assorted lua_base_entity setters. Those arrive at arbitrary times and
    -- would reset the display for no visible reason.
    --
    -- struct.unpack is 1-based, hence the +1.
    local ok, uniqueNo, hp, mp = pcall(function()
        return struct.unpack('I4', e.data, 0x04 + 1),
               struct.unpack('I4', e.data, 0x08 + 1),
               struct.unpack('I4', e.data, 0x0C + 1);
    end);
    if not ok or uniqueNo == nil or hp == nil or mp == nil then return; end

    local myId = get_player_server_id();
    if myId == nil or uniqueNo ~= myId then return; end

    -- Require an actual RISE in HP or MP. A rest tick always raises at least
    -- one of them (unless both are capped, in which case no packet is sent at
    -- all and we stay on the estimate).
    local rose = false;
    if last_hp ~= nil and last_mp ~= nil then
        rose = (hp > last_hp) or (mp > last_mp);
    end
    last_hp = hp;
    last_mp = mp;
    if not rose then return; end

    local t = now_sec();

    -- Plausibility gate. Even from the packet, a gain has to land where a tick
    -- is possible -- a cure or an item would otherwise anchor the cycle to the
    -- wrong instant for the whole rest.
    if not synced then
        local since_rest = t - rest_start_ts;
        if since_rest < FIRST_MIN or since_rest > FIRST_MAX then return; end

        anchor_ts = t;      -- phase anchor, set ONCE
        synced    = true;
    else
        -- Judge against the ANCHOR GRID, not the last accepted packet.
        --
        -- Measuring from tick_seen_ts is self-poisoning: any stray packet that
        -- happens to land near the window gets accepted as a tick, and the
        -- REAL tick a second later then reads as ~1s since the last one and is
        -- rejected. From that point nothing is ever accepted again and the
        -- display stops resetting -- which is exactly the "first sync fine,
        -- updates dead" symptom.
        --
        -- The anchor is a stable 10s grid, so distance from the nearest grid
        -- point is a reference a bad packet cannot corrupt.
        local into_cycle = (t - anchor_ts) % REST_CYCLE_SEC;
        local off_grid   = math.min(into_cycle, REST_CYCLE_SEC - into_cycle);
        if off_grid > CYCLE_TOL then
            return;
        end

        -- The anchor is NOT moved to this packet.
        --
        -- Packet arrival still varies 9-11s -- server scheduling granularity
        -- plus network latency -- so re-anchoring on each one would fold that
        -- jitter into the base and the countdown would wander despite the true
        -- cycle being a clean 10s. Correct the anchor only by WHOLE cycles, so
        -- it stays phase-locked without absorbing per-packet noise.
        --
        -- Threshold is one full cycle, not 1.5: at 1.5 the anchor only caught
        -- up after falling 15s behind, so it sat a whole tick in arrears and
        -- the countdown read a cycle late. At 1.0 it tracks the grid within
        -- the jitter (verified: 0.35s off after eight ticks vs 10.35s).
        while (t - anchor_ts) >= REST_CYCLE_SEC do
            anchor_ts = anchor_ts + REST_CYCLE_SEC;
        end
    end

    -- Visual reset point. This is what makes the counter and shimmer restart
    -- exactly when the gain lands, while the schedule above stays on 10s.
    tick_seen_ts = t;
end

-- Track resting and return seconds until the next HP/MP tick (nil when not
-- resting). Called once per frame from DrawWindow.
--
-- The schedule is anchored to an OBSERVED tick, then run as pure arithmetic:
--   anchor + n * 10s
-- The anchor is set once and afterwards corrected only by whole cycles. Every
-- detection carries up to ~2s of sampling error (the frame poll beats against
-- the server's 10s tick, so measured intervals alias to ~9 or ~12, never 10),
-- so re-anchoring on each tick would fold that error into the base and the
-- countdown would wobble forever despite the true rate being a clean 9.98s.
--
-- Detection still snaps the DISPLAY so the readout visibly restarts when MP
-- lands, but it never moves the underlying schedule.
local function update_rest_state()
    if not is_resting() then
        was_resting = false;
        synced      = false;
        last_hp     = nil;
        last_mp     = nil;
        return nil;
    end

    local t = now_sec();
    if not was_resting then
        rest_start_ts = t;
        was_resting   = true;
        synced        = false;
        anchor_ts     = 0.0;
        tick_seen_ts  = 0.0;

        -- Choose which stat to watch, once, at the start of this rest. Both
        -- are sampled so the baseline is correct whichever gets picked.
    end

    -- Tick detection lives entirely in M.HandlePacket (0x0DF). There is no
    -- polling fallback: the server sends that packet on every HP/MP change, so
    -- if it isn't arriving the countdown should stay on its estimate rather
    -- than silently reverting to a less accurate method that looks like it
    -- works.

    if synced then
        -- Count down from the last OBSERVED tick, not from the anchor grid.
        --
        -- The anchor wraps every 10s, so basing the display on it would jump
        -- back to 12 at t=10 -- exactly during the window where a late packet
        -- is still expected. Counting from tick_seen_ts lets the number keep
        -- falling through that window and only reset when a packet actually
        -- lands. The anchor is still the schedule; this is presentation.
        local since_seen = t - tick_seen_ts;
        local remaining;
        if tick_seen_ts > 0 then
            remaining = REST_DISPLAY_SPAN_SEC - since_seen;
        else
            remaining = REST_DISPLAY_SPAN_SEC - ((t - anchor_ts) % REST_CYCLE_SEC);
        end

        -- Hold at 0 rather than going negative if a packet is later than the
        -- span. It resets the moment one arrives.
        if remaining < 0 then remaining = 0; end

        return remaining;
    end

    local elapsed = t - rest_start_ts;

    -- Not synced yet: run the nominal schedule off the estimate.
    --
    -- Usually this lasts only the few seconds before the first packet lands.
    -- It persists for the whole rest in one case -- HP and MP both capped, so
    -- nothing moves and no packet is ever sent -- and cycling is the right
    -- behaviour there rather than sitting at 0: there is no observable tick to
    -- contradict it, and a frozen readout looks broken.
    if elapsed >= REST_FIRST_TICK_SEC then
        -- Unsynced means no packets are arriving (both HP and MP capped), so
        -- nothing will ever reset the display. Cycle on the TRUE 10s here
        -- rather than the 12s display span: the span exists to leave room for
        -- a late packet, and without packets that room would just make the
        -- number jump 12 -> 2 -> 12 and never count down properly.
        local into_cycle = (elapsed - REST_FIRST_TICK_SEC) % REST_CYCLE_SEC;
        return REST_CYCLE_SEC - into_cycle;
    end
    return REST_FIRST_TICK_SEC - elapsed;
end

-- Progress 0..1 through the current tick interval, or nil when not resting.
-- Exposed so the player-bar shimmer sweeps in lockstep with this countdown
-- instead of keeping a second, unsynced copy of the timing.
function M.GetRestTickProgress()
    if not is_resting() then return nil; end
    local t = now_sec();

    if synced then
        -- Measured from the last OBSERVED tick, same as the countdown, so the
        -- wave keeps travelling through the late window instead of wrapping
        -- when the anchor grid rolls over at 10s.
        local into_cycle;
        local since_seen = t - tick_seen_ts;
        if tick_seen_ts > 0 then
            into_cycle = since_seen;
        else
            into_cycle = (t - anchor_ts) % REST_CYCLE_SEC;
        end

        -- Normalised over the 12s span, clamped so the wave parks at the end
        -- of the bar instead of wrapping if a packet is unusually late.
        local progress = into_cycle / REST_DISPLAY_SPAN_SEC;
        if progress > 1.0 then progress = 1.0; end
        return progress;
    end

    local elapsed = t - rest_start_ts;

    -- Mirrors the countdown above: cycle on the estimate rather than pinning
    -- at 1.0, so the shimmer keeps sweeping when nothing can move. Unsynced
    -- means no packets are coming, so the sweep uses the true cycle -- there
    -- is no late arrival to leave room for.
    if elapsed >= REST_FIRST_TICK_SEC then
        -- True 10s here too, matching the countdown -- see the note there.
        return ((elapsed - REST_FIRST_TICK_SEC) % REST_CYCLE_SEC) / REST_CYCLE_SEC;
    end
    return elapsed / REST_FIRST_TICK_SEC;
end

-- Normalize a raw log line: strip control/color/auto-translate bytes and
-- collapse whitespace. Mirrors bovinebattle's sanitize_log_text.
local function sanitize_log_text(text)
    text = tostring(text or '');
    text = text:gsub('\r', ' '):gsub('\n', ' ');
    -- apostrophe variants -> ASCII apostrophe (before the non-printable strip)
    text = text:gsub('\xE2\x80\x99', "'");
    text = text:gsub('\xE2\x80\x98', "'");
    text = text:gsub('\x92',         "'");
    text = text:gsub('\xA4',         "'");
    text = text:gsub('[%z\1-\31\127-\255]', '');
    text = text:gsub('`', "'");
    text = text:gsub('%s+', ' ');
    text = text:gsub('^%s+', ''):gsub('%s+$', '');
    return text;
end

-- True when the line's grammatical subject is the player (or "You").
local function line_is_you_or_player(lower_text)
    if lower_text:find('you ', 1, true) == 1 then return true; end
    if escaped_name ~= '' then
        if lower_text:match('^' .. escaped_name .. '%s+') then return true; end
        if lower_text:match('^' .. escaped_name .. "'s%s+") then return true; end
    end
    return false;
end

-- Player's own melee round: "<name> hits/misses/critically hits/attacks ...".
local function is_player_attack_line(sl)
    if escaped_name == '' then return false; end
    if sl:match('^' .. escaped_name .. '%s+hits%s+') then return true; end
    if sl:match('^' .. escaped_name .. '%s+misses%s+') then return true; end
    if sl:match('^' .. escaped_name .. '%s+critically%s+hits%s+') then return true; end
    if sl:match('^' .. escaped_name .. '%s+scores%s+a%s+critical%s+hit') then return true; end
    if sl:match('^' .. escaped_name .. '%s+attacks%s+') then return true; end
    return false;
end

-- Mob attacking the player: handles "<name> takes N points", "... hits/misses
-- you", shadow absorbs, and verb-agreement for plural-named mobs.
local function is_enemy_attack_you_line(sl)
    -- HorizonXI combat-log style "<name> takes N points" starts with the
    -- player's name (subject) though the player is the victim. Check first.
    if escaped_name ~= '' then
        if sl:match('^' .. escaped_name .. '%s+takes%s+%d+%s+point') then return true; end
    end

    if line_is_you_or_player(sl) then return false; end

    -- Verb agrees with the MOB (subject). Plural-named mobs emit "hit"/"miss";
    -- singular emit "hits"/"misses". hits? / misse?s? matches both.
    if sl:match('^.+%s+misse?s?%s+you%f[%W]') then return true; end
    if sl:match('^.+%s+hits?%s+you%s+for%s+%d+') then return true; end
    if sl:match('^.+%s+critically%s+hits?%s+you%s+for%s+%d+') then return true; end
    if sl:match("^%d+%s+of%s+your%s+shadows%s+absorbs%s+the%s+damage%s+and%s+disappears%.?$") then return true; end

    if escaped_name ~= '' then
        if sl:match('^.+%s+misse?s?%s+' .. escaped_name .. '%f[%W]') then return true; end
        if sl:match('^.+%s+hits?%s+' .. escaped_name .. '%s+for%s+%d+') then return true; end
        if sl:match('^.+%s+critically%s+hits?%s+' .. escaped_name .. '%s+for%s+%d+') then return true; end
        if sl:match("^[1234]%s+of%s+" .. escaped_name .. "'s%s+shadows%s+absorbs") then return true; end
    end

    return false;
end

-- Process one already-split log line.
local function handle_line(line)
    if not is_engaged() then return; end

    local sl = sanitize_log_text(line):lower();
    if sl == '' then return; end

    local t = now_sec();

    if is_player_attack_line(sl) then
        if (t - last_attack_ts) >= BURST_WINDOW_SEC then
            last_attack_ts = t;
            atk_round_seq = atk_round_seq + 1;
        end
        return;  -- a player-attack line can't also be an enemy-attack line
    end

    if is_enemy_attack_you_line(sl) then
        if (t - last_defence_ts) >= BURST_WINDOW_SEC then
            last_defence_ts = t;
            def_round_seq = def_round_seq + 1;
        end
    end
end

local function on_text_in(e)
    local raw = e.message;
    if type(raw) ~= 'string' or #raw == 0 then return; end

    ensure_player_name_cached();
    if escaped_name == '' then return; end

    -- Strip auto-translate markers, then split on bell/CR/LF like bovinelatent.
    local cleaned = raw:gsub('\x1E.', ''):gsub('\x1F.', '');
    for chunk in cleaned:gmatch('[^\x07\r\n]+') do
        handle_line(chunk);
    end
end

-- Format elapsed since a timestamp. Only meaningful while engaged; shows '--'
-- when not engaged or nothing has happened yet.
local function format_elapsed(ts)
    if not is_engaged() then return '--'; end
    ts = tonumber(ts or 0) or 0;
    if ts <= 0 then return '--'; end
    local dt = now_sec() - ts;
    if dt < 0 then dt = 0; end
    return string.format('%.1fs', dt);
end

---------------------------------------------------------------------
-- REGISTRY CONTRACT
---------------------------------------------------------------------

function M.Initialize(settings)
    module_settings = settings;
    ensure_player_name_cached();

    if not text_event_registered then
        ashita.events.register('text_in', 'bovinecombat_text_in', on_text_in);
        text_event_registered = true;
    end
end

function M.UpdateVisuals(settings)
    module_settings = settings;
end

function M.SetHidden(state)
    hidden = (state == true);
end

function M.Cleanup()
    if text_event_registered then
        ashita.events.unregister('text_in', 'bovinecombat_text_in');
        text_event_registered = false;
    end
end

-- Reset both timers/counters (config menu hook).
function M.Reset()
    last_attack_ts  = 0.0;
    last_defence_ts = 0.0;
    atk_round_seq   = 0;
    def_round_seq   = 0;
    rest_start_ts   = 0.0;
    was_resting     = false;
    anchor_ts       = 0.0;
    tick_seen_ts    = 0.0;
    synced          = false;
    last_hp         = nil;
    last_mp         = nil;
end

function M.DrawWindow(settings)
    if hidden then return; end
    module_settings = settings or module_settings;

    local cfg = rawget(_G, 'gConfig');
    if cfg and cfg.bovinecombatHidden == true then return; end

    -- Player-name cache can miss on the very first frames after login; keep
    -- trying so detection comes online without a reload.
    ensure_player_name_cached();

    -- No SetNextWindowSize: AlwaysAutoResize below sizes the window to its
    -- contents every frame. The layout is three label/value rows whose widths
    -- come entirely from the font, so a fixed or user-set size would only ever
    -- be wrong -- too narrow and it clips, too wide and it wastes screen.
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 8.0);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 6.0);
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.08, 0.08, 0.10, 0.92 });
    imgui.PushStyleColor(ImGuiCol_TitleBg, { 0.13, 0.12, 0.18, 1.0 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive, { 0.22, 0.18, 0.32, 1.0 });

    -- p_open gives a title-bar X; clicking it sets bovinecombatHidden so the
    -- window stays hidden until re-enabled from the config menu.
    local win_open = { true };
    -- Font override.
    --
    -- This window uses imgui.Text rather than draw-list calls, so the font is
    -- applied by PUSHING it for the window rather than passed per call. When
    -- the override is off, or is set to 'Default', no font is pushed and the
    -- built-in bitmap font is used -- which is what this window looked like
    -- before, and stays crisp at small sizes.
    local pushedFont = false;
    if cfg and cfg.bovinecombatOverrideFont then
        imtext.SetConfig(cfg.bovinecombatFontFamily or 'Default',
            cfg.bovinecombatFontWeight == 'Bold',
            cfg.bovinecombatFontOutlineWidth or 2);
        local f = imtext.GetFont();
        if f ~= nil then
            pushedFont = pcall(imgui.PushFont, f);
        end
    end

    ApplyWindowPosition('Combat Timers##bovinecombat');
    local drew = imgui.Begin('Combat Timers##bovinecombat', win_open,
        bit.bor(ImGuiWindowFlags_NoCollapse,
                ImGuiWindowFlags_AlwaysAutoResize,
                ImGuiWindowFlags_NoResize));
    if drew then
        SaveWindowPosition('Combat Timers##bovinecombat');
    end
    if not win_open[1] and cfg then
        cfg.bovinecombatHidden = true;
    end
    if drew then
        local engaged = is_engaged();

        -- Column position for the values.
        --
        -- Was a hardcoded 110px, which broke once the font became
        -- configurable: 'Since Defence:' is the longest label and at a larger
        -- size or wider face it overruns 110, so its value shifted right while
        -- the other two stayed put. Measuring the widest label keeps the
        -- column aligned at any font or size.
        local valueColX = imgui.CalcTextSize('Since Defence:') + 12;

        -- Reserve the width of the widest value the window will ever show.
        --
        -- With AlwaysAutoResize the window hugs its contents, so a row reading
        -- '--' is far narrower than one reading '123.4s' -- the window would
        -- visibly snap between two widths as timers start and stop. Drawing an
        -- invisible placeholder at the widest value pins the width so it stays
        -- put, with a small margin so the text never touches the edge.
        local valueW = imgui.CalcTextSize('123.4s') + 8;
        local function drawValue(text, color)
            imgui.PushStyleColor(ImGuiCol_Text, color);
            imgui.Text(text);
            imgui.PopStyleColor();
            -- Invisible spacer holding the reserved width.
            imgui.SameLine(valueColX + valueW);
            imgui.Text(' ');
        end

        imgui.Text('Since Attack:');
        imgui.SameLine(valueColX);
        drawValue(format_elapsed(last_attack_ts),
            engaged and { 0.55, 1.0, 0.65, 1.0 } or { 0.55, 0.55, 0.60, 1.0 });

        imgui.Text('Since Defence:');
        imgui.SameLine(valueColX);
        drawValue(format_elapsed(last_defence_ts),
            engaged and { 1.0, 0.7, 0.55, 1.0 } or { 0.55, 0.55, 0.60, 1.0 });

        -- Resting tick countdown. Only counts while resting (Status 33);
        -- shows '--' otherwise. Toggleable from the Combat Timers config.
        if not cfg or cfg.bovinecombatShowRestTick ~= false then
            local secs_to_tick = update_rest_state();

            imgui.Text('Next Tick:');
            imgui.SameLine(valueColX);
            if secs_to_tick then
                drawValue(string.format('%.1fs', secs_to_tick), { 0.35, 0.85, 1.0, 1.0 });
            else
                drawValue('--', { 0.55, 0.55, 0.60, 1.0 });
            end
        else
            -- Keep edge tracking correct even while the row is hidden.
            update_rest_state();
        end
    end
    imgui.End();

    if pushedFont then
        imgui.PopFont();
    end

    imgui.PopStyleColor(3);
    imgui.PopStyleVar(2);
end

return M;
