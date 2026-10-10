-- CooldownFlash: when you press an action button whose spell/item is on cooldown,
-- flash its icon, name and remaining time on screen for a short while.
--
-- Midnight (12.0+): cooldown numbers are "secret" in combat, so we never read them.
-- We only use NeverSecret flags (isActive / isOnGCD) to decide whether to flash, and
-- hand the action's DurationObject to a Cooldown widget, which renders the countdown.

local ADDON = ...
local DEFAULTS = {
    iconSize = 64,      -- icon width/height in pixels
    fontSize = 24,      -- countdown number size
    secondsOnly = true,  -- show 75 instead of 1:15 style countdowns
    x = 0, y = -80,        -- offset from screen centre
    duration = 1,       -- seconds the flash stays up
    minCooldown = 15,   -- only flash abilities whose cooldown is longer than this (seconds)
}

local db
local probing = false  -- /cdf probe
local debug = false    -- /cdf debug
local frame, icon, cd, mask, overlay
local countdownFont = CreateFont("CooldownFlashCountdownFont")

local function Print(...) print("|cff33ccffCooldownFlash:|r", ...) end

---------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------
-- Seconds only: a NumericRuleFormatter with one rule that rounds up to whole seconds and
-- prints the bare number ("75", not "1:15" or "75s"). The result is checked with a
-- readable test value; if it doesn't produce a plain number we report it and keep
-- Blizzard's default format. Never allowed to error.
local secondsFormatter
local function BuildSecondsFormatter()
    for _, fmt in ipairs({ "%d", "%.0f" }) do
        local f = C_StringUtil.CreateNumericRuleFormatter()
        f:SetBreakpoints({ {
            threshold = 0,
            step = 1,
            rounding = Enum.NumericRuleFormatRounding.Up,
            format = fmt,
        } })
        local out = f:FormatNumber(75.4)
        if type(out) == "string" and out:match("^%d+$") then return f end
    end
end

local function ApplyCountdownFormat()
    local ok, err = pcall(function()
        if db.secondsOnly then
            secondsFormatter = secondsFormatter or BuildSecondsFormatter()
            if not secondsFormatter then error("no formatter produced a plain number") end
            cd:SetCountdownFormatter(secondsFormatter)
        else
            cd:SetCountdownFormatter(nil)
        end
    end)
    if not ok then Print("could not change countdown format: " .. tostring(err)) end
end

local function ApplyLayout()
    local box = db.iconSize   -- icon is a square, countdown number sits in its middle
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", db.x, db.y)
    frame:SetSize(box, box)
    icon:ClearAllPoints()
    icon:SetAllPoints(frame)
    cd:ClearAllPoints()
    cd:SetAllPoints(frame)
    if overlay then
        -- Blizzard's cooldown manager draws its shadow overlay 6px/5px larger than a 30px icon
        overlay:ClearAllPoints()
        overlay:SetPoint("TOPLEFT", frame, "TOPLEFT", -box * 0.2, box * (5 / 30))
        overlay:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", box * 0.2, -box * (5 / 30))
    end
    countdownFont:SetFont(STANDARD_TEXT_FONT, db.fontSize, "OUTLINE")
    ApplyCountdownFormat()
end

local shownUntil

-- setCooldown(cd) fills the Cooldown widget (duration object, or plain numbers for tests)
local function Flash(iconTexture, setCooldown)
    icon:SetTexture(iconTexture)
    setCooldown(cd)
    shownUntil = GetTime() + db.duration
    frame:SetAlpha(1)
    frame:Show()
end

