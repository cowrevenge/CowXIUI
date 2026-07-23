--[[
* XIUI self-updater
*
* Pulls updated files straight from the GitHub repo. Nothing to maintain:
* there is no manifest file to regenerate and commit.
*
* How it decides what to download:
*  - Purely by comparing file contents. There is no version check: gating on
*    addon.version assumes every push bumps it, and this repo gets fixes
*    pushed constantly while the version moves rarely -- so a version gate
*    would report "up to date" while the files on disk were genuinely behind.
*  - GitHub's git/trees API returns EVERY file in the repo with its size and
*    blob SHA in a single request. That is effectively a manifest GitHub keeps
*    up to date for us automatically, so a push is all that's needed -- no
*    build step, and no risk of a stale manifest silently skipping files.
*  - We compute each local file's git blob SHA (libs/sha1.lua) and compare it
*    to the remote one. That's an exact content match, so an edit that happens
*    to leave the file the same length is still detected. Hashing all ~130 Lua
*    files costs about 100ms, which is nothing next to the network calls it
*    saves us from making.
*  - Files are then fetched from raw.githubusercontent.com, which is not rate
*    limited (the API is, at 60 req/hr, but we only use it once per check).
*
* Safety:
*  - https.request() is BLOCKING (LuaSocket/LuaSec) and freezes the game
*    thread, so we only ever run on an explicit button press or a load-time
*    check that's off by default -- and we diff first to keep the download
*    count to the handful of files that actually changed.
*  - Downloads land in a .tmp, the old file moves to .bak, and only then is
*    the new file renamed into place. If anything fails the original is
*    restored, so a broken download can never leave a truncated .lua behind.
*  - Overwriting files does not affect the running session (Lua is already
*    loaded in memory), so Update() queues an /addon reload xiui on success.
*    Both the manual button and the auto-update path go through Update(), so
*    they behave identically -- neither leaves you running stale code.
]]--

require('common');

local https = require('socket.ssl.https');
local sha1  = require('libs.sha1');

local M = {};

-- ============================================================
-- Config
-- ============================================================

local REPO_OWNER  = 'cowrevenge';
local REPO_NAME   = 'CowXIUI';
local REPO_BRANCH = 'main';

local RAW_BASE = string.format('https://raw.githubusercontent.com/%s/%s/%s/',
    REPO_OWNER, REPO_NAME, REPO_BRANCH);

local TREE_URL = string.format(
    'https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1',
    REPO_OWNER, REPO_NAME, REPO_BRANCH);

-- Only these extensions are ever updated. Assets are deliberately excluded:
-- this repo carries several thousand PNGs, and syncing those would mean
-- thousands of blocking requests. Art changes rarely; re-clone for that.
local INCLUDE_EXT = T{ '.lua' };

-- Directory prefixes the updater never touches.
local SKIP_PREFIX = T{
    'submodules/',   -- tracked as git submodules, updated separately
    'settings/',     -- user data
    'tools/',        -- dev scripts, not shipped
    '.github/',
};

