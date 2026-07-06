--[[
* XIUI module: bovinededication
* Watches for the player using an EXP-bonus item (Empress/Emperor/Chariot
* Band, Tale of the Wandering Heroes scroll, Anniversary Ring), latches
* onto the Dedication effect, and tracks bonus EXP remaining until the cap.
*
* Detection chain (all match on chat lines from text_in):
*   1. "<Name> uses <Item>."  -- capture the item (must be one of our table
*      entries). Stash as last_item.
*   2. "<Name> gains the effect of Dedication."  -- arm active tracking:
*      bonus_used = 0, bonus_cap = table.cap_exp, bonus_pct = table.bonus.
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

-- Keyed by exact item name as it appears in the "<Name> uses <Item>." line.
local EXP_BUFFS = {
    ['Empress Band']                 = { bonus = 50,  duration_min = 180,  cap_exp = 1000  },
    ['Emperor Band']                 = { bonus = 75,  duration_min = 150,  cap_exp = 2250  },
    ['Chariot Band']                 = { bonus = 100, duration_min = 120,  cap_exp = 4000  },
    ['Tale of the Wandering Heroes'] = { bonus = 75,  duration_min = 1440, cap_exp = 10000, is_scroll = true },
    ['Anniversary Ring']             = { bonus = 100, duration_min = 720,  cap_exp = 3000  },
};

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------

local hidden = false;
local text_event_registered = false;

-- Pending item state: the last EXP-buff item the player USED but hasn't yet
-- produced a "gains the effect of Dedication" line for. Cleared on effect
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
-- (between "gains the effect of Dedication" and "wears off"). Doesn't gate
-- counting -- counting keys off tracked_item ~= '' -- so a wear-off just
-- hides the window without dropping the state.
local effect_up      = false;

local escaped_name   = '';          -- cached pattern-escaped player name

-- Time window between "player uses X" and "player gains the effect of
-- Dedication" -- the game emits both back-to-back, but keep this generous.
local USE_TO_EFFECT_SEC = 5.0;

---------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------

local function now_sec()
    return os.clock();
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
end

---------------------------------------------------------------------
-- TEXT HANDLER
---------------------------------------------------------------------

local function on_text_in(e)
    local raw = e.message;
    if type(raw) ~= 'string' or #raw == 0 then return; end

    ensure_player_name_cached();
    if escaped_name == '' then return; end

    -- Strip auto-translate + color escape bytes.
    local text = raw:gsub('\x1E.', ''):gsub('\x1F.', '');
    local now = now_sec();

    -- 1. Player uses an item. Only stash if it's an EXP-buff item; other
    --    "uses" lines (meds, salvos, etc.) never touch our state.
    --
    --    IMPORTANT: using an item does NOT reset the tracker. If Dedication
    --    is already up and the player tries to use another band, the game
    --    refuses to stack -- if no new "gains the effect" line follows,
    --    tracked_* stays as it was.
    local item = text:match('^' .. escaped_name .. ' uses (.-)%.');
    if item then
        local buff = EXP_BUFFS[item];
        if buff then
            last_item     = item;
            last_item_at  = now;
            last_item_pct = buff.bonus;
            last_item_cap = buff.cap_exp;
        end
        return;
    end

    -- 2. Effect gained. If we saw an EXP item use within the arming window,
    --    a fresh Dedication is starting. THIS is the only automatic reset
    --    path -- roll last_item into tracked_*, zero the bonus counter,
    --    mark the effect up.
    --
    --    If there's no pending item (party member's aura, whatever), leave
    --    the tracker alone -- flip effect_up so the window shows the
    --    prior data, but don't zero it.
    if text:match('^' .. escaped_name .. ' gains the effect of Dedication%.') then
        if last_item ~= '' and (now - last_item_at) <= USE_TO_EFFECT_SEC then
            tracked_item = last_item;
            tracked_pct  = last_item_pct;
            tracked_cap  = last_item_cap;
            bonus_used   = 0;
            last_item    = '';        -- consumed
            last_item_at = 0.0;
        end
        effect_up = true;
        return;
    end

    -- 3. XP gain. Only accumulate if we actually have a tracked buff.
    if tracked_item ~= '' and effect_up then
        local xp = tonumber(text:match('^' .. escaped_name .. ' gains (%d+) experience points?%.'));
        if xp and xp > 0 then
            -- Total XP after buff = base + base * pct/100 = base * (100+pct)/100
            -- Bonus portion of the reported XP = xp * pct / (100 + pct)
            local pct = tracked_pct;
            local bonus = math.floor(xp * pct / (100 + pct) + 0.5);
            if bonus < 0 then bonus = 0; end
            bonus_used = bonus_used + bonus;
            if bonus_used > tracked_cap then bonus_used = tracked_cap; end
            return;
        end
    end

    -- 4. Effect wears off. Hide the window but PRESERVE the tracker so a
    --    zoning / relog / lag hiccup doesn't nuke context. State only
    --    changes again on a fresh item-use + Dedication-gain pair.
    if text:match('effect of Dedication wears off') then
        effect_up = false;
        return;
    end
end

---------------------------------------------------------------------
-- MODULE INTERFACE
---------------------------------------------------------------------

function M.Initialize(settings)
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
end

function M.Cleanup()
    if text_event_registered then
        ashita.events.unregister('text_in', 'bovinededication_text_in');
        text_event_registered = false;
    end
end

---------------------------------------------------------------------
-- GUI
---------------------------------------------------------------------

function M.DrawWindow(settings)
    if hidden then return; end
    -- Visibility: window only while the Dedication effect is up. Wearing
    -- off / zoning / relogging hides the window but the tracker's numbers
    -- persist -- next time the effect comes back (or Reset is pressed)
    -- they'll be right where you left them.
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
    local drew = imgui.Begin('Dedication##bovinededication', win_open, ImGuiWindowFlags_NoCollapse);
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