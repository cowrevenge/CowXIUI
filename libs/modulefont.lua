--[[
* libs/modulefont -- per-module font family / weight / outline override.
*
* Several modules draw their text with imgui rather than gdifont primitives
* (gdi renders UNDER imgui, so a window background would cover it). Bare
* imgui.AddText has no font argument, which pins the text to imgui's built-in
* bitmap font -- crisp, but it means the configured font family, weight and
* size settings do nothing.
*
* Routing those draws through libs/imtext fixes the sizing, but imtext holds
* the family/weight as MODULE-level state shared by every caller, so whichever
* module drew last wins. This wraps that in a per-module override:
*
*   Apply(moduleKey, overrideEnabled, family, weight, outlineWidth, fallback)
*
* Call it once per frame before drawing. When overrideEnabled is false the
* module follows the global font settings passed as `fallback`.
*
* 'Default' as a family means imgui's built-in font (imtext leaves activeFont
* nil and falls through to bare AddText). It stays sharp at small sizes where
* the TTF families blur, which is why it is the default for these modules --
* they were using it implicitly before, and the intent is to preserve that
* look while making it selectable.
]]--

require('common');
local imtext = require('libs.imtext');

local M = {};

--- Apply a module's font configuration to imtext for this frame.
---
--- @param overrideEnabled boolean  module has its own font settings
--- @param family          string   font family, or 'Default' for built-in
--- @param weight          string   'Normal' or 'Bold'
--- @param outlineWidth    number   0-2
--- @param fallback        table    font_settings table used when not overriding
function M.Apply(overrideEnabled, family, weight, outlineWidth, fallback)
    if overrideEnabled then
        imtext.SetConfig(family or 'Default', weight == 'Bold', outlineWidth or 2);
    elseif fallback ~= nil then
        imtext.SetConfigFromSettings(fallback);
    end
end

--- Draw outlined text at the given size, converting an RGBA float table to the
--- ARGB int imtext expects.
---
--- Kept here so the modules that need it do not each carry their own copy of
--- the colour packing, which is easy to get subtly wrong.
---
--- @param drawList  imgui draw list
--- @param x,y       number  top-left position
--- @param text      string
--- @param rgba      table   {r,g,b,a} floats 0-1
--- @param size      number|nil  font height; nil uses imtext's default
function M.DrawText(drawList, x, y, text, rgba, size)
    if drawList == nil or text == nil or text == '' then return; end
    local c = rgba or { 1, 1, 1, 1 };
    local argb = bit.bor(
        bit.lshift(math.floor((c[4] or 1) * 255), 24),
        bit.lshift(math.floor(c[1] * 255), 16),
        bit.lshift(math.floor(c[2] * 255), 8),
        math.floor(c[3] * 255));
    imtext.Draw(drawList, tostring(text), x, y, argb, size);
end

--- Measure at the size the text will actually be drawn at.
---
--- Always pair this with DrawText. Measuring with imgui.CalcTextSize while
--- drawing through imtext reports the wrong width, and every right-aligned or
--- centred value lands in the wrong place.
function M.Measure(text, size)
    return imtext.Measure(tostring(text or ''), size);
end

return M;
