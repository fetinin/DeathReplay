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

local BUFFER_WINDOW_S       = 10
local MAX_EVENTS_BUFFERED   = 500
local COMBAT_EVENT_KIND = {
    [GameData.CombatEvent.HIT]               = { kind = "HIT", crit = false },
    [GameData.CombatEvent.ABILITY_HIT]       = { kind = "HIT", crit = false },
    [GameData.CombatEvent.CRITICAL]          = { kind = "HIT", crit = true  },
    [GameData.CombatEvent.ABILITY_CRITICAL]  = { kind = "HIT", crit = true  },
}
local recentEvents          = {}   -- chronological, oldest first; each entry has .t (GetComputerTime) + kind + payload

local lastEffectSnapshot = {}      -- keyed by tostring(buffId) .. "|" .. tostring(casterId)
local effectsBaseline = false      -- true once we've seeded from GetBuffs after LOADING_END

local deathState  = "alive"      -- "alive" | "dead"
local captureDone = false        -- prevents double-capture on HP=0 re-fires

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

local function snapshotEffects(buffList)
    local snap = {}
    if buffList == nil then return snap end
    for _, b in ipairs(buffList) do
        local key = tostring(b.id or b.buffId or 0) .. "|" .. tostring(b.casterId or 0)
        snap[key] = b
    end
    return snap
end

local function seedEffectsBaseline()
    lastEffectSnapshot = snapshotEffects(GetBuffs(GameData.BuffTargetType.SELF))
    effectsBaseline = true
end

function DeathReplay.OnContextMaybeChanged()
    recomputePvpContext()
    seedEffectsBaseline()
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

local trimAccumulator = 0
local TRIM_INTERVAL_S = 0.5

local function trimRecentEvents()
    if #recentEvents == 0 then return end
    local now = GetComputerTime() / 1000   -- GetComputerTime returns ms; convert to seconds
    local cutoff = now - BUFFER_WINDOW_S
    -- Drop from the front until oldest entry is within the window.
    while #recentEvents > 0 and recentEvents[1].t < cutoff do
        table.remove(recentEvents, 1)
    end
end

local function pushEvent(entry)
    entry.t = GetComputerTime() / 1000
    if #recentEvents >= MAX_EVENTS_BUFFERED then
        table.remove(recentEvents, 1)   -- drop oldest to make room
    end
    table.insert(recentEvents, entry)
end

function DeathReplay.OnCombatEvent(objectID, amount, combatEvent, abilityID)
    if not isPvpNow then return end
    if not isDefenderPlayer(objectID) then return end
    local mapping = COMBAT_EVENT_KIND[combatEvent]
    if mapping == nil then return end       -- v1 ignores misses and unknowns
    if amount == nil or amount <= 0 then return end
    local abilityName = GetAbilityName(abilityID)
    pushEvent({
        kind      = mapping.kind,
        crit      = mapping.crit,
        amount    = amount,
        abilityId = abilityID,
        ability   = abilityName,    -- may be empty wstring if unresolvable
    })
end

function DeathReplay.OnEffectsUpdated(changedEffects, isFullList)
    if not isPvpNow then return end
    if not effectsBaseline then return end
    local current = snapshotEffects(GetBuffs(GameData.BuffTargetType.SELF))
    for key, eff in pairs(current) do
        if lastEffectSnapshot[key] == nil then
            pushEvent({
                kind     = "BUFF_GAIN",
                name     = eff.name or L"?",
                buffId   = eff.id or eff.buffId or 0,
                duration = eff.duration or 0,
            })
        end
    end
    for key, eff in pairs(lastEffectSnapshot) do
        if current[key] == nil then
            pushEvent({
                kind   = "BUFF_LOSS",
                name   = eff.name or L"?",
                buffId = eff.id or eff.buffId or 0,
            })
        end
    end
    lastEffectSnapshot = current
end

function DeathReplay.OnHitPointsUpdated()
    if not isPvpNow then return end
    local hp = GameData.Player.hitPoints and GameData.Player.hitPoints.current or 0
    if deathState == "alive" and hp == 0 and not captureDone then
        EA_ChatWindow.Print(L"[stub] DeathReplay: would capture death here")
        captureDone = true
        deathState  = "dead"
    elseif deathState == "dead" and hp > 0 then
        deathState  = "alive"
        captureDone = false
    end
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

    RegisterEventHandler(SystemData.Events.WORLD_OBJ_COMBAT_EVENT, "DeathReplay.OnCombatEvent")

    RegisterEventHandler(SystemData.Events.PLAYER_EFFECTS_UPDATED, "DeathReplay.OnEffectsUpdated")

    RegisterEventHandler(SystemData.Events.PLAYER_CUR_HIT_POINTS_UPDATED, "DeathReplay.OnHitPointsUpdated")

    EA_ChatWindow.Print(L"DeathReplay v0.1.0 loaded.")
end

function DeathReplay.OnShutdown()
    UnregisterEventHandler(SystemData.Events.LOADING_END,                "DeathReplay.OnContextMaybeChanged")
    UnregisterEventHandler(SystemData.Events.PLAYER_AREA_NAME_CHANGED,   "DeathReplay.OnContextMaybeChanged")
    UnregisterEventHandler(SystemData.Events.SCENARIO_INSTANCE_JOIN_NOW, "DeathReplay.OnContextMaybeChanged")

    UnregisterEventHandler(SystemData.Events.WORLD_OBJ_COMBAT_EVENT, "DeathReplay.OnCombatEvent")

    UnregisterEventHandler(SystemData.Events.PLAYER_EFFECTS_UPDATED, "DeathReplay.OnEffectsUpdated")

    UnregisterEventHandler(SystemData.Events.PLAYER_CUR_HIT_POINTS_UPDATED, "DeathReplay.OnHitPointsUpdated")
end

function DeathReplay.OnUpdate(elapsed)
    trimAccumulator = trimAccumulator + elapsed
    if trimAccumulator < TRIM_INTERVAL_S then return end
    trimAccumulator = 0
    trimRecentEvents()
end

function DeathReplay.HandleSlash(input)
    EA_ChatWindow.Print(L"DeathReplay: slash command alive. Real UI in later tasks.")
end
