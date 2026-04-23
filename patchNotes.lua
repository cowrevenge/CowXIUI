require('common');
local imgui = require('imgui');
local ffi = require('ffi');

local HXUITexture;
local PatchVerTexture;
local NewTexture;
gShowPatchNotes = { true };

local patchNotes = {};

local function InitializeTextures()
	if (HXUITexture == nil) then
		HXUITexture = LoadTexture("patchNotes/hxui");
	end
	if (PatchVerTexture == nil) then
		PatchVerTexture = LoadTexture("patchNotes/patch");
	end
	if (NewTexture == nil) then
		NewTexture = LoadTexture("patchNotes/new");
	end
end

--[[
* event: d3d_present
* desc : Event called when the Direct3D device is presenting a scene.
--]]
patchNotes.DrawWindow = function()
	if (gShowPatchNotes[1] == false) then
		HXUITexture = nil;
		PatchVerTexture = nil;
		NewTexture = nil;
		gConfig.patchNotesVer = gAdjustedSettings.currentPatchVer;
		UpdateSettings();
		return;
	end

	if (HXUITexture == nil or PatchVerTexture == nil or NewTexture == nil) then
		InitializeTextures();
	end
	if (HXUITexture == nil or PatchVerTexture == nil or NewTexture == nil) then
		return;
	end

	imgui.PushStyleColor(ImGuiCol_WindowBg, {0, 0.06, 0.16, 0.9});
	imgui.PushStyleColor(ImGuiCol_TitleBg, {0, 0.06, 0.16, 0.7});
	imgui.PushStyleColor(ImGuiCol_TitleBgActive, {0, 0.06, 0.16, 0.9});
	imgui.PushStyleColor(ImGuiCol_TitleBgCollapsed, {0, 0.06, 0.16, 0.5});

	-- Default size on first open. Patch notes got dense after the rewrite
	-- so give the player a comfortable reading pane; resize freely after.
	imgui.SetNextWindowSize({ 520, 640 }, ImGuiCond_FirstUseEver);

	if (gShowPatchNotes[1] and imgui.Begin('HXUI PatchNotes', gShowPatchNotes, bit.bor(ImGuiWindowFlags_NoSavedSettings))) then
		-- Header: HXUI logo + patch banner + version label.
		imgui.Image(tonumber(ffi.cast("uint32_t", HXUITexture.image)), { 83, 53 });
		imgui.SameLine();
		imgui.Image(tonumber(ffi.cast("uint32_t", PatchVerTexture.image)), { 130, 21 });
		imgui.SameLine();
		imgui.BulletText(' HOTFIX 2');
		imgui.NewLine();

		-- "NEW" banner lifted straight from the original layout.
		imgui.Image(tonumber(ffi.cast("uint32_t", NewTexture.image)), { 30, 13 });
		imgui.NewLine();

		------------------------------------------------------------------
		-- Fixed section - amber heading.
		------------------------------------------------------------------
		imgui.TextColored({ 1.0, 0.75, 0.35, 1.0 }, 'Fixed');
		imgui.Separator();
		imgui.BulletText('Dispel bug - effect is now actually removed from mob status when cast.');
		imgui.BulletText('Target bar: long mob names now ellipsis-truncate cleanly instead of overlapping the HP percent.');
		imgui.BulletText('Party list leader / sync dots: proper colors (yellow / red) and positions (left / right of the job icon).');
		imgui.NewLine();

		------------------------------------------------------------------
		-- Added section - green heading.
		------------------------------------------------------------------
		imgui.TextColored({ 0.45, 1.0, 0.55, 1.0 }, 'Added');
		imgui.Separator();
		imgui.BulletText('Stacked HP/MP option.');
		imgui.BulletText('Modern Style (see General section).');
		imgui.BulletText('Treasure Pool.');
		imgui.BulletText('Cast Box - spell/ability MP cost, recast, and TP info above the target.');
		imgui.Indent();
		imgui.BulletText('Includes its own Modern theme toggle for clean dark-blue styling.');
		imgui.Unindent();
		imgui.BulletText('Cure buttons on party list (off by default).');
		imgui.BulletText('Fixed-anchor target window in the party menu (snaps to Party 1).');
		imgui.BulletText('Target bar options:');
		imgui.Indent();
		imgui.BulletText('Show Enemy ID next to mob names.');
		imgui.BulletText('Always Show Health Percent (works on friendly / neutral targets too).');
		imgui.Unindent();
		imgui.BulletText('Party status dot system:');
		imgui.Indent();
		imgui.BulletText('Gold Treasure / Cyan Trade dots above Player 1 at the 25% / 75% marks.');
		imgui.BulletText('Yellow Leader / Red Sync dots beside each member\'s job icon.');
		imgui.BulletText('All dots work in both the textured and Modern themes.');
		imgui.Unindent();
		imgui.BulletText('Pet HUD - floating HUD for BST / DRG / SMN with:');
		imgui.Indent();
		imgui.BulletText('HP / TP / MP and BST charge tracker.');
		imgui.BulletText('Pet portrait images for jug pets, wyverns, all 14 avatars, and spirits.');
		imgui.BulletText('Pet buff / debuff panel (Stoneskin, Regen, Haste, etc. visible on your pet).');
		imgui.BulletText('Charm duration timer using the PetMe formula with a full 16-slot gear scan and the Familiar +25 min extension.');
		imgui.BulletText('Jug duration timer with HzXI-accurate pet database (27 pets sourced from the HzXI wiki).');
		imgui.BulletText('BST ready moves list with damage-type icons.');
		imgui.BulletText('Ability recasts tracked for Reward, Call Beast, Call Wyvern, Spirit Link, Steady Wing, Deep Breathing, Apogee, Mana Cede, and Astral Flow.');
		imgui.BulletText('Click any ability or ready-move row to fire the /ja or /pet command - no macro needed.');
		imgui.BulletText('Click-to-summon button when no pet is out: "Call Wyvern" on DRG, "Call Beast" on BST.');
		imgui.BulletText('Per-avatar SMN Blood Pact favorites - 14 avatars, each with Rage and Ward inputs in the nested config menu.');
		imgui.Unindent();
		imgui.NewLine();

		------------------------------------------------------------------
		-- Modded section - cyan heading for tweaks to existing features.
		------------------------------------------------------------------
		imgui.TextColored({ 0.45, 0.85, 1.0, 1.0 }, 'Modded');
		imgui.Separator();
		imgui.BulletText('Removed blue dots from inventory count.');
		imgui.BulletText('Shift+click slightly to the right of the text numbers to move the inventory tracker.');
		imgui.BulletText('Enhanced Debuffs - click a party member\'s debuff icon to auto-cast the matching White Magic cure.');
		imgui.BulletText('Enhanced Targeting - click alliance or party member names to target them.');
		imgui.BulletText('Party list Shift+hold-drag to move the window (plain click still targets the member under the cursor).');
		imgui.BulletText('Click-to-target extended to cover the job icon area, not just the HP/MP bars.');
		imgui.BulletText('Compact Mode 1 / Mode 2 - choose whether buffs and debuffs share one line or split onto two.');
		imgui.NewLine();

		------------------------------------------------------------------
		-- Todo section - soft-red heading for things on the list but
		-- not yet shipping. Helps players know what NOT to expect to
		-- work yet so they stop reporting the same bugs.
		------------------------------------------------------------------
		imgui.TextColored({ 1.0, 0.5, 0.5, 1.0 }, 'Todo');
		imgui.Separator();
		imgui.BulletText('Anchored target bar (party menu) is unfinished:');
		imgui.Indent();
		imgui.BulletText('No locked-position support yet.');
		imgui.BulletText('Treasure / status icons do not render.');
		imgui.BulletText('NPC status is not read correctly.');
		imgui.Unindent();
		imgui.NewLine();
	end
	imgui.PopStyleColor(4);
	imgui.End();
end

return patchNotes;