--[[
* XIUI Treasure Pool - BovineLooty Auto-Lot / Auto-Pass Module
*
* Self-contained treasure-pool automation. Maintains two persisted lists of
* item IDs -- a LOT list and a PASS list -- and, while running, acts on pooled
* items whose ItemId is on a list:
*     - PASS list  -> passes the item (0x42) via actions.PassItem
*     - LOT  list  -> lots the item  (0x41) via actions.LotItem (validated)
*
* Safety model (all confirmed with the user):
*   - One action per second (PASS_INTERVAL), shared across lot AND pass, so the
*     system issues at most one packet per second total.
*   - Rolling ceiling of MAX_ACTIONS_PER_WINDOW (10) actions in any
*     WINDOW_SECONDS (10s) span. When hit, the whole queue HOLDS for
*     HOLD_SECONDS (5s), then resumes.
*   - "Lot once": a given (slot,itemId) pairing is lotted at most once. Tracked
*     so a lot is never re-fired while GetPlayerLotStatus lags a tick. The guard
*     is keyed slot+itemId (not slot alone) because pool slots reindex when
*     items drop out. Entries are cleared when the item leaves the pool.
*   - Failed/invalid lot: actions.LotItem returns (false, err) on rare-owned /
*     inventory-full / already-lotted. On failure we put that (slot,itemId) on a
*     1s cooldown and allow ONE retry; a second failure marks it skip-until-exit.
*   - Lists are mutually exclusive: adding an id to one list removes it from the
*     other (Lot has priority -- see resolveConflict). If an id somehow appears
*     on both (e.g. hand-edited config), the drain treats it as LOT and ignores
*     the pass entry.
*   - "Running" defaults to OFF and must be started each session. The lists
*     persist via gConfig.
*   - No packets are parsed here; the live pool model is read from
*     data.GetSortedPoolItems() each tick (current truth, no stale-slot race).
]]--

require('common');
require('handlers.helpers');
local imgui = require('imgui');
local windowBg = require('libs.windowbackground');
local button = require('libs.button');

local data = require('modules.treasurepool.data');
local actions = require('modules.treasurepool.actions');

local M = {};

----------------------------------------------------------------------------------------------------
-- Tunables
----------------------------------------------------------------------------------------------------

local PASS_INTERVAL          = 1.0;   -- seconds between any two actions
local MAX_ACTIONS_PER_WINDOW = 10;    -- ceiling within the rolling window
local WINDOW_SECONDS         = 10.0;  -- rolling window span
local HOLD_SECONDS           = 5.0;   -- queue hold when ceiling is hit
local FAIL_RETRY_CD          = 1.0;   -- cooldown before the single lot retry

----------------------------------------------------------------------------------------------------
-- Live state (not persisted)
----------------------------------------------------------------------------------------------------

local running    = false;   -- master toggle (always starts false)
local windowOpen = false;   -- /xiui bvl window visibility
local nextActAt  = 0.0;     -- os.clock() gate for the next action (1s spacing)
local holdUntil  = 0.0;     -- if > now, queue is held (ceiling backoff)
local lastAction = '';      -- short status string for the window

-- Rolling action timestamps (os.clock values) for the 10/10s ceiling.
local actionTimes = {};

-- Per-(slot,itemId) guards. Key string: slot .. ':' .. itemId.
--   lotDone[key]   = true            -> already lotted this pairing (lot-once)
--   lotFail[key]   = { count, cdAt } -> failed lots: count, and next-retry time
local lotDone = {};
local lotFail = {};

-- imgui input buffers (single-element tables, per imgui binding).
local addLotBuf  = { '' };
local addPassBuf = { '' };

----------------------------------------------------------------------------------------------------
-- Persistence (rides gConfig + SaveSettingsOnly)
--   gConfig.bovineLootyLotList  = array of { id, name }
--   gConfig.bovineLootyPassList = array of { id, name }
----------------------------------------------------------------------------------------------------

local function ensureLists()
    if gConfig == nil then return; end
    if gConfig.bovineLootyLotList  == nil then gConfig.bovineLootyLotList  = {}; end
    if gConfig.bovineLootyPassList == nil then gConfig.bovineLootyPassList = {}; end
end

local function persist()
    if SaveSettingsOnly ~= nil then SaveSettingsOnly(); end
end

local function resolveName(itemId)
    if itemId == nil or itemId <= 0 then return tostring(itemId); end
    local res = AshitaCore:GetResourceManager():GetItemById(itemId);
    if res ~= nil and res.Name ~= nil then
        local n = res.Name[1];
        if n ~= nil and n ~= '' then return n; end
    end
    return tostring(itemId);
end

local function findIndex(list, itemId)
    for i, entry in ipairs(list) do
        if entry.id == itemId then return i; end
    end
    return nil;
end

----------------------------------------------------------------------------------------------------
-- List queries (public)
----------------------------------------------------------------------------------------------------

function M.IsOnLotList(itemId)
    if itemId == nil then return false; end
    ensureLists();
    return findIndex(gConfig.bovineLootyLotList, itemId) ~= nil;
end

function M.IsOnPassList(itemId)
    if itemId == nil then return false; end
    ensureLists();
    return findIndex(gConfig.bovineLootyPassList, itemId) ~= nil;
end

function M.GetLotList()
    ensureLists();
    return gConfig.bovineLootyLotList;
end

function M.GetPassList()
    ensureLists();
    return gConfig.bovineLootyPassList;
end

----------------------------------------------------------------------------------------------------
-- List mutation (public). Mutually exclusive: adding to one removes from the
-- other. Lot has priority as the conflict backstop in the drain.
----------------------------------------------------------------------------------------------------

local function removeFrom(list, itemId)
    local i = findIndex(list, itemId);
    if i ~= nil then table.remove(list, i); return true; end
    return false;
end

function M.AddToLotList(itemId, itemName)
    if itemId == nil or itemId <= 0 then return false; end
    ensureLists();
    removeFrom(gConfig.bovineLootyPassList, itemId);   -- mutual exclusion
    if findIndex(gConfig.bovineLootyLotList, itemId) ~= nil then
        persist();  -- still persist the pass-removal above
        return false;
    end
    local name = itemName;
    if name == nil or name == '' then name = resolveName(itemId); end
    table.insert(gConfig.bovineLootyLotList, { id = itemId, name = name });
    persist();
    lastAction = string.format('lot+ %s (%d)', name, itemId);
    return true;
end

function M.AddToPassList(itemId, itemName)
    if itemId == nil or itemId <= 0 then return false; end
    ensureLists();
    removeFrom(gConfig.bovineLootyLotList, itemId);    -- mutual exclusion
    if findIndex(gConfig.bovineLootyPassList, itemId) ~= nil then
        persist();
        return false;
    end
    local name = itemName;
    if name == nil or name == '' then name = resolveName(itemId); end
    table.insert(gConfig.bovineLootyPassList, { id = itemId, name = name });
    persist();
    lastAction = string.format('pass+ %s (%d)', name, itemId);
    return true;
end

function M.RemoveFromLotList(itemId)
    ensureLists();
    if removeFrom(gConfig.bovineLootyLotList, itemId) then
        persist();
        lastAction = string.format('lot- %d', itemId);
        return true;
    end
    return false;
end

function M.RemoveFromPassList(itemId)
    ensureLists();
    if removeFrom(gConfig.bovineLootyPassList, itemId) then
        persist();
        lastAction = string.format('pass- %d', itemId);
        return true;
    end
    return false;
end

----------------------------------------------------------------------------------------------------
-- Named list files (Load / Save) -- mirrors the proven bovinefh picker:
-- a detached PowerShell Open/Save dialog writes the chosen path to a .result
-- file, polled every frame (non-blocking, game keeps rendering). Lists are
-- saved as .txt in the user's chosen location (default: <addon>/bovinelooty/),
-- in a two-section "Name - ID" format:
--
--     # BovineLooty list
--     Lot
--     Kraken Club - 17440
--     Pass
--     Byne Bill - 1454
--
-- On load, the ID is authoritative; the name is display-only.
----------------------------------------------------------------------------------------------------

