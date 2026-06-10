-- DeathReplay v0.4.3 — skeleton, see docs/superpowers/specs/2026-05-15-death-replay-design.md

DeathReplay = {}
DeathReplay_SavedVariables = nil   -- engine populates from disk on load, or leaves nil on first run

local SCHEMA_VERSION = 3

-- Per-character death bucketing. The engine has no SavedVariablesPerCharacter
-- declaration, so we shard inside the single account-wide SavedVariable.
-- Key shape (slot + server) matches Pure/AceDB-3.0.lua:305-306 -- stable across
-- character renames, populated by the time OnInitialize fires.
local function characterKey()
    local slot   = GameData.Account.SelectedCharacterSlot
    local server = GameData.Account.ServerName
    return tostring(slot) .. " - " .. tostring(server)
end

local function getCharDeaths()
    local chars = DeathReplay_SavedVariables.characters
    local key   = characterKey()
    if chars[key] == nil then chars[key] = { deaths = {} } end
    return chars[key].deaths
end

-- Public accessor for the GUI / Indicator modules.
function DeathReplay.GetCharDeaths()
    if DeathReplay_SavedVariables == nil
       or DeathReplay_SavedVariables.characters == nil then
        return {}
    end
    return getCharDeaths()
end

function DeathReplay.IsDebug()
    return DeathReplay_SavedVariables ~= nil
       and DeathReplay_SavedVariables.config ~= nil
       and DeathReplay_SavedVariables.config.debug == true
end

function DeathReplay.DebugPrint(msg)
    if DeathReplay.IsDebug() then
        EA_ChatWindow.Print(msg)
    end
end

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

-- Open-RvR zone ids. The scenario-tied campaign list at QueueQueuer.lua:276-302
-- (CampaignZones) is incomplete -- it omits RvR lakes without scenarios (zone
-- 102 etc.). The pairings at Enemy/Code/KillSpam/KillSpam.lua:494-504 are the
-- authoritative open-RvR list: each elseif covers one realm-pair tier.
local RVR_ZONES = {
    -- T1: Greenskins (1/7), Empire (2/8), Dark Elves (6/11)
    [1]   = true,  [7]   = true,
    [2]   = true,  [8]   = true,
    [6]   = true,  [11]  = true,
    -- Plus campaign-zone T1s that have scenarios attached:
    [9]   = true,  [5]   = true,  [3]   = true,  [4]   = true,  [10]  = true,
    -- T2: Greenskins (101/107), Empire (102/108)
    [101] = true,  [107] = true,
    [102] = true,  [108] = true,
    -- Plus campaign-zone T2s:
    [103] = true,  [105] = true,  [109] = true,  [104] = true,  [110] = true,
    -- Capitals
    [161] = true,  [162] = true,
    -- T4: Greenskins (201/207), Empire (202/208), Dark Elves (200/206)
    [200] = true,  [206] = true,
    [201] = true,  [207] = true,
    [202] = true,  [208] = true,
    -- Plus campaign-zone T4s (forts + Eataine):
    [203] = true,  [205] = true,  [209] = true,  [204] = true,  [210] = true,
}

local isPvpNow = false   -- cached; updated by DeathReplay.OnContextMaybeChanged

local MAX_EVENTS_BUFFERED   = 1000
local COMBAT_EVENT_KIND = {
    [GameData.CombatEvent.HIT]               = { kind = "HIT", crit = false },
    [GameData.CombatEvent.ABILITY_HIT]       = { kind = "HIT", crit = false },
    [GameData.CombatEvent.CRITICAL]          = { kind = "HIT", crit = true  },
    [GameData.CombatEvent.ABILITY_CRITICAL]  = { kind = "HIT", crit = true  },
}
local recentEvents          = {}   -- chronological, oldest first; each entry has .t (GetGameTime seconds) + kind + payload

