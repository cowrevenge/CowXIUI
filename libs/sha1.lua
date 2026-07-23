--[[
* SHA-1 / git blob hashing
*
* Used by libs/updater.lua to tell whether a local file matches what's in the
* GitHub repo. GitHub's git/trees API hands back a blob SHA for every file, so
* computing the same hash locally gives an exact content comparison -- no
* manifest to maintain, and no blind spot for edits that happen to keep the
* file the same length.
*
* Implemented in pure Lua on LuaJIT's bit library (which Ashita provides).
* Verified against the standard SHA-1 test vectors and against real blob SHAs
* returned by the GitHub API. Hashing this addon's ~130 Lua files takes about
* 100ms total, i.e. one dropped frame, which is cheap next to the network
* calls it saves.
*
* A "git blob SHA" is not a plain SHA-1 of the file: git prefixes the content
* with a header, so the hash is sha1("blob <bytelength>\0" .. content).
]]--

local bit = require('bit');

local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot;
local lshift, rshift, rol, tobit = bit.lshift, bit.rshift, bit.rol, bit.tobit;

local M = {};

-- LuaJIT's tobit() yields a SIGNED 32-bit integer. Passing a negative value to
-- string.format('%08x') sign-extends it to 64 bits and prints eight leading
-- 'f's, so fold to unsigned before formatting.
local function hex32(n)
    local u = n % 4294967296;
    if u < 0 then
        u = u + 4294967296;
    end
    return string.format('%08x', u);
end

local function be32(n)
    return string.char(
        band(rshift(n, 24), 0xFF),
        band(rshift(n, 16), 0xFF),
        band(rshift(n, 8), 0xFF),
        band(n, 0xFF));
end

-- SHA-1 of an arbitrary string. Returns a lowercase 40-char hex digest.
function M.sha1(msg)
    local h0, h1, h2, h3, h4 =
        0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0;

    local bitlen = #msg * 8;

    -- Pad: 0x80, then zeros until the length is 56 mod 64, then the original
    -- bit length as a 64-bit big-endian integer.
    msg = msg .. '\128';
    while (#msg % 64) ~= 56 do
        msg = msg .. '\0';
    end
    msg = msg .. be32(math.floor(bitlen / 4294967296)) .. be32(bitlen % 4294967296);

    local w = {};
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3);
            w[i] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d);
        end
        for i = 16, 79 do
            w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1);
        end

        local a, b, c, d, e = h0, h1, h2, h3, h4;
        for i = 0, 79 do
            local f, k;
            if i < 20 then
                f = bor(band(b, c), band(bnot(b), d));
                k = 0x5A827999;
            elseif i < 40 then
                f = bxor(b, c, d);
                k = 0x6ED9EBA1;
            elseif i < 60 then
                f = bor(band(b, c), band(b, d), band(c, d));
                k = 0x8F1BBCDC;
            else
                f = bxor(b, c, d);
                k = 0xCA62C1D6;
            end

            local temp = tobit(rol(a, 5) + f + e + k + w[i]);
            e = d;
            d = c;
            c = rol(b, 30);
            b = a;
            a = temp;
        end

        h0 = tobit(h0 + a);
        h1 = tobit(h1 + b);
        h2 = tobit(h2 + c);
        h3 = tobit(h3 + d);
        h4 = tobit(h4 + e);
    end

    return hex32(h0) .. hex32(h1) .. hex32(h2) .. hex32(h3) .. hex32(h4);
end

-- Git blob SHA of a string: sha1("blob <len>\0" .. content).
function M.blobFromString(data)
    return M.sha1('blob ' .. #data .. '\0' .. data);
end

-- Git blob SHA of a file on disk, or nil if it can't be read.
--
-- IMPORTANT: line endings are normalized to LF first.
--
-- Git stores blobs with LF, but Git for Windows defaults to
-- core.autocrlf=true, which converts to CRLF on checkout. So a file that is
-- byte-identical to the repo as far as git is concerned sits on disk with
-- CRLF and hashes differently. Without this normalization the updater
-- reports untouched files as "needs updating", tries to download them, and
-- they immediately come back as changed again -- a permanent false positive.
--
-- Hashing the LF-normalized bytes reproduces exactly what git hashed, so the
-- comparison matches regardless of the user's autocrlf setting.
function M.blobFromFile(path)
    local f = io.open(path, 'rb');
    if not f then
        return nil;
    end
    local data = f:read('*all');
    f:close();
    if data == nil then
        return nil;
    end
    data = data:gsub('\r\n', '\n');
    return M.blobFromString(data);
end

return M;
