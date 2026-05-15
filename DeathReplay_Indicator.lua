-- DeathReplay_Indicator — small movable on-screen widget; lit when unviewed deaths exist.

DeathReplayIndicator = {}

local LIT_COLOR = { r = 255, g = 200, b = 80  }    -- bright amber
local DIM_COLOR = { r = 110, g = 110, b = 110 }    -- gray

function DeathReplayIndicator.Recompute()
    local anyUnviewed = false
    for _, d in ipairs(DeathReplay_SavedVariables.deaths) do
        if d.viewed == false then anyUnviewed = true; break end
    end
    local c = anyUnviewed and LIT_COLOR or DIM_COLOR
    -- WindowSetTintColor takes (window, r, g, b). If the texture API differs slightly, see Aura/wsct examples.
    WindowSetTintColor("DeathReplay_IndicatorIconTex", c.r, c.g, c.b)
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
