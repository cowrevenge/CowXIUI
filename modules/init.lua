--[[
    UI Modules for XIUI
    Main entry point that provides access to all UI modules
]]

local modules = {};

-- Load UI modules
modules.playerbar = require('modules.playerbar');
modules.targetbar = require('modules.targetbar');
modules.enemylist = require('modules.enemylist');
modules.expbar = require('modules.expbar');
modules.giltracker = require('modules.giltracker');
modules.inventory = require('modules.inventory.init');
modules.partylist = require('modules.partylist.init');
modules.castbar = require('modules.castbar');
modules.petbar = require('modules.petbar.init');
modules.castcost = require('modules.castcost.init');
modules.notifications = require('modules.notifications.init');
modules.treasurepool = require('modules.treasurepool.init');

-- Self-registering side-effect module (no Initialize/DrawWindow/etc.).
-- Registers its own load/present/unload Ashita event callbacks under unique
-- names. Assigned to the table only so it shows up in `modules` for inspection;
-- the registry will skip it because it has no DrawWindow.
modules.hideparty = require('modules.hideparty');

return modules;