-- DeathReplay_GUI — main replay window controller.

DeathReplay_GUI = {}

-- Public table read by XML <ListData table="DeathReplay_GUI.Listdata"...>. Each
-- entry is one HIT row: wstring columns for the engine's auto-fill
-- (Time/Name/Amount/Flags) plus hidden helpers (_dt/_amount) used by the sort
-- comparator.
DeathReplay_GUI.Listdata = {}

-- Public table read by XML <ListData table="DeathReplay_GUI.OverviewData"...>.
-- Each entry is one skill row aggregated from the current death's HIT events:
-- wstring display columns (Skill/Total/Hits/Avg/Max) plus hidden numeric
-- helpers (_total/_hits/_avg/_max/_name/_maxCrit) used by the sort comparator
-- and the row populator to colour the Max cell when its peak hit was a crit.
DeathReplay_GUI.OverviewData = {}

-- Maps visible row index -> Listdata index. Rebuilt by sortListdata() and
-- handed to ListBoxSetDisplayOrder; engine then exposes it as
-- _G["DeathReplay_GUITimeline"].PopulatorIndices when populationfunction fires.
local displayOrder = {}

-- Same role as displayOrder, but for the Overview ListBox.
local overviewDisplayOrder = {}

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
    visible               = false,
    currentIndex          = 1,
    sortColumn            = "Time",   -- "Time" | "Amount"
    sortDirection         = "desc",   -- "asc" | "desc"
    currentTab            = 1,        -- 1 = Overview (aggregated, default), 2 = Timeline (per-hit table)
    overviewSortColumn    = "Total",  -- "Skill" | "Total" | "Hits" | "Avg" | "Max"
    overviewSortDirection = "desc",   -- "asc" | "desc"
}

-- Widgets that belong to the Timeline tab. Hidden as a group when the user
-- switches to the Overview tab. $parentEmptyHint is intentionally NOT here:
-- Render() owns its visibility based on whether any deaths exist.
local TIMELINE_WIDGETS = {
    "DeathReplay_GUITimeline",
    "DeathReplay_GUISortTime",
    "DeathReplay_GUIHeaderAbility",
    "DeathReplay_GUISortDmg",
}

-- Widgets that belong to the Overview tab. Hidden as a group when the user
-- switches to the Timeline tab. The OverviewContent panel hosts the ListBox
-- and is toggled with this group.
local OVERVIEW_WIDGETS = {
    "DeathReplay_GUIOverviewContent",
    "DeathReplay_GUISortSkill",
    "DeathReplay_GUISortTotal",
    "DeathReplay_GUISortHits",
    "DeathReplay_GUISortAvg",
    "DeathReplay_GUISortMax",
}

-- Apply state.currentTab to the visible widgets and pressed-state of the tab
-- buttons. Called from Render() (populated branch) and OnTabClick().
local function applyTabVisibility()
    local onTimeline = (state.currentTab == 2)
    for _, w in ipairs(TIMELINE_WIDGETS) do
        WindowSetShowing(w, onTimeline)
    end
    for _, w in ipairs(OVERVIEW_WIDGETS) do
        WindowSetShowing(w, not onTimeline)
    end
    ButtonSetPressedFlag("DeathReplay_GUITabsTimeline", onTimeline)
    ButtonSetPressedFlag("DeathReplay_GUITabsOverview", not onTimeline)
end

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

-- Aggregate a death's HIT events into one row per abilityId. Rebuilds
-- DeathReplay_GUI.OverviewData in place. Display strings (Skill/Total/Hits/
-- Avg/Max) are pre-formatted as wstrings so the engine's auto-fill works; the
-- _total/_hits/_avg/_max/_name/_maxCrit fields drive sortOverview() and
-- OnOverviewRowPopulated's crit-coloring.
local function aggregateBySkill(d)
    DeathReplay_GUI.OverviewData = {}
    overviewDisplayOrder = {}
    if d == nil then return end
    local byId = {}
    for i = 1, #d.events do
        local e = d.events[i]
        if e.kind == "HIT" then
            local key = e.abilityId or 0
            local row = byId[key]
            if row == nil then
                row = {
                    name    = abilityDisplayName(e.ability, e.abilityId),
                    total   = 0, hits = 0, crits = 0,
                    max     = 0, maxCrit = false,
                }
                byId[key] = row
            end
            row.total = row.total + (e.amount or 0)
            row.hits  = row.hits + 1
            if e.crit then row.crits = row.crits + 1 end
            if (e.amount or 0) > row.max then
                row.max     = e.amount or 0
                row.maxCrit = e.crit and true or false
            end
        end
    end
    for _, r in pairs(byId) do
        local avg = (r.hits > 0) and math.floor(r.total / r.hits + 0.5) or 0
        local maxText = towstring(r.max)
        if r.maxCrit then maxText = maxText .. L"*" end
        local hitsText = towstring(r.hits)
        if r.crits > 0 then hitsText = hitsText .. L" (" .. towstring(r.crits) .. L"*)" end
        DeathReplay_GUI.OverviewData[#DeathReplay_GUI.OverviewData + 1] = {
            Skill   = r.name,
            Total   = towstring(r.total),
            Hits    = hitsText,
            Avg     = towstring(avg),
            Max     = maxText,
            _name   = r.name,
            _total  = r.total,
            _hits   = r.hits,
            _avg    = avg,
            _max    = r.max,
            _maxCrit = r.maxCrit,
        }
    end
