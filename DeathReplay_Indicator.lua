-- DeathReplay_Indicator — small movable on-screen widget; lit when unviewed deaths exist.

DeathReplayIndicator = {}

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
    Tooltips.CreateTextOnlyTooltip(SystemData.MouseOverWindow.name, L"Death Replay - click to view captured deaths")
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
    Tooltips.Finalize()
end

function DeathReplayIndicator.OnWindowInit()
    if LayoutEditor and LayoutEditor.RegisterWindow then
        LayoutEditor.RegisterWindow(
            "DeathReplay_Indicator",
            L"Death Replay",
            L"Unviewed death indicator",
            true,   -- defaultShown
            false,  -- resizable
            false,  -- scalable
            nil)
    end
end

-- Wrap all public entry points in pcall + trace for diagnosis.
DeathReplayIndicator.Recompute    = dr_safe("Indicator.Recompute",    DeathReplayIndicator.Recompute)
DeathReplayIndicator.OnClick      = dr_safe("Indicator.OnClick",      DeathReplayIndicator.OnClick)
DeathReplayIndicator.OnMouseOver  = dr_safe("Indicator.OnMouseOver",  DeathReplayIndicator.OnMouseOver)
DeathReplayIndicator.OnWindowInit = dr_safe("Indicator.OnWindowInit", DeathReplayIndicator.OnWindowInit)
