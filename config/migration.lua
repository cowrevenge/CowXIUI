--[[
* XIUI Hotbar - Migration Wizard (stub)
*
* The full migration wizard imports hotbar/crossbar bindings from the tHotBar
* and tCrossBar addons. It depends on handlers/tbar_migration.lua and a large
* imgui wizard UI that are not shipped in this fork. config/hotbar.lua hard-
* requires this module at load time and exposes it as M.migrationWizard, and
* config.lua may call .Draw() as an overlay -- so this stub exists purely to
* satisfy those references and keep the addon loading.
*
* Behaviour: the "Import" button in the Hotbar config prints a notice instead
* of opening the wizard. Everything else in the hotbar works normally. Drop in
* the real config/migration.lua (and handlers/tbar_migration.lua) to enable
* tHotBar/tCrossBar import.
]]--

local M = {};

local isOpen = false;

--- Open the import wizard. Stub: report that import is unavailable in this build.
function M.Open()
    isOpen = false;
    print('[XIUI] Hotbar import wizard is not included in this build.');
    print('[XIUI] Add config/migration.lua + handlers/tbar_migration.lua to enable tHotBar/tCrossBar import.');
end

--- Close the wizard. No-op in the stub.
function M.Close()
    isOpen = false;
end

--- Whether the wizard is open. Always false in the stub.
function M.IsOpen()
    return isOpen;
end

--- Per-frame draw. No-op in the stub (nothing to render).
function M.Draw()
end

return M;