-- abilityId -> iconNum AND ability-name -> iconNum, harvested at
-- PLAYER_EFFECTS_UPDATED from GetBuffs(SELF). The name-keyed cache exists
-- because the engine's DoT ticks fire with a DIFFERENT abilityId than the
-- effect's own abilityId on the buff bar (verified empirically: Touch of Palsy
-- cast=8338, tick=3400). Both share the wstring name, so name match catches
-- ticks the id match misses. GetAbilityData() only resolves icons for the
-- player's own spellbook; for incoming enemy abilities we have to scrape
-- iconNum off active debuffs. Covers DoTs / lingering effects; pure direct-
-- damage abilities never appear. Runtime-only (not persisted).
local iconCache       = {}
local iconCacheByName = {}
-- Maintained counters so the DR_BUFF debug line doesn't need an O(n) `pairs`
-- walk on every PLAYER_EFFECTS_UPDATED. Increment-on-first-insert only.
local iconCacheSize       = 0
local iconCacheByNameSize = 0

-- abilityID -> { icon, type, buffType, line }, harvested once at init from
-- Warbuilder.Career[]. Covers direct-hit abilities that the runtime iconCache
-- never sees, and supplies the tooltip subtitle data (career name via
-- GetCareerLine(line), human-readable type via Warbuilder.GetType/GetBuffType).
-- ~1500 unique entries across all 24 PvP careers. Hard-dep on Warbuilder
-- declared in DeathReplay.mod so the table is guaranteed populated at init.
local staticAbilityDB = {}
-- wstring name -> meta record (same table reference as staticAbilityDB[id]).
-- Built by calling GetAbilityName(castId) for each Warbuilder entry at init.
-- Bridges DoT tick ids (3162, 3787, etc.) to their cast entry: captured event
-- carries the tick id and the same wstring name as the cast, so a name lookup
-- finds the meta record (incl. castId, icon, type/buffType/line) when an
-- id lookup against staticAbilityDB misses. Lets GUI tooltip recover the
-- engine's ability description via GetAbilityDesc(meta.castId, 40) even when
-- only the tick id is known.
local staticAbilityDBByName = {}

local effectFieldDumpDone = false
local function harvestIconsFromActiveEffects()
    local effects = GetBuffs(GameData.BuffTargetType.SELF)
    if effects == nil then
        if DeathReplay.IsDebug() then
            EA_ChatWindow.Print(L"DR_BUFF GetBuffs returned nil")
        end
        return
    end
    local seen = 0
    local added = 0
    local firstE = nil
    -- GetBuffs may return a sparse map (numeric keys not necessarily 1..N), so
    -- iterate via pairs not ipairs.
    for _, e in pairs(effects) do
        seen = seen + 1
        if firstE == nil then firstE = e end
        if e.iconNum and e.iconNum > 0 then
            if e.abilityId then
                if iconCache[e.abilityId] == nil then
                    added = added + 1
                    iconCacheSize = iconCacheSize + 1
                end
                iconCache[e.abilityId] = e.iconNum
            end
            if e.name and e.name ~= L"" then
                if iconCacheByName[e.name] == nil then
                    iconCacheByNameSize = iconCacheByNameSize + 1
                end
                iconCacheByName[e.name] = e.iconNum
            end
        end
    end
    -- One-shot: dump keys of the first effect we see, so we can confirm whether
    -- `abilityId` is actually a real field name on this engine build.
    if DeathReplay.IsDebug() and firstE ~= nil and not effectFieldDumpDone then
        effectFieldDumpDone = true
        local keys = L""
        for k, v in pairs(firstE) do
            keys = keys .. L" " .. towstring(tostring(k)) .. L"=" .. towstring(tostring(v))
        end
        EA_ChatWindow.Print(L"DR_BUFF first-effect keys:" .. keys)
    end
    if DeathReplay.IsDebug() and (seen > 0 or added > 0) then
        EA_ChatWindow.Print(L"DR_BUFF harvest seen=" .. towstring(seen)
            .. L" added=" .. towstring(added)
            .. L" cacheSize=" .. towstring(iconCacheSize)
            .. L" byName=" .. towstring(iconCacheByNameSize))
    end
