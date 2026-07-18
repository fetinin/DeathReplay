-- DeathReplay v0.6.0 — skeleton, see docs/superpowers/specs/2026-05-15-death-replay-design.md

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
    -- Either accessor may create the char record first; backfill the list
    -- the other one seeds.
    if chars[key].deaths == nil then chars[key].deaths = {} end
    return chars[key].deaths
end

-- Enemy target-deaths live at characters[key].kills, beside .deaths.
local function getCharKills()
    local chars = DeathReplay_SavedVariables.characters
    local key   = characterKey()
    if chars[key] == nil then chars[key] = { deaths = {} } end
    if chars[key].kills == nil then chars[key].kills = {} end
    return chars[key].kills
end

-- Public accessor for the GUI / Indicator modules.
function DeathReplay.GetCharDeaths()
    if DeathReplay_SavedVariables == nil
       or DeathReplay_SavedVariables.characters == nil then
        return {}
    end
    return getCharDeaths()
end

-- Public accessor for the GUI's Kills view.
function DeathReplay.GetCharKills()
    if DeathReplay_SavedVariables == nil
       or DeathReplay_SavedVariables.characters == nil then
        return {}
    end
    return getCharKills()
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

-- Kill Log tunables. Outgoing damage is buffered per victim (keyed by
-- objectID) so each enemy has its own timeline ready to snapshot when it dies.
local MAX_KILL_VICTIMS         = 60    -- cap distinct victim buffers (RvR has many)
local MAX_KILL_EVENTS_PER_VICTIM = 200 -- cap hits stored per victim
-- Lazy staleness cutoff. If your damage on a victim has a gap wider than this,
-- the earlier timeline is a separate/abandoned attempt and is wiped. Doubles
-- as stale-victim eviction. Bump to 60 if long kite fights false-evict.
local KILL_STALE_GAP_SECONDS   = 30
-- GameData.Player.RvRStats.LifetimeDeathBlows increments +1 when YOU land a
-- killing blow, but the increment and the target-death event can surface in
-- EITHER order relative to each other. Killing-blow tagging therefore matches
-- the two signals two-sidedly: a captured death waits this long for a counter
-- credit, and a counter credit observed with no matching death waits this long
-- to be claimed by one. 5 seconds because the counter's surfacing latency at
-- the death instant is unmeasured and integer-second gap math truncates; the
-- cost is a slightly higher chance of crediting a simultaneous AoE deathblow
-- on an untargeted victim (~2/10 deathblows have no matching target-death) to
-- a targeted death -- accepted, crediting stays conservative.
local KILL_KB_WINDOW_SECONDS   = 5
-- Trailing fold-in window for combat events that arrive after their victim's
-- hp=0 target update. Late lethal hits land about a second after the death,
-- so this stays tight -- independent of the wider credit-matching window.
local KILL_FOLDIN_WINDOW_SECONDS = 2

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
    -- Career suffix, same meta path as the GUI tooltip subtitle. Resolves
    -- only for abilities in Warbuilder's database; NPC abilities, weapon
    -- procs and items have no .line, so the name stays bare -- no brackets.
    local meta = killingBlow
        and DeathReplay.GetAbilityMeta(killingBlow.abilityId, killingBlow.ability)
    if meta and meta.line then
        local career = GetCareerLine(meta.line)
        if career and career ~= L"" then
            kbName = kbName .. L" (" .. career .. L")"
        end
    end
    -- Filter id 11 is the channel Deathblow2 prints its death-stats line on,
    -- which chat renders gold-yellow (filter 21, Deathblow's kill line, comes
    -- out green; EA_ChatWindow.Print would be plain white). Embedded <LINK>
    -- stays clickable either way.
    TextLogAddEntry("Chat", 11, L"[DeathReplay]: Killed by "
        .. CreateHyperLink(L"DeathReplay:open", kbName, { 255, 255, 0 }, {}))
end

