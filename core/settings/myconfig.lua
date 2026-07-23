--[[
* XIUI baked-in user config defaults (curated: only config-settable tuning).
* Deep-merged over the base defaults by core/settings/init.lua so a fresh
* install comes up in the intended look. Window PLACEMENT is excluded; users
* still drag windows themselves. Dead keys and float-noise are NOT included.
]]--

local M = {};

function M.createConfigOverrides()
    return T{
        ["StartKey"] = 1,
        ["castCost"] = T{
            ["backgroundTheme"] = "Plain",
            ["showRecast"] = true,
        },
        ["colorCustomization"] = T{
            -- hpTextColor stays black: HP text sits over the light HP bar fill,
            -- where black reads well. tpEmptyTextColor was ALSO black, but the
            -- sub-1000 TP bar is nearly empty and very dark, so "0" was drawn
            -- black-on-black and looked like a blank box. White instead.
            -- (-16777216 == 0xFF000000, -1 == 0xFFFFFFFF)
            ["partyListA"] = T{
                ["hpTextColor"] = -16777216,
                ["tpEmptyTextColor"] = -1,
            },
            ["partyListB"] = T{
                ["hpTextColor"] = -16777216,
                ["tpEmptyTextColor"] = -1,
            },
            ["partyListC"] = T{
                ["hpTextColor"] = -16777216,
                ["tpEmptyTextColor"] = -1,
            },
        },
        ["enablePartyListClickTarget"] = true,
        ["enemyListDebuffsAnchor"] = "left",
        ["gilTrackerIconRight"] = false,
        ["gilTrackerShowGilPerHour"] = false,
        ["inventoryShowDots"] = false,
        ["inventoryShowLabels"] = true,
        ["inventoryTextUseThresholdColor"] = true,
        ["mobInfoShowResistances"] = true,
        ["mobInfoShowWeaknesses"] = true,
        ["notificationsHideDuringEvents"] = true,
        ["notificationsShowGil"] = false,
        ["notificationsShowItems"] = false,
        ["notificationsShowKeyItems"] = false,
        ["notificationsShowTreasure"] = false,
        ["partyA"] = T{
            ["alignBottom"] = true,
            ["backgroundName"] = "Plain",
            ["flashTP"] = true,
            ["hpBarScaleX"] = 0.85,
            ["hpDisplayMode"] = "both",
            ["layout"] = 1,
            ["mpDisplayMode"] = "number",
            ["showDistance"] = true,
        },
        ["partyB"] = T{
            ["alignBottom"] = true,
            ["backgroundName"] = "Plain",
            ["entrySpacing"] = 0,
            ["flashTP"] = true,
            ["jobIconScale"] = 1,
            ["layout"] = 2,
            ["scaleX"] = 1,
            ["scaleY"] = 1,
            ["showDistance"] = true,
            ["showTP"] = true,
        },
        ["partyC"] = T{
            ["alignBottom"] = true,
            ["backgroundName"] = "Plain",
            ["entrySpacing"] = 0,
            ["flashTP"] = true,
            ["jobIconScale"] = 1,
            ["layout"] = 2,
            ["scaleX"] = 1,
            ["scaleY"] = 1,
            ["showDistance"] = true,
            ["showTP"] = true,
        },
        ["petBarAutomaton"] = T{
            ["showTimers"] = false,
        },
        ["petBarAvatar"] = T{
            ["backgroundTheme"] = "Plain",
            ["showLevel"] = true,
        },
        ["petBarAvatarSettings"] = T{
            ["diabolos"] = T{
                ["offsetX"] = -161,
            },
        },
        ["petBarBstShowCallBeast"] = true,
        ["petBarCharm"] = T{
            ["backgroundTheme"] = "Plain",
        },
        ["petBarDrgShowDeepBreathing"] = false,
        ["petBarJug"] = T{
            ["backgroundTheme"] = "Plain",
        },
        ["petBarPreviewType"] = 1,
        ["petBarReadyBaseRecast"] = 45,
        ["petBarWyvern"] = T{
            ["backgroundTheme"] = "Plain",
            ["imageOffsetX"] = -80,
            ["imageOffsetY"] = 0,
            ["imageOpacity"] = 0.41,
        },
        ["playerBarHpDisplayMode"] = "Number (Percent)",
        ["playerBarMpDisplayMode"] = "Number (Percent)",
        ["showCastBarBookends"] = false,
        ["showEnemyId"] = true,
        ["showEnemyListBookends"] = false,
        ["showPartyListBookends"] = false,
        ["showPartyListTarget"] = true,
        ["showPartyListWhenSolo"] = true,
        ["treasurePoolAutoHideWhenEmpty"] = false,
        ["treasurePoolPreview"] = true,
        ["treasurePoolShowTimerBar"] = false,
    };
end

return M;