end

local function buildStaticAbilityDB()
    if not Warbuilder or not Warbuilder.Career then return end
    local count = 0
    local nameCount = 0
    local function ingest(e, careerLine)
        if e and e.ID and staticAbilityDB[e.ID] == nil then
            local meta = {
                castId   = e.ID,    -- lets GUI call GetAbilityDesc(castId) when only tick id is known
                icon     = e.Icon,
                type     = e.Type,
                buffType = e.BuffType,
                line     = careerLine,
            }
            staticAbilityDB[e.ID] = meta
            count = count + 1
            -- Resolve wstring name via the engine, then mirror the same meta
            -- table by name so DoT tick captures (whose abilityID differs from
            -- the cast id but whose name matches) can recover the full record:
            -- icon for the row, castId for GetAbilityDesc, and line/type/
            -- buffType for the subtitle.
            local name = GetAbilityName(e.ID)
            if name and name ~= L"" and staticAbilityDBByName[name] == nil then
                staticAbilityDBByName[name] = meta
                nameCount = nameCount + 1
            end
        end
    end
    for _, career in pairs(Warbuilder.Career) do
        -- Use career.Line (the canonical career-line id used by GetCareerLine),
        -- not the table key. Warbuilder's own code does the same -- see
        -- Warbuilder.lua:349 which calls GetCareerLine(Warbuilder.Career[k].Line).
        -- They match in the shipped data, but reading the named field is more
        -- robust against any future reshuffle.
        local careerLine = career.Line
        if career.Core then
            -- Core.Ability / Core.Tactic / Core.Morale are flat arrays.
            for _, list in pairs({career.Core.Ability, career.Core.Tactic, career.Core.Morale}) do
                for _, e in ipairs(list) do ingest(e, careerLine) end
            end
        end
        if career.Path then
            -- Each Path[i] is a hybrid table: a named .Core sub-table holding
            -- the mastery path's tree abilities (plus a decorative .Icon field
            -- that ipairs skips), and array entries at the path level for
            -- mastery tactics/morales. ipairs iterates only numeric keys.
            for _, path in ipairs(career.Path) do
                if path.Core then
                    for _, e in ipairs(path.Core) do ingest(e, careerLine) end
                end
                for _, e in ipairs(path) do ingest(e, careerLine) end
            end
        end
    end
    if DeathReplay.IsDebug() then
        EA_ChatWindow.Print(L"DR_INIT staticAbilityDB built, entries=" .. towstring(count)
            .. L" byName=" .. towstring(nameCount))
    end
end

-- Accessor for the GUI tooltip layer. Returns { castId, icon, type, buffType,
-- line } for abilities in the Warbuilder database, nil otherwise (NPC, items,
-- renown). When abilityID is a DoT tick (and so misses the by-id table), the
-- optional abilityName argument retries against the by-name mirror. Callers
-- must tolerate nil and fall back to engine APIs for name and description.
function DeathReplay.GetAbilityMeta(abilityID, abilityName)
    if abilityID and abilityID > 0 then
        local meta = staticAbilityDB[abilityID]
        if meta then return meta end
    end
    if abilityName and abilityName ~= L"" then
        local nameMeta = staticAbilityDBByName[abilityName]
        if nameMeta then return nameMeta end
        -- Hand-curated weapon-proc fallback. Engine reports these with
        -- abilityId=0 and they are absent from Warbuilder, so a separate table
        -- (DeathReplay_WeaponProcs.lua) supplies icon + description by name.
        -- Returned meta intentionally lacks castId/line/type/buffType so the
        -- GUI subtitle path skips and the description path uses meta.description.
        local proc = DeathReplay_WeaponProcs and DeathReplay_WeaponProcs.Lookup(abilityName)
        if proc then
            return { icon = proc.icon, description = proc.description }
        end
    end
    return nil
end

local function resolveIconForAbility(abilityID, abilityName)
    -- Player's own outgoing abilities resolve here (cheap, authoritative).
    -- For most DeathReplay events (incoming damage) this path returns iconNum=0
    -- so we fall through to the harvested-from-effects caches.
    if abilityID and abilityID > 0 then
        local data = GetAbilityData(abilityID)
        if data and data.iconNum and data.iconNum > 0 then
            return data.iconNum
        end
        local byId = iconCache[abilityID]
        if byId then return byId end
    end
    -- Name fallback: catches DoT ticks whose abilityID differs from the buff's
    -- effect.abilityId (e.g. Touch of Palsy cast=8338, tick=3400, name="Touch
    -- of Palsy^n" on both).
    if abilityName and abilityName ~= L"" then
        local byName = iconCacheByName[abilityName]
        if byName then return byName end
    end
    -- Static DB fallback: covers direct-hit abilities the runtime caches never
    -- see (no debuff aura applied to the player). Sourced from
    -- Warbuilder.Career[] at addon init. Holds cast-time ability IDs only, so
    -- it deliberately sits after the runtime name cache that catches DoT tick
    -- IDs.
    if abilityID and abilityID > 0 then
        local meta = staticAbilityDB[abilityID]
        if meta and meta.icon and meta.icon > 0 then
            return meta.icon
        end
    end
    -- Name fallback against the Warbuilder DB. Bridges tick->cast when the
    -- player has never observed the debuff on their own bar (so
    -- iconCacheByName is empty for this name) but Warbuilder has the cast
    -- entry. Builds on the same wstring-name invariant the runtime name cache
    -- relies on: engine fires tick and cast with matching .name field.
    if abilityName and abilityName ~= L"" then
        local nameMeta = staticAbilityDBByName[abilityName]
        if nameMeta and nameMeta.icon and nameMeta.icon > 0 then return nameMeta.icon end
    end
    -- Last resort: hand-curated weapon-proc table. Engine reports these with
    -- abilityId=0 (no GetAbilityData entry) and Warbuilder doesn't carry item
    -- enchants, so neither id nor Warbuilder name fallbacks above can resolve.
    if abilityName and abilityName ~= L"" and DeathReplay_WeaponProcs then
        local proc = DeathReplay_WeaponProcs.Lookup(abilityName)
        if proc and proc.icon and proc.icon > 0 then return proc.icon end
    end
    return nil
end

local deathState  = "alive"      -- "alive" | "dead"
local captureDone = false        -- prevents double-capture on HP=0 re-fires

-- Handle to the most-recently captured death. Lets OnCombatEvent fold in
-- "trailing" damage -- hits whose combat events are dispatched just after the
-- hp=0 update that triggered captureDeath(), so they miss the snapshot
-- (verified in the wild: a same-instant killing burst, and a DoT tick landing a
-- second post-capture). Held only between capture and respawn; cleared in
-- OnHitPointsUpdated on revive.
local lastCapturedDeath = nil

local function fixZoneName(name)
    -- Quick wstring trim — same pattern as QueueQueuer.FixName. Strip trailing junk control chars.
    if name == nil then return L"" end
    local s = tostring(name)
    -- Drop everything from a ^ if present (game appends ^M / ^F sometimes)
    local i = string.find(s, "^", 1, true)
    if i then s = string.sub(s, 1, i - 1) end
    return towstring(s)
end

local function captureDeath()
    -- GetGameTime returns elapsed seconds at whole-second resolution on this
    -- engine build (observed: combat-event gaps land on exact 0s/1s boundaries,
    -- never fractional). WarBoard uses it for session timing — see
    -- WarBoard_Session.lua:101 where (GetGameTime() - initialClock) is divided
    -- directly to get "per second" rates. GetComputerTime's unit (ms vs s) is
    -- ambiguous on this engine build, so we avoid it.
    local deathTime = GetGameTime()
    local events = {}
    local killingBlow = nil
    for _, e in ipairs(recentEvents) do
        local entry = {
            dt   = e.t - deathTime,         -- negative number, seconds before death
            kind = e.kind,
        }
        if e.kind == "HIT" then
            entry.ability   = e.ability
            entry.abilityId = e.abilityId
            entry.iconNum   = e.iconNum
            entry.amount    = e.amount
            entry.crit      = e.crit
            -- Last HIT event wins as killing blow.
            killingBlow = {
                kind      = (e.crit and "ABILITY_CRITICAL" or "ABILITY_HIT"),
                ability   = e.ability,
                abilityId = e.abilityId,
                iconNum   = e.iconNum,
                amount    = e.amount,
            }
            entry.killingBlow = true       -- will be cleared below for non-final HITs
        end
        table.insert(events, entry)
    end
    -- Only the final HIT keeps killingBlow=true. Walk backwards, clear it from all but the last.
    local seenKillingBlow = false
    for i = #events, 1, -1 do
        if events[i].killingBlow then
            if seenKillingBlow then
                events[i].killingBlow = nil
            else
                seenKillingBlow = true
            end
        end
    end

    -- Back-propagate iconNum across same-ability events. The harvest-from-
    -- effects cache fills lazily, so the FIRST hit of any new debuff lands
    -- before PLAYER_EFFECTS_UPDATED has had a chance to seed iconCache. The
    -- name fallback covers the case where the engine's DoT ticks fire with a
    -- different abilityId than the parent cast (Touch of Palsy: cast=8338,
    -- tick=3400, name matches on both). Pass 1: build aid/name -> iconNum
    -- maps from any populated entry. Pass 2: fill nil-iconNum entries via id,
    -- falling back to name.
    local iconByAid, iconByName = {}, {}
    for _, e in ipairs(events) do
        if e.iconNum and e.iconNum > 0 then
            if e.abilityId and iconByAid[e.abilityId] == nil then
                iconByAid[e.abilityId] = e.iconNum
            end
            if e.ability and e.ability ~= L"" and iconByName[e.ability] == nil then
                iconByName[e.ability] = e.iconNum
            end
        end
    end
    local function backfill(target)
        if target.iconNum and target.iconNum > 0 then return end
        if target.abilityId and iconByAid[target.abilityId] then
            target.iconNum = iconByAid[target.abilityId]
            return
        end
        if target.ability and target.ability ~= L"" and iconByName[target.ability] then
            target.iconNum = iconByName[target.ability]
        end
    end
    for _, e in ipairs(events) do backfill(e) end
    if killingBlow then backfill(killingBlow) end

    local death = {
        timestamp   = deathTime,
        zone        = fixZoneName(GetZoneName(GameData.Player.zone)),
        zoneId      = GameData.Player.zone,
        context     = (GameData.Player.isInScenario and "scenario" or "rvr"),
        viewed      = false,
        killingBlow = killingBlow,
        events      = events,
    }

    -- Prepend, FIFO trim to maxDeathsStored
    local charDeaths = getCharDeaths()
    table.insert(charDeaths, 1, death)
    while #charDeaths > DeathReplay_SavedVariables.config.maxDeathsStored do
        table.remove(charDeaths)
    end

    -- Flush the event buffer now that this death is captured. The only other
    -- clear (OnHitPointsUpdated, on reaching full HP) doesn't fire between two
    -- deaths if the player respawns and dies again without ever topping off --
    -- so without this, the prior death's hits stay buffered and get re-stamped
    -- with the next death's deathTime, surfacing as bogus far-negative-dt events
    -- in the new timeline. Reassigns the upvalue, same as the full-HP clear.
    recentEvents = {}

    -- Fold-in target for trailing post-death damage; see OnCombatEvent. Same
    -- table reference now living at charDeaths[1], so appends persist.
    lastCapturedDeath = death

    if DeathReplayIndicator and DeathReplayIndicator.Recompute then
        DeathReplayIndicator.Recompute()
    end

    -- killingBlow is nil when no HIT made it into the buffer (e.g. fall
    -- damage or every event filtered out), so the name needs a fallback.
    local kbName = L"Unknown"
    if killingBlow and killingBlow.ability and killingBlow.ability ~= L"" then
        kbName = killingBlow.ability
    end
    EA_ChatWindow.Print(CreateHyperLink(L"DeathReplay:open",
        L"[DeathReplay]: Killed by " .. kbName, { 255, 255, 0 }, {}))
end

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
        version    = SCHEMA_VERSION,
        config     = {
            maxDeathsStored     = 5,
            captureMode         = "pvp",
            debug               = false,
        },
        characters = {},
    }
end

local function pushEvent(entry)
    entry.t = GetGameTime()
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
    -- Engine reuses HIT/ABILITY_HIT/CRITICAL/ABILITY_CRITICAL for both incoming
    -- damage (amount < 0) and incoming heals (amount > 0). v1 captures damage
    -- only; same sign-based DAMAGE/HEAL split used in wsct.lua:515-527.
    if amount == nil or amount >= 0 then return end
    local abilityName = GetAbilityName(abilityID)
    local iconNum = resolveIconForAbility(abilityID, abilityName)
    if deathState == "dead" then
        -- Trailing damage: the killing blow's combat events are sometimes
        -- dispatched just after the hp=0 update that triggered captureDeath(),
        -- so they miss the snapshot. Given ordered delivery and that a corpse
        -- takes no new damage, every event we receive in the dead-window is
        -- alive-time damage arriving late, in order -- so the LAST one we see is
        -- the real killing blow. Fold each into the just-saved death (clamped to
        -- dt=0, "at death", since GetGameTime only resolves to whole seconds)
        -- and hand it the killing blow; last trailing hit wins, clearing the
        -- previous holder's *KB* flag.
        if lastCapturedDeath then
            for _, ev in ipairs(lastCapturedDeath.events) do
                if ev.killingBlow then ev.killingBlow = nil end
            end
            table.insert(lastCapturedDeath.events, {
                dt          = 0,
                kind        = "HIT",
                ability     = abilityName,
                abilityId   = abilityID,
                iconNum     = iconNum,
                amount      = -amount,
                crit        = mapping.crit,
                killingBlow = true,   -- last trailing hit wins
            })
            lastCapturedDeath.killingBlow = {
                kind      = (mapping.crit and "ABILITY_CRITICAL" or "ABILITY_HIT"),
                ability   = abilityName,
                abilityId = abilityID,
                iconNum   = iconNum,
                amount    = -amount,
            }
            if DeathReplayIndicator and DeathReplayIndicator.Recompute then
                DeathReplayIndicator.Recompute()
            end
        end
        return   -- patched onto the death; do NOT also buffer it (avoids bleed)
    end
    if DeathReplay.IsDebug() then
        EA_ChatWindow.Print(L"DR_HIT aid=" .. towstring(abilityID)
            .. L" icon=" .. towstring(iconNum or "nil")
            .. L" name=" .. towstring(abilityName))
    end
    pushEvent({
        kind      = mapping.kind,
        crit      = mapping.crit,
        amount    = -amount,
        abilityId = abilityID,
        ability   = abilityName,    -- may be empty wstring if unresolvable
        iconNum   = iconNum,        -- may be nil if cache miss
    })
