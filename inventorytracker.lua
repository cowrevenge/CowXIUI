require('common');
local imgui = require('imgui');
local fonts = require('fonts');

local inventoryText;

local inventoryTracker = {};

local function UpdateTextVisibility(visible)
    inventoryText:SetVisible(visible);
end

local function MakeColor(a, r, g, b)
    return bit.bor(
        bit.lshift(a, 24),
        bit.lshift(r, 16),
        bit.lshift(g, 8),
        b
    );
end

inventoryTracker.DrawWindow = function(settings)
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player == nil) then
        UpdateTextVisibility(false);
        return;
    end

    local mainJob = player:GetMainJob();
    if (player.isZoning or mainJob == 0) then
        UpdateTextVisibility(false);
        return;
    end

    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    if (inventory == nil) then
        UpdateTextVisibility(false);
        return;
    end

    local used = inventory:GetContainerCount(0);
    local max  = inventory:GetContainerCountMax(0);
    local text = ('%u/%u'):format(used, max);

    imgui.SetNextWindowSize({ -1, -1 }, ImGuiCond_Always);

    local windowFlags = bit.bor(
        ImGuiWindowFlags_NoDecoration,
        ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoBackground,
        ImGuiWindowFlags_NoBringToFrontOnFocus
    );

    if (gConfig.lockPositions) then
        windowFlags = bit.bor(windowFlags, ImGuiWindowFlags_NoMove);
    end

    if (imgui.Begin('InventoryTracker', true, windowFlags)) then
        local cursorX, cursorY = imgui.GetCursorScreenPos();
        local textSizeX, textSizeY = imgui.CalcTextSize(text);

        local offsetX = settings.offsetX or 0;
        local offsetY = settings.offsetY or 0;
        local textPosX = cursorX + offsetX;
        local textPosY = cursorY + offsetY;

        -- If right-justified, the visible text extends left from textPosX.
        local hitboxX = textPosX;
        if (settings.font_settings and settings.font_settings.right_justified) then
            hitboxX = textPosX - textSizeX;
        end

        -- Move cursor to the actual text area and make the window occupy it.
        imgui.SetCursorScreenPos({ hitboxX, textPosY });
        imgui.Dummy({ textSizeX, textSizeY });

        inventoryText:SetText(text);

        if (used >= max) then
            inventoryText:SetColor(MakeColor(255, 255, 0, 0));       -- red
        elseif (max > 0 and (used / max) >= 0.80) then
            inventoryText:SetColor(MakeColor(255, 255, 255, 0));     -- yellow
        else
            inventoryText:SetColor(MakeColor(255, 255, 255, 255));   -- white
        end

        inventoryText:SetPositionX(textPosX);
        inventoryText:SetPositionY(textPosY);

        UpdateTextVisibility(true);
    end
    imgui.End();
end

inventoryTracker.Initialize = function(settings)
    inventoryText = fonts.new(settings.font_settings);
end

inventoryTracker.UpdateFonts = function(settings)
    inventoryText:SetFontHeight(settings.font_settings.font_height);
    inventoryText:SetRightJustified(settings.font_settings.right_justified);
end

inventoryTracker.SetHidden = function(hidden)
    if (hidden == true) then
        UpdateTextVisibility(false);
    end
end

return inventoryTracker;