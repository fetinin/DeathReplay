-- DeathReplay_Indicator — small movable on-screen widget; lit when unviewed deaths exist.

DeathReplayIndicator = {}


function DeathReplayIndicator.Recompute()
    local anyUnviewed = false
    for _, d in ipairs(DeathReplay_SavedVariables.deaths) do
        if d.viewed == false then anyUnviewed = true; break end
    end
    -- v1 simplification: show the widget only when there are unviewed deaths.
    -- v2 backlog: bring back amber/gray tinting via proper DynamicImage icon.
    WindowSetShowing("DeathReplay_Indicator", anyUnviewed)
end

function DeathReplayIndicator.OnClick()
    -- DeathReplay_GUI is created in task 10; for this task we just print.
    if DeathReplay_GUI and DeathReplay_GUI.Toggle then
        DeathReplay_GUI.Toggle()
    else
        EA_ChatWindow.Print(L"DeathReplay indicator clicked — main window arrives in task 10.")
    end
end

function DeathReplayIndicator.OnMouseOver()
    Tooltips.CreateTextOnlyTooltip(SystemData.MouseOverWindow.name, L"Death Replay — click to view captured deaths")
    Tooltips.Finalize()
end