end

-- Engine fires this when a buff/debuff is added/refreshed/removed on the player.
-- We don't care about the diff -- just re-walk the full SELF effect list and
-- refresh the iconCache so OnCombatEvent's resolveIconForAbility() has fresh
-- data for the most common case (an enemy applied a debuff; the next combat
-- event tick of that debuff will then match the cache).
function DeathReplay.OnEffectsUpdated()
    harvestIconsFromActiveEffects()
end

function DeathReplay.OnHitPointsUpdated()
    if not isPvpNow then return end
    local hp    = GameData.Player.hitPoints and GameData.Player.hitPoints.current or 0
    local maxHp = GameData.Player.hitPoints and GameData.Player.hitPoints.maximum or 0
    if deathState == "alive" and hp == 0 and not captureDone then
        captureDeath()
        captureDone = true
        deathState  = "dead"
    elseif deathState == "dead" and hp > 0 then
        deathState        = "alive"
        captureDone       = false
        lastCapturedDeath = nil   -- respawned: stop folding trailing damage
    end
    if hp > 0 and maxHp > 0 and hp >= maxHp and #recentEvents > 0 then
        recentEvents = {}
    end
end

-- Clicking a CreateHyperLink in chat lands in EA_ChatWindow.OnHyperLinkLButtonUp.
-- The engine routes every chat link through that one handler, so the original
-- must be chained for item links and other addons' links to keep working
-- (same shared-hook pattern as Deathblow2 and Warbuilder).
local _origOnHyperLinkLButtonUp
local function onHyperLinkLButtonUp(linkData, flags, x, y)
    _origOnHyperLinkLButtonUp(linkData, flags, x, y)
    if towstring(linkData) == L"DeathReplay:open" then
        DeathReplay_GUI.Show()
    end
end

function DeathReplay.OnInitialize()
    local function init()
        if DeathReplay_SavedVariables == nil then
            DeathReplay_SavedVariables = defaultSavedVariables()
        end
        -- Backfill config fields added after the initial v1 schema, so existing
        -- saved files don't crash IsDebug() / config reads. Cheaper than a
        -- version bump for additive defaults.
        if DeathReplay_SavedVariables.config.debug == nil then
            DeathReplay_SavedVariables.config.debug = false
        end

        -- Migration v1/v2 -> v3: deaths used to live at the root as one flat
        -- account-wide list; v3 buckets them per character under .characters.
        -- Pre-v3 captures are discarded (clean slate; capped at maxDeathsStored
        -- so the loss is small). Also drops the v1 BUFF_GAIN/BUFF_LOSS cleanup
        -- since the legacy table is going away anyway.
        if (DeathReplay_SavedVariables.version or 1) < 3 then
            DeathReplay_SavedVariables.deaths     = nil
            DeathReplay_SavedVariables.characters = DeathReplay_SavedVariables.characters or {}
            DeathReplay_SavedVariables.version    = 3
        end

        LibSlash.RegisterSlashCmd("dr", function(input) DeathReplay.HandleSlash(input) end)

        RegisterEventHandler(SystemData.Events.LOADING_END,                "DeathReplay.OnContextMaybeChanged")
        RegisterEventHandler(SystemData.Events.PLAYER_AREA_NAME_CHANGED,   "DeathReplay.OnContextMaybeChanged")
        RegisterEventHandler(SystemData.Events.SCENARIO_INSTANCE_JOIN_NOW, "DeathReplay.OnContextMaybeChanged")

        local combatEventId = SystemData.Events.WORLD_OBJ_COMBAT_EVENT
        DeathReplay.DebugPrint(L"DR_VERIFY WORLD_OBJ_COMBAT_EVENT id=" .. towstring(combatEventId or "NIL"))
        RegisterEventHandler(combatEventId, "DeathReplay.OnCombatEvent")
        DeathReplay.DebugPrint(L"DR_VERIFY registered DeathReplay.OnCombatEvent for combat events")

        RegisterEventHandler(SystemData.Events.PLAYER_CUR_HIT_POINTS_UPDATED, "DeathReplay.OnHitPointsUpdated")

        RegisterEventHandler(SystemData.Events.PLAYER_EFFECTS_UPDATED, "DeathReplay.OnEffectsUpdated")
        -- Seed iconCache with whatever's currently active so a hit that lands
        -- before the first PLAYER_EFFECTS_UPDATED still has a chance to resolve.
        harvestIconsFromActiveEffects()
        -- One-shot ingest of Warbuilder's static ability database so direct-hit
        -- abilities (no debuff aura) resolve to icons too, and so rows can
        -- enrich their hover tooltip with career name + ability category.
        buildStaticAbilityDB()

        -- Seed isPvpNow from current GameData. None of the context-change
        -- events refire on /reloadui mid-scenario, so without this seed the
        -- cache stays at its initial `false` and OnCombatEvent rejects every
        -- hit until the next zone change.
        recomputePvpContext()

        -- The GUI window has savesettings="true", so the engine restores its
        -- shown flag across /reloadui even though the .mod creates it with
        -- show="false". Lua state doesn't survive the reload, so the restored
        -- window would be empty; force it closed (and keep state.visible in
        -- sync) instead.
        DeathReplay_GUI.Hide()

        -- /reloadui rebuilds EA_ChatWindow too, so re-hooking here never
        -- stacks the hook twice.
        _origOnHyperLinkLButtonUp = EA_ChatWindow.OnHyperLinkLButtonUp
        EA_ChatWindow.OnHyperLinkLButtonUp = onHyperLinkLButtonUp

        EA_ChatWindow.Print(L"DeathReplay v0.4.3 loaded.")

        if DeathReplayIndicator and DeathReplayIndicator.Recompute then
            DeathReplayIndicator.Recompute()
        end
    end
    local ok, err = pcall(init)
    if not ok then
        EA_ChatWindow.Print(L"DeathReplay INIT ERROR: " .. towstring(tostring(err)))
    end