local function BuildFrame()
    frame = CreateFrame("Frame", "CooldownFlashFrame", UIParent)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:Hide()
    icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    -- Same look as Blizzard's Cooldown Manager icons (Blizzard_CooldownViewer/CooldownViewer.xml):
    -- rounded mask on the icon plus a shadow overlay that fades out around and into the icon.
    -- Atlases are checked so a missing one degrades to the plain icon instead of a green box.
    if C_Texture.GetAtlasInfo("UI-HUD-CoolDownManager-Mask") then
        mask = frame:CreateMaskTexture()
        mask:SetAtlas("UI-HUD-CoolDownManager-Mask")
        mask:SetAllPoints(icon)
        icon:AddMaskTexture(mask)
    end
    if C_Texture.GetAtlasInfo("UI-HUD-CoolDownManager-IconOverlay") then
        overlay = frame:CreateTexture(nil, "OVERLAY")
        overlay:SetAtlas("UI-HUD-CoolDownManager-IconOverlay")
    end
    cd = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
    cd:SetDrawSwipe(false)
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)
    cd:SetHideCountdownNumbers(false)
    cd:SetCountdownFont("CooldownFlashCountdownFont")

    frame:SetScript("OnUpdate", function(self)
        if self.moving then return end
        local left = shownUntil - GetTime()
        if left <= 0 then self:Hide() return end
        if left < 0.25 then self:SetAlpha(left / 0.25) end -- fade out
    end)

    -- dragging (only while /cdf unlock is active)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) if self.unlocked then self.moving = true self:StartMoving() end end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self.moving = false
        local cx, cy = UIParent:GetCenter()
        local fx, fy = self:GetCenter()
        db.x, db.y = math.floor(fx - cx + 0.5), math.floor(fy - cy + 0.5)
        ApplyLayout()
        Print(("position saved: %d, %d"):format(db.x, db.y))
    end)
end

