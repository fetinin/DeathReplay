-- Self-id assumption (not yet empirically verified): for WORLD_OBJ_COMBAT_EVENT,
-- defender objectID equals GameData.Player.worldObjNum. Probe deferred to
-- end-of-batch in-game verification. If wrong, replace via fixup commit.

-- DeathReplay v0.1.0 — skeleton, see docs/superpowers/specs/2026-05-15-death-replay-design.md

DeathReplay = {}
DeathReplay_SavedVariables = nil   -- engine populates from disk on load, or leaves nil on first run

local SCHEMA_VERSION = 1

-- Open-RvR campaign zone ids. Copied from QueueQueuer.lua:280-302 (CampaignZones).
local RVR_ZONES = {
    [9]   = true,  [5]   = true,  [3]   = true,  [4]   = true,  [10]  = true,
    [103] = true,  [105] = true,  [109] = true,  [104] = true,  [110] = true,
    [161] = true,  [162] = true,
    [203] = true,  [205] = true,  [209] = true,  [204] = true,  [210] = true,
}

local isPvpNow = false   -- cached; updated by DeathReplay.OnContextMaybeChanged

local function isRvrZone(zoneId)
    return RVR_ZONES[zoneId] == true
end

local function recomputePvpContext()
    local prev = isPvpNow
    isPvpNow = (GameData.Player.isInScenario == true)
               or isRvrZone(GameData.Player.zone)
    return prev, isPvpNow
end

local function isDefenderPlayer(objectID)
    return objectID == GameData.Player.worldObjNum
end

function DeathReplay.OnContextMaybeChanged()
    recomputePvpContext()
end

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

    RegisterEventHandler(SystemData.Events.LOADING_END,                "DeathReplay.OnContextMaybeChanged")
    RegisterEventHandler(SystemData.Events.PLAYER_AREA_NAME_CHANGED,   "DeathReplay.OnContextMaybeChanged")
    RegisterEventHandler(SystemData.Events.SCENARIO_INSTANCE_JOIN_NOW, "DeathReplay.OnContextMaybeChanged")

    EA_ChatWindow.Print(L"DeathReplay v0.1.0 loaded.")
end

function DeathReplay.OnShutdown()
    UnregisterEventHandler(SystemData.Events.LOADING_END,                "DeathReplay.OnContextMaybeChanged")
    UnregisterEventHandler(SystemData.Events.PLAYER_AREA_NAME_CHANGED,   "DeathReplay.OnContextMaybeChanged")
    UnregisterEventHandler(SystemData.Events.SCENARIO_INSTANCE_JOIN_NOW, "DeathReplay.OnContextMaybeChanged")
end

function DeathReplay.OnUpdate(elapsed)
    -- Ring buffer trim added in task 4.
end

function DeathReplay.HandleSlash(input)
    EA_ChatWindow.Print(L"DeathReplay: slash command alive. Real UI in later tasks.")
end