local SETTINGS_DIR = addon.path .. 'settings/';
local LISTS_DIR    = addon.path .. 'bovinelooty/';
for _, d in ipairs({ SETTINGS_DIR, LISTS_DIR }) do
    os.execute(string.format('mkdir "%s" 2>nul', d:gsub('/', '\\')));
end
local PICK_SCRIPT = SETTINGS_DIR .. 'bvl_pick.ps1';
local PICK_RESULT = SETTINGS_DIR .. 'bvl_pick.result';
local SAVE_RESULT = SETTINGS_DIR .. 'bvl_save.result';
local pick_pending = false;
local save_pending = false;
local loadedListName = '';   -- base name of the last loaded/saved list (display)

local function baseName(path)
    local n = path:gsub('[/\\]+$', ''):match('([^/\\]+)$') or path;
    return n:gsub('%.[Tt][Xx][Tt]$', '');
end

-- Parse a two-section list file into the Lot and Pass lists (replace).
local function loadListFile(path)
    if path == nil or path == '' then return; end
    local f = io.open(path, 'r');
    if not f then lastAction = 'could not open ' .. path; return; end
    ensureLists();
    local newLot, newPass = {}, {};
    local section = nil;   -- 'lot' | 'pass'
    for line in f:lines() do
        local l = line:gsub('^%s+', ''):gsub('%s+$', '');
        if l ~= '' and l:sub(1, 1) ~= '#' then
            local low = l:lower();
            if low == 'lot' then
                section = 'lot';
            elseif low == 'pass' then
                section = 'pass';
            else
                -- "Name - ID"  (ID authoritative; name optional/display)
                local name, id = l:match('^(.-)%s*%-%s*(%d+)%s*$');
                if id == nil then
                    -- tolerate a bare ID line
                    id = l:match('^(%d+)$');
                    name = nil;
                end
                if id ~= nil then
                    local nid = tonumber(id);
                    local nm = (name ~= nil and name ~= '') and name or resolveName(nid);
                    local entry = { id = nid, name = nm };
                    if section == 'pass' then
                        newPass[#newPass + 1] = entry;
                    else
                        newLot[#newLot + 1] = entry;   -- default to lot if no header yet
                    end
                end
            end
        end
    end
    f:close();
    -- Auto-backup current lists before replacing (mis-click protection).
    M.SaveListTo(LISTS_DIR .. '_last.txt', true);
    gConfig.bovineLootyLotList = newLot;
    gConfig.bovineLootyPassList = newPass;
    persist();
    loadedListName = baseName(path);
    lastAction = string.format('loaded %s (%d lot, %d pass)',
        loadedListName, #newLot, #newPass);
end

-- Serialize current lists to the two-section format.
local function serializeLists()
    ensureLists();
    local lines = { '# BovineLooty list', '# format: Name - ID   ( # = comment )', 'Lot' };
    for _, e in ipairs(gConfig.bovineLootyLotList) do
        lines[#lines + 1] = string.format('%s - %d', tostring(e.name or e.id), e.id);
    end
    lines[#lines + 1] = 'Pass';
    for _, e in ipairs(gConfig.bovineLootyPassList) do
        lines[#lines + 1] = string.format('%s - %d', tostring(e.name or e.id), e.id);
    end
    return table.concat(lines, '\n') .. '\n';
end

-- Write current lists to a path. quiet=true suppresses the status message
-- (used for the auto-backup).
function M.SaveListTo(path, quiet)
    if path == nil or path == '' then return; end
    local f = io.open(path, 'w');
    if not f then if not quiet then lastAction = 'could not write ' .. path; end return; end
    f:write(serializeLists());
    f:close();
    if not quiet then
        loadedListName = baseName(path);
        lastAction = 'saved ' .. loadedListName;
    end
end

-- Poll the dialog result files; call every frame.
local function pollDialogs()
    if pick_pending then
        local f = io.open(PICK_RESULT, 'r');
        if f then
            local path = f:read('*l'); f:close();
            os.remove(PICK_RESULT); pick_pending = false;
            if path and path ~= '' then loadListFile((path:gsub('%s+$', ''))); end
        end
    end
    if save_pending then
        local f = io.open(SAVE_RESULT, 'r');
        if f then
            local path = f:read('*l'); f:close();
            os.remove(SAVE_RESULT); save_pending = false;
            if path and path ~= '' then M.SaveListTo((path:gsub('%s+$', '')), false); end
        end
    end
end

-- Launch a non-blocking native dialog. kind = 'load' | 'save'.
local function openDialog(kind)
    if pick_pending or save_pending then return; end
    local resultFile = (kind == 'load') and PICK_RESULT or SAVE_RESULT;
    os.remove(resultFile);
    local ps = io.open(PICK_SCRIPT, 'w');
    if not ps then lastAction = 'could not write picker'; return; end
    if kind == 'load' then
        ps:write(
            "Add-Type -AssemblyName System.Windows.Forms\n" ..
            "Set-Location -LiteralPath $PSScriptRoot\n" ..
            "$d = New-Object System.Windows.Forms.OpenFileDialog\n" ..
            "$d.Filter = 'BovineLooty lists (*.txt)|*.txt|All files (*.*)|*.*'\n" ..
            "$d.Title = 'Load BovineLooty list'\n" ..
            "$d.InitialDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..\\bovinelooty')).Path\n" ..
            "$out = Join-Path $PSScriptRoot 'bvl_pick.result'\n" ..
            "if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {\n" ..
            "  Set-Content -Path $out -Value $d.FileName\n" ..
            "} else { Set-Content -Path $out -Value '' }\n");
        ps:close();
        os.execute('start "" /b powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "'
            .. PICK_SCRIPT .. '"');
        pick_pending = true;
        lastAction = 'load dialog open...';
    else
        local default_name = (loadedListName ~= '' and loadedListName or 'bovinelist')
            :gsub('[\\/:%*%?"<>|]', '_');
        ps:write(
            "Add-Type -AssemblyName System.Windows.Forms\n" ..
            "Set-Location -LiteralPath $PSScriptRoot\n" ..
            "$d = New-Object System.Windows.Forms.SaveFileDialog\n" ..
            "$d.Filter = 'BovineLooty lists (*.txt)|*.txt|All files (*.*)|*.*'\n" ..
            "$d.Title = 'Save BovineLooty list'\n" ..
            "$d.InitialDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..\\bovinelooty')).Path\n" ..
            "$d.FileName = '" .. default_name .. ".txt'\n" ..
            "$d.OverwritePrompt = $true\n" ..
            "$d.AddExtension = $true\n" ..
            "$d.DefaultExt = 'txt'\n" ..
            "$out = Join-Path $PSScriptRoot 'bvl_save.result'\n" ..
            "if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {\n" ..
            "  Set-Content -Path $out -Value $d.FileName\n" ..
            "} else { Set-Content -Path $out -Value '' }\n");
        ps:close();
        os.execute('start "" /b powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "'
            .. PICK_SCRIPT .. '"');
        save_pending = true;
        lastAction = 'save dialog open...';
    end
end

function M.RequestLoad() openDialog('load'); end
function M.RequestSave() openDialog('save'); end
function M.GetLoadedListName() return loadedListName; end

----------------------------------------------------------------------------------------------------
-- Run + window state (public)
----------------------------------------------------------------------------------------------------

function M.IsRunning() return running; end

function M.Start()
    running = true;
    nextActAt = 0.0;     -- allow an immediate first action (dump-all on start)
    holdUntil = 0.0;
    actionTimes = {};
    lastAction = 'started';
end

function M.Stop()
    running = false;
    lastAction = 'stopped';
end

function M.Toggle()
    if running then M.Stop() else M.Start() end
    return running;
end

-- "Show boxes" controls whether the blue/red add boxes appear on Pool-tab
-- rows. Persisted; defaults true. (Formerly the standalone-window visibility.)
function M.IsOpen()
    if gConfig == nil then return true; end
    if gConfig.bovineLootyShowBoxes == nil then gConfig.bovineLootyShowBoxes = true; end
    return gConfig.bovineLootyShowBoxes ~= false;
end
function M.ToggleWindow()
    if gConfig == nil then return true; end
    gConfig.bovineLootyShowBoxes = not M.IsOpen();
    persist();
    return gConfig.bovineLootyShowBoxes;
end
function M.SetOpen(open)
    if gConfig == nil then return; end
    gConfig.bovineLootyShowBoxes = (open == true);
    persist();
end

----------------------------------------------------------------------------------------------------
-- Internal helpers for the drain
----------------------------------------------------------------------------------------------------

local function keyFor(slot, itemId)
    return tostring(slot) .. ':' .. tostring(itemId);
end

-- Prune the rolling action-time window; return current count within WINDOW_SECONDS.
local function pruneAndCount(now)
    local cutoff = now - WINDOW_SECONDS;
    local kept = {};
    for _, t in ipairs(actionTimes) do
        if t >= cutoff then kept[#kept + 1] = t; end
    end
    actionTimes = kept;
    return #kept;
end

-- Clear lot guards for pairings no longer present in the pool ("cleared when
-- item leaves pool"). Build a present-key set from current pool, drop the rest.
local function clearStaleGuards(items)
    local present = {};
    for _, it in ipairs(items) do
        if it.slot ~= nil and it.itemId ~= nil then
            present[keyFor(it.slot, it.itemId)] = true;
        end
    end
    for k in pairs(lotDone) do
        if not present[k] then lotDone[k] = nil; end
    end
    for k in pairs(lotFail) do
        if not present[k] then lotFail[k] = nil; end
    end
end

----------------------------------------------------------------------------------------------------
-- Drain tick -- call every frame from treasurepool init.DrawWindow (before the
-- visibility guards there, so automation runs while the pool window is hidden).
----------------------------------------------------------------------------------------------------

function M.Tick()
    -- Poll Load/Save dialog results every frame (cheap no-op when idle), so a
    -- dialog completes even if automation is stopped or the window is closed.
    pollDialogs();

    if not running then return; end
    if gConfig == nil then return; end
    ensureLists();

    local now = os.clock();

    -- Never act during preview (mock slots); preview is for visual testing only.
    if data.IsPreviewActive() then return; end

    local items = data.GetSortedPoolItems();
    if items == nil then return; end

    -- Keep guards in sync with the live pool first.
    clearStaleGuards(items);

    -- Ceiling hold active?
    if now < holdUntil then return; end

    -- 1s spacing gate.
    if now < nextActAt then return; end

    -- Rolling ceiling check.
    local count = pruneAndCount(now);
    if count >= MAX_ACTIONS_PER_WINDOW then
        holdUntil = now + HOLD_SECONDS;
        lastAction = string.format('rate limit hit - holding %ds', math.floor(HOLD_SECONDS));
        return;
    end

    -- Find the first actionable item. LOT has priority over PASS.
    -- Pass 1: lot candidates. Pass 2: pass candidates.
    for phase = 1, 2 do
        for _, item in ipairs(items) do
            local slot   = item.slot;
            local itemId = item.itemId;
            if slot ~= nil and itemId ~= nil then
                local key = keyFor(slot, itemId);

                if phase == 1 and M.IsOnLotList(itemId) then
                    -- LOT path (validated, lot-once, fail-retry-once).
                    if not lotDone[key] then
                        local fail = lotFail[key];
                        local mayTry = true;
                        if fail ~= nil then
                            if fail.count >= 2 then
                                mayTry = false;            -- skip-until-exit
                            elseif now < fail.cdAt then
                                mayTry = false;            -- still on 1s cooldown
                            end
                        end
                        if mayTry then
                            local ok, err = actions.LotItem(slot);
                            if ok then
                                lotDone[key] = true;
                                lotFail[key] = nil;
                                actionTimes[#actionTimes + 1] = now;
                                nextActAt = now + PASS_INTERVAL;
                                lastAction = string.format('lotted %s (slot %d)',
                                    item.itemName or tostring(itemId), slot);
                            else
                                -- Validation/transient failure: arm one retry.
                                local c = (fail and fail.count or 0) + 1;
                                lotFail[key] = { count = c, cdAt = now + FAIL_RETRY_CD };
                                lastAction = string.format('lot fail %s: %s (try %d)',
                                    item.itemName or tostring(itemId),
                                    tostring(err or 'invalid'), c);
                                -- A failed lot still consumes the 1s spacing so we
                                -- don't spin, but does NOT count toward the ceiling
                                -- (no packet of consequence went out on invalid).
                                nextActAt = now + PASS_INTERVAL;
                            end
                            return;  -- one action attempt per tick
                        end
                    end

                elseif phase == 2 and M.IsOnPassList(itemId)
                       and not M.IsOnLotList(itemId) then
                    -- PASS path. Skip if already passed.
                    local status = data.GetPlayerLotStatus(slot);
                    if status ~= 'passed' then
                        local ok = actions.PassItem(slot);
                        if ok then
                            actionTimes[#actionTimes + 1] = now;
                            nextActAt = now + PASS_INTERVAL;
                            lastAction = string.format('passed %s (slot %d)',
                                item.itemName or tostring(itemId), slot);
                        end
                        return;  -- one action attempt per tick (retry next if failed)
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------------------------------------------
-- GDI window chrome -- matches the treasure pool window (windowBg + FontManager
-- fonts + button prims), inside an imgui frame used only for position/scroll/
-- input. Fonts are created lazily and torn down in M.Cleanup.
--
-- Note: text INPUT (add-by-ID) stays imgui -- the GDI font system renders text
-- but has no text-entry widget, so the two small input fields are imgui drawn
-- over the themed background. Everything else (titles, list rows, status) is GDI.
----------------------------------------------------------------------------------------------------

local fontsReady = false;
local fontCfg    = nil;   -- font_settings captured from Initialize
local titleCfg   = nil;   -- title_font_settings
local bgHandle   = nil;
local loadedTheme = nil;

-- GDI font objects.
local fTitle, fStatus, fHold, fLast = nil, nil, nil, nil;
local fLotHdr, fPassHdr = nil, nil;
local fBtnStart, fBtnLoad, fBtnSave = nil, nil, nil;   -- button labels
local fListName = nil;                                  -- loaded list name display
local fLotHint, fPassHint = nil, nil;                   -- resolved-name preview after +
local MAX_ROWS = 20;       -- visible/managed font rows per list
local fLotRows = {};       -- [i] = font
local fPassRows = {};
local scrollLot, scrollPass = 0, 0;

-- Capture font settings from the module registry (called by init.Initialize).
function M.Configure(settings)
    fontCfg  = settings and settings.font_settings or nil;
    titleCfg = settings and settings.title_font_settings or fontCfg;
end

local function createFonts()
    if fontsReady then return; end
    if fontCfg == nil then return; end   -- not configured yet; try again next frame
    local function mk(cfg)
        local ok, f = pcall(function() return FontManager.create(cfg); end);
        return ok and f or nil;
    end
    fTitle  = mk(titleCfg);
    fStatus = mk(fontCfg);
    fHold   = mk(fontCfg);
    fLast   = mk(fontCfg);
    fLotHdr = mk(fontCfg);
    fPassHdr = mk(fontCfg);
    fBtnStart = mk(fontCfg);
    fBtnLoad = mk(fontCfg);
    fBtnSave = mk(fontCfg);
    fListName = mk(fontCfg);
    fLotHint = mk(fontCfg);
    fPassHint = mk(fontCfg);
    for i = 1, MAX_ROWS do
        fLotRows[i]  = mk(fontCfg);
        fPassRows[i] = mk(fontCfg);
    end
    fontsReady = true;
end

local function hideAllFonts()
    local function h(f) if f then f:set_visible(false); end end
    h(fTitle); h(fStatus); h(fHold); h(fLast); h(fLotHdr); h(fPassHdr);
    h(fBtnStart); h(fBtnLoad); h(fBtnSave); h(fListName); h(fLotHint); h(fPassHint);
    for i = 1, MAX_ROWS do h(fLotRows[i]); h(fPassRows[i]); end
end

local function hideAllRowButtons()
    for i = 1, MAX_ROWS do
        button.HidePrim('bvlLotRm' .. i);
        button.HidePrim('bvlPassRm' .. i);
    end
    button.HidePrim('bvlStartStop');
    button.HidePrim('bvlLoad');
    button.HidePrim('bvlSave');
end

-- Position+show a GDI font with text/color.
local function put(f, text, x, y, color, height)
    if not f then return 0; end
    if height then f:set_font_height(height); end
    f:set_text(text or '');
    f:set_position_x(x);
    f:set_position_y(y);
    f:set_font_color(color or 0xFFFFFFFF);
    f:set_visible(true);
    local w = select(1, f:get_text_size()) or 0;
    return w;
end

-- Tear down all GDI resources (called from init.Cleanup).
function M.Cleanup()
    local function d(f) if f then return FontManager.destroy(f); end return nil; end
    fTitle = d(fTitle); fStatus = d(fStatus); fHold = d(fHold); fLast = d(fLast);
    fLotHdr = d(fLotHdr); fPassHdr = d(fPassHdr);
    fBtnStart = d(fBtnStart); fBtnLoad = d(fBtnLoad); fBtnSave = d(fBtnSave);
    fListName = d(fListName);
    fLotHint = d(fLotHint); fPassHint = d(fPassHint);
    for i = 1, MAX_ROWS do
        fLotRows[i] = d(fLotRows[i]);
        fPassRows[i] = d(fPassRows[i]);
    end
    hideAllRowButtons();
    if bgHandle then
        pcall(function() windowBg.destroy(bgHandle); end);
        bgHandle = nil;
    end
    fontsReady = false;
end

-- Render one list's rows as GDI text + a remove button per row, with scroll.
-- Returns the y after the last drawn row.
local function drawRows(list, rowFonts, rmTag, x, y, rowW, fontSize, scroll)
    local rowH = fontSize + 6;
    local shown = 0;
    local first = math.floor(scroll / rowH) + 1;
    if first < 1 then first = 1; end
    for vis = 1, MAX_ROWS do
        local idx = first + vis - 1;
        local entry = list[idx];
        local f = rowFonts[vis];
        local btnId = rmTag .. vis;
        if entry ~= nil and f ~= nil and shown < MAX_ROWS then
            -- Remove button (red) on the LEFT; it's a delete button.
            local rmW = fontSize + 4;
            local clicked = button.DrawPrim(btnId, x, y - 1, rmW, rmW, {
                colors = button.COLORS_NEGATIVE,
                tooltip = 'Remove from list',
            });
            -- Row label to the right of the remove button.
            local label = string.format('%s (%d)', tostring(entry.name or entry.id), entry.id);
            put(f, label, x + rmW + 6, y, 0xFFEEEEEE, fontSize);
            if clicked then
                return y, entry.id;   -- signal removal of this id
            end
            y = y + rowH;
            shown = shown + 1;
        else
            if f then f:set_visible(false); end
            button.HidePrim(btnId);
        end
    end
    return y, nil;
end

-- Render BovineLooty content into the pool window's frame (called by
-- display.lua when the BovineLooty tab is selected). No imgui.Begin / windowBg
-- here -- the pool window owns the frame and themed background. We draw GDI
-- text + button prims, and position the two add-by-ID imgui inputs at absolute
-- screen coords inside the already-open frame.
function M.DrawTabContent(x, y, contentW, fontSize)
    ensureLists();
    createFonts();
    if fontSize == nil or fontSize < 8 then fontSize = 11; end

    local now = os.clock();
    local rowH = fontSize + 6;
    local listH = 6 * rowH;  -- matches the height branch in display.lua

    -- Status + loaded list name.
    local statusText = running and 'RUNNING' or 'stopped';
    local statusColor = running and 0xFF66FF66 or 0xFFFF8080;
    put(fStatus, 'Status: ' .. statusText, x, y, statusColor, fontSize);
    if now < holdUntil then
        put(fHold, string.format('(held %.0fs)', holdUntil - now), x + 130, y, 0xFFFFCC55, fontSize);
    elseif fHold then fHold:set_visible(false); end
    if loadedListName ~= '' then
        put(fListName, 'List: ' .. loadedListName, x + 200, y, 0xFFAAAAAA, fontSize);
    elseif fListName then fListName:set_visible(false); end
    y = y + fontSize + 8;

    -- Button row: Start/Stop | Load | Save.
    local btnH = fontSize + 6;
    local btnW = fontSize * 4;
    local gap = 6;
    local bx = x;
    local startClicked = button.DrawPrim('bvlStartStop', bx, y, btnW, btnH, {
        colors = running and button.COLORS_NEGATIVE or button.COLORS_POSITIVE,
        tooltip = running and 'Stop auto-lot/pass' or 'Start auto-lot/pass',
    });
    put(fBtnStart, running and 'Stop' or 'Start', bx + (btnW / 2) - 14, y + 2, 0xFFFFFFFF, fontSize);
    if startClicked then M.Toggle(); end
    bx = bx + btnW + gap;
    local loadClicked = button.DrawPrim('bvlLoad', bx, y, btnW, btnH, {
        colors = button.COLORS_INFO, tooltip = 'Load a list file',
    });
    put(fBtnLoad, 'Load', bx + (btnW / 2) - 14, y + 2, 0xFFFFFFFF, fontSize);
    if loadClicked then M.RequestLoad(); end
    bx = bx + btnW + gap;
    local saveClicked = button.DrawPrim('bvlSave', bx, y, btnW, btnH, {
        colors = button.COLORS_INFO, tooltip = 'Save current lists to a file',
    });
    put(fBtnSave, 'Save', bx + (btnW / 2) - 14, y + 2, 0xFFFFFFFF, fontSize);
    if saveClicked then M.RequestSave(); end
    y = y + btnH + 6;

    -- Auto-Lot header + add-by-ID input.
    put(fLotHdr, 'Auto-Lot (blue)', x, y, 0xFF77AAFF, fontSize);
    imgui.SetCursorScreenPos({ x + 130, y - 2 });
    imgui.PushItemWidth(70);
    imgui.InputText('##bvlAddLot', addLotBuf, 16);
    imgui.PopItemWidth();
    imgui.SameLine();
    if imgui.Button('+##bvlAddLot') then
        local id = tonumber(addLotBuf[1]);
        if id and id > 0 then M.AddToLotList(math.floor(id), nil); addLotBuf[1] = ''; end
    end
    -- Static label after the + so it's clear what the field expects.
    put(fLotHint, 'ItemID', x + 230, y, 0xFF99CCFF, fontSize - 1);
    y = y + fontSize + 8;

    local lotTop = y;
    local rmId;
    _, rmId = drawRows(gConfig.bovineLootyLotList, fLotRows, 'bvlLotRm', x, lotTop, contentW, fontSize, scrollLot);
    if rmId then M.RemoveFromLotList(rmId); end
    y = lotTop + listH;

    -- Auto-Pass header + add-by-ID input.
    put(fPassHdr, 'Auto-Pass (red)', x, y, 0xFFFF8080, fontSize);
    imgui.SetCursorScreenPos({ x + 130, y - 2 });
    imgui.PushItemWidth(70);
    imgui.InputText('##bvlAddPass', addPassBuf, 16);
    imgui.PopItemWidth();
    imgui.SameLine();
    if imgui.Button('+##bvlAddPass') then
        local id = tonumber(addPassBuf[1]);
        if id and id > 0 then M.AddToPassList(math.floor(id), nil); addPassBuf[1] = ''; end
    end
    put(fPassHint, 'ItemID', x + 230, y, 0xFFFF9999, fontSize - 1);
    y = y + fontSize + 8;

    local passTop = y;
    _, rmId = drawRows(gConfig.bovineLootyPassList, fPassRows, 'bvlPassRm', x, passTop, contentW, fontSize, scrollPass);
    if rmId then M.RemoveFromPassList(rmId); end
    y = passTop + listH;

    -- Last action line.
    if lastAction ~= '' then
        put(fLast, 'Last: ' .. lastAction, x, y, 0xFF999999, fontSize - 1);
    elseif fLast then fLast:set_visible(false); end

    -- Hide unused title/bg fonts from the old standalone window.
    if fTitle then fTitle:set_visible(false); end
end

-- Called when the BovineLooty tab is NOT shown, to hide its fonts/buttons.
function M.HideTabContent()
    hideAllFonts();
    hideAllRowButtons();
end

return M;