-- ===========================================================================
-- Kill Log capture. Mirror of the death log for ENEMIES that die while you
-- have them targeted. Mechanism (empirically verified in-game):
--   * OUTGOING combat events (objectID != you) are your own hits on a victim;
--     we buffer them per victim so each has a ready timeline.
--   * PLAYER_TARGET_UPDATED fires on your hostile target's HP changes (event-
--     driven, no polling). At death it fires with id>0 & hp==0, victim identity
--     still readable, ~1s before the corpse auto-deselects.
--   * Death rule: same id as last update, was hp>0, now hp==0 -> snapshot.
-- Object ids are PER-SPAWN, so each death is a distinct record even for a
-- repeat-dying name.
-- ===========================================================================

local HOSTILE = "selfhostiletarget"

-- Per-victim outgoing-damage buffers, keyed by objectID. Each is
-- { events = {…}, lastEventTime = <GetComputerTime secs> }. victimCount is a
-- maintained counter so we never need an O(n) walk just to test the cap.
local victimBuffers = {}
local victimCount   = 0

-- Last seen hostile-target state, for the >0 -> 0 death transition.
local lastTargetId = 0
local lastTargetHp = -1   -- -1 = unknown; UnitHealth is a 0..100 percent

-- Just-captured kill records, keyed by victim objectID, held for a short
-- trailing window so a lethal hit whose WORLD_OBJ_COMBAT_EVENT arrives AFTER the
-- hp=0 PLAYER_TARGET_UPDATED (the common ordering) folds into the ALREADY-stored
-- record instead of landing in a fresh orphan buffer for the now-dead id.
-- Keyed by objectID because several enemies can die within one window and each
-- must catch only its OWN late hit. Entry shapes (wallTime = GetComputerTime
-- secs at the death): { record = <stored kill>, wallTime } folds late hits in;
-- { ghost = <UNstored kill>, wallTime } is a death with none of our damage --
-- stored only if our late hit arrives inside the window, discarded otherwise.
-- Pruned lazily, no timer.
local recentKills = {}

local function wipeVictim(objectID)
    if victimBuffers[objectID] ~= nil then
        victimBuffers[objectID] = nil
        victimCount = victimCount - 1
    end
end

-- GetComputerTime() is INTEGER SECONDS SINCE MIDNIGHT (not milliseconds --
-- verified in-game), so a naive (now - then) goes negative across the midnight
-- boundary; add a day.
local function killGapSeconds(fromTime, toTime)
    local dt = toTime - fromTime
    if dt < 0 then dt = dt + 86400 end
    return dt
end

-- Drop recentKills entries whose trailing fold-in window has closed. Called from
-- the same handlers that already fire (a new capture, an outgoing hit) -- no
-- timer.
local function pruneRecentKills(now)
    for objectID, entry in pairs(recentKills) do
        if killGapSeconds(entry.wallTime, now) > KILL_FOLDIN_WINDOW_SECONDS then
            recentKills[objectID] = nil
        end
    end
end

-- Killing-blow tag machinery. ---------------------------------------------------
-- Guarded read of the lifetime killing-blow counter. Returns nil when RvRStats
-- isn't populated yet (early load) so callers can tell "unknown" from a real 0.
-- Deliberately NOT LifetimeKills -- that counter does not move in scenarios.
local function readDeathBlows()
    local rv = GameData.Player and GameData.Player.RvRStats
    if rv == nil then return nil end
    return rv.LifetimeDeathBlows or 0
end

-- Killing-blow state: two-sided matching between LifetimeDeathBlows increments
-- and captured target-deaths. The two signals surface in either order, so each
-- side that arrives without its counterpart waits (bounded by
-- KILL_KB_WINDOW_SECONDS) for the other. A one-sided baseline cannot work
-- here: when the counter bumps BEFORE the death event, any poke landing in
-- between observes the transition with no pending to credit, and the capture
-- that follows would never see the counter move again.
local lastSeenDb = nil   -- last successfully read LifetimeDeathBlows; nil until first read
-- Counter increments observed with no open pending kill to credit. Each entry
-- is the GetComputerTime stamp of the observation; a death captured inside the
-- window consumes the oldest one, otherwise the credit expires unclaimed.
local unclaimedDbCredits = {}
-- Kill records awaiting a counter credit. Each entry:
--   { record = <the stored kill table ref>, wallTime = <GetComputerTime secs
--     at capture, or at ghost materialization> }.
-- We hold the record TABLE (not a charKills index) so a FIFO eviction can't make
-- us tag the wrong record; mutating an evicted-but-referenced table is harmless.
-- Ordered oldest-first so a surfaced increment is credited FIFO.
local pendingKills = {}

