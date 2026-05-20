-- DeathReplay_GUI — main replay window controller.

DeathReplay_GUI = {}

-- Public table read by XML <ListData table="DeathReplay_GUI.Listdata"...>. Each
-- entry is one HIT row: wstring columns for the engine's auto-fill
-- (Time/Name/Amount/Flags) plus hidden helpers (_dt/_amount) used by the sort
-- comparator.
DeathReplay_GUI.Listdata = {}

-- Maps visible row index -> Listdata index. Rebuilt by sortListdata() and
-- handed to ListBoxSetDisplayOrder; engine then exposes it as
-- _G["DeathReplay_GUITimeline"].PopulatorIndices when populationfunction fires.
local displayOrder = {}

-- Diagnostic helper: wrap entry points in pcall + trace for silent error detection.
local function dr_safe(fn_name, fn)
    return function(...)
        if DeathReplay.IsDebug() then
            EA_ChatWindow.Print(L"DR_TRACE " .. towstring(fn_name))
        end
        local ok, err = pcall(fn, ...)
        if not ok and DeathReplay.IsDebug() then
            EA_ChatWindow.Print(L"DR_ERR " .. towstring(fn_name) .. L": " .. towstring(tostring(err)))
        end
    end
end

local state = {
    visible       = false,
    currentIndex  = 1,
    sortColumn    = "Time",   -- "Time" | "Amount"
    sortDirection = "desc",   -- "asc" | "desc"
}

local function deaths()
    return DeathReplay_SavedVariables and DeathReplay_SavedVariables.deaths or {}
end

-- abilityId=0 means melee auto-attack (no ability id from engine).
local function abilityDisplayName(ability, abilityId)
    if ability ~= nil and ability ~= L"" then return ability end
    if (abilityId or 0) == 0 then return L"Melee" end
    return L"Ability #" .. towstring(abilityId)
end

local function sortListdata()
    displayOrder = {}
    for i = 1, #DeathReplay_GUI.Listdata do
        displayOrder[i] = i
    end
    local col = state.sortColumn
    local desc = (state.sortDirection == "desc")
    local data = DeathReplay_GUI.Listdata
    table.sort(displayOrder, function(a, b)
        local ra, rb = data[a], data[b]
        if col == "Amount" then
            if ra._amount ~= rb._amount then
                if desc then return ra._amount > rb._amount end
                return ra._amount < rb._amount
            end
            -- tie-break newest-first
            return ra._dt > rb._dt
        else
            if desc then return ra._dt > rb._dt end
            return ra._dt < rb._dt
        end
    end)
end

local function populateTimeline(d)
    DeathReplay_GUI.Listdata = {}
    displayOrder = {}
    if d == nil then return end
    for i = 1, #d.events do
        local e = d.events[i]
        if e.kind == "HIT" then
            -- %7.3f keeps millisecond precision and a consistent column width
            -- for "-10.000" through "  0.000" (GetGameTime returns seconds).
            local dtText = towstring(string.format("%7.3fs", e.dt))
            -- Leading space separates the flag text from the right-aligned
            -- Amount column that visually butts up against the Flags column.
            local flags = L""
            if e.crit then flags = L" CRIT" end
            if e.killingBlow then
                if flags == L"" then flags = L" *KB*"
                else flags = flags .. L" *KB*" end
            end
            table.insert(DeathReplay_GUI.Listdata, {
                Time     = dtText,
                Name     = abilityDisplayName(e.ability, e.abilityId),
                Amount   = towstring(e.amount or 0),
                Flags    = flags,
                _dt      = e.dt or 0,
                _amount  = e.amount or 0,
                _iconNum = e.iconNum,   -- captured at hit-time; nil for cache misses / pre-feature deaths
            })
        end
    end
    sortListdata()
    ListBoxSetDisplayOrder("DeathReplay_GUITimeline", displayOrder)
end

