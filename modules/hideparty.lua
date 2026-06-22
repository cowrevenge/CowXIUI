--[[---------------------------------------------------------------------------
  XIUI hideparty module
  Maps to: xiui/modules/hideparty.lua

  Hides the native FFXI party / alliance / target / cast-info UI primitives so
  XIUI users don't need to install atom0s's standalone hideparty addon. Memory
  signatures and write offsets for the four atom0s primitives are kept verbatim
  from his hideparty.lua v1.0 (Ashita Development Team, GPL).

  Adds one extra primitive beyond atom0s's set:

    castinfo  - the native spell/ability info window that displays selected
                spell or job ability details (MP cost, recast, "Next: 0:00",
                etc). Slot address sits exactly 4 bytes below `target` in the
                FFXiMain.dll data section, so we resolve it as `target - 4`.
                Discovered empirically with the dumpprims debug addon.

  Defaults: all five elements hidden.

  Self-registers three Ashita events under unique callback names so it can't
  collide with XIUI.lua's own load/present/unload handlers:
    xiui_hideparty_load_cb     - resolves the 5 primitive pointers
    xiui_hideparty_present_cb  - per-frame visibility apply
    xiui_hideparty_unload_cb   - restores everything to visible on unload
                                 (so the user isn't stuck with a missing
                                  native UI if they unload XIUI)
-----------------------------------------------------------------------------]]

require('common');
local chat = require('chat');

local hideparty = {
    initialized = false,
    ptrs = {
        target   = 0,
        party0   = 0,
        party1   = 0,
        party2   = 0,
        castinfo = 0,
    },
};

-- Writes the visibility byte pair (+0x69, +0x6A from the dereferenced primitive
-- base) for a single native UI primitive. `p` is an address-of-address; the
-- pointer it holds may move between zones, so we dereference fresh every call.
-- Source: atom0s/hideparty set_primitive_visibility, unchanged.
local function set_primitive_visibility(p, v)
    if (p == nil or p == 0) then return; end
    local ptr = ashita.memory.read_uint32(p);
    if (ptr ~= 0) then
        ptr = ashita.memory.read_uint32(ptr + 0x08);
        if (ptr ~= 0) then
            ashita.memory.write_uint8(ptr + 0x69, v);
            ashita.memory.write_uint8(ptr + 0x6A, v);
        end
    end
end

-- Reads gConfig.hideStockUI with sane defaults (hide everything). Returns a
-- flat table the d3d_present callback uses directly.
local function get_settings()
    local cfg = (gConfig and gConfig.hideStockUI) or {};
    return {
        enabled  = (cfg.enabled  ~= false),  -- default true
        party0   = (cfg.party0   ~= false),  -- default true (hide main party)
        party1   = (cfg.party1   ~= false),  -- default true (hide alliance 1)
        party2   = (cfg.party2   ~= false),  -- default true (hide alliance 2)
        target   = (cfg.target   ~= false),  -- default true (hide target cursor)
        castinfo = (cfg.castinfo ~= false),  -- default true (hide spell/ability info window)
    };
end

--[[
  Resolve the 5 native primitive pointers.

  ptr1 sig hits a CMP-block in FFXiMain.dll that prepares main-party + target
       primitive slot pointers; party0 lives at +0x19, target at +0x23.
       castinfo is target_slot - 4 (4 bytes earlier in the same data array).

  ptr2 sig hits the alliance setup; party1 at +0x01, party2 at +0x07.
--]]
ashita.events.register('load', 'xiui_hideparty_load_cb', function ()
    local ptr1 = ashita.memory.find('FFXiMain.dll', 0,
        '66C78182000000????C7818C000000????????C781900000', 0, 0);
    if (ptr1 == 0) then
        print(chat.header('xiui'):append(chat.error(
            'hideparty: failed to locate signature 1 (main party / target / castinfo). Native UI will not be hidden.')));
        return;
    end

    local ptr2 = ashita.memory.find('FFXiMain.dll', 0,
        'A1????????8B0D????????89442424A1????????33DB89', 0, 0);
    if (ptr2 == 0) then
        print(chat.header('xiui'):append(chat.error(
            'hideparty: failed to locate signature 2 (alliance). Alliance frames will not be hidden.')));
        -- Continue anyway; party0 + target + castinfo still work.
    end

    hideparty.ptrs.party0   = ashita.memory.read_uint32(ptr1 + 0x19);
    hideparty.ptrs.target   = ashita.memory.read_uint32(ptr1 + 0x23);
    hideparty.ptrs.castinfo = hideparty.ptrs.target - 4;
    if (ptr2 ~= 0) then
        hideparty.ptrs.party1 = ashita.memory.read_uint32(ptr2 + 0x01);
        hideparty.ptrs.party2 = ashita.memory.read_uint32(ptr2 + 0x07);
    end

    hideparty.initialized = true;
end);

--[[
  Per-frame visibility apply. Cheap (5 memory reads + 10 writes), so running
  every present is fine. We re-read settings each frame because the user can
  toggle elements in the config menu without us needing a notification path.
--]]
ashita.events.register('d3d_present', 'xiui_hideparty_present_cb', function ()
    if (not hideparty.initialized) then return; end
    local s = get_settings();
    -- Visibility byte: 0 = hidden, 1 = visible.
    -- "Module enabled AND element flagged to hide" -> 0 (hide), else 1.
    set_primitive_visibility(hideparty.ptrs.party0,   (s.enabled and s.party0)   and 0 or 1);
    set_primitive_visibility(hideparty.ptrs.party1,   (s.enabled and s.party1)   and 0 or 1);
    set_primitive_visibility(hideparty.ptrs.party2,   (s.enabled and s.party2)   and 0 or 1);
    set_primitive_visibility(hideparty.ptrs.target,   (s.enabled and s.target)   and 0 or 1);
    set_primitive_visibility(hideparty.ptrs.castinfo, (s.enabled and s.castinfo) and 0 or 1);
end);

--[[
  Restore on unload so disabling XIUI doesn't leave the user with no native UI.
  Sets every primitive back to visible regardless of config state.
--]]
ashita.events.register('unload', 'xiui_hideparty_unload_cb', function ()
    if (not hideparty.initialized) then return; end
    set_primitive_visibility(hideparty.ptrs.party0,   1);
    set_primitive_visibility(hideparty.ptrs.party1,   1);
    set_primitive_visibility(hideparty.ptrs.party2,   1);
    set_primitive_visibility(hideparty.ptrs.target,   1);
    set_primitive_visibility(hideparty.ptrs.castinfo, 1);
end);

return hideparty;