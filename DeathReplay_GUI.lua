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
    return DeathReplay.GetCharDeaths()
end

-- abilityId=0 covers both melee and ranged auto-attacks (the engine reports
-- neither with a discrete ability id), so the label is the broader "Auto-attack".
local function abilityDisplayName(ability, abilityId)
    if ability ~= nil and ability ~= L"" then return ability end
    if (abilityId or 0) == 0 then return L"Auto-attack" end
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

-- Aggregate a death's HIT events into one row per display-name. Keyed by name
-- (not abilityId) so DoT ticks merge with their parent cast even though the
-- engine fires them with different abilityIds (verified: Touch of Palsy
-- cast=8338, tick=3400, same name "Touch of Palsy^n"). Rebuilds
-- DeathReplay_GUI.OverviewData in place. Display strings (Skill/Total/Hits/
-- Avg/Max) are pre-formatted as wstrings so the engine's auto-fill works; the
-- _total/_hits/_avg/_max/_name/_maxCrit/_iconNum fields drive sortOverview(),
-- OnOverviewRowPopulated's crit-coloring, and the icon column.
local function aggregateBySkill(d)
    DeathReplay_GUI.OverviewData = {}
    overviewDisplayOrder = {}
    if d == nil then return end
    local byName = {}
    for i = 1, #d.events do
        local e = d.events[i]
        if e.kind == "HIT" then
            local key = abilityDisplayName(e.ability, e.abilityId)
            local row = byName[key]
            if row == nil then
                row = {
                    name      = key,
                    rawName   = e.ability,  -- raw wstring (for retroactive icon resolver); key may be a fallback like "Auto-attack"
                    total     = 0, hits = 0, crits = 0,
                    max       = 0, maxCrit = false,
                    iconNum   = nil,
                    abilityId = nil,  -- first non-zero hit's id; drives the hover tooltip lookup
                }
                byName[key] = row
            end
            -- Capture a representative abilityId for the aggregated row.
            -- Mirrors the iconNum-first-wins pattern: cast + ticks of the
            -- same ability merge into one row, so the cast id (or whatever
            -- the engine fired first) is fine for the tooltip lookup.
            if row.abilityId == nil and e.abilityId and e.abilityId > 0 then
                row.abilityId = e.abilityId
            end
            row.total = row.total + (e.amount or 0)
            row.hits  = row.hits + 1
            if e.crit then row.crits = row.crits + 1 end
            if (e.amount or 0) > row.max then
                row.max     = e.amount or 0
                row.maxCrit = e.crit and true or false
            end
            -- Take the first non-zero iconNum we see for this name. Different
            -- abilityIds with the same name (cast + ticks) share the same icon.
            if row.iconNum == nil and e.iconNum and e.iconNum > 0 then
                row.iconNum = e.iconNum
            end
        end
    end
    for _, r in pairs(byName) do
        local avg = (r.hits > 0) and math.floor(r.total / r.hits + 0.5) or 0
        -- Max stays a plain number; crit-ness is communicated in
        -- OnOverviewRowPopulated by swapping the cell's font to bold.
        local maxText = towstring(r.max)
        -- Hits column shows just the plain count. The crit count, when > 0,
        -- renders in a sibling $parentHitsCrit label (set in the row populator)
        -- so we can bold only the "(N)" part without affecting the main count.
        DeathReplay_GUI.OverviewData[#DeathReplay_GUI.OverviewData + 1] = {
            Skill   = r.name,
            Total   = towstring(r.total),
            Hits    = towstring(r.hits),
            Avg     = towstring(avg),
            Max     = maxText,
            _name      = r.name,
            _total     = r.total,
            _hits      = r.hits,
            _avg       = avg,
            _max       = r.max,
            _maxCrit   = r.maxCrit,
            _crits     = r.crits,
            _iconNum   = r.iconNum,
            _abilityId = r.abilityId,  -- drives OnRowMouseOver tooltip lookup
            _ability   = r.rawName,    -- raw wstring; lets the populator retro-resolve a missing icon
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
            -- Whole-second resolution is enough for at-a-glance replay; the
            -- millisecond precision the engine reports was noise on screen.
            -- %3.0f rounds to nearest integer and keeps width consistent for
            -- "-10s" through "  0s" (GetGameTime returns seconds).
            local dtText = towstring(string.format("%3.0fs", e.dt))
            -- Crit-ness is conveyed by bolding the Amount cell in
            -- OnRowPopulated; Flags now only carries the killing-blow marker.
            local flags = L""
            if e.killingBlow then flags = L" *KB*" end
            table.insert(DeathReplay_GUI.Listdata, {
                Time      = dtText,
                Name      = abilityDisplayName(e.ability, e.abilityId),
                Amount    = towstring(e.amount or 0),
                Flags     = flags,
                _dt       = e.dt or 0,
                _amount   = e.amount or 0,
                _crit     = e.crit and true or false,
                _iconNum  = e.iconNum,   -- captured at hit-time; nil for cache misses / pre-feature deaths
                _abilityId = e.abilityId, -- needed by OnRowMouseOver tooltip lookup
                _ability   = e.ability,   -- raw wstring name; lets the populator retro-resolve a missing icon
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

            -- Crit marker on the timeline: swap Amount to bold instead of
            -- printing a separate "CRIT" tag. Same font pair as the Overview
            -- Max cell uses (font_clear_small_bold vs font_chat_text); the
            -- LinespacingArgument is mandatory or LabelSetFont silently no-ops.
            if row._crit then
                LabelSetFont(rowName .. "Amount", "font_clear_small_bold", WindowUtils.FONT_DEFAULT_TEXT_LINESPACING)
            else
                LabelSetFont(rowName .. "Amount", "font_chat_text", WindowUtils.FONT_DEFAULT_TEXT_LINESPACING)
            end

            -- Icon column: render only if we captured an iconNum at hit-time
            -- (via DeathReplay.lua's GetBuffs(SELF) harvest). Otherwise hide the
            -- slot so recycled rows don't show a stale texture from another row.
            local iconName = rowName .. "Icon"
            local iconNum = row._iconNum
            if iconNum and iconNum > 0 then
                local tex, ix, iy = GetIconData(iconNum)
                if tex and tex ~= "" and tex ~= "icon000000" then
                    -- Scale comes from textureScale in XML; runtime tweaks only
                    -- set the source rect + texture. Match PotionBar's pattern.
                    DynamicImageSetTextureDimensions(iconName, ix, iy)
                    DynamicImageSetTexture(iconName, tex, ix, iy)
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
            LabelSetTextColor(rowName .. "Max",   255,  80,  80)
            -- Crit marker on the peak hit: swap Max font to a bold variant.
            -- font_clear_small_bold is the bold pair other RoR addons use
            -- (Warbuilder); font_chat_text_bold appears registered but is
            -- visually identical to font_chat_text in this client.
            -- Note: LabelSetFont silently no-ops without the linespacing
            -- argument — every working call in the codebase passes it
            -- (PotionBar, wsct, Enemy, Obsidian).
            if row._maxCrit then
                LabelSetFont(rowName .. "Max", "font_clear_small_bold", WindowUtils.FONT_DEFAULT_TEXT_LINESPACING)
            else
                LabelSetFont(rowName .. "Max", "font_chat_text", WindowUtils.FONT_DEFAULT_TEXT_LINESPACING)
            end

            -- Crit count "(N)" rendered as a bold sibling to $parentHits so
            -- only the parenthetical is bold while the plain hit count keeps
            -- the normal font. Hidden when there are no crits, since recycled
            -- rows would otherwise leak the previous skill's crit count.
            local hitsCritName = rowName .. "HitsCrit"
            if row._crits and row._crits > 0 then
                LabelSetText(hitsCritName, L" (" .. towstring(row._crits) .. L")")
                LabelSetFont(hitsCritName, "font_clear_small_bold", WindowUtils.FONT_DEFAULT_TEXT_LINESPACING)
                LabelSetTextColor(hitsCritName, 220, 220, 220)
                WindowSetShowing(hitsCritName, true)
            else
                WindowSetShowing(hitsCritName, false)
            end

            -- Icon column: same scheme as the Timeline row populator. Hide
            -- the slot when no iconNum was captured for this skill (Auto-
            -- attacks, direct-damage abilities, abilities whose only hit
            -- arrived before the buff harvest had seen them).
            local iconName = rowName .. "Icon"
            local iconNum = row._iconNum
            if iconNum and iconNum > 0 then
                local tex, ix, iy = GetIconData(iconNum)
                if tex and tex ~= "" and tex ~= "icon000000" then
                    DynamicImageSetTextureDimensions(iconName, ix, iy)
                    DynamicImageSetTexture(iconName, tex, ix, iy)
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
        ButtonSetDisabledFlag("DeathReplay_GUIPrev", true)
        ButtonSetDisabledFlag("DeathReplay_GUINext", true)
        return
    end
    if state.currentIndex < 1 then state.currentIndex = 1 end
    if state.currentIndex > #list then state.currentIndex = #list end
    -- Prev walks toward the newest (lower index); Next walks toward older
    -- (higher index). Disable each at the corresponding boundary so the
    -- handler can't push currentIndex out of range.
    ButtonSetDisabledFlag("DeathReplay_GUIPrev", state.currentIndex <= 1)
    ButtonSetDisabledFlag("DeathReplay_GUINext", state.currentIndex >= #list)
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

-- Resolve the active mouse-over row window name back to its data record.
-- Engine names instantiated rows ...Row1, ...Row2, ...; the trailing index k
-- is the same k used in OnRowPopulated where PopulatorIndices[k] maps to the
-- source data array. Returns the row record, or nil for unrecognized names.
local function rowDataFromWindowName(windowName)
    if windowName == nil then return nil end
    local tIdx = string.match(windowName, "DeathReplay_GUITimelineRow(%d+)$")
    if tIdx then
        local list = _G["DeathReplay_GUITimeline"]
        if not list or not list.PopulatorIndices then return nil end
        local dataIndex = list.PopulatorIndices[tonumber(tIdx)]
        if not dataIndex then return nil end
        return DeathReplay_GUI.Listdata[dataIndex]
    end
    local oIdx = string.match(windowName, "DeathReplay_GUIOverviewContentListRow(%d+)$")
    if oIdx then
        local list = _G["DeathReplay_GUIOverviewContentList"]
        if not list or not list.PopulatorIndices then return nil end
        local dataIndex = list.PopulatorIndices[tonumber(oIdx)]
        if not dataIndex then return nil end
        return DeathReplay_GUI.OverviewData[dataIndex]
    end
    return nil
end

-- Build a hover tooltip with ability name, attacker career / type /
-- category subtitle (when the ability is in the Warbuilder DB), and the
-- full ability description from the engine. Mirrors the pattern in
-- Warbuilder/Source/Warbuilder.lua:1069-1082.
function DeathReplay_GUI.OnRowMouseOver()
    local row = rowDataFromWindowName(SystemData.ActiveWindow.name)
    if row == nil then return end
    local abilityID = row._abilityId
    if not abilityID or abilityID <= 0 then return end

    -- Pass the captured wstring name as a fallback key so DoT-tick captures
    -- (whose abilityID isn't in Warbuilder's by-id table) still recover the
    -- meta record via the by-name mirror.
    local meta = DeathReplay.GetAbilityMeta(abilityID, row._ability)
    local name = GetAbilityName(abilityID)
    if name == nil or name == L"" then
        -- Timeline rows expose the display name on row.Name, Overview rows on
        -- row.Skill. Try each in turn before giving up to the "Ability #N" form.
        if row.Name and row.Name ~= L"" then
            name = row.Name
        elseif row.Skill and row.Skill ~= L"" then
            name = row.Skill
        else
            name = L"Ability #" .. towstring(abilityID)
        end
    end
    -- GetAbilityDesc on a tick id returns L""; use the cast id from the
    -- Warbuilder meta when available so DoTs get their real description.
    local descId = (meta and meta.castId) or abilityID
    local desc = GetAbilityDesc(descId, 40)

    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, nil)
    Tooltips.SetTooltipColor(1, 1, 255, 220, 80)
    Tooltips.SetTooltipText (1, 1, name)

    if meta and meta.line then
        local careerName = GetCareerLine(meta.line)
        local typeStr    = (Warbuilder and Warbuilder.GetType    and Warbuilder.GetType(meta.type))     or L""
        local buffStr    = (Warbuilder and Warbuilder.GetBuffType and Warbuilder.GetBuffType(meta.buffType)) or L""
        local subtitle   = towstring(careerName or L"")
        if typeStr ~= L"" then subtitle = subtitle .. L"  -  " .. towstring(typeStr) end
        if buffStr ~= L"" then subtitle = subtitle .. L"  -  " .. towstring(buffStr) end
        Tooltips.SetTooltipColor(2, 1, 180, 180, 180)
        Tooltips.SetTooltipText (2, 1, subtitle)
    end

    if desc and desc ~= L"" then
        Tooltips.SetTooltipColor(3, 1, 255, 255, 255)
        Tooltips.SetTooltipText (3, 1, desc)
    end

    -- Cursor-anchored: tooltip follows the mouse so it appears next to the
    -- hovered row regardless of where the player has dragged the DeathReplay
    -- window. ANCHOR_CURSOR is the constant Enemy and other addons use for
    -- in-list hover tooltips (Enemy/Code/UnitFrames/UnitFrame.lua:568).
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_CURSOR)
    Tooltips.Finalize()
end

function DeathReplay_GUI.OnRowMouseOverEnd()
    -- Engine dismisses text-only tooltips automatically when the mouse leaves
    -- the anchor window; no explicit teardown needed.
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
DeathReplay_GUI.OnRowMouseOver    = dr_safe("OnRowMouseOver",    DeathReplay_GUI.OnRowMouseOver)
DeathReplay_GUI.OnRowMouseOverEnd = dr_safe("OnRowMouseOverEnd", DeathReplay_GUI.OnRowMouseOverEnd)
