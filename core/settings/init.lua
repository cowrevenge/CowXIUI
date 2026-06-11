--[[
* XIUI Settings Init
* Re-exports all settings modules for backward compatibility
*
* Structure:
*   settings/factories.lua  - Factory functions for creating defaults with overrides
*   settings/colors.lua     - Color customization defaults
*   settings/user.lua       - User-configurable settings (gConfig defaults)
*   settings/modules.lua    - Internal module defaults (dimensions, fonts, etc.)
]]--

local factories = require('core.settings.factories');
local colors = require('core.settings.colors');
local user = require('core.settings.user');
local modules = require('core.settings.modules');
local myconfig = require('core.settings.myconfig');

local M = {};

-- Deep-merge override values onto a base table (recurses into subtables;
-- scalar/array values are replaced outright). Used to layer the shipped,
-- pre-tuned config over the base defaults.
local function deepMerge(base, over)
    if type(base) ~= 'table' or type(over) ~= 'table' then return over; end
    for k, v in pairs(over) do
        if type(v) == 'table' and type(base[k]) == 'table' then
            deepMerge(base[k], v);
        else
            base[k] = v;
        end
    end
    return base;
end

-- Re-export factory functions for external use
M.createPartyDefaults = factories.createPartyDefaults;
M.createPetBarTypeDefaults = factories.createPetBarTypeDefaults;
M.createPetBarTypeColorDefaults = factories.createPetBarTypeColorDefaults;
M.createPartyColorDefaults = factories.createPartyColorDefaults;

-- Re-export color customization creator
M.createColorCustomizationDefaults = colors.createColorCustomizationDefaults;

-- Create the main settings tables (called at load time)
M.user_settings = user.createUserSettingsDefaults();
M.default_settings = modules.createModuleDefaults();

-- Layer the pre-tuned config over the defaults so a fresh install comes up in
-- the intended look (layout, fonts, colors, offsets). Window PLACEMENT is NOT
-- in the override set, so users still position windows themselves.
deepMerge(M.user_settings, myconfig.createConfigOverrides());

return M;