end

function DeathReplay.OnShutdown()
    UnregisterEventHandler(SystemData.Events.LOADING_END,                "DeathReplay.OnContextMaybeChanged")
    UnregisterEventHandler(SystemData.Events.PLAYER_AREA_NAME_CHANGED,   "DeathReplay.OnContextMaybeChanged")
    UnregisterEventHandler(SystemData.Events.SCENARIO_INSTANCE_JOIN_NOW, "DeathReplay.OnContextMaybeChanged")

    UnregisterEventHandler(SystemData.Events.WORLD_OBJ_COMBAT_EVENT, "DeathReplay.OnCombatEvent")

    UnregisterEventHandler(SystemData.Events.PLAYER_CUR_HIT_POINTS_UPDATED, "DeathReplay.OnHitPointsUpdated")

    UnregisterEventHandler(SystemData.Events.PLAYER_EFFECTS_UPDATED, "DeathReplay.OnEffectsUpdated")
end

function DeathReplay.HandleSlash(input)
    local body = input and tostring(input) or ""
    local cmd  = string.match(body, "^%s*(%S+)")
    if cmd == "debug" then
        local sub = string.match(body, "^%s*%S+%s+(%S+)")
        if sub == "on" then
            DeathReplay_SavedVariables.config.debug = true
            EA_ChatWindow.Print(L"DeathReplay: debug ON.")
        elseif sub == "off" then
            DeathReplay_SavedVariables.config.debug = false
            EA_ChatWindow.Print(L"DeathReplay: debug OFF.")
        else
            local stateText = DeathReplay.IsDebug() and L"ON" or L"OFF"
            EA_ChatWindow.Print(L"DeathReplay: debug is " .. stateText .. L". Usage: /dr debug on|off")
        end
        return
    end
    if cmd == "reset" then
        local list = getCharDeaths()
        local n = #list
        for i = #list, 1, -1 do list[i] = nil end
        recentEvents = {}
        if DeathReplay_GUI and DeathReplay_GUI.Render then
            DeathReplay_GUI.Render()
        end
        if DeathReplayIndicator and DeathReplayIndicator.Recompute then
            DeathReplayIndicator.Recompute()
        end
        EA_ChatWindow.Print(L"DeathReplay: cleared " .. towstring(n) .. L" captured death(s).")
        return
    end
    if DeathReplay_GUI and DeathReplay_GUI.Toggle then
        DeathReplay_GUI.Toggle()
    else
        EA_ChatWindow.Print(L"DeathReplay: GUI not loaded. Try /reloadui.")
    end
end

-- Wrap all public entry points in pcall + trace for diagnosis.
DeathReplay.HandleSlash             = dr_safe("HandleSlash",             DeathReplay.HandleSlash)