end

-- Build overviewDisplayOrder from current sort state. Numeric columns use the
-- hidden _* fields; the Skill column uses a wstring comparison. Total-desc is
-- the default tie-break — matches a typical damage-meter expectation that the
-- biggest contributors float to the top.
local function sortOverview()
    overviewDisplayOrder = {}
    for i = 1, #DeathReplay_GUI.OverviewData do
        overviewDisplayOrder[i] = i
    end
    local col = state.overviewSortColumn
    local desc = (state.overviewSortDirection == "desc")
    local data = DeathReplay_GUI.OverviewData
    table.sort(overviewDisplayOrder, function(a, b)
        local ra, rb = data[a], data[b]
        local pa, pb
        if col == "Skill" then
            pa, pb = ra._name, rb._name
        elseif col == "Hits" then
            pa, pb = ra._hits, rb._hits
        elseif col == "Avg" then
            pa, pb = ra._avg, rb._avg
        elseif col == "Max" then
            pa, pb = ra._max, rb._max
        else  -- "Total"
            pa, pb = ra._total, rb._total
        end
        if pa ~= pb then
            if desc then return pa > pb end
            return pa < pb
        end
        -- tie-break: highest total first, regardless of primary sort direction
        return ra._total > rb._total
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
                Time    = dtText,
                Name    = abilityDisplayName(e.ability, e.abilityId),
                Amount  = towstring(e.amount or 0),
                Flags   = flags,
                _dt     = e.dt or 0,
                _amount = e.amount or 0,
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
        end
    end
end

function DeathReplay_GUI.OnOverviewRowPopulated()
    -- Engine flattens $parentList inside $parentOverviewContent to
    -- DeathReplay_GUIOverviewContentList, and instantiates row windows under
    -- it as ...ListRow1, ...ListRow2, ... matching the Overview row template.
    local list = _G["DeathReplay_GUIOverviewContentList"]
    if list == nil or list.PopulatorIndices == nil then return end
    for k, dataIndex in ipairs(list.PopulatorIndices) do
        local row = DeathReplay_GUI.OverviewData[dataIndex]
        if row ~= nil then
            local rowName = "DeathReplay_GUIOverviewContentListRow" .. k
            LabelSetTextColor(rowName .. "Skill", 255, 255, 255)
            LabelSetTextColor(rowName .. "Total", 255,  80,  80)
            LabelSetTextColor(rowName .. "Hits",  220, 220, 220)
            LabelSetTextColor(rowName .. "Avg",   220, 220, 220)
            -- When the row's peak hit was a crit, colour Max yellow (matches
            -- the Timeline Flags column's CRIT/*KB* highlight) instead of the
            -- normal red so the marker pops at a glance.
            if row._maxCrit then
                LabelSetTextColor(rowName .. "Max", 255, 220,  80)
            else
                LabelSetTextColor(rowName .. "Max", 255,  80,  80)
            end
        end
    end
end

local function arrowFor(col)
    if state.sortColumn ~= col then return L"" end
    if state.sortDirection == "desc" then return L" v" end
    return L" ^"
end

local function arrowForOverview(col)
    if state.overviewSortColumn ~= col then return L"" end
    if state.overviewSortDirection == "desc" then return L" v" end
    return L" ^"
end

-- Maps Overview header button id (XML id="N") to the sort column key.
local OVERVIEW_SORT_COLS = { [1] = "Skill", [2] = "Total", [3] = "Hits", [4] = "Avg", [5] = "Max" }

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
        for _, w in ipairs(OVERVIEW_WIDGETS) do
            WindowSetShowing(w, false)
        end
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
    -- Timeline widgets + Overview panel visibility is owned by applyTabVisibility()
    -- (called at the end of this function) based on state.currentTab.

    ButtonSetText("DeathReplay_GUISortTime",      L"Time"   .. arrowFor("Time"))
    ButtonSetText("DeathReplay_GUIHeaderAbility", L"Ability")
    ButtonSetText("DeathReplay_GUISortDmg",       L"Damage" .. arrowFor("Amount"))
    ButtonSetText("DeathReplay_GUISortSkill",     L"Skill"  .. arrowForOverview("Skill"))
    ButtonSetText("DeathReplay_GUISortTotal",     L"Total"  .. arrowForOverview("Total"))
    ButtonSetText("DeathReplay_GUISortHits",      L"Hits"   .. arrowForOverview("Hits"))
    ButtonSetText("DeathReplay_GUISortAvg",       L"Avg"    .. arrowForOverview("Avg"))
    ButtonSetText("DeathReplay_GUISortMax",       L"Max"    .. arrowForOverview("Max"))
    if Button and Button.ButtonState then
        local headers = {
            "DeathReplay_GUISortTime", "DeathReplay_GUIHeaderAbility", "DeathReplay_GUISortDmg",
            "DeathReplay_GUISortSkill", "DeathReplay_GUISortTotal", "DeathReplay_GUISortHits",
            "DeathReplay_GUISortAvg",  "DeathReplay_GUISortMax",
        }
        for _, btn in ipairs(headers) do
            ButtonSetTextColor(btn, Button.ButtonState.NORMAL,              255, 220,  80)
            ButtonSetTextColor(btn, Button.ButtonState.HIGHLIGHTED,         255, 255, 255)
            ButtonSetTextColor(btn, Button.ButtonState.PRESSED,             255, 255, 255)
            ButtonSetTextColor(btn, Button.ButtonState.PRESSED_HIGHLIGHTED, 255, 255, 255)
        end
    end

    populateTimeline(d)
    aggregateBySkill(d)
    sortOverview()
    ListBoxSetDisplayOrder("DeathReplay_GUIOverviewContentList", overviewDisplayOrder)
    applyTabVisibility()

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
    ButtonSetText("DeathReplay_GUISortSkill",     L"Skill"  .. arrowForOverview("Skill"))
    ButtonSetText("DeathReplay_GUISortTotal",     L"Total"  .. arrowForOverview("Total"))
    ButtonSetText("DeathReplay_GUISortHits",      L"Hits"   .. arrowForOverview("Hits"))
    ButtonSetText("DeathReplay_GUISortAvg",       L"Avg"    .. arrowForOverview("Avg"))
    ButtonSetText("DeathReplay_GUISortMax",       L"Max"    .. arrowForOverview("Max"))
    ButtonSetText("DeathReplay_GUITabsOverview", L"Overview")
    ButtonSetText("DeathReplay_GUITabsTimeline", L"Timeline")
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

function DeathReplay_GUI.OnOverviewSort()
    -- Five Overview headers share one handler; id=1..5 picks the column via
    -- OVERVIEW_SORT_COLS. Same id-dispatch idiom as OnTabClick above.
    local name = SystemData.ActiveWindow.name
    local id = WindowGetId(name)
    local col = OVERVIEW_SORT_COLS[id]
    if col == nil then return end
    if state.overviewSortColumn == col then
        state.overviewSortDirection = (state.overviewSortDirection == "desc") and "asc" or "desc"
    else
        state.overviewSortColumn    = col
        -- Skill defaults to ascending (alphabetical), numeric columns to desc.
        state.overviewSortDirection = (col == "Skill") and "asc" or "desc"
    end
    DeathReplay_GUI.Render()
end

function DeathReplay_GUI.OnTabClick()
    -- Tab buttons share one handler; id=1 (Overview) vs id=2 (Timeline)
    -- distinguishes them. WindowGetId reads the id="N" attribute set in XML.
    local name = SystemData.ActiveWindow.name
    local id = WindowGetId(name)
    DeathReplay.DebugPrint(L"DR_DEBUG OnTabClick name=" .. towstring(name)
                           .. L" id=" .. towstring(id)
                           .. L" prevTab=" .. towstring(state.currentTab))
    if id == 0 or id == state.currentTab then return end
    state.currentTab = id
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
DeathReplay_GUI.OnOverviewRowPopulated = dr_safe("OnOverviewRowPopulated", DeathReplay_GUI.OnOverviewRowPopulated)
DeathReplay_GUI.OnOverviewSort  = dr_safe("OnOverviewSort",  DeathReplay_GUI.OnOverviewSort)
DeathReplay_GUI.OnTabClick      = dr_safe("OnTabClick",      DeathReplay_GUI.OnTabClick)
DeathReplay_GUI.OnClose         = dr_safe("OnClose",         DeathReplay_GUI.OnClose)
