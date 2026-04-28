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
        local anchorX, anchorY = imgui.GetCursorScreenPos();
        local textSizeX, textSizeY = imgui.CalcTextSize(text);

        -- The drag-handle region. The visible numbers are drawn by
        -- gdifonts, which renders a few pixels to the right of where
        -- ImGui's CalcTextSize/cursor places things, AND each glyph is
        -- wider in gdifonts than in ImGui's bundled font. So we both
        -- shift right and widen the rectangle to wrap the real text.
        local fontXNudge = 0;       -- horizontal offset to gdifont start
        local fontYNudge = 4;       -- nudge box DOWN to sit on the numbers
        local glyphScale = 1.30;    -- wider to extend box ~half a glyph past the last digit
        local rectX = anchorX + fontXNudge;
        local rectY = anchorY + fontYNudge;
        local rectW = math.floor(textSizeX * glyphScale + 0.5);

        imgui.SetCursorScreenPos({ rectX, rectY });
        imgui.Dummy({ rectW, textSizeY });

        -- Visible numbers drawn by gdifonts at the same anchor.
        inventoryText:SetText(text);
        if (used >= max) then
            inventoryText:SetColor(MakeColor(255, 255, 0, 0));       -- red
        elseif (max > 0 and (used / max) >= 0.80) then
            inventoryText:SetColor(MakeColor(255, 255, 255, 0));     -- yellow
        else
            inventoryText:SetColor(MakeColor(255, 255, 255, 255));   -- white
        end
        inventoryText:SetPositionX(anchorX);
        inventoryText:SetPositionY(anchorY);
        UpdateTextVisibility(true);
    end
    imgui.End();
end

inventoryTracker.Initialize = function(settings)
    inventoryText = fonts.new(settings.font_settings);
    if (inventoryText.SetRightJustified) then
        inventoryText:SetRightJustified(false);
    end
end

inventoryTracker.UpdateFonts = function(settings)
    inventoryText:SetFontHeight(settings.font_settings.font_height);
    if (inventoryText.SetRightJustified) then
        inventoryText:SetRightJustified(false);
    end
end

inventoryTracker.SetHidden = function(hidden)
    if (hidden == true) then
        UpdateTextVisibility(false);
    end
end

return inventoryTracker;