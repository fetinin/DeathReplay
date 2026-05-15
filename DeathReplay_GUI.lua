-- DeathReplay_GUI — main replay window controller.

DeathReplay_GUI = {}

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
    if #list == 0 then
        LabelSetText("DeathReplay_GUITitle", L"DeathReplay")
        LabelSetText("DeathReplay_GUINavLabel", L"")
        LabelSetText("DeathReplay_GUITimeline",
            L"No deaths captured yet. Die in a scenario or RvR zone to capture your first replay.")
        return
    end
    if state.currentIndex < 1 then state.currentIndex = 1 end
    if state.currentIndex > #list then state.currentIndex = #list end
    local d = list[state.currentIndex]
    local kbName = (d.killingBlow and d.killingBlow.ability) or L"unknown"
    LabelSetText("DeathReplay_GUITitle",
        L"DeathReplay   " .. towstring(state.currentIndex) .. L"/" .. towstring(#list))
    LabelSetText("DeathReplay_GUINavLabel",
        (d.zone or L"?") .. L"  —  killed by " .. kbName)
    LabelSetText("DeathReplay_GUITimeline", renderTimeline(d))

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
