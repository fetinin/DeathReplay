-- DeathReplay v0.1.0 — skeleton, see docs/superpowers/specs/2026-05-15-death-replay-design.md

DeathReplay = {}
DeathReplay_SavedVariables = nil   -- engine populates from disk on load, or leaves nil on first run

local SCHEMA_VERSION = 1

local function defaultSavedVariables()
    return {
        version = SCHEMA_VERSION,
        config  = {
            bufferWindowSeconds = 10,
            maxDeathsStored     = 5,
            captureMode         = "pvp",
        },
        deaths  = {},
    }
end

function DeathReplay.OnInitialize()
    if DeathReplay_SavedVariables == nil then
        DeathReplay_SavedVariables = defaultSavedVariables()
    end
    -- Migration scaffold: if version older than SCHEMA_VERSION, run migrations.
    -- No migrations exist yet (we are v1).

    LibSlash.RegisterSlashCmd("dr", function(input) DeathReplay.HandleSlash(input) end)
    EA_ChatWindow.Print(L"DeathReplay v0.1.0 loaded.")
end

function DeathReplay.OnShutdown()
    -- Nothing to unregister yet; handlers added in later tasks.
end

function DeathReplay.OnUpdate(elapsed)
    -- Ring buffer trim added in task 4.
end

function DeathReplay.HandleSlash(input)
    EA_ChatWindow.Print(L"DeathReplay: slash command alive. Real UI in later tasks.")
end