---------------------------------------------------------------------------
-- Detect the pressed ability and its cooldown
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Ability cooldown length (for the minimum-cooldown filter)
--
-- GetSpellBaseCooldown is unreliable (wrong for talent/category/charge cooldowns),
-- and live cooldown numbers are secret in combat. The spell tooltip's "1.3 min
-- cooldown" / "8.9 sec recharge" line is readable out of combat, so we parse that
-- (using Blizzard's localized format strings) and cache it per spell.
---------------------------------------------------------------------------
local cdCache = {}   -- spellID -> seconds
local patterns

local function BuildPatterns()
    patterns = {}
    local function add(fmt, mult)
        if type(fmt) ~= "string" then return end
        local p = fmt:gsub("%%%d?%$?s", "\1"):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        p = p:gsub("\1", function() return "([%d%.,]+)" end)
        patterns[#patterns + 1] = { p, mult }
    end
    add(SPELL_RECAST_TIME_SEC, 1)
    add(SPELL_RECAST_TIME_MIN, 60)
    add(SPELL_RECAST_TIME_CHARGES_SEC, 1)
    add(SPELL_RECAST_TIME_CHARGES_MIN, 60)
end

local function TooltipCooldown(spell)
    if not patterns then BuildPatterns() end
    local data = C_TooltipInfo and C_TooltipInfo.GetSpellByID(spell)
    if not data or not data.lines then return end   -- no data: unknown
    for _, line in ipairs(data.lines) do
        for _, text in ipairs({ line.leftText or "", line.rightText or "" }) do
            if not issecretvalue(text) then
                for _, pm in ipairs(patterns) do
                    local num = text:match(pm[1])
                    if num then
                        num = tonumber((num:gsub(",", ".")))
                        if num then return num * pm[2] end
                    end
                end
                -- Fallback that doesn't depend on the global format strings:
                -- "1.3 min cooldown", "8.9 sec recharge", "2 hr cooldown"
                local lower = text:lower()
                if lower:find("cooldown") or lower:find("recharge") then
                    local num, unit = lower:match("([%d%.,]+)%s*(%a+)")
                    num = num and tonumber((num:gsub(",", ".")))
                    if num then
                        if unit:find("^min") then return num * 60
                        elseif unit:find("^h") then return num * 3600
                        elseif unit:find("^s") then return num end
                    end
                end
            end
        end
    end
    return false   -- tooltip readable but has no cooldown line: no cooldown
end

-- Fallback: live values, only readable outside restrictions.
local function LiveCooldown(spell)
    local info = C_Spell.GetSpellCooldown(spell)
    local d = info and info.duration
    if d and not issecretvalue(d) and not info.isOnGCD and d > 0 then return d end
    local ch = C_Spell.GetSpellCharges(spell)
    d = ch and ch.cooldownDuration
    if d and not issecretvalue(d) and d > 0 then return d end
end

local function SpellForSlot(slot)
    local kind, id = GetActionInfo(slot)
    if kind == "spell" then return id end
    if kind == "macro" then
        -- GetMacroSpell misses some macros (conditionals, castsequence); ask the action slot too
        return GetMacroSpell(id) or (C_ActionBar.GetSpell and C_ActionBar.GetSpell(slot)) or nil
    end
    if kind == "item" then
        local _, spell = (C_Item and C_Item.GetItemSpell or GetItemSpell)(id)
        return spell
    end
end

-- Returns seconds (nil if unknown) and where it came from.
local function CooldownLength(spell)
    local secs = TooltipCooldown(spell)
    if secs then cdCache[spell] = secs return secs, "tooltip" end
    if secs == false then
        -- In combat the tooltip can lose its cooldown line, so trust an earlier value.
        if cdCache[spell] then return cdCache[spell], "cache" end
        if not InCombatLockdown() then
            return 0, "tooltip (no cooldown line)"   -- deliberately not cached
        end
        return nil, "unknown (no tooltip line, in combat)"
    end
    secs = LiveCooldown(spell)
    if secs then cdCache[spell] = secs return secs, "live" end
    if cdCache[spell] then return cdCache[spell], "cache" end
end

-- Pre-fill the cache for everything on the bars, while out of combat.
local scanQueued
local function ScanBars()
    scanQueued = false
    if InCombatLockdown() then return end
    for slot = 1, 180 do
        local ok, spell = pcall(SpellForSlot, slot)
        if ok and spell then pcall(CooldownLength, spell) end
    end
end
local function QueueScan()
    if scanQueued then return end
    scanQueued = true
    C_Timer.After(1, ScanBars)
    C_Timer.After(6, ScanBars)    -- tooltip data can still be loading at login
end

local function Dbg(...) if debug then Print(...) end end

local function SlotLabel(slot)
    local kind, id = GetActionInfo(slot)
    if kind == "macro" then
        local name, _, body = GetMacroInfo(id)
        local first = body and body:match("[^\n]*") or ""
        return ("macro '%s' [%s]"):format(tostring(name), first)
    end
    return tostring(kind)
end

local function OnUseAction(slot)
    if not db then return end
    -- isActive / isOnGCD are NeverSecret, so these checks are safe in combat.
    local ok, info = pcall(C_ActionBar.GetActionCooldown, slot)
    if not ok or not info or not info.isActive or info.isOnGCD then
        if debug and ok and info then
            Print(("slot %d (%s): skipped, isActive=%s isOnGCD=%s"):format(slot, SlotLabel(slot),
                tostring(info.isActive), tostring(info.isOnGCD)))
        end
        return
    end

    -- Minimum cooldown filter. Known-short cooldowns are ignored, leaving the current
    -- display untouched.
    local okS, spell = pcall(SpellForSlot, slot)
    if okS and spell then
        local okC, secs, src = pcall(CooldownLength, spell)
        Dbg(("slot %d (%s) spell %s: cooldown %s (%s), min %s"):format(slot, SlotLabel(slot), tostring(spell),
            okC and tostring(secs) or ("ERROR " .. tostring(secs)), tostring(src), db.minCooldown))
        -- Only hide what we positively know is short; unknown cooldowns still show.
        if okC and secs and secs <= db.minCooldown then return end
    else
        -- Can't map this action to a spell (e.g. a macro): can't filter it, so show it as before.
        Dbg(("slot %d (%s): no spell resolved, showing unfiltered"):format(slot, SlotLabel(slot)))
    end

    local tex = GetActionTexture(slot)
    if not tex then return end
    pcall(Flash, tex, function(c)
        -- second arg (12.0.5+) excludes the GCD from the duration
        c:SetCooldownFromDurationObject(C_ActionBar.GetActionCooldownDuration(slot, true))
    end)
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function Help()
    Print("commands (/cdf or /cooldownflash):")
    print("  size <16-256>     icon size (now " .. db.iconSize .. ")")
    print("  font <8-120>      countdown number size (now " .. db.fontSize .. ")")
    print("  seconds           toggle seconds-only countdown, e.g. 75 instead of 1:15 (now " .. tostring(db.secondsOnly) .. ")")
    print("  pos <x> <y>       offset from screen centre (now " .. db.x .. ", " .. db.y .. ")")
    print("  unlock / lock     drag the display with the mouse")
    print("  min <seconds>     only show abilities with a longer cooldown (now " .. db.minCooldown .. ")")
    print("  cache             list cached ability cooldowns")
    print("  debug             toggle filter debug output (now " .. tostring(debug) .. ")")
    print("  time <seconds>    how long it stays up (now " .. db.duration .. ")")
    print("  probe             toggle base-cooldown probe output (now " .. tostring(probing) .. ")")
    print("  test              show a sample flash")
    print("  reset             restore defaults")
end

local function Test()
    Flash(134400, function(c) c:SetCooldown(GetTime(), 12.3) end)
end

SLASH_COOLDOWNFLASH1 = "/cdf"
SLASH_COOLDOWNFLASH2 = "/cooldownflash"
SlashCmdList.COOLDOWNFLASH = function(input)
    local cmd, a, b = strsplit(" ", strtrim(input):lower(), 3)
    if cmd == "size" and tonumber(a) then
        db.iconSize = math.max(16, math.min(256, tonumber(a)))
        ApplyLayout(); Test()
    elseif cmd == "font" and tonumber(a) then
        db.fontSize = math.max(8, math.min(120, tonumber(a)))
        ApplyLayout(); Test()
    elseif cmd == "seconds" then
        db.secondsOnly = not db.secondsOnly
        ApplyLayout(); Test()
        Print("seconds-only countdown " .. (db.secondsOnly and "on" or "off"))
    elseif cmd == "pos" and tonumber(a) and tonumber(b) then
        db.x, db.y = tonumber(a), tonumber(b)
        ApplyLayout(); Test()
    elseif cmd == "time" and tonumber(a) then
        db.duration = math.max(0.2, math.min(10, tonumber(a)))
        Print("duration " .. db.duration .. "s"); Test()
    elseif cmd == "min" and tonumber(a) then
        db.minCooldown = math.max(0, tonumber(a))
        Print("minimum cooldown " .. db.minCooldown .. "s")
    elseif cmd == "cache" then
        local n = 0
        for spell, secs in pairs(cdCache) do
            local si = C_Spell.GetSpellInfo(spell)
            print(("  %s (%d): %ss"):format(si and si.name or "?", spell, tostring(secs)))
            n = n + 1
        end
        Print(n .. " spells cached, " .. (patterns and #patterns or 0) .. " tooltip patterns built")
    elseif cmd == "debug" then
        debug = not debug
        Print("debug " .. (debug and "on" or "off"))
    elseif cmd == "probe" then
        probing = not probing
        Print("probe " .. (probing and "on: press abilities, in and out of combat" or "off"))
    elseif cmd == "unlock" then
        frame.unlocked = true
        frame:EnableMouse(true)
        Flash(134400, function(c) c:SetCooldown(GetTime(), 99) end)
        shownUntil = math.huge
        Print("drag the display, then /cdf lock")
    elseif cmd == "lock" then
        frame.unlocked = false
        frame:EnableMouse(false)
        shownUntil = 0
        Print("locked")
    elseif cmd == "test" then
        Test()
    elseif cmd == "reset" then
        for k, v in pairs(DEFAULTS) do db[k] = v end
        ApplyLayout(); Test()
    else
        Help()
    end
end

---------------------------------------------------------------------------
-- Probe (/cdf probe): report every way we can think of to get a spell's base
-- cooldown, so we can see which ones work in combat. Fully separate from the
-- flash path: its own hook, everything pcall'd, only runs while enabled.
---------------------------------------------------------------------------
local function V(v)  -- format a value, flagging secrets (check secrecy before any comparison)
    local okS, secret = pcall(issecretvalue, v)
    if okS and secret then return "<SECRET>" end
    if v == nil then return "nil" end
    return tostring(v)
end

local function P(label, fn, ...)
    local r = { pcall(fn, ...) }
    local n = select("#", unpack(r))
    if not r[1] then return print(("  %-36s ERROR %s"):format(label, tostring(r[2]))) end
    local out = {}
    for i = 2, n do out[#out + 1] = V(r[i]) end
    print(("  %-36s %s"):format(label, #out > 0 and table.concat(out, ", ") or "(no return)"))
end

local reportedMethods
local function Probe(slot)
    local kind, id = GetActionInfo(slot)
    local spell = id
    if kind == "macro" then spell = GetMacroSpell(id) end
    print(("|cff33ccffCDF probe:|r slot %d kind=%s id=%s spell=%s inCombat=%s"):format(
        slot, tostring(kind), tostring(id), tostring(spell), tostring(InCombatLockdown())))
    if not spell then return end

    -- 1. legacy global API
    P("GetSpellBaseCooldown (ms,gcd)", GetSpellBaseCooldown, spell)
    -- 2. possible C_Spell equivalents (may not exist)
    if C_Spell and C_Spell.GetSpellBaseCooldown then
        P("C_Spell.GetSpellBaseCooldown", C_Spell.GetSpellBaseCooldown, spell)
    else
        print("  C_Spell.GetSpellBaseCooldown       (does not exist)")
    end
    -- 3. live cooldown structs: duration is the *modified* cooldown, but may be readable
    P("C_Spell.GetSpellCooldown.duration", function() return C_Spell.GetSpellCooldown(spell).duration end)
    P("C_ActionBar.GetActionCooldown.duration", function() return C_ActionBar.GetActionCooldown(slot).duration end)
    -- 4. charges (charge spells expose the full recharge time)
    P("C_Spell.GetSpellCharges cdDuration", function()
        local c = C_Spell.GetSpellCharges(spell); return c and c.cooldownDuration end)
    -- 5. secrecy flags
    if C_Secrets then
        P("Secrecy.GetSpellCooldownSecrecy", C_Secrets.GetSpellCooldownSecrecy, spell)
        P("Secrecy.ShouldSpellCooldownBeSecret", C_Secrets.ShouldSpellCooldownBeSecret, spell)
        P("Secrecy.ShouldActionCooldownBeSecret", C_Secrets.ShouldActionCooldownBeSecret, slot)
    end
    -- 6. duration object: list its methods once, then query the useful-looking ones
    local okD, dur = pcall(C_ActionBar.GetActionCooldownDuration, slot, true)
    if okD and dur then
        local mt = getmetatable(dur)
        local idx = mt and mt.__index
        if not reportedMethods and type(idx) == "table" then
            local names = {}
            for k in pairs(idx) do names[#names + 1] = tostring(k) end
            table.sort(names)
            print("  DurationObject methods: " .. table.concat(names, ", "))
            reportedMethods = true
        end
        for _, m in ipairs({ "GetTotalDuration", "GetRemainingDuration", "GetElapsedDuration",
                             "EvaluateRemainingDuration", "GetStartTime", "GetEndTime" }) do
            if type(dur[m]) == "function" then
                P("DurationObject:" .. m, function() return dur[m](dur) end)
            end
        end
    else
        print("  GetActionCooldownDuration          " .. V(dur))
    end
    -- 7. tooltip text ("15 sec cooldown") - static data, may survive combat
    P("Tooltip cooldown line", function()
        local d = C_TooltipInfo.GetSpellByID(spell)
        if not d then return nil end
        for _, line in ipairs(d.lines or {}) do
            local t = line.leftText or line.rightText
            if t and not issecretvalue(t) and t:lower():find("cooldown") then return t end
            t = line.rightText
            if t and not issecretvalue(t) and t:lower():find("cooldown") then return t end
        end
        return "(no cooldown line)"
    end)
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    CooldownFlashDB = CooldownFlashDB or {}
    db = CooldownFlashDB
    if db.size then   -- pre-1.4: one size, icon was twice the font size
        db.fontSize, db.iconSize, db.size = db.size, db.size * 2, nil
    end
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    BuildFrame()
    ApplyLayout()
    hooksecurefunc("UseAction", OnUseAction)
    for _, ev in ipairs({ "PLAYER_ENTERING_WORLD", "ACTIONBAR_SLOT_CHANGED", "PLAYER_REGEN_ENABLED",
                          "SPELLS_CHANGED", "TRAIT_CONFIG_UPDATED" }) do
        pcall(loader.RegisterEvent, loader, ev)
    end
    loader:SetScript("OnEvent", QueueScan)
    hooksecurefunc("UseAction", function(slot)
        if probing then
            local ok, err = pcall(Probe, slot)
            if not ok then Print("probe error: " .. tostring(err)) end
        end
    end)
end)