function DeathReplay_GUI.OnRowPopulated()
    local list = _G["DeathReplay_GUITimeline"]
    if list == nil or list.PopulatorIndices == nil then return end
    for k, dataIndex in ipairs(list.PopulatorIndices) do
        local row = DeathReplay_GUI.Listdata[dataIndex]
        if row ~= nil then
            local rowName = "DeathReplay_GUITimelineRow" .. k
            LabelSetTextColor(rowName .. "Time",   220, 220, 220)
            LabelSetTextColor(rowName .. "Name",   255, 255, 255)
            LabelSetTextColor(rowName .. "Amount", 255,  80,  80)
            LabelSetTextColor(rowName .. "Flags",  255, 220,  80)

            -- Icon column: render only if we captured an iconNum at hit-time
            -- (via DeathReplay.lua's GetBuffs(SELF) harvest). Otherwise hide the
            -- slot so recycled rows don't show a stale texture from another row.
            local iconName = rowName .. "Icon"
            local iconNum = row._iconNum
            if iconNum and iconNum > 0 then
                local tex, ix, iy = GetIconData(iconNum)
                if tex and tex ~= "" and tex ~= "icon000000" then
                    DynamicImageSetTextureDimensions(iconName, ix, iy)
                    DynamicImageSetTexture(iconName, tex, ix, iy)
                    -- Source ability-icon sheet is 64x64; our slot is 22x22.
                    if ix and ix > 0 then
                        local s = 22 / ix
                        DynamicImageSetTextureScale(iconName, s, s)
                    end
                    WindowSetShowing(iconName, true)
                else
                    WindowSetShowing(iconName, false)
                end
            else
                WindowSetShowing(iconName, false)
            end
        end
    end
end

local function arrowFor(col)
    if state.sortColumn ~= col then return L"" end
    if state.sortDirection == "desc" then return L" v" end
    return L" ^"
end

function DeathReplay_GUI.Render()
    local list = deaths()
    DeathReplay.DebugPrint(L"DR_DEBUG Render: deaths=" .. towstring(#list))
    if #list == 0 then
        LabelSetText("DeathReplay_GUITitleBarText", L"DeathReplay")
        LabelSetText("DeathReplay_GUINavLabel", L"")
        LabelSetTextColor("DeathReplay_GUINavLabel", 255, 255, 255)
        LabelSetText("DeathReplay_GUIEmptyHint",
            L"No deaths captured yet. Die in a scenario or RvR zone to capture your first replay.")
        LabelSetTextColor("DeathReplay_GUIEmptyHint", 255, 255, 255)
        WindowSetShowing("DeathReplay_GUITimeline", false)
        WindowSetShowing("DeathReplay_GUIEmptyHint", true)
        WindowSetShowing("DeathReplay_GUISortTime", false)
        WindowSetShowing("DeathReplay_GUIHeaderAbility", false)
        WindowSetShowing("DeathReplay_GUISortDmg",  false)
        return
    end
    if state.currentIndex < 1 then state.currentIndex = 1 end
    if state.currentIndex > #list then state.currentIndex = #list end
    local d = list[state.currentIndex]
    local kbName = L"unknown"
    if d.killingBlow then
        kbName = abilityDisplayName(d.killingBlow.ability, d.killingBlow.abilityId)
    end

    LabelSetText("DeathReplay_GUITitleBarText",
        L"DeathReplay   " .. towstring(state.currentIndex) .. L"/" .. towstring(#list))

    LabelSetText("DeathReplay_GUINavLabel", (d.zone or L"?") .. L"  -  killed by " .. kbName)
    LabelSetTextColor("DeathReplay_GUINavLabel", 255, 255, 255)

    WindowSetShowing("DeathReplay_GUIEmptyHint", false)
    WindowSetShowing("DeathReplay_GUITimeline", true)
    WindowSetShowing("DeathReplay_GUISortTime", true)
    WindowSetShowing("DeathReplay_GUIHeaderAbility", true)
    WindowSetShowing("DeathReplay_GUISortDmg",  true)

    ButtonSetText("DeathReplay_GUISortTime",      L"Time"   .. arrowFor("Time"))
    ButtonSetText("DeathReplay_GUIHeaderAbility", L"Ability")
    ButtonSetText("DeathReplay_GUISortDmg",       L"Damage" .. arrowFor("Amount"))
    if Button and Button.ButtonState then
        for _, btn in ipairs({"DeathReplay_GUISortTime", "DeathReplay_GUIHeaderAbility", "DeathReplay_GUISortDmg"}) do
            ButtonSetTextColor(btn, Button.ButtonState.NORMAL,              255, 220,  80)
            ButtonSetTextColor(btn, Button.ButtonState.HIGHLIGHTED,         255, 255, 255)
            ButtonSetTextColor(btn, Button.ButtonState.PRESSED,             255, 255, 255)
            ButtonSetTextColor(btn, Button.ButtonState.PRESSED_HIGHLIGHTED, 255, 255, 255)
        end
    end

    populateTimeline(d)

    -- Mark this death viewed.
    if d.viewed == false then
        d.viewed = true
        if DeathReplayIndicator and DeathReplayIndicator.Recompute then
            DeathReplayIndicator.Recompute()
        end
    end
end

function DeathReplay_GUI.Show()
    state.visible = true
    WindowSetShowing("DeathReplay_GUI", true)
    ButtonSetText("DeathReplay_GUIPrev", L"<")
    ButtonSetText("DeathReplay_GUINext", L">")
    ButtonSetText("DeathReplay_GUISortTime",      L"Time"   .. arrowFor("Time"))
    ButtonSetText("DeathReplay_GUIHeaderAbility", L"Ability")
    ButtonSetText("DeathReplay_GUISortDmg",       L"Damage" .. arrowFor("Amount"))
    DeathReplay_GUI.Render()
end

function DeathReplay_GUI.Hide()
    state.visible = false
    WindowSetShowing("DeathReplay_GUI", false)
end

function DeathReplay_GUI.Toggle()
    if state.visible then DeathReplay_GUI.Hide() else DeathReplay_GUI.Show() end
end

function DeathReplay_GUI.OnPrev()
    state.currentIndex = state.currentIndex - 1   -- '<' walks toward newer (lower index)
    DeathReplay_GUI.Render()
end

function DeathReplay_GUI.OnNext()
    state.currentIndex = state.currentIndex + 1   -- '>' walks toward older (higher index)
    DeathReplay_GUI.Render()
end

function DeathReplay_GUI.OnSortTime()
    if state.sortColumn == "Time" then
        state.sortDirection = (state.sortDirection == "desc") and "asc" or "desc"
    else
        state.sortColumn    = "Time"
        state.sortDirection = "desc"
    end
    DeathReplay_GUI.Render()
end

function DeathReplay_GUI.OnSortDmg()
    if state.sortColumn == "Amount" then
        state.sortDirection = (state.sortDirection == "desc") and "asc" or "desc"
    else
        state.sortColumn    = "Amount"
        state.sortDirection = "desc"
    end
    DeathReplay_GUI.Render()
end

function DeathReplay_GUI.OnClose()
    DeathReplay_GUI.Hide()
end

-- Wrap all public entry points in pcall + trace for diagnosis.
DeathReplay_GUI.Show            = dr_safe("Show",            DeathReplay_GUI.Show)
DeathReplay_GUI.Hide            = dr_safe("Hide",            DeathReplay_GUI.Hide)
DeathReplay_GUI.Toggle          = dr_safe("Toggle",          DeathReplay_GUI.Toggle)
DeathReplay_GUI.Render          = dr_safe("Render",          DeathReplay_GUI.Render)
DeathReplay_GUI.OnPrev          = dr_safe("OnPrev",          DeathReplay_GUI.OnPrev)
DeathReplay_GUI.OnNext          = dr_safe("OnNext",          DeathReplay_GUI.OnNext)
DeathReplay_GUI.OnSortTime      = dr_safe("OnSortTime",      DeathReplay_GUI.OnSortTime)
DeathReplay_GUI.OnSortDmg       = dr_safe("OnSortDmg",       DeathReplay_GUI.OnSortDmg)
DeathReplay_GUI.OnRowPopulated  = dr_safe("OnRowPopulated",  DeathReplay_GUI.OnRowPopulated)
DeathReplay_GUI.OnClose         = dr_safe("OnClose",         DeathReplay_GUI.OnClose)
