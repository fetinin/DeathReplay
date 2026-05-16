-- DeathReplay_GUI — main replay window controller.

DeathReplay_GUI = {}

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
    DeathReplay.DebugPrint(L"DR_DEBUG Render: deaths=" .. towstring(#list))
    if #list == 0 then
        DeathReplay.DebugPrint(L"DR_DEBUG empty state - setting TitleBar to 'DeathReplay'")
        LabelSetText("DeathReplay_GUITitleBarText", L"DeathReplay")
        DeathReplay.DebugPrint(L"DR_DEBUG empty state - setting NavLabel to ''")
        LabelSetText("DeathReplay_GUINavLabel", L"")
        LabelSetTextColor("DeathReplay_GUINavLabel", 255, 255, 255)
        DeathReplay.DebugPrint(L"DR_DEBUG empty state - setting Timeline placeholder")
        LabelSetText("DeathReplay_GUITimeline",
            L"No deaths captured yet. Die in a scenario or RvR zone to capture your first replay.")
        LabelSetTextColor("DeathReplay_GUITimeline", 255, 255, 255)
        return
    end
    if state.currentIndex < 1 then state.currentIndex = 1 end
    if state.currentIndex > #list then state.currentIndex = #list end
    local d = list[state.currentIndex]
    local kbName = (d.killingBlow and d.killingBlow.ability) or L"unknown"

    local titleText = L"DeathReplay   " .. towstring(state.currentIndex) .. L"/" .. towstring(#list)
    DeathReplay.DebugPrint(L"DR_DEBUG LabelSetText DeathReplay_GUITitleBarText = " .. titleText)
    LabelSetText("DeathReplay_GUITitleBarText", titleText)

    local navText = (d.zone or L"?") .. L"  -  killed by " .. kbName
    DeathReplay.DebugPrint(L"DR_DEBUG LabelSetText DeathReplay_GUINavLabel = " .. navText)
    LabelSetText("DeathReplay_GUINavLabel", navText)
    LabelSetTextColor("DeathReplay_GUINavLabel", 255, 255, 255)

    local timelineText = renderTimeline(d)
    DeathReplay.DebugPrint(L"DR_DEBUG LabelSetText DeathReplay_GUITimeline length=" .. towstring(wstring.len(timelineText)))
    LabelSetText("DeathReplay_GUITimeline", timelineText)
    LabelSetTextColor("DeathReplay_GUITimeline", 255, 255, 255)

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
    DeathReplay.DebugPrint(L"DR_DEBUG setting button + checkbox label text")
    ButtonSetText("DeathReplay_GUIPrev", L"<")
    ButtonSetText("DeathReplay_GUINext", L">")
    LabelSetText("DeathReplay_GUIFilterDmgLabel",   L"damage")
    LabelSetText("DeathReplay_GUIFilterBuffsLabel", L"buffs")
    LabelSetTextColor("DeathReplay_GUIFilterDmgLabel",   255, 255, 255)
    LabelSetTextColor("DeathReplay_GUIFilterBuffsLabel", 255, 255, 255)
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
