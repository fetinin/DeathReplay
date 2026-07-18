-- DeathReplay_Indicator — small movable on-screen widget; always visible,
-- click opens the DeathReplay window.

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


-- The indicator is a permanent screen element (user decision), so this only
-- enforces visibility. Unviewed-death tinting via a DynamicImage icon remains
-- on the backlog; callers still poke this after captures/views/resets so the
-- tint can hook in here later without touching them.
function DeathReplayIndicator.Recompute()
    WindowSetShowing("DeathReplay_Indicator", true)
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
