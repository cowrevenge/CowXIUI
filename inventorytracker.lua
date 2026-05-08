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

-- Returns the (x, y) pixel offset of a dot at (row, column) within a group.
-- Row/column are 1-indexed; (1,1) sits at (radius*2, radius*2). dotSpacing is
-- the gap between adjacent dots in the same group.
local function GetDotOffset(row, column, dotRadius, dotSpacing)
    local x = (column * dotRadius * 2) + (dotSpacing * (column - 1));
    local y = (row    * dotRadius * 2) + (dotSpacing * (row    - 1));
    return x, y;
end

-- Color-code the count text by fill ratio:
--   >=100%  red    (full)
--   >=80%   yellow (warning)
--   else    white  (ok)
local function ApplyCountColor(used, max)
    if (used >= max) then
        inventoryText:SetColor(MakeColor(255, 255, 0,   0));
    elseif (max > 0 and (used / max) >= 0.80) then
        inventoryText:SetColor(MakeColor(255, 255, 255, 0));
    else
        inventoryText:SetColor(MakeColor(255, 255, 255, 255));
    end
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

    -- gConfig is the source of truth (configmenu writes here directly).
    -- showInventoryDots    - toggle restoring the old-style dot grid.
    -- inventoryShowCount   - nil/true => show the numeric counter (default: on).
    -- inventoryAnchoredText- nil/true => count is anchored to a corner of the grid
    --                        (the Text Position + New Line options apply).
    --                        false    => count floats in its own draggable window
    --                        (shift-drag, partylist style).
    local showDots  = (gConfig.showInventoryDots   == true);
    local showCount = (gConfig.inventoryShowCount  ~= false);
    local anchored  = (gConfig.inventoryAnchoredText ~= false);

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
        if (showDots) then
            -- =====================================================
            -- Dot-grid mode (restored from the pre-rewrite tracker).
            -- One dot per inventory slot, arranged in groups of
            -- rowCount x columnCount. Filled (blue) = used, empty
            -- (dark) = free. Count text (if shown) is drawn to the
            -- right of the grid by gdifonts.
            -- =====================================================
            local rowCount     = settings.rowCount     or 5;
            local columnCount  = settings.columnCount  or 16;
            local dotRadius    = settings.dotRadius    or 4;
            local dotSpacing   = settings.dotSpacing   or 2;
            local groupSpacing = settings.groupSpacing or 8;
            local opacity      = settings.opacity      or 1.0;
            local textOffsetY  = settings.textOffsetY  or 0;

            local groupOffsetX, groupOffsetY = GetDotOffset(rowCount, columnCount, dotRadius, dotSpacing);
            groupOffsetX = groupOffsetX + groupSpacing;
            local numPerGroup = rowCount * columnCount;
            local totalGroups = math.ceil(max / numPerGroup);
            local winSizeX    = (groupOffsetX * totalGroups);
            local winSizeY    = groupOffsetY;

            -- Drag-handle area (also drives auto-resize of the window).
            imgui.Dummy({ winSizeX, winSizeY });
            local locX, locY = imgui.GetWindowPos();

            for i = 1, max do
                local groupNum        = math.ceil(i / numPerGroup);
                local offsetFromGroup = i - ((groupNum - 1) * numPerGroup);
                local rowNum          = math.ceil(offsetFromGroup / columnCount);
                local columnNum       = offsetFromGroup - ((rowNum - 1) * columnCount);

                local x, y = GetDotOffset(rowNum, columnNum, dotRadius, dotSpacing);
                x = x + ((groupNum - 1) * groupOffsetX);

                local cx = x + locX + imgui.GetStyle().FramePadding.x;
                local cy = y + locY;

                if (i > used) then
                    -- empty slot: hollow dark dot
                    draw_circle({ cx, cy }, dotRadius, { 0, 0.07, 0.17, opacity }, dotRadius * 3, true);
                else
                    -- used slot: blue fill with dark outline
                    draw_circle({ cx, cy }, dotRadius, { 0.37, 0.70, 0.88, opacity }, dotRadius * 3, true);
                    draw_circle({ cx, cy }, dotRadius, { 0,    0.07, 0.17, opacity }, dotRadius * 3, false);
                end
            end

            if (showCount and anchored) then
                inventoryText:SetText(text);
                ApplyCountColor(used, max);

                -- Compute the VISUAL bounding box of the dot grid.
                -- The dots are inset from the imgui window by FramePadding.x on the
                -- left, and the first row's dot tops sit dotRadius below locY (since
                -- a row's center is at +2*dotRadius and its top edge is +dotRadius).
                -- Likewise the right edge: the last column's right edge is at
                --   winSizeX - groupSpacing + dotRadius
                -- because winSizeX includes a trailing groupSpacing for the (absent)
                -- next group.
                local fp         = imgui.GetStyle().FramePadding.x;
                local gridLeft   = locX + fp + dotRadius;
                local gridRight  = locX + fp + winSizeX - groupSpacing + dotRadius;
                local gridTop    = locY + dotRadius;
                local gridBottom = locY + winSizeY + dotRadius;

                -- Anchor the count at one of four positions of the dot grid.
                -- gConfig.inventoryTextPosition: 'Top Right' | 'Bottom Right' | 'Top Left' | 'Bottom Left'
                -- gConfig.inventoryTextNewLine:
                --   false (default) - text sits ALONGSIDE the grid (right/left of it).
                --     Right/Left controls which side; Top/Bottom controls vertical alignment.
                --   true            - text sits on its own line ABOVE or BELOW the grid.
                --     Top/Bottom controls which side; Right/Left controls justification.
                local fontH    = inventoryText:GetFontHeight();
                local gap      = 4;
                local position = gConfig.inventoryTextPosition or 'Top Right';
                local newLine  = (gConfig.inventoryTextNewLine == true);

                local px, py;
                local rightJustified;

                if (newLine) then
                    -- Text on its own line above/below the grid.
                    if (position == 'Top Right') then
                        rightJustified = true;
                        px = gridRight;
                        py = gridTop - fontH - gap;
                    elseif (position == 'Top Left') then
                        rightJustified = false;
                        px = gridLeft;
                        py = gridTop - fontH - gap;
                    elseif (position == 'Bottom Right') then
                        rightJustified = true;
                        px = gridRight;
                        py = gridBottom + gap;
                    else  -- 'Bottom Left'
                        rightJustified = false;
                        px = gridLeft;
                        py = gridBottom + gap;
                    end
                else
                    -- Text alongside the grid (right or left of it).
                    if (position == 'Bottom Right') then
                        rightJustified = false;
                        px = gridRight + gap;
                        py = gridBottom - fontH;
                    elseif (position == 'Top Left') then
                        rightJustified = true;
                        px = gridLeft - gap;
                        py = gridTop;
                    elseif (position == 'Bottom Left') then
                        rightJustified = true;
                        px = gridLeft - gap;
                        py = gridBottom - fontH;
                    else  -- 'Top Right' (default)
                        rightJustified = false;
                        px = gridRight + gap;
                        py = gridTop;
                    end
                end

                if (inventoryText.SetRightJustified) then
                    inventoryText:SetRightJustified(rightJustified);
                end
                inventoryText:SetPositionX(px);
                inventoryText:SetPositionY(py + textOffsetY);
                UpdateTextVisibility(true);
            elseif (not showCount) then
                UpdateTextVisibility(false);
            end
            -- (when not anchored the text is rendered after this Begin/End
            -- block, in its own draggable window — see below.)
        else
            -- =====================================================
            -- Text-only mode (the "new" tracker, untouched).
            -- Color-coded fraction with a drag-handle Dummy nudged
            -- to overlap the gdifonts glyph area.
            -- =====================================================
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

            if (showCount) then
                inventoryText:SetText(text);
                ApplyCountColor(used, max);
                -- Reset justification in case dots-mode left it right-justified.
                if (inventoryText.SetRightJustified) then inventoryText:SetRightJustified(false); end
                inventoryText:SetPositionX(anchorX);
                inventoryText:SetPositionY(anchorY);
                UpdateTextVisibility(true);
            else
                UpdateTextVisibility(false);
            end
        end
    end
    imgui.End();

    -- =====================================================
    -- Free-floating text window (when 'Anchored Text' is unchecked).
    -- Renders the count in its own ImGui window so the user can position
    -- it freely with shift+drag (matching the partylist behavior).
    -- =====================================================
    if (showDots and showCount and not anchored) then
        local textWindowFlags = bit.bor(
            ImGuiWindowFlags_NoDecoration,
            ImGuiWindowFlags_AlwaysAutoResize,
            ImGuiWindowFlags_NoFocusOnAppearing,
            ImGuiWindowFlags_NoNav,
            ImGuiWindowFlags_NoBackground,
            ImGuiWindowFlags_NoBringToFrontOnFocus
        );
        -- Window is draggable only while Shift is held (and only if lockPositions is off).
        if (gConfig.lockPositions or not imgui.GetIO().KeyShift) then
            textWindowFlags = bit.bor(textWindowFlags, ImGuiWindowFlags_NoMove);
        end

        imgui.SetNextWindowSize({ -1, -1 }, ImGuiCond_Always);
        if (imgui.Begin('InventoryTrackerFloatingText', true, textWindowFlags)) then
            local anchorX, anchorY = imgui.GetCursorScreenPos();
            local textSizeX, textSizeY = imgui.CalcTextSize(text);

            -- Same drag-handle nudge math as the text-only mode so the gdifont
            -- glyphs sit on top of the invisible Dummy rather than next to it.
            local fontXNudge = 0;
            local fontYNudge = 4;
            local glyphScale = 1.30;
            local rectX = anchorX + fontXNudge;
            local rectY = anchorY + fontYNudge;
            local rectW = math.floor(textSizeX * glyphScale + 0.5);

            imgui.SetCursorScreenPos({ rectX, rectY });
            imgui.Dummy({ rectW, textSizeY });

            inventoryText:SetText(text);
            ApplyCountColor(used, max);
            if (inventoryText.SetRightJustified) then inventoryText:SetRightJustified(false); end
            inventoryText:SetPositionX(anchorX);
            inventoryText:SetPositionY(anchorY);
            UpdateTextVisibility(true);
        end
        imgui.End();
    end
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