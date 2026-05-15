-- DeathReplay_GUI — main replay window controller.

DeathReplay_GUI = {}

-- Diagnostic helper: wrap entry points in pcall + trace for silent error detection.
local function dr_safe(fn_name, fn)
    return function(...)
        EA_ChatWindow.Print(L"DR_TRACE " .. towstring(fn_name))
        local ok, err = pcall(fn, ...)
        if not ok then
            EA_ChatWindow.Print(L"DR_ERR " .. towstring(fn_name) .. L": " .. towstring(tostring(err)))
        end
    end
end

local state = {
    visible      = false,
    currentIndex = 1,
    filterDmg    = true,
    filterBuffs  = true,
}

local function deaths()
    return DeathReplay_SavedVariables and DeathReplay_SavedVariables.deaths or {}
end

local function renderTimeline(d)
    if d == nil then return L"" end
    local lines = {}
    for _, e in ipairs(d.events) do
        local show = (e.kind == "HIT" and state.filterDmg)
                  or ((e.kind == "BUFF_GAIN" or e.kind == "BUFF_LOSS") and state.filterBuffs)
        if show then
            local dt = string.format("%6.1fs", e.dt)
            if e.kind == "HIT" then
                local crit = e.crit and L" CRIT" or L""
                local kb   = e.killingBlow and L" *KB*" or L""
                local abilityLabel = e.ability
                if abilityLabel == nil or abilityLabel == L"" then
                    abilityLabel = L"Ability #" .. towstring(e.abilityId or 0)
                end
                table.insert(lines, towstring(dt) .. L"  HIT  " .. abilityLabel
                    .. L"  " .. towstring(e.amount or 0) .. crit .. kb)
            elseif e.kind == "BUFF_GAIN" or e.kind == "BUFF_LOSS" then
                local sign = (e.kind == "BUFF_GAIN") and L"  +" or L"  -"
                local buffLabel = e.name
                if buffLabel == nil or buffLabel == L"" then
                    buffLabel = L"Buff #" .. towstring(e.buffId or 0)
                end
                table.insert(lines, towstring(dt) .. sign .. buffLabel)
            end
        end
    end
    -- Join with newlines into one wstring (multiline label).
    local out = L""
    for i, line in ipairs(lines) do
        if i > 1 then out = out .. L"\n" end
        out = out .. line
    end
    return out
end

function DeathReplay_GUI.Render()
    local list = deaths()
    EA_ChatWindow.Print(L"DR_DEBUG Render: deaths=" .. towstring(#list))
    if #list == 0 then
        EA_ChatWindow.Print(L"DR_DEBUG empty state - setting Title to 'DeathReplay'")
        LabelSetText("DeathReplay_GUITitle", L"DeathReplay")
        EA_ChatWindow.Print(L"DR_DEBUG empty state - setting NavLabel to ''")
        LabelSetText("DeathReplay_GUINavLabel", L"")
        EA_ChatWindow.Print(L"DR_DEBUG empty state - setting Timeline placeholder")
        LabelSetText("DeathReplay_GUITimeline",
            L"No deaths captured yet. Die in a scenario or RvR zone to capture your first replay.")
        return
    end
    if state.currentIndex < 1 then state.currentIndex = 1 end
    if state.currentIndex > #list then state.currentIndex = #list end
    local d = list[state.currentIndex]
    local kbName = (d.killingBlow and d.killingBlow.ability) or L"unknown"

    local titleText = L"DeathReplay   " .. towstring(state.currentIndex) .. L"/" .. towstring(#list)
    EA_ChatWindow.Print(L"DR_DEBUG LabelSetText DeathReplay_GUITitle = " .. titleText)
    LabelSetText("DeathReplay_GUITitle", titleText)

    local navText = (d.zone or L"?") .. L"  -  killed by " .. kbName
    EA_ChatWindow.Print(L"DR_DEBUG LabelSetText DeathReplay_GUINavLabel = " .. navText)
    LabelSetText("DeathReplay_GUINavLabel", navText)

    local timelineText = renderTimeline(d)
    EA_ChatWindow.Print(L"DR_DEBUG LabelSetText DeathReplay_GUITimeline length=" .. towstring(wstring.len(timelineText)))
    LabelSetText("DeathReplay_GUITimeline", timelineText)

    -- Mark this death viewed.
    if d.viewed == false then
        d.viewed = true
        if DeathReplayIndicator and DeathReplayIndicator.Recompute then
            DeathReplayIndicator.Recompute()
        end
    end

    ButtonSetPressedFlag("DeathReplay_GUIFilterDmg",   state.filterDmg)
    ButtonSetPressedFlag("DeathReplay_GUIFilterBuffs", state.filterBuffs)
end

function DeathReplay_GUI.Show()
    state.visible = true
    WindowSetShowing("DeathReplay_GUI", true)
    EA_ChatWindow.Print(L"DR_DEBUG calling ButtonSetText on 5 buttons (Prev/Next/FilterDmg/FilterBuffs/Close)")
    ButtonSetText("DeathReplay_GUIPrev",        L"<")
    ButtonSetText("DeathReplay_GUINext",        L">")
    ButtonSetText("DeathReplay_GUIFilterDmg",   L"damage")
    ButtonSetText("DeathReplay_GUIFilterBuffs", L"buffs")
    ButtonSetText("DeathReplay_GUIClose",       L"X")
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
    state.currentIndex = state.currentIndex + 1   -- older death = higher index
    DeathReplay_GUI.Render()
end

function DeathReplay_GUI.OnNext()
    state.currentIndex = state.currentIndex - 1   -- newer death = lower index
    DeathReplay_GUI.Render()
end

function DeathReplay_GUI.OnToggleDmg()
    state.filterDmg = not state.filterDmg
    DeathReplay_GUI.Render()
end

function DeathReplay_GUI.OnToggleBuffs()
    state.filterBuffs = not state.filterBuffs
    DeathReplay_GUI.Render()
end

function DeathReplay_GUI.OnClose()
    DeathReplay_GUI.Hide()
end

-- Wrap all public entry points in pcall + trace for diagnosis.
DeathReplay_GUI.Show          = dr_safe("Show",          DeathReplay_GUI.Show)
DeathReplay_GUI.Hide          = dr_safe("Hide",          DeathReplay_GUI.Hide)
DeathReplay_GUI.Toggle        = dr_safe("Toggle",        DeathReplay_GUI.Toggle)
DeathReplay_GUI.Render        = dr_safe("Render",        DeathReplay_GUI.Render)
DeathReplay_GUI.OnPrev        = dr_safe("OnPrev",        DeathReplay_GUI.OnPrev)
DeathReplay_GUI.OnNext        = dr_safe("OnNext",        DeathReplay_GUI.OnNext)
DeathReplay_GUI.OnToggleDmg   = dr_safe("OnToggleDmg",   DeathReplay_GUI.OnToggleDmg)
DeathReplay_GUI.OnToggleBuffs = dr_safe("OnToggleBuffs", DeathReplay_GUI.OnToggleBuffs)
DeathReplay_GUI.OnClose       = dr_safe("OnClose",       DeathReplay_GUI.OnClose)