-- Reconcile the DeathBlows counter against pending kills. Called from events
-- that already fire (renown poke primarily; also target updates), so there is
-- NO OnUpdate polling timer. Each observed counter increment credits the
-- OLDEST pending kill whose window is still open; credits are matched BEFORE
-- pendings expire, so a credit and its death observed in the same poke still
-- pair up. An increment with no open pending is parked in unclaimedDbCredits
-- for a death that surfaces later. Pendings past the window resolve as assist
-- (record.isKillingBlow stays false); parked credits past the window expire.
local function resolveKbState()
    local db  = readDeathBlows()
    local now = GetComputerTime()
    if db ~= nil then
        if lastSeenDb == nil then
            -- First successful read is the baseline; nothing to credit.
            lastSeenDb = db
        elseif db > lastSeenDb then
            local jump = db - lastSeenDb
            if jump > 10 then
                -- A jump this large is a stats resync (e.g. RvRStats
                -- repopulating after a glitch), not kill credit; rebase
                -- without crediting anything.
                jump = 0
            end
            for _ = 1, jump do
                -- pendingKills is ordered oldest-first, so the first entry
                -- still inside its window is the oldest creditable one;
                -- expired entries are skipped here and reaped below.
                local credited = false
                for i = 1, #pendingKills do
                    local p = pendingKills[i]
                    if killGapSeconds(p.wallTime, now) <= KILL_KB_WINDOW_SECONDS then
                        p.record.isKillingBlow = true
                        table.remove(pendingKills, i)
                        credited = true
                        if DeathReplay.IsDebug() then
                            EA_ChatWindow.Print(L"DR_KILL tag=killingblow victim=" .. (p.record.victimName or L"?")
                                .. L" db=" .. towstring(tostring(db))
                                .. L" gap=" .. towstring(killGapSeconds(p.wallTime, now)))
                        end
                        break
                    end
                end
                if not credited then
                    unclaimedDbCredits[#unclaimedDbCredits + 1] = now
                    if DeathReplay.IsDebug() then
                        EA_ChatWindow.Print(L"DR_KILL credit-unclaimed db=" .. towstring(tostring(db))
                            .. L" parked=" .. towstring(#unclaimedDbCredits))
                    end
                end
            end
            lastSeenDb = db
        elseif db < lastSeenDb then
            -- Counter went backwards (stats resync); rebase, no credit.
            lastSeenDb = db
        end
    end
    local i = 1
    while i <= #pendingKills do
        local p = pendingKills[i]
        if killGapSeconds(p.wallTime, now) > KILL_KB_WINDOW_SECONDS then
            if DeathReplay.IsDebug() then
                EA_ChatWindow.Print(L"DR_KILL tag=assist victim=" .. (p.record.victimName or L"?")
                    .. L" db=" .. towstring(tostring(db))
                    .. L" gap=" .. towstring(killGapSeconds(p.wallTime, now)))
            end
            table.remove(pendingKills, i)
        else
            i = i + 1
        end
    end
    i = 1
    while i <= #unclaimedDbCredits do
        if killGapSeconds(unclaimedDbCredits[i], now) > KILL_KB_WINDOW_SECONDS then
            table.remove(unclaimedDbCredits, i)
        else
            i = i + 1
        end
    end
end

-- Attach the killing-blow verdict path to a freshly stored kill record:
-- consume the oldest still-valid parked credit if one exists (the counter
-- bumped before this death surfaced), otherwise queue the record to await a
-- future increment. Callers run resolveKbState() first so a counter
-- transition in the same dispatch is already parked when this looks.
local function claimOrPendKill(record, now)
    for i = 1, #unclaimedDbCredits do
        if killGapSeconds(unclaimedDbCredits[i], now) <= KILL_KB_WINDOW_SECONDS then
            table.remove(unclaimedDbCredits, i)
            record.isKillingBlow = true
            if DeathReplay.IsDebug() then
                EA_ChatWindow.Print(L"DR_KILL tag=killingblow victim=" .. (record.victimName or L"?")
                    .. L" via=parked-credit db=" .. towstring(tostring(lastSeenDb)))
            end
            return
        end
    end
    pendingKills[#pendingKills + 1] = { record = record, wallTime = now }
end

-- Drop every victim whose last hit is older than the stale cutoff. Runs only
-- inside handlers that already fire -- no timer.
local function evictStaleVictims(now)
    for objectID, buf in pairs(victimBuffers) do
        if killGapSeconds(buf.lastEventTime, now) > KILL_STALE_GAP_SECONDS then
            victimBuffers[objectID] = nil
            victimCount = victimCount - 1
        end
    end
end

-- Safety valve for a huge simultaneous fight: evict the single stalest victim
-- so a genuinely new one fits under MAX_KILL_VICTIMS.
local function evictStalestVictim(now)
    local worstId, worstGap = nil, -1
    for objectID, buf in pairs(victimBuffers) do
        local gap = killGapSeconds(buf.lastEventTime, now)
        if gap > worstGap then worstGap, worstId = gap, objectID end
    end
    if worstId ~= nil then
        victimBuffers[worstId] = nil
        victimCount = victimCount - 1
    end
end

-- Append one outgoing hit to its victim's buffer. mapping is the resolved
-- COMBAT_EVENT_KIND entry (always a HIT here). Handles the stale-gap wipe and
-- the buffer/victim caps.
local function pushKillEvent(objectID, amount, mapping, abilityID)
    local now = GetComputerTime()
    local buf = victimBuffers[objectID]
    if buf == nil then
        if victimCount >= MAX_KILL_VICTIMS then
            evictStaleVictims(now)
            if victimCount >= MAX_KILL_VICTIMS then evictStalestVictim(now) end
        end
        buf = { events = {}, lastEventTime = now }
        victimBuffers[objectID] = buf
        victimCount = victimCount + 1
    elseif killGapSeconds(buf.lastEventTime, now) > KILL_STALE_GAP_SECONDS then
        -- The prior timeline is an abandoned attempt on this same spawn; wipe
        -- it before recording the fresh damage.
        buf.events = {}
    end
    buf.lastEventTime = now

    local abilityName = GetAbilityName(abilityID)
    local iconNum     = resolveIconForAbility(abilityID, abilityName)
    local evs = buf.events
    if #evs >= MAX_KILL_EVENTS_PER_VICTIM then
        table.remove(evs, 1)
    end
    -- Two clocks, deliberate: .t uses GetGameTime (monotonic whole seconds),
    -- matching the death log's event stamps, so dt = t - deathTime works the
    -- same for both record kinds. Only the wall-clock gap math needs
    -- GetComputerTime + its rollover guard.
    evs[#evs + 1] = {
        kind      = mapping.kind,
        crit      = mapping.crit,
        amount    = -amount,
        abilityId = abilityID,
        ability   = abilityName,   -- may be empty wstring if unresolvable
        iconNum   = iconNum,       -- may be nil if cache miss
        t         = GetGameTime(),
    }
end

local function storeKill(kill)
    local charKills = getCharKills()
    table.insert(charKills, 1, kill)
    while #charKills > DeathReplay_SavedVariables.config.maxKillsStored do
        table.remove(charKills)
    end
end

-- Snapshot a dead victim's buffer into a kill record. Reads name/career/level
-- NOW (on the death event) because the client auto-clears the target ~1s
-- later. Kill records keep the death record's field shape -- the GUI renders
-- both with the same code -- so do not diverge the event fields.
-- A death with NO damage of ours (never hit it, or last hit older than the
-- stale cutoff) is NOT stored -- witnessed kills must not appear in the log.
local function captureKill(objectID)
    local deathTime = GetGameTime()
    local buf       = victimBuffers[objectID]

    local events      = {}
    local killingBlow = nil
    if buf and #buf.events > 0
       and killGapSeconds(buf.lastEventTime, GetComputerTime()) <= KILL_STALE_GAP_SECONDS then
        for _, e in ipairs(buf.events) do
            table.insert(events, {
                dt        = e.t - deathTime,   -- negative: seconds before death
                kind      = e.kind,
                ability   = e.ability,
                abilityId = e.abilityId,
                iconNum   = e.iconNum,
                amount    = e.amount,
                crit      = e.crit,
            })
        end
        -- All buffered outgoing events are HITs, so the last one is the
        -- killing blow.
        local last = events[#events]
        last.killingBlow = true
        killingBlow = {
            kind      = (last.crit and "ABILITY_CRITICAL" or "ABILITY_HIT"),
            ability   = last.ability,
            abilityId = last.abilityId,
            iconNum   = last.iconNum,
            amount    = last.amount,
        }
    end

    local kill = {
        timestamp   = deathTime,
        zone        = fixZoneName(GetZoneName(GameData.Player.zone)),
        zoneId      = GameData.Player.zone,
        context     = (GameData.Player.isInScenario and "scenario" or "rvr"),
        viewed      = false,
        victimName  = fixZoneName(TargetInfo:UnitName(HOSTILE)),   -- strips ^M/^F
        career      = TargetInfo:UnitCareerName(HOSTILE),
        level       = TargetInfo:UnitLevel(HOSTILE),
        -- killingBlow is the last-hit EVENT table {kind,ability,...}, mirroring
        -- the death record. isKillingBlow is the SEPARATE boolean tag: true =
        -- YOU landed the finishing blow, false = assist / teammate finished it.
        -- It starts false and flips when a LifetimeDeathBlows increment is
        -- matched to this record (either side of the death may surface first).
        -- Do NOT conflate the two fields.
        killingBlow   = killingBlow,
        isKillingBlow = false,
        events        = events,
    }

    -- Prune first so the map stays bounded by kills-per-window.
    pruneRecentKills(GetComputerTime())

    if #events > 0 then
        storeKill(kill)
        -- Killing-blow verdict: reconcile the counter FIRST so an increment
        -- that surfaced before this death event is parked as a credit, then
        -- either consume a parked credit immediately or queue the record to
        -- await one.
        resolveKbState()
        claimOrPendKill(kill, GetComputerTime())
        -- Remember this record for a short trailing window so the actual
        -- killing hit -- whose combat event commonly arrives AFTER this hp=0
        -- capture -- folds into THIS record instead of a fresh orphan buffer
        -- for the now-dead id.
        recentKills[objectID] = { record = kill, wallTime = GetComputerTime() }
    else
        -- No damage of ours -> do NOT store the record. Keep it as a GHOST for
        -- the fold-in window instead: when the finishing hit is our ONLY recent
        -- hit, its combat event commonly lags the hp=0 update, so at this point
        -- the buffer is still empty even though the kill is ours. If that hit
        -- arrives within the window, the ghost is materialized into a stored
        -- record; otherwise it evaporates and nothing is logged. A killing-blow
        -- credit that surfaces before materialization is parked in
        -- unclaimedDbCredits and consumed at materialization.
        recentKills[objectID] = {
            ghost    = kill,
            wallTime = GetComputerTime(),
        }
    end

    -- Consumed; per-spawn id won't recur for a different unit, so free it.
    wipeVictim(objectID)

    if DeathReplay.IsDebug() then
        EA_ChatWindow.Print(L"DR_KILL victim=" .. kill.victimName
            .. L" lvl=" .. towstring(tostring(kill.level))
            .. L" hits=" .. towstring(#events)
            .. L" stored=" .. towstring(tostring(#events > 0))
            .. L" kb=" .. towstring(killingBlow and tostring(killingBlow.amount) or "none")
            .. L" db=" .. towstring(tostring(readDeathBlows()))
            .. L" lastSeen=" .. towstring(tostring(lastSeenDb))
            .. L" unclaimed=" .. towstring(#unclaimedDbCredits))
    end
end

-- Fold a late lethal hit into an already-captured kill record: the killing
-- hit's combat event usually lands AFTER the hp=0 target update that triggered
-- the capture, so it would otherwise miss the snapshot. Append it as a new HIT
-- and hand it the killing blow; the previous holder's *KB* flag is cleared so
-- the latest trailing hit always wins. dt (GetGameTime relative to
-- record.timestamp) is clamped forward -- never earlier than the last stored
-- event, never negative -- to keep the timeline monotonic. An EMPTY events[]
-- (witnessed kill) is fine: the late hit is still YOUR blow that killed it, so
-- it becomes both the first event and the killing blow.
local function foldLateHitIntoKill(record, amount, mapping, abilityID)
    local abilityName = GetAbilityName(abilityID)
    local iconNum     = resolveIconForAbility(abilityID, abilityName)
    for _, ev in ipairs(record.events) do
        if ev.killingBlow then ev.killingBlow = nil end
    end
    local dt   = GetGameTime() - record.timestamp
    local last = record.events[#record.events]
    if last and last.dt and dt < last.dt then dt = last.dt end
    if dt < 0 then dt = 0 end
    table.insert(record.events, {
        dt          = dt,
        kind        = mapping.kind,
        ability     = abilityName,
        abilityId   = abilityID,
        iconNum     = iconNum,
        amount      = -amount,
        crit        = mapping.crit,
        killingBlow = true,   -- latest trailing hit wins
    })
    record.killingBlow = {
        kind      = (mapping.crit and "ABILITY_CRITICAL" or "ABILITY_HIT"),
        ability   = abilityName,
        abilityId = abilityID,
        iconNum   = iconNum,
        amount    = -amount,
    }
    if DeathReplay.IsDebug() then
        EA_ChatWindow.Print(L"DR_KILL foldin victim=" .. (record.victimName or L"?")
            .. L" amount=" .. towstring(tostring(-amount)))
    end
end

-- Hostile-target watch. Fires on HP changes as well as target switches, so it
-- is fully event-driven. UnitHealth is a 0..100 PERCENT; id==0 means no target,
-- so every check gates on id>0.
function DeathReplay.OnTargetUpdated()
    if not isPvpNow then return end
    -- Piggyback poke: this fires on every target HP change (frequent in combat),
    -- so it reconciles killing-blow credit state without any dedicated timer.
    resolveKbState()
    local id = TargetInfo:UnitEntityId(HOSTILE) or 0
    local hp = TargetInfo:UnitHealth(HOSTILE)   -- 0..100 percent, may be nil

    if id > 0 and id == lastTargetId and lastTargetHp ~= nil
       and lastTargetHp > 0 and hp == 0 then
        -- It just died. The client auto-clears a dead target ~1s later, so
        -- capture (and read the victim's identity) right now.
        captureKill(id)
    elseif id > 0 and hp == 100 and victimBuffers[id] ~= nil then
        -- Full-HP reset: target seen back at full HP (retarget or heal to 100)
        -- -> the buffered damage did not contribute to a kill; wipe it so a
        -- later kill's timeline holds only post-reset damage.
        wipeVictim(id)
    end

    lastTargetId = id
    lastTargetHp = hp
end

-- Renown credit poke. objectID here is ALWAYS the recipient (you), never
-- the victim, and it fires very frequently in combat (~117x/scenario) -- useless
-- as a death trigger, but the natural, cheap "re-read LifetimeDeathBlows now"
-- signal, so this is where most killing-blow credits are actually observed.
function DeathReplay.OnRenownGained(objectID, amount)
    resolveKbState()
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
    -- Deliberately NO kill-state flush here: the stale-gap eviction is the only
    -- staleness mechanism for victim buffers (per-spawn object ids don't
    -- collide in practice), and pendingKills/recentKills self-expire in their
    -- own short windows.
    recomputePvpContext()
end

local function defaultSavedVariables()
    return {
        version    = SCHEMA_VERSION,
        config     = {
            maxDeathsStored     = 5,
            maxKillsStored      = 20,
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
    local mapping = COMBAT_EVENT_KIND[combatEvent]
    if mapping == nil then return end       -- v1 ignores misses and unknowns
    -- Engine reuses HIT/ABILITY_HIT/CRITICAL/ABILITY_CRITICAL for both damage
    -- (amount < 0) and heals (amount > 0); the sign is the only damage/heal
    -- discriminator. We capture damage only.
    if amount == nil or amount >= 0 then return end
    -- objectID != you => this is your OUTGOING hit and objectID is the victim's
    -- entity id (its abilityID is your own spellbook). Buffer it for the Kill
    -- Log; the death log below only wants the incoming branch.
    if not isDefenderPlayer(objectID) then
        -- Late killing-hit fold-in: if this victim was just captured (its hp=0
        -- target update beat this combat event, the common ordering) and we're
        -- still inside the trailing window, patch the hit onto the STORED record
        -- rather than opening a fresh orphan buffer for the now-dead id.
        local capd = recentKills[objectID]
        if capd ~= nil then
            if killGapSeconds(capd.wallTime, GetComputerTime()) <= KILL_FOLDIN_WINDOW_SECONDS then
                if capd.ghost ~= nil then
                    -- The death itself produced no stored record (no buffered
                    -- damage), but this late hit proves the kill involved us:
                    -- materialize the ghost. The KB verdict window is anchored
                    -- at NOW, not at the death: a credit that surfaced between
                    -- the death and this hit was parked in unclaimedDbCredits
                    -- (reconcile first so a same-dispatch bump is parked too)
                    -- and is consumed here.
                    local record = capd.ghost
                    foldLateHitIntoKill(record, amount, mapping, abilityID)
                    storeKill(record)
                    resolveKbState()
                    claimOrPendKill(record, GetComputerTime())
                    recentKills[objectID] = { record = record, wallTime = capd.wallTime }
                else
                    foldLateHitIntoKill(capd.record, amount, mapping, abilityID)
                end
                return
            end
            recentKills[objectID] = nil   -- window closed; treat as ordinary damage
        end
        pushKillEvent(objectID, amount, mapping, abilityID)
        return
    end
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
        if DeathReplay_SavedVariables.config.maxKillsStored == nil then
            DeathReplay_SavedVariables.config.maxKillsStored = 20
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

        -- Kill Log: hostile-target HP watch (event-driven, no polling timer).
        RegisterEventHandler(SystemData.Events.PLAYER_TARGET_UPDATED, "DeathReplay.OnTargetUpdated")

        -- Renown gains are the frequent, cheap poke that resolves pending
        -- killing-blow tags. No polling timer.
        RegisterEventHandler(SystemData.Events.WORLD_OBJ_RENOWN_GAINED, "DeathReplay.OnRenownGained")

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

        EA_ChatWindow.Print(L"DeathReplay v0.6.0 loaded.")

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

    UnregisterEventHandler(SystemData.Events.PLAYER_TARGET_UPDATED, "DeathReplay.OnTargetUpdated")

    UnregisterEventHandler(SystemData.Events.WORLD_OBJ_RENOWN_GAINED, "DeathReplay.OnRenownGained")

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
        -- Empty kills in place so the GUI's table ref stays valid. Drop
        -- pendingKills/recentKills/unclaimedDbCredits too, so a still-pending
        -- verdict or a late-hit fold-in can't mutate a record on the now-wiped
        -- list. lastSeenDb deliberately survives: it mirrors a lifetime
        -- counter, not session records, and resetting it would only force a
        -- fresh (credit-free) baseline read. victimBuffers deliberately stay:
        -- they are live in-flight timelines, not stored captures, and
        -- self-evict on the stale gap. The skull badge is deaths-only, so
        -- kills need no indicator work.
        local kills = getCharKills()
        local kn = #kills
        for i = #kills, 1, -1 do kills[i] = nil end
        pendingKills       = {}
        unclaimedDbCredits = {}
        recentKills        = {}
        recentEvents       = {}
        if DeathReplay_GUI and DeathReplay_GUI.Render then
            DeathReplay_GUI.Render()
        end
        if DeathReplayIndicator and DeathReplayIndicator.Recompute then
            DeathReplayIndicator.Recompute()
        end
        EA_ChatWindow.Print(L"DeathReplay: cleared " .. towstring(n)
            .. L" captured death(s) and " .. towstring(kn) .. L" kill(s).")
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
