--[[
* XIUI module: bovinededication
* Watches for the player using an EXP-bonus item (Empress/Emperor/Chariot
* Band, Tale of the Wandering Heroes scroll, Anniversary Ring), latches
* onto the Dedication effect, and tracks bonus EXP remaining until the cap.
*
* Detection chain (all match on chat lines from text_in):
*   1. "<Name> uses <Item>."  -- capture the item (must be one of our table
*      entries). Stash as last_item.
*   2. Dedication buff (id 249) appears in the player's buff array within
*      30s of the item use -- proof the item ACTIVATED. Commit it as the
*      tracked buff: bonus_used = 0, cap/pct from the table. No buff edge
*      within 30s = the item failed (already had the effect) -- discard.
*   3. "<Name> gains N experience points."  -- increment bonus_used by
*      floor(N * (bonus_pct / (100 + bonus_pct))), i.e. the extra portion
*      the buff added on top of base XP. When bonus_used >= bonus_cap the
*      buff has effectively capped.
*   4. "The effect of Dedication wears off." (or on wear-off timer) --
*      clear active state, hide window.
*
* GUI: shows only while Dedication is active (or Hidden Window is off).
* Close button (X) flips gConfig.bovinededicationHidden = true, same UX as
* the Latent Trial tracker.
]]--

local imgui = require('imgui');

local M = {};

---------------------------------------------------------------------
-- EXP BUFF TABLE (HorizonFFXI EXP Buff Reference Sheet)
---------------------------------------------------------------------