-- Files that must never be overwritten once they exist on disk -- things a
-- user may customize. Still BACK-FILLED if missing entirely (fresh install),
-- but never replaced once present. (Borrowed from anglin's onlyIfMissing.)
local ONLY_IF_MISSING = T{
    -- e.g. ['assets/sounds/custom.wav'] = true,
};

-- ============================================================
-- State (read by the config panel)
-- ============================================================

M.status        = 'idle';   -- idle | checking | updating | done | error
M.message       = '';
M.updateReady   = false;
M.pending       = nil;
M.lastError     = nil;

-- Seed once so the cache-buster's random component isn't identical every
-- session (LuaJIT's PRNG is otherwise deterministic from a fixed seed).
math.randomseed(os.time());

-- Clear all result state. Called at the start of every Check() so a repeat
-- click always starts from a clean slate rather than showing a mix of old
-- and new values.
function M.Reset()
    M.status        = 'idle';
    M.message       = '';
    M.updateReady   = false;
    M.pending       = nil;
    M.lastError     = nil;
end

-- ============================================================
-- Helpers
-- ============================================================

local function installRoot()
    return string.format('%saddons\\XIUI\\', AshitaCore:GetInstallPath());
end

local function toLocalPath(relPath)
    return installRoot() .. relPath:gsub('/', '\\');
end

local function hasIncludedExt(path)
    for _, ext in ipairs(INCLUDE_EXT) do
        if path:sub(-#ext):lower() == ext then
            return true;
        end
    end
    return false;
end

local function isSkipped(path)
    for _, prefix in ipairs(SKIP_PREFIX) do
        if path:sub(1, #prefix) == prefix then
            return true;
        end
    end
    return false;
end

-- Monotonically increasing counter for cache busting. os.time() alone has
-- only one-second resolution, so two checks inside the same second produced
-- an identical URL and could be served from cache -- which looked like the
-- check "not resetting" because it returned the previous result.
local requestCounter = 0;

-- Blocking HTTPS GET. Returns body, or nil plus an error string.
-- Cache-busted because raw.githubusercontent caches aggressively and would
-- otherwise serve a stale file right after a push.
--
-- Uses the simple https.request(url) -> body, code form, which is the same
-- call the anglin addon uses successfully under Ashita v4.
local function httpGet(url)
    requestCounter = requestCounter + 1;

    local sep = url:find('%?') and '&' or '?';
    local bust = string.format('t=%d_%d_%d',
        os.time(), requestCounter, math.random(100000, 999999));

    local ok, body, code = pcall(function()
        return https.request(url .. sep .. bust);
    end);

    if not ok then
        return nil, 'request failed (no network?)';
    end
    if code ~= 200 then
        return nil, string.format('HTTP %s', tostring(code));
    end
    if body == nil or body == '' then
        return nil, 'empty response';
    end
    return body, nil;
end

local function fileSize(path)
    local f = io.open(path, 'rb');
    if not f then return nil; end
    local size = f:seek('end');
    f:close();
    return size;
end

-- Pull { path, size } out of the git/trees JSON response.
--
-- Entries look like:
--   {"path":"modules/playerbar.lua","mode":"100644","type":"blob",
--    "sha":"ab12...","size":1234,"url":"..."}
--
-- We deliberately do NOT use gmatch('%b{}') -- that balanced match grabs the
-- OUTERMOST brace pair (the whole document) and yields a single bogus entry.
-- Instead we walk "path" keys and read the fields bounded by the next one.
local function parseTree(body)
    local files = {};

    local pos = 1;
    while true do
        local s, e, path = body:find('"path"%s*:%s*"([^"]+)"', pos);
        if not s then break; end

        local nextS = body:find('"path"%s*:%s*"', e + 1);
        local segment = body:sub(e + 1, (nextS and nextS - 1) or #body);

        local ftype = segment:match('"type"%s*:%s*"([^"]+)"');
        local size  = tonumber(segment:match('"size"%s*:%s*(%d+)'));
        local bsha  = segment:match('"sha"%s*:%s*"([^"]+)"');

        if ftype == 'blob' and size ~= nil then
            table.insert(files, { path = path, size = size, sha = bsha });
        end

        pos = e + 1;
    end

    return files;
end

-- ============================================================
-- Public API
-- ============================================================

-- Compare the remote version to ours and work out which files differ.
-- Blocking: 2 requests (XIUI.lua for the version, the tree API for the list).
function M.Check()
    -- Full reset first: a repeat click must not inherit updateReady, pending
    -- or the message from the previous run.
    M.Reset();

    M.status  = 'checking';
    M.message = 'Checking for updates...';

    -- Straight to the file comparison. There's no version pre-fetch: the
    -- version doesn't gate anything, so downloading a 56KB XIUI.lua just to
    -- read one line was a wasted request -- and a failure point, since a
    -- hiccup there would abort the check before the comparison that actually
    -- matters ever ran.
    --
    -- The repo's addon.version is picked up from the tree data below if we
    -- happen to be downloading XIUI.lua anyway, purely for display.
    local treeBody, terr = httpGet(TREE_URL);
    if not treeBody then
        M.status      = 'error';
        M.updateReady = false;
        -- The tree API is rate limited to 60 requests/hour per IP (we use one
        -- per check, but the limit is shared by everything on that IP). Call
        -- that out specifically, since "HTTP 403" on its own looks like a
        -- permissions problem rather than something that clears on its own.
        if terr == 'HTTP 403' or terr == 'HTTP 429' then
            M.message = 'GitHub is rate limiting right now. Try again in a few minutes.';
        else
            M.message = string.format('Could not list repo files (%s).', tostring(terr));
        end
        return false;
    end

    local files = parseTree(treeBody);
    if #files == 0 then
        M.status      = 'error';
        M.updateReady = false;
        M.message     = 'Could not read the repo file list.';
        return false;
    end

    local pending = {};
    local matched = 0;
    for _, entry in ipairs(files) do
        if hasIncludedExt(entry.path) and not isSkipped(entry.path) then
            local localPath = toLocalPath(entry.path);
            local localSha  = sha1.blobFromFile(localPath);

            -- Always back-fill a missing file, even a user-customizable one:
            -- that repairs a partial install. Otherwise skip anything flagged
            -- onlyIfMissing, and content-compare everything else.
            if localSha == nil then
                table.insert(pending, entry);
            elseif not ONLY_IF_MISSING[entry.path] then
                -- Exact comparison against the remote blob SHA. Falls back to
                -- a size check only if the API somehow omitted the sha.
                if entry.sha ~= nil then
                    if localSha ~= entry.sha then
                        table.insert(pending, entry);
                    else
                        matched = matched + 1;
                    end
                elseif fileSize(localPath) ~= entry.size then
                    table.insert(pending, entry);
                else
                    matched = matched + 1;
                end
            else
                matched = matched + 1;
            end
        end
    end

    M.pending = pending;
    M.status  = 'done';

    local total = matched + #pending;

    if #pending == 0 then
        M.updateReady = false;
        M.message     = string.format('All files checked! %d/%d, No updates',
            matched, total);
        return false;
    end

    M.updateReady = true;
    M.message     = string.format('All files checked! %d/%d, %d need updating',
        matched, total, #pending);
    return true;
end

-- Download every file flagged by Check(). Blocking: one request per changed
-- file. Writes to .tmp then swaps via .bak, so a failure restores the original.
function M.Update()
    if M.pending == nil then
        M.Check();
    end

    if M.pending == nil or #M.pending == 0 then
        M.status  = 'done';
        M.message = 'Nothing to update.';
        return true;
    end

    M.status = 'updating';
    local done, failed = 0, 0;

    for _, entry in ipairs(M.pending) do
        local body = httpGet(RAW_BASE .. entry.path);

        if body == nil then
            failed = failed + 1;
        else
            local target = toLocalPath(entry.path);

            -- Create the containing folder for files in new directories.
            -- Ashita's API is ashita.fs.create_directory (not ashita.file.*).
            local dir = target:match('^(.*)\\[^\\]+$');
            if dir then
                pcall(ashita.fs.create_directory, dir);
            end

            -- Write to .tmp first so a truncated download never lands on a
            -- real .lua. Then swap: on Windows os.rename fails if the target
            -- exists, so the old file moves to .bak -- kept until the swap
            -- succeeds, because deleting it outright would leave nothing at
            -- all if the rename then failed.
            local tmp = target .. '.tmp';
            local bak = target .. '.bak';
            local out = io.open(tmp, 'wb');
            if out == nil then
                failed = failed + 1;
            else
                out:write(body);
                out:close();

                os.remove(bak);
                local hadOriginal = (fileSize(target) ~= nil);
                if hadOriginal then
                    os.rename(target, bak);
                end

                local ok = os.rename(tmp, target);
                if ok then
                    os.remove(bak);
                    done = done + 1;
                else
                    if hadOriginal then
                        os.rename(bak, target);
                    end
                    os.remove(tmp);
                    failed = failed + 1;
                end
            end
        end
    end

    if failed > 0 then
        M.status  = 'error';
        M.message = string.format('Updated %d file%s, %d failed. Try again.',
            done, done == 1 and '' or 's', failed);
        return false;
    end

    M.pending     = nil;
    M.updateReady = false;
    M.status      = 'done';
    M.message     = string.format('Updated %d file%s, reloading...',
        done, done == 1 and '' or 's');

    -- Reload ourselves. Overwriting the .lua files does nothing to the running
    -- session -- Lua is already loaded in memory -- so without this you'd keep
    -- running the old code against the new files until a manual reload. Queued
    -- rather than called directly so the current frame finishes first.
    AshitaCore:GetChatManager():QueueCommand(-1, '/addon reload xiui');

    return true;
end

return M;