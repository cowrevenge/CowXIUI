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

local imgui = require('imgui');

local M = {};

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------

local ENTITY_STATUS_ENGAGED = 1;
local BURST_WINDOW_SEC       = 0.35;  -- collapse multi-hit rounds

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
end

function M.DrawWindow(settings)
    if hidden then return; end
    module_settings = settings or module_settings;

    local cfg = rawget(_G, 'gConfig');
    if cfg and cfg.bovinecombatHidden == true then return; end

    -- Player-name cache can miss on the very first frames after login; keep
    -- trying so detection comes online without a reload.
    ensure_player_name_cached();

    imgui.SetNextWindowSize({ 200, 0 }, ImGuiCond_FirstUseEver);
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 8.0);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 6.0);
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.08, 0.08, 0.10, 0.92 });
    imgui.PushStyleColor(ImGuiCol_TitleBg, { 0.13, 0.12, 0.18, 1.0 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive, { 0.22, 0.18, 0.32, 1.0 });

    -- p_open gives a title-bar X; clicking it sets bovinecombatHidden so the
    -- window stays hidden until re-enabled from the config menu.
    local win_open = { true };
    local drew = imgui.Begin('Combat Timers##bovinecombat', win_open, ImGuiWindowFlags_NoCollapse);
    if not win_open[1] and cfg then
        cfg.bovinecombatHidden = true;
    end
    if drew then
        local engaged = is_engaged();

        imgui.Text('Since Attack:');
        imgui.SameLine(110);
        if engaged then
            imgui.PushStyleColor(ImGuiCol_Text, { 0.55, 1.0, 0.65, 1.0 });
        else
            imgui.PushStyleColor(ImGuiCol_Text, { 0.55, 0.55, 0.60, 1.0 });
        end
        imgui.Text(format_elapsed(last_attack_ts));
        imgui.PopStyleColor();

        imgui.Text('Since Defence:');
        imgui.SameLine(110);
        if engaged then
            imgui.PushStyleColor(ImGuiCol_Text, { 1.0, 0.7, 0.55, 1.0 });
        else
            imgui.PushStyleColor(ImGuiCol_Text, { 0.55, 0.55, 0.60, 1.0 });
        end
        imgui.Text(format_elapsed(last_defence_ts));
        imgui.PopStyleColor();
    end
    imgui.End();

    imgui.PopStyleColor(3);
    imgui.PopStyleVar(2);
end

return M;