-- Canonical names (as shown on the wiki / item info screen). The chat log
-- lower-cases these and prefixes an article ("Cowrevenge uses an Emperor
-- band."), so match happens against BUFF_LOOKUP below, keyed by the
-- lowercase item text without the leading "a/an/the".
local EXP_BUFFS = {
    ['Empress Band']                 = { bonus = 50,  duration_min = 180,  cap_exp = 1000  },
    ['Emperor Band']                 = { bonus = 75,  duration_min = 150,  cap_exp = 2250  },
    ['Chariot Band']                 = { bonus = 100, duration_min = 120,  cap_exp = 4000  },
    ['Tale of the Wandering Heroes'] = { bonus = 75,  duration_min = 1440, cap_exp = 10000, is_scroll = true },
    ['Anniversary Ring']             = { bonus = 100, duration_min = 720,  cap_exp = 3000  },
};

-- Lowercase lookup, indexed by the exact form the chat log emits.
local BUFF_LOOKUP = {};
for name, data in pairs(EXP_BUFFS) do
    BUFF_LOOKUP[name:lower()] = { canonical = name, data = data };
end

-- Resolve whatever the chat line captured to a canonical buff entry.
-- Strips a leading article ("a", "an", "the"), lower-cases, and looks up.
-- Returns nil if it isn't one of our tracked items.
local function resolve_buff(item_text)
    if type(item_text) ~= 'string' or item_text == '' then return nil; end
    local s = item_text:lower();
    -- Strip a leading article + single space.
    s = s:gsub('^a ', ''):gsub('^an ', ''):gsub('^the ', '');
    local hit = BUFF_LOOKUP[s];
    if hit then return hit; end
    return nil;
end

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------

local hidden = false;
local text_event_registered = false;

-- Pending item state: the last EXP-buff item the player USED but whose
-- Dedication buff hasn't appeared in the buff array yet. Cleared on effect
-- gained (rolled into tracked_*), on a wear-off followed by a fresh item
-- use, and on Reset.
local last_item      = '';          -- most recent EXP item name the player used
local last_item_at   = 0.0;         -- time of that use (arming window)
local last_item_pct  = 0;           -- bonus % for that item
local last_item_cap  = 0;           -- cap EXP for that item

-- Tracked state: the item currently attributed to the counter. Persists
-- across wear-off, zoning, relog, lag -- ONLY cleared by a fresh item-use +
-- Dedication-effect combo, or by the config Reset button. This is why the
-- window can hide (effect_up = false) without wiping the numbers.
local tracked_item   = '';          -- item the counter belongs to
local tracked_pct    = 0;
local tracked_cap    = 0;
local bonus_used     = 0;           -- bonus EXP consumed so far

-- Just a visibility signal. TRUE while the player has the Dedication effect
-- (mirrors the buff array read each frame). Doesn't gate
-- counting -- counting keys off tracked_item ~= '' -- so a wear-off just
-- hides the window without dropping the state.
local effect_up      = false;

-- Edge detector: buff state last frame. A false->true transition within
-- ITEM_ACTIVATE_WINDOW_SEC of an item use = that item activated.
local had_dedication = false;

local escaped_name   = '';          -- cached pattern-escaped player name

-- Activation window: after "player uses <item>", the Dedication buff must
-- appear within this long or the item is judged to have FAILED (already
-- had the effect, item on cooldown, etc.) and the pending use is dropped.
local ITEM_ACTIVATE_WINDOW_SEC = 30.0;

---------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------

local function now_sec()
    return os.clock();
end

-- Dedication buff id (from horizonffxi status list). Reading the player
-- buff array directly beats scraping chat -- text lines localize / vary,
-- IDs don't. effect_up flips on the presence of this id, not on chat.
local DEDICATION_BUFF_ID = 249;

local function player_has_dedication()
    local ok, has = pcall(function()
        local buffs = AshitaCore:GetMemoryManager():GetPlayer():GetBuffs();
        -- IMPORTANT (from general.lua's own buff scan): GetBuffs() returns a
        -- userdata-with-metamethods, NOT a Lua table. A type(buffs)=='table'
        -- check FAILS on it -- do not type-check, just index. Cover both
        -- index bases (0..32).
        for i = 0, 32 do
            local v = tonumber(buffs[i]);
            if v ~= nil and math.floor(v + 0.5) == DEDICATION_BUFF_ID then
                return true;
            end
        end
        return false;
    end);
    return ok and has == true;
end

-- Debounced buff state. During login / zoning the player object briefly
-- reads no buffs -- a raw false there must not be treated as "Dedication
-- ended". A raw TRUE is instant; a raw FALSE only counts as really-gone
-- after it has stayed false past the grace window. NOTHING wipes tracker
-- state on buff loss either way -- visibility and counting just pause.
local DEDICATION_GRACE_SEC = 5.0;
local buff_true_at = 0.0;

local function dedication_up()
    if player_has_dedication() then
        buff_true_at = now_sec();
        return true;
    end
    return buff_true_at > 0 and (now_sec() - buff_true_at) <= DEDICATION_GRACE_SEC;
end

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

local function clear_all()
    last_item     = '';
    last_item_at  = 0.0;
    last_item_pct = 0;
    last_item_cap = 0;
    tracked_item  = '';
    tracked_pct   = 0;
    tracked_cap   = 0;
    bonus_used    = 0;
    effect_up     = false;
    had_dedication = false;
end

---------------------------------------------------------------------
-- PERSISTENCE -- tracker survives /addon reload, logout, crash. The
-- Dedication buff itself persists through logout server-side, so the
-- counter must too. modules/bovinededication/dedication_state.json.
---------------------------------------------------------------------

local function state_file_path()
    return addon.path .. 'modules/bovinededication/dedication_state.json';
end

local function save_state()
    local f = io.open(state_file_path(), 'w');
    if not f then return; end
    f:write(string.format(
        '{ "item": "%s", "pct": %d, "cap": %d, "used": %d }\r\n',
        tostring(tracked_item):gsub('\\', '\\\\'):gsub('"', '\\"'),
        tracked_pct or 0, tracked_cap or 0, bonus_used or 0));
    f:close();
end

local function load_state()
    local f = io.open(state_file_path(), 'r');
    if not f then return; end
    local text = f:read('*a') or '';
    f:close();
    local item = text:match('"item"%s*:%s*"([^"]*)"');
    if item ~= nil and item ~= '' then
        tracked_item = item:gsub('\\"', '"'):gsub('\\\\', '\\');
        tracked_pct  = tonumber(text:match('"pct"%s*:%s*(%d+)'))  or 0;
        tracked_cap  = tonumber(text:match('"cap"%s*:%s*(%d+)'))  or 0;
        bonus_used   = tonumber(text:match('"used"%s*:%s*(%d+)')) or 0;
    end
end

---------------------------------------------------------------------
-- TEXT HANDLER
---------------------------------------------------------------------

local function handle_line(text)
    local now = now_sec();
    text = text:gsub('^%[[%d:]+%]%s*', '');

    -- 1. Player uses an item. Only stash if it's an EXP-buff item; other
    --    "uses" lines (meds, salvos, etc.) never touch our state.
    --
    --    IMPORTANT: using an item does NOT reset the tracker. If Dedication
    --    is already up and the player tries to use another band, the game
    --    refuses to stack -- if no new "gains the effect" line follows,
    --    tracked_* stays as it was.
    --
    --    Chat log form is "<Name> uses an emperor band." -- lowercase, with
    --    an article. resolve_buff strips both to look up canonical entry.
    local item = text:match('^' .. escaped_name .. ' uses (.-)%.');
    if item then
        local hit = resolve_buff(item);
        if hit then
            last_item     = hit.canonical;
            last_item_at  = now;
            last_item_pct = hit.data.bonus;
            last_item_cap = hit.data.cap_exp;
        end
        return;
    end

    -- XP gain. Only accumulate while the Dedication buff is actually up
    --    (read from the buff array) and we know which item it came from.
    --
    if tracked_item ~= '' and dedication_up() then
        local xp = tonumber(text:match('^' .. escaped_name .. ' gains (%d+) experience points?%.'));
        if xp and xp > 0 then
            -- Total XP after buff = base + base * pct/100. Bonus portion of
            -- the reported XP = xp * pct / (100 + pct). FLOOR, don't round:
            -- the server floors its per-kill bonus, and rounding up drifted
            -- the estimate high enough over a session to declare CAPPED one
            -- mob before the buff actually wore. Floor keeps the tracker at
            -- or slightly behind the server, never ahead.
            local pct = tracked_pct;
            local bonus = math.floor(xp * pct / (100 + pct));
            if bonus < 0 then bonus = 0; end
            bonus_used = bonus_used + bonus;
            if bonus_used > tracked_cap then bonus_used = tracked_cap; end
            save_state();
            return;
        end
    end
end

local function on_text_in(e)
    local raw = e.message;
    if type(raw) ~= 'string' or #raw == 0 then return; end

    ensure_player_name_cached();
    if escaped_name == '' then return; end

    -- Strip auto-translate + color escape bytes, then split on FFXI's
    -- in-message line separator (0x07) and real newlines. The game PACKS
    -- multiple display lines into one message ("EXP chain #2!\x07Cowrevenge
    -- gains 225 experience points.") -- anchored matches fail on the packed
    -- form, which is why chain-kill XP wasn't tracked.
    local cleaned = raw:gsub('\x1E.', ''):gsub('\x1F.', '');
    for line in cleaned:gmatch('[^\x07\r\n]+') do
        handle_line(line);
    end
end

---------------------------------------------------------------------
-- MODULE INTERFACE
---------------------------------------------------------------------

function M.Initialize(settings)
    load_state();
    if not text_event_registered then
        ashita.events.register('text_in', 'bovinededication_text_in', on_text_in);
        text_event_registered = true;
    end
end

function M.UpdateVisuals(settings) end
function M.SetHidden(state) hidden = (state == true); end

-- Config menu Reset button hook. Wipes both pending and tracked state.
function M.Reset()
    clear_all();
    save_state();
end

-- Config menu Force buttons: seed the tracker as if the player had used
-- this item and gotten the Dedication effect. Used when the chat-line
-- detection misses (item wasn't tracked from this session, wear-off caught
-- offline, addon loaded mid-buff, etc.). Manual override -- no chat
-- detection required.
function M.ForceItem(name)
    if type(name) ~= 'string' or name == '' then return; end
    -- Force only makes sense while the Dedication buff is actually up --
    -- it tells the tracker WHICH item the current effect came from. No
    -- buff = nothing to attribute = no-op (with a local debug print so the
    -- click always visibly reports what happened).
    if not player_has_dedication() then
        print('[dedication] Force failed: no Dedication buff (id ' .. tostring(DEDICATION_BUFF_ID) .. ') found on player.');
        return;
    end
    local hit = resolve_buff(name);
    if not hit then
        print('[dedication] Force failed: unknown item "' .. tostring(name) .. '".');
        return;
    end
    last_item     = '';
    last_item_at  = 0.0;
    tracked_item  = hit.canonical;
    tracked_pct   = hit.data.bonus;
    tracked_cap   = hit.data.cap_exp;
    bonus_used    = 0;
    effect_up     = true;
    save_state();
    print('[dedication] Forced: ' .. hit.canonical .. ' (+' .. hit.data.bonus .. '%, cap ' .. hit.data.cap_exp .. ').');
end

-- Config panel status readout: current tracker state regardless of the
-- window's visibility (Hidden Window still allows checking here).
function M.GetStatus()
    return {
        item      = tracked_item,
        pct       = tracked_pct,
        cap       = tracked_cap,
        used      = bonus_used,
        remaining = math.max(0, (tracked_cap or 0) - (bonus_used or 0)),
        buff_up   = player_has_dedication(),
    };
end

-- Debug dump: prints every visibility/tracking gate so a "no window" report
-- pinpoints the failing gate in one click.
function M.Debug()
    local age = now_sec() - last_draw_at;
    print(string.format('[dedication] DrawWindow called: %s (%.1fs ago)',
        last_draw_at > 0 and 'YES' or 'NEVER', last_draw_at > 0 and age or 0));
    print(string.format('[dedication] init/text handler: %s', tostring(text_event_registered)));
    print(string.format('[dedication] buff(249) present: %s', tostring(player_has_dedication())));
    print(string.format('[dedication] hidden(SetHidden): %s', tostring(hidden)));
    local cfg = rawget(_G, 'gConfig');
    print(string.format('[dedication] cfg hiddenWindow: %s  enabled: %s',
        tostring(cfg and cfg.bovinededicationHidden), tostring(cfg and cfg.showBovinededication)));
    print(string.format('[dedication] tracked: "%s"  pct: %d  cap: %d  used: %d',
        tostring(tracked_item), tracked_pct or 0, tracked_cap or 0, bonus_used or 0));
end

-- Config menu list source: canonical item names sorted for display.
function M.GetBuffNames()
    local list = {};
    for name, _ in pairs(EXP_BUFFS) do list[#list + 1] = name; end
    table.sort(list);
    return list;
end

function M.Cleanup()
    save_state();
    if text_event_registered then
        ashita.events.unregister('text_in', 'bovinededication_text_in');
        text_event_registered = false;
    end
end

---------------------------------------------------------------------
-- GUI
---------------------------------------------------------------------

local last_draw_at = 0.0;   -- stamped every DrawWindow entry (Debug reports age)

function M.DrawWindow(settings)
    -- State maintenance runs BEFORE any visibility early-return so pending
    -- commits and expiry keep working while the window is hidden.
    local has_raw = player_has_dedication();
    local has = dedication_up();
    local tnow = now_sec();
    last_draw_at = tnow;

    -- Buff EDGE (false -> true): Dedication just appeared. If an EXP item
    -- was used within the activation window, that item ACTIVATED -- commit
    -- it as the tracked buff with a fresh counter. This is the proof the
    -- item worked; no edge within the window = the item failed (already
    -- had the effect, etc.) and the pending use expires below.
    if has_raw and not had_dedication then
        if last_item ~= '' and (tnow - last_item_at) <= ITEM_ACTIVATE_WINDOW_SEC then
            tracked_item = last_item;
            tracked_pct  = last_item_pct;
            tracked_cap  = last_item_cap;
            bonus_used   = 0;
            last_item    = '';
            last_item_at = 0.0;
            save_state();
        end
    end
    had_dedication = has_raw;

    -- Pending expiry: no activation within the window -> item failed.
    if last_item ~= '' and (tnow - last_item_at) > ITEM_ACTIVATE_WINDOW_SEC then
        last_item    = '';
        last_item_at = 0.0;
    end

    effect_up = has;

    if hidden then return; end
    if not effect_up then return; end
    if tracked_item == '' then return; end

    local cfg = rawget(_G, 'gConfig');
    if cfg and cfg.bovinededicationHidden == true then return; end

    imgui.SetNextWindowSize({ 260, 0 }, ImGuiCond_FirstUseEver);
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 8.0);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 6.0);
    imgui.PushStyleColor(ImGuiCol_WindowBg,     { 0.08, 0.09, 0.12, 0.92 });
    imgui.PushStyleColor(ImGuiCol_TitleBg,      { 0.10, 0.15, 0.20, 1.0 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive,{ 0.15, 0.28, 0.42, 1.0 });

    -- Passing p_open gives the title bar an X. If clicked, imgui sets it
    -- false -- we flip the shared config so the window stays hidden even
    -- while the buff is still active.
    local win_open = { true };
    ApplyWindowPosition('Dedication##bovinededication');
    local drew = imgui.Begin('Dedication##bovinededication', win_open, ImGuiWindowFlags_NoCollapse);
    if drew then
        SaveWindowPosition('Dedication##bovinededication');
    end
    if not win_open[1] and cfg then
        cfg.bovinededicationHidden = true;
    end
    if drew then
        imgui.PushStyleColor(ImGuiCol_Text, { 0.75, 0.90, 1.0, 1.0 });
        imgui.Text(tracked_item);
        imgui.PopStyleColor();
        imgui.Separator();

        imgui.Text(string.format('Bonus %d%%', tracked_pct));
        imgui.Text(string.format('Used  %d / %d', bonus_used, tracked_cap));

        local remaining = tracked_cap - bonus_used;
        if remaining < 0 then remaining = 0; end

        imgui.Separator();
        if remaining <= 0 then
            imgui.PushStyleColor(ImGuiCol_Text, { 1.0, 0.5, 0.5, 1.0 });
            imgui.Text('CAPPED (0 remaining)');
            imgui.PopStyleColor();
        else
            imgui.PushStyleColor(ImGuiCol_Text, { 0.55, 1.0, 0.65, 1.0 });
            imgui.Text(string.format('Remaining  %d exp', remaining));
            imgui.PopStyleColor();
        end
    end
    imgui.End();

    imgui.PopStyleColor(3);
    imgui.PopStyleVar(2);
end

return M;