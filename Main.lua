ReUI.Require {
    "ReUI.Core >= 1.1.0",
    "ReUI.Options >= 1.0.0",
}

function Main(isReplay)
    -- No isReplay guard: works in replays (switch into a player POV).
    --
    -- NOTE: Lua caps a function at 32 captured upvalues. To stay under it,
    -- related locals are bundled into tables (C colors, K constants, S state,
    -- W widgets) so each closure captures a few tables, not dozens of locals.

    local UIUtil           = import("/lua/ui/uiutil.lua")
    local LayoutHelpers    = import("/lua/maui/layouthelpers.lua")
    local Prefs            = import('/lua/user/prefs.lua')
    local Dragger          = import('/lua/maui/dragger.lua').Dragger
    local Bitmap           = import('/lua/maui/bitmap.lua').Bitmap
    local GetEnhancements  = import('/lua/enhancementcommon.lua').GetEnhancements
    local GameMain         = import('/lua/ui/game/gamemain.lua')
    local ObserveSelection = GameMain.ObserveSelection

    local OPT = ReUI.Options.Mods["DynamicSelectionInfo"]

    -- Colors (each number is identified by color since labels are gone)
    local C = {
        MASS    = "FFB8F400", -- green
        ENERGY  = "FFF8C000", -- yellow
        BUILD   = "FFFFFFFF", -- white
        KILLED  = "FFFF5050", -- red
        RECLAIM = "FF40E0A0", -- spring green
        DPS     = "FFFF8030", -- orange
        HP      = "FF40E060", -- green
        SHIELD  = "FF50A8FF", -- blue
        NEG     = "FFF30017", -- negative rate
        HEADER  = "FF8893A0", -- dim grey
    }

    -- Layout constants (logical px, at 100% font scale)
    local K = {
        FONT        = UIUtil.bodyFont,
        NUM_SIZE    = 14,
        HDR_SIZE    = 11,
        TOP_PAD     = 3,
        BOT_PAD     = 4,
        LINE_H      = 15,
        HDR_H       = 14,
        COL_LEFT    = 5, -- x of first column
        COL_W       = 50, -- pitch between columns
        COL_CONTENT = 72, -- content width inside a column (for panel width)
    }

    -- Live scaled layout values (K * fontScale); filled by Rescale().
    local LV = {
        TOP_PAD = K.TOP_PAD, BOT_PAD = K.BOT_PAD,
        LINE_H = K.LINE_H, HDR_H = K.HDR_H,
        COL_LEFT = K.COL_LEFT, COL_W = K.COL_W, COL_CONTENT = K.COL_CONTENT,
        CHAR_W_NUM = 1, CHAR_W_HDR = 1,
    }

    -- Mutable state
    local S = {
        panel        = nil,
        built        = false,
        count        = 0, -- current selection size
        sel          = nil, -- current selection (array)
        dps          = 0, -- cached static DPS (recomputed only on selection change)
        reclaimed    = 0, -- last-computed total reclaimed mass
        reclaimShown = false, -- whether the reclaim row is currently laid out
    }

    -- Forward declaration: UpdateValues (ticker) may trigger a relayout when
    -- the reclaim total crosses 0, so it needs to call Layout.
    local Layout

    -- Widget controls
    local W = {}

    -- ── Font scaling ──────────────────────────────────────────────────────
    -- Reads the fontScale option (percent) and rescales both the live layout
    -- values and every text control. SetFont takes a logical point size and
    -- applies the UI-resolution scale itself, so we pass scaled-but-logical
    -- sizes here. Panel size follows from LV in Layout(), so the background
    -- scales automatically.
    local function Rescale()
        local pct = 100
        pcall(function() pct = OPT.fontScale() end)
        pct = pct or 100
        if pct < 50 then pct = 50 end
        if pct > 400 then pct = 400 end
        local s = pct / 100
        local function R(base) return math.floor(base * s + 0.5) end

        LV.TOP_PAD     = R(K.TOP_PAD)
        LV.BOT_PAD     = R(K.BOT_PAD)
        LV.LINE_H      = R(K.LINE_H)
        LV.HDR_H       = R(K.HDR_H)
        LV.COL_LEFT    = R(K.COL_LEFT)
        LV.COL_W       = R(K.COL_W)
        LV.COL_CONTENT = R(K.COL_CONTENT)

        -- approximate average character widths (pixels) for numeric and header fonts
        LV.CHAR_W_NUM = math.max(1, math.floor(R(K.NUM_SIZE) * 0.55 + 0.5))
        -- headers use slightly tighter average width
        LV.CHAR_W_HDR = math.max(1, math.floor(R(K.HDR_SIZE) * 0.5 + 0.5))

        local numSize = R(K.NUM_SIZE)
        local hdrSize = R(K.HDR_SIZE)
        local hdrs = { W.hdrResources, W.hdrBuildpower, W.hdrCost,
            W.hdrKilled, W.hdrReclaimed, W.hdrCombat }
        for i = 1, table.getn(hdrs) do
            if hdrs[i] then pcall(function() hdrs[i]:SetFont(K.FONT, hdrSize) end) end
        end
        local vals = { W.valMass, W.valEnergy, W.valBuildpower, W.valEnergyUsage,
            W.valMassUsage, W.valMassKilled, W.valReclaimed,
            W.valDPS, W.valHP, W.valShield }
        for i = 1, table.getn(vals) do
            if vals[i] then pcall(function() vals[i]:SetFont(K.FONT, numSize) end) end
        end
    end

    -- Helper to set text and remember it for width measurement
    local function SetTextAndRecord(ctrl, text, color)
        pcall(function() ctrl:SetText(text) end)
        if color and type(ctrl.SetColor) == 'function' then pcall(function() ctrl:SetColor(color) end) end
        ctrl._text = tostring(text or "")
    end

    -- ── Position persistence ─────────────────────────────────────────────
    local function LoadPos()
        local p = Prefs.GetFromCurrentProfile('SelectionInfo_pos')
        if p and p.left ~= nil and p.top ~= nil then return p.left, p.top end
        return 450, 14
    end

    local function SavePos()
        if not S.panel or IsDestroyed(S.panel) then return end
        Prefs.SetToCurrentProfile("SelectionInfo_pos", {
            left = LayoutHelpers.InvScaleNumber(S.panel.Left()),
            top  = LayoutHelpers.InvScaleNumber(S.panel.Top()),
        })
    end

    -- ── DPS (blueprint-derived, static; computed only on selection change) ─
    -- Rules:
    --   * ACU (COMMAND): always a flat 100, regardless of upgrades.
    --   * SACU (SUBCOMMANDER): base direct-fire DPS by faction
    --       Seraphim 400, Nomads 200, everyone else (UEF/Cybran/Aeon) 300.
    --   * Every other unit: straight blueprint sum of its real weapons.
    -- Overcharge / Death / Teleport / dummy / zero-damage weapons never count.
    local function WeaponDPS(w)
        local dmg = w.Damage or 0
        if dmg <= 0 then return 0 end

        local rof = w.RateOfFire or 1
        if rof <= 0 then rof = 1 end

        -- Match FA's weapon-detail calculation. MuzzleSalvoSize is the number
        -- of projectiles in a delayed muzzle salvo; ProjectilesPerOnFire is
        -- not an additional multiplier for these weapons. A full firing cycle
        -- also includes the muzzle delays, charge time, and salvo reload time.
        local function RoundToTick(t)
            if t <= 0 then return 0 end
            return math.max(0.1, math.floor(t * 10 + 0.5) / 10)
        end

        local cooldown = RoundToTick(1 / rof)
        local charge = RoundToTick(w.RackSalvoChargeTime or 0)
        local reload = RoundToTick(w.RackSalvoReloadTime or 0)
        local muzzleDelay = RoundToTick(w.MuzzleSalvoDelay or 0)
        local muzzleChargeDelay = RoundToTick(w.MuzzleChargeDelay or 0)
        local perMuzzleDelay = muzzleDelay + muzzleChargeDelay
        local racks = w.RackBones or {}
        local rackCount = table.getn(racks)
        if rackCount == 0 then rackCount = 1 end

        local cycleProjectiles = 0
        local cycleTime = 0
        local subCycleTime = 0
        for ri = 1, rackCount do
            local rack = racks[ri] or {}
            local muzzleBones = rack.MuzzleBones or {}
            local muzzleCount
            if (w.MuzzleSalvoDelay or 0) == 0 then
                muzzleCount = table.getn(muzzleBones)
            else
                muzzleCount = w.MuzzleSalvoSize or 1
            end
            if muzzleCount < 1 then muzzleCount = 1 end

            cycleProjectiles = cycleProjectiles + muzzleCount
            subCycleTime = subCycleTime + muzzleCount * perMuzzleDelay

            if not w.RackFireTogether and ri ~= rackCount then
                if cooldown <= subCycleTime + charge then
                    cycleTime = cycleTime + subCycleTime + charge
                        + math.max(0.1, cooldown - subCycleTime - charge)
                else
                    cycleTime = cycleTime + cooldown
                end
                subCycleTime = 0
            end
        end

        if cooldown <= subCycleTime + charge + reload then
            cycleTime = cycleTime + subCycleTime + charge + reload
                + math.max(0.1, cooldown - subCycleTime - charge - reload)
        else
            cycleTime = cycleTime + cooldown
        end

        return math.floor(dmg * cycleProjectiles / cycleTime + 0.5)
    end

    local function WeaponCounts(w)
        if not w then return false end
        if (w.Damage or 0) <= 0 then return false end
        local cat = w.WeaponCategory
        if cat == 'Death' or cat == 'Teleport' then return false end
        if w.DummyWeapon then return false end
        if w.DamageType == 'Overcharge' then return false end
        return true
    end

    -- Regular (non-commander) unit DPS: straight blueprint weapon sum.
    local function UnitWeaponDPS(unit)
        local bp = unit:GetBlueprint()
        if not bp.Weapon then return 0 end
        local total = 0
        for wi = 1, table.getn(bp.Weapon) do
            local w = bp.Weapon[wi]
            if WeaponCounts(w) then
                total = total + WeaponDPS(w)
            end
        end
        return total
    end

    -- Fixed DPS for commanders (no weapon iteration, ignores upgrades).
    local function CommanderDPS(unit)
        if unit:IsInCategory("COMMAND") then return 100 end
        -- SUBCOMMANDER base direct-fire DPS by faction
        if unit:IsInCategory("SERAPHIM") then return 400 end
        if unit:IsInCategory("NOMADS") then return 200 end
        return 300 -- UEF / Cybran / Aeon
    end

    -- Compute total DPS once per selection (fully static -> cached in S.dps).
    local function ComputeDPS(sel)
        local total = 0
        local count = sel and table.getn(sel) or 0
        for i = 1, count do
            local unit = sel[i]
            if unit ~= nil and not unit:IsDead() then
                if unit:IsInCategory("COMMAND") or unit:IsInCategory("SUBCOMMANDER") then
                    total = total + CommanderDPS(unit)
                else
                    total = total + UnitWeaponDPS(unit)
                end
            end
        end
        S.dps = total
    end

    -- ── Dynamic compute + set all value texts (DPS comes from cache) ──────
    -- HP/Shield computed only when their toggle is on, to keep per-tick cost
    -- low for large selections.
    local function UpdateValues(allowRelayout)
        local sel = S.sel
        local count = sel and table.getn(sel) or 0
        if count == 0 then return 0 end

        local doHP      = OPT.showHP()
        local doShield  = OPT.showShield()
        local doDPS     = OPT.showDPS()
        local doReclaim = OPT.showMassReclaimed()

        local massRate, energyRate = 0, 0
        local massCost, energyCost = 0, 0
        local totalbr = 0
        local totalMassKilled = 0
        local totalReclaimed = 0
        local totalHP = 0
        local totalShield = 0

        for i = 1, count do
            local unit = sel[i]
            if unit ~= nil and not unit:IsDead() then
                local econData = unit:GetEconData()
                local bp = unit:GetBlueprint()

                massRate   = massRate - econData["massRequested"] + econData["massProduced"]
                energyRate = energyRate - econData["energyRequested"] + econData["energyProduced"]

                if unit:IsInCategory("COMMAND") or unit:IsInCategory("SUBCOMMANDER") then
                    totalbr = totalbr + unit:GetBuildRate()
                    local enh = GetEnhancements(unit:GetEntityId())
                    if enh then
                        for _, ench in enh do
                            if not bp.CategoriesHash[ench] then
                                local eb = bp.Enhancements and bp.Enhancements[ench]
                                if eb then
                                    massCost   = massCost + (eb.BuildCostMass or 0)
                                    energyCost = energyCost + (eb.BuildCostEnergy or 0)
                                end
                            end
                        end
                    end
                elseif unit:IsInCategory("ENGINEER") or unit:IsInCategory("FACTORY") or unit:IsInCategory("SILO") then
                    totalbr = totalbr + (bp.Economy.BuildRate or 0)
                end

                if not unit:IsInCategory("COMMAND") then
                    massCost   = massCost + (bp.Economy.BuildCostMass or 0)
                    energyCost = energyCost + (bp.Economy.BuildCostEnergy or 0)
                end

                totalMassKilled = totalMassKilled + unit:GetStat('VetExperience', 0).Value

                if doReclaim then
                    totalReclaimed = totalReclaimed + (unit:GetStat('ReclaimedMass', 0).Value or 0)
                end

                if doHP then
                    totalHP = totalHP + (unit:GetHealth() or 0)
                end

                if doShield then
                    local sh = bp.Defense and bp.Defense.Shield
                    local maxsh = sh and sh.ShieldMaxHealth or 0
                    if maxsh > 0 then
                        local ratio = 0
                        pcall(function() ratio = unit:GetShieldRatio() end)
                        totalShield = totalShield + (ratio or 0) * maxsh
                    end
                end
            end
        end

        if massRate < 0 then
            SetTextAndRecord(W.valMass, string.format("%d", massRate), C.NEG)
        else
            SetTextAndRecord(W.valMass, string.format("+%d", massRate), C.MASS)
        end
        if energyRate < 0 then
            SetTextAndRecord(W.valEnergy, string.format("%d", energyRate), C.NEG)
        else
            SetTextAndRecord(W.valEnergy, string.format("+%d", energyRate), C.ENERGY)
        end

        SetTextAndRecord(W.valBuildpower, string.format("%d", totalbr), C.BUILD)
        SetTextAndRecord(W.valEnergyUsage, string.format("%d", energyCost), C.ENERGY)
        SetTextAndRecord(W.valMassUsage, string.format("%d", massCost), C.MASS)
        SetTextAndRecord(W.valMassKilled, string.format("%d", totalMassKilled), C.KILLED)
        SetTextAndRecord(W.valReclaimed, string.format("%d", totalReclaimed), C.RECLAIM)
        if doDPS then
            SetTextAndRecord(W.valDPS, string.format("%d", S.dps), C.DPS)
        end
        SetTextAndRecord(W.valHP, string.format("%d", totalHP), C.HP)
        SetTextAndRecord(W.valShield, string.format("%d", totalShield), C.SHIELD)

        local showMass = OPT.showMass()
        local showEnergy = OPT.showEnergy()
        local showBuildpower = OPT.showBuildpower()
        S.showColA = false
        if showMass and massRate ~= 0 then S.showColA = true end
        if showEnergy and energyRate ~= 0 then S.showColA = true end
        if showBuildpower and totalbr ~= 0 then S.showColA = true end

        -- The reclaim row only appears when the total is > 0. That total is
        -- computed here on the ticker, so when it crosses 0 mid-selection we
        -- need to relayout to add/remove the row (only then, not every tick).
        S.reclaimed = totalReclaimed
        if allowRelayout then
            local want = doReclaim and totalReclaimed > 0
            if want ~= S.reclaimShown then Layout() end
        end

        return count
    end

    -- ── Lay out one column (left-aligned headers + values); returns bottom y
    local function LayoutColumn(items, xLeft)
        local y = LV.TOP_PAD
        for i = 1, table.getn(items) do
            local it = items[i]
            it.ctrl:Show()
            LayoutHelpers.AtLeftTopIn(it.ctrl, S.panel, xLeft, y)
            if it.kind == 'h' then
                y = y + LV.HDR_H
            else
                y = y + LV.LINE_H
            end
        end
        return y
    end

    -- ── Visibility + positioning (reads options). Packs non-empty columns ──
    Layout = function()
        if not S.panel or IsDestroyed(S.panel) then return end

        -- Show panel FIRST: in FA, Show() on a parent re-shows its children,
        -- so child Hide() calls must come AFTER this to stick.
        S.panel:Show()

        W.hdrResources:Hide();
        W.hdrBuildpower:Hide();
        W.hdrCost:Hide();
        W.hdrKilled:Hide();
        W.hdrReclaimed:Hide();
        W.hdrCombat:Hide()
        W.valMass:Hide();
        W.valEnergy:Hide();
        W.valBuildpower:Hide()
        W.valEnergyUsage:Hide();
        W.valMassUsage:Hide();
        W.valMassKilled:Hide()
        W.valReclaimed:Hide();
        W.valDPS:Hide();
        W.valHP:Hide();
        W.valShield:Hide()

        local showCat = OPT.showCategories()

        -- Column A (left): Resources + Buildpower. Hide completely if active values are all zero.
        local colA = {}
        if S.showColA then
            if showCat and (OPT.showMass() or OPT.showEnergy()) then table.insert(colA,
                    { kind = 'h', ctrl = W.hdrResources })
            end
            if OPT.showMass() then table.insert(colA, { kind = 'v', ctrl = W.valMass }) end
            if OPT.showEnergy() then table.insert(colA, { kind = 'v', ctrl = W.valEnergy }) end
            if showCat and OPT.showBuildpower() then table.insert(colA, { kind = 'h', ctrl = W.hdrBuildpower }) end
            if OPT.showBuildpower() then table.insert(colA, { kind = 'v', ctrl = W.valBuildpower }) end
        end

        -- Column B (middle): Cost, then Mass killed
        local colB = {}
        if showCat and (OPT.showEnergyUsage() or OPT.showMassUsage()) then table.insert(colB,
                { kind = 'h', ctrl = W.hdrCost })
        end
        if OPT.showMassUsage() then table.insert(colB, { kind = 'v', ctrl = W.valMassUsage }) end
        if OPT.showEnergyUsage() then table.insert(colB, { kind = 'v', ctrl = W.valEnergyUsage }) end
        if showCat and OPT.showMassKilled() then table.insert(colB, { kind = 'h', ctrl = W.hdrKilled }) end
        if OPT.showMassKilled() then table.insert(colB, { kind = 'v', ctrl = W.valMassKilled }) end

        -- Column C (combat stats)
        local colC = {}
        if showCat and (OPT.showDPS() or OPT.showHP() or OPT.showShield()) then table.insert(colC,
                { kind = 'h', ctrl = W.hdrCombat })
        end
        if OPT.showDPS() then table.insert(colC, { kind = 'v', ctrl = W.valDPS }) end
        if OPT.showHP() then table.insert(colC, { kind = 'v', ctrl = W.valHP }) end
        if OPT.showShield() then table.insert(colC, { kind = 'v', ctrl = W.valShield }) end

        -- Column D (Mass reclaimed): its own column, always the last one, and
        -- only present when the selection's total reclaimed mass is > 0.
        local colD = {}
        local showReclaim = OPT.showMassReclaimed() and S.reclaimed > 0
        S.reclaimShown = showReclaim
        if showCat and showReclaim then table.insert(colD, { kind = 'h', ctrl = W.hdrReclaimed }) end
        if showReclaim then table.insert(colD, { kind = 'v', ctrl = W.valReclaimed }) end

        -- Pack non-empty columns left-to-right
        local cols = { colA, colB, colC, colD }
        local visible = {}
        for c = 1, 4 do
            if table.getn(cols[c]) > 0 then table.insert(visible, cols[c]) end
        end

        local nCols = table.getn(visible)
        if nCols == 0 then
            S.panel:Hide()
            return
        end

        -- Compute per-column widths from the widest string in each column
        local maxH = 0
        local colWidths = {}
        for ci = 1, nCols do
            local maxW = 0
            for ii = 1, table.getn(visible[ci]) do
                local it = visible[ci][ii]
                local txt = tostring((it.ctrl and it.ctrl._text) or "")
                local charW = (it.kind == 'h') and LV.CHAR_W_HDR or LV.CHAR_W_NUM
                local w = string.len(txt) * charW
                if w > maxW then maxW = w end
            end
            -- add padding inside column and a small inter-column gap; cap width
            local proposed = math.ceil(maxW + 12)
            colWidths[ci] = math.min(LV.COL_CONTENT, math.max(24, proposed))
        end

        -- Layout columns left-to-right using computed widths
        local curX = LV.COL_LEFT
        for ci = 1, nCols do
            local h = LayoutColumn(visible[ci], curX)
            if h > maxH then maxH = h end
            curX = curX + colWidths[ci]
        end

        local w = curX + 6
        S.panel.Width:Set(LayoutHelpers.ScaleNumber(w))
        S.panel.Height:Set(LayoutHelpers.ScaleNumber(maxH + LV.BOT_PAD))
    end

    -- Full refresh: recompute dynamic values + relayout (selection/option change)
    local function FullRefresh()
        local count = UpdateValues(false)
        if count == 0 then
            S.count = 0
            if S.panel and not IsDestroyed(S.panel) then S.panel:Hide() end
            return
        end
        S.count = count
        Layout()
    end

    -- Selection changed: recompute static DPS once, then full refresh
    local function OnSelection(sel)
        S.sel = sel
        local count = sel and table.getn(sel) or 0
        if count == 0 then
            S.count = 0
            if S.panel and not IsDestroyed(S.panel) then S.panel:Hide() end
            return
        end
        ComputeDPS(sel)
        FullRefresh()
    end

    -- ── Build the panel once the UI exists ────────────────────────────────
    ReUI.Core.OnPostCreateUI(function()
        local parent = GameMain.GetStatusCluster()

        S.panel = Bitmap(parent)
        S.panel:SetSolidColor("770a0c10") -- subtle, ~47% opaque
        local px, py = LoadPos()
        S.panel.Left:Set(LayoutHelpers.ScaleNumber(px))
        S.panel.Top:Set(LayoutHelpers.ScaleNumber(py))
        LayoutHelpers.SetDimensions(S.panel, K.COL_LEFT + K.COL_W + K.COL_CONTENT, 60)
        LayoutHelpers.DepthOverParent(S.panel, parent, 500)
        S.panel:Hide()

        local function MkHdr(text)
            local t = UIUtil.CreateText(S.panel, text, K.HDR_SIZE, K.FONT, true)
            t:SetColor(C.HEADER);
            t:DisableHitTest(true)
            t._text = tostring(text or "")
            return t
        end

        local function MkVal(color)
            local t = UIUtil.CreateText(S.panel, "0", K.NUM_SIZE, K.FONT, true)
            t:SetColor(color);
            t:DisableHitTest(true)
            t._text = "0"
            return t
        end

        W.hdrResources  = MkHdr("Resources")
        W.hdrBuildpower = MkHdr("Buildpower")
        W.hdrCost       = MkHdr("Cost")
        W.hdrKilled     = MkHdr("Mass killed")
        W.hdrReclaimed  = MkHdr("Mass reclaimed")
        W.hdrCombat     = MkHdr("Combat stats")

        W.valMass        = MkVal(C.MASS)
        W.valEnergy      = MkVal(C.ENERGY)
        W.valBuildpower  = MkVal(C.BUILD)
        W.valEnergyUsage = MkVal(C.ENERGY)
        W.valMassUsage   = MkVal(C.MASS)
        W.valMassKilled  = MkVal(C.KILLED)
        W.valReclaimed   = MkVal(C.RECLAIM)
        W.valDPS         = MkVal(C.DPS)
        W.valHP          = MkVal(C.HP)
        W.valShield      = MkVal(C.SHIELD)

        -- Apply the saved font scale to the freshly-created controls.
        Rescale()

        -- Middle-mouse 2D drag + persistence
        S.panel.HandleEvent = function(self, event)
            if event.Type == 'ButtonPress' and event.Modifiers.Middle then
                local drag = Dragger()
                local offX = event.MouseX - self.Left()
                local offY = event.MouseY - self.Top()
                drag.OnMove = function(_, x, y)
                    self.Left:Set(x - offX)
                    self.Top:Set(y - offY)
                    GetCursor():SetTexture(UIUtil.GetCursor('MOVE_WINDOW'))
                end
                drag.OnRelease = function(_)
                    SavePos()
                    GetCursor():Reset()
                    drag:Destroy()
                end
                PostDragger(self:GetRootFrame(), event.KeyCode, drag)
                return true
            end
            return false
        end

        -- React to option changes (relayout + refresh; DPS stays cached)
        local function onChange()
            if not S.built then return end
            FullRefresh()
        end

        -- ── ReUI.Options compatibility shim (old :Bind + new OnChanged event) ──
        -- ReUI 1.3.0 ships ReUI.Options 2.0.0, which replaces opt:Bind(fn) with
        -- the event opt.OnChanged:Add(fn). The old :Bind still exists in 1.3.0 but
        -- is deprecated and slated for removal. This wrapper uses whichever API is
        -- present, so the mod runs on both old and new ReUI.
        local function BindOption(opt, fn)
            local onChanged
            local ok = pcall(function() onChanged = opt.OnChanged end)
            if ok and type(onChanged) == 'table' and type(onChanged.Add) == 'function' then
                fn(opt)
                onChanged:Add(function(o) fn(o) end)
            else
                opt:Bind(fn)
            end
        end

        BindOption(OPT.showCategories, function() onChange() end)
        BindOption(OPT.showMass, function() onChange() end)
        BindOption(OPT.showEnergy, function() onChange() end)
        BindOption(OPT.showBuildpower, function() onChange() end)
        BindOption(OPT.showEnergyUsage, function() onChange() end)
        BindOption(OPT.showMassUsage, function() onChange() end)
        BindOption(OPT.showMassKilled, function() onChange() end)
        BindOption(OPT.showMassReclaimed, function() onChange() end)
        BindOption(OPT.showDPS, function() onChange() end)
        BindOption(OPT.showHP, function() onChange() end)
        BindOption(OPT.showShield, function() onChange() end)
        BindOption(OPT.fontScale, function()
            if not S.built then return end
            Rescale()
            FullRefresh()
        end)

        S.built = true
        FullRefresh()

        -- Instant update on selection change (recomputes static DPS; empty -> hide)
        ObserveSelection:AddObserver(function(info)
            OnSelection(info.newSelection)
        end, "DynamicSelectionInfo")

        -- Live refresh of dynamic values while selected; idle when none.
        -- No relayout and no DPS recompute here.
        local ticker = Bitmap(parent)
        ticker:SetAlpha(0)
        ticker:DisableHitTest()
        ticker:SetNeedsFrameUpdate(true)
        local acc = 0
        ticker.OnFrame = function(_, delta)
            if S.count == 0 then return end
            acc = acc + delta
            if acc >= 0.5 then
                acc = 0
                UpdateValues(true)
            end
        end
    end)